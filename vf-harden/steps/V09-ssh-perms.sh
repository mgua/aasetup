# shellcheck shell=bash
# V9 - SSH configuration and host key permissions (runbook V9; script section 11,
# lines 329-334). Permissions only: no reload, the active sshd config is unchanged.

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v9_meta() { STEP_TITLE="SSH config and host key permissions"; STEP_IDS="U22-SS-01,12,13"; }

v9_check() {
    local f
    [[ -d /etc/ssh ]] || { item_na "/etc/ssh absent"; return 0; }
    perm_item /etc/ssh/sshd_config 0600 root root
    for f in /etc/ssh/sshd_config.d/*.conf; do [[ -e "$f" ]] && perm_item "$f" 0600 root root; done
    for f in /etc/ssh/ssh_host_*_key;      do [[ -e "$f" ]] && perm_item "$f" 0600 root root; done
    for f in /etc/ssh/ssh_host_*_key.pub;  do [[ -e "$f" ]] && perm_item "$f" 0644 root root; done
    return 0
}
