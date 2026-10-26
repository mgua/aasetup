# shellcheck shell=bash
# vf-harden/lib/pam.sh - reading and editing PAM stacks as TEXT (pure functions,
# stdin -> stdout, unit-tested). Used when pam-auth-update must not be run: on
# Plesk it would drop the hand-added pam_plesk.so lines (servers A and B).
#
# PAM jumps ("[success=2 default=ignore]") count RULE LINES of the same type. A
# line inserted inside a jump's range moves its target, so pam_insert_before
# increases every earlier jump that crosses the insertion point.

PAM_DIR="${PAM_DIR:-/etc/pam.d}"

# pam_rules TYPE < text : the rule lines of TYPE (comments and blank lines dropped)
pam_rules() {
    awk -v t="$1" '{ sub(/^[ \t]+/, "") } /^#/ || NF == 0 { next } { x = $1; sub(/^-/, "", x) } x == t'
}

# pam_has TYPE MODULE_REGEX [ARGS_REGEX] < text : a rule of TYPE with that module (and args)
pam_has() {
    awk -v t="$1" -v m="$2" -v a="${3:-}" '
        { sub(/^[ \t]+/, "") } /^#/ || NF == 0 { next }
        { x = $1; sub(/^-/, "", x); if (x != t) next
          line = $0; sub(/^[^ \t]+[ \t]+/, "", line)
          if (line ~ /^\[/) sub(/^\[[^]]*\][ \t]*/, "", line); else sub(/^[^ \t]+[ \t]+/, "", line)
          split(line, w, /[ \t]+/)
          if (w[1] ~ m && (a == "" || line ~ a)) f = 1 }
        END { exit !f }'
}

# pam_insert_before TYPE MODULE_REGEX NEWLINE < text : insert NEWLINE before the first
# TYPE rule whose module matches (MODULE_REGEX "." = the first TYPE rule), fixing jumps.
# Fails (prints nothing) when no such rule exists.
pam_insert_before() {
    awk -v t="$1" -v m="$2" -v nl="$3" '
        { L[NR] = $0; s = $0; sub(/^[ \t]+/, "", s)
          if (s ~ /^#/ || s == "") next
          x = s; sub(/^-/, "", x); split(x, f, /[ \t]+/); if (f[1] != t) next
          R[NR] = ++r
          body = s; sub(/^[^ \t]+[ \t]+/, "", body)
          if (body ~ /^\[/) sub(/^\[[^]]*\][ \t]*/, "", body); else sub(/^[^ \t]+[ \t]+/, "", body)
          split(body, w, /[ \t]+/)
          if (!K && w[1] ~ m) { K = NR; RK = r } }
        END {
          if (!K) exit 1
          for (i = 1; i <= NR; i++) {
            if (i == K) print nl
            line = L[i]
            if ((i in R) && R[i] < RK && match(line, /\[[^]]*\]/)) {
              ctl = substr(line, RSTART, RLENGTH); out = ""; rest = ctl
              while (match(rest, /=[0-9]+/)) {
                n = substr(rest, RSTART + 1, RLENGTH - 1) + 0
                if (R[i] + n >= RK) n++
                out = out substr(rest, 1, RSTART) n; rest = substr(rest, RSTART + RLENGTH)
              }
              line = substr(line, 1, index(line, ctl) - 1) out rest substr(line, index(line, ctl) + length(ctl))
            }
            print line
          } }'
}

# pam_strip_arg MODULE_REGEX ARG < text : remove ARG (e.g. nullok) from that module's rules
pam_strip_arg() {
    awk -v m="$1" -v a="$2" '
        { s = $0; sub(/^[ \t]+/, "", s) }
        s !~ /^#/ && $0 ~ m { gsub("[ \t]+" a "([ \t]|$)", " "); sub(/[ \t]+$/, "") }
        { print }'
}

# pam_add_arg TYPE MODULE_REGEX ARG < text : append ARG right after the module name if absent
pam_add_arg() {
    awk -v t="$1" -v m="$2" -v a="$3" '
        { s = $0; sub(/^[ \t]+/, "", s); x = s; sub(/^-/, "", x); split(x, f, /[ \t]+/) }
        s !~ /^#/ && f[1] == t && match($0, m) && $0 !~ ("[ \t]" a "([ \t]|$)") {
            $0 = substr($0, 1, RSTART + RLENGTH - 1) " " a substr($0, RSTART + RLENGTH) }
        { print }'
}

# pam_module_args TYPE MODULE_REGEX < text : the argument list of the first such rule
pam_module_args() {
    awk -v t="$1" -v m="$2" '
        { s = $0; sub(/^[ \t]+/, "", s) } s ~ /^#/ || s == "" { next }
        { x = s; sub(/^-/, "", x); split(x, f, /[ \t]+/); if (f[1] != t) next
          body = x; sub(/^[^ \t]+[ \t]+/, "", body)
          if (body ~ /^\[/) sub(/^\[[^]]*\][ \t]*/, "", body); else sub(/^[^ \t]+[ \t]+/, "", body)
          n = split(body, w, /[ \t]+/)
          if (w[1] ~ m) { o = ""; for (i = 2; i <= n; i++) o = o (o == "" ? "" : " ") w[i]; print o; exit } }'
}

# kv_conf_last KEY < text : last "key = value" (pwquality.conf, faillock.conf style);
# a bare "key" line (a flag such as enforce_for_root) prints "yes".
kv_conf_last() {
    awk -v k="$1" '
        { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") } $0 == "" { next }
        $0 == k { v = "yes"; f = 1; next }
        { split($0, p, /[ \t]*=[ \t]*/) } p[1] == k { v = p[2]; f = 1 }
        END { if (f) print v; exit !f }'
}

# The files pam-auth-update may rewrite (recorded before it runs).
pam_common_files() {
    local f
    for f in common-auth common-account common-password common-session common-session-noninteractive; do
        printf '%s ' "$PAM_DIR/$f"
    done
}
