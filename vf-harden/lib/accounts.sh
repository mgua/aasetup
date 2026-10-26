# shellcheck shell=bash
# vf-harden/lib/accounts.sh - accounts and password ageing (pure where possible).
#
# /etc/shadow fields: 3 lastchg (days since 1970; 0 = must change; empty = no ageing)
# 4 min, 5 max, 6 warn, 7 inactive (empty = never). chage -1 means "empty".

SHADOW_FILE="${SHADOW_FILE:-/etc/shadow}"
PASSWD_FILE="${PASSWD_FILE:-/etc/passwd}"

today_days() { echo $(( $(date +%s) / 86400 )); }

# r1_eval TODAY LASTCHG MIN MAX WARN INACT  WANT_MAX WANT_MIN WANT_WARN WANT_INACT EXEMPT
# Prints "ok", or "fix" plus "reset" when the last change must move to today first
# (the template's firstboot trick: a password older than the new max would expire
# - or, with INACTIVE, lock - the moment the max is set).
r1_eval() {
    local today=$1 last=$2 min=$3 max=$4 warn=$5 ina=$6 wmax=$7 wmin=$8 wwarn=$9 wina=${10} exempt=${11} bad=0
    if [[ "$exempt" == yes ]]; then
        [[ -z "$max" || "$max" -ge 99999 ]] 2>/dev/null || bad=1
        [[ -z "$ina" ]] || bad=1
        (( bad )) && echo fix || echo ok
        return 0
    fi
    [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 && max <= wmax )) || bad=1
    [[ "$min" =~ ^[0-9]+$ ]] && (( min >= wmin )) || bad=1
    [[ "$warn" =~ ^[0-9]+$ ]] && (( warn >= wwarn )) || bad=1
    if [[ "$wina" == -1 ]]; then [[ -z "$ina" || "$ina" == -1 ]] || bad=1
    else [[ "$ina" =~ ^[0-9]+$ ]] && (( ina > 0 && ina <= wina )) || bad=1; fi
    (( bad )) || { echo ok; return 0; }
    if [[ "$last" =~ ^[0-9]+$ ]] && (( last > 0 && today - last >= wmax )); then echo "fix reset"; else echo fix; fi
}

# people_auto : persons with a password hash, by the profile's rules (see R1).
# Excludes: UID < UID_MIN, nobody, nologin/false shells, homes outside HOME_SCOPE,
# SITE_USER_GROUP members, SITE_USER_REGEX names, R1_EXCLUDE.
people_auto() {
    local min site
    min=$(awk '$1 == "UID_MIN" { print $2 }' /etc/login.defs 2>/dev/null); min=${min:-1000}
    site=$( [[ -n "$SITE_USER_GROUP" ]] && getent group "$SITE_USER_GROUP" | cut -d: -f4 )
    awk -F: 'NR == FNR { if ($2 ~ /^\$/) h[$1] = 1; next }
             ($1 in h) { print $1, $3, $6, $7 }' "$SHADOW_FILE" "$PASSWD_FILE" |
    while read -r u uid home shell; do
        (( uid >= min && uid != 65534 )) || continue
        [[ "$shell" =~ (nologin|false)$ ]] && continue
        [[ "$home" == "${HOME_SCOPE%/}/"* ]] || continue
        [[ ",$site," == *",$u,"* ]] && continue
        [[ -n "$SITE_USER_REGEX" && "$u" =~ $SITE_USER_REGEX ]] && continue
        # shellcheck disable=SC2086  # space-separated profile list, split into words on purpose
        in_list "$u" $R1_EXCLUDE && continue
        printf '%s\n' "$u"
    done
}

people_list() {
    # shellcheck disable=SC2086  # space-separated profile list, split into words on purpose
    if [[ "$PEOPLE_ACCOUNTS" == auto ]]; then people_auto; else printf '%s\n' $PEOPLE_ACCOUNTS; fi
}

shadow_fields() { awk -F: -v u="$1" '$1 == u { print $3 ":" $4 ":" $5 ":" $6 ":" $7; f = 1 } END { exit !f }' "$SHADOW_FILE"; }

# grub_hash_ok HASH : the shape grub-mkpasswd-pbkdf2 prints
grub_hash_ok() { [[ "$1" =~ ^grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F]+\.[0-9A-F]+$ ]]; }
