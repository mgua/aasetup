# shellcheck shell=bash
# R6 - world-writable files and SUID/SGID binaries (runbook R6; script lines 489-498).
# REPORT ONLY. The template chmod'ed every world-writable file; on a live server a
# wrong `chmod o-w` breaks an exchange between users, and customer files under
# PLESK_VHOSTS are never touched. Fixes are made by hand, file by file, with the owner.
# Per file: the package that owns it (dpkg -S) - a world-writable or SUID file that
# no package owns is the interesting one.

r6_meta() { STEP_TITLE="World-writable and SUID/SGID (report)"; STEP_IDS="U22-SFD-11, SFD-13"; }

r6_check() {
    local raw www=${PLESK_VHOSTS:-/var/www/vhosts} ww dirs suid n
    raw=$(findmnt -rn -o TARGET,FSTYPE | awk '$2 ~ /^(ext[234]|xfs|btrfs|zfs|f2fs|jfs)$/ { print $1 }' |
        while IFS= read -r m; do
            nice -n 19 ionice -c 3 find "$m" -xdev \( -path /proc -o -path /sys -o -path /run -o -path /dev -o -path "$www" \) -prune -o \
                \( \( -type f -perm -0002 -printf 'WWF %p\n' \) , \( -type d -perm -0002 ! -perm -1000 -printf 'WWD %p\n' \) , \
                   \( -type f -perm /6000 -printf 'SUID %p\n' \) \) 2>/dev/null
        done)
    ww=$(awk '$1 == "WWF" { print $2 }' <<<"$raw")
    dirs=$(awk '$1 == "WWD" { print $2 }' <<<"$raw")
    suid=$(awk '$1 == "SUID" { print $2 }' <<<"$raw")
    item_info "$www skipped entirely (customer files: never changed by this tool)"
    r6_list "SFD-11 world-writable files (outside $www)" "$ww"
    r6_list "SFD-11 world-writable dirs without sticky bit" "$dirs"
    n=$(grep -c . <<<"$suid" || true)
    item_info "SFD-13 SUID/SGID files: $n"
    r6_list "SFD-13 SUID/SGID files not owned by any package (investigate)" "$(r6_unpackaged "$suid")"
    return 0
}

r6_list() {                     # LABEL LINES
    local n; n=$(grep -c . <<<"$2" || true)
    if (( n == 0 )); then item_ok "$1: none"; return 0; fi
    item_info "$1: $n"
    while IFS= read -r f; do
        [[ -n "$f" ]] && printf '              %s  [%s]\n' "$f" "$(r6_pkg "$f")"
    done < <(head -10 <<<"$2")
    (( n > 10 )) && printf '              ... and %s more\n' $((n - 10))
    return 0
}

r6_pkg() { dpkg -S "$1" 2>/dev/null | head -1 | cut -d: -f1 || true; }

r6_unpackaged() {
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        dpkg -S "$f" >/dev/null 2>&1 || dpkg -S "/usr$f" >/dev/null 2>&1 || dpkg -S "${f#/usr}" >/dev/null 2>&1 || echo "$f"
    done <<<"$1"
}
