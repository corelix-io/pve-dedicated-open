# Input validation functions
# shellcheck shell=bash

validate_ipv4() {
    local ip="$1"
    local label="${2:-IP address}"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid ${label}: ${ip}"
        return 1
    fi
    local -a octets
    local octet
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( 10#$octet > 255 )); then
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
    if (( 10#$mask > 32 )); then
        log_error "Invalid ${label}: mask /${mask} > /32"
        return 1
    fi
    return 0
}

# IPv4 address with an optional /prefix.
validate_ipv4_or_cidr() {
    local value="$1"
    local label="${2:-IP address}"
    if [[ "$value" == */* ]]; then
        validate_cidr "$value" "$label"
    else
        validate_ipv4 "$value" "$label"
    fi
}

validate_ipv6() {
    local ip="$1"
    local label="${2:-IPv6 address}"
    if ! net_ipv6_expand "${ip%/*}" >/dev/null 2>&1; then
        log_error "Invalid ${label}: ${ip}"
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

# The auto-installer derives the hostname from the FQDN; a mismatch would
# leave the node with one name in /etc/hostname and another in pmxcfs.
validate_hostname_matches_fqdn() {
    local hostname="$1"
    local fqdn="$2"
    if [[ "${fqdn%%.*}" != "$hostname" ]]; then
        log_error "Hostname '${hostname}' does not match the first label of FQDN '${fqdn}'"
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
    local zoneinfo="${PVE_ZONEINFO_DIR:-/usr/share/zoneinfo}"
    if [[ "$tz" == "UTC" ]]; then
        return 0
    fi
    if [[ ! "$tz" =~ ^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$ ]]; then
        log_error "Invalid timezone: ${tz} (expected format: Region/City or UTC)"
        return 1
    fi
    if [[ -d "$zoneinfo" ]] && [[ ! -f "${zoneinfo}/${tz}" ]]; then
        log_error "Unknown timezone: ${tz} (not found in ${zoneinfo})"
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
    if [[ ${#pass} -lt 8 ]]; then
        log_error "Password too short: ${#pass} chars (minimum 8)"
        return 1
    fi
    if [[ "$pass" == *CHANGE_ME* ]]; then
        log_error "Root password is still the example placeholder (CHANGE_ME...)"
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

validate_zfs_compress() {
    local alg="$1"
    case "$alg" in
        on|off|lzjb|lz4|zle|gzip|zstd) return 0 ;;
        *)
            log_error "Invalid ZFS compression: ${alg} (on, off, lzjb, lz4, zle, gzip, zstd)"
            return 1
            ;;
    esac
}

validate_zfs_ashift() {
    local ashift="$1"
    if [[ ! "$ashift" =~ ^[0-9]+$ ]] || (( 10#$ashift < 9 || 10#$ashift > 16 )); then
        log_error "Invalid ZFS ashift: ${ashift} (must be 9-16)"
        return 1
    fi
    return 0
}

validate_positive_int() {
    local value="$1"
    local label="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value == 0 )); then
        log_error "Invalid ${label}: ${value} (must be a positive integer)"
        return 1
    fi
    return 0
}

validate_port() {
    local port="$1"
    local label="${2:-port}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        log_error "Invalid ${label}: ${port} (must be 1-65535)"
        return 1
    fi
    return 0
}

validate_bool() {
    local value="$1"
    local label="$2"
    case "$value" in
        true|false) return 0 ;;
        *)
            log_error "Invalid ${label}: ${value} (must be true or false)"
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
    if [[ "$raid" == "raid10" ]] && (( count % 2 != 0 )); then
        log_error "ZFS raid10 requires an even number of disks, got ${count}"
        return 1
    fi
    return 0
}

validate_keyboard() {
    local kb="$1"
    local valid_layouts="de de-ch dk en-gb en-us es fi fr fr-be fr-ca fr-ch hu is it jp lt mk nl no pl pt pt-br se si tr"
    local layout
    for layout in $valid_layouts; do
        if [[ "$layout" == "$kb" ]]; then
            return 0
        fi
    done
    log_error "Invalid keyboard layout: ${kb}"
    return 1
}

validate_country() {
    local country="$1"
    if [[ ! "$country" =~ ^[a-z]{2}$ ]]; then
        log_error "Invalid country code: ${country} (expected two lowercase letters, e.g. de)"
        return 1
    fi
    return 0
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

validate_disk_mode() {
    local mode="$1"
    case "$mode" in
        auto|manual) return 0 ;;
        *)
            log_error "Invalid disk mode: ${mode} (must be auto or manual)"
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
    if [[ -z "$modes" ]]; then
        log_error "LUKS unlock modes empty"
        return 1
    fi
    local m
    for m in ${modes//,/ }; do
        case "$m" in
            passphrase|ssh|tpm|tang) ;;
            *)
                log_error "Invalid LUKS unlock mode: ${m} (must be passphrase, ssh, tpm, or tang)"
                return 1
                ;;
        esac
    done
    return 0
}

# Tang URLs end up inside Clevis JSON; allow plain host[:port][/path] only.
validate_tang_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        log_error "Invalid Tang URL: ${url} (expected http(s)://host[:port][/path])"
        return 1
    fi
    return 0
}

# Tang advertisement thumbprints are base64url (tang-show-keys output).
validate_tang_thumbprint() {
    local thp="$1"
    if [[ ! "$thp" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
        log_error "Invalid Tang thumbprint: ${thp}"
        return 1
    fi
    return 0
}

# Comma-separated TPM PCR indexes, 0-23.
validate_tpm_pcrs() {
    local pcrs="$1"
    if [[ ! "$pcrs" =~ ^([0-9]|1[0-9]|2[0-3])(,([0-9]|1[0-9]|2[0-3]))*$ ]]; then
        log_error "Invalid TPM PCR list: ${pcrs} (expected e.g. 0,1,2,7)"
        return 1
    fi
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

# Validate the normalized (one per line) SSH key list.
validate_ssh_keys() {
    local keys="$1"
    local errors=0 line type
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        type="$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^(sk-)?(ssh|ecdsa-sha2)-/) {print $i; exit}}' <<< "$line")"
        case "$type" in
            "")
                log_error "Invalid SSH public key: ${line:0:40}..."
                errors=$(( errors + 1 ))
                ;;
            ssh-dss*)
                log_error "DSA SSH keys are not supported by OpenSSH 10 (Debian trixie); use ed25519"
                errors=$(( errors + 1 ))
                ;;
        esac
    done <<< "$keys"
    (( errors == 0 ))
}

# Validate all configuration before proceeding
# Hetzner vSwitch settings (PVE_HETZNER_VSWITCH_*). Logs every problem and
# returns 1 if there was any.
validate_hetzner_vswitch() {
    local errors=0 vlan="${PVE_HETZNER_VSWITCH_VLAN:-}"
    local ip="${PVE_HETZNER_VSWITCH_IP:-}" gw="${PVE_HETZNER_VSWITCH_GATEWAY:-}"
    local routes="${PVE_HETZNER_VSWITCH_ROUTES:-}" mtu="${PVE_HETZNER_VSWITCH_MTU:-1400}"
    local route

    if [[ -z "$vlan" ]]; then
        if [[ -n "$ip$gw$routes" ]]; then
            log_error "vSwitch IP/gateway/routes given without --vswitch-vlan"
            return 1
        fi
        return 0
    fi
    if [[ "${PVE_PROVIDER:-}" != "hetzner" ]]; then
        log_error "--vswitch-* is Hetzner-only (provider: ${PVE_PROVIDER:-unset}); use --ovh-vrack-* on OVH"
        errors=$(( errors + 1 ))
    fi
    if [[ ! "$vlan" =~ ^[0-9]+$ ]] || (( 10#$vlan < 4000 || 10#$vlan > 4091 )); then
        log_error "Invalid vSwitch VLAN ID: ${vlan} (Hetzner vSwitch IDs are 4000-4091)"
        errors=$(( errors + 1 ))
    fi
    if [[ ! "$mtu" =~ ^[0-9]+$ ]] || (( 10#$mtu < 1280 || 10#$mtu > 1400 )); then
        log_error "Invalid vSwitch MTU: ${mtu} (1280-1400; Hetzner requires at most 1400)"
        errors=$(( errors + 1 ))
    fi
    if [[ -z "$ip" ]]; then
        if [[ "${PVE_HETZNER_VSWITCH_BRIDGE:-false}" != true ]]; then
            log_error "--vswitch-vlan needs --vswitch-ip (host address) or --vswitch-bridge (guests only)"
            errors=$(( errors + 1 ))
        fi
        if [[ -n "$routes" ]]; then
            log_error "--vswitch-routes needs --vswitch-ip"
            errors=$(( errors + 1 ))
        fi
        (( errors == 0 ))
        return
    fi
    if ! validate_cidr "$ip" "vSwitch IP"; then
        return 1
    fi
    if (( 10#${ip#*/} > 30 )); then
        log_error "vSwitch IP needs a subnet prefix (e.g. ${ip%/*}/24), got /${ip#*/}"
        errors=$(( errors + 1 ))
    fi
    if [[ -n "${PVE_PRIVATE_SUBNET:-}" ]] && [[ "${PVE_NETWORK_MODE:-nat}" == "nat" ]]; then
        if net_ipv4_in_subnet "${PVE_PRIVATE_SUBNET%/*}" "$ip" \
            || net_ipv4_in_subnet "${ip%/*}" "$PVE_PRIVATE_SUBNET"; then
            log_error "vSwitch subnet ${ip} overlaps the NAT subnet ${PVE_PRIVATE_SUBNET}"
            errors=$(( errors + 1 ))
        fi
    fi
    if [[ -n "$gw" ]]; then
        if ! validate_ipv4 "$gw" "vSwitch gateway"; then
            errors=$(( errors + 1 ))
        elif ! net_ipv4_in_subnet "$gw" "$ip"; then
            log_error "vSwitch gateway ${gw} is outside the vSwitch subnet ${ip}"
            errors=$(( errors + 1 ))
        elif [[ "$gw" == "${ip%/*}" ]]; then
            log_error "vSwitch gateway ${gw} is this server's own vSwitch address"
            errors=$(( errors + 1 ))
        fi
    elif [[ -n "$routes" ]] && [[ "$(net_ipv4_host "$ip" 1)" == "${ip%/*}" ]]; then
        log_error "vSwitch IP ${ip%/*} is the subnet's first host, the default gateway; pick another address or set --vswitch-gateway"
        errors=$(( errors + 1 ))
    fi
    for route in ${routes//,/ }; do
        validate_cidr "$route" "vSwitch route" || errors=$(( errors + 1 ))
    done
    (( errors == 0 ))
}

validate_all() {
    local errors=0

    log_info "Validating configuration..."

    validate_provider "$PVE_PROVIDER"       || errors=$(( errors + 1 ))
    validate_hostname "$PVE_HOSTNAME"       || errors=$(( errors + 1 ))
    validate_fqdn "$PVE_FQDN"               || errors=$(( errors + 1 ))
    validate_hostname_matches_fqdn "$PVE_HOSTNAME" "$PVE_FQDN" || errors=$(( errors + 1 ))
    validate_email "$PVE_EMAIL"             || errors=$(( errors + 1 ))
    validate_timezone "$PVE_TIMEZONE"       || errors=$(( errors + 1 ))
    validate_password "$PVE_ROOT_PASSWORD"  || errors=$(( errors + 1 ))
    validate_filesystem "$PVE_FILESYSTEM"   || errors=$(( errors + 1 ))
    validate_keyboard "$PVE_KEYBOARD"       || errors=$(( errors + 1 ))
    validate_country "$PVE_COUNTRY"         || errors=$(( errors + 1 ))
    validate_disk_mode "$PVE_DISK_MODE"     || errors=$(( errors + 1 ))
    validate_network_mode "$PVE_NETWORK_MODE" || errors=$(( errors + 1 ))
    validate_bool "$PVE_ENABLE_DHCP" "DHCP flag"   || errors=$(( errors + 1 ))
    validate_bool "$PVE_ISO_VERIFY" "ISO verify flag" || errors=$(( errors + 1 ))

    if [[ -n "$PVE_SSH_KEYS" ]]; then
        validate_ssh_keys "$PVE_SSH_KEYS" || errors=$(( errors + 1 ))
    fi

    local dns
    for dns in $PVE_DNS_SERVERS; do
        if [[ "$dns" == *:* ]]; then
            validate_ipv6 "$dns" "DNS server" || errors=$(( errors + 1 ))
        else
            validate_ipv4 "$dns" "DNS server" || errors=$(( errors + 1 ))
        fi
    done
    if [[ -z "$PVE_DNS_SERVERS" ]]; then
        log_error "No DNS servers configured"
        errors=$(( errors + 1 ))
    fi

    if [[ "$PVE_NETWORK_MODE" == "nat" ]]; then
        if [[ -z "$PVE_PRIVATE_SUBNET" ]]; then
            log_error "NAT mode requires a private subnet (--private-subnet)"
            errors=$(( errors + 1 ))
        elif validate_cidr "$PVE_PRIVATE_SUBNET" "private subnet"; then
            local prefix="${PVE_PRIVATE_SUBNET#*/}"
            if [[ "$PVE_ENABLE_DHCP" == true ]] && (( 10#$prefix > 24 )); then
                log_error "DHCP needs a private subnet of /24 or larger (got /${prefix})"
                errors=$(( errors + 1 ))
            fi
        else
            errors=$(( errors + 1 ))
        fi
    fi

    local ip
    for ip in ${PVE_ADDITIONAL_IPS//,/ }; do
        validate_ipv4_or_cidr "$ip" "additional IP" || errors=$(( errors + 1 ))
    done
    if [[ -n "$PVE_ADDITIONAL_IPS" ]] && [[ "$PVE_NETWORK_MODE" != "routed" ]]; then
        log_warn "--additional-ips is only used in routed network mode (current: ${PVE_NETWORK_MODE})"
    fi

    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        validate_zfs_raid "$PVE_ZFS_RAID" || errors=$(( errors + 1 ))
        if [[ -n "$PVE_ZFS_COMPRESS" ]]; then
            validate_zfs_compress "$PVE_ZFS_COMPRESS" || errors=$(( errors + 1 ))
        fi
        if [[ -n "$PVE_ZFS_ASHIFT" ]]; then
            validate_zfs_ashift "$PVE_ZFS_ASHIFT" || errors=$(( errors + 1 ))
        fi
        if [[ -n "$PVE_ZFS_ARC_MAX" ]]; then
            validate_positive_int "$PVE_ZFS_ARC_MAX" "ZFS ARC max (MiB)" || errors=$(( errors + 1 ))
        fi
    fi

    if [[ -n "$PVE_BOOT_MODE" ]]; then
        validate_boot_mode "$PVE_BOOT_MODE" || errors=$(( errors + 1 ))
    fi

    validate_hetzner_vswitch || errors=$(( errors + 1 ))

    if [[ "$PVE_PROVIDER" == "ovh" ]]; then
        validate_ovh_gateway_model "${PVE_OVH_GATEWAY_MODEL:-auto}" || errors=$(( errors + 1 ))
        if [[ -n "${PVE_OVH_VRACK_IP_CIDR:-}" ]]; then
            validate_cidr "$PVE_OVH_VRACK_IP_CIDR" "vRack IP" || errors=$(( errors + 1 ))
        fi
        if [[ -n "${PVE_OVH_IPV6_GATEWAY:-}" ]]; then
            validate_ipv6 "$PVE_OVH_IPV6_GATEWAY" "OVH IPv6 gateway" || errors=$(( errors + 1 ))
        fi
    fi

    if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
        validate_luks_unlock_modes "$PVE_LUKS_UNLOCK_MODES" || errors=$(( errors + 1 ))
        validate_port "$PVE_LUKS_DROPBEAR_PORT" "LUKS dropbear port" || errors=$(( errors + 1 ))
        if [[ -n "$PVE_LUKS_WAN_MAC" ]]; then
            validate_mac "$PVE_LUKS_WAN_MAC" "LUKS WAN MAC" || errors=$(( errors + 1 ))
        fi
        if [[ "$PVE_LUKS_UNLOCK_MODES" == *"ssh"* ]] && [[ -z "$PVE_SSH_KEYS" ]]; then
            log_error "LUKS SSH unlock requires --ssh-keys (used by dropbear-initramfs)"
            errors=$(( errors + 1 ))
        fi
        if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
            log_error "LUKS premium currently supports ZFS root only; got filesystem=${PVE_FILESYSTEM}"
            errors=$(( errors + 1 ))
        fi
        if [[ ",${PVE_LUKS_UNLOCK_MODES}," == *",tpm,"* ]]; then
            validate_tpm_pcrs "$PVE_LUKS_TPM_PCRS" || errors=$(( errors + 1 ))
        fi
        local -a tang_urls=() tang_thps=()
        read -ra tang_urls <<< "${PVE_LUKS_TANG_URLS//,/ }"
        read -ra tang_thps <<< "${PVE_LUKS_TANG_THUMBPRINTS//,/ }"
        if [[ ",${PVE_LUKS_UNLOCK_MODES}," == *",tang,"* ]] && [[ ${#tang_urls[@]} -eq 0 ]]; then
            log_error "LUKS unlock mode 'tang' requires --luks-tang-url"
            errors=$(( errors + 1 ))
        fi
        local u
        for u in "${tang_urls[@]}"; do
            validate_tang_url "$u" || errors=$(( errors + 1 ))
        done
        for u in "${tang_thps[@]}"; do
            validate_tang_thumbprint "$u" || errors=$(( errors + 1 ))
        done
        if [[ ${#tang_thps[@]} -gt 0 ]] && [[ ${#tang_thps[@]} -ne ${#tang_urls[@]} ]]; then
            log_error "Give one --luks-tang-thumbprint per --luks-tang-url (${#tang_urls[@]} URL(s), ${#tang_thps[@]} thumbprint(s))"
            errors=$(( errors + 1 ))
        fi
        case "$PVE_LUKS_AUTO_UNLOCK_POLICY" in
            all|any) ;;
            *)
                log_error "Invalid --luks-auto-unlock-policy: ${PVE_LUKS_AUTO_UNLOCK_POLICY} (all or any)"
                errors=$(( errors + 1 ))
                ;;
        esac
        validate_bool "$PVE_LUKS_WIPE_FREE_SPACE" "LUKS free-space wipe flag" || errors=$(( errors + 1 ))
        validate_bool "$PVE_LUKS_ALLOW_RAID0" "LUKS raid0 flag" || errors=$(( errors + 1 ))
    fi

    if [[ "${PVE_ZFS_ENCRYPTION:-false}" == true ]]; then
        if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
            log_error "--zfs-encrypt requires PVE_FILESYSTEM=zfs (got ${PVE_FILESYSTEM})"
            errors=$(( errors + 1 ))
        fi
        if [[ "${PVE_FEATURE_LUKS:-false}" == true ]]; then
            log_error "Choose one of --enable-luks or --zfs-encrypt, not both (double encryption)"
            errors=$(( errors + 1 ))
        fi
        local zm
        for zm in ${PVE_ZFS_UNLOCK_MODES//,/ }; do
            case "$zm" in
                passphrase|tpm|tang) ;;
                *)
                    log_error "Invalid ZFS unlock mode: ${zm} (passphrase, tpm, or tang)"
                    errors=$(( errors + 1 ))
                    ;;
            esac
        done
        if [[ ",${PVE_ZFS_UNLOCK_MODES}," == *",tpm,"* ]]; then
            validate_tpm_pcrs "$PVE_LUKS_TPM_PCRS" || errors=$(( errors + 1 ))
        fi
        if [[ ",${PVE_ZFS_UNLOCK_MODES}," == *",tang,"* ]] && [[ -z "$PVE_LUKS_TANG_URLS" ]]; then
            log_error "ZFS unlock mode 'tang' requires --tang-url"
            errors=$(( errors + 1 ))
        fi
        local zu
        for zu in ${PVE_LUKS_TANG_URLS//,/ }; do
            validate_tang_url "$zu" || errors=$(( errors + 1 ))
        done
        validate_bool "$PVE_ZFS_ENCRYPT_LOCAL" "ZFS local-storage encryption flag" || errors=$(( errors + 1 ))
    fi

    if [[ "$errors" -gt 0 ]]; then
        die "Validation failed with ${errors} error(s). Fix the issues above and retry."
    fi

    ui_success "All inputs validated"
}
