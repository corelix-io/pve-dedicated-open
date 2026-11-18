# CPU, RAM, boot mode detection, and KVM availability
# shellcheck shell=bash

hw_check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
    ui_success "Running as root"
}

# Rescue detection is now handled by the active provider; see
# provider_check_rescue (lib/providers/common.sh) and the per-provider
# implementations in lib/providers/<provider>.sh.

hw_check_kvm() {
    if [[ ! -e /dev/kvm ]]; then
        log_info "KVM device not found, attempting to load modules..."
        modprobe kvm 2>/dev/null || true
        if grep -qw vmx /proc/cpuinfo 2>/dev/null; then
            modprobe kvm_intel 2>/dev/null || true
        elif grep -qw svm /proc/cpuinfo 2>/dev/null; then
            modprobe kvm_amd 2>/dev/null || true
        fi

        if [[ ! -e /dev/kvm ]]; then
            die "KVM is not available. Check that virtualization (VT-x/AMD-V) is enabled in BIOS."
        fi
    fi
    ui_success "KVM acceleration available"
}

hw_detect_boot_mode() {
    if [[ -n "$PVE_BOOT_MODE" ]] && [[ "$PVE_BOOT_MODE" != "auto" ]]; then
        log_info "Boot mode override: ${PVE_BOOT_MODE}"
        return 0
    fi

    if [[ -d /sys/firmware/efi ]]; then
        PVE_BOOT_MODE="uefi"
        ui_success "Boot mode: UEFI"
    else
        PVE_BOOT_MODE="legacy"
        ui_success "Boot mode: Legacy BIOS"
    fi
}

# Locate OVMF firmware. Echoes "pflash|CODE|VARS" for a split image pair
# (preferred: read-only code + writable NVRAM copy) or "bios|IMAGE|" for a
# combined image. Debian trixie only ships the 4M split images.
hw_find_uefi_firmware() {
    local root="${PVE_FIRMWARE_ROOT:-}"
    local -a pairs=(
        "/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd"
        "/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd"
        "/usr/share/edk2/x64/OVMF_CODE.4m.fd|/usr/share/edk2/x64/OVMF_VARS.4m.fd"
        "/usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd"
    )
    local -a combined=(
        "/usr/share/ovmf/OVMF.fd"
        "/usr/share/qemu/OVMF.fd"
    )

    local pair code vars
    for pair in "${pairs[@]}"; do
        code="${pair%%|*}"
        vars="${pair#*|}"
        if [[ -f "${root}${code}" ]] && [[ -f "${root}${vars}" ]]; then
            echo "pflash|${root}${code}|${root}${vars}"
            return 0
        fi
    done
    local fw
    for fw in "${combined[@]}"; do
        if [[ -f "${root}${fw}" ]]; then
            echo "bios|${root}${fw}|"
            return 0
        fi
    done
    return 1
}

hw_detect_cpu() {
    local total_cores
    total_cores="$(nproc 2>/dev/null || echo 4)"

    # Allocate up to 8 cores, leave at least 1 for the host
    local alloc=$(( total_cores > 1 ? total_cores - 1 : 1 ))
    if (( alloc > 8 )); then
        alloc=8
    fi

    PVE_QEMU_CPUS="$alloc"

    local model
    model="$(awk -F': *' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    model="${model:-Unknown}"
    ui_kv "CPU" "${model}"
    ui_kv "Cores (total)" "${total_cores}"
    ui_kv "Cores (QEMU)" "${PVE_QEMU_CPUS}"
}

# Pure helper: QEMU guest RAM (MiB) for a host with TOTAL_MB of RAM.
# 75% of RAM, but always leave 5 GiB for the RAM-backed rescue rootfs and
# the tmpfs workspace holding two ISO copies; floor 2 GiB, cap 16 GiB.
hw_qemu_ram_mb() {
    local total_mb="$1"
    [[ "$total_mb" =~ ^[0-9]+$ ]] || total_mb=0
    local alloc=$(( total_mb * 75 / 100 ))
    local headroom=$(( total_mb - 5120 ))
    if (( alloc > headroom )); then
        alloc=$headroom
    fi
    if (( alloc < 2048 )); then
        alloc=2048
    fi
    if (( alloc > 16384 )); then
        alloc=16384
    fi
    echo "$alloc"
}

hw_detect_ram() {
    local total_kb
    total_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    total_kb="${total_kb:-0}"
    local total_mb=$(( total_kb / 1024 ))
    local total_gb=$(( total_mb / 1024 ))

    PVE_QEMU_RAM_MB="$(hw_qemu_ram_mb "$total_mb")"

    if (( total_mb < 4096 )); then
        ui_warn "Only ${total_gb} GB RAM detected; the installer may run out of memory"
    fi

    ui_kv "RAM (total)" "${total_gb} GB"
    ui_kv "RAM (QEMU)" "$(( PVE_QEMU_RAM_MB / 1024 )) GB"
}

hw_detect_all() {
    hw_detect_boot_mode
    hw_detect_cpu
    hw_detect_ram
}
