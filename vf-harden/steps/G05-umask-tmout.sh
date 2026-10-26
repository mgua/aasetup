# shellcheck shell=bash
# G5 - umask, shell timeout, root umask (runbook G5; script lines 411, 440-454).
#   /etc/profile.d/50-vf-hardening.sh  umask 027 + readonly TMOUT=900 (if not set)
#   login.defs UMASK 027, `umask 027` in /root/.bashrc
# Plesk (decision Q4 pending): kept, with a warning - files an admin creates BY HAND
# in a vhost become unreadable for the web server (group/other lose read).

G5_FILE=/etc/profile.d/50-vf-hardening.sh

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
g5_meta() { STEP_TITLE="umask, shell timeout"; STEP_IDS="U22-UD-02, UD-03, RT-08"; }

g5_umask_ok() { [[ "$1" =~ ^0?[0-7]{3}$ ]] && (( (8#$1 & 8#$2) == 8#$2 )); }   # at least as strict

g5_check() {
    local v files t
    v=$(login_defs_get UMASK) || v=""
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    g5_umask_ok "$v" "$ROOT_UMASK" && item_ok "login.defs UMASK $v" \
        || item_fix "login.defs UMASK ${v:-unset}: set $ROOT_UMASK" act_login_defs UMASK "$ROOT_UMASK"
    files=$(ls /etc/profile.d/*.sh /etc/profile /etc/bash.bashrc 2>/dev/null)
    # shellcheck disable=SC2086
    t=$(cat $files 2>/dev/null)
    local um=0 tm=0
    while read -r v; do
        g5_umask_ok "$v" "$ROOT_UMASK" && um=1
    done < <(grep -oE '^[[:space:]]*umask[[:space:]]+0?[0-7]{3}' <<<"$t" | awk '{ print $2 }')
    v=$(grep -oE '^[[:space:]]*(readonly[[:space:]]+)?(export[[:space:]]+)?TMOUT=[0-9]+' <<<"$t" | tail -1 | grep -oE '[0-9]+$')
    [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 && v <= SHELL_TMOUT )) && grep -qE 'readonly[[:space:]]+(TMOUT|.*TMOUT)' <<<"$t" && tm=1
    if (( um && tm )); then
        item_ok "login shells: umask and readonly TMOUT=$v"
    elif [[ -e "$G5_FILE" ]] && ! ledger_owns file "$G5_FILE"; then
        item_block "$G5_FILE exists (not ours) without umask $ROOT_UMASK + readonly TMOUT<=$SHELL_TMOUT: fix by hand"
    else
        item_fix "write $G5_FILE (umask $ROOT_UMASK, readonly TMOUT=$SHELL_TMOUT)" act_write_file "$G5_FILE" 0644 "$(g5_text)"$'\n'
    fi
    if grep -qE "^[[:space:]]*umask[[:space:]]+0?${ROOT_UMASK#0}\b" /root/.bashrc 2>/dev/null; then
        item_ok "/root/.bashrc: umask $ROOT_UMASK"
    else
        item_fix "/root/.bashrc: append umask $ROOT_UMASK" act_replace_file /root/.bashrc 0644 "$(cat /root/.bashrc 2>/dev/null)"$'\n'"umask $ROOT_UMASK  # VF G-0312 / U22-RT-08 (vf-harden G5)"$'\n'
    fi
    if [[ "$PROFILE" == plesk ]]; then
        if (( N_FIX )); then item_warn "Plesk: with umask $ROOT_UMASK, files created BY HAND in a vhost are not readable by the web server (fix their mode, or use the panel)"
        else item_info "Plesk: files created by hand in vhosts get mode 640 (umask $ROOT_UMASK)"; fi
    fi
    return 0
}

g5_text() {
    # shellcheck disable=SC2016  # literal text on purpose: expanded later, not here
    printf '%s\n' "# VF G-0312 / U22-UD-02, UD-03 - aasetup_harden.sh (vf-harden G5)" "umask $ROOT_UMASK" \
        'if [ -z "${TMOUT:-}" ]; then' "    TMOUT=$SHELL_TMOUT" "    readonly TMOUT" "    export TMOUT" "fi"
}
