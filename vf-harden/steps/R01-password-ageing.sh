# shellcheck shell=bash
# R1 - password ageing of EXISTING accounts, per person (runbook R1; script lines
# 413-417 and firstboot line 720).
#
# Only PEOPLE (lib/accounts.sh people_list): never site users (SITE_USER_GROUP,
# SITE_USER_REGEX, homes outside HOME_SCOPE), never service accounts (UID < UID_MIN,
# nologin shells), never root (its password is the console fallback), never R1_EXCLUDE.
#   person:  max PEOPLE_PASS_MAX_DAYS, min >= PASS_MIN_DAYS, warn >= PASS_WARN_AGE,
#            inactive never when PASS_INACTIVE=-1 (Plesk: a daily journal flag instead)
#   EXPIRY_EXEMPT (break-glass, tomware): never expires.
# A password older than the new max gets its last-change date moved to TODAY first
# (as the template's firstboot did): no instant expiry, no lock, no forced change.
# Old shadow fields are recorded; rollback restores them only if R1's values are still there.

r1_meta() { STEP_TITLE="Password ageing per person"; STEP_IDS="U22-SP-01, SP-05, SP-06"; }

r1_check() {
    local today u f last min max warn ina exempt res n=0
    today=$(today_days)
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        n=$((n + 1))
        f=$(shadow_fields "$u") || { item_warn "$u: not in /etc/shadow"; continue; }
        IFS=: read -r last min max warn ina <<<"$f"
        exempt=no; in_list "$u" $EXPIRY_EXEMPT && exempt=yes
        res=$(r1_eval "$today" "$last" "$min" "$max" "$warn" "$ina" "$PEOPLE_PASS_MAX_DAYS" "$PASS_MIN_DAYS" "$PASS_WARN_AGE" "$PASS_INACTIVE" "$exempt")
        if [[ "$res" == ok ]]; then
            item_ok "$u: max ${max:-none} min ${min:-0} warn ${warn:-0} inactive ${ina:-never}$([[ $exempt == yes ]] && echo ' (exempt)')"
        else
            item_fix "$u: max ${max:-none} min ${min:-0} warn ${warn:-0} inactive ${ina:-never} -> $(r1_target "$exempt")$([[ "$res" == *reset* ]] && echo ", last change -> today (password $((today - last)) days old)")" \
                r1_apply "$u" "$exempt" "${res#fix}"
        fi
    done < <(people_list)
    (( n )) || item_na "no person accounts found by the profile's rules"
    item_info "excluded: root, service accounts, site users (${SITE_USER_GROUP:-no group}${SITE_USER_REGEX:+, $SITE_USER_REGEX}), homes outside $HOME_SCOPE${R1_EXCLUDE:+, $R1_EXCLUDE}"
    r1_check_flag
    return 0
}

r1_target() {
    if [[ "$1" == yes ]]; then echo "never expires"; return; fi
    printf 'max %s min %s warn %s inactive %s' "$PEOPLE_PASS_MAX_DAYS" "$PASS_MIN_DAYS" "$PASS_WARN_AGE" \
        "$([[ "$PASS_INACTIVE" == -1 ]] && echo never || echo "$PASS_INACTIVE")"
}

# With INACTIVE never, an expired password must still reach a person: the daily flag.
r1_check_flag() {
    [[ "$PASSWD_EXPIRY_FLAG" == yes ]] || return 0
    if [[ "$(unit_enabled vf-passwd-expiry-flag.timer)" == enabled ]]; then
        item_ok "vf-passwd-expiry-flag.timer enabled (expired passwords flagged daily)"
    else
        item_warn "PASSWD_EXPIRY_FLAG=yes but vf-passwd-expiry-flag.timer is not enabled (install it as on .71, plesk71-cutover.md 2026-10-22)"
    fi
}

r1_apply() {                    # USER EXEMPT [reset]
    local u=$1 exempt=$2 reset=${3:-} old
    old=$(shadow_fields "$u") || return 1
    IFS=: read -r -a o <<<"$old:"
    manifest_add chage "$u" "${o[0]}" "${o[1]}" "${o[2]}" "${o[3]}" "${o[4]}" || return 1
    if [[ "$exempt" == yes ]]; then
        chage -M 99999 -I -1 "$u" || return 1
    else
        [[ "$reset" == *reset* ]] && { chage -d "$(date +%F)" "$u" || return 1; }
        chage -M "$PEOPLE_PASS_MAX_DAYS" -m "$PASS_MIN_DAYS" -W "$PASS_WARN_AGE" -I "$PASS_INACTIVE" "$u" || return 1
    fi
    IFS=: read -r -a o <<<"$(shadow_fields "$u"):"
    manifest_add chage-after "$u" "${o[0]}" "${o[1]}" "${o[2]}" "${o[3]}" "${o[4]}"
    ok "$u: $(chage -l "$u" | grep -iE 'password expires|inactive' | tr -s ' ' | tr '\n' ';')"
}
