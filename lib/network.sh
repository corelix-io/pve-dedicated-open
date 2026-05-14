# Network interface detection, IP/gateway/MAC extraction, predicted names
# shellcheck shell=bash

net_get_active_interface() {
    local iface
    iface="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
    if [[ -z "$iface" ]]; then
        iface="$(udevadm info -e 2>/dev/null | grep -m1 -A 20 '^P.*eth0' | grep ID_NET_NAME_PATH | cut -d'=' -f2)"
    fi
    if [[ -z "$iface" ]]; then
        iface="eth0"
    fi
    echo "$iface"
}

net_list_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | sort
}

net_list_interfaces_display() {
    local ifaces=()
    while IFS= read -r iface; do
        ifaces+=("$iface")
    done < <(net_list_interfaces)

    local IFS=', '
    echo "${ifaces[*]}"
}

net_get_interface_info() {
    local iface="$1"
    local mac ip4_cidr ip6_cidr

    mac="$(ip link show "$iface" 2>/dev/null | awk '/ether/ {print $2}')"
    ip4_cidr="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet.*global/ {print $2; exit}')"
    ip6_cidr="$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6.*global/ {print $2; exit}')"

    echo "${mac}|${ip4_cidr}|${ip6_cidr}"
}

net_extract_info() {
    local iface="$1"

    PVE_MAIN_IPV4_CIDR="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet.*global/ {print $2; exit}')"
    PVE_MAIN_IPV4="$(echo "$PVE_MAIN_IPV4_CIDR" | cut -d'/' -f1)"
    PVE_MAIN_IPV4_GW="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
    PVE_MAC_ADDRESS="$(ip link show "$iface" 2>/dev/null | awk '/ether/ {print $2}')"
    PVE_IPV6_CIDR="$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6.*global/ {print $2; exit}')"
    PVE_IPV6="$(echo "$PVE_IPV6_CIDR" | cut -d'/' -f1)"

    if [[ -z "$PVE_MAIN_IPV4" ]]; then
        log_warn "No IPv4 address found on interface ${iface}"
    fi

    log_debug "Network: iface=${iface} ip=${PVE_MAIN_IPV4_CIDR} gw=${PVE_MAIN_IPV4_GW} mac=${PVE_MAC_ADDRESS}"
}

net_get_predicted_name() {
    # Delegate to the active provider when one is selected.
    if [[ -n "${PVE_PROVIDER:-}" ]] && declare -F provider_predict_iface >/dev/null; then
        provider_predict_iface
        return $?
    fi

    # Generic fallback (used during early boot before provider_resolve runs).
    local predicted=""
    if command -v predict-check &>/dev/null; then
        predicted="$(predict-check 2>/dev/null | awk -F' -> ' '{print $2}' | head -n1 | xargs)"
    fi
    if [[ -z "$predicted" ]]; then
        local active
        active="$(net_get_active_interface)"
        predicted="$(udevadm info "/sys/class/net/${active}" 2>/dev/null | grep 'ID_NET_NAME_PATH=' | cut -d'=' -f2)"
    fi
    if [[ -z "$predicted" ]]; then
        log_warn "Could not predict post-install interface name, using current"
        predicted="$(net_get_active_interface)"
    fi
    echo "$predicted"
}

net_detect_all() {
    local active_iface
    active_iface="$(net_get_active_interface)"

    if [[ -z "$PVE_INTERFACE" ]]; then
        PVE_INTERFACE="$active_iface"
    fi

    net_extract_info "$PVE_INTERFACE"

    PVE_PREDICTED_IFACE="$(net_get_predicted_name)"

    # Capture WAN MAC for premium LUKS pre-boot networking, if not set
    if [[ -z "${PVE_LUKS_WAN_MAC:-}" ]]; then
        PVE_LUKS_WAN_MAC="$PVE_MAC_ADDRESS"
    fi

    ui_success "Active interface: ${PVE_INTERFACE}"
    ui_kv "IPv4" "${PVE_MAIN_IPV4_CIDR:-none}"
    ui_kv "Gateway" "${PVE_MAIN_IPV4_GW:-none}"
    ui_kv "MAC" "${PVE_MAC_ADDRESS:-none}"
    ui_kv "IPv6" "${PVE_IPV6_CIDR:-none}"
    ui_kv "Predicted name" "${PVE_PREDICTED_IFACE}"
}

# Display a summary of all available interfaces
net_show_interfaces() {
    local ifaces
    ifaces="$(net_list_interfaces)"

    ui_info "Available network interfaces:"
    while IFS= read -r iface; do
        local info mac ip4 ip6 driver
        info="$(net_get_interface_info "$iface")"
        IFS='|' read -r mac ip4 ip6 <<< "$info"
        driver="$(ethtool -i "$iface" 2>/dev/null | awk '/driver:/ {print $2}' || echo "?")"

        local status
        status="$(ip link show "$iface" 2>/dev/null | grep -q 'state UP' && echo "UP" || echo "DOWN")"

        ui_detail "${iface} [${status}] MAC:${mac:-?} IPv4:${ip4:-none} Driver:${driver}"
    done <<< "$ifaces"
}
