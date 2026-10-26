# shellcheck shell=bash
# G10 - rare network protocols (runbook G10; script line 141).
# Same rules as V5: compliant = `modprobe --showconfig` maps the module to
# /bin/false (any file: server A modprobe.d/60-vf-net.conf, server B 60-vf-hardening.conf);
# a LOADED module (or open SCTP sockets: telco roles) is left out and reported.

G10_FILE=/etc/modprobe.d/60-vf-net.conf

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
g10_meta() { STEP_TITLE="Rare network protocols"; STEP_IDS="U22-NKM-01..04"; }

g10_check() {
    local cfg loaded m need=()
    cfg=$(modprobe --showconfig 2>/dev/null) || { item_block "modprobe --showconfig failed"; return 0; }
    loaded=$(lsmod | awk 'NR > 1 { print $1 }')
    for m in $NET_MODULES; do
        if mod_is_disabled "$m" "$cfg"; then
            item_ok "$m: install $(mod_install_cmd "$m" "$cfg")"
        elif grep -qx -- "$(mod_norm "$m")" <<<"$loaded"; then
            item_warn "$m is LOADED (in use): left out, decide by hand"
        elif [[ "$m" == sctp ]] && [[ -n "$(ss -H -A sctp 2>/dev/null)" ]]; then
            item_warn "open SCTP sockets (telco role?): sctp left out"
        elif ! modinfo -- "$m" >/dev/null 2>&1; then
            item_na "$m: not available in this kernel"
        else
            need+=("$m")
        fi
    done
    (( ${#need[@]} )) || return 0
    if [[ -e "$G10_FILE" ]] && ! ledger_owns file "$G10_FILE"; then
        item_block "$G10_FILE exists (not ours) but ${need[*]} are not blocked: fix by hand"; return 0
    fi
    item_fix "block ${need[*]} in $G10_FILE (next load; nothing is unloaded)" g10_write "$loaded"
}

g10_write() {
    local loaded=$1 m c="# VF G-0312 / U22-NKM - aasetup_harden.sh (vf-harden G10)"$'\n'
    for m in $NET_MODULES; do
        grep -qx -- "$(mod_norm "$m")" <<<"$loaded" && continue
        c+="install $m /bin/false"$'\n'"blacklist $m"$'\n'
    done
    act_write_file "$G10_FILE" 0644 "$c"
}
