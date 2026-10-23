# shellcheck shell=bash
# G2 - sudo (runbook G2; script section 15, lines 457-477).
# Compliant = the Defaults sudo actually reads (sudoers + sudoers.d files without
# '.' or '~'): use_pty, logfile (PE-06), timestamp_timeout <= 15 (sudo's default is
# 15 when unset). Production additions: a logrotate rule for sudo.log WITH
# `su root syslog` (/var/log is root:syslog 0775; logrotate refuses without it),
# and sudoers.d files that are not 0440 are REPORTED (visudo -c complains), not changed.
# NOPASSWD rules are listed: PE-01 is Optional, automations keep them as an exception.

G2_DROPIN=/etc/sudoers.d/01_vf_hardening       # no '.' in the name: sudo skips such files
G2_ROTATE=/etc/logrotate.d/vf-sudo

g2_meta() { STEP_TITLE="sudo"; STEP_IDS="U22-PE-02,05,06,07 (PE-01 reported)"; }

g2_impl() { sudo -V 2>/dev/null | head -1; }

g2_check() {
    local d impl pty lf tt bad=()
    command -v sudo >/dev/null 2>&1 || { item_na "sudo not installed"; return 0; }
    impl=$(g2_impl)
    d=$(sudo_defaults $(sudoers_files))
    pty=$(sudo_default_last use_pty <<<"$d") || pty=""
    [[ "$pty" == on ]] && item_ok "Defaults use_pty" || bad+=("use_pty")
    if [[ "$impl" == sudo-rs* ]]; then
        item_warn "sudo-rs ($impl): no logfile support - PE-06 is an exception (logs in the journal)"
    else
        lf=$(sudo_default_last logfile <<<"$d") || lf=""
        [[ -n "$lf" ]] && item_ok "Defaults logfile=$lf" || bad+=("logfile")
    fi
    tt=$(sudo_default_last timestamp_timeout <<<"$d") || tt=15
    [[ "$tt" =~ ^[0-9]+$ ]] && (( tt <= SUDO_TIMESTAMP_TIMEOUT )) && item_ok "timestamp_timeout $tt" || bad+=("timestamp_timeout")
    g2_report
    g2_check_rotate "${lf:-$SUDO_LOGFILE}"
    (( ${#bad[@]} )) || return 0
    if [[ -e "$G2_DROPIN" ]] && ! ledger_owns file "$G2_DROPIN"; then
        item_block "$G2_DROPIN exists (not ours) but ${bad[*]} are not effective: fix by hand"
    else
        item_fix "${bad[*]}: write $G2_DROPIN (checked with visudo -cf first)" g2_write
    fi
}

g2_report() {
    local f m n
    for f in $(sudoers_files); do
        [[ "$f" == /etc/sudoers ]] && continue
        m=$(file_mode "$f")
        [[ "$m" == 440 ]] || item_warn "$f has mode $m, not 0440 (visudo -c complains; sudo still reads it): fix by hand"
    done
    n=$(grep -hE '^[^#]*NOPASSWD' $(sudoers_files) 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')
    [[ -z "$n" ]] || item_info "PE-01 exception (NOPASSWD, Optional): $n"
    grep -qhE '^[^#]*!authenticate' $(sudoers_files) 2>/dev/null && item_warn "PE-07: a rule uses !authenticate"
    return 0
}

g2_check_rotate() {
    local log=$1 rule
    rule=$(grep -lsF "$log" /etc/logrotate.d/* | head -1)
    if [[ -z "$rule" ]]; then
        if [[ -e "$G2_ROTATE" ]] && ! ledger_owns file "$G2_ROTATE"; then
            item_block "$G2_ROTATE exists (not ours) and does not rotate $log: fix by hand"
        else
            item_fix "no logrotate rule for $log: write $G2_ROTATE (with 'su root syslog')" \
                act_write_file "$G2_ROTATE" 0644 "$(g2_rotate_text "$log")"$'\n'
        fi
    elif grep -qE '^[[:space:]]*su[[:space:]]' "$rule" || grep -qE '^[[:space:]]*su[[:space:]]' /etc/logrotate.conf; then
        item_ok "$log rotated by $rule"
    else
        item_warn "$rule rotates $log without an 'su' line: logrotate refuses it while /var/log is group-writable"
    fi
}

g2_rotate_text() {
    printf '%s\n' "# VF G-0312 / U22-PE-06 - aasetup_harden.sh (vf-harden G2)" "$1 {" "    su root syslog" \
        "    weekly" "    rotate 12" "    compress" "    delaycompress" "    missingok" "    notifempty" \
        "    create 0600 root root" "}"
}

g2_write() {
    local tmp c="# VF G-0312 / U22-PE - aasetup_harden.sh (vf-harden G2)"$'\n'"Defaults use_pty"$'\n'
    [[ "$(g2_impl)" == sudo-rs* ]] || c+="Defaults logfile=\"$SUDO_LOGFILE\""$'\n'
    c+="Defaults timestamp_timeout=$SUDO_TIMESTAMP_TIMEOUT"$'\n'
    tmp=$(mktemp) || return 1
    printf '%s' "$c" > "$tmp"
    if ! visudo -cf "$tmp" >/dev/null; then err "visudo rejects the new Defaults - not installed"; rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    act_write_file "$G2_DROPIN" 0440 "$c" && visudo -c >/dev/null
}
