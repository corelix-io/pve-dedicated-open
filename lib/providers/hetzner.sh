# Hetzner provider: rescue checks, DNS defaults, interface prediction,
# network rendering. Preserves the legacy behavior of pve-hetzner.
# shellcheck shell=bash

readonly HETZNER_IPV6_GATEWAY="fe80::1"

hetzner_check_rescue() {
    if [[ -f /etc/hetzner-rescue ]]; then
        ui_success "Hetzner Rescue System detected"
        return 0
    fi
    if command -v installimage &>/dev/null; then
        ui_success "Hetzner Rescue System detected (installimage found)"
        return 0
    fi
    if [[ -f /etc/motd ]] && grep -qi 'hetzner' /etc/motd 2>/dev/null; then
        ui_success "Hetzner Rescue System detected (motd)"
        return 0
    fi
    if grep -qi 'hetzner' /etc/resolv.conf 2>/dev/null; then
        ui_success "Hetzner Rescue System detected (DNS)"
        return 0
    fi

    local root_fs
    root_fs="$(df / 2>/dev/null | awk 'NR == 2 {print $1}')"
    if [[ "$root_fs" == "tmpfs" ]] || [[ "$root_fs" == "rootfs" ]] || [[ "$root_fs" == *"nfs"* ]]; then
        ui_success "RAM/NFS-based root filesystem detected (likely rescue)"
        return 0
    fi

    local hn
    hn="$(hostname 2>/dev/null || true)"
    if [[ "$hn" == *"rescue"* ]] || [[ "$hn" == *"hetzner"* ]]; then
        ui_success "Hetzner Rescue System detected (hostname)"
        return 0
    fi

    log_warn "Not running in Hetzner Rescue System. Proceed with caution."
    ui_warn "Rescue system not detected -- results may vary"
    return 0
}

hetzner_default_dns() {
    echo "185.12.64.1 185.12.64.2"
}

# Hetzner rescue ships predict-check ("eth0 -> enp7s0"). Use the line for
# the selected NIC, then fall back to udev's naming properties.
hetzner_predict_iface() {
    local iface="${PVE_INTERFACE:-$(net_get_active_interface)}"
    local predicted=""
    if command -v predict-check &>/dev/null; then
        predicted="$(predict-check 2>/dev/null \
            | awk -v i="$iface" -F' *-> *' '{gsub(/^[ \t]+/, "", $1)} $1 == i {print $2; exit}' \
            | tr -d '[:space:]')"
    fi
    if [[ -z "$predicted" ]]; then
        predicted="$(net_udev_predict_name "$iface" || true)"
    fi
    echo "${predicted:-$iface}"
}

hetzner_post_network_detect() {
    return 0
}

# Render /etc/network/interfaces for a Hetzner host.
#   nat     -- vmbr0 bridges the NIC and owns the main IP; vmbr1 is a NAT bridge
#   bridged -- as nat without vmbr1; VMs on vmbr0 need Robot virtual MACs
#   routed  -- NIC owns the main IP; vmbr0 (no ports) routes additional IPs
hetzner_render_interfaces() {
    local iface="${1:-${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}}"

    cat <<HEADER
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback
HEADER

    case "${PVE_NETWORK_MODE:-nat}" in
        nat|bridged) _hetzner_render_bridge_main "$iface" ;;
        routed)      _hetzner_render_routed "$iface" ;;
        *)           die "Unknown PVE_NETWORK_MODE: ${PVE_NETWORK_MODE}" ;;
    esac

    local vswitch_parent="vmbr0"
    [[ "${PVE_NETWORK_MODE:-nat}" == "routed" ]] && vswitch_parent="$iface"
    _hetzner_render_vswitch "$vswitch_parent"

    if [[ "${PVE_NETWORK_MODE:-nat}" == "nat" ]]; then
        provider_render_nat_bridge
        if [[ -n "$PVE_FIRST_IPV6_CIDR" ]] && [[ -n "$PVE_PRIVATE_IP_CIDR" ]]; then
            cat <<IPV6B

iface vmbr1 inet6 static
    address ${PVE_FIRST_IPV6_CIDR}
IPV6B
        fi
    fi
}

_hetzner_render_bridge_main() {
    local iface="$1"
    cat <<IFACES

iface ${iface} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4_CIDR}
    gateway ${PVE_MAIN_IPV4_GW}
    bridge-ports ${iface}
    bridge-stp off
    bridge-fd 1
    bridge-vlan-aware yes
    bridge-vids 2-4094
    pointopoint ${PVE_MAIN_IPV4_GW}
IFACES

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        cat <<IPV6

iface vmbr0 inet6 static
    address ${PVE_IPV6_CIDR}
    gateway ${HETZNER_IPV6_GATEWAY}
IPV6
    fi
}

# Hetzner "routed" setup: the main IP is a /32 on the NIC with an on-link
# gateway; the same IPv6 address is /128 on the NIC and /64 on vmbr0 so the
# rest of the /64 is reachable through the bridge.
_hetzner_render_routed() {
    local iface="$1"
    cat <<IFACES

auto ${iface}
iface ${iface} inet static
    address ${PVE_MAIN_IPV4}/32
    gateway ${PVE_MAIN_IPV4_GW}
    pointopoint ${PVE_MAIN_IPV4_GW}
IFACES

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        cat <<IPV6

iface ${iface} inet6 static
    address ${PVE_IPV6}/128
    gateway ${HETZNER_IPV6_GATEWAY}
IPV6
    fi

    cat <<BRIDGE

auto vmbr0
iface vmbr0 inet static
    address ${PVE_MAIN_IPV4}/32
    bridge-ports none
    bridge-stp off
    bridge-fd 0
BRIDGE
    provider_render_additional_routes

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        cat <<IPV6B

iface vmbr0 inet6 static
    address ${PVE_IPV6}/64
IPV6B
    fi
}

# --- vSwitch ------------------------------------------------------------------

hetzner_vswitch_enabled() {
    [[ -n "${PVE_HETZNER_VSWITCH_VLAN:-}" ]]
}

# VLAN device name, both on the installed host and in the LUKS initramfs.
hetzner_vswitch_dev() {
    echo "vlan${PVE_HETZNER_VSWITCH_VLAN}"
}

# Gateway for PVE_HETZNER_VSWITCH_ROUTES: explicit, else the first host of the
# vSwitch subnet (the address a Hetzner Cloud Network gives its vSwitch subnet).
hetzner_vswitch_gateway() {
    if [[ -n "${PVE_HETZNER_VSWITCH_GATEWAY:-}" ]]; then
        echo "$PVE_HETZNER_VSWITCH_GATEWAY"
        return 0
    fi
    [[ -n "${PVE_HETZNER_VSWITCH_IP:-}" ]] || return 1
    net_ipv4_host "$PVE_HETZNER_VSWITCH_IP" 1
}

# Return 0 when IPv4 address IP is reached over the vSwitch (on-link or routed).
hetzner_vswitch_reaches() {
    local ip="$1" cidr
    hetzner_vswitch_enabled || return 1
    [[ -n "${PVE_HETZNER_VSWITCH_IP:-}" ]] || return 1
    net_ipv4_in_subnet "$ip" "$PVE_HETZNER_VSWITCH_IP" && return 0
    for cidr in ${PVE_HETZNER_VSWITCH_ROUTES//,/ }; do
        net_ipv4_in_subnet "$ip" "$cidr" && return 0
    done
    return 1
}

# vSwitch VLAN on PARENT (vmbr0 when the NIC is a bridge port, else the NIC).
# Hetzner requires MTU 1400 on the VLAN.
_hetzner_render_vswitch() {
    local parent="$1"
    hetzner_vswitch_enabled || return 0
    local vlan="$PVE_HETZNER_VSWITCH_VLAN"
    local mtu="${PVE_HETZNER_VSWITCH_MTU:-1400}"
    local dev l3dev method="manual" gw="" route
    dev="$(hetzner_vswitch_dev)"
    l3dev="$dev"
    [[ -n "${PVE_HETZNER_VSWITCH_IP:-}" ]] && method="static"

    if [[ "${PVE_HETZNER_VSWITCH_BRIDGE:-false}" == true ]]; then
        l3dev="vmbr${vlan}"
        cat <<VLAN

auto ${dev}
iface ${dev} inet manual
    vlan-raw-device ${parent}
    vlan-id ${vlan}
    mtu ${mtu}

auto ${l3dev}
iface ${l3dev} inet ${method}
VLAN
        [[ "$method" == "static" ]] && echo "    address ${PVE_HETZNER_VSWITCH_IP}"
        cat <<BRIDGE
    bridge-ports ${dev}
    bridge-stp off
    bridge-fd 0
    mtu ${mtu}
BRIDGE
    else
        cat <<VLAN

auto ${dev}
iface ${dev} inet ${method}
VLAN
        [[ "$method" == "static" ]] && echo "    address ${PVE_HETZNER_VSWITCH_IP}"
        cat <<VLAN
    vlan-raw-device ${parent}
    vlan-id ${vlan}
    mtu ${mtu}
VLAN
    fi

    if [[ -n "${PVE_HETZNER_VSWITCH_ROUTES:-}" ]]; then
        gw="$(hetzner_vswitch_gateway)" || return 0
        for route in ${PVE_HETZNER_VSWITCH_ROUTES//,/ }; do
            echo "    up   ip route replace ${route} via ${gw} dev ${l3dev}"
            echo "    down ip route del ${route} via ${gw} dev ${l3dev} || true"
        done
    fi
}

# Bring the vSwitch up temporarily in rescue and fetch URL/adv from each Tang
# URL given, proving Robot vSwitch membership and Cloud Network coupling
# before the disks are erased. Prints one line per URL; returns 1 on any
# failure. The temporary VLAN device is always removed.
hetzner_vswitch_probe_tang() {
    local iface="${PVE_INTERFACE:-}"
    [[ -n "$iface" ]] || iface="$(net_get_active_interface 2>/dev/null || true)"
    local dev="pvevsw${PVE_HETZNER_VSWITCH_VLAN}"
    local mtu="${PVE_HETZNER_VSWITCH_MTU:-1400}"
    local gw="" route url rc=0

    if [[ -z "$iface" ]] || [[ -z "${PVE_HETZNER_VSWITCH_IP:-}" ]]; then
        ui_warn "vSwitch probe skipped (no rescue interface or vSwitch IP)"
        return 1
    fi
    if ip link show "$dev" &>/dev/null; then
        ui_warn "vSwitch probe skipped: ${dev} already exists in rescue"
        return 1
    fi
    modprobe 8021q 2>/dev/null || true
    if ! ip link add link "$iface" name "$dev" type vlan id "$PVE_HETZNER_VSWITCH_VLAN" 2>/dev/null; then
        ui_warn "vSwitch probe skipped: cannot create VLAN ${PVE_HETZNER_VSWITCH_VLAN} on ${iface}"
        return 1
    fi

    if ip link set "$dev" mtu "$mtu" up \
        && ip addr add "$PVE_HETZNER_VSWITCH_IP" dev "$dev"; then
        if [[ -n "${PVE_HETZNER_VSWITCH_ROUTES:-}" ]]; then
            gw="$(hetzner_vswitch_gateway || true)"
            for route in ${PVE_HETZNER_VSWITCH_ROUTES//,/ }; do
                ip route replace "$route" via "$gw" dev "$dev" 2>/dev/null || rc=1
            done
        fi
        sleep 3
        for url in "$@"; do
            if curl -4fsS --max-time 5 -o /dev/null "${url%/}/adv" 2>/dev/null; then
                ui_success "Tang server reachable over vSwitch VLAN ${PVE_HETZNER_VSWITCH_VLAN}: ${url}"
            else
                ui_warn "Tang server NOT reachable over vSwitch VLAN ${PVE_HETZNER_VSWITCH_VLAN}: ${url}"
                rc=1
            fi
        done
    else
        rc=1
    fi

    ip link del "$dev" 2>/dev/null || true
    if (( rc != 0 )); then
        ui_warn "Check: server added to the vSwitch in Robot, vSwitch subnet coupled to the Cloud Network, Tang firewall allows ${PVE_HETZNER_VSWITCH_IP%/*}"
    fi
    return "$rc"
}

hetzner_post_install_notes() {
    cat <<NOTES
Hetzner Robot Firewall (recommended):
  1. Go to robot.hetzner.com > Server > Firewall
  2. Allow ports 22 and 8006 from your management IP(s) only
  3. Set the default incoming policy to DROP and apply it

Reboot after install:
  Robot Panel > Server > Reset > 'Execute an automatic hardware reset'.
  A shell 'reboot' may loop back into rescue mode.
NOTES
    if hetzner_vswitch_enabled; then
        cat <<NOTES

vSwitch VLAN ${PVE_HETZNER_VSWITCH_VLAN} ($(hetzner_vswitch_dev), MTU ${PVE_HETZNER_VSWITCH_MTU:-1400}):
  The server must be a member of the vSwitch in Robot > vSwitches.
  Guests on the vSwitch need MTU ${PVE_HETZNER_VSWITCH_MTU:-1400} inside the guest too.
NOTES
    fi
    if [[ "${PVE_NETWORK_MODE:-nat}" == "bridged" ]]; then
        cat <<NOTES

Bridged mode: every VM NIC on vmbr0 needs a virtual MAC from
  Robot Panel > IPs > (additional IP) > Virtual MAC.
NOTES
    fi
}
