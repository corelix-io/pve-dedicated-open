# Legacy SSH-based post-install configuration (fallback when first-boot hooks unavailable)
# shellcheck shell=bash

readonly SSH_PORT=5555
# The guest is a throwaway VM on a loopback-only port forward; its host key
# is new on every install, so it is not pinned.
readonly -a SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

sshcfg_configure() {
    log_info "Starting SSH-based post-install configuration..."

    if [[ -n "$PVE_ROOT_PASSWORD" ]] && ! command -v sshpass &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -yq sshpass >>"${LOG_FILE:-/dev/null}" 2>&1 \
            || log_warn "sshpass unavailable; you will be prompted for the root password"
    fi

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

    cat > "${tpl_dir}/90-pve-dedicated.conf" <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL
    ui_success "Generated sysctl config"

    firstboot_render_resolv > "${tpl_dir}/resolv.conf"
    echo "$PVE_HOSTNAME" > "${tpl_dir}/hostname"
}

# Execute SSH/SCP command with password
_sshcfg_ssh() {
    local -a ssh_cmd=(ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" "root@127.0.0.1")
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
    local -a scp_cmd=(scp -P "$SSH_PORT" "${SSH_OPTS[@]}" "$src" "root@127.0.0.1:${dst}")
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
        "${tpl_dir}/90-pve-dedicated.conf|/etc/sysctl.d/90-pve-dedicated.conf"
        "${tpl_dir}/resolv.conf|/etc/resolv.conf"
        "${tpl_dir}/hostname|/etc/hostname"
    )

    local entry src dst
    for entry in "${uploads[@]}"; do
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
    # shellcheck disable=SC2016
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
    local ceph_release="ceph-tentacle"
    [[ "$PVE_DEBIAN_SUITE" == "bookworm" ]] && ceph_release="ceph-squid"
    _sshcfg_ssh "echo 'deb http://download.proxmox.com/debian/pve ${PVE_DEBIAN_SUITE} pve-no-subscription' \
        > /etc/apt/sources.list.d/pve-no-subscription.list && \
        echo 'deb http://download.proxmox.com/debian/${ceph_release} ${PVE_DEBIAN_SUITE} no-subscription' \
        > /etc/apt/sources.list.d/ceph-no-subscription.list" \
        2>/dev/null || true

    # Backup and clear sources.list
    _sshcfg_ssh 'if [ -s /etc/apt/sources.list ]; then mv /etc/apt/sources.list /etc/apt/sources.list.bak; fi' \
        2>/dev/null || true

    # Disable unnecessary services
    _sshcfg_ssh "systemctl disable --now rpcbind rpcbind.socket" 2>/dev/null || true

    # Remove subscription nag
    # shellcheck disable=SC2016
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
