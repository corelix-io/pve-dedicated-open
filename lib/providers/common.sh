# Provider abstraction: dispatch table and default hook implementations
# shellcheck shell=bash
#
# All providers must implement (in their own module):
#   <provider>_check_rescue       -- detect that we are running in the
#                                    provider's rescue/recovery environment
#   <provider>_default_dns        -- echo a space-separated list of DNS
#                                    servers to use as defaults
#   <provider>_predict_iface      -- echo the post-install interface name
#                                    for the currently active NIC
#   <provider>_render_interfaces  -- write /etc/network/interfaces content
#                                    to stdout for the current PVE_* state;
#                                    optional $1 overrides the WAN NIC name
#                                    (first-boot passes a placeholder that is
#                                    resolved by MAC on the real hardware)
#   <provider>_post_network_detect -- optional; refine derived network
#                                    facts after net_detect_all completes
#   <provider>_post_install_notes -- optional; provider-specific lines for
#                                    the install report
#
# Provider modules must NOT execute code at source time.

declare -ga PROVIDER_REGISTRY=("hetzner" "ovh")

provider_is_known() {
    local p="$1"
    local known
    for known in "${PROVIDER_REGISTRY[@]}"; do
        [[ "$known" == "$p" ]] && return 0
    done
    return 1
}

# Auto-detect provider when PVE_PROVIDER is empty.
# Returns first match (Hetzner is checked before OVH so existing Hetzner
# servers behave exactly as before this refactor).
provider_autodetect() {
    if [[ -f /etc/hetzner-rescue ]] || command -v installimage &>/dev/null; then
        echo "hetzner"
        return 0
    fi
    if [[ -f /etc/ovhrescue ]] || grep -qi 'ovh' /etc/motd 2>/dev/null \
        || grep -qi 'ovh' /etc/resolv.conf 2>/dev/null; then
        echo "ovh"
        return 0
    fi
    echo ""
}

# Resolve PVE_PROVIDER (auto-detect, validate, prompt as needed) and apply
# provider-specific defaults. Must be called once after config_parse_args.
provider_resolve() {
    if [[ -z "${PVE_PROVIDER:-}" ]]; then
        local detected
        detected="$(provider_autodetect)"
        if [[ -n "$detected" ]]; then
            PVE_PROVIDER="$detected"
            log_info "Auto-detected provider: ${PVE_PROVIDER}"
        elif [[ "${PVE_UNATTENDED:-false}" == true ]]; then
            die "Provider not specified. Pass --provider hetzner|ovh in unattended mode."
        else
            provider_interactive_select
        fi
    fi

    if ! provider_is_known "$PVE_PROVIDER"; then
        die "Unknown provider '${PVE_PROVIDER}'. Valid: ${PROVIDER_REGISTRY[*]}"
    fi

    # Apply provider DNS defaults unless the user chose DNS servers
    if [[ -z "$PVE_DNS_SERVERS" ]]; then
        PVE_DNS_SERVERS="$(provider_default_dns)"
        log_debug "Provider ${PVE_PROVIDER} default DNS: ${PVE_DNS_SERVERS}"
    fi

    log_info "Active provider: ${PVE_PROVIDER}"
}

provider_interactive_select() {
    echo ""
    ui_section "Provider Selection"
    echo -e "  ${CLR_DIM}Choose the cloud provider where this server is hosted.${CLR_RESET}"
    echo ""
    local idx=1 p
    for p in "${PROVIDER_REGISTRY[@]}"; do
        echo -e "  ${CLR_YELLOW}${idx}${CLR_RESET}) ${p}"
        idx=$(( idx + 1 ))
    done
    echo ""
    local answer=""
    ui_read answer "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Provider [1-${#PROVIDER_REGISTRY[@]}]: ")" "1"
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
        local i=$(( answer - 1 ))
        if (( i < 0 || i >= ${#PROVIDER_REGISTRY[@]} )); then
            die "Invalid provider selection: ${answer}"
        fi
        PVE_PROVIDER="${PROVIDER_REGISTRY[$i]}"
    else
        if provider_is_known "$answer"; then
            PVE_PROVIDER="$answer"
        else
            die "Invalid provider: ${answer}"
        fi
    fi
}

# --- Dispatch helpers ------------------------------------------------------

provider_check_rescue() {
    "${PVE_PROVIDER}_check_rescue"
}

provider_default_dns() {
    "${PVE_PROVIDER}_default_dns"
}

provider_predict_iface() {
    "${PVE_PROVIDER}_predict_iface"
}

provider_render_interfaces() {
    "${PVE_PROVIDER}_render_interfaces" "$@"
}

provider_post_network_detect() {
    if declare -F "${PVE_PROVIDER}_post_network_detect" >/dev/null; then
        "${PVE_PROVIDER}_post_network_detect"
    fi
}

provider_post_install_notes() {
    if declare -F "${PVE_PROVIDER}_post_install_notes" >/dev/null; then
        "${PVE_PROVIDER}_post_install_notes"
    fi
}

# --- Shared rendering helpers ------------------------------------------------

# Return 0 when GW is outside the subnet of CIDR, i.e. it must be declared
# on-link (`pointopoint`) for ifupdown2 to install the default route.
provider_gateway_is_offlink() {
    local cidr="$1"
    local gw="$2"
    [[ -n "$gw" ]] || return 1
    ! net_ipv4_in_subnet "$gw" "$cidr"
}

# "up/down ip route" lines that route each additional IP onto vmbr0.
provider_render_additional_routes() {
    local ip cidr ips="${PVE_ADDITIONAL_IPS:-${PVE_OVH_ADDITIONAL_IPS:-}}"
    for ip in ${ips//,/ }; do
        [[ -z "$ip" ]] && continue
        cidr="$ip"
        [[ "$ip" != */* ]] && cidr="${ip}/32"
        echo "    up   ip route add ${cidr} dev vmbr0 || true"
        echo "    down ip route del ${cidr} dev vmbr0 || true"
    done
}

# vmbr1: private NAT bridge (NAT mode only).
provider_render_nat_bridge() {
    [[ -n "$PVE_PRIVATE_IP_CIDR" ]] || return 0
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
}

# --- Premium feature gate stubs (overridden by lib/premium/*.sh in private) -

# Public default: announce premium availability with a CTA and continue.
# In premium builds, lib/premium/luks_common.sh overrides this with the real
# pre-flight that also handles --enable-luks.
premium_announce_cta() {
    local overridden=false
    if declare -F _premium_luks_real_announce >/dev/null; then
        _premium_luks_real_announce || return $?
        overridden=true
    fi
    if declare -F _premium_zfs_crypt_real_announce >/dev/null; then
        _premium_zfs_crypt_real_announce || return $?
        overridden=true
    fi
    [[ "$overridden" == true ]] && return 0

    local feature=""
    if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
        feature="Host-level LUKS encryption"
    elif [[ "${PVE_ZFS_ENCRYPTION:-false}" == true ]]; then
        feature="ZFS native encryption of VM data"
    fi
    if [[ -n "$feature" ]]; then
        echo ""
        ui_warn "${feature} is a PREMIUM feature."
        ui_info "This public build does not include the encryption premium modules."
        ui_info "Get premium access at: https://corelix.io/pve-dedicated-premium"
        echo ""
        if [[ "${PVE_UNATTENDED:-false}" != true ]]; then
            if ! ui_confirm "Continue without encryption?" "y"; then
                die "Installation cancelled by user (encryption premium not available)."
            fi
        fi
        PVE_FEATURE_LUKS=false
        PVE_ZFS_ENCRYPTION=false
    fi
}
