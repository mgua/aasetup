# shellcheck shell=bash
# V5 - unused filesystem modules (runbook V5; script section 2, lines 140-148).
# Compliant = `modprobe --showconfig` maps the module to /bin/false (or /bin/true),
# from any file (server A: 60-vf-fs.conf, server B: 60-vf-hardening.conf). A LOADED module
# is in use: it is reported and left out, never unloaded (no `modprobe -r`).

V5_FILE=/etc/modprobe.d/60-vf-fs.conf

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v5_meta() { STEP_TITLE="Unused filesystem modules"; STEP_IDS="U22-FKM-01..05,09,10 (+FKM-08 udf if BLOCK_UDF=yes)"; }

v5_modules() {
    local m=$FS_MODULES
    [[ "$BLOCK_UDF" == yes ]] && m+=" udf"
    [[ "$BLOCK_OVERLAY_SQUASHFS" == yes ]] && m+=" overlay squashfs"
    printf '%s\n' "$m"
}

v5_check() {
    local cfg loaded m n need=()
    cfg=$(modprobe --showconfig 2>/dev/null) || { item_block "modprobe --showconfig failed"; return 0; }
    loaded=$(lsmod | awk 'NR > 1 { print $1 }')
    for m in $(v5_modules); do
        n=$(mod_norm "$m")
        if mod_is_disabled "$m" "$cfg"; then
            item_ok "$m: install $(mod_install_cmd "$m" "$cfg")"
        elif grep -qx -- "$n" <<<"$loaded"; then
            item_warn "$m is LOADED (in use): left out, decide by hand"
        elif ! modinfo -- "$m" >/dev/null 2>&1; then
            item_na "$m: not available in this kernel"
        else
            need+=("$m")
        fi
    done
    (( ${#need[@]} )) || return 0
    if [[ -e "$V5_FILE" ]] && ! ledger_owns file "$V5_FILE"; then
        item_block "$V5_FILE exists (not ours) but ${need[*]} are not blocked: fix by hand"
        return 0
    fi
    item_fix "block ${need[*]} in $V5_FILE (takes effect for the next load; nothing is unloaded)" \
        v5_write "$loaded"
}

v5_write() {                    # every profile module that is not loaded goes in our file
    local loaded=$1 m content="# VF G-0312 / U22-FKM - aasetup_harden.sh (vf-harden V5)"$'\n'
    for m in $(v5_modules); do
        grep -qx -- "$(mod_norm "$m")" <<<"$loaded" && continue
        content+="install $m /bin/false"$'\n'"blacklist $m"$'\n'
    done
    act_write_file "$V5_FILE" 0644 "$content"
}
