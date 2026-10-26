# shellcheck shell=bash
# vf-harden/lib/rollback.sh - replay a run's manifest backwards.
#
# Rollback STATUS: written, UNTESTED (no throw-away VM yet). See README.md.
# Every handler first checks that the target is still exactly as this tool left
# it. If not, it keeps the target, warns, and the rollback reports PARTIAL (exit 4).

declare -A FILE_SHA_AFTER=()    # sha written by a 'file-sha' line (act_cmd_files), seen first in reverse
declare -A CHAGE_AFTER=()       # shadow fields right after a chage (R1), seen first in reverse

rb_file_created() {             # PATH SHA
    local p=$1 sha=${2:-${FILE_SHA_AFTER[$1]:-}}
    if [[ ! -e "$p" ]]; then log "$p already gone"; ledger_del file "$p"; return 0; fi
    if [[ -z "$sha" || "$(sha_of "$p")" != "$sha" ]]; then
        warn "$p was changed after this tool wrote it (or its result is unknown) - kept, remove it by hand if wanted"; return 1
    fi
    rm -f -- "$p" && ledger_del file "$p" && ok "removed $p"
}

rb_file_modified() {            # PATH BACKUP SHA
    local p=$1 b=$2 sha=${3:-${FILE_SHA_AFTER[$1]:-}}
    [[ -e "$b" ]] || { err "backup $b is missing - $p not restored"; return 1; }
    if [[ -e "$p" && ( -z "$sha" || "$(sha_of "$p")" != "$sha" ) ]]; then
        warn "$p was changed after this tool edited it - kept (original saved in $b)"; return 1
    fi
    cp -a -- "$b" "$p" || return 1
    ledger_owns file "$p" && ledger_set file "$p" "$(sha_of "$p")"
    ok "restored $p"
}

rb_perm() {                     # PATH OLDMODE OLDOWNER OLDGROUP NEWMODE NEWOWNER NEWGROUP
    local p=$1 om=$2 oo=$3 og=$4 nm=$5 no=$6 ng=$7
    [[ -e "$p" ]] || { warn "$p is gone - nothing to restore"; return 1; }
    if [[ "$(file_mode "$p")" != "$nm" || "$(file_owner "$p")" != "$no" || "$(file_group "$p")" != "$ng" ]]; then
        warn "$p mode/owner changed after this tool set them - kept"; return 1
    fi
    chown "$oo:$og" -- "$p" && chmod "$om" -- "$p" && ok "restored $p to $om $oo:$og"
}

rb_unit() {                     # UNIT OLDENABLED OLDACTIVE WANT
    local u=$1 oe=$2 oa=$3 rc=0
    [[ "$oe" != masked && "$(unit_enabled "$u")" == masked ]] && { systemctl unmask "$u" || rc=1; }
    case "$oe" in
        enabled)  systemctl enable "$u"  || rc=1 ;;
        disabled) systemctl disable "$u" || rc=1 ;;
        masked)   systemctl mask "$u"    || rc=1 ;;
        *)        log "$u: previous enable state '$oe' - left as is" ;;
    esac
    case "$oa" in
        active)   systemctl start "$u" || rc=1 ;;
        inactive) [[ "$(unit_active "$u")" == active ]] && { systemctl stop "$u" || rc=1; } ;;
    esac
    (( rc == 0 )) && ok "$u back to $oe/$oa"
    return $rc
}

# Restarts and reloads run once, AFTER every file of the rollback is back in place.
RB_DEFERRED=()
rb_deferred() {
    local d rc=0
    for d in "${RB_DEFERRED[@]}"; do
        case "${d%%:*}" in
            restart) systemctl restart "${d#*:}" && ok "restarted ${d#*:}" || rc=1 ;;
            remount) rb_remount "${d#*:}" || rc=1 ;;
            regen-grub) update-grub && chmod 0600 /boot/grub/grub.cfg && ok "grub.cfg regenerated" || rc=1 ;;
            hup)     pkill -HUP -x "${d#*:}" && ok "${d#*:} re-read its configuration (SIGHUP)" || rc=1 ;;
            reload)  if [[ "${d#*:}" == ssh.service ]] && ! sshd -t; then
                         err "sshd -t fails after the rollback - ssh NOT reloaded, fix from the console"; rc=1
                     else systemctl try-reload-or-restart "${d#*:}" && ok "reloaded ${d#*:}" || rc=1; fi ;;
        esac
    done
    RB_DEFERRED=()
    return $rc
}

# After fstab is restored: remount with the old options, and explicitly undo the
# no* flags that were not there before (a remount merges with the current flags).
rb_remount() {                  # "MOUNTPOINT:OLDOPTS"
    local mp=${1%%:*} old=${1#*:} o opts
    opts=$old
    for o in noexec:exec nosuid:suid nodev:dev; do
        [[ ",$old," == *",${o%%:*},"* ]] || opts+=",${o#*:}"
    done
    mount -o "remount,$opts" "$mp" && ok "remounted $mp ($opts)"
}

rb_chage() {                    # USER OLD3 OLD4 OLD5 OLD6 OLD7 (only if still what R1 set)
    local u=$1 now
    now=$(shadow_fields "$u") || { warn "$u is gone"; return 1; }
    if [[ "$now" != "${CHAGE_AFTER[$u]:-}" ]]; then
        warn "$u: password ageing changed since R1 (now $now) - kept"; return 1
    fi
    chage ${2:+-d "$2"} -m "${3:-0}" -M "${4:--1}" -W "${5:-0}" -I "${6:--1}" "$u" && ok "$u: ageing restored ($2:$3:$4:$5:$6)"
}

rb_pkg_removed() {              # "name=version ..." : reinstall (the version if still available)
    local p names=()
    for p in $1; do names+=("${p%%=*}"); done
    (( ${#names[@]} )) || return 0
    if apt-get install -y "${names[@]}"; then
        ok "reinstalled ${names[*]} (configs may differ from before: check them)"
    else
        err "could not reinstall ${names[*]}"; return 1
    fi
}

rb_entry() {                    # rb_entry TYPE FIELDS...
    local type=$1; shift
    local a=("$@") i
    for i in "${!a[@]}"; do [[ "${a[$i]}" == - ]] && a[i]=""; done
    case "$type" in
        file-created)  rb_file_created "${a[0]}" "${a[1]}" ;;
        file-modified) rb_file_modified "${a[0]}" "${a[1]}" "${a[2]}" ;;
        dir-created)
            if rmdir -- "${a[0]}" 2>/dev/null; then ok "removed empty dir ${a[0]}"
            elif [[ -d "${a[0]}" ]]; then warn "kept ${a[0]} (not empty)"; return 1; fi ;;
        perm)          rb_perm "${a[@]:0:7}" ;;
        unit)          rb_unit "${a[0]}" "${a[1]}" "${a[2]}" ;;
        sysctl)        [[ -z "${a[1]}" ]] || sysctl -q -w "${a[0]}=${a[1]}" ;;
        restart|reload|hup) in_list "$type:${a[0]}" "${RB_DEFERRED[@]}" || RB_DEFERRED+=("$type:${a[0]}") ;;
        regen-grub)    in_list "regen-grub:" "${RB_DEFERRED[@]}" || RB_DEFERRED+=("regen-grub:") ;;
        chage-after)   CHAGE_AFTER[${a[0]}]="${a[1]}:${a[2]}:${a[3]}:${a[4]}:${a[5]}" ;;
        chage)         rb_chage "${a[@]:0:6}" ;;
        usershell)     if [[ "$(getent passwd "${a[0]}" | cut -d: -f7)" != "${a[2]}" ]]; then
                           warn "${a[0]}: shell changed since - kept"; return 1
                       elif usermod -s "${a[1]}" "${a[0]}"; then
                           ok "${a[0]}: shell back to ${a[1]}"
                       else
                           warn "${a[0]}: usermod failed - shell not restored"; return 1
                       fi ;;
        userlock)      usermod -U "${a[0]}" >/dev/null && ok "${a[0]} unlocked" ;;
        pkg-removed)   rb_pkg_removed "${a[0]}" ;;
        pkg-installed)
            # shellcheck disable=SC2086  # the field is a space-separated package list
            [[ -z "${a[0]}" ]] || apt_purge_gated ${a[0]} ;;
        note)          log "note: ${a[*]}" ;;
        file-sha)      FILE_SHA_AFTER[${a[0]}]=${a[1]} ;;
        remount)       RB_DEFERRED+=("remount:${a[0]}:${a[1]}") ;;
        group-member-added)
                       gpasswd -d "${a[0]}" "${a[1]}" >/dev/null && ok "${a[0]} removed from ${a[1]}" ;;
        group-created)
            if [[ -n "$(getent group "${a[0]}" | cut -d: -f4)" ]]; then
                warn "group ${a[0]} has members added since - kept"; return 1
            fi
            groupdel "${a[0]}" && ok "removed group ${a[0]}" ;;
        *)             warn "unknown manifest entry '$type' - skipped"; return 1 ;;
    esac
}

# state_rollback RUNDIR [STEP] : undo a whole run (newest change first), or only
# one step of it (used by --apply when a step fails its verification).
state_rollback() {
    local rd=$1 only=${2:-} partial=0 step type rest done_steps line
    FILE_SHA_AFTER=(); CHAGE_AFTER=(); RB_DEFERRED=()
    [[ -s "$rd/manifest.tsv" ]] || { log "nothing was changed in this run - nothing to undo"; return 0; }
    done_steps=$(awk -F'\t' '$2 == "rolled-back" { print $1 }' "$rd/steps.tsv" 2>/dev/null)
    while IFS= read -r line; do
        step=${line%%$'\t'*}; rest=${line#*$'\t'}; type=${rest%%$'\t'*}; rest=${rest#*$'\t'}
        [[ "$rest" == "$type" ]] && rest=""
        if [[ -n "$only" ]]; then [[ "$step" == "$only" ]] || continue
        elif grep -qx -- "$step" <<<"$done_steps"; then continue
        fi
        local fields=()
        IFS=$'\t' read -r -a fields <<<"$rest"
        # shellcheck disable=SC2034  # read by another file of the tool
        CUR_STEP=$step
        rb_entry "$type" "${fields[@]}" || partial=1
    done < <(tac "$rd/manifest.tsv")
    rb_deferred || partial=1
    if [[ -n "$only" ]]; then
        step_record "$only" rolled-back
        ledger_del step "$only"
    else
        awk -F'\t' '{ print $1 }' "$rd/manifest.tsv" | sort -u | while IFS= read -r step; do
            awk -F'\t' -v s="$step" -v r="${rd##*/}" '$1 == "step" && $2 == s && $5 == r { f = 1 } END { exit !f }' "$(LEDGER)" 2>/dev/null \
                && ledger_del step "$step"
        done
    fi
    return $partial
}
