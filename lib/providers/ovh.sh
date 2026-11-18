# OVH provider: rescue checks, DNS defaults, interface prediction,
# network rendering for OVH dedicated/SoYouStart/Kimsufi servers.
# shellcheck shell=bash
#
# OVH-specific facts informing this module:
#   * Rescue is a Debian-based image; SSH is via password or key emailed by OVH.
#   * NIC name in rescue (eth0) typically differs from the installed name
#     (eno1, enp*, ens*); first-boot re-resolves the NIC by MAC.
#   * Classic ranges use a /24-style gateway in the same subnet.
#   * High Grade / Scale / Advance ranges use /32 host IP with a fixed
#     gateway 100.64.0.1 reachable on-link.
#   * The IPv6 gateway is either the block's "<prefix>FF:FF:FF:FF:FF" form or
#     fe80::1 depending on the range -- the Control Panel shows the real one.
#   * Additional IPs on classic ranges require a Virtual MAC (vMAC)
#     configured in the OVH Control Panel; vRack IP blocks do NOT.
#   * vRack uses a second NIC and is private between OVH services.

# --- OVH-specific config knobs (read by config.sh CLI parsing) ---------------
declare -g PVE_OVH_GATEWAY_MODEL="${PVE_OVH_GATEWAY_MODEL:-auto}"   # auto | classic | scale
declare -g PVE_OVH_VRACK_INTERFACE="${PVE_OVH_VRACK_INTERFACE:-}"   # second NIC name for vRack
declare -g PVE_OVH_VRACK_IP_CIDR="${PVE_OVH_VRACK_IP_CIDR:-}"       # static IP/CIDR on vRack bridge
declare -g PVE_OVH_ADDITIONAL_IPS="${PVE_OVH_ADDITIONAL_IPS:-}"     # legacy alias of PVE_ADDITIONAL_IPS
declare -g PVE_OVH_IPV6_GATEWAY="${PVE_OVH_IPV6_GATEWAY:-}"         # explicit IPv6 gateway override

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
    root_fs="$(df / 2>/dev/null | awk 'NR == 2 {print $1}')"
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

# OVH does not provide predict-check. Mirror systemd's NamePolicy
# (onboard > slot > path) using the rescue system's udev properties.
ovh_predict_iface() {
    local iface="${PVE_INTERFACE:-$(net_get_active_interface)}"
    local predicted
    predicted="$(net_udev_predict_name "$iface" || true)"
    echo "${predicted:-$iface}"
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
    echo "classic"
}

ovh_post_network_detect() {
    local model
    model="$(ovh_detect_gateway_model)"
    PVE_OVH_GATEWAY_MODEL="$model"
    log_debug "OVH gateway model: ${model}"
}

# Return 0 when the main IPv4 gateway must be declared on-link.
_ovh_gateway_needs_pointopoint() {
    if [[ "$(ovh_detect_gateway_model)" == "scale" ]]; then
        return 0
    fi
    provider_gateway_is_offlink "${PVE_MAIN_IPV4_CIDR}" "${PVE_MAIN_IPV4_GW}"
}

# Effective IPv6 gateway: explicit override, else what the rescue system
# routes through, else the classic derived form.
ovh_ipv6_gateway() {
    if [[ -n "${PVE_OVH_IPV6_GATEWAY:-}" ]]; then
        echo "$PVE_OVH_IPV6_GATEWAY"
    elif [[ -n "${PVE_IPV6_GW_DETECTED:-}" ]]; then
        echo "$PVE_IPV6_GW_DETECTED"
    else
        ovh_compute_ipv6_gateway "$PVE_IPV6_CIDR"
    fi
}

# inet6 stanza for DEV. Link-local gateways use a plain `gateway` line;
# OVH's off-prefix gateways need an explicit on-link host route first.
_ovh_render_ipv6() {
    local dev="$1"
    local address="$2"
    local gw
    gw="$(ovh_ipv6_gateway)"

    printf '\niface %s inet6 static\n    address %s\n' "$dev" "$address"
    if [[ "${gw,,}" == fe80:* ]]; then
        printf '    gateway %s\n' "$gw"
    else
        cat <<IPV6
    post-up /sbin/ip -f inet6 route add ${gw} dev ${dev} || true
    post-up /sbin/ip -f inet6 route add default via ${gw} dev ${dev} || true
    pre-down /sbin/ip -f inet6 route del default via ${gw} dev ${dev} || true
    pre-down /sbin/ip -f inet6 route del ${gw} dev ${dev} || true
IPV6
    fi
}

_ovh_render_header() {
    cat <<HEADER
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback
HEADER
}

# /etc/network/interfaces renderer dispatches by network mode.
ovh_render_interfaces() {
    local iface="${1:-${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}}"
    case "${PVE_NETWORK_MODE:-nat}" in
        nat)     ovh_render_interfaces_nat "$iface" ;;
        routed)  ovh_render_interfaces_routed "$iface" ;;
        bridged) ovh_render_interfaces_bridged "$iface" ;;
        *)       die "Unknown PVE_NETWORK_MODE: ${PVE_NETWORK_MODE}" ;;
    esac
}

# Shared vmbr0 stanza for nat and bridged modes.
_ovh_render_vmbr0_bridge() {
    local iface="$1"
    local hwaddress="${2:-}"

    cat <<IFACES

iface ${iface} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4_CIDR}
    gateway ${PVE_MAIN_IPV4_GW}
    bridge-ports ${iface}
    bridge-stp off
    bridge-fd 0
IFACES
    if [[ -n "$hwaddress" ]]; then
        echo "    hwaddress ${hwaddress}"
    fi
    if _ovh_gateway_needs_pointopoint; then
        echo "    # OVH High Grade/Scale/Advance (or /32): gateway is on-link"
        echo "    pointopoint ${PVE_MAIN_IPV4_GW}"
    fi

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        _ovh_render_ipv6 vmbr0 "$PVE_IPV6_CIDR"
    fi
}

# NAT (default): public IP on vmbr0 bridged to physical NIC, vmbr1 NAT
# bridge with MASQUERADE.
ovh_render_interfaces_nat() {
    local iface="${1:-${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}}"
    _ovh_render_header
    _ovh_render_vmbr0_bridge "$iface"
    provider_render_nat_bridge
    ovh_render_vrack_block
}

# Routed mode: physical NIC keeps the main IP as /32 with an on-link
# gateway; vmbr0 has no bridge-ports and serves as gateway for additional
# IPs routed onto it. IPv6 lives on the NIC (/128) and vmbr0 (/64).
ovh_render_interfaces_routed() {
    local iface="${1:-${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}}"
    _ovh_render_header

    cat <<IFACES

# Physical interface holds the public IP as /32 (OVH routed mode).
auto ${iface}
iface ${iface} inet static
    address ${PVE_MAIN_IPV4}/32
    gateway ${PVE_MAIN_IPV4_GW}
    pointopoint ${PVE_MAIN_IPV4_GW}
IFACES

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        _ovh_render_ipv6 "$iface" "${PVE_IPV6}/128"
    fi

    cat <<BRIDGE

# vmbr0 is a bridge with no ports; additional IPs are routed onto it.
auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4}/32
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE
    provider_render_additional_routes

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        printf '\niface vmbr0 inet6 static\n    address %s/64\n' "$PVE_IPV6"
    fi

    ovh_render_vrack_block
}

# Bridged mode: physical NIC manual, vmbr0 owns the main IP and bridges
# to the NIC. VMs use Virtual MACs for additional IPs.
ovh_render_interfaces_bridged() {
    local iface="${1:-${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}}"
    _ovh_render_header
    _ovh_render_vmbr0_bridge "$iface" "$PVE_MAC_ADDRESS"
    ovh_render_vrack_block
}

# Optional: a second bridge on the OVH vRack interface.
ovh_render_vrack_block() {
    [[ -n "$PVE_OVH_VRACK_INTERFACE" ]] || return 0

    local method="manual"
    [[ -n "$PVE_OVH_VRACK_IP_CIDR" ]] && method="static"
    cat <<VRACK

# OVH vRack: private network bridge across OVH services.
iface ${PVE_OVH_VRACK_INTERFACE} inet manual

auto vmbr2
iface vmbr2 inet ${method}
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

# OVH IPv6 gateway derivation (classic ranges):
#   For 2001:41d0:1510:1c89::/64 the gateway is 2001:41d0:1510:1cFF:FF:FF:FF:FF
#   (last byte of the /64 prefix becomes 0xFF, then host part is FF:FF:FF:FF).
ovh_compute_ipv6_gateway() {
    local cidr="$1"
    local prefix
    prefix="$(net_ipv6_prefix64 "$cidr")" || return 1

    local block
    block="$(printf '%04x' "$((16#${prefix##*:}))")"
    echo "${prefix%:*}:${block:0:2}FF:FF:FF:FF:FF"
}

ovh_post_install_notes() {
    cat <<NOTES
OVH Control Panel actions required:
  1. Disable rescue mode: Server > Boot > 'Boot from the hard disk'.
  2. Reboot the server (Server > Status > Restart).
  3. (Bridged mode) For each VM additional IP, add a Virtual MAC in:
     Bare Metal Cloud > IPs > 'Add a virtual MAC'. Routed mode needs none.
  4. Firewall (network edge): Bare Metal Cloud > Network Firewall.

OVH-specific notes:
  - Main interface name in installed system: ${PVE_PREDICTED_IFACE:-detected}
  - Gateway model: ${PVE_OVH_GATEWAY_MODEL:-classic}
  - vRack: ${PVE_OVH_VRACK_INTERFACE:-not configured}
NOTES
    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        echo "  - IPv6 gateway: $(ovh_ipv6_gateway) (check it in the Control Panel)"
    fi
}
