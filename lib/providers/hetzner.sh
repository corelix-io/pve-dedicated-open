# Hetzner provider: rescue checks, DNS defaults, interface prediction,
# network rendering. Preserves the legacy behavior of pve-hetzner.
# shellcheck shell=bash

hetzner_check_rescue() {
    if [[ -f /etc/hetzner-rescue ]]; then
        ui_success "Hetzner Rescue System detected"
        return 0
    fi
    if command -v installimage &>/dev/null; then
        ui_success "Hetzner Rescue System detected (installimage found)"
        return 0
    fi
    if [[ -f /etc/motd ]] && grep -qi 'hetzner\|rescue' /etc/motd 2>/dev/null; then
        ui_success "Hetzner Rescue System detected (motd)"
        return 0
    fi
    if grep -qi 'hetzner' /etc/resolv.conf 2>/dev/null; then
        ui_success "Hetzner Rescue System detected (DNS)"
        return 0
    fi

    local root_fs
    root_fs="$(df / 2>/dev/null | tail -1 | awk '{print $1}')"
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

# Hetzner provides predict-check; fall back to the udev-based detection
# already implemented in lib/network.sh.
hetzner_predict_iface() {
    local predicted=""
    if command -v predict-check &>/dev/null; then
        predicted="$(predict-check 2>/dev/null | awk -F' -> ' '{print $2}' | head -n1 | xargs)"
    fi
    if [[ -z "$predicted" ]]; then
        local active
        active="$(net_get_active_interface)"
        predicted="$(udevadm info "/sys/class/net/${active}" 2>/dev/null \
            | grep 'ID_NET_NAME_PATH=' | cut -d'=' -f2)"
    fi
    if [[ -z "$predicted" ]]; then
        predicted="$(net_get_active_interface)"
    fi
    echo "$predicted"
}

hetzner_post_network_detect() {
    return 0
}

# Render /etc/network/interfaces for a Hetzner host. Identical to the
# pre-refactor firstboot_render_interfaces output.
hetzner_render_interfaces() {
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
    bridge-fd 1
    bridge-vlan-aware yes
    bridge-vids 2-4094
    pointopoint ${PVE_MAIN_IPV4_GW}
IFACES

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        cat <<IPV6

iface vmbr0 inet6 static
    address ${PVE_IPV6_CIDR}
    gateway fe80::1
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

    if [[ -n "$PVE_FIRST_IPV6_CIDR" ]]; then
        cat <<IPV6B

iface vmbr1 inet6 static
    address ${PVE_FIRST_IPV6_CIDR}
IPV6B
    fi
}

hetzner_post_install_notes() {
    cat <<NOTES
Hetzner Robot Firewall (recommended):
  1. Go to robot.hetzner.com > Server > Firewall
  2. Create rules to ALLOW ports 22, 8006 from your management IP(s) only
  3. Set default incoming policy to DROP
  4. Apply the firewall to your server

Reboot after install:
  Use Hetzner Robot Panel > Server > Reset > 'Execute an automatic hardware reset'.
  A shell 'reboot' may loop back to rescue mode.
NOTES
}
