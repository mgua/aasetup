# shellcheck shell=bash
# R3 - auditd (runbook R3; script section 20, lines 591-697).
#   install auditd; auditd.conf as the profile says (Plesk = server B since 2026-10-22:
#     rotate x5 x32 MB, space_left syslog, admin_space_left/disk_full SUSPEND, disk_error
#     syslog - DR-03 exception: never stop a web server for its audit log);
#   rules: data/audit-50-vf.rules.in (+ privileged, generated on THIS host) in
#     /etc/audit/rules.d, loaded with augenrules;
#   immutability (-e 2, AR-20) only with -E AND after AUDIT_OBSERVE_DAYS of running
#     the rules. When rules are locked (enabled=2), loading needs a REBOOT: reported.
# auditd re-reads auditd.conf on SIGHUP (systemd refuses a manual restart of it).

R3_RULES=/etc/audit/rules.d/50-vf.rules
R3_PRIV=/etc/audit/rules.d/50-vf-privileged.rules
R3_FINAL=/etc/audit/rules.d/99-finalize.rules
R3_CONF=/etc/audit/auditd.conf
R3_KEYS="scope user_emulation time-change system-locale access identity perm_mod mounts session logins delete MAC-policy perm_chng usermod kernel_modules privileged"

# shellcheck disable=SC2034  # STEP_TITLE/STEP_IDS are read by lib/main.sh
r3_meta() { STEP_TITLE="auditd"; STEP_IDS="U22-AS-*, AR-01..20, AF-01..10, DR-01..03"; }

r3_conf_want() {
    printf '%s\n' "max_log_file=$AUDIT_MAX_LOG_MB" "max_log_file_action=$AUDIT_MAX_LOG_ACTION" "num_logs=$AUDIT_NUM_LOGS" \
        "space_left_action=$AUDIT_SPACE_LEFT_ACTION" "admin_space_left_action=$AUDIT_ADMIN_SPACE_LEFT_ACTION" \
        "disk_full_action=$AUDIT_DISK_FULL_ACTION" "disk_error_action=$AUDIT_DISK_ERROR_ACTION" "log_group=root"
}

r3_enabled() { auditctl -s 2>/dev/null | awk '$1 == "enabled" { print $2 }'; }

r3_check() {
    local en
    [[ "$ENABLE_AUDITD" == yes ]] || { item_na "ENABLE_AUDITD=no in the profile"; return 0; }
    if ! pkg_installed auditd; then
        item_fix "install auditd" act_apt_install --no-install-recommends auditd
        item_fix "auditd.conf, rules, then start auditd" r3_after_install
        return 0
    fi
    # shellcheck disable=SC2015  # B is an item_*/ok helper that always returns 0
    [[ "$(unit_active auditd.service)" == active ]] && item_ok "auditd running" || item_fix "auditd not running: enable --now" act_unit_set auditd.service enabled
    r3_check_conf
    en=$(r3_enabled)
    r3_check_rules "$en"
    r3_check_immutable "$en"
    r3_check_files
    item_info "audit log: $(du -sh /var/log/audit 2>/dev/null | cut -f1), on $(findmnt -no TARGET --target /var/log/audit) ($(df -h --output=avail /var/log/audit | tail -1 | tr -d ' ') free)"
    return 0
}

r3_check_conf() {
    local kv k want have bad=()
    while IFS= read -r kv; do
        k=${kv%%=*}; want=${kv#*=}
        have=$(awk -F= -v k="$k" '{ gsub(/[ \t]/, "", $1) } $1 == k { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v) } END { print v }' "$R3_CONF" 2>/dev/null)
        [[ "${have,,}" == "${want,,}" ]] && item_ok "auditd.conf $k = $have" || bad+=("$k=$want")
    done < <(r3_conf_want)
    (( ${#bad[@]} )) && item_fix "auditd.conf: ${bad[*]} (original backed up), then SIGHUP" r3_write_conf "${bad[@]}"
    return 0
}

r3_write_conf() {               # KEY=VALUE... : edit the active lines (or append), then SIGHUP
    local kv k v expr=""
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        if grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$R3_CONF"; then expr+="s/^[[:space:]]*${k}[[:space:]]*=.*/${k} = ${v}/;"
        else expr+="\$a ${k} = ${v}"$'\n'; fi
    done
    manifest_add hup auditd || return 1
    act_sed_file "$R3_CONF" "$expr" && pkill -HUP -x auditd
}

r3_check_rules() {              # ENABLED
    local disk loaded k miss_disk=() miss_live=()
    disk=$(cat /etc/audit/rules.d/*.rules 2>/dev/null)
    loaded=$(auditctl -l 2>/dev/null)
    for k in $R3_KEYS; do
        # shellcheck disable=SC2086  # space-separated profile list, split into words on purpose
        in_list "$k" $AUDIT_SKIP_RULES && continue
        grep -qE -- "-k ${k}([[:space:]]|$)|key=${k}([[:space:]]|$)" <<<"$disk" || miss_disk+=("$k")
        grep -qE -- "-k ${k}([[:space:]]|$)|key=${k}([[:space:]]|$)" <<<"$loaded" || miss_live+=("$k")
    done
    if (( ${#miss_disk[@]} )); then
        if [[ -e "$R3_RULES" ]] && ! ledger_owns file "$R3_RULES"; then
            item_block "$R3_RULES exists (not ours) without keys ${miss_disk[*]}: fix by hand"
        else
            item_fix "rules missing on disk: ${miss_disk[*]} - write $R3_RULES + generated privileged rules, load" r3_write_rules
        fi
    elif (( ${#miss_live[@]} )); then
        if [[ "$1" == 2 ]]; then item_warn "rules on disk are not loaded (${miss_live[*]}) and the set is LOCKED (-e 2): they load at the next REBOOT"
        else item_fix "rules on disk not loaded (${miss_live[*]}): augenrules --load" r3_load; fi
    else
        item_ok "rules for $(wc -w <<<"$R3_KEYS") keys on disk and loaded ($(grep -c . <<<"$loaded") rules)"
    fi
}

r3_check_immutable() {          # ENABLED
    local age
    if [[ "$1" == 2 ]]; then
        item_info "rules are IMMUTABLE (-e 2, enabled=2): any rule change needs a reboot (AR-20)"; return 0
    fi
    [[ "$AUDIT_IMMUTABLE" == yes || "$AUDIT_MAKE_IMMUTABLE" == 1 ]] || { item_info "rules not immutable (AR-20: only with -E, after the observation period)"; return 0; }
    [[ "$AUDIT_MAKE_IMMUTABLE" == 1 ]] || { item_info "AUDIT_IMMUTABLE=yes: add -E to lock the rules (needs a reboot)"; return 0; }
    age=$(( ( $(date +%s) - $(stat -c %Y "$R3_RULES" 2>/dev/null || date +%s) ) / 86400 ))
    if (( age < AUDIT_OBSERVE_DAYS )); then
        item_block "-E: the rules are only $age day(s) old; observe $AUDIT_OBSERVE_DAYS days first (aureport -k --summary)"
    else
        item_fix "write $R3_FINAL (-e 2): rules locked from the next reboot" act_write_file "$R3_FINAL" 0640 $'## U22-AR-20 - aasetup_harden.sh (vf-harden R3)\n-e 2\n'
    fi
}

r3_check_files() {              # AF-01..10
    local f t
    perm_item "$R3_CONF" 0640 root root
    for f in /etc/audit/rules.d/*.rules; do [[ -e "$f" ]] && perm_item "$f" 0640 root root; done
    perm_item /var/log/audit 0750 root "root adm"
    for t in auditctl aureport ausearch autrace auditd augenrules; do
        f=$(readlink -e "/usr/sbin/$t" 2>/dev/null) && perm_item "$f" 0755 root root
    done
    return 0
}

r3_rules_text() {
    local min; min=$(login_defs_get UID_MIN) || min=1000
    sed "s/@UID_MIN@/$min/g" "$VF_DIR/data/audit-50-vf.rules.in" | while IFS= read -r l; do
        [[ "$l" =~ path=([^ ]+) && ! -e "${BASH_REMATCH[1]}" ]] && continue
        printf '%s\n' "$l"
    done
    [[ -e "$SUDO_LOGFILE" ]] && printf '%s\n' "## U22-AR-03 sudo_log_file" "-w $SUDO_LOGFILE -p wa -k sudo_log_file"
    [[ -d /var/lib/wtmpdb ]] && printf '%s\n' "-w /var/lib/wtmpdb -p wa -k session"
    return 0
}

r3_priv_text() {                # AR-06: every SUID/SGID binary on filesystems that allow it, on THIS host
    local min mnt; min=$(login_defs_get UID_MIN) || min=1000
    echo "## U22-AR-06 privileged (generated $(date +%F) by vf-harden R3)"
    findmnt -rn -o TARGET,FSTYPE,OPTIONS | awk '$2 ~ /^(ext[234]|xfs|btrfs|zfs|f2fs)$/ && $3 !~ /(noexec|nosuid)/ { print $1 }' |
        while IFS= read -r mnt; do
            find "$mnt" -xdev -type f -perm /6000 2>/dev/null
        done | sort -u | sed "s|.*|-a always,exit -F path=& -F perm=x -F auid>=$min -F auid!=unset -k privileged|"
}

r3_write_rules() {
    act_write_file "$R3_RULES" 0640 "$(r3_rules_text)"$'\n' || return 1
    act_write_file "$R3_PRIV" 0640 "$(r3_priv_text)"$'\n' || return 1
    r3_load
}

r3_load() {
    [[ "$(r3_enabled)" == 2 ]] && { REBOOT_REQUIRED+=("R3 (rules locked)"); warn "rules are locked (-e 2): new rules load at the next reboot"; return 0; }
    augenrules --load
}

r3_after_install() {
    local kv want=()
    while IFS= read -r kv; do want+=("$kv"); done < <(r3_conf_want)
    r3_write_conf "${want[@]}" || return 1
    r3_write_rules || return 1
    systemctl enable --now auditd.service
}
