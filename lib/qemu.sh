# QEMU orchestrator: launch, serial console, monitor, progress parsing
# shellcheck shell=bash

declare -g QEMU_PID=""
declare -g QEMU_MONITOR_SOCK=""
declare -g QEMU_SERIAL_LOG=""
declare -g QEMU_CONFIG_LOG=""
declare -ga QEMU_FW_ARGS=()

# Overridable for very slow disks (large HDD raidz) via the environment.
readonly QEMU_INSTALL_TIMEOUT="${PVE_QEMU_INSTALL_TIMEOUT:-2400}"
readonly QEMU_BOOT_TIMEOUT="${PVE_QEMU_BOOT_TIMEOUT:-300}"
readonly QEMU_SSH_PORT=5555

# Populate QEMU_FW_ARGS for the detected boot mode. UEFI uses a read-only
# OVMF code image plus a private, writable copy of the NVRAM template.
qemu_firmware_args() {
    QEMU_FW_ARGS=()
    [[ "$PVE_BOOT_MODE" == "uefi" ]] || return 0

    local spec kind code vars
    spec="$(hw_find_uefi_firmware)" || die "UEFI firmware (OVMF) not found. Install it: apt install ovmf"
    IFS='|' read -r kind code vars <<< "$spec"

    if [[ "$kind" == "pflash" ]]; then
        local vars_copy="${PVE_WORKING_DIR:-/root}/generated/OVMF_VARS.fd"
        mkdir -p "$(dirname "$vars_copy")"
        if [[ ! -f "$vars_copy" ]]; then
            cp "$vars" "$vars_copy" || die "Cannot copy OVMF NVRAM template ${vars}"
        fi
        QEMU_FW_ARGS=(
            -drive "if=pflash,format=raw,unit=0,readonly=on,file=${code}"
            -drive "if=pflash,format=raw,unit=1,file=${vars_copy}"
        )
    else
        QEMU_FW_ARGS=(-bios "$code")
    fi
    log_debug "UEFI firmware: ${kind} ${code} ${vars}"
}

# Run the installation QEMU with progress monitoring
qemu_run_install() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local iso_file="${working_dir}/pve-autoinstall.iso"
    local log_dir="${working_dir}/logs"

    [[ -f "$iso_file" ]] || die "Auto-install ISO not found: ${iso_file}"

    mkdir -p "$log_dir"

    QEMU_SERIAL_LOG="${log_dir}/qemu-install-serial.log"
    QEMU_MONITOR_SOCK="/run/pve-dedicated-qemu-$$.sock"
    : > "$QEMU_SERIAL_LOG"
    cleanup_register_monitor "$QEMU_MONITOR_SOCK"

    qemu_firmware_args
    disk_build_qemu_args

    local -a cmd=(
        qemu-system-x86_64
        -name pve-dedicated-install
        -enable-kvm
        -cpu host
        -smp "${PVE_QEMU_CPUS:-4}"
        -m "${PVE_QEMU_RAM_MB:-4096}"
        "${QEMU_FW_ARGS[@]}"
        -boot d
        -cdrom "$iso_file"
        "${QEMU_DISK_ARGS[@]}"
        -netdev "user,id=net0"
        -device "virtio-net-pci,netdev=net0,romfile="
        -serial "file:${QEMU_SERIAL_LOG}"
        -monitor "unix:${QEMU_MONITOR_SOCK},server,nowait"
        -no-reboot
        -display none
    )

    log_info "Starting QEMU installation..."
    log_debug "QEMU command: ${cmd[*]}"

    "${cmd[@]}" >>"${LOG_FILE:-/dev/null}" 2>&1 &
    QEMU_PID=$!
    cleanup_register_qemu "$QEMU_PID"

    ui_info "QEMU started (PID: ${QEMU_PID})"
    ui_info "Serial log: ${QEMU_SERIAL_LOG}"
    echo ""

    qemu_monitor_install
}

# Pure helper: map serial log content (stdin) to the furthest phase seen.
# Echoes "<n>|<label>"; n=0 when nothing matched yet.
qemu_detect_phase() {
    local content
    content="$(cat)"
    local -a phases=(
        "6|Installation complete|installation.*(successful|complete|finished)"
        "5|Configuring system|post.install|running.*hook|first.boot"
        "4|Installing packages|installing.*packages|apt.*install|configuring.*packages"
        "3|Installing base system|installing.*base|debootstrap|extracting"
        "2|Creating filesystems|creating.*zpool|creating.*filesystem|formatting|partitioning"
        "1|Starting automated installation|starting installation|auto.install|automated installation"
    )
    local entry n label re
    for entry in "${phases[@]}"; do
        n="${entry%%|*}"
        label="${entry#*|}"; label="${label%%|*}"
        re="${entry#*|*|}"
        if grep -qiE "$re" <<< "$content"; then
            echo "${n}|${label}"
            return 0
        fi
    done
    echo "0|Waiting for installer to start"
}

# Monitor the serial log for installation progress
qemu_monitor_install() {
    local start_time
    start_time="$(date +%s)"
    local last_phase="Waiting for installer to start"
    local phase_num=0

    ui_info "Monitoring installation progress (timeout: $(( QEMU_INSTALL_TIMEOUT / 60 )) min)..."
    echo ""

    while kill -0 "$QEMU_PID" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_time ))

        if (( elapsed > QEMU_INSTALL_TIMEOUT )); then
            log_error "Installation timed out after ${QEMU_INSTALL_TIMEOUT}s"
            qemu_kill
            die "Installation exceeded timeout. Check serial log: ${QEMU_SERIAL_LOG}"
        fi

        local detected n label
        detected="$(qemu_detect_phase < "$QEMU_SERIAL_LOG" 2>/dev/null || echo "0|")"
        n="${detected%%|*}"
        label="${detected#*|}"
        if (( n > phase_num )); then
            phase_num="$n"
            last_phase="$label"
            if [[ -t 1 ]]; then
                printf "\r\033[K"
            fi
            ui_success "$last_phase"
        fi

        if [[ -t 1 ]]; then
            printf "\r  ${CLR_DIM}Elapsed: %dm %02ds | Phase: %s${CLR_RESET}  " \
                $(( elapsed / 60 )) $(( elapsed % 60 )) "$last_phase"
        fi

        sleep 3
    done

    if [[ -t 1 ]]; then
        printf "\r\033[K"
    fi

    local exit_code=0
    wait "$QEMU_PID" 2>/dev/null || exit_code=$?
    QEMU_PID=""

    # Flush everything QEMU wrote to the physical disks before anyone hits
    # the provider's hardware-reset button.
    sync

    local total_elapsed=$(( $(date +%s) - start_time ))
    if [[ "$exit_code" -eq 0 ]]; then
        echo ""
        ui_success "Installation completed in $(( total_elapsed / 60 ))m $(( total_elapsed % 60 ))s"
        return 0
    fi

    echo ""
    log_error "QEMU exited with code ${exit_code}"
    ui_fail "Installation failed (QEMU exit code: ${exit_code})"
    ui_info "Check serial log: ${QEMU_SERIAL_LOG}"

    if [[ -s "$QEMU_SERIAL_LOG" ]]; then
        echo ""
        ui_info "Last 20 lines of serial log:"
        local line
        tail -20 "$QEMU_SERIAL_LOG" | while IFS= read -r line; do
            echo -e "    ${CLR_DIM}${line}${CLR_RESET}"
        done
    fi

    die "Installation failed"
}

# Boot for SSH-based configuration (legacy fallback)
qemu_run_config() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local log_dir="${working_dir}/logs"

    mkdir -p "$log_dir"

    QEMU_CONFIG_LOG="${log_dir}/qemu-config.log"
    QEMU_MONITOR_SOCK="/run/pve-dedicated-qemu-config-$$.sock"
    cleanup_register_monitor "$QEMU_MONITOR_SOCK"

    log_info "Booting Proxmox for post-install configuration..."

    qemu_firmware_args
    disk_build_qemu_args

    local -a cmd=(
        qemu-system-x86_64
        -name pve-dedicated-config
        -enable-kvm
        -cpu host
        -smp "${PVE_QEMU_CPUS:-4}"
        -m "${PVE_QEMU_RAM_MB:-4096}"
        "${QEMU_FW_ARGS[@]}"
        "${QEMU_DISK_ARGS[@]}"
        -device "e1000,netdev=net0,romfile="
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${QEMU_SSH_PORT}-:22"
        -monitor "unix:${QEMU_MONITOR_SOCK},server,nowait"
        -display none
    )

    log_debug "QEMU config command: ${cmd[*]}"

    "${cmd[@]}" > "${QEMU_CONFIG_LOG}" 2>&1 &
    QEMU_PID=$!
    cleanup_register_qemu "$QEMU_PID"

    ui_info "QEMU config boot started (PID: ${QEMU_PID})"

    qemu_wait_for_ssh
}

# Wait for SSH on the forwarded port with countdown
qemu_wait_for_ssh() {
    local port="$QEMU_SSH_PORT"
    local timeout="$QEMU_BOOT_TIMEOUT"
    local start_time
    start_time="$(date +%s)"

    ui_info "Waiting for SSH on port ${port}..."

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        local remaining=$(( timeout - elapsed ))

        if (( remaining <= 0 )); then
            printf "\r\033[K"
            ui_fail "SSH did not become available within ${timeout}s"
            die "Timeout waiting for SSH. Check log: ${QEMU_CONFIG_LOG}"
        fi

        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            die "Configuration VM exited unexpectedly. Check log: ${QEMU_CONFIG_LOG}"
        fi

        if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
            printf "\r\033[K"
            ui_success "SSH available on port ${port}"
            sleep 3
            return 0
        fi

        printf "\r  ${CLR_DIM}Waiting for SSH... %ds remaining${CLR_RESET}  " "$remaining"
        sleep 5
    done
}

# Graceful shutdown via monitor socket
qemu_shutdown_guest() {
    if [[ -z "$QEMU_PID" ]]; then
        return 0
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        QEMU_PID=""
        return 0
    fi

    ui_info "Shutting down QEMU guest..."

    if [[ -S "$QEMU_MONITOR_SOCK" ]]; then
        echo "system_powerdown" | socat - "UNIX-CONNECT:${QEMU_MONITOR_SOCK}" 2>/dev/null || true
    fi

    local waited=0
    while kill -0 "$QEMU_PID" 2>/dev/null && (( waited < 60 )); do
        sleep 1
        waited=$(( waited + 1 ))
    done

    if kill -0 "$QEMU_PID" 2>/dev/null; then
        log_warn "Guest did not shut down gracefully, forcing..."
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi

    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
    sync
    ui_success "QEMU process stopped"
}

# Kill QEMU immediately
qemu_kill() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill -9 "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}
