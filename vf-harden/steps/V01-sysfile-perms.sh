# shellcheck shell=bash
# V1 - permissions of the account files (runbook V1; script section 16, lines 481-488).
# Compliant = mode no looser than the maximum, right owner and group. Ubuntu's
# defaults already comply, so this is normally ADOPTED with nothing to do.

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v1_meta() { STEP_TITLE="System file permissions"; STEP_IDS="U22-SFD-01..10"; }

v1_check() {
    local f
    for f in /etc/passwd /etc/passwd- /etc/group /etc/group- /etc/shells; do
        perm_item "$f" 0644 root root
    done
    for f in /etc/shadow /etc/shadow- /etc/gshadow /etc/gshadow-; do
        perm_item "$f" 0640 root "shadow root"
    done
    # opasswd exists once pam_pwhistory has stored a password (yellow G3); n/a before.
    perm_item /etc/security/opasswd 0600 root root
    [[ -e /etc/security/opasswd.old ]] && perm_item /etc/security/opasswd.old 0600 root root
    return 0
}
