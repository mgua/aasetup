# shellcheck shell=bash
# V3 - cron and at (runbook V3; script section 8, lines 250-267). YELLOW since
# 2026-10-22: an allow file takes `crontab` away from every user not listed, and on
# Plesk it blocked scheduled tasks for NEW site users (.61, 2026-10-15).
#
# CRON_ALLOW_MODE (profile):
#   existing  cron.allow = the users who have a crontab today (runbook)
#   empty     cron.allow with no users (template script: root only)
#   none      no cron.allow (Plesk exception, CA-01); an existing one is reported
# The permission part (crontab 600, cron.* dirs 700) applies in every mode.

v3_meta() { STEP_TITLE="cron and at"; STEP_IDS="U22-CC-01..08, CA-01"; }

v3_check() {
    local d
    [[ -e /etc/crontab ]] || { item_na "cron not installed (no /etc/crontab)"; return 0; }
    perm_item /etc/crontab 0600 root root
    for d in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.yearly /etc/cron.d; do
        [[ -d "$d" ]] && perm_item "$d" 0700 root root
    done
    v3_check_allow cron /etc/cron.allow /etc/cron.deny crontab /var/spool/cron/crontabs
    pkg_installed at && v3_check_allow at /etc/at.allow /etc/at.deny daemon /var/spool/cron/atjobs
    return 0
}

v3_users_with_jobs() {          # users owning a file in the spool dir, except root
    local spool=$1
    [[ -d "$spool" ]] || return 0
    find "$spool" -maxdepth 1 -type f -printf '%u\n' 2>/dev/null | grep -vx root | sort -u
}

v3_check_allow() {              # NAME ALLOW DENY GROUP SPOOL
    local name=$1 allow=$2 deny=$3 grp=$4 spool=$5 users missing
    [[ -e "$deny" ]] && perm_item "$deny" 0640 root "$grp root"
    if [[ "$CRON_ALLOW_MODE" == none ]]; then
        if [[ -e "$allow" ]]; then
            item_warn "$allow exists, but this profile wants none (on Plesk it blocks scheduled tasks of new site users): review by hand"
        else
            item_ok "no $allow (profile: CRON_ALLOW_MODE=none, exception CA-01)"
        fi
        return 0
    fi
    users=""
    [[ "$CRON_ALLOW_MODE" == existing ]] && users=$(v3_users_with_jobs "$spool")
    if [[ ! -e "$allow" ]]; then
        item_fix "$allow missing: create it with $(grep -c . <<<"$users" || true) user(s) who have $name jobs today" \
            v3_write_allow "$allow" "$grp" "$users"
        return 0
    fi
    perm_item "$allow" 0640 root "$grp root"
    missing=$(comm -23 <(printf '%s\n' "$users" | sed '/^$/d' | sort -u) <(sort -u "$allow"))
    [[ -z "$missing" ]] || item_warn "$allow lacks users who have $name jobs: $(tr '\n' ' ' <<<"$missing")- they cannot edit them"
}

v3_write_allow() {              # ALLOW GROUP USERS
    local allow=$1 grp=$2 users=$3
    getent group "$grp" >/dev/null || grp=root
    act_write_file "$allow" 0640 "${users:+$users$'\n'}" && chown "root:$grp" "$allow"
}
