# shellcheck shell=bash
# G7 - network kernel parameters (runbook G7; script lines 157-185).
#   always safe  -> /etc/sysctl.d/60-vf-net.conf
#   role keys    -> /etc/sysctl.d/61-vf-net-role.conf, only when ip_forward is 0, one
#                   physical NIC, no docker/br-/tun/wg/... (runbook table); accept_ra=0
#                   also needs networkd/static IPv6
#   every NIC    -> /etc/sysctl.d/62-vf-net-nic.conf: explicit <nic> keys. `all`
#                   and `default` do not change an EXISTING interface, and the kernel
#                   ORs/maxes all+nic for redirects and rp_filter (.61 and .71:
#                   ens192 stayed at rp_filter=2 with all=1).
# .61 keeps these in 60-vf-net.conf/61-vf-net-role.conf, .71 in 60-vf-hardening.conf:
# both are read as the effective state (lib/sysctl.sh).

g7_meta() { STEP_TITLE="Network kernel parameters"; STEP_IDS="U22-NKP-01..26"; }

G7_SAFE_V4="net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.default.send_redirects=0
 net.ipv4.icmp_ignore_bogus_error_responses=1 net.ipv4.icmp_echo_ignore_broadcasts=1
 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.default.accept_redirects=0
 net.ipv4.conf.all.secure_redirects=0 net.ipv4.conf.default.secure_redirects=0
 net.ipv4.conf.all.accept_source_route=0 net.ipv4.conf.default.accept_source_route=0
 net.ipv4.conf.all.log_martians=1 net.ipv4.conf.default.log_martians=1 net.ipv4.tcp_syncookies=1"
G7_SAFE_V6="net.ipv6.conf.all.accept_redirects=0 net.ipv6.conf.default.accept_redirects=0
 net.ipv6.conf.all.accept_source_route=0 net.ipv6.conf.default.accept_source_route=0"
G7_ROLE="net.ipv4.ip_forward=0 net.ipv4.conf.all.forwarding=0 net.ipv4.conf.default.forwarding=0
 net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.default.rp_filter=1"
G7_ROLE_V6="net.ipv6.conf.all.forwarding=0 net.ipv6.conf.default.forwarding=0"
G7_RA="net.ipv6.conf.all.accept_ra=0 net.ipv6.conf.default.accept_ra=0"
#        family key                want semantics
G7_NIC="ipv4   rp_filter           1    max
        ipv4   accept_redirects    0    or
        ipv4   secure_redirects    0    or
        ipv4   send_redirects      0    or
        ipv4   accept_source_route 0    and
        ipv4   log_martians        1    or
        ipv6   accept_redirects    0    own"

g7_v6() { [[ -d /proc/sys/net/ipv6 ]]; }

g7_check() {
    local kv tgt role ra nic fam key want sem
    SYSCTL_NEED=(); SYSCTL_NOW=()
    tgt=$(sysctl_target /etc/sysctl.d/60-vf-net.conf)
    for kv in $G7_SAFE_V4 $(g7_v6 && echo "$G7_SAFE_V6"); do sysctl_item "${kv%%=*}" "${kv#*=}" "$tgt"; done
    sysctl_flush "$tgt" "always-safe keys"
    role=$(net_role_blockers); ra=$(net_ra_blocker)
    tgt=$(sysctl_target /etc/sysctl.d/61-vf-net-role.conf)
    for kv in $G7_ROLE $(g7_v6 && echo "$G7_ROLE_V6"); do sysctl_item "${kv%%=*}" "${kv#*=}" "$tgt"; done
    g7_role_gate "$tgt" "role keys" "$role"
    if g7_v6; then
        for kv in $G7_RA; do sysctl_item "${kv%%=*}" "${kv#*=}" "$tgt"; done
        g7_role_gate "$tgt" "accept_ra" "$role${ra:+; $ra}"
    fi
    tgt=$(sysctl_target /etc/sysctl.d/62-vf-net-nic.conf)
    for nic in $(nic_list); do
        while read -r fam key want sem; do
            [[ -n "$fam" ]] || continue
            [[ "$key" == rp_filter && -n "$role" ]] && { item_warn "$nic rp_filter not set: $role"; continue; }
            g7_nic_skip "$fam" "$nic" && continue
            nic_item "$fam" "$nic" "$key" "$want" "$sem" "$tgt"
        done <<<"$G7_NIC"
        [[ -z "$role" ]] && g7_v6 && ! g7_nic_skip ipv6 "$nic" && [[ -z "$ra" ]] && nic_item ipv6 "$nic" accept_ra 0 own "$tgt"
    done
    g7_role_gate "$tgt" "per-NIC keys" ""
    return 0
}

g7_nic_skip() {                 # IPv6 keys are moot on a NIC with IPv6 disabled
    [[ "$1" == ipv6 ]] || return 1
    [[ "$(sysctl -n "net.ipv6.conf.$2.disable_ipv6" 2>/dev/null)" == 1 ]] && { item_na "$2: IPv6 disabled"; return 0; }
    return 1
}

# g7_role_gate TARGET LABEL BLOCKERS : with blockers, missing keys are reported, not written
g7_role_gate() {
    if [[ -n "$3" ]] && (( ${#SYSCTL_NEED[@]} + ${#SYSCTL_NOW[@]} )); then
        item_warn "$2 not applied here: $3 (keys: ${SYSCTL_NEED[*]} ${SYSCTL_NOW[*]})"
        SYSCTL_NEED=(); SYSCTL_NOW=()
        return 0
    fi
    sysctl_flush "$1" "$2"
}
