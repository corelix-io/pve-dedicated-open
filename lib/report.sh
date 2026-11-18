# Final installation report generation
# shellcheck shell=bash

report_generate() {
    local status="${1:-SUCCESS}"
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local report_file="${working_dir}/logs/install-report.txt"
    local elapsed
    elapsed="$(log_elapsed)"

    mkdir -p "$(dirname "$report_file")"

    local rendered
    rendered="$(_report_render "$status" "$elapsed")"
    printf '%s\n' "$rendered"
    printf '%s\n' "$rendered" | _ui_strip_color > "$report_file"

    log_info "Report saved to ${report_file}"
}

_report_render() {
    local status="$1"
    local elapsed="$2"

    local status_color="$CLR_GREEN"
    local status_icon="$CHECK_MARK"
    if [[ "$status" != "SUCCESS" ]]; then
        status_color="$CLR_RED"
        status_icon="$CROSS_MARK"
    fi

    local disk_info
    disk_info="$(disk_summary 2>/dev/null || echo "N/A")"

    local iface="${PVE_PREDICTED_IFACE:-${PVE_INTERFACE:-unknown}}"
    local public_ip="${PVE_MAIN_IPV4_CIDR:-unknown}"
    local ip_bare="${PVE_MAIN_IPV4:-${public_ip%/*}}"
    local gateway="${PVE_MAIN_IPV4_GW:-unknown}"

    echo ""
    ui_box_start "PROXMOX VE INSTALLATION REPORT"

    ui_box_kv "Status" "${status_color}${status_icon} ${status}${CLR_RESET}"
    ui_box_kv "Duration" "$elapsed"
    ui_box_kv "Installer" "v${PVE_INSTALLER_VERSION}"
    if [[ -n "${PVE_ISO_NAME:-}" ]]; then
        ui_box_kv "Proxmox ISO" "$PVE_ISO_NAME"
    fi

    ui_box_row ""
    ui_box_row "${CLR_BOLD}SYSTEM${CLR_RESET}"
    ui_box_row "  ${CLR_DIM}$(_ui_repeat 30 "$BOX_H")${CLR_RESET}"
    ui_box_kv "Hostname" "${PVE_FQDN:-unknown}"
    ui_box_kv "Boot Mode" "${PVE_BOOT_MODE:-unknown}"
    ui_box_kv "Disks" "$disk_info"
    ui_box_kv "Filesystem" "${PVE_FILESYSTEM:-unknown}"
    if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
        ui_box_kv "Encryption" "LUKS (modes: ${PVE_LUKS_UNLOCK_MODES:-passphrase})"
    elif [[ "${PVE_ZFS_ENCRYPTION:-false}" == true ]]; then
        ui_box_kv "Encryption" "ZFS native (modes: ${PVE_ZFS_UNLOCK_MODES:-passphrase})"
        ui_box_row "  After reboot, if not automatic: pve-zfs-crypt unlock --start-guests"
    fi

    ui_box_row ""
    ui_box_row "${CLR_BOLD}NETWORK${CLR_RESET}"
    ui_box_row "  ${CLR_DIM}$(_ui_repeat 30 "$BOX_H")${CLR_RESET}"
    ui_box_kv "Interface" "$iface"
    ui_box_kv "Public IP" "$public_ip"
    ui_box_kv "Gateway" "$gateway"
    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        ui_box_kv "IPv6" "$PVE_IPV6_CIDR"
    fi
    if [[ -n "$PVE_PRIVATE_IP_CIDR" ]]; then
        ui_box_kv "Private Bridge" "${PVE_PRIVATE_IP_CIDR} (vmbr1)"
    fi
    if [[ "${PVE_ENABLE_DHCP:-false}" == true ]] && [[ "$PVE_NETWORK_MODE" == "nat" ]]; then
        local _dhcp_pfx
        _dhcp_pfx="$(echo "$PVE_PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)"
        ui_box_kv "DHCP (vmbr1)" "${_dhcp_pfx}.100-.200 (dnsmasq)"
    fi

    ui_box_row ""
    ui_box_row "${CLR_BOLD}ACCESS${CLR_RESET}"
    ui_box_row "  ${CLR_DIM}$(_ui_repeat 30 "$BOX_H")${CLR_RESET}"
    ui_box_kv "Web UI" "https://${ip_bare}:8006"
    ui_box_kv "SSH" "ssh root@${ip_bare}"
    if [[ -n "$PVE_SSH_KEYS" ]]; then
        ui_box_kv "SSH Auth" "key-only (password disabled)"
    else
        ui_box_kv "SSH Auth" "${CLR_YELLOW}password (not hardened)${CLR_RESET}"
    fi

    ui_box_row ""
    ui_box_row "${CLR_RED}${CLR_BOLD}SECURITY -- ACTION REQUIRED${CLR_RESET}"
    ui_box_row "  ${CLR_DIM}$(_ui_repeat 30 "$BOX_H")${CLR_RESET}"
    ui_box_row "  ${CLR_RED}Ports 22 (SSH) and 8006 (Web UI) are exposed!${CLR_RESET}"
    ui_box_row "  Set up IP filtering BEFORE going to production."
    ui_box_row ""

    # Provider-specific guidance
    local notes
    notes="$(provider_post_install_notes 2>/dev/null || true)"
    if [[ -n "$notes" ]]; then
        ui_box_row "  ${CLR_BOLD}Provider next steps (${PVE_PROVIDER}):${CLR_RESET}"
        while IFS= read -r line; do
            ui_box_row "  $line"
        done <<< "$notes"
        ui_box_row ""
    fi

    ui_box_row "  ${CLR_BOLD}Proxmox built-in firewall (additional layer):${CLR_RESET}"
    ui_box_row "    Datacenter > Firewall > Add rules for SSH/HTTPS"
    ui_box_row "    Enable at Datacenter + Node level"

    ui_box_row ""
    ui_box_row "${CLR_BOLD}NEXT STEPS${CLR_RESET}"
    ui_box_row "  ${CLR_DIM}$(_ui_repeat 30 "$BOX_H")${CLR_RESET}"
    ui_box_row "  1. Reboot from your provider's control panel"
    ui_box_row "  2. Configure provider edge firewall (see above)"
    ui_box_row "  3. Access web UI and login as root"
    ui_box_row "  4. Verify: ip addr, zpool status"
    ui_box_row "  5. Enable Proxmox firewall"
    ui_box_row "  6. Set up backup schedule"

    # Premium upsell when LUKS is not active in this build
    if [[ "${PVE_FEATURE_LUKS:-false}" != true ]] && [[ "${PVE_ZFS_ENCRYPTION:-false}" != true ]]; then
        ui_box_row ""
        ui_box_row "${CLR_BOLD}${CLR_MAGENTA}PREMIUM${CLR_RESET}"
        ui_box_row "  Want encryption (LUKS or ZFS native, TPM/Tang auto-unlock)?"
        ui_box_row "  ${CLR_CYAN}https://corelix.io/pve-dedicated-premium${CLR_RESET}"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        ui_box_row ""
        ui_box_kv "Log file" "$LOG_FILE"
    fi

    ui_box_row ""
    ui_box_row "  ${CLR_DIM}Provided freely by Corelix.io - Made in France${CLR_RESET}"

    ui_box_end
}

report_prompt_reboot() {
    echo ""
    echo -e "  ${CLR_YELLOW}${CLR_BOLD}How to reboot into Proxmox:${CLR_RESET}"
    echo ""

    case "${PVE_PROVIDER:-}" in
        hetzner)
            echo -e "  ${CLR_WHITE}Option A (recommended):${CLR_RESET} Hetzner Robot Panel"
            echo -e "    ${CLR_DIM}robot.hetzner.com > Server > Reset > 'Execute an automatic hardware reset'${CLR_RESET}"
            ;;
        ovh)
            echo -e "  ${CLR_WHITE}Option A (recommended):${CLR_RESET} OVH Control Panel"
            echo -e "    ${CLR_DIM}1. Bare Metal Cloud > Server > Boot > 'Boot from the hard disk'${CLR_RESET}"
            echo -e "    ${CLR_DIM}2. Bare Metal Cloud > Server > Status > Restart${CLR_RESET}"
            ;;
        *)
            echo -e "  ${CLR_WHITE}Option A (recommended):${CLR_RESET} Use your provider's control panel to reboot"
            ;;
    esac
    echo -e "  ${CLR_WHITE}Option B:${CLR_RESET} Try shell reboot (may not work in rescue)"
    echo ""

    if [[ "${PVE_UNATTENDED:-false}" == true ]]; then
        ui_info "Unattended mode: not rebooting. Reboot via your provider's panel."
        return 0
    fi

    if ui_confirm "Attempt shell reboot now?" "n"; then
        ui_info "Rebooting in 5 seconds..."
        ui_countdown 5 "Rebooting"
        sync
        reboot
    else
        echo ""
        ui_info "Reboot via your provider's panel when ready."
        echo ""
    fi
}

# Escape a string for inclusion in a JSON document (fallback without jq).
_report_json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\t'/\\t}"
    printf '"%s"' "$v"
}

# Generate a machine-readable JSON report
report_generate_json() {
    local status="${1:-SUCCESS}"
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local json_file="${working_dir}/logs/install-report.json"
    local elapsed_s timestamp luks=false zfs_crypt=false
    elapsed_s="$(log_elapsed_seconds)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
        luks=true
    fi
    if [[ "${PVE_ZFS_ENCRYPTION:-false}" == true ]]; then
        zfs_crypt=true
    fi

    local -a fields=(
        status "$status"
        version "$PVE_INSTALLER_VERSION"
        provider "${PVE_PROVIDER:-unknown}"
        timestamp "$timestamp"
        iso "${PVE_ISO_NAME:-}"
        hostname "$PVE_HOSTNAME"
        fqdn "$PVE_FQDN"
        boot_mode "$PVE_BOOT_MODE"
        filesystem "$PVE_FILESYSTEM"
        zfs_raid "$PVE_ZFS_RAID"
        disks "${SELECTED_DISKS[*]}"
        network_mode "$PVE_NETWORK_MODE"
        interface "${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}"
        ipv4 "$PVE_MAIN_IPV4_CIDR"
        gateway "$PVE_MAIN_IPV4_GW"
        ipv6 "$PVE_IPV6_CIDR"
        mac "$PVE_MAC_ADDRESS"
        private_subnet "$PVE_PRIVATE_SUBNET"
        web_ui "https://${PVE_MAIN_IPV4}:8006"
        ssh "ssh root@${PVE_MAIN_IPV4}"
    )

    mkdir -p "$(dirname "$json_file")"
    local i
    if command -v jq >/dev/null 2>&1; then
        local -a jq_args=()
        for (( i = 0; i < ${#fields[@]}; i += 2 )); do
            jq_args+=(--arg "${fields[i]}" "${fields[i+1]}")
        done
        # shellcheck disable=SC2016
        jq -n "${jq_args[@]}" \
            --argjson elapsed "${elapsed_s:-0}" --argjson luks "$luks" \
            --argjson zfs_crypt "$zfs_crypt" '{
                status: $status, version: $version, provider: $provider,
                premium_features: {luks: $luks, zfs_encryption: $zfs_crypt},
                elapsed_seconds: $elapsed, timestamp: $timestamp, iso: $iso,
                system: {hostname: $hostname, fqdn: $fqdn, boot_mode: $boot_mode,
                         filesystem: $filesystem, zfs_raid: $zfs_raid, disks: $disks},
                network: {mode: $network_mode, interface: $interface, ipv4: $ipv4,
                          gateway: $gateway, ipv6: $ipv6, mac: $mac,
                          private_subnet: $private_subnet},
                access: {web_ui: $web_ui, ssh: $ssh}
            }' > "$json_file"
    else
        local sep=""
        {
            echo "{"
            for (( i = 0; i < ${#fields[@]}; i += 2 )); do
                printf '%s  %s: %s' "$sep" "$(_report_json_escape "${fields[i]}")" "$(_report_json_escape "${fields[i+1]}")"
                sep=$',\n'
            done
            printf ',\n  "elapsed_seconds": %d,\n  "premium_features": {"luks": %s, "zfs_encryption": %s}\n}\n' \
                "${elapsed_s:-0}" "$luks" "$zfs_crypt"
        } > "$json_file"
    fi

    log_info "JSON report saved to ${json_file}"
}
