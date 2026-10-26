# shellcheck shell=bash
# G1 - SSH server (runbook G1; script section 11, lines 304-341).
#
# Compliant = the EFFECTIVE configuration (`sshd -T`, and `sshd -T -C` per user and
# address), whatever file sets it. Layout used on servers A and B:
#   /etc/ssh/sshd_config.d/01-vf-hardening.conf   the runbook's drop-in (PermitRootLogin no)
#   end of /etc/ssh/sshd_config:                   Match User root Address <intranet>
#                                                  PermitRootLogin prohibit-password
# The root exception never goes into the drop-in: drop-ins are included at the TOP
# of sshd_config, and a Match block there would swallow the rest of the file.
# server B has an existing root block without 127.0.0.1: an allowed address that is missing is a
# WARN (a foreign Match block is never edited); root allowed from OUTSIDE is a BLOCKER.

G1_DROPIN=/etc/ssh/sshd_config.d/01-vf-hardening.conf
G1_SNAP=""

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
g1_meta() { STEP_TITLE="SSH server"; STEP_IDS="U22-SS-02..11, 14..22 (SS-08 per role)"; }

g1_rules() {
    printf '%s\n' "usepam eq yes" "hostbasedauthentication eq no" "ignorerhosts eq yes" \
        "maxauthtries le $SSH_MAX_AUTH_TRIES" "permitemptypasswords eq no" "permitrootlogin eq no" \
        "clientaliveinterval le $SSH_CLIENT_ALIVE_INTERVAL" "clientalivecountmax le $SSH_CLIENT_ALIVE_COUNT_MAX" \
        "gssapiauthentication eq no" "banner eq /etc/issue.net" \
        "ciphers excl 3des-cbc,aes128-cbc,aes192-cbc,aes256-cbc" \
        "kexalgorithms excl diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1" \
        "macs excl hmac-md5,hmac-md5-96,hmac-ripemd160,hmac-sha1-96,umac-64@openssh.com,hmac-md5-etm@openssh.com,hmac-md5-96-etm@openssh.com,hmac-ripemd160-etm@openssh.com,hmac-sha1-96-etm@openssh.com,umac-64-etm@openssh.com,umac-128-etm@openssh.com" \
        "logingracetime le $SSH_LOGIN_GRACE_TIME" "loglevel eq VERBOSE" "maxsessions le $SSH_MAX_SESSIONS" \
        "maxstartups eq $SSH_MAX_STARTUPS" "permituserenvironment eq no"
    [[ "$SSH_DISABLE_FORWARDING" == yes ]] && echo "disableforwarding eq yes"
    return 0
}

g1_eff() { sshd -T -C "user=$1,host=vf-check.invalid,addr=$2" 2>/dev/null | sshd_value "$3"; }

g1_check() {
    local glob key op want bad=()
    command -v sshd >/dev/null 2>&1 || { item_na "no sshd on this machine"; return 0; }
    glob=$(sshd -T 2>/dev/null) || { item_block "sshd -T fails: $(sshd -T 2>&1 | tail -1)"; return 0; }
    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
        || item_warn "sshd_config does not Include sshd_config.d/*.conf: the drop-in would be ignored"
    while read -r key op want; do
        if sshd_rule_ok "$key" "$op" "$want" <<<"$glob"; then item_ok "$key $(sshd_value "$key" <<<"$glob" | cut -c1-60)"
        else bad+=("$key"); item_info "$key = $(sshd_value "$key" <<<"$glob" | cut -c1-80) (want $op $want)"; fi
    done < <(g1_rules)
    g1_check_root
    g1_cases
    if (( ${#bad[@]} )); then
        if [[ -e "$G1_DROPIN" ]] && ! ledger_owns file "$G1_DROPIN"; then
            item_block "$G1_DROPIN exists (not ours) but ${bad[*]} differ: fix by hand"
        else
            g1_prima_root_logins
            item_fix "write $G1_DROPIN (${bad[*]})" act_write_file "$G1_DROPIN" 0600 "$(g1_dropin)"
        fi
    fi
    (( N_FIX )) && item_fix "sshd -t, then reload ssh (existing sessions stay open)" g1_test_reload
    return 0
}

# Root by key from the profile's addresses only; never from outside.
g1_check_root() {
    local c host v out ok=() missing=()
    out=$(g1_eff root "$SSH_ROOT_OUTSIDE_TEST" permitrootlogin)
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    [[ "$out" == no ]] && item_ok "root from outside ($SSH_ROOT_OUTSIDE_TEST): no" \
        || item_block "root from outside ($SSH_ROOT_OUTSIDE_TEST) is '$out': fix by hand"
    [[ -n "$ROOT_LOGIN_ALLOW_FROM" ]] || return 0
    for c in $ROOT_LOGIN_ALLOW_FROM; do
        host=$(cidr_test_host "$c") || { item_warn "ROOT_LOGIN_ALLOW_FROM: '$c' is not an IPv4 address/CIDR"; continue; }
        v=$(g1_eff root "$host" permitrootlogin)
        case "$v" in
            without-password|prohibit-password|forced-commands-only) ok+=("$c") ;;
            *) missing+=("$c") ;;
        esac
    done
    (( ${#ok[@]} )) && item_ok "root by key only from: ${ok[*]}"
    (( ${#missing[@]} )) || return 0
    if grep -Eqi '^[[:space:]]*Match[[:space:]].*User[[:space:]]+root' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        item_warn "root is refused from ${missing[*]} (profile allows it), but a 'Match User root' block exists: adjust it by hand if wanted"
    else
        item_fix "append 'Match User root Address ${ROOT_LOGIN_ALLOW_FROM// /,}' (prohibit-password) to the END of sshd_config" g1_append_root_match
    fi
}

g1_append_root_match() {
    local f=/etc/ssh/sshd_config c
    c="$(cat "$f")"$'\n\n'"# VF G-0312 / U22-SS-06 exception - aasetup_harden.sh (vf-harden G1): root by key, these addresses only"$'\n'
    c+="Match User root Address ${ROOT_LOGIN_ALLOW_FROM// /,}"$'\n'"    PermitRootLogin prohibit-password"$'\n'
    act_replace_file "$f" 0600 "$c"
}

# The users/addresses the profile wants watched (SSH_VERIFY_CASES="user@addr ..."):
# shown in check, and compared before/after an apply (no-harm).
g1_cases() {
    local c line
    G1_SNAP=""
    for c in $SSH_VERIFY_CASES; do
        line="$c: $(sshd -T -C "user=${c%@*},host=vf-check.invalid,addr=${c#*@}" 2>/dev/null \
            | awk '$1 ~ /^(permitrootlogin|forcecommand|allowusers|passwordauthentication)$/ { printf "%s=%s ", $1, $2 }')"
        item_info "$line"
        G1_SNAP+="$line"$'\n'
    done
}

# Before PermitRootLogin no: who logs in as root today, and would they be refused?
g1_prima_root_logins() {
    local ip refused=()
    for ip in $(journalctl -u ssh -u sshd --since -30d --no-pager -q -o cat 2>/dev/null \
                | grep -oE 'Accepted [a-z-]+ for root from [0-9.]+' | awk '{ print $NF }' | sort -u); do
        ip_in_any "$ip" "$ROOT_LOGIN_ALLOW_FROM" || refused+=("$ip")
    done
    (( ${#refused[@]} == 0 )) || item_block "root logged in (last 30 days) from ${refused[*]}, which PermitRootLogin no would refuse: agree first (ROOT_LOGIN_ALLOW_FROM)"
}

g1_dropin() {
    printf '%s\n' "# VF G-0312 - aasetup_harden.sh (vf-harden G1). First value wins: included at the top of sshd_config." \
        "UsePAM yes" "HostbasedAuthentication no" "IgnoreRhosts yes" "MaxAuthTries $SSH_MAX_AUTH_TRIES" \
        "PermitEmptyPasswords no" "PermitRootLogin no" "ClientAliveInterval $SSH_CLIENT_ALIVE_INTERVAL" \
        "ClientAliveCountMax $SSH_CLIENT_ALIVE_COUNT_MAX" "GSSAPIAuthentication no" "Banner /etc/issue.net" \
        "Ciphers -3des-cbc,aes128-cbc,aes192-cbc,aes256-cbc" \
        "KexAlgorithms -diffie-hellman-group1-sha1,diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1" \
        "MACs -hmac-md5,hmac-md5-96,hmac-ripemd160,hmac-sha1-96,umac-64@openssh.com,hmac-md5-etm@openssh.com,hmac-md5-96-etm@openssh.com,hmac-ripemd160-etm@openssh.com,hmac-sha1-96-etm@openssh.com,umac-64-etm@openssh.com,umac-128-etm@openssh.com" \
        "LoginGraceTime $SSH_LOGIN_GRACE_TIME" "LogLevel VERBOSE" "MaxSessions $SSH_MAX_SESSIONS" \
        "MaxStartups $SSH_MAX_STARTUPS" "PermitUserEnvironment no"
    [[ "$SSH_DISABLE_FORWARDING" == yes ]] && echo "DisableForwarding yes"
    return 0
}

g1_test_reload() {
    local before=$G1_SNAP
    sshd -t || { err "sshd -t fails with the new configuration"; return 1; }
    act_reload_later ssh.service || return 1
    systemctl try-reload-or-restart ssh.service || return 1
    g1_cases >/dev/null
    if [[ "$(g1_strip_root <<<"$before")" != "$(g1_strip_root <<<"$G1_SNAP")" ]]; then
        err "no-harm: forcecommand/allowusers changed for a SSH_VERIFY_CASES user"; return 1
    fi
    warn "G1: open a NEW ssh session and run 'sudo true' before closing this one"
}

g1_strip_root() { sed -E 's/permitrootlogin=[^ ]+ //; s/passwordauthentication=[^ ]+ //'; }
