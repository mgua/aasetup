# shellcheck shell=bash
# R2 - system account shells and locks (runbook R2; script lines 424, 431-439, 502-503).
# REPORT first, then account by account: only the accounts named in R2_NOLOGIN
# (shell -> nologin) and R2_LOCK (usermod -L) are changed, never the template's
# automatic loop. postgres, git, backup agents often have a real shell on purpose.
# UD-01 (nologin out of /etc/shells) is only reported: FTP daemons read that file.
# On .61/.71 there is nothing to do.

r2_meta() { STEP_TITLE="System accounts: shells and locks"; STEP_IDS="U22-RT-04, RT-06, RT-07, UD-01, UG-02"; }

r2_check() {
    local min u uid sh shells site st
    min=$(login_defs_get UID_MIN) || min=1000
    shells=$(grep -vE '^[[:space:]]*(#|$)' /etc/shells 2>/dev/null)
    site=$( [[ -n "$SITE_USER_GROUP" ]] && getent group "$SITE_USER_GROUP" | cut -d: -f4 )
    while IFS=: read -r u _ uid _ _ _ sh; do
        [[ "$u" =~ ^(root|sync|shutdown|halt)$ ]] && continue
        (( uid < min )) || continue
        [[ "$sh" =~ (nologin|false)$ ]] && continue
        if in_list "$u" $R2_NOLOGIN; then item_fix "$u ($uid) has shell $sh: set nologin (R2_NOLOGIN)" r2_nologin "$u"
        else item_warn "RT-06: system account $u ($uid) has a login shell ($sh): decide, then list it in R2_NOLOGIN"; fi
    done < /etc/passwd
    while IFS=: read -r u _ uid _ _ _ sh; do
        [[ "$u" == root ]] && continue
        grep -qxF "$sh" <<<"$shells" && continue
        st=$(passwd -S "$u" 2>/dev/null | awk '{ print $2 }')
        [[ "$st" == L* || "$st" == NP ]] && continue
        [[ ",$site," == *",$u,"* || ( -n "$SITE_USER_REGEX" && "$u" =~ $SITE_USER_REGEX ) ]] && continue
        if in_list "$u" $R2_LOCK; then item_fix "$u: no valid shell but not locked: lock (R2_LOCK)" r2_lock "$u"
        elif [[ "$st" == P* ]]; then item_warn "RT-07: $u has a password but no valid shell ($sh): lock it? (R2_LOCK)"; fi
    done < /etc/passwd
    awk -F: '$2 == "" { print $1 }' /etc/shadow | while IFS= read -r u; do item_warn "UG-02: $u has an EMPTY password"; done
    grep -q '/nologin$' <<<"$shells" && item_info "UD-01: nologin is listed in /etc/shells (left: some FTP daemons use it)"
    st=$(passwd -S root 2>/dev/null | awk '{ print $2 }')
    [[ "$st" == L* || "$st" == P* ]] && item_ok "RT-04: root password status $st" || item_warn "RT-04: root password status '$st'"
    return 0
}

r2_nologin() {
    local u=$1 old new
    old=$(getent passwd "$u" | cut -d: -f7); new=$(command -v nologin || echo /usr/sbin/nologin)
    manifest_add usershell "$u" "$old" "$new" || return 1
    usermod -s "$new" "$u"
}

r2_lock() { manifest_add userlock "$1" || return 1; usermod -L "$1"; }
