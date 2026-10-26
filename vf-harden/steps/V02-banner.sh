# shellcheck shell=bash
# V2 - login banners (runbook V2; script section 7, lines 240-247).
# Adds what production taught us: motd-news.timer must be disabled once
# /etc/update-motd.d is not executable, or it fails every day (server A, 2026-10-15).

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v2_meta() { STEP_TITLE="Login banners"; STEP_IDS="U22-CB-01..06"; }

v2_check() {
    local f want
    want="$BANNER_TEXT"$'\n'
    for f in /etc/issue /etc/issue.net /etc/motd; do
        if [[ ! -e "$f" ]]; then
            item_fix "$f missing: write the banner" act_write_file "$f" 0644 "$want"
        elif [[ "$(cat -- "$f")" != "$BANNER_TEXT" ]]; then
            item_fix "$f text differs from BANNER_TEXT: replace it (original backed up)" \
                act_replace_file "$f" 0644 "$want"
        else
            item_ok "$f has the banner text"
            perm_item "$f" 0644 root root
        fi
    done
    v2_check_motd_scripts
    v2_check_motd_news
    return 0
}

# The dynamic motd prints the OS version. Symlinked scripts are judged (and, like
# the runbook's `chmod -x /etc/update-motd.d/*`, changed) through their target.
v2_check_motd_scripts() {
    local f n=0
    [[ -d /etc/update-motd.d ]] || { item_na "/etc/update-motd.d absent"; return 0; }
    for f in /etc/update-motd.d/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        n=$((n + 1))
        item_fix "$f is executable (dynamic motd shows the OS version): chmod -x" \
            act_perm "$f" 7666 "$(file_owner "$f")" "$(file_group "$f")"
    done
    (( n )) || item_ok "/etc/update-motd.d: no executable scripts"
}

v2_check_motd_news() {
    local st
    unit_exists motd-news.timer || { item_na "motd-news.timer not installed"; return 0; }
    st=$(unit_enabled motd-news.timer)
    if [[ "$st" == enabled ]]; then
        item_fix "motd-news.timer is enabled (fails daily once update-motd.d is -x): disable it" \
            act_unit_set motd-news.timer disabled
    else
        item_ok "motd-news.timer is $st"
    fi
}
