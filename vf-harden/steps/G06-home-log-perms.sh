# shellcheck shell=bash
# G6 - home and log permissions (runbook G6; script lines 512-524, 549-555).
#   /var/log files: no access for "other" (lastlog/wtmp/btmp/README may stay o+r,
#     group utmp); LOG_PERM_EXCLUDE dirs are left alone (Plesk: the panel runs as
#     psaadm and reads /var/log/plesk and /var/log/sw-cp-server).
#   homes of people (UID >= UID_MIN, below HOME_SCOPE): mode <= 750; dotfiles and
#     dot-dirs not group/other-writable; .netrc/.bash_history <= 600; .forward/.rhosts reported.
# Never chown, never the vhost homes of site users. The old mode of every file is
# recorded in the manifest (rollback). Known limit: logrotate `create` modes can
# bring o+r back on rotated logs.

g6_meta() { STEP_TITLE="Home and log permissions"; STEP_IDS="U22-UG-09, UG-10, LG-01"; }

g6_log_files() {                # log files "other" may access (lastlog/wtmp/btmp/README: only o+w/o+x count)
    local x prune=() keep='.*/\(lastlog\|wtmp\|btmp\|README\)[^/]*'
    for x in $LOG_PERM_EXCLUDE; do prune+=(-path "$x" -prune -o); done
    find /var/log -xdev "${prune[@]}" -type f \
        \( \( -regex "$keep" -perm /o+wx \) -o \( ! -regex "$keep" -perm /o+rwx \) \) -print 2>/dev/null
}

g6_homes() {                    # "user home" for people below HOME_SCOPE
    local min; min=$(login_defs_get UID_MIN) || min=1000
    awk -F: -v min="$min" -v scope="${HOME_SCOPE%/}/" '$3 >= min && $3 != 65534 && index($6, scope) == 1 && $7 !~ /(nologin|false)$/ { print $1, $6 }' /etc/passwd
}

g6_check() {
    local logs n u h m f
    logs=$(g6_log_files)
    n=$(grep -c . <<<"$logs" || true)
    if (( n )); then
        item_fix "$n log file(s) in /var/log accessible by other: o-rwx (old modes recorded)" g6_fix_logs
        head -3 <<<"$logs" | sed 's/^/              /'
    else
        item_ok "/var/log: no file accessible by other${LOG_PERM_EXCLUDE:+ (excluded: $LOG_PERM_EXCLUDE)}"
    fi
    while read -r u h; do
        [[ -d "$h" ]] || { item_warn "home of $u ($h) does not exist"; continue; }
        [[ "$(file_owner "$h")" == "$u" ]] || item_warn "$h is owned by $(file_owner "$h"), not $u (not changed)"
        m=$(file_mode "$h")
        [[ "$(mode_excess "$m" 750)" == 0 ]] && item_ok "$h $m" || item_fix "$h mode $m: at most 750" act_perm "$h" 7750 "$(file_owner "$h")" "$(file_group "$h")"
        while IFS= read -r f; do
            case "${f##*/}" in
                .forward|.rhosts) item_warn "$f exists (UG-10): remove it by hand" ;;
                .netrc|.bash_history) g6_dot "$f" 7600 ;;
                *) g6_dot "$f" 7755 ;;
            esac
        done < <(find "$h" -xdev -mindepth 1 -maxdepth 1 -name '.*' \( -type f -o -type d \) 2>/dev/null)
    done < <(g6_homes)
    return 0
}

g6_dot() {                      # PATH MAX
    local m; m=$(stat -c %a -- "$1")
    [[ "$(mode_excess "$m" "$2")" == 0 ]] && { item_ok "$1 $m"; return 0; }
    item_fix "$1 mode $m: at most $2" act_perm "$1" "$2" "$(stat -c %U -- "$1")" "$(stat -c %G -- "$1")"
}

g6_fix_logs() {
    local f max
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        case "${f##*/}" in lastlog*|wtmp*|btmp*|README*) max=7774 ;; *) max=7770 ;; esac
        act_perm "$f" "$max" "$(file_owner "$f")" "$(file_group "$f")" || return 1
    done < <(g6_log_files)
}
