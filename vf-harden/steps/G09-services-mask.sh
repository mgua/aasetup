# shellcheck shell=bash
# G9 (yellow part) - unneeded services: MASK only (runbook G9; script lines 270-284).
# Yellow never removes a package: purge (and client removal) is red, after days of
# watching the masked unit, behind the apt simulation gate (lib/pkg.sh).
#   - only units that exist; PROTECTED_UNITS are never touched (Plesk: the web,
#     FTP, DNS and mail stack);
#   - a RUNNING unit is reported, not masked (masking stops it: decide by hand);
#   - rpcbind stays when NFS mounts exist.
# rsync.service (the daemon) is always masked; the rsync command keeps working.

g9_meta() { STEP_TITLE="Unneeded services (mask only)"; STEP_IDS="U22-CS-*, GD-11 (mask; purge = red)"; }

g9_check() {
    local u st act
    for u in $MASK_UNITS; do
        if in_list "$u" $PROTECTED_UNITS || in_list "${u%.*}" $PROTECTED_UNITS; then item_na "$u: protected by the profile"; continue; fi
        unit_exists "$u" || { item_na "$u: not installed"; continue; }
        st=$(unit_enabled "$u"); act=$(unit_active "$u")
        if [[ "$st" == masked ]]; then item_ok "$u masked"; continue; fi
        if [[ "$u" == rpcbind* ]] && [[ -n "$(findmnt -t nfs,nfs4 -n 2>/dev/null)" ]]; then
            item_warn "$u: NFS mounts present, rpcbind is needed - left alone"; continue
        fi
        if [[ "$act" == active && "$u" != rsync.service ]]; then
            item_warn "$u is RUNNING ($st): masking would stop it - decide by hand (is anything using it?)"; continue
        fi
        item_fix "$u is $st/$act: stop and mask it" g9_mask "$u"
    done
    g9_report_clients
    return 0
}

g9_mask() {
    local u=$1
    manifest_add unit "$u" "$(unit_enabled "$u")" "$(unit_active "$u")" masked || return 1
    systemctl stop "$u" 2>/dev/null; systemctl mask "$u"
}

g9_report_clients() {
    local p have=()
    for p in $REMOVE_CLIENTS; do pkg_installed "$p" && have+=("$p"); done
    (( ${#have[@]} )) && item_info "client packages installed (removal is RED, gated by apt simulation): ${have[*]}"
    return 0
}
