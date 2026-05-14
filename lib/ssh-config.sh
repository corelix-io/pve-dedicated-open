# Legacy SSH-based post-install configuration (fallback when first-boot hooks unavailable)
# shellcheck shell=bash

readonly SSH_PORT=5555
readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

sshcfg_configure() {
    log_info "Starting SSH-based post-install configuration..."

    # Clean up any stale host keys
    ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "[localhost]:${SSH_PORT}" 2>/dev/null || true

    # Generate template files
    sshcfg_generate_templates

    # Upload configuration files
    sshcfg_upload_files

    # Execute remote commands
    sshcfg_run_commands

    # Shutdown the VM
    sshcfg_shutdown

    ui_success "SSH-based configuration complete"
}

sshcfg_generate_templates() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local tpl_dir="${working_dir}/generated"

    mkdir -p "$tpl_dir"

    # Generate interfaces file
    firstboot_render_interfaces > "${tpl_dir}/interfaces"
    ui_success "Generated network interfaces"

    # Generate hosts file
    firstboot_render_hosts > "${tpl_dir}/hosts"
    ui_success "Generated hosts file"

    # Generate sysctl config
    cat > "${tpl_dir}/99-proxmox.conf" <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL
    ui_success "Generated sysctl config"
}

# Execute SSH/SCP command with password
_sshcfg_ssh() {
    local -a ssh_cmd=(ssh -p "$SSH_PORT" $SSH_OPTS "root@localhost")
    if [[ -n "$PVE_ROOT_PASSWORD" ]]; then
        if command -v sshpass &>/dev/null; then
            SSHPASS="$PVE_ROOT_PASSWORD" sshpass -e "${ssh_cmd[@]}" "$@"
        else
            "${ssh_cmd[@]}" "$@"
        fi
    else
        "${ssh_cmd[@]}" "$@"
    fi
}

_sshcfg_scp() {
    local src="$1"
    local dst="$2"
    local -a scp_cmd=(scp -P "$SSH_PORT" $SSH_OPTS "$src" "root@localhost:${dst}")
    if [[ -n "$PVE_ROOT_PASSWORD" ]]; then
        if command -v sshpass &>/dev/null; then
            SSHPASS="$PVE_ROOT_PASSWORD" sshpass -e "${scp_cmd[@]}"
        else
            "${scp_cmd[@]}"
        fi
    else
        "${scp_cmd[@]}"
    fi
}

sshcfg_upload_files() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local tpl_dir="${working_dir}/generated"

    ui_spinner_start "Uploading configuration files"

    local -a uploads=(
        "${tpl_dir}/hosts|/etc/hosts"
        "${tpl_dir}/interfaces|/etc/network/interfaces"
        "${tpl_dir}/99-proxmox.conf|/etc/sysctl.d/99-proxmox.conf"
    )

    for entry in "${uploads[@]}"; do
        local src dst
        IFS='|' read -r src dst <<< "$entry"
        if [[ -f "$src" ]]; then
            _sshcfg_scp "$src" "$dst" || {
                ui_spinner_stop false
                die "Failed to upload ${src} to ${dst}"
            }
            log_debug "Uploaded ${src} -> ${dst}"
        fi
    done

    ui_spinner_stop true
}

sshcfg_run_commands() {
    ui_spinner_start "Applying remote configuration"

    # Disable all enterprise repos (PVE + Ceph, both .list and .sources formats)
    _sshcfg_ssh 'for f in /etc/apt/sources.list.d/pve-enterprise.list \
        /etc/apt/sources.list.d/pve-enterprise.sources \
        /etc/apt/sources.list.d/ceph.list \
        /etc/apt/sources.list.d/ceph.sources; do \
        [ -f "$f" ] && mv "$f" "${f}.disabled"; done; \
        for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do \
        [ -f "$f" ] && grep -q "enterprise.proxmox.com" "$f" 2>/dev/null && \
        mv "$f" "${f}.disabled"; done' \
        2>/dev/null || true

    # Add no-subscription repos
    _sshcfg_ssh "echo 'deb http://download.proxmox.com/debian/pve ${PVE_DEBIAN_SUITE} pve-no-subscription' \
        > /etc/apt/sources.list.d/pve-no-subscription.list && \
        echo 'deb http://download.proxmox.com/debian/ceph-squid ${PVE_DEBIAN_SUITE} no-subscription' \
        > /etc/apt/sources.list.d/ceph-no-subscription.list" \
        2>/dev/null || true

    # Backup and clear sources.list
    _sshcfg_ssh "[ -f /etc/apt/sources.list ] && [ -s /etc/apt/sources.list ] && \
        mv /etc/apt/sources.list /etc/apt/sources.list.bak" \
        2>/dev/null || true

    # Set DNS resolvers
    local dns_content=""
    for dns in $PVE_DNS_SERVERS; do
        dns_content+="nameserver ${dns}\n"
    done
    _sshcfg_ssh "echo -e '${dns_content}' > /etc/resolv.conf" 2>/dev/null || true

    # Set hostname
    _sshcfg_ssh "echo '${PVE_HOSTNAME}' > /etc/hostname" 2>/dev/null || true

    # Disable unnecessary services
    _sshcfg_ssh "systemctl disable --now rpcbind rpcbind.socket" 2>/dev/null || true

    # Remove subscription nag
    _sshcfg_ssh 'PROXMOXLIB="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"; \
        [ -f "$PROXMOXLIB" ] && sed -Ezi.bak \
        "s/(Ext.Msg.show\(\{\s+title: gettext\('"'"'No valid sub)/void\(\{ \/\/\1/g" \
        "$PROXMOXLIB" && systemctl restart pveproxy.service' \
        2>/dev/null || true

    ui_spinner_stop true
}

sshcfg_shutdown() {
    ui_info "Shutting down configuration VM..."

    _sshcfg_ssh "poweroff" 2>/dev/null || true

    # Wait for QEMU to exit
    if [[ -n "$QEMU_PID" ]]; then
        local waited=0
        while kill -0 "$QEMU_PID" 2>/dev/null && (( waited < 60 )); do
            printf "\r  ${CLR_DIM}Waiting for VM shutdown... %ds${CLR_RESET}" "$waited"
            sleep 2
            waited=$(( waited + 2 ))
        done
        printf "\r\033[K"

        if kill -0 "$QEMU_PID" 2>/dev/null; then
            log_warn "VM did not shut down, forcing..."
            kill -TERM "$QEMU_PID" 2>/dev/null || true
            sleep 2
            kill -9 "$QEMU_PID" 2>/dev/null || true
        fi

        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi

    ui_success "Configuration VM stopped"
}
