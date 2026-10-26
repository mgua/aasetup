# shellcheck shell=bash
# vf-harden/lib/parse.sh - read-only parsers for EFFECTIVE configuration.
#
# Servers hardened by hand (server A) use the runbook's file names, servers built from
# the template (server B) use the script's names. Steps therefore ask "what will the
# system actually use?" and never "does file X exist?". Every function here is
# pure (reads files, prints a result) so tests can point it at fixture dirs.

# ---- sysctl ---------------------------------------------------------------- #
# The directories systemd-sysctl reads at boot. For files with the same name, the
# earlier directory wins. Files are applied in lexical order of their names, so
# the LAST setting of a key wins. /etc/sysctl.conf counts only through Ubuntu's
# /etc/sysctl.d/99-sysctl.conf symlink, which is how systemd-sysctl sees it too.
SYSCTL_DIRS="${SYSCTL_DIRS:-/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d}"

sysctl_files() {
    local d f b
    local -A seen=()
    for d in $SYSCTL_DIRS; do
        for f in "$d"/*.conf; do
            [[ -e "$f" ]] || continue
            b=${f##*/}
            [[ -n "${seen[$b]:-}" ]] && continue
            seen[$b]=$f
        done
    done
    (( ${#seen[@]} )) || return 0
    printf '%s\n' "${!seen[@]}" | LC_ALL=C sort | while IFS= read -r b; do
        printf '%s\n' "${seen[$b]}"
    done
}

# sysctl_persisted KEY -> "VALUE<TAB>FILE" of the setting that wins at boot.
# Returns 1 when no file sets the key.
sysctl_persisted() {
    local key=$1 f line val="" src=""
    local re="^[[:space:]]*-?${key//./[./]}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$"
    while IFS= read -r f; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ $re ]] || continue
            val=${BASH_REMATCH[1]}; src=$f
        done < "$f"
    done < <(sysctl_files)
    [[ -n "$src" ]] || return 1
    printf '%s\t%s\n' "$val" "$src"
}

# sysctl_value_ok KEY VALUE WANT: ptrace_scope may be stricter (2, 3) than 1.
sysctl_value_ok() {
    local key=$1 have=$2 want=$3
    [[ -n "$have" ]] || return 1
    if [[ "$key" == kernel.yama.ptrace_scope && "$have" =~ ^[0-9]+$ ]]; then
        (( have >= want )); return
    fi
    [[ "$have" == "$want" ]]
}

# ---- systemd INI-style files (journald.conf, coredump.conf) ---------------- #
# ini_last SECTION KEY < text: the last value of KEY inside [SECTION] (the text is
# what `systemd-analyze cat-config` prints: main file, then drop-ins, in order).
# Prints nothing and returns 1 when the key is never set.
ini_last() {
    local sec=$1 key=$2 cur="" line val="" found=0
    local re_comment='^[[:space:]]*[#;]'
    local re_section='^[[:space:]]*\[([^]]+)\][[:space:]]*$'
    local re_key="^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ $re_comment ]] && continue
        if [[ "$line" =~ $re_section ]]; then cur=${BASH_REMATCH[1]}; continue; fi
        [[ "$cur" == "$sec" && "$line" =~ $re_key ]] || continue
        val=${BASH_REMATCH[1]}
        val=${val%"${val##*[![:space:]]}"}
        found=1
    done
    (( found )) || return 1
    printf '%s\n' "$val"
}

# ---- kernel modules -------------------------------------------------------- #
# These take the `modprobe --showconfig` text as their last argument. Names are
# normalised to underscores (usb-storage == usb_storage), as the kernel does.
mod_norm() { printf '%s' "${1//-/_}"; }

mod_install_cmd() {             # mod_install_cmd MODULE CONFIGTEXT -> the install command, if any
    awk -v m="$(mod_norm "$1")" '
        $1 == "install" { x = $2; gsub("-", "_", x)
                          if (x == m) { $1 = ""; $2 = ""; sub(/^ +/, ""); c = $0 } }
        END { if (c != "") print c }' <<<"$2"
}

mod_is_disabled() {             # true when the install command is /bin/false or /bin/true
    local c
    c=$(mod_install_cmd "$1" "$2")
    [[ "$c" =~ ^(/usr)?/bin/(false|true)$ ]]
}

# ---- AIDE excludes --------------------------------------------------------- #
# aide_negative_rules FILE... -> the '!' selection lines, reduced to plain paths
# (leading '^' and any trailing regex such as '(/|$)', '/.*' or '$' removed).
aide_negative_rules() {
    local f line
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*![[:space:]]*([^[:space:]]+) ]] || continue
            line=${BASH_REMATCH[1]}
            line=${line#^}
            line=${line//\\./.}
            line=${line%%[\(\$\*\[]*}
            line=${line%.}                # '/var/log/.*' -> '/var/log/.' -> '/var/log'
            line=${line%/}
            [[ -n "$line" ]] && printf '%s\n' "$line"
        done < "$f"
    done
}

# aide_excluded PATH RULES: true when PATH equals, or sits under, one of the rules.
aide_excluded() {
    local p=${1%/} r
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        [[ "$p" == "$r" || "$p" == "$r"/* ]] && return 0
    done <<<"$2"
    return 1
}

# ---- fstab ----------------------------------------------------------------- #
# fstab_opts MOUNTPOINT < fstab : the options field of the active line, if any
fstab_opts() { awk -v mp="$1" '$1 !~ /^#/ && $2 == mp { o = $4 } END { if (o != "") print o; exit (o == "") }'; }

# fstab_add_opts MOUNTPOINT OPTS < fstab : add the missing OPTS (comma list) to that line
fstab_add_opts() {
    awk -v mp="$1" -v add="$2" 'BEGIN { n = split(add, A, ",") }
        $1 !~ /^#/ && $2 == mp { m = split($4, O, ",")
            for (i = 1; i <= n; i++) { f = 0; for (j = 1; j <= m; j++) if (O[j] == A[i]) f = 1
                                       if (!f) $4 = $4 "," A[i] } }
        { print }'
}

opts_missing() {                # opts_missing HAVE WANT : prints the WANT options not in HAVE (comma lists)
    local o out=()
    for o in ${2//,/ }; do [[ ",$1," == *",$o,"* ]] || out+=("$o"); done
    (IFS=,; printf '%s' "${out[*]}")
}

# ---- sshd -T output -------------------------------------------------------- #
# sshd_rule_ok KEY OP WANT < `sshd -T` text
#   eq   value equals WANT (case-insensitive)      le   0 < value <= WANT (numbers)
#   excl none of the comma-separated WANT items appears in the value's comma list
sshd_rule_ok() {
    local key=$1 op=$2 want=$3 have x
    have=$(awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }')
    case "$op" in
        eq)   [[ "${have,,}" == "${want,,}" ]] ;;
        le)   [[ "$have" =~ ^[0-9]+$ ]] && (( have > 0 && have <= want )) ;;
        excl) for x in ${want//,/ }; do [[ ",$have," == *",$x,"* ]] && return 1; done; [[ -n "$have" ]] ;;
        *)    return 2 ;;
    esac
}
sshd_value() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }

# ---- sudoers Defaults ------------------------------------------------------ #
# sudo_defaults FILE... : one option per line from every "Defaults" line, in order
sudo_defaults() {
    local f
    for f in "$@"; do [[ -f "$f" ]] && cat -- "$f"; done |
        awk '/^[ \t]*Defaults([ \t]|$)/ { sub(/^[ \t]*Defaults[ \t]*/, ""); n = split($0, a, /,[ \t]*/)
             for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", a[i]); if (a[i] != "") print a[i] } }'
}

# sudo_default_last NAME < options : the last setting of NAME
#   flags: prints "on" / "off" ("!name") ; values: prints the value without quotes
sudo_default_last() {
    awk -v k="$1" '$0 == k { v = "on" } $0 == "!" k { v = "off" }
        index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/^"|"$/, "", v) }
        END { if (v != "") print v; exit (v == "") }'
}

# sudoers_files : the files sudo reads (sudoers + includedir files without '.' or '~')
sudoers_files() {
    local f
    printf '%s\n' /etc/sudoers
    for f in /etc/sudoers.d/*; do
        [[ -f "$f" && "${f##*/}" != *.* && "${f##*/}" != *~ ]] && printf '%s\n' "$f"
    done
}

# ---- login.defs ------------------------------------------------------------ #
login_defs_get() { awk -v k="$1" '$1 == k { v = $2 } END { if (v != "") print v; exit (v == "") }' "${2:-/etc/login.defs}"; }
