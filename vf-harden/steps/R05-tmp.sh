# shellcheck shell=bash
# R5 - /tmp as tmpfs with nodev,nosuid[,noexec] (runbook R5; script lines 118-126).
# fstab line + `systemctl unmask tmp.mount`; effective at the next REBOOT (the
# content of /tmp is lost then). Never remounted live here.
# Plesk: allowed, with a loud warning. server B has run it through 4 Plesk updates
# (18.0.81.1-.4) without trouble, server A has never had it. Java apps that unpack .so
# files into java.io.tmpdir need -Djava.io.tmpdir elsewhere.

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
r5_meta() { STEP_TITLE="/tmp as tmpfs (noexec)"; STEP_IDS="U22-FP-15, FP-16"; }

r5_want() { echo "nodev,nosuid$([[ "$TMP_NOEXEC" == no ]] || echo ,noexec)"; }

r5_check() {
    local want fst type live miss st
    want=$(r5_want)
    type=$(awk '$1 !~ /^#/ && $2 == "/tmp" { print $3 }' /etc/fstab)
    fst=$(fstab_opts /tmp < /etc/fstab) || fst=""
    st=$(unit_enabled tmp.mount)
    if [[ -z "$fst" ]]; then
        r5_prima
        item_fix "no /tmp line in fstab: add tmpfs /tmp ($want,size=$TMP_SIZE) + unmask tmp.mount - active at the next REBOOT" r5_apply
        return 0
    fi
    miss=$(opts_missing "$fst" "$want")
    if [[ -n "$miss" ]]; then
        r5_prima
        item_fix "/tmp ($type) in fstab lacks $miss: add them - active at the next REBOOT" r5_apply
    else
        item_ok "/tmp in fstab: $type $fst"
    fi
    [[ "$st" == masked ]] && item_fix "tmp.mount is masked: unmask it" r5_unmask
    live=$(findmnt -no FSTYPE,OPTIONS --mountpoint /tmp 2>/dev/null)
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    [[ -n "$live" && -z "$(opts_missing "${live#* }" "$want")" ]] && item_ok "/tmp mounted now: $live" \
        || item_info "/tmp now: ${live:-on the root filesystem} - the fstab line takes effect at the next reboot"
    return 0
}

r5_prima() {
    local x
    item_info "/tmp uses $(du -sh /tmp 2>/dev/null | cut -f1); RAM $(free -h | awk '/^Mem:/ { print $2 }'); tmpfs size $TMP_SIZE (content lost at reboot)"
    x=$(awk '$2 ~ /x/ && $6 ~ /^\/tmp\// { print FILENAME }' /proc/[0-9]*/maps 2>/dev/null | sort -u | head -3 | tr '\n' ' ')
    [[ -z "$x" ]] || item_warn "processes run code from /tmp now ($x): with noexec they break (Java: -Djava.io.tmpdir)"
    [[ "$PROFILE" == plesk ]] && item_warn "PLESK: /tmp noexec has worked through several Plesk updates on a production server, but installers that run code from /tmp can fail: check the next Plesk/Imunify update"
    return 0
}

r5_apply() {
    local t want; want=$(r5_want)
    if fstab_opts /tmp < /etc/fstab >/dev/null; then
        t=$(fstab_add_opts /tmp "$want" < /etc/fstab)
    else
        t="$(cat /etc/fstab)"$'\n'"# VF G-0312 / U22-FP-15,16 (vf-harden R5)"$'\n'"tmpfs /tmp tmpfs defaults,rw,$want,relatime,size=$TMP_SIZE,mode=1777 0 0"
    fi
    act_replace_file /etc/fstab 0644 "$t"$'\n' || return 1
    [[ "$(unit_enabled tmp.mount)" == masked ]] && { r5_unmask || return 1; }
    systemctl daemon-reload
    REBOOT_REQUIRED+=("R5 (/tmp)")
}

r5_unmask() {
    manifest_add unit tmp.mount "$(unit_enabled tmp.mount)" "$(unit_active tmp.mount)" unmasked || return 1
    systemctl unmask tmp.mount
}
