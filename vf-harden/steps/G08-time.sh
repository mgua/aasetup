# shellcheck shell=bash
# G8 - time synchronisation (runbook G8; script section 10, lines 287-301).
# Ubuntu 24.04: systemd-timesyncd (TS-01/02 apply, the daemon is NOT switched).
# Ubuntu 26.04: chrony (TS-03..06). TS-03 in both: one daemon only, VMware tools
# time sync off. The company NTP servers are not known yet: with NTP_SERVERS empty
# the step is N/A and only reports the current state.

G8_TIMESYNCD=/etc/systemd/timesyncd.conf.d/60-vf.conf
G8_CHRONY=/etc/chrony/sources.d/60-vf.sources

g8_meta() { STEP_TITLE="Time synchronisation"; STEP_IDS="U22-TS-01..06"; }

g8_daemon() {
    if [[ "$(unit_active chrony.service)" == active ]]; then echo chrony
    elif [[ "$(unit_active systemd-timesyncd.service)" == active ]]; then echo timesyncd
    else echo none; fi
}

g8_check() {
    local d sync vm
    d=$(g8_daemon)
    sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    vm=$(command -v vmware-toolbox-cmd >/dev/null 2>&1 && vmware-toolbox-cmd timesync status 2>/dev/null)
    if [[ -z "$NTP_SERVERS" ]]; then
        item_na "NTP_SERVERS not set in the profile (company NTP names pending)"
        item_info "now: daemon $d, synchronized=${sync:-?}${vm:+, VMware timesync $vm}"
        return 0
    fi
    [[ "${vm,,}" == enabled ]] && item_fix "VMware tools time sync is enabled (two clocks): disable it" g8_vmware_off
    case "$d" in
        chrony)    g8_check_chrony ;;
        timesyncd) g8_check_timesyncd ;;
        *)         item_block "no time daemon active (chrony / systemd-timesyncd): decide by hand" ;;
    esac
    [[ "$sync" == yes ]] && item_ok "clock synchronized" || item_warn "clock not synchronized yet"
}

g8_vmware_off() { act_note "VMware timesync disabled; undo by hand: vmware-toolbox-cmd timesync enable" && vmware-toolbox-cmd timesync disable; }

g8_check_timesyncd() {
    local cfg ntp
    cfg=$(systemd-analyze cat-config systemd/timesyncd.conf 2>/dev/null)
    ntp=$(ini_last Time NTP <<<"$cfg") || ntp=""
    if [[ "$ntp" == "$NTP_SERVERS" ]]; then item_ok "timesyncd NTP=$ntp"
    elif [[ -e "$G8_TIMESYNCD" ]] && ! ledger_owns file "$G8_TIMESYNCD"; then item_block "$G8_TIMESYNCD exists (not ours): fix by hand"
    else
        item_fix "timesyncd NTP='${ntp:-default}': write $G8_TIMESYNCD (NTP=$NTP_SERVERS, no fallback)" g8_write_timesyncd
    fi
}

g8_write_timesyncd() {
    act_restart_later systemd-timesyncd || return 1
    act_write_file "$G8_TIMESYNCD" 0644 $'# VF G-0312 / U22-TS - aasetup_harden.sh (vf-harden G8)\n[Time]\n'"NTP=$NTP_SERVERS"$'\nFallbackNTP=\n' \
        && systemctl restart systemd-timesyncd
}

g8_check_chrony() {
    local s missing=()
    for s in $NTP_SERVERS; do
        grep -qsE "^[[:space:]]*(server|pool)[[:space:]]+$s([[:space:]]|$)" /etc/chrony/chrony.conf /etc/chrony/sources.d/*.sources \
            || missing+=("$s")
    done
    if (( ${#missing[@]} == 0 )); then item_ok "chrony sources include $NTP_SERVERS"
    elif [[ -e "$G8_CHRONY" ]] && ! ledger_owns file "$G8_CHRONY"; then item_block "$G8_CHRONY exists (not ours): fix by hand"
    else
        item_fix "chrony lacks ${missing[*]}: write $G8_CHRONY and reload sources (pool lines are left as they are)" g8_write_chrony
    fi
}

g8_write_chrony() {
    local s c="# VF G-0312 / U22-TS - aasetup_harden.sh (vf-harden G8)"$'\n'
    for s in $NTP_SERVERS; do c+="server $s iburst"$'\n'; done
    act_write_file "$G8_CHRONY" 0644 "$c" && chronyc reload sources >/dev/null
}
