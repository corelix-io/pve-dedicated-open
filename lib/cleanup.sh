# Trap handlers for EXIT/INT/TERM, QEMU process cleanup, temp file removal
# shellcheck shell=bash

declare -g _CLEANUP_QEMU_PIDS=()
declare -g _CLEANUP_TEMP_FILES=()
declare -g _CLEANUP_MONITOR_SOCKS=()
declare -g _CLEANUP_REGISTERED=false

cleanup_register_trap() {
    if [[ "$_CLEANUP_REGISTERED" == true ]]; then
        return 0
    fi
    trap '_cleanup_handler' EXIT
    trap '_cleanup_handler_signal INT' INT
    trap '_cleanup_handler_signal TERM' TERM
    _CLEANUP_REGISTERED=true
    log_debug "Cleanup traps registered"
}

cleanup_register_qemu() {
    local pid="$1"
    _CLEANUP_QEMU_PIDS+=("$pid")
    log_debug "Registered QEMU PID ${pid} for cleanup"
}

cleanup_register_temp() {
    local file="$1"
    _CLEANUP_TEMP_FILES+=("$file")
}

cleanup_register_monitor() {
    local sock="$1"
    _CLEANUP_MONITOR_SOCKS+=("$sock")
}

# Attempt graceful QEMU shutdown via monitor socket, then force kill
_cleanup_kill_qemu() {
    local pid="$1"
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log_warn "Cleaning up QEMU process ${pid}..."

    for sock in "${_CLEANUP_MONITOR_SOCKS[@]}"; do
        if [[ -S "$sock" ]]; then
            log_debug "Sending quit via monitor socket ${sock}"
            echo "quit" | socat - "UNIX-CONNECT:${sock}" 2>/dev/null || true
            sleep 2
            if ! kill -0 "$pid" 2>/dev/null; then
                log_debug "QEMU ${pid} exited via monitor"
                return 0
            fi
        fi
    done

    log_debug "Sending SIGTERM to QEMU ${pid}"
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
        sleep 1
        waited=$(( waited + 1 ))
    done

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Force killing QEMU ${pid}"
        kill -9 "$pid" 2>/dev/null || true
    fi
}

_cleanup_handler() {
    local exit_code=$?
    set +e

    for pid in "${_CLEANUP_QEMU_PIDS[@]}"; do
        _cleanup_kill_qemu "$pid"
    done

    for sock in "${_CLEANUP_MONITOR_SOCKS[@]}"; do
        rm -f "$sock" 2>/dev/null
    done

    for file in "${_CLEANUP_TEMP_FILES[@]}"; do
        rm -f "$file" 2>/dev/null
    done

    if [[ "$exit_code" -ne 0 ]] && [[ "$exit_code" -ne 130 ]]; then
        log_error "Installer exited with code ${exit_code}"
        if [[ -n "$LOG_FILE" ]]; then
            echo ""
            echo -e "  ${CLR_DIM}Full log: ${LOG_FILE}${CLR_RESET}"
        fi
    fi

    exit "$exit_code"
}

_cleanup_handler_signal() {
    local signal="$1"
    echo ""
    log_warn "Caught signal ${signal}, cleaning up..."
    exit 130
}
