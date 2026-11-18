# Network interface detection, IP/gateway/MAC extraction, address math helpers
# shellcheck shell=bash

# --- Pure address helpers (no system calls; unit-tested) ---------------------

# Convert a dotted IPv4 address to a 32-bit integer. Returns 1 on bad input.
net_ipv4_to_int() {
    local ip="$1"
    local -a o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -ra o <<< "$ip"
    local x
    for x in "${o[@]}"; do
        (( 10#$x <= 255 )) || return 1
    done
    echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

net_int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# Echo the dotted netmask for a prefix length (e.g. 24 -> 255.255.255.0).
net_prefix_to_netmask() {
    local prefix="$1"
    local mask=0
    if (( prefix > 0 )); then
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    net_int_to_ipv4 "$mask"
}

# Return 0 when IP lies inside CIDR (e.g. 10.0.0.5 in 10.0.0.0/24).
net_ipv4_in_subnet() {
    local ip="$1"
    local cidr="$2"
    local net="${cidr%/*}"
    local prefix="${cidr#*/}"
    [[ "$cidr" == */* ]] || prefix=32
    local ip_i net_i
    ip_i="$(net_ipv4_to_int "$ip")" || return 1
    net_i="$(net_ipv4_to_int "$net")" || return 1
    local mask=0
    if (( prefix > 0 )); then
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    (( (ip_i & mask) == (net_i & mask) ))
}

# Network address of an IPv4 CIDR (e.g. 192.168.26.7/24 -> 192.168.26.0).
net_ipv4_network() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    local ip_i
    ip_i="$(net_ipv4_to_int "$ip")" || return 1
    local mask=0
    if (( prefix > 0 )); then
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    net_int_to_ipv4 $(( ip_i & mask ))
}

# Nth host address of an IPv4 CIDR (e.g. 192.168.26.0/24, 1 -> 192.168.26.1).
net_ipv4_host() {
    local cidr="$1"
    local n="$2"
    local network net_i
    network="$(net_ipv4_network "$cidr")" || return 1
    net_i="$(net_ipv4_to_int "$network")" || return 1
    net_int_to_ipv4 $(( net_i + n ))
}

# Expand an IPv6 address (no prefix) to 8 groups of 4 lowercase hex digits.
# "2a01:4f8:1::2" -> "2a01:04f8:0001:0000:0000:0000:0000:0002"
net_ipv6_expand() {
    local addr="${1%/*}"
    addr="${addr,,}"
    [[ "$addr" =~ ^[0-9a-f:]+$ ]] || return 1

    local -a head=() tail=()
    if [[ "$addr" == *"::"* ]]; then
        local left="${addr%%::*}"
        local right="${addr#*::}"
        [[ "$right" != *"::"* ]] || return 1
        [[ -n "$left" ]] && IFS=':' read -ra head <<< "$left"
        [[ -n "$right" ]] && IFS=':' read -ra tail <<< "$right"
        local missing=$(( 8 - ${#head[@]} - ${#tail[@]} ))
        (( missing >= 1 )) || return 1
        local i
        for (( i = 0; i < missing; i++ )); do
            head+=("0")
        done
        head+=("${tail[@]}")
    else
        IFS=':' read -ra head <<< "$addr"
    fi

    (( ${#head[@]} == 8 )) || return 1
    local out="" g
    for g in "${head[@]}"; do
        [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        out+="$(printf '%04x' "$((16#$g))"):"
    done
    echo "${out%:}"
}

# Echo the first four groups (the /64 prefix) of an IPv6 address, without
# leading zeros, e.g. "2a01:4f8:1::2/64" -> "2a01:4f8:1:0".
net_ipv6_prefix64() {
    local full
    full="$(net_ipv6_expand "$1")" || return 1
    local -a g
    IFS=':' read -ra g <<< "$full"
    printf '%x:%x:%x:%x\n' "$((16#${g[0]}))" "$((16#${g[1]}))" "$((16#${g[2]}))" "$((16#${g[3]}))"
}

# --- System probes -----------------------------------------------------------

net_get_active_interface() {
    local iface
    iface="$(ip -4 route show default 2>/dev/null | awk '/^default/ {for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    if [[ -z "$iface" ]]; then
        iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" && /state UP/ {sub(/@.*/, "", $2); print $2; exit}')"
    fi
    echo "${iface:-eth0}"
}

net_list_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}' | grep -v '^lo$' | sort
}

net_list_interfaces_display() {
    local -a ifaces=()
    local iface
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && ifaces+=("$iface")
    done < <(net_list_interfaces)

    local out=""
    for iface in "${ifaces[@]}"; do
        out+="${out:+, }${iface}"
    done
    echo "$out"
}

net_get_interface_info() {
    local iface="$1"
    local mac ip4_cidr ip6_cidr

    mac="$(ip link show "$iface" 2>/dev/null | awk '/link\/ether/ {print $2; exit}')"
    ip4_cidr="$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet .*global/ {print $2; exit}')"
    ip6_cidr="$(ip -6 addr show "$iface" 2>/dev/null | awk '/inet6 .*global/ {print $2; exit}')"

    echo "${mac}|${ip4_cidr}|${ip6_cidr}"
}

# Default IPv4 gateway, preferring the route bound to IFACE.
_net_default_gw4() {
    local iface="$1"
    local gw
    gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [[ -z "$gw" ]]; then
        gw="$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
    fi
    echo "$gw"
}

# IPv6 default gateway as configured in the rescue system (empty if none).
_net_default_gw6() {
    local iface="$1"
    ip -6 route show default dev "$iface" 2>/dev/null | awk '/^default via/ {print $3; exit}'
}

net_extract_info() {
    local iface="$1"
    local info mac ip4 ip6
    info="$(net_get_interface_info "$iface")"
    IFS='|' read -r mac ip4 ip6 <<< "$info"

    PVE_MAIN_IPV4_CIDR="$ip4"
    PVE_MAIN_IPV4="${ip4%/*}"
    PVE_MAIN_IPV4_GW="$(_net_default_gw4 "$iface")"
    PVE_MAC_ADDRESS="${mac,,}"
    PVE_IPV6_CIDR="$ip6"
    # shellcheck disable=SC2034  # read by the providers and firstboot
    PVE_IPV6="${ip6%/*}"
    PVE_IPV6_GW_DETECTED="$(_net_default_gw6 "$iface")"

    if [[ -z "$PVE_MAIN_IPV4" ]]; then
        log_warn "No IPv4 address found on interface ${iface}"
    fi

    log_debug "Network: iface=${iface} ip=${PVE_MAIN_IPV4_CIDR} gw=${PVE_MAIN_IPV4_GW} mac=${PVE_MAC_ADDRESS} ip6=${PVE_IPV6_CIDR} gw6=${PVE_IPV6_GW_DETECTED}"
}

# Generic udev-based prediction of the post-install interface name.
# systemd's default NamePolicy prefers onboard > slot > path, so mirror it.
net_udev_predict_name() {
    local iface="$1"
    [[ -e "/sys/class/net/${iface}" ]] || return 1

    local props key value
    props="$(udevadm info --query=property "/sys/class/net/${iface}" 2>/dev/null || true)"
    for key in ID_NET_NAME_ONBOARD ID_NET_NAME_SLOT ID_NET_NAME_PATH; do
        value="$(awk -F= -v k="$key" '$1 == k {print $2; exit}' <<< "$props")"
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    done
    return 1
}

net_get_predicted_name() {
    if [[ -n "${PVE_PROVIDER:-}" ]] && declare -F provider_predict_iface >/dev/null; then
        provider_predict_iface
        return $?
    fi

    local predicted=""
    predicted="$(net_udev_predict_name "${PVE_INTERFACE:-$(net_get_active_interface)}" || true)"
    if [[ -z "$predicted" ]]; then
        log_warn "Could not predict post-install interface name, using current"
        predicted="${PVE_INTERFACE:-$(net_get_active_interface)}"
    fi
    echo "$predicted"
}

net_detect_all() {
    if [[ -z "$PVE_INTERFACE" ]]; then
        PVE_INTERFACE="$(net_get_active_interface)"
    fi

    net_extract_info "$PVE_INTERFACE"

    PVE_PREDICTED_IFACE="$(net_get_predicted_name)"

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

net_show_interfaces() {
    local ifaces
    ifaces="$(net_list_interfaces)"

    ui_info "Available network interfaces:"
    local iface
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local info mac ip4 ip6 driver status
        info="$(net_get_interface_info "$iface")"
        IFS='|' read -r mac ip4 ip6 <<< "$info"
        driver="$(ethtool -i "$iface" 2>/dev/null | awk '/^driver:/ {print $2}')"
        if ip link show "$iface" 2>/dev/null | grep -q 'state UP'; then
            status="UP"
        else
            status="DOWN"
        fi
        ui_detail "${iface} [${status}] MAC:${mac:-?} IPv4:${ip4:-none} IPv6:${ip6:-none} Driver:${driver:-?}"
    done <<< "$ifaces"
}
