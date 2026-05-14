# Structured logging with levels and timestamps
# shellcheck shell=bash

# Log levels: DEBUG=0, INFO=1, WARN=2, ERROR=3, FATAL=4
declare -g LOG_LEVEL="${LOG_LEVEL:-1}"
declare -g LOG_FILE=""
declare -g LOG_INITIALIZED=false

readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

log_init() {
    local log_dir="${1:-/root/logs}"
    local timestamp
    timestamp="$(date +%Y-%m-%d-%H%M%S)"

    mkdir -p "$log_dir"
    LOG_FILE="${log_dir}/pve-install-${timestamp}.log"
    touch "$LOG_FILE"
    LOG_INITIALIZED=true

    log_info "Log initialized: ${LOG_FILE}"
}

log_get_file() {
    echo "$LOG_FILE"
}

_log_format() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$*"
}

_log_write() {
    local level_num="$1"
    local level_str="$2"
    shift 2
    local message="$*"

    if [[ "$level_num" -lt "$LOG_LEVEL" ]]; then
        return 0
    fi

    local formatted
    formatted="$(_log_format "$level_str" "$message")"

    if [[ "$LOG_INITIALIZED" == true ]] && [[ -n "$LOG_FILE" ]]; then
        echo "$formatted" >> "$LOG_FILE"
    fi

    case "$level_num" in
        "$LOG_LEVEL_ERROR"|"$LOG_LEVEL_FATAL")
            echo "$formatted" >&2
            ;;
        *)
            if [[ "${LOG_QUIET:-false}" != true ]]; then
                echo "$formatted"
            fi
            ;;
    esac
}

log_debug() {
    _log_write "$LOG_LEVEL_DEBUG" "DEBUG" "$@"
}

log_info() {
    _log_write "$LOG_LEVEL_INFO" "INFO" "$@"
}

log_warn() {
    _log_write "$LOG_LEVEL_WARN" "WARN" "$@"
}

log_error() {
    _log_write "$LOG_LEVEL_ERROR" "ERROR" "$@"
}

log_fatal() {
    _log_write "$LOG_LEVEL_FATAL" "FATAL" "$@"
}

# Log and exit with error
die() {
    log_fatal "$@"
    exit 1
}

# Execute a command with logging, capturing exit code
log_exec() {
    local description="$1"
    shift
    log_debug "Executing: $* ($description)"

    local exit_code=0
    if [[ "$LOG_INITIALIZED" == true ]] && [[ -n "$LOG_FILE" ]]; then
        "$@" >> "$LOG_FILE" 2>&1 || exit_code=$?
    else
        "$@" || exit_code=$?
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "$description failed (exit code: $exit_code)"
    else
        log_debug "$description succeeded"
    fi
    return "$exit_code"
}

# Log a command and show output to both terminal and log
log_exec_tee() {
    local description="$1"
    shift
    log_debug "Executing: $* ($description)"

    local exit_code=0
    if [[ "$LOG_INITIALIZED" == true ]] && [[ -n "$LOG_FILE" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE" || exit_code=${PIPESTATUS[0]}
    else
        "$@" || exit_code=$?
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        log_error "$description failed (exit code: $exit_code)"
    else
        log_debug "$description succeeded"
    fi
    return "$exit_code"
}

# Record the start time for duration tracking
log_start_timer() {
    declare -g _LOG_START_TIME
    _LOG_START_TIME="$(date +%s)"
}

# Get elapsed time since timer start as human-readable string
log_elapsed() {
    local now
    now="$(date +%s)"
    local elapsed=$(( now - ${_LOG_START_TIME:-$now} ))
    local minutes=$(( elapsed / 60 ))
    local seconds=$(( elapsed % 60 ))
    printf "%dm %02ds" "$minutes" "$seconds"
}

log_elapsed_seconds() {
    local now
    now="$(date +%s)"
    echo $(( now - ${_LOG_START_TIME:-$now} ))
}
