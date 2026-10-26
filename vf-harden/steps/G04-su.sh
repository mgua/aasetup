# shellcheck shell=bash
# G4 - su restricted to a group (runbook G4; script lines 400-403).
# `auth required pam_wheel.so use_uid group=<SUGROUP>` right after pam_rootok in
# /etc/pam.d/su: root (and so `sudo su - x`) still switches, and so do the group's members.
# The template created the group EMPTY, which blocked `su` for every admin on server B.
# Members: SUGROUP_MEMBERS, or auto = the sudo group + the users in /etc/sudoers.d.
# An empty group with pam_wheel active is fixed (members added). A non-empty group
# that lacks some admin is only reported: adding members grants `su`.

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
g4_meta() { STEP_TITLE="su restricted to $SUGROUP"; STEP_IDS="U22-PE-03"; }

g4_admins() {
    local u f
    # shellcheck disable=SC2086
    if [[ "$SUGROUP_MEMBERS" != auto ]]; then printf '%s\n' $SUGROUP_MEMBERS; return 0; fi
    { getent group sudo | cut -d: -f4 | tr ',' '\n'
      for f in $(sudoers_files); do
          [[ "$f" == /etc/sudoers ]] && continue
          awk '!/^[ \t]*(#|$|Defaults|%|[A-Z_]+_Alias)/ && /=/ { print $1 }' "$f"
      done; } | sort -u | while IFS= read -r u; do
        [[ -n "$u" ]] && getent passwd "$u" >/dev/null && printf '%s\n' "$u"
    done
}

g4_members() { getent group "$SUGROUP" | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort -u; }

g4_check() {
    local su=/etc/pam.d/su admins members missing
    [[ -f "$su" ]] || { item_na "$su absent"; return 0; }
    admins=$(g4_admins); members=$(g4_members)
    item_info "admins (sudo): $(tr '\n' ' ' <<<"$admins")| $SUGROUP: $(tr '\n' ' ' <<<"$members")"
    if pam_has auth 'pam_wheel' "group=$SUGROUP" < "$su"; then
        item_ok "pam_wheel group=$SUGROUP in $su"
    elif pam_has auth 'pam_wheel' '' < "$su"; then
        item_block "$su has a pam_wheel rule for another group: fix by hand"; return 0
    else
        item_fix "add 'auth required pam_wheel.so use_uid group=$SUGROUP' after pam_rootok in $su" g4_add_wheel
    fi
    getent group "$SUGROUP" >/dev/null || item_fix "create group $SUGROUP" act_group_create "$SUGROUP"
    missing=$(comm -23 <(sed '/^$/d' <<<"$admins" | sort -u) <(sed '/^$/d' <<<"$members"))
    if [[ -z "$members" && -n "$admins" ]]; then
        item_fix "$SUGROUP is empty (su blocked for every admin): add $(tr '\n' ' ' <<<"$admins")" g4_add_members "$admins"
    elif [[ -n "$missing" ]]; then
        item_warn "admins not in $SUGROUP (they can use sudo, not su): $(tr '\n' ' ' <<<"$missing")"
    else
        item_ok "$SUGROUP has all admins"
    fi
}

g4_add_members() { local u; for u in $1; do act_group_add "$u" "$SUGROUP" || return 1; done; }

g4_add_wheel() {
    local f=/etc/pam.d/su t
    t=$(awk -v g="$SUGROUP" '{ print } !done && /^[ \t]*auth[ \t]+sufficient[ \t]+pam_rootok\.so/ {
            print "auth       required   pam_wheel.so use_uid group=" g; done = 1 }
        END { exit !done }' "$f") || { err "no 'auth sufficient pam_rootok.so' line in $f"; return 1; }
    act_group_create "$SUGROUP" || return 1
    act_replace_file "$f" 0644 "$t"$'\n'
}
