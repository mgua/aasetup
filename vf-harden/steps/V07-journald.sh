# shellcheck shell=bash
# V7 - journald (runbook V7; script section 18, lines 529-547).
# Compliant = the EFFECTIVE value (systemd-analyze cat-config: main file + drop-ins
# in order) of each key. ForwardToSyslog follows rsyslog (SL-13 with rsyslog,
# SL-04 without); a mismatch there is only a warning, because either value is a
# valid VF choice and the template decided it at build time.

V7_FILE=/etc/systemd/journald.conf.d/60-vf.conf

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v7_meta() { STEP_TITLE="journald"; STEP_IDS="U22-SL-01..06 (SL-04/SL-13)"; }

v7_wanted() {
    local fwd=no
    pkg_installed rsyslog && fwd=yes
    printf '%s\n' "Storage=$JOURNALD_STORAGE" "Compress=yes" "ForwardToSyslog=$fwd" \
        "SystemMaxUse=$JOURNALD_SYSTEM_MAX_USE" "SystemKeepFree=$JOURNALD_SYSTEM_KEEP_FREE" \
        "MaxFileSec=$JOURNALD_MAX_FILE_SEC"
}

v7_check() {
    local cfg kv k want cur bad=()
    cfg=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null) \
        || { item_block "systemd-analyze cat-config systemd/journald.conf failed"; return 0; }
    while IFS= read -r kv; do
        k=${kv%%=*}; want=${kv#*=}
        cur=$(ini_last Journal "$k" <<<"$cfg") || cur=""
        [[ -z "$cur" && "$k" == Compress ]] && cur=yes          # systemd default
        if [[ "$(bool_norm "$cur")" == "$(bool_norm "$want")" ]]; then
            item_ok "$k=$cur"
        elif [[ "$k" == ForwardToSyslog ]]; then
            item_warn "ForwardToSyslog=${cur:-default} but rsyslog installed=$want - both are valid VF choices (SL-04/SL-13); review"
        else
            bad+=("$k=${cur:-default} (want $want)")
        fi
    done < <(v7_wanted)
    (( ${#bad[@]} )) || return 0
    if [[ -e "$V7_FILE" ]] && ! ledger_owns file "$V7_FILE"; then
        item_block "$V7_FILE exists (not ours) but: ${bad[*]} - fix by hand"
        return 0
    fi
    item_fix "journald: ${bad[*]} - write $V7_FILE and restart systemd-journald" v7_write
}

v7_write() {
    local content="# VF G-0312 / U22-SL-01..06 - aasetup_harden.sh (vf-harden V7)"$'\n[Journal]\n'
    content+="$(v7_wanted)"$'\n'
    act_restart_later systemd-journald || return 1     # rollback restarts after removing the file
    act_write_file "$V7_FILE" 0644 "$content" && systemctl restart systemd-journald
}
