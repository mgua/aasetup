# shellcheck shell=bash
# V6 - password policy for the future (runbook V6; script lines 95-97, 345-356,
# 407-412). YELLOW since 2026-10-22: it changes PAM for every password change, and
# on Plesk the defaults reach the site users Plesk creates.
#
# Lessons from servers A/B:
#  - libpam-pwquality WITH its recommends: without cracklib-runtime, dictcheck=1
#    makes every non-root password change fail ("error loading dictionary").
#  - Plesk: no enforce_for_root (Plesk sets site-user passwords as root), PAM edited
#    by hand (pam-auth-update leaves or drops the pam_plesk.so lines),
#    PASS_MAX_DAYS 99999 and INACTIVE -1 as defaults (per-person expiry = R1, red).

V6_FILE=/etc/security/pwquality.conf.d/50-vf.conf

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v6_meta() { STEP_TITLE="Password policy (pwquality, login.defs)"; STEP_IDS="U22-PQ-01..08, SP-01..04 defaults, SP-05 default"; }

v6_check() {
    v6_check_packages
    v6_check_pwquality
    v6_check_pam
    v6_check_login_defs
    return 0
}

v6_check_packages() {
    local p
    for p in libpam-pwquality cracklib-runtime; do
        if pkg_installed "$p"; then item_ok "$p installed"
        else item_fix "install $p (with its recommends)" act_apt_install "" "$p"; fi
    done
    if [[ -s /var/cache/cracklib/cracklib_dict.pwd ]]; then
        item_ok "cracklib dictionary present"
    elif pkg_installed cracklib-runtime; then
        item_fix "cracklib dictionary missing: build it (update-cracklib)" v6_build_dict
    fi
}

v6_build_dict() { act_note "cracklib dictionary built (not removed by rollback)" && update-cracklib; }

# Effective pwquality: pwquality.conf, then pwquality.conf.d/*.conf in order (last wins).
v6_pwq_text() { cat /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null; }

v6_check_pwquality() {
    local t bad=() k v want efr op
    t=$(v6_pwq_text)
    for k in minlen:ge:$PW_MINLEN minclass:ge:$PW_MINCLASS difok:ge:2 maxrepeat:le:3 maxsequence:le:3 dictcheck:eq:1 enforcing:eq:1; do
        IFS=: read -r k op want <<<"$k"
        v=$(kv_conf_last "$k" <<<"$t") || v=""
        [[ "$k" == enforcing && -z "$v" ]] && v=1                     # library default
        case "$op" in
            ge) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= want )) ;;
            le) [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 && v <= want )) ;;
            eq) [[ "$v" == "$want" ]] ;;
        esac && item_ok "pwquality $k = $v" || bad+=("$k=${v:-unset}")
    done
    efr=no; kv_conf_last enforce_for_root <<<"$t" >/dev/null && efr=yes
    if [[ "$efr" == yes && "$PW_ENFORCE_FOR_ROOT" == no ]]; then
        item_block "pwquality has enforce_for_root, this profile forbids it (Plesk site creation fails): remove it by hand"
    elif [[ "$efr" == no && "$PW_ENFORCE_FOR_ROOT" == yes ]]; then
        bad+=("enforce_for_root=absent")
    else
        item_ok "pwquality enforce_for_root: $efr (profile: $PW_ENFORCE_FOR_ROOT)"
    fi
    (( ${#bad[@]} )) || return 0
    local f; f=$(v6_target)
    item_fix "pwquality: ${bad[*]} - write $f" v6_write_pwq "$f"
}

v6_target() {                   # our file, or a later-sorting one when 50-vf.conf is not ours
    if [[ -e "$V6_FILE" ]] && ! ledger_owns file "$V6_FILE"; then echo /etc/security/pwquality.conf.d/60-vf-aasetup.conf
    else echo "$V6_FILE"; fi
}

v6_write_pwq() {
    local c="# VF G-0312 / U22-PQ - aasetup_harden.sh (vf-harden V6)"$'\n'
    c+="minlen = $PW_MINLEN"$'\n'"minclass = $PW_MINCLASS"$'\n'"difok = 2"$'\n'"maxrepeat = 3"$'\n'
    c+="maxsequence = 3"$'\n'"dictcheck = 1"$'\n'"enforcing = 1"$'\n'
    [[ "$PW_ENFORCE_FOR_ROOT" == yes ]] && c+="enforce_for_root"$'\n'
    act_write_file "$1" 0644 "$c"
}

v6_check_pam() {
    local t="$PAM_DIR/common-password" args
    if pam_has password 'pam_pwquality' < "$t"; then
        item_ok "common-password uses pam_pwquality"
        args=$(pam_module_args password 'pam_pwquality' < "$t")
        [[ "$args" =~ (minlen|minclass|[dulo]credit|enforce_for_root|dictcheck)= ]] \
            && item_warn "pam_pwquality has inline options that override the .conf: $args"
        pam_has password 'pam_unix' 'use_authtok' < "$t" || item_warn "pam_unix (password) without use_authtok"
        return 0
    fi
    if [[ "$PAM_MODE" == manual ]]; then
        item_fix "add pam_pwquality to common-password BY HAND (before the first password rule; ${PAM_ANCHOR:-no} anchor kept)" v6_pam_manual
    else
        item_fix "enable the pwquality profile with pam-auth-update (no --force)" v6_pam_auto
    fi
}

# Both re-check first: installing libpam-pwquality earlier in the same plan may
# already have added the line (pam-auth-update runs from the package).
v6_pam_auto() {
    pam_has password 'pam_pwquality' < "$PAM_DIR/common-password" && { log "pam_pwquality already present"; return 0; }
    act_cmd_files "$(pam_common_files)" pam-auth-update --enable pwquality
}

v6_pam_manual() {
    local f="$PAM_DIR/common-password" new
    pam_has password 'pam_pwquality' < "$f" && { log "pam_pwquality already present"; return 0; }
    new=$(pam_insert_before password '.' $'password\trequisite\t\t\tpam_pwquality.so retry=3' < "$f" \
          | pam_add_arg password 'pam_unix[.]so' use_authtok) || { err "no password rule in $f"; return 1; }
    act_replace_file "$f" 0644 "$new"$'\n'
}

v6_check_login_defs() {
    local v max=$LOGIN_DEFS_PASS_MAX_DAYS ina
    v=$(login_defs_get PASS_MAX_DAYS) || v=""
    if v6_limit_ok "$v" "$max" 99999; then
        item_ok "login.defs PASS_MAX_DAYS $v"
    else item_fix "login.defs PASS_MAX_DAYS ${v:-unset}: set $max" act_login_defs PASS_MAX_DAYS "$max"; fi
    v=$(login_defs_get PASS_MIN_DAYS) || v=0
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    (( v >= PASS_MIN_DAYS )) && item_ok "login.defs PASS_MIN_DAYS $v" || item_fix "login.defs PASS_MIN_DAYS $v: set $PASS_MIN_DAYS" act_login_defs PASS_MIN_DAYS "$PASS_MIN_DAYS"
    v=$(login_defs_get PASS_WARN_AGE) || v=0
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    (( v >= PASS_WARN_AGE )) && item_ok "login.defs PASS_WARN_AGE $v" || item_fix "login.defs PASS_WARN_AGE $v: set $PASS_WARN_AGE" act_login_defs PASS_WARN_AGE "$PASS_WARN_AGE"
    v=$(login_defs_get ENCRYPT_METHOD) || v=""
    case "${v^^}" in
        YESCRYPT) item_ok "login.defs ENCRYPT_METHOD $v" ;;
        SHA512)   item_warn "login.defs ENCRYPT_METHOD SHA512 (acceptable; the standard prefers YESCRYPT)" ;;
        *)        item_fix "login.defs ENCRYPT_METHOD ${v:-unset}: set YESCRYPT" act_login_defs ENCRYPT_METHOD YESCRYPT ;;
    esac
    ina=$(useradd -D 2>/dev/null | awk -F= '$1 == "INACTIVE" { print $2 }')
    if v6_limit_ok "$ina" "$PASS_INACTIVE" -1; then
        item_ok "useradd default INACTIVE $ina"
    else
        item_fix "useradd default INACTIVE ${ina:-unset}: set $PASS_INACTIVE" \
            act_cmd_files /etc/default/useradd useradd -D -f "$PASS_INACTIVE"
    fi
}

# v6_limit_ok HAVE WANT OFFVALUE : WANT == OFFVALUE ("never") needs exactly that;
# otherwise HAVE must be a number in 1..WANT.
v6_limit_ok() {
    local have=$1 want=$2 off=$3
    if [[ "$want" == "$off" ]]; then [[ "$have" == "$off" ]]; return; fi
    [[ "$have" =~ ^[0-9]+$ ]] || return 1
    (( have > 0 && have <= want ))
}
