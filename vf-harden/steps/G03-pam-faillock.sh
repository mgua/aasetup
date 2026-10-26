# shellcheck shell=bash
# G3 - PAM: faillock, pwhistory, no nullok (runbook G3; script lines 357-399).
# THE step with the highest lock-out risk: --apply runs it only with -C (console
# open and a second root session ready) or when it is named alone with -o G3.
#
# Target stacks (server B, built by pam-auth-update from the template, then Plesk):
#   common-auth     faillock preauth -> pam_unix -> [pam_plesk] -> faillock authfail -> pam_deny
#   common-account  pam_faillock first
#   common-password pwquality -> [pam_plesk] -> pwhistory -> pam_unix use_authtok
# PAM_MODE=manual (Plesk) inserts these lines BY HAND, fixing the jump counts, and
# keeps every other line; auto runs pam-auth-update (never --force).
# pwhistory enforce_for_root differing from the profile is a WARN (server B has it; the
# decision is the user's), never changed here.

G3_PROFILES=/usr/share/pam-configs

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
g3_meta() { STEP_TITLE="PAM faillock, pwhistory, nullok"; STEP_IDS="U22-PF-01..03, PH-01..03, PU-01..04"; }

g3_check() {
    local a="$PAM_DIR/common-auth" ac="$PAM_DIR/common-account" pw="$PAM_DIR/common-password" ext
    G3_TODO=""
    ext=$(grep -lE 'pam_(sss|krb5|ldap|google_authenticator|duo)' "$PAM_DIR"/common-* 2>/dev/null | tr '\n' ' ')
    [[ -z "$ext" ]] || { item_block "external auth modules in $ext: PAM must be done by hand with the referent"; return 0; }
    grep -qs pam_mkhomedir "$PAM_DIR"/common-* && item_warn "pam_mkhomedir found: a hand-edited stack - review the result"
    [[ -n "$PAM_ANCHOR" ]] && ! grep -qs "$PAM_ANCHOR" "$a" && item_warn "PAM_ANCHOR $PAM_ANCHOR not in common-auth"
    g3_check_faillock_conf
    g3_rule auth 'pam_faillock' 'preauth' "$a" "faillock preauth in common-auth"
    g3_rule auth 'pam_faillock' 'authfail' "$a" "faillock authfail in common-auth"
    g3_rule account 'pam_faillock' '' "$ac" "pam_faillock in common-account"
    g3_check_pwhistory "$pw"
    if grep -qE '^[^#]*pam_unix\.so.*[[:space:]]nullok' "$a" "$pw" 2>/dev/null; then
        G3_TODO+=" nullok"; item_info "pam_unix has nullok (empty passwords accepted)"
    else item_ok "no nullok on pam_unix"; fi
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    pam_has password 'pam_unix' '(yescrypt|sha512)' < "$pw" && item_ok "pam_unix hashes with yescrypt/sha512" \
        || item_warn "PU-03: pam_unix (password) without yescrypt/sha512"
    [[ -z "$G3_TODO" ]] && return 0
    if [[ "$PAM_MODE" == manual ]]; then
        item_fix "edit common-auth/account/password BY HAND:$G3_TODO (Plesk lines kept, jumps fixed)" g3_apply_manual
    else
        item_fix "pam-configs profiles +$G3_TODO, then pam-auth-update (no --force)" g3_apply_auto
    fi
}
G3_TODO=""

g3_rule() {                     # TYPE MODULE ARGS FILE LABEL
    if pam_has "$1" "$2" "$3" < "$4"; then item_ok "$5"
    else G3_TODO+=" $1:${3:-required}"; item_info "missing: $5"; fi
}

g3_check_faillock_conf() {
    local t v bad=() inl
    t=$(cat /etc/security/faillock.conf 2>/dev/null)
    v=$(kv_conf_last deny <<<"$t") || v=3
    [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 && v <= FAILLOCK_DENY )) || bad+=("deny=$v")
    v=$(kv_conf_last unlock_time <<<"$t") || v=600
    [[ "$v" =~ ^[0-9]+$ ]] && (( v == 0 || v >= FAILLOCK_UNLOCK )) || bad+=("unlock_time=$v")
    if [[ "$FAILLOCK_EVEN_DENY_ROOT" == yes ]]; then
        kv_conf_last even_deny_root <<<"$t" >/dev/null || bad+=("even_deny_root=absent")
        v=$(kv_conf_last root_unlock_time <<<"$t") || v=""
        [[ "$v" =~ ^[0-9]+$ ]] && (( v >= FAILLOCK_ROOT_UNLOCK )) || bad+=("root_unlock_time=${v:-unset}")
    fi
    inl=$(grep -hoE 'pam_faillock\.so.*(deny|unlock_time)=[0-9]+' "$PAM_DIR"/common-* 2>/dev/null | head -1)
    [[ -z "$inl" ]] || item_warn "inline faillock options override faillock.conf: $inl"
    if (( ${#bad[@]} )); then
        item_fix "faillock.conf: ${bad[*]} - rewrite it (original backed up)" act_replace_file /etc/security/faillock.conf 0644 "$(g3_faillock_text)"$'\n'
    else item_ok "faillock.conf deny/unlock_time/root settings"; fi
}

g3_faillock_text() {
    printf '%s\n' "# VF G-0312 / U22-PF - aasetup_harden.sh (vf-harden G3)" "deny = $FAILLOCK_DENY" "unlock_time = $FAILLOCK_UNLOCK"
    [[ "$FAILLOCK_EVEN_DENY_ROOT" == yes ]] && printf '%s\n' "even_deny_root" "root_unlock_time = $FAILLOCK_ROOT_UNLOCK"
    return 0
}

g3_check_pwhistory() {
    local pw=$1 args r
    if ! pam_has password 'pam_pwhistory' '' < "$pw"; then G3_TODO+=" pwhistory"; item_info "missing: pam_pwhistory"; return 0; fi
    args=$(pam_module_args password 'pam_pwhistory' < "$pw")
    r=$(grep -oE 'remember=[0-9]+' <<<"$args" | cut -d= -f2)
    [[ -z "$r" ]] && r=$(kv_conf_last remember < /etc/security/pwhistory.conf 2>/dev/null)
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    [[ "${r:-0}" =~ ^[0-9]+$ ]] && (( ${r:-0} >= PW_REMEMBER )) && item_ok "pwhistory remember=$r" \
        || item_warn "pwhistory remember=${r:-default} < $PW_REMEMBER: edit by hand"
    if [[ " $args " == *" enforce_for_root "* && "$PWHISTORY_ENFORCE_FOR_ROOT" == no ]]; then
        item_warn "pwhistory has enforce_for_root, the profile says no (Plesk resetting an old site password would fail): your decision"
    elif [[ " $args " != *" enforce_for_root "* && "$PWHISTORY_ENFORCE_FOR_ROOT" == yes ]]; then
        item_warn "pwhistory without enforce_for_root, the profile says yes"
    fi
}

g3_pwhistory_line() {
    local l=$'password\trequisite\t\t\tpam_pwhistory.so remember='"$PW_REMEMBER"
    [[ "$PWHISTORY_ENFORCE_FOR_ROOT" == yes ]] && l+=" enforce_for_root"
    printf '%s use_authtok' "$l"
}

g3_apply_manual() {
    local a="$PAM_DIR/common-auth" ac="$PAM_DIR/common-account" pw="$PAM_DIR/common-password" t
    t=$(cat "$a")
    pam_has auth 'pam_faillock' 'preauth' <<<"$t" || t=$(pam_insert_before auth '.' $'auth\trequisite\t\t\tpam_faillock.so preauth' <<<"$t") || return 1
    pam_has auth 'pam_faillock' 'authfail' <<<"$t" || t=$(pam_insert_before auth 'pam_deny[.]so' $'auth\t[default=die]\t\t\tpam_faillock.so authfail' <<<"$t") || return 1
    t=$(pam_strip_arg 'pam_unix[.]so' nullok <<<"$t")
    [[ "$t"$'\n' == "$(cat "$a")"$'\n' ]] || act_replace_file "$a" 0644 "$t"$'\n' || return 1
    t=$(cat "$ac")
    pam_has account 'pam_faillock' '' <<<"$t" || { t=$(pam_insert_before account '.' $'account\trequired\t\t\tpam_faillock.so' <<<"$t") && act_replace_file "$ac" 0644 "$t"$'\n'; } || return 1
    t=$(cat "$pw")
    pam_has password 'pam_pwhistory' '' <<<"$t" || t=$(pam_insert_before password 'pam_unix[.]so' "$(g3_pwhistory_line)" <<<"$t") || return 1
    t=$(pam_strip_arg 'pam_unix[.]so' nullok <<<"$t")
    [[ "$t"$'\n' == "$(cat "$pw")"$'\n' ]] || act_replace_file "$pw" 0644 "$t"$'\n' || return 1
    g3_print_rollback
}

g3_apply_auto() {
    act_write_file "$G3_PROFILES/faillock" 0644 $'Name: Enable pam_faillock to deny access\nDefault: yes\nPriority: 0\nAuth-Type: Primary\nAuth:\n\t[default=die]\tpam_faillock.so authfail\n' || return 1
    act_write_file "$G3_PROFILES/faillock_notify" 0644 $'Name: Notify of failed login attempts and reset count upon success\nDefault: yes\nPriority: 1024\nAuth-Type: Primary\nAuth:\n\trequisite\tpam_faillock.so preauth\nAccount-Type: Primary\nAccount:\n\trequired\tpam_faillock.so\n' || return 1
    act_write_file "$G3_PROFILES/pwhistory" 0644 "Name: pwhistory password history checking"$'\nDefault: yes\nPriority: 1023\nPassword-Type: Primary\nPassword:\n\t'"$(g3_pwhistory_line | cut -f2-)"$'\n' || return 1
    grep -q 'nullok' "$G3_PROFILES/unix" && { act_sed_file "$G3_PROFILES/unix" '/pam_unix\.so/ s/[[:space:]]+nullok\b//g' || return 1; }
    act_cmd_files "$(pam_common_files)" pam-auth-update --enable unix pwquality faillock faillock_notify pwhistory || return 1
    g3_print_rollback
}

g3_print_rollback() {
    warn "G3 applied. From a SECOND session: new login, sudo true, then 3 wrong passwords for a test user + 'faillock --user <test>'."
    warn "Undo G3 only: sudo bash $VF_ENTRY -l yellow -o G3 -r $RUN_ID"
    warn "From the console if locked out: cp -a $RUN_DIR/files$PAM_DIR/common-* $PAM_DIR/"
}
