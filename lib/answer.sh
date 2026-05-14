# answer.toml generation for Proxmox auto-installer
# shellcheck shell=bash

answer_generate() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local output_dir="${working_dir}/generated"
    local output_file="${output_dir}/answer.toml"

    mkdir -p "$output_dir"

    log_info "Generating answer.toml..."

    local disk_list
    disk_list="$(disk_build_answer_list)"

    local password_field
    password_field="root-password = \"${PVE_ROOT_PASSWORD}\""

    local ssh_keys_block=""
    if [[ -n "$PVE_SSH_KEYS" ]]; then
        ssh_keys_block="root-ssh-keys = ["
        local first=true
        for key in $PVE_SSH_KEYS; do
            if [[ "$first" == true ]]; then
                ssh_keys_block+=$'\n'"    \"${key}\""
                first=false
            else
                ssh_keys_block+=","$'\n'"    \"${key}\""
            fi
        done
        ssh_keys_block+=$'\n'"]"
    fi

    local zfs_block=""
    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        zfs_block="zfs.raid = \"${PVE_ZFS_RAID}\""
        [[ -n "$PVE_ZFS_COMPRESS" ]] && zfs_block+=$'\n'"    zfs.compress = \"${PVE_ZFS_COMPRESS}\""
        [[ -n "$PVE_ZFS_ASHIFT" ]]   && zfs_block+=$'\n'"    zfs.ashift = ${PVE_ZFS_ASHIFT}"
        [[ -n "$PVE_ZFS_ARC_MAX" ]]  && zfs_block+=$'\n'"    zfs.arc-max = ${PVE_ZFS_ARC_MAX}"
    fi

    cat > "$output_file" <<TOML
[global]
    keyboard = "${PVE_KEYBOARD}"
    country = "${PVE_COUNTRY}"
    fqdn = "${PVE_FQDN}"
    mailto = "${PVE_EMAIL}"
    timezone = "${PVE_TIMEZONE}"
    ${password_field}
    reboot-on-error = false
${ssh_keys_block:+    ${ssh_keys_block}}

[network]
    source = "from-dhcp"

[disk-setup]
    filesystem = "${PVE_FILESYSTEM}"
    ${zfs_block}
    disk-list = ${disk_list}
TOML

    # Add first-boot section if supported
    local firstboot_file="${working_dir}/generated/first-boot.sh"
    if [[ -f "$firstboot_file" ]]; then
        cat >> "$output_file" <<TOML

[first-boot]
    source = "from-iso"
    ordering = "fully-up"
TOML
    fi

    log_debug "answer.toml contents:"
    if [[ "${LOG_LEVEL}" -le "$LOG_LEVEL_DEBUG" ]]; then
        # Redact password in debug output
        sed 's/root-password = ".*"/root-password = "[REDACTED]"/' "$output_file" | while IFS= read -r line; do
            log_debug "  $line"
        done
    fi

    # Validate answer file if tool is available
    if command -v proxmox-auto-install-assistant &>/dev/null; then
        if proxmox-auto-install-assistant validate-answer "$output_file" >/dev/null 2>&1; then
            ui_success "answer.toml generated and validated"
        else
            log_warn "answer.toml validation returned warnings (may still work)"
            ui_warn "answer.toml has validation warnings"
        fi
    else
        ui_success "answer.toml generated"
    fi
}

# Display the answer config summary (without password)
answer_show_summary() {
    ui_section "Installation Configuration"
    ui_kv "Hostname" "$PVE_FQDN"
    ui_kv "Timezone" "$PVE_TIMEZONE"
    ui_kv "Keyboard" "$PVE_KEYBOARD"
    ui_kv "Email" "$PVE_EMAIL"
    ui_kv "Filesystem" "$PVE_FILESYSTEM"
    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        ui_kv "ZFS RAID" "$PVE_ZFS_RAID"
        if [[ -n "$PVE_ZFS_COMPRESS" ]]; then
            ui_kv "ZFS Compress" "$PVE_ZFS_COMPRESS"
        fi
    fi
    ui_kv "Disks" "${SELECTED_DISKS[*]}"
    ui_kv "Network Mode" "$PVE_NETWORK_MODE"
    ui_kv "Public IP" "${PVE_MAIN_IPV4_CIDR:-auto}"
    ui_kv "Private Subnet" "${PVE_PRIVATE_SUBNET:-none}"
    if [[ "$PVE_NETWORK_MODE" == "nat" ]]; then
        ui_kv "DHCP (vmbr1)" "${PVE_ENABLE_DHCP}"
    fi
    ui_kv "Boot Mode" "$PVE_BOOT_MODE"
    ui_kv "Interface" "${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}}"
    if [[ -n "$PVE_SSH_KEYS" ]]; then
        ui_kv "SSH Keys" "configured"
    fi
}
