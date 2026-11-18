# answer.toml generation for Proxmox auto-installer
# shellcheck shell=bash

# Escape a value for a TOML basic (double-quoted) string.
answer_toml_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# SHA-512 crypt hash of the root password, so the plaintext never lands in
# answer.toml or the prepared ISO. Empty output when no hasher is available.
answer_hash_password() {
    local pass="$1"
    if command -v openssl >/dev/null 2>&1; then
        printf '%s\n' "$pass" | openssl passwd -6 -stdin 2>/dev/null && return 0
    fi
    if command -v mkpasswd >/dev/null 2>&1; then
        printf '%s\n' "$pass" | mkpasswd --method=sha-512 --stdin 2>/dev/null && return 0
    fi
    return 1
}

# Render the root-ssh-keys TOML array from the newline-separated key list.
answer_render_ssh_keys() {
    local keys="$1"
    local line out="" first=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$first" == true ]]; then
            first=false
        else
            out+=","
        fi
        out+=$'\n'"        \"$(answer_toml_escape "$line")\""
    done <<< "$keys"
    [[ "$first" == true ]] && return 0
    printf 'root-ssh-keys = [%s\n    ]' "$out"
}

answer_generate() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local output_dir="${working_dir}/generated"
    local output_file="${output_dir}/answer.toml"

    mkdir -p "$output_dir"
    chmod 700 "$output_dir"

    log_info "Generating answer.toml..."

    local disk_list
    disk_list="$(disk_build_answer_list)"

    local password_field hashed
    if hashed="$(answer_hash_password "$PVE_ROOT_PASSWORD")" && [[ "$hashed" == "\$6\$"* ]]; then
        password_field="root-password-hashed = \"$(answer_toml_escape "$hashed")\""
    else
        log_warn "openssl/mkpasswd unavailable; storing the root password in plaintext in answer.toml"
        password_field="root-password = \"$(answer_toml_escape "$PVE_ROOT_PASSWORD")\""
    fi

    local ssh_keys_block=""
    if [[ -n "$PVE_SSH_KEYS" ]]; then
        ssh_keys_block="$(answer_render_ssh_keys "$PVE_SSH_KEYS")"
    fi

    local zfs_block=""
    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        zfs_block="zfs.raid = \"${PVE_ZFS_RAID}\""
        if [[ -n "$PVE_ZFS_COMPRESS" ]]; then
            zfs_block+=$'\n'"    zfs.compress = \"${PVE_ZFS_COMPRESS}\""
        fi
        if [[ -n "$PVE_ZFS_ASHIFT" ]]; then
            zfs_block+=$'\n'"    zfs.ashift = $(( 10#$PVE_ZFS_ASHIFT ))"
        fi
        if [[ -n "$PVE_ZFS_ARC_MAX" ]]; then
            zfs_block+=$'\n'"    zfs.arc-max = $(( 10#$PVE_ZFS_ARC_MAX ))"
        fi
    fi

    (
        umask 077
        cat > "$output_file" <<TOML
[global]
    keyboard = "$(answer_toml_escape "$PVE_KEYBOARD")"
    country = "$(answer_toml_escape "$PVE_COUNTRY")"
    fqdn = "$(answer_toml_escape "$PVE_FQDN")"
    mailto = "$(answer_toml_escape "$PVE_EMAIL")"
    timezone = "$(answer_toml_escape "$PVE_TIMEZONE")"
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

        if [[ -f "${output_dir}/first-boot.sh" ]]; then
            cat >> "$output_file" <<TOML

[first-boot]
    source = "from-iso"
    ordering = "fully-up"
TOML
        fi
    )
    chmod 600 "$output_file"

    if [[ "${LOG_LEVEL}" -le "$LOG_LEVEL_DEBUG" ]]; then
        log_debug "answer.toml contents:"
        local line
        sed -E 's/^([[:space:]]*root-password(-hashed)?[[:space:]]*=).*/\1 "[REDACTED]"/' "$output_file" \
            | while IFS= read -r line; do
                log_debug "  $line"
            done
    fi

    if command -v proxmox-auto-install-assistant &>/dev/null; then
        local validation
        if validation="$(proxmox-auto-install-assistant validate-answer "$output_file" 2>&1)"; then
            ui_success "answer.toml generated and validated"
        else
            log_error "answer.toml validation failed:"
            local line
            while IFS= read -r line; do
                log_error "  ${line}"
            done <<< "$validation"
            die "Generated answer.toml is invalid; fix the reported values and retry"
        fi
    else
        ui_success "answer.toml generated"
    fi
}

# Display the answer config summary (without password)
answer_show_summary() {
    ui_section "Installation Configuration"
    ui_kv "Provider" "$PVE_PROVIDER"
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
    if [[ "$PVE_NETWORK_MODE" == "nat" ]]; then
        ui_kv "Private Subnet" "${PVE_PRIVATE_SUBNET:-none}"
        ui_kv "DHCP (vmbr1)" "${PVE_ENABLE_DHCP}"
    fi
    if [[ "$PVE_NETWORK_MODE" == "routed" ]] && [[ -n "$PVE_ADDITIONAL_IPS" ]]; then
        ui_kv "Routed IPs" "$PVE_ADDITIONAL_IPS"
    fi
    if [[ -n "${PVE_HETZNER_VSWITCH_VLAN:-}" ]]; then
        ui_kv "vSwitch" "VLAN ${PVE_HETZNER_VSWITCH_VLAN} ${PVE_HETZNER_VSWITCH_IP:-(no host IP)}${PVE_HETZNER_VSWITCH_ROUTES:+ -> ${PVE_HETZNER_VSWITCH_ROUTES}}"
    fi
    ui_kv "DNS" "$PVE_DNS_SERVERS"
    ui_kv "Boot Mode" "$PVE_BOOT_MODE"
    ui_kv "Interface" "${PVE_PREDICTED_IFACE:-${PVE_INTERFACE}} (MAC ${PVE_MAC_ADDRESS:-?})"
    if [[ -n "$PVE_SSH_KEYS" ]]; then
        ui_kv "SSH Keys" "$(grep -c . <<< "$PVE_SSH_KEYS") key(s), password login disabled"
    else
        ui_kv "SSH Keys" "none (password login stays enabled)"
    fi
}
