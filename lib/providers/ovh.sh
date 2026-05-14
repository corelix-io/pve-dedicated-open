# OVH provider: rescue checks, DNS defaults, interface prediction,
# network rendering for OVH dedicated/SoYouStart/Kimsufi servers.
# shellcheck shell=bash
#
# OVH-specific facts informing this module:
#   * Rescue is a Debian-based image; SSH is via password or key emailed by OVH.
#   * NIC name in rescue (eth0) typically differs from the installed name
#     (eno1, enp*, ens*); MAC-based identification is the most reliable.
#   * Classic ranges use a /24-style gateway in the same subnet.
#   * High Grade / Scale / Advance ranges use /32 host IP with a fixed
#     gateway 100.64.0.1 reachable on-link.
#   * IPv6 gateway is the network's "::FF:FF:FF:FF:FF" form, NOT fe80::1.
#   * Additional IPs on classic ranges require a Virtual MAC (vMAC)
#     configured in the OVH Control Panel; vRack IP blocks do NOT.
#   * vRack uses a second NIC and is private between OVH services.

# --- New OVH-specific config knobs (read by config.sh CLI parsing) ---------
declare -g PVE_OVH_GATEWAY_MODEL="${PVE_OVH_GATEWAY_MODEL:-auto}"   # auto | classic | scale
declare -g PVE_OVH_VRACK_INTERFACE="${PVE_OVH_VRACK_INTERFACE:-}"   # second NIC name for vRack
declare -g PVE_OVH_VRACK_IP_CIDR="${PVE_OVH_VRACK_IP_CIDR:-}"       # static IP/CIDR on vRack bridge
declare -g PVE_OVH_ADDITIONAL_IPS="${PVE_OVH_ADDITIONAL_IPS:-}"     # space/comma separated /32s for routed mode

# Constants
readonly OVH_SCALE_GATEWAY="100.64.0.1"
readonly OVH_DEFAULT_DNS="213.186.33.99 1.1.1.1"

ovh_check_rescue() {
    if [[ -f /etc/ovhrescue ]] || [[ -f /etc/ovh-rescue ]]; then
        ui_success "OVH Rescue System detected"
        return 0
    fi
    if [[ -f /etc/motd ]] && grep -qi 'ovh\|kimsufi\|soyoustart' /etc/motd 2>/dev/null; then
        ui_success "OVH Rescue System detected (motd)"
        return 0
    fi
    if grep -qi 'ovh' /etc/resolv.conf 2>/dev/null; then
        ui_success "OVH Rescue System detected (DNS)"
        return 0
    fi

    local hn
    hn="$(hostname 2>/dev/null || true)"
    if [[ "$hn" == *"rescue"* ]] || [[ "$hn" == *"ovh"* ]]; then
        ui_success "OVH Rescue System detected (hostname)"
        return 0
    fi

    local root_fs
    root_fs="$(df / 2>/dev/null | tail -1 | awk '{print $1}')"
    if [[ "$root_fs" == "tmpfs" ]] || [[ "$root_fs" == "rootfs" ]] || [[ "$root_fs" == *"nfs"* ]]; then
        ui_success "RAM/NFS-based root filesystem detected (likely OVH rescue)"
        return 0
    fi

    log_warn "Not running in OVH Rescue System. Proceed with caution."
    ui_warn "OVH rescue not detected -- ensure you booted via netboot 'rescue' option"
    return 0
}

ovh_default_dns() {
    echo "$OVH_DEFAULT_DNS"
}

# OVH does not provide predict-check. Use udev's persistent name path which
# matches what the installed kernel will assign on first boot.
ovh_predict_iface() {
    local active predicted=""
    active="$(net_get_active_interface)"

    if [[ -e "/sys/class/net/${active}" ]]; then
        predicted="$(udevadm info "/sys/class/net/${active}" 2>/dev/null \
            | grep 'ID_NET_NAME_PATH=' | cut -d'=' -f2)"
    fi
    if [[ -z "$predicted" ]] && [[ -e "/sys/class/net/${active}" ]]; then
        predicted="$(udevadm info "/sys/class/net/${active}" 2>/dev/null \
            | grep 'ID_NET_NAME_SLOT=' | cut -d'=' -f2)"
    fi
    if [[ -z "$predicted" ]]; then
        predicted="$active"
    fi
    echo "$predicted"
}

# Classify the OVH gateway model from detected facts.
ovh_detect_gateway_model() {
    if [[ "$PVE_OVH_GATEWAY_MODEL" != "auto" ]]; then
        echo "$PVE_OVH_GATEWAY_MODEL"
        return 0
    fi

    if [[ "$PVE_MAIN_IPV4_GW" == "$OVH_SCALE_GATEWAY" ]]; then
        echo "scale"
        return 0
    fi
    # /32 main IP with any non-100.64.0.1 gateway is rare; assume classic.
    echo "classic"
}

ovh_post_network_detect() {
    local model
    model="$(ovh_detect_gateway_model)"
    PVE_OVH_GATEWAY_MODEL="$model"
    log_debug "OVH gateway model: ${model}"
}

# /etc/network/interfaces renderer dispatches by network mode.
ovh_render_interfaces() {
    case "${PVE_NETWORK_MODE:-nat}" in
        nat)     ovh_render_interfaces_nat ;;
        routed)  ovh_render_interfaces_routed ;;
        bridged) ovh_render_interfaces_bridged ;;
        *)       die "Unknown PVE_NETWORK_MODE: ${PVE_NETWORK_MODE}" ;;
    esac
}

# NAT (default): public IP on vmbr0 bridged to physical NIC, vmbr1 NAT
# bridge with MASQUERADE -- same shape as Hetzner NAT mode but with
# OVH gateway semantics.
ovh_render_interfaces_nat() {
    local iface="${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}"
    local model="${PVE_OVH_GATEWAY_MODEL:-classic}"

    cat <<IFACES
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

iface ${iface} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4_CIDR}
    gateway ${PVE_MAIN_IPV4_GW}
    bridge-ports ${iface}
    bridge-stp off
    bridge-fd 0
IFACES

    # Scale/HG/Advance ranges: /32 host with on-link gateway 100.64.0.1.
    if [[ "$model" == "scale" ]]; then
        cat <<SCALE
    # OVH High Grade/Scale/Advance: gateway is on-link via /32
    pointopoint ${PVE_MAIN_IPV4_GW}
SCALE
    fi

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        local ipv6_gw
        ipv6_gw="$(ovh_compute_ipv6_gateway "$PVE_IPV6_CIDR")"
        cat <<IPV6

iface vmbr0 inet6 static
    address ${PVE_IPV6_CIDR}
    post-up /sbin/ip -f inet6 route add ${ipv6_gw} dev vmbr0 || true
    post-up /sbin/ip -f inet6 route add default via ${ipv6_gw} || true
    pre-down /sbin/ip -f inet6 route del default via ${ipv6_gw} || true
    pre-down /sbin/ip -f inet6 route del ${ipv6_gw} dev vmbr0 || true
IPV6
    fi

    if [[ -n "$PVE_PRIVATE_IP_CIDR" ]]; then
        cat <<VMBR1

auto vmbr1
iface vmbr1 inet static
    address ${PVE_PRIVATE_IP_CIDR}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '${PVE_PRIVATE_SUBNET}' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${PVE_PRIVATE_SUBNET}' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
VMBR1
    fi

    ovh_render_vrack_block
}

# Routed mode: physical NIC keeps the main IP as /32; vmbr0 has no
# bridge-ports and serves as gateway for additional /32 IPs added by route.
ovh_render_interfaces_routed() {
    local iface="${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}"

    cat <<IFACES
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

# Physical interface holds the public IP as /32 (OVH routed mode).
auto ${iface}
iface ${iface} inet static
    address ${PVE_MAIN_IPV4%/*}/32
    gateway ${PVE_MAIN_IPV4_GW}
IFACES

    if [[ "$(ovh_detect_gateway_model)" == "scale" ]]; then
        echo "    pointopoint ${PVE_MAIN_IPV4_GW}"
    fi

    cat <<BRIDGE

# vmbr0 is a bridge with no ports; OVH additional IPs are routed onto it.
auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4%/*}/32
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE

    if [[ -n "$PVE_OVH_ADDITIONAL_IPS" ]]; then
        local ip
        for ip in ${PVE_OVH_ADDITIONAL_IPS//,/ }; do
            [[ -z "$ip" ]] && continue
            local cidr="${ip}"
            [[ "$ip" != */* ]] && cidr="${ip}/32"
            echo "    up   ip route add ${cidr} dev vmbr0 || true"
            echo "    down ip route del ${cidr} dev vmbr0 || true"
        done
    fi

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        local ipv6_gw
        ipv6_gw="$(ovh_compute_ipv6_gateway "$PVE_IPV6_CIDR")"
        cat <<IPV6

iface vmbr0 inet6 static
    address ${PVE_IPV6_CIDR}
    post-up /sbin/ip -f inet6 route add ${ipv6_gw} dev vmbr0 || true
    post-up /sbin/ip -f inet6 route add default via ${ipv6_gw} || true
    pre-down /sbin/ip -f inet6 route del default via ${ipv6_gw} || true
    pre-down /sbin/ip -f inet6 route del ${ipv6_gw} dev vmbr0 || true
IPV6
    fi

    ovh_render_vrack_block
}

# Bridged mode: physical NIC manual, vmbr0 owns the main IP and bridges
# to the NIC. VMs use Virtual MACs for additional IPs.
ovh_render_interfaces_bridged() {
    local iface="${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}"

    cat <<IFACES
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

iface ${iface} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4_CIDR}
    gateway ${PVE_MAIN_IPV4_GW}
    bridge-ports ${iface}
    bridge-stp off
    bridge-fd 0
    hwaddress ${PVE_MAC_ADDRESS}
IFACES

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        local ipv6_gw
        ipv6_gw="$(ovh_compute_ipv6_gateway "$PVE_IPV6_CIDR")"
        cat <<IPV6

iface vmbr0 inet6 static
    address ${PVE_IPV6_CIDR}
    post-up /sbin/ip -f inet6 route add ${ipv6_gw} dev vmbr0 || true
    post-up /sbin/ip -f inet6 route add default via ${ipv6_gw} || true
    pre-down /sbin/ip -f inet6 route del default via ${ipv6_gw} || true
    pre-down /sbin/ip -f inet6 route del ${ipv6_gw} dev vmbr0 || true
IPV6
    fi

    ovh_render_vrack_block
}

# Optional: a second bridge on the OVH vRack interface.
ovh_render_vrack_block() {
    [[ -z "$PVE_OVH_VRACK_INTERFACE" ]] && return 0

    cat <<VRACK

# OVH vRack: private network bridge across OVH services.
iface ${PVE_OVH_VRACK_INTERFACE} inet manual

auto vmbr2
iface vmbr2 inet static
VRACK
    if [[ -n "$PVE_OVH_VRACK_IP_CIDR" ]]; then
        echo "    address ${PVE_OVH_VRACK_IP_CIDR}"
    fi
    cat <<VRACKEND
    bridge-ports ${PVE_OVH_VRACK_INTERFACE}
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
VRACKEND
}

# OVH IPv6 gateway derivation:
#   For 2001:41d0:1510:1c89::/64 the gateway is 2001:41d0:1510:1cFF:FF:FF:FF:FF
#   (last byte of the /64 prefix becomes 0xFF, then host part is FF:FF:FF:FF).
# Handles both fully-written prefixes ("2001:41d0:1510:1c89::") and short-form
# addresses with `::` collapsing ("2001:db8::").
ovh_compute_ipv6_gateway() {
    local cidr="$1"
    local addr="${cidr%/*}"

    # Expand "::" so we have at least 4 explicit groups of /64 prefix.
    local prefix=""
    if [[ "$addr" == *"::"* ]]; then
        local before_dc="${addr%%::*}"
        local before_count=0
        if [[ -n "$before_dc" ]]; then
            before_count=$(awk -F: '{print NF}' <<< "$before_dc")
        fi
        local needed=$(( 4 - before_count ))
        prefix="$before_dc"
        local i
        for ((i = 0; i < needed; i++)); do
            prefix+=":0"
        done
    else
        prefix="$(echo "$addr" | cut -d: -f1-4)"
    fi

    local block="${prefix##*:}"
    if [[ ${#block} -lt 4 ]]; then
        block="$(printf '%04s' "$block" | tr ' ' '0')"
    fi
    local subnet_prefix="${block:0:2}"
    local gw_block="${subnet_prefix}FF"
    local prefix_head="${prefix%:*}"
    echo "${prefix_head}:${gw_block}:FF:FF:FF:FF"
}

ovh_post_install_notes() {
    cat <<NOTES
OVH Control Panel actions required:
  1. Disable rescue mode: Server > Boot > 'Boot from the hard disk'.
  2. Reboot the server (Server > Status > Restart).
  3. (Bridged or routed mode) For each VM additional IP, add a Virtual
     MAC in: Bare Metal Cloud > IPs > 'Add a virtual MAC'.
  4. Firewall (network edge): Bare Metal Cloud > Network Firewall.

OVH-specific notes:
  - Main interface name in installed system: ${PVE_PREDICTED_IFACE:-detected}
  - Gateway model: ${PVE_OVH_GATEWAY_MODEL:-classic}
  - vRack: ${PVE_OVH_VRACK_INTERFACE:-not configured}
NOTES
}
