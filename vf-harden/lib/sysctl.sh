# shellcheck shell=bash
# vf-harden/lib/sysctl.sh - sysctl checks shared by yellow steps (G7).
#
# A key is compliant when its RUNNING value is right AND the value that wins at
# boot is right, whichever file sets it. Missing keys are collected per target file
# (SYSCTL_NEED) and written by one action. A wrong value set in a file that sorts
# AFTER our target would win anyway: that is a BLOCKER, to fix by hand.
#
# Per-NIC keys follow the kernel's own combination of all/<nic>:
#   or   effective = all || nic   (accept/secure/send_redirects with forwarding off, log_martians)
#   and  effective = all && nic   (accept_source_route)
#   max  effective = max(all,nic) (rp_filter)
#   own  effective = nic          (IPv6 accept_redirects, accept_ra)
# An existing NIC's boot value comes from an explicit <nic> line or, when the NIC
# appears after systemd-sysctl, from 'default'. A running value that is right plus
# a right 'default' (or explicit line) at boot = compliant (as on .71). Otherwise
# an explicit <nic> line is written.

SYSCTL_NEED=(); SYSCTL_NOW=()

# sysctl_target FILE : FILE, or a later-sorting name we own when FILE is somebody else's
sysctl_target() {
    local f=$1
    if [[ -e "$f" ]] && ! ledger_owns file "$f"; then f="$(dirname -- "$f")/68-vf-aasetup-${f##*/}"; fi
    printf '%s\n' "$f"
}

_sysctl_boot() { local v="" f=""; IFS=$'\t' read -r v f < <(sysctl_persisted "$1") || true; printf '%s\t%s\n' "$v" "$f"; }

sysctl_item() {                 # sysctl_item KEY WANT TARGET
    local k=$1 want=$2 target=$3 run per pfile
    run=$(sysctl -n "$k" 2>/dev/null) || { item_na "$k: not on this kernel"; return 0; }
    IFS=$'\t' read -r per pfile < <(_sysctl_boot "$k")
    if sysctl_value_ok "$k" "$per" "$want"; then
        if sysctl_value_ok "$k" "$run" "$want"; then item_ok "$k = $run (boot: ${pfile##*/})"
        else item_info "$k runs as $run (boot value is right)"; SYSCTL_NOW+=("$k=$want"); fi
    elif [[ -n "$pfile" && "${pfile##*/}" > "${target##*/}" ]]; then
        item_block "$k = $per is set in $pfile, which is read after ${target##*/}: fix that file by hand"
    else
        item_info "$k: boot '${per:-unset}'${pfile:+ (${pfile##*/})}, running $run, want $want"
        SYSCTL_NEED+=("$k=$want")
    fi
}

nic_item() {                    # nic_item FAMILY NIC KEY WANT SEMANTICS TARGET
    local fam=$1 nic=$2 key=$3 want=$4 sem=$5 target=$6 kn ka kd vn va eff pn pf pd
    kn="net.$fam.conf.$nic.$key"; ka="net.$fam.conf.all.$key"; kd="net.$fam.conf.default.$key"
    vn=$(sysctl -n "$kn" 2>/dev/null) || { item_na "$kn: not present"; return 0; }
    va=$(sysctl -n "$ka" 2>/dev/null || echo 0)
    case "$sem" in
        or)  eff=$(( va || vn )) ;;
        and) eff=$(( va && vn )) ;;
        max) eff=$(( va > vn ? va : vn )) ;;
        *)   eff=$vn ;;
    esac
    IFS=$'\t' read -r pn pf < <(_sysctl_boot "$kn")
    if [[ -n "$pf" && "$pn" != "$want" && "${pf##*/}" > "${target##*/}" ]]; then
        item_block "$kn = $pn is set in $pf, read after ${target##*/}: fix that file by hand"; return 0
    fi
    pd=$(_sysctl_boot "$kd" | cut -f1)
    if (( eff == want )) && [[ "$pn" == "$want" || ( -z "$pf" && "$pd" == "$want" ) ]]; then
        item_ok "$kn = $vn (all=$va, effective $eff; boot: ${pf:+${pf##*/}}${pf:-default=$pd})"
    else
        item_info "$kn = $vn (all=$va, effective $eff, boot '${pn:-default=${pd:-unset}}'): want an explicit $want"
        SYSCTL_NEED+=("$kn=$want")
    fi
}

# sysctl_flush TARGET LABEL : turn the collected keys into fix items, then reset
sysctl_flush() {
    local target=$1 label=$2
    if (( ${#SYSCTL_NEED[@]} )); then
        item_fix "$label: write ${#SYSCTL_NEED[@]} key(s) to $target and load it" act_sysctl_write "$target" "${SYSCTL_NEED[@]}"
    fi
    if (( ${#SYSCTL_NOW[@]} )); then
        item_fix "$label: set ${#SYSCTL_NOW[@]} running value(s) back to the boot value" act_sysctl_now "${SYSCTL_NOW[@]}"
    fi
    SYSCTL_NEED=(); SYSCTL_NOW=()
}

# act_sysctl_write FILE KEY=VALUE... : our file keeps its own earlier keys, new ones win
act_sysctl_write() {
    local f=$1 kv k content keys=() old=""; shift
    for kv in "$@"; do keys+=("${kv%%=*}"); done
    if [[ -e "$f" ]] && ledger_owns file "$f"; then
        old=$(grep -vE '^[[:space:]]*(#|$)' "$f" | while IFS= read -r l; do
            k=${l%%=*}; k=${k//[[:space:]]/}; in_list "$k" "${keys[@]}" || printf '%s\n' "$l"; done)
    fi
    content="# VF G-0312 - written by aasetup_harden.sh (vf-harden $CUR_STEP)"$'\n'
    [[ -n "$old" ]] && content+="$old"$'\n'
    for kv in "$@"; do content+="${kv%%=*} = ${kv#*=}"$'\n'; done
    act_sysctl_record "${keys[@]}" || return 1
    act_write_file "$f" 0644 "$content" && sysctl -q -p "$f"
}

act_sysctl_now() {
    local kv
    for kv in "$@"; do act_sysctl_record "${kv%%=*}" && sysctl -q -w "$kv" || return 1; done
}
