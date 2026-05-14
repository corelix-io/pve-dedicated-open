# QEMU orchestrator: launch, serial console, monitor, progress parsing
# shellcheck shell=bash

declare -g QEMU_PID=""
declare -g QEMU_MONITOR_SOCK=""
declare -g QEMU_SERIAL_LOG=""
declare -g QEMU_CONFIG_LOG=""

readonly QEMU_INSTALL_TIMEOUT=1200   # 20 minutes max for install
readonly QEMU_BOOT_TIMEOUT=300       # 5 minutes for SSH to come up

# Run the installation QEMU with progress monitoring
qemu_run_install() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local iso_file="${working_dir}/pve-autoinstall.iso"
    local log_dir="${working_dir}/logs"

    if [[ ! -f "$iso_file" ]]; then
        die "Auto-install ISO not found: ${iso_file}"
    fi

    mkdir -p "$log_dir"

    QEMU_SERIAL_LOG="${log_dir}/qemu-install-serial.log"
    QEMU_MONITOR_SOCK="/tmp/qemu-monitor-$$.sock"

    cleanup_register_monitor "$QEMU_MONITOR_SOCK"

    # Build QEMU command
    local -a cmd=(
        qemu-system-x86_64
        -enable-kvm
        -cpu host
        -smp "${PVE_QEMU_CPUS:-4}"
        -m "${PVE_QEMU_RAM_MB:-4096}"
        -boot d
        -cdrom "$iso_file"
    )

    local fw
    fw="$(hw_get_uefi_firmware)"
    if [[ -n "$fw" ]]; then
        cmd+=(-bios "$fw")
    fi

    local disk_args
    disk_args="$(disk_build_qemu_args)"
    # shellcheck disable=SC2206
    cmd+=($disk_args)

    cmd+=(-serial "file:${QEMU_SERIAL_LOG}")
    cmd+=(-monitor "unix:${QEMU_MONITOR_SOCK},server,nowait")
    cmd+=(-no-reboot -display none)

    log_info "Starting QEMU installation..."
    log_debug "QEMU command: ${cmd[*]}"

    # Launch QEMU in background
    "${cmd[@]}" &
    QEMU_PID=$!
    cleanup_register_qemu "$QEMU_PID"

    ui_info "QEMU started (PID: ${QEMU_PID})"
    ui_info "Serial log: ${QEMU_SERIAL_LOG}"
    echo ""

    # Monitor installation progress via serial log
    qemu_monitor_install
}

# Monitor the serial log for installation progress
qemu_monitor_install() {
    local start_time
    start_time="$(date +%s)"
    local last_phase="Waiting for installer to start"
    local phase_num=0
    local total_phases=6

    ui_info "Monitoring installation progress..."
    echo ""

    # Ensure serial log exists
    touch "$QEMU_SERIAL_LOG"

    while kill -0 "$QEMU_PID" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_time ))

        # Check for timeout
        if (( elapsed > QEMU_INSTALL_TIMEOUT )); then
            log_error "Installation timed out after ${QEMU_INSTALL_TIMEOUT}s"
            qemu_kill
            die "Installation exceeded timeout. Check serial log: ${QEMU_SERIAL_LOG}"
        fi

        # Parse serial log for progress indicators
        local new_phase=""
        if grep -qi 'starting installation\|auto.install\|automated installation' "$QEMU_SERIAL_LOG" 2>/dev/null; then
            if [[ "$phase_num" -lt 1 ]]; then
                new_phase="Starting automated installation"
                phase_num=1
            fi
        fi
        if grep -qi 'creating.*zpool\|creating.*filesystem\|formatting\|partitioning' "$QEMU_SERIAL_LOG" 2>/dev/null; then
            if [[ "$phase_num" -lt 2 ]]; then
                new_phase="Creating filesystems"
                phase_num=2
            fi
        fi
        if grep -qi 'installing.*base\|debootstrap\|extracting' "$QEMU_SERIAL_LOG" 2>/dev/null; then
            if [[ "$phase_num" -lt 3 ]]; then
                new_phase="Installing base system"
                phase_num=3
            fi
        fi
        if grep -qi 'installing.*packages\|apt.*install\|configuring.*packages' "$QEMU_SERIAL_LOG" 2>/dev/null; then
            if [[ "$phase_num" -lt 4 ]]; then
                new_phase="Installing packages"
                phase_num=4
            fi
        fi
        if grep -qi 'configuring\|post.install\|running.*hook\|first.boot' "$QEMU_SERIAL_LOG" 2>/dev/null; then
            if [[ "$phase_num" -lt 5 ]]; then
                new_phase="Configuring system"
                phase_num=5
            fi
        fi
        if grep -qi 'installation.*successful\|installation.*complete\|installation.*finished' "$QEMU_SERIAL_LOG" 2>/dev/null; then
            if [[ "$phase_num" -lt 6 ]]; then
                new_phase="Installation complete"
                phase_num=6
            fi
        fi

        if [[ -n "$new_phase" ]] && [[ "$new_phase" != "$last_phase" ]]; then
            last_phase="$new_phase"
            printf "\r\033[K"
            ui_success "${new_phase}"
        fi

        # Show elapsed time
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        printf "\r  ${CLR_DIM}Elapsed: %dm %02ds | Phase: %s${CLR_RESET}  " "$mins" "$secs" "$last_phase"

        sleep 3
    done

    printf "\r\033[K"

    # Check exit status
    wait "$QEMU_PID" 2>/dev/null
    local exit_code=$?
    QEMU_PID=""

    local total_elapsed=$(( $(date +%s) - start_time ))
    local total_mins=$(( total_elapsed / 60 ))
    local total_secs=$(( total_elapsed % 60 ))

    if [[ "$exit_code" -eq 0 ]] || [[ "$exit_code" -eq 143 ]]; then
        echo ""
        ui_success "Installation completed in ${total_mins}m ${total_secs}s"
    else
        echo ""
        log_error "QEMU exited with code ${exit_code}"
        ui_fail "Installation may have failed (exit code: ${exit_code})"
        ui_info "Check serial log: ${QEMU_SERIAL_LOG}"

        if [[ -f "$QEMU_SERIAL_LOG" ]] && [[ -s "$QEMU_SERIAL_LOG" ]]; then
            echo ""
            ui_info "Last 20 lines of serial log:"
            tail -20 "$QEMU_SERIAL_LOG" | while IFS= read -r line; do
                echo -e "    ${CLR_DIM}${line}${CLR_RESET}"
            done
        fi

        die "Installation failed"
    fi
}

# Boot for SSH-based configuration (legacy fallback)
qemu_run_config() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local log_dir="${working_dir}/logs"

    mkdir -p "$log_dir"

    QEMU_CONFIG_LOG="${log_dir}/qemu-config.log"

    log_info "Booting Proxmox for post-install configuration..."

    local -a cmd=(
        qemu-system-x86_64
        -enable-kvm
        -cpu host
        -smp "${PVE_QEMU_CPUS:-4}"
        -m "${PVE_QEMU_RAM_MB:-4096}"
        -device e1000,netdev=net0
        -netdev "user,id=net0,hostfwd=tcp::5555-:22"
    )

    local fw
    fw="$(hw_get_uefi_firmware)"
    if [[ -n "$fw" ]]; then
        cmd+=(-bios "$fw")
    fi

    local disk_args
    disk_args="$(disk_build_qemu_args)"
    # shellcheck disable=SC2206
    cmd+=($disk_args)

    cmd+=(-display none)

    log_debug "QEMU config command: ${cmd[*]}"

    nohup "${cmd[@]}" > "${QEMU_CONFIG_LOG}" 2>&1 &
    QEMU_PID=$!
    cleanup_register_qemu "$QEMU_PID"

    ui_info "QEMU config boot started (PID: ${QEMU_PID})"

    # Wait for SSH
    qemu_wait_for_ssh
}

# Wait for SSH on port 5555 with countdown
qemu_wait_for_ssh() {
    local port=5555
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

        if nc -z localhost "$port" 2>/dev/null || \
           bash -c "echo > /dev/tcp/localhost/${port}" 2>/dev/null; then
            printf "\r\033[K"
            ui_success "SSH available on port ${port}"
            # Give services a moment to fully start
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
    while kill -0 "$QEMU_PID" 2>/dev/null && (( waited < 30 )); do
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
