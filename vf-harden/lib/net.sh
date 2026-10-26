# shellcheck shell=bash
# vf-harden/lib/net.sh - addresses, NICs and the "role" of a server (pure helpers,
# overridable sysfs root for tests).

NET_SYSFS="${NET_SYSFS:-/sys/class/net}"

ip_to_int() {                   # dotted quad -> integer; fails on anything else
    local IFS=. a b c d
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -r a b c d <<<"$1"
    (( a < 256 && b < 256 && c < 256 && d < 256 )) || return 1
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ip() { local n=$1; echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"; }

ip_in_cidr() {                  # ip_in_cidr IP CIDR|IP
    local net bits=32 i n mask
    i=$(ip_to_int "$1") || return 1
    net=${2%/*}; [[ "$2" == */* ]] && bits=${2#*/}
    n=$(ip_to_int "$net") || return 1
    (( bits >= 0 && bits <= 32 )) || return 1
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (i & mask) == (n & mask) ))
}

ip_in_any() {                   # ip_in_any IP "CIDR CIDR ..."
    local c
    for c in $2; do ip_in_cidr "$1" "${c//,/}" && return 0; done
    return 1
}

cidr_test_host() {              # an address inside CIDR to ask sshd about (network + 1)
    local net=${1%/*} bits=32 n
    [[ "$1" == */* ]] && bits=${1#*/}
    n=$(ip_to_int "$net") || return 1
    (( bits >= 31 )) && { echo "$net"; return 0; }
    int_to_ip $(( n + 1 ))
}

# Physical NICs = interfaces backed by a device (VMware ens192, eth0, ...).
nic_list() {
    local d n
    for d in "$NET_SYSFS"/*; do
        n=${d##*/}
        [[ "$n" == lo || ! -e "$d/device" ]] && continue
        printf '%s\n' "$n"
    done
}

# Prints why the role-dependent keys (forwarding, rp_filter=1, accept_ra=0) must
# not be applied here; prints nothing when they are safe (runbook G7 table).
net_role_blockers() {
    local d n virt=() nics
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 0 ]] || echo "ip_forward is not 0 (router, Docker, VPN, k8s)"
    nics=$(nic_list | grep -c . || true)
    (( nics <= 1 )) || echo "$nics physical NICs (multi-homed: rp_filter=1 can drop traffic)"
    for d in "$NET_SYSFS"/*; do
        n=${d##*/}
        [[ "$n" =~ ^(docker|br-|veth|tun|tap|wg|virbr|vnet|lxc|lxd|cni|flannel|cali) ]] && virt+=("$n")
    done
    (( ${#virt[@]} == 0 )) || echo "virtual interfaces present: ${virt[*]}"
}

# accept_ra=0 is safe only when RAs are handled in userspace (networkd) or IPv6 is static.
net_ra_blocker() {
    if grep -rqsE '^[[:space:]]*renderer:[[:space:]]*NetworkManager' /etc/netplan; then
        echo "netplan renderer is NetworkManager (accept_ra=0 can lose SLAAC IPv6)"
    elif [[ -f /etc/network/interfaces ]] && grep -qsE '^[[:space:]]*iface .* inet6 auto' /etc/network/interfaces; then
        echo "ifupdown with IPv6 SLAAC"
    fi
}
