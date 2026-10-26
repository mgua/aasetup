# shellcheck shell=bash
# V8 - AIDE installed, daily check enabled, profile excludes, baseline (runbook V8;
# script section 19, lines 558-588; excludes from server A, 2026-10-15/20).
#
# The baseline reads the whole disk (~25 min on server A at idle I/O): it is never part
# of a normal run. Without a baseline the step only WARNs; `-a -b` starts it in the
# background (systemd-run, nice 19, idle I/O class). AIDE's report mail is out of
# scope (root mail is not delivered yet; server A reads /var/log/aide/aide.log).
# Excludes: if an exclude file that is not ours exists (servers A/B have
# 99_vf_plesk_excludes), differences from the profile list are reported, never
# rewritten. Our own file is written only when no exclude file exists at all.

V8_DB_GLOB="/var/lib/aide/aide.db /var/lib/aide/aide.db.gz"

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
v8_meta() { STEP_TITLE="AIDE (install, daily check, excludes)"; STEP_IDS="U22-IC-01..03"; }

v8_check() {
    if ! pkg_installed aide || ! pkg_installed aide-common; then
        item_fix "install aide + aide-common (--no-install-recommends: no MTA pulled in)" \
            act_apt_install --no-install-recommends aide aide-common
        v8_check_excludes
        item_fix "enable the daily AIDE check timer (after the install)" v8_enable_timer
        [[ "$AIDE_BASELINE" == 1 ]] && item_fix "start the AIDE baseline in the background" v8_baseline
        return 0
    fi
    item_ok "aide and aide-common installed"
    if aide --config-check --config /etc/aide/aide.conf >/dev/null 2>&1; then
        item_ok "aide --config-check passes"
    else
        item_warn "aide --config-check reports errors: run it by hand"
    fi
    v8_check_timer
    v8_check_excludes
    v8_check_baseline
    return 0
}

v8_timer_name() {
    local t
    for t in dailyaidecheck.timer aidecheck.timer; do unit_exists "$t" && { echo "$t"; return 0; }; done
    return 1
}

v8_check_timer() {
    local t st
    t=$(v8_timer_name) || { item_warn "no AIDE timer unit (dailyaidecheck/aidecheck) found"; return 0; }
    st=$(unit_enabled "$t")
    if [[ "$st" == enabled ]]; then item_ok "$t enabled"
    else item_fix "$t is $st: enable it" act_unit_set "$t" enabled; fi
}

v8_enable_timer() {
    local t
    t=$(v8_timer_name) || { err "no AIDE timer unit after the install"; return 1; }
    [[ "$(unit_enabled "$t")" == enabled ]] || act_unit_set "$t" enabled
}

v8_check_excludes() {
    local f rules p missing=() others
    [[ -n "${AIDE_EXCLUDES// }" ]] || { item_na "this profile defines no AIDE excludes"; return 0; }
    f="/etc/aide/aide.conf.d/$AIDE_EXCLUDE_FILE"
    rules=$(aide_negative_rules /etc/aide/aide.conf /etc/aide/aide.conf.d/*)
    for p in $AIDE_EXCLUDES; do aide_excluded "$p" "$rules" || missing+=("$p"); done
    if (( ${#missing[@]} == 0 )); then
        item_ok "all $(wc -w <<<"$AIDE_EXCLUDES") profile excludes are covered"
        return 0
    fi
    # Hand-made VF exclude files (*vf*, e.g. server A's 99_vf_plesk_excludes) that are
    # not ours are reported, never rewritten. Ubuntu's stock rule files don't count.
    others=$(for x in /etc/aide/aide.conf.d/*vf*; do
        [[ -f "$x" ]] && ! ledger_owns file "$x" && printf '%s ' "$x"; done)
    if [[ -n "$others" ]]; then
        item_warn "exclude file(s) not ours ($others) do not cover: ${missing[*]} - compare with the profile, edit by hand"
    else
        item_fix "no exclude file covers: ${missing[*]} - write $f" v8_write_excludes "$f"
    fi
}

v8_write_excludes() {
    local f=$1 p content="# VF G-0312 / U22-IC - profile '$PROFILE' excludes - aasetup_harden.sh (vf-harden V8)"$'\n'
    for p in $AIDE_EXCLUDES; do content+="!$p"$'\n'; done
    act_write_file "$f" 0644 "$content"
}

v8_check_baseline() {
    local db
    for db in $V8_DB_GLOB; do
        [[ -s "$db" ]] && { item_ok "baseline $db ($(date -r "$db" '+%F'))"; return 0; }
    done
    if [[ -n "$(systemctl list-units --no-legend --state=active 'vf-aideinit*' 2>/dev/null)" ]]; then
        item_ok "baseline being built (vf-aideinit unit running)"
    elif [[ "$AIDE_BASELINE" == 1 ]]; then
        item_fix "no AIDE baseline: start it in the background (idle I/O)" v8_baseline
    else
        item_warn "no AIDE baseline yet: run '-a -o V8 -b' off-hours"
    fi
}

v8_baseline() {
    manifest_add note "AIDE baseline started; rollback does not delete the database" || return 1
    systemd-run --unit="vf-aideinit-${RUN_ID//[^A-Za-z0-9]/-}" --nice=19 -p IOSchedulingClass=idle \
        /usr/sbin/aideinit -y -f && ok "AIDE baseline started (journalctl -u 'vf-aideinit*')"
}
