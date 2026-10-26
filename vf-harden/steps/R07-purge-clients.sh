# shellcheck shell=bash
# R7 - G9's red half: PURGE unneeded client packages (runbook G9; script lines 278-280).
# Yellow G9 only masks services; removing packages is not cleanly reversible, so it
# is red. Behind apt's own simulation: if the purge would remove ANYTHING beyond the
# listed packages (and R7_ALLOW_ALSO), it is a BLOCKER - on server A removing telnet/ftp
# also took the ubuntu-standard metapackage. PROTECTED_PACKAGES are never purged.
# Before: the command is searched in crontabs and scripts (still used = BLOCKER).

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
r7_meta() { STEP_TITLE="Purge unneeded client packages (G9b)"; STEP_IDS="U22-CL-*"; }

r7_check() {
    local p have=() extra used
    for p in $REMOVE_CLIENTS; do
        # shellcheck disable=SC2086  # space-separated profile list, split into words on purpose
        in_list "$p" $PROTECTED_PACKAGES && { item_na "$p: protected by the profile"; continue; }
        if pkg_installed "$p"; then have+=("$p"); else item_ok "$p not installed"; fi
    done
    (( ${#have[@]} )) || return 0
    used=$(r7_in_use "${have[@]}")
    [[ -z "$used" ]] || { item_block "still used by: $used - remove those uses first"; return 0; }
    extra=$(purge_sim_extra "${have[@]}")
    if [[ -n "$extra" ]]; then
        item_block "purging ${have[*]} would ALSO remove: $(tr '\n' ' ' <<<"$extra")- refused (allow a metapackage explicitly with R7_ALLOW_ALSO)"
        return 0
    fi
    item_fix "purge ${have[*]} (simulation: nothing else removed${R7_ALLOW_ALSO:+ beyond $R7_ALLOW_ALSO})" act_apt_purge "${have[@]}"
}

# Commands of the packages that appear in crontabs or local scripts.
r7_in_use() {
    local p c hits=""
    for p in "$@"; do
        for c in $(dpkg -L "$p" 2>/dev/null | grep -E '^/usr/s?bin/' | xargs -rn1 basename); do
            grep -rqsw -- "$c" /etc/crontab /etc/cron.d /var/spool/cron/crontabs /usr/local/bin /usr/local/sbin /root/bin 2>/dev/null \
                && hits+="$c($p) "
        done
    done
    printf '%s' "$hits"
}
