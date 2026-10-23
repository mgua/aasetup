# shellcheck shell=bash
# R4 - GRUB: password and boot parameters (runbook R4; script lines 205-237, 748-750).
#   boot params: apparmor=1 security=apparmor (AA-02/03), + audit=1
#     audit_backlog_limit=8192 when auditd is installed (AS-03/04), in
#     /etc/default/grub.d/60-vf-hardening.cfg; checked in the generated grub.cfg.
#   password: superuser + pbkdf2 hash in /etc/grub.d/01_vf_password, and
#     --unrestricted on the menu entries (boot needs no password, editing does).
#     WITHOUT --unrestricted the server waits for a password at every boot.
#   grub.cfg 0600 (BL-02), re-applied after every kernel update by a postinst hook.
# The hash comes from GRUB_PASSWORD_HASH_FILE (root-only file) or the environment
# variable VF_GRUB_PASSWORD_HASH - NEVER from the command line (it would land in
# sudo.log, the journal and auditd). This step NEVER reboots: it prints REBOOT REQUIRED.

R4_CMDLINE=/etc/default/grub.d/60-vf-hardening.cfg
R4_PWFILE=/etc/grub.d/01_vf_password
R4_HOOK=/etc/kernel/postinst.d/zzz-vf-grub-perms
R4_CFG=/boot/grub/grub.cfg

r4_meta() { STEP_TITLE="GRUB password and boot parameters"; STEP_IDS="U22-BL-01, BL-02, AA-02, AA-03, AS-03, AS-04"; }

r4_params() { echo "apparmor=1 security=apparmor$(pkg_installed auditd && echo ' audit=1 audit_backlog_limit=8192')"; }

r4_check() {
    local p miss=() first run
    [[ -f "$R4_CFG" ]] || { item_na "no $R4_CFG (not GRUB/BIOS layout)"; return 0; }
    r4_check_pending_reboot
    first=$(grep -m1 -E '^[[:space:]]*linux[[:space:]]' "$R4_CFG")
    run=$(cat /proc/cmdline)
    for p in $(r4_params); do
        if [[ " $first " == *" $p "* ]]; then
            [[ " $run " == *" $p "* ]] && item_ok "boot param $p (configured and running)" \
                || { item_info "boot param $p configured, active after the next reboot"; }
        else miss+=("$p"); fi
    done
    if (( ${#miss[@]} )); then
        if [[ -e "$R4_CMDLINE" ]] && ! ledger_owns file "$R4_CMDLINE"; then
            item_block "$R4_CMDLINE exists (not ours) but grub.cfg lacks ${miss[*]}: fix by hand (update-grub?)"
        else
            item_fix "boot params missing in grub.cfg: ${miss[*]} - write $R4_CMDLINE" r4_write_cmdline
        fi
    fi
    r4_check_password
    perm_item "$R4_CFG" 0600 root root
    [[ -x "$R4_HOOK" ]] && item_ok "kernel postinst hook keeps grub.cfg 0600" \
        || item_fix "add $R4_HOOK (grub.cfg back to 0600 after kernel updates)" act_write_file "$R4_HOOK" 0755 "$(r4_hook_text)"$'\n'
    (( N_FIX )) && item_fix "update-grub, grub.cfg 0600, verify --unrestricted + params; REBOOT REQUIRED (never done here)" r4_regen
    return 0
}

# A reboot scheduled behind our back (e.g. .61's vf-cond-reboot.timer) + a half-made
# GRUB password is the one dangerous combination (plesk61-hardening-plan.md).
r4_check_pending_reboot() {
    local t
    t=$(systemctl list-timers --all --no-legend 2>/dev/null | grep -iE 'reboot|shutdown' | awk '{ print $(NF-1) }' | tr '\n' ' ')
    [[ -z "${t// }" ]] && return 0
    item_block "a reboot timer is scheduled ($t): stop it before touching GRUB"
}

r4_check_password() {
    local unres entries
    if grep -qE '^[[:space:]]*set[[:space:]]+superusers=' "$R4_CFG" && grep -qE '^[[:space:]]*password_pbkdf2[[:space:]]' "$R4_CFG"; then
        item_ok "GRUB superuser with a pbkdf2 password"
        unres=$(grep -cE "^[[:space:]]*menuentry .*--unrestricted" "$R4_CFG"); entries=$(grep -cE '^[[:space:]]*menuentry ' "$R4_CFG")
        if (( unres == 0 )); then item_block "password set but NO menu entry is --unrestricted: the server will NOT boot unattended - fix NOW from the console"
        elif (( unres < entries )); then item_info "$unres of $entries menu entries are --unrestricted (the default one boots alone; recovery entries ask)"
        else item_ok "all $entries menu entries --unrestricted"; fi
        return 0
    fi
    item_fix "no GRUB password (BL-01): add superuser $GRUB_SUPERUSER from the hash file/env, --unrestricted in 10_linux" r4_password
}

r4_hash() {                     # the hash from the file (root-only) or the environment; never echoed
    local h=""
    if [[ -n "${GRUB_PASSWORD_HASH_FILE:-}" ]]; then
        [[ -f "$GRUB_PASSWORD_HASH_FILE" && "$(stat -c %U "$GRUB_PASSWORD_HASH_FILE")" == root \
           && "$(mode_excess "$(stat -c %a "$GRUB_PASSWORD_HASH_FILE")" 600)" == 0 ]] \
            || { err "GRUB_PASSWORD_HASH_FILE must be a root-owned file with mode 0600 or stricter"; return 1; }
        h=$(head -1 "$GRUB_PASSWORD_HASH_FILE" | tr -d '[:space:]')
    else
        h=${VF_GRUB_PASSWORD_HASH:-}
    fi
    grub_hash_ok "$h" || { err "no valid GRUB hash (grub-mkpasswd-pbkdf2 output) in GRUB_PASSWORD_HASH_FILE or VF_GRUB_PASSWORD_HASH"; return 1; }
    printf '%s' "$h"
}

r4_password() {
    local h
    h=$(r4_hash) || return 1
    manifest_add regen-grub || return 1
    if ! grep -q -- '--unrestricted' /etc/grub.d/10_linux; then
        act_sed_file /etc/grub.d/10_linux 's/^(CLASS="--class gnu-linux --class gnu --class os)/\1 --unrestricted/' || return 1
        grep -q -- '--unrestricted' /etc/grub.d/10_linux || { err "could not add --unrestricted to 10_linux (CLASS line differs)"; return 1; }
    fi
    act_write_file "$R4_PWFILE" 0700 "$(printf '#!/bin/sh\nexec tail -n +3 $0\nset superusers="%s"\npassword_pbkdf2 %s %s\n' "$GRUB_SUPERUSER" "$GRUB_SUPERUSER" "$h")"
}

r4_write_cmdline() {
    manifest_add regen-grub || return 1
    act_write_file "$R4_CMDLINE" 0644 "# VF G-0312 - aasetup_harden.sh (vf-harden R4)"$'\n'"GRUB_CMDLINE_LINUX=\"\$GRUB_CMDLINE_LINUX $(r4_params)\""$'\n'
}

r4_hook_text() {
    printf '%s\n' '#!/bin/sh' '# VF G-0312 / U22-BL-02 - aasetup_harden.sh (vf-harden R4)' \
        '[ -f /boot/grub/grub.cfg ] && chown root:root /boot/grub/grub.cfg && chmod 0600 /boot/grub/grub.cfg' 'exit 0'
}

r4_regen() {
    manifest_add regen-grub || return 1
    update-grub || { err "update-grub failed"; return 1; }
    chown root:root "$R4_CFG" && chmod 0600 "$R4_CFG"
    if grep -qE '^[[:space:]]*set[[:space:]]+superusers=' "$R4_CFG" && ! grep -qE 'menuentry .*--unrestricted' "$R4_CFG"; then
        err "grub.cfg has a password but no --unrestricted entry: rolling back"; return 1
    fi
    REBOOT_REQUIRED+=("R4 (GRUB)")
    warn "R4: REBOOT REQUIRED - do it attended, console open, the GRUB password at hand (vault)"
}
