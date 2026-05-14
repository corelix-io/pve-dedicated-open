# Input validation functions
# shellcheck shell=bash

validate_ipv4() {
    local ip="$1"
    local label="${2:-IP address}"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid ${label}: ${ip}"
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            log_error "Invalid ${label}: octet ${octet} > 255"
            return 1
        fi
    done
    return 0
}

validate_cidr() {
    local cidr="$1"
    local label="${2:-CIDR}"
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_error "Invalid ${label}: ${cidr}"
        return 1
    fi
    local ip="${cidr%/*}"
    local mask="${cidr#*/}"
    validate_ipv4 "$ip" "$label" || return 1
    if (( mask > 32 )); then
        log_error "Invalid ${label}: mask /${mask} > /32"
        return 1
    fi
    return 0
}

validate_fqdn() {
    local fqdn="$1"
    if [[ ! "$fqdn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        log_error "Invalid FQDN: ${fqdn}"
        return 1
    fi
    if [[ ${#fqdn} -gt 253 ]]; then
        log_error "FQDN too long: ${#fqdn} chars (max 253)"
        return 1
    fi
    return 0
}

validate_hostname() {
    local hostname="$1"
    if [[ ! "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        log_error "Invalid hostname: ${hostname}"
        return 1
    fi
    if [[ ${#hostname} -gt 63 ]]; then
        log_error "Hostname too long: ${#hostname} chars (max 63)"
        return 1
    fi
    return 0
}

validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email: ${email}"
        return 1
    fi
    return 0
}

validate_timezone() {
    local tz="$1"
    if [[ ! "$tz" =~ ^[A-Za-z]+/[A-Za-z_]+$ ]] && [[ "$tz" != "UTC" ]]; then
        log_error "Invalid timezone: ${tz} (expected format: Region/City or UTC)"
        return 1
    fi
    return 0
}

validate_password() {
    local pass="$1"
    if [[ -z "$pass" ]]; then
        log_error "Password cannot be empty"
        return 1
    fi
    if [[ ${#pass} -lt 5 ]]; then
        log_error "Password too short: ${#pass} chars (minimum 5)"
        return 1
    fi
    return 0
}

validate_filesystem() {
    local fs="$1"
    case "$fs" in
        zfs|ext4|xfs|btrfs) return 0 ;;
        *)
            log_error "Invalid filesystem: ${fs} (must be zfs, ext4, xfs, or btrfs)"
            return 1
            ;;
    esac
}

validate_zfs_raid() {
    local raid="$1"
    case "$raid" in
        raid0|raid1|raid10|raidz-1|raidz-2|raidz-3) return 0 ;;
        *)
            log_error "Invalid ZFS RAID level: ${raid}"
            return 1
            ;;
    esac
}

validate_disk_count_for_raid() {
    local raid="$1"
    local count="$2"

    local min_disks=1
    case "$raid" in
        raid0)   min_disks=1 ;;
        raid1)   min_disks=2 ;;
        raid10)  min_disks=4 ;;
        raidz-1) min_disks=3 ;;
        raidz-2) min_disks=4 ;;
        raidz-3) min_disks=5 ;;
    esac

    if (( count < min_disks )); then
        log_error "ZFS ${raid} requires at least ${min_disks} disks, got ${count}"
        return 1
    fi
    return 0
}

validate_keyboard() {
    local kb="$1"
    local valid_layouts="de de-ch dk en-gb en-us es fi fr fr-be fr-ca fr-ch hu is it jp lt mk nl no pl pt pt-br se si tr"
    local layout
    for layout in $valid_layouts; do
        [[ "$layout" == "$kb" ]] && return 0
    done
    log_error "Invalid keyboard layout: ${kb}"
    return 1
}

validate_boot_mode() {
    local mode="$1"
    case "$mode" in
        auto|uefi|legacy) return 0 ;;
        *)
            log_error "Invalid boot mode: ${mode} (must be auto, uefi, or legacy)"
            return 1
            ;;
    esac
}

validate_network_mode() {
    local mode="$1"
    case "$mode" in
        nat|routed|bridged) return 0 ;;
        *)
            log_error "Invalid network mode: ${mode} (must be nat, routed, or bridged)"
            return 1
            ;;
    esac
}

validate_provider() {
    local p="$1"
    case "$p" in
        hetzner|ovh) return 0 ;;
        *)
            log_error "Invalid provider: ${p} (must be hetzner or ovh)"
            return 1
            ;;
    esac
}

validate_ovh_gateway_model() {
    local m="$1"
    case "$m" in
        auto|classic|scale) return 0 ;;
        *)
            log_error "Invalid OVH gateway model: ${m} (must be auto, classic, or scale)"
            return 1
            ;;
    esac
}

validate_luks_unlock_modes() {
    local modes="$1"
    [[ -z "$modes" ]] && { log_error "LUKS unlock modes empty"; return 1; }
    local m
    for m in ${modes//,/ }; do
        case "$m" in
            passphrase|ssh|tpm) ;;
            *)
                log_error "Invalid LUKS unlock mode: ${m} (must be passphrase, ssh, or tpm)"
                return 1
                ;;
        esac
    done
    return 0
}

validate_mac() {
    local mac="$1"
    local label="${2:-MAC address}"
    if [[ ! "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        log_error "Invalid ${label}: ${mac}"
        return 1
    fi
    return 0
}

# Validate all configuration before proceeding
validate_all() {
    local errors=0

    log_info "Validating configuration..."

    validate_provider "$PVE_PROVIDER"       || errors=$(( errors + 1 ))
    validate_hostname "$PVE_HOSTNAME"       || errors=$(( errors + 1 ))
    validate_fqdn "$PVE_FQDN"               || errors=$(( errors + 1 ))
    validate_email "$PVE_EMAIL"             || errors=$(( errors + 1 ))
    validate_timezone "$PVE_TIMEZONE"       || errors=$(( errors + 1 ))
    validate_password "$PVE_ROOT_PASSWORD"  || errors=$(( errors + 1 ))
    validate_filesystem "$PVE_FILESYSTEM"   || errors=$(( errors + 1 ))
    validate_keyboard "$PVE_KEYBOARD"       || errors=$(( errors + 1 ))
    validate_network_mode "$PVE_NETWORK_MODE" || errors=$(( errors + 1 ))

    if [[ -n "$PVE_PRIVATE_SUBNET" ]]; then
        validate_cidr "$PVE_PRIVATE_SUBNET" "private subnet" || errors=$(( errors + 1 ))
    fi

    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        validate_zfs_raid "$PVE_ZFS_RAID" || errors=$(( errors + 1 ))
    fi

    if [[ -n "$PVE_BOOT_MODE" ]]; then
        validate_boot_mode "$PVE_BOOT_MODE" || errors=$(( errors + 1 ))
    fi

    # OVH-specific validation
    if [[ "$PVE_PROVIDER" == "ovh" ]]; then
        validate_ovh_gateway_model "${PVE_OVH_GATEWAY_MODEL:-auto}" || errors=$(( errors + 1 ))
        if [[ -n "${PVE_OVH_VRACK_IP_CIDR:-}" ]]; then
            validate_cidr "$PVE_OVH_VRACK_IP_CIDR" "vRack IP" || errors=$(( errors + 1 ))
        fi
    fi

    # Premium LUKS validation (only when feature is enabled)
    if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
        validate_luks_unlock_modes "$PVE_LUKS_UNLOCK_MODES" || errors=$(( errors + 1 ))
        if [[ -n "$PVE_LUKS_WAN_MAC" ]]; then
            validate_mac "$PVE_LUKS_WAN_MAC" "LUKS WAN MAC" || errors=$(( errors + 1 ))
        fi
        if [[ "$PVE_LUKS_UNLOCK_MODES" == *"ssh"* ]]; then
            if [[ -z "$PVE_SSH_KEYS" ]]; then
                log_error "LUKS SSH unlock requires --ssh-keys (used by dropbear-initramfs)"
                errors=$(( errors + 1 ))
            fi
        fi
        if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
            log_error "LUKS premium currently supports ZFS root only; got filesystem=${PVE_FILESYSTEM}"
            errors=$(( errors + 1 ))
        fi
    fi

    if [[ "$errors" -gt 0 ]]; then
        die "Validation failed with ${errors} error(s). Fix the issues above and retry."
    fi

    ui_success "All inputs validated"
}
