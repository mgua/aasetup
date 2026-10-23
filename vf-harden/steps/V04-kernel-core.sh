# shellcheck shell=bash
# V4 - core dumps and non-network kernel parameters (runbook V4; script sections
# 3 (lines 152-156) and 4 (lines 198-202)). apport is DISABLED, never purged:
# purging it takes ubuntu-server-minimal along (runbook).
#
# sysctl compliance = the running value is right AND the value that wins at boot
# is right, from whichever file sets it (.61: 60-vf-kernel.conf, .71:
# 60-vf-hardening.conf, or Ubuntu's own 10-*.conf).

V4_SYSCTL_FILE=/etc/sysctl.d/60-vf-kernel.conf
V4_LIMITS_FILE=/etc/security/limits.d/60-vf-core.conf
V4_COREDUMP_FILE=/etc/systemd/coredump.conf.d/60-vf.conf

v4_meta() { STEP_TITLE="Core dumps, kernel parameters"; STEP_IDS="U22-APH-01..03,05,06"; }

v4_check() {
    v4_check_sysctl
    v4_check_limits
    v4_check_apport
    v4_check_coredump
    return 0
}

v4_check_sysctl() {
    local kv k want run per pfile need=()
    for kv in $V4_SYSCTL; do
        k=${kv%%=*}; want=${kv#*=}
        run=$(sysctl -n "$k" 2>/dev/null)
        per=""; pfile=""
        IFS=$'\t' read -r per pfile < <(sysctl_persisted "$k") || true
        if sysctl_value_ok "$k" "$per" "$want"; then
            if sysctl_value_ok "$k" "$run" "$want"; then item_ok "$k = $run (boot: $per from $pfile)"
            else item_fix "$k runs as $run, boot value is right: set it now" v4_sysctl_now "$k" "$want"; fi
        elif [[ -n "$pfile" && "${pfile##*/}" > "${V4_SYSCTL_FILE##*/}" ]]; then
            item_block "$k = $per is set in $pfile, which is read after ${V4_SYSCTL_FILE##*/}: fix that file by hand"
        else
            need+=("$k")
            item_info "$k: boot value '${per:-unset}'${pfile:+ ($pfile)}, running $run: want $want"
        fi
    done
    (( ${#need[@]} )) || return 0
    if [[ -e "$V4_SYSCTL_FILE" ]] && ! ledger_owns file "$V4_SYSCTL_FILE"; then
        item_block "$V4_SYSCTL_FILE exists (not ours) but does not set ${need[*]} correctly: fix by hand"
        return 0
    fi
    item_fix "write $V4_SYSCTL_FILE and load it" v4_write_sysctl
}

v4_sysctl_now() { act_sysctl_record "$1" && sysctl -q -w "$1=$2"; }

v4_write_sysctl() {
    local kv content="# VF G-0312 / U22-APH-01,02,06 - written by aasetup_harden.sh (vf-harden V4)"$'\n'
    for kv in $V4_SYSCTL; do content+="${kv%%=*} = ${kv#*=}"$'\n'; done
    # shellcheck disable=SC2046
    act_sysctl_record $(for kv in $V4_SYSCTL; do printf '%s ' "${kv%%=*}"; done) || return 1
    act_write_file "$V4_SYSCTL_FILE" 0644 "$content" && sysctl -q -p "$V4_SYSCTL_FILE"
}

v4_check_limits() {
    local re='^[[:space:]]*\*[[:space:]]+hard[[:space:]]+core[[:space:]]+0([[:space:]]|$)'
    if grep -Eqs "$re" /etc/security/limits.conf /etc/security/limits.d/*.conf; then
        item_ok "a '* hard core 0' limit is set"
    elif [[ -e "$V4_LIMITS_FILE" ]] && ! ledger_owns file "$V4_LIMITS_FILE"; then
        item_block "$V4_LIMITS_FILE exists (not ours) without '* hard core 0': fix by hand"
    else
        item_fix "no '* hard core 0' limit: write $V4_LIMITS_FILE (new logins only)" \
            act_write_file "$V4_LIMITS_FILE" 0644 $'# VF G-0312 / U22-APH-03 - aasetup_harden.sh (vf-harden V4)\n* hard core 0\n'
    fi
}

v4_check_apport() {
    local st
    pkg_installed apport || { item_na "apport not installed"; return 0; }
    st=$(unit_enabled apport.service)
    if [[ "$st" == enabled ]]; then
        item_fix "apport.service is enabled: disable it (not purge)" act_unit_set apport.service disabled
    else
        item_ok "apport.service is ${st:-not enabled}"
    fi
    if [[ -f /etc/default/apport ]] && grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*1' /etc/default/apport; then
        item_fix "/etc/default/apport has enabled=1: set enabled=0" \
            act_sed_file /etc/default/apport 's/^([[:space:]]*enabled[[:space:]]*=[[:space:]]*)1/\10/'
    fi
    if [[ "$(cat /proc/sys/kernel/core_pattern 2>/dev/null)" == *apport* && "$st" != enabled ]]; then
        item_warn "kernel.core_pattern still pipes to apport (clears at the next reboot)"
    fi
}

# Only relevant when systemd-coredump is installed (then core_pattern pipes to it).
v4_check_coredump() {
    local st
    pkg_installed systemd-coredump || { item_na "systemd-coredump not installed"; return 0; }
    st=$(systemd-analyze cat-config systemd/coredump.conf 2>/dev/null | ini_last Coredump Storage) || st=""
    if [[ "${st,,}" == none ]]; then
        item_ok "systemd-coredump Storage=none"
    elif [[ -e "$V4_COREDUMP_FILE" ]] && ! ledger_owns file "$V4_COREDUMP_FILE"; then
        item_block "$V4_COREDUMP_FILE exists (not ours) but Storage is '${st:-default}': fix by hand"
    else
        item_fix "systemd-coredump Storage='${st:-default}': write $V4_COREDUMP_FILE (Storage=none)" \
            act_write_file "$V4_COREDUMP_FILE" 0644 $'# VF G-0312 / U22-APH - aasetup_harden.sh (vf-harden V4)\n[Coredump]\nStorage=none\nProcessSizeMax=0\n'
    fi
}
