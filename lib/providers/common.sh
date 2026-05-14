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
#                                    to stdout for the current PVE_* state
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

    # Apply provider DNS defaults if user did not override
    local default_dns
    default_dns="$(provider_default_dns)"
    if [[ -n "$default_dns" ]] && [[ "$PVE_DNS_SERVERS" == "185.12.64.1 185.12.64.2" || -z "$PVE_DNS_SERVERS" ]]; then
        PVE_DNS_SERVERS="$default_dns"
        log_debug "Provider ${PVE_PROVIDER} default DNS: ${PVE_DNS_SERVERS}"
    fi

    log_info "Active provider: ${PVE_PROVIDER}"
}

provider_interactive_select() {
    echo ""
    ui_section "Provider Selection"
    echo -e "  ${CLR_DIM}Choose the cloud provider where this server is hosted.${CLR_RESET}"
    echo ""
    local idx=1
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
    "${PVE_PROVIDER}_render_interfaces"
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

# --- Premium feature gate stubs (overridden by lib/premium/*.sh in private) -

# Public default: announce premium availability with a CTA and continue.
# In premium builds, lib/premium/luks_common.sh overrides this with the real
# pre-flight that also handles --enable-luks.
premium_announce_cta() {
    if declare -F _premium_luks_real_announce >/dev/null; then
        _premium_luks_real_announce
        return $?
    fi

    if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
        echo ""
        ui_warn "Host-level LUKS encryption is a PREMIUM feature."
        ui_info "This public build does not include the LUKS premium module."
        ui_info "Get premium access at: https://corelix.io/pve-dedicated-premium"
        echo ""
        if [[ "${PVE_UNATTENDED:-false}" != true ]]; then
            if ! ui_confirm "Continue without LUKS encryption?" "y"; then
                die "Installation cancelled by user (LUKS premium not available)."
            fi
        fi
        PVE_FEATURE_LUKS=false
    fi
}
