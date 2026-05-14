# CLI argument parsing, config file loading, and defaults
# shellcheck shell=bash

# All config variables are prefixed with PVE_
# Precedence: defaults < config file < CLI args < interactive prompts

declare -g PVE_PROVIDER="${PVE_PROVIDER:-}"   # hetzner | ovh (auto-detected when empty)
declare -g PVE_HOSTNAME=""
declare -g PVE_FQDN=""
declare -g PVE_TIMEZONE=""
declare -g PVE_EMAIL=""
declare -g PVE_ROOT_PASSWORD=""
declare -g PVE_SSH_KEYS=""
declare -g PVE_PRIVATE_SUBNET=""
declare -g PVE_INTERFACE=""
declare -g PVE_DISK_MODE="auto"    # auto, manual
declare -g PVE_DISKS=""            # comma-separated list
declare -g PVE_FILESYSTEM="zfs"
declare -g PVE_ZFS_RAID="raid1"
declare -g PVE_ZFS_COMPRESS="lz4"
declare -g PVE_ZFS_ASHIFT=""
declare -g PVE_ZFS_ARC_MAX=""
declare -g PVE_KEYBOARD="en-us"
declare -g PVE_COUNTRY="us"
declare -g PVE_ISO_PATH=""
declare -g PVE_BOOT_MODE="auto"    # auto, uefi, legacy
declare -g PVE_DNS_SERVERS="185.12.64.1 185.12.64.2"
declare -g PVE_UNATTENDED=false
declare -g PVE_CONFIG_FILE=""
declare -g PVE_SKIP_CONFIRM=false
declare -g PVE_LOG_LEVEL=1
declare -g PVE_WORKING_DIR="/root"
declare -g PVE_DEBIAN_SUITE="trixie"
declare -g PVE_NETWORK_MODE="nat"  # nat, routed, bridged
declare -g PVE_ENABLE_DHCP=true    # dnsmasq DHCP on vmbr1 (NAT mode only)

# Premium feature flags (gated; LUKS implementation only ships in premium build)
declare -g PVE_FEATURE_LUKS="${PVE_FEATURE_LUKS:-false}"
declare -g PVE_LUKS_PASSPHRASE="${PVE_LUKS_PASSPHRASE:-}"
# Empty = "not explicitly set". The premium LUKS pre-flight resolver will
# prompt interactively (default `passphrase,ssh`) or pick a sensible default
# in unattended mode. CLI/config-file values continue to win unchanged.
declare -g PVE_LUKS_UNLOCK_MODES="${PVE_LUKS_UNLOCK_MODES:-}"
declare -g PVE_LUKS_DROPBEAR_PORT="${PVE_LUKS_DROPBEAR_PORT:-2222}"
declare -g PVE_LUKS_WAN_MAC="${PVE_LUKS_WAN_MAC:-}"

# Premium license credentials (validated at install time against a Cloudflare
# Worker that talks to Creem.io). The bootstrap from the Worker presets these
# via env, OR the customer can pass --license-key on the CLI.
declare -g PVE_LICENSE_KEY="${PVE_LICENSE_KEY:-}"
declare -g PVE_LICENSE_INSTANCE_ID="${PVE_LICENSE_INSTANCE_ID:-}"
declare -g PVE_LICENSE_ENDPOINT="${PVE_LICENSE_ENDPOINT:-https://get.corelix.io/products/pve-dedicated/license}"

# Derived values (populated during detection/config)
declare -g PVE_MAIN_IPV4=""
declare -g PVE_MAIN_IPV4_CIDR=""
declare -g PVE_MAIN_IPV4_GW=""
declare -g PVE_MAC_ADDRESS=""
declare -g PVE_IPV6=""
declare -g PVE_IPV6_CIDR=""
declare -g PVE_PRIVATE_IP=""
declare -g PVE_PRIVATE_IP_CIDR=""
declare -g PVE_PREDICTED_IFACE=""
declare -g PVE_FIRST_IPV6_CIDR=""
declare -g PVE_QEMU_CPUS=""
declare -g PVE_QEMU_RAM_MB=""
declare -g PVE_INSTALL_START_TIME=""

config_load_defaults() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local defaults_file="${script_dir}/configs/default.env"

    if [[ -f "$defaults_file" ]]; then
        log_debug "Loading defaults from ${defaults_file}"
        config_load_file "$defaults_file"
    fi
}

config_load_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        die "Config file not found: ${file}"
    fi

    log_info "Loading configuration from ${file}"

    local key value
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"

        case "$key" in
            PVE_PROVIDER)             PVE_PROVIDER="$value" ;;
            PVE_HOSTNAME)             PVE_HOSTNAME="$value" ;;
            PVE_FQDN)                 PVE_FQDN="$value" ;;
            PVE_TIMEZONE)             PVE_TIMEZONE="$value" ;;
            PVE_EMAIL)                PVE_EMAIL="$value" ;;
            PVE_ROOT_PASSWORD)        PVE_ROOT_PASSWORD="$value" ;;
            PVE_SSH_KEYS)             PVE_SSH_KEYS="$value" ;;
            PVE_PRIVATE_SUBNET)       PVE_PRIVATE_SUBNET="$value" ;;
            PVE_INTERFACE)            PVE_INTERFACE="$value" ;;
            PVE_DISK_MODE)            PVE_DISK_MODE="$value" ;;
            PVE_DISKS)                PVE_DISKS="$value" ;;
            PVE_FILESYSTEM)           PVE_FILESYSTEM="$value" ;;
            PVE_ZFS_RAID)             PVE_ZFS_RAID="$value" ;;
            PVE_ZFS_COMPRESS)         PVE_ZFS_COMPRESS="$value" ;;
            PVE_ZFS_ASHIFT)           PVE_ZFS_ASHIFT="$value" ;;
            PVE_ZFS_ARC_MAX)          PVE_ZFS_ARC_MAX="$value" ;;
            PVE_KEYBOARD)             PVE_KEYBOARD="$value" ;;
            PVE_COUNTRY)              PVE_COUNTRY="$value" ;;
            PVE_ISO_PATH)             PVE_ISO_PATH="$value" ;;
            PVE_BOOT_MODE)            PVE_BOOT_MODE="$value" ;;
            PVE_DNS_SERVERS)          PVE_DNS_SERVERS="$value" ;;
            PVE_NETWORK_MODE)         PVE_NETWORK_MODE="$value" ;;
            PVE_ENABLE_DHCP)          PVE_ENABLE_DHCP="$value" ;;
            PVE_DEBIAN_SUITE)         PVE_DEBIAN_SUITE="$value" ;;
            PVE_LOG_LEVEL)            PVE_LOG_LEVEL="$value"; LOG_LEVEL="$value" ;;
            PVE_OVH_GATEWAY_MODEL)    PVE_OVH_GATEWAY_MODEL="$value" ;;
            PVE_OVH_VRACK_INTERFACE)  PVE_OVH_VRACK_INTERFACE="$value" ;;
            PVE_OVH_VRACK_IP_CIDR)    PVE_OVH_VRACK_IP_CIDR="$value" ;;
            PVE_OVH_ADDITIONAL_IPS)   PVE_OVH_ADDITIONAL_IPS="$value" ;;
            PVE_FEATURE_LUKS)         PVE_FEATURE_LUKS="$value" ;;
            PVE_LUKS_PASSPHRASE)      PVE_LUKS_PASSPHRASE="$value" ;;
            PVE_LUKS_UNLOCK_MODES)    PVE_LUKS_UNLOCK_MODES="$value" ;;
            PVE_LUKS_DROPBEAR_PORT)   PVE_LUKS_DROPBEAR_PORT="$value" ;;
            PVE_LUKS_WAN_MAC)         PVE_LUKS_WAN_MAC="$value" ;;
            PVE_LICENSE_KEY)          PVE_LICENSE_KEY="$value" ;;
            PVE_LICENSE_INSTANCE_ID)  PVE_LICENSE_INSTANCE_ID="$value" ;;
            PVE_LICENSE_ENDPOINT)     PVE_LICENSE_ENDPOINT="$value" ;;
            *)                        log_debug "Unknown config key: ${key}" ;;
        esac
    done < "$file"
}

config_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --provider)              PVE_PROVIDER="$2"; shift 2 ;;
            --hostname)              PVE_HOSTNAME="$2"; shift 2 ;;
            --fqdn)                  PVE_FQDN="$2"; shift 2 ;;
            --timezone)              PVE_TIMEZONE="$2"; shift 2 ;;
            --email)                 PVE_EMAIL="$2"; shift 2 ;;
            --password)              PVE_ROOT_PASSWORD="$2"; shift 2 ;;
            --ssh-keys)              PVE_SSH_KEYS="$2"; shift 2 ;;
            --private-subnet)        PVE_PRIVATE_SUBNET="$2"; shift 2 ;;
            --interface)             PVE_INTERFACE="$2"; shift 2 ;;
            --disk-mode)             PVE_DISK_MODE="$2"; shift 2 ;;
            --disks)                 PVE_DISKS="$2"; shift 2 ;;
            --filesystem)            PVE_FILESYSTEM="$2"; shift 2 ;;
            --zfs-raid)              PVE_ZFS_RAID="$2"; shift 2 ;;
            --zfs-compress)          PVE_ZFS_COMPRESS="$2"; shift 2 ;;
            --zfs-ashift)            PVE_ZFS_ASHIFT="$2"; shift 2 ;;
            --zfs-arc-max)           PVE_ZFS_ARC_MAX="$2"; shift 2 ;;
            --keyboard)              PVE_KEYBOARD="$2"; shift 2 ;;
            --country)               PVE_COUNTRY="$2"; shift 2 ;;
            --iso)                   PVE_ISO_PATH="$2"; shift 2 ;;
            --boot-mode)             PVE_BOOT_MODE="$2"; shift 2 ;;
            --dns)                   PVE_DNS_SERVERS="$2"; shift 2 ;;
            --network-mode)          PVE_NETWORK_MODE="$2"; shift 2 ;;
            --dhcp)                  PVE_ENABLE_DHCP=true; shift ;;
            --no-dhcp)               PVE_ENABLE_DHCP=false; shift ;;
            --debian-suite)          PVE_DEBIAN_SUITE="$2"; shift 2 ;;
            --config)                PVE_CONFIG_FILE="$2"; shift 2 ;;
            --unattended)            PVE_UNATTENDED=true; shift ;;
            --yes|-y)                PVE_SKIP_CONFIRM=true; shift ;;
            --debug)                 PVE_LOG_LEVEL=0; LOG_LEVEL=0; shift ;;
            --quiet)                 PVE_LOG_LEVEL=2; LOG_LEVEL=2; shift ;;
            --help|-h)               config_show_help; exit 0 ;;
            --version|-v)            echo "pve-dedicated ${PVE_INSTALLER_VERSION}"; exit 0 ;;
            # OVH-specific options
            --ovh-gateway-model)     PVE_OVH_GATEWAY_MODEL="$2"; shift 2 ;;
            --ovh-vrack-interface)   PVE_OVH_VRACK_INTERFACE="$2"; shift 2 ;;
            --ovh-vrack-ip)          PVE_OVH_VRACK_IP_CIDR="$2"; shift 2 ;;
            --ovh-additional-ips)    PVE_OVH_ADDITIONAL_IPS="$2"; shift 2 ;;
            # Premium options (LUKS host encryption)
            --enable-luks)           PVE_FEATURE_LUKS=true; shift ;;
            --luks-passphrase)       PVE_LUKS_PASSPHRASE="$2"; shift 2 ;;
            --luks-unlock-modes)     PVE_LUKS_UNLOCK_MODES="$2"; shift 2 ;;
            --luks-dropbear-port)    PVE_LUKS_DROPBEAR_PORT="$2"; shift 2 ;;
            --luks-wan-mac)          PVE_LUKS_WAN_MAC="$2"; shift 2 ;;
            # Premium license (validated against the corelix license Worker)
            --license-key)           PVE_LICENSE_KEY="$2"; shift 2 ;;
            --license-instance-id)   PVE_LICENSE_INSTANCE_ID="$2"; shift 2 ;;
            --license-endpoint)      PVE_LICENSE_ENDPOINT="$2"; shift 2 ;;
            *)
                die "Unknown option: $1 (use --help for usage)"
                ;;
        esac
    done
}

config_show_help() {
    cat <<'HELP'
Usage: pve-dedicated.sh [OPTIONS]

Proxmox VE Installer for Dedicated Servers (Hetzner, OVH)
Provided freely by Corelix.io - Made in France
Author: Amir Moradi

PROVIDER:
  --provider NAME        Provider: hetzner | ovh (auto-detected if omitted)

SYSTEM:
  --hostname NAME        Set hostname (default: interactive)
  --fqdn FQDN            Set fully qualified domain name
  --timezone TZ          Set timezone (e.g., UTC, Europe/Berlin)
  --email EMAIL          Set admin email address
  --password PASS        Set root password
  --ssh-keys "KEY..."    Set SSH public keys (space-separated)
  --keyboard LAYOUT      Keyboard layout (default: en-us)
  --country CODE         Country code (default: us)

DISK:
  --disk-mode MODE       Disk selection: auto, manual (default: auto)
  --disks LIST           Comma-separated disk list (e.g., nvme0n1,nvme1n1)
  --filesystem FS        Filesystem: zfs, ext4, xfs, btrfs (default: zfs)
  --zfs-raid LEVEL       ZFS RAID: raid0, raid1, raid10, raidz-1/2/3
  --zfs-compress ALG     ZFS compression: lz4, zstd, on, off
  --zfs-ashift N         ZFS ashift value
  --zfs-arc-max MiB      ZFS ARC max memory in MiB

NETWORK:
  --interface NAME       Network interface to use
  --private-subnet CIDR  Private subnet for NAT (e.g., 192.168.26.0/24)
  --network-mode MODE    Network: nat, routed, bridged (default: nat)
  --dhcp                 Enable DHCP server on NAT bridge (default)
  --no-dhcp              Disable DHCP server on NAT bridge
  --dns SERVERS          DNS servers (space-separated)

OVH-SPECIFIC:
  --ovh-gateway-model M  auto | classic | scale (HG/Scale/Advance use 100.64.0.1)
  --ovh-vrack-interface  Second NIC name for vRack bridge (vmbr2)
  --ovh-vrack-ip CIDR    Static IP/CIDR on vRack bridge (vmbr2)
  --ovh-additional-ips L Comma/space-separated /32s to route on vmbr0 (routed mode)

PREMIUM (LUKS host encryption -- requires premium build):
  --enable-luks          Request host-level LUKS full-disk encryption
  --luks-passphrase P    Passphrase (or read from /root/.luks_pass interactively)
  --luks-unlock-modes L  Comma-separated: passphrase,ssh,tpm (default: passphrase)
  --luks-dropbear-port N Pre-boot SSH port for cryptroot-unlock (default: 2222)
  --luks-wan-mac MAC     Pin pre-boot NIC by MAC (resilient across rename)

LICENSE (premium build):
  --license-key K        Creem.io license key (auto-set when launched via the
                         license bootstrap one-liner). Required for premium.
  --license-instance-id  Instance id returned by Creem activation; auto-set by
                         the bootstrap, persisted to /etc/pve-dedicated/license.json.
  --license-endpoint URL Override the license validation endpoint
                         (default: https://get.corelix.io/products/pve-dedicated/license)

INSTALL:
  --iso PATH             Path to Proxmox ISO (skip download)
  --boot-mode MODE       Boot mode: auto, uefi, legacy
  --debian-suite SUITE   Debian suite (default: trixie)
  --config FILE          Load configuration from .env file
  --unattended           Run without interactive prompts
  --yes, -y              Skip confirmation prompts
  --debug                Enable debug logging
  --quiet                Suppress info-level output
  --help, -h             Show this help message
  --version, -v          Show version

EXAMPLES:
  # Interactive mode (auto-detects provider)
  ./pve-dedicated.sh

  # Hetzner unattended
  ./pve-dedicated.sh --provider hetzner \
      --config configs/example-hetzner-ax102.env --unattended --yes

  # OVH unattended (Scale/HG range)
  ./pve-dedicated.sh --provider ovh --ovh-gateway-model scale \
      --hostname pve1 --fqdn pve1.example.com --password "s3cret" \
      --timezone UTC --email admin@example.com --unattended --yes
HELP
}

# Interactive configuration prompts
config_interactive() {
    log_info "Starting interactive configuration..."
    echo ""

    if [[ -z "$PVE_INTERFACE" ]]; then
        local default_iface
        default_iface="$(net_get_active_interface 2>/dev/null || echo "eth0")"
        local iface_list
        iface_list="$(net_list_interfaces_display 2>/dev/null || echo "eth0")"
        ui_read PVE_INTERFACE "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Network interface (${iface_list}): ")" "$default_iface"
    fi

    net_extract_info "$PVE_INTERFACE"

    echo ""
    ui_section "Detected Network"
    ui_kv "Interface" "$PVE_INTERFACE"
    ui_kv "IPv4" "$PVE_MAIN_IPV4_CIDR"
    ui_kv "Gateway" "$PVE_MAIN_IPV4_GW"
    ui_kv "MAC" "$PVE_MAC_ADDRESS"
    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        ui_kv "IPv6" "$PVE_IPV6_CIDR"
    fi
    echo ""

    if [[ -z "$PVE_HOSTNAME" ]]; then
        ui_read PVE_HOSTNAME "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Hostname: ")" "proxmox"
    fi

    if [[ -z "$PVE_FQDN" ]]; then
        ui_read PVE_FQDN "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} FQDN: ")" "${PVE_HOSTNAME}.example.com"
    fi

    if [[ -z "$PVE_TIMEZONE" ]]; then
        ui_read PVE_TIMEZONE "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Timezone: ")" "UTC"
    fi

    if [[ -z "$PVE_EMAIL" ]]; then
        ui_read PVE_EMAIL "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Admin email: ")" "admin@example.com"
    fi

    if [[ -z "$PVE_PRIVATE_SUBNET" ]]; then
        ui_read PVE_PRIVATE_SUBNET "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Private subnet: ")" "192.168.26.0/24"
    fi

    if [[ "$PVE_NETWORK_MODE" == "nat" ]]; then
        echo ""
        echo -e "  ${CLR_DIM}VMs on the NAT bridge (vmbr1) need IP addresses.${CLR_RESET}"
        echo -e "  ${CLR_DIM}A DHCP server (dnsmasq) gives VMs automatic connectivity.${CLR_RESET}"
        if ui_confirm "Enable DHCP server on the NAT bridge?" "y"; then
            PVE_ENABLE_DHCP=true
        else
            PVE_ENABLE_DHCP=false
            ui_warn "VMs will need manual static IP configuration"
        fi
    fi

    while [[ -z "$PVE_ROOT_PASSWORD" ]]; do
        ui_read PVE_ROOT_PASSWORD "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Root password: ")" "" "-s"
        if [[ -z "$PVE_ROOT_PASSWORD" ]]; then
            ui_warn "Password cannot be empty"
        fi
    done

    # SSH key setup
    if [[ -z "$PVE_SSH_KEYS" ]]; then
        _config_detect_ssh_keys
    fi

    config_derive_values
}

# Auto-detect SSH public keys from the rescue system and prompt user
_config_detect_ssh_keys() {
    local detected_keys=""

    # Check common locations for existing authorized keys
    for keyfile in /root/.ssh/authorized_keys /root/.ssh/id_*.pub; do
        if [[ -f "$keyfile" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" || "$line" =~ ^# ]] && continue
                if [[ "$line" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || [[ "$line" =~ ^ecdsa-sha2 ]]; then
                    if [[ -z "$detected_keys" ]]; then
                        detected_keys="$line"
                    else
                        detected_keys="${detected_keys}"$'\n'"${line}"
                    fi
                fi
            done < "$keyfile"
        fi
    done

    echo ""
    ui_section "SSH Security"

    if [[ -n "$detected_keys" ]]; then
        local key_count
        key_count="$(echo "$detected_keys" | wc -l)"
        ui_success "Found ${key_count} SSH public key(s) from rescue system"

        echo "$detected_keys" | while IFS= read -r k; do
            local key_type key_comment
            key_type="$(echo "$k" | awk '{print $1}')"
            key_comment="$(echo "$k" | awk '{print $NF}')"
            ui_detail "${key_type} ...${key_comment}"
        done
        echo ""

        if ui_confirm "Use these keys for Proxmox root access and harden SSH (disable password login)?"; then
            PVE_SSH_KEYS="$detected_keys"
            ui_success "SSH keys will be installed and password login disabled"
        else
            ui_warn "SSH password login will remain enabled (less secure)"
        fi
    else
        ui_warn "No SSH public keys detected in rescue system"
        echo ""
        echo -e "  ${CLR_DIM}To enable key-only SSH (recommended), provide your public key.${CLR_RESET}"
        echo -e "  ${CLR_DIM}Paste it below, or press Enter to skip.${CLR_RESET}"
        echo ""

        local manual_key=""
        ui_read manual_key "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} SSH public key (or Enter to skip): ")" ""

        if [[ -n "$manual_key" ]] && [[ "$manual_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
            PVE_SSH_KEYS="$manual_key"
            ui_success "SSH key accepted -- password login will be disabled"
        else
            if [[ -n "$manual_key" ]]; then
                ui_warn "Invalid key format (must start with ssh-rsa, ssh-ed25519, etc.)"
            fi
            ui_warn "No SSH keys configured -- password login will remain enabled"
            echo -e "  ${CLR_DIM}You can harden SSH later: see docs/TROUBLESHOOTING.md${CLR_RESET}"
        fi
    fi
}

# Calculate derived values from user inputs
config_derive_values() {
    if [[ -n "$PVE_PRIVATE_SUBNET" ]]; then
        local prefix
        prefix="$(echo "$PVE_PRIVATE_SUBNET" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)"
        PVE_PRIVATE_IP="${prefix}.1"
        local mask
        mask="$(echo "$PVE_PRIVATE_SUBNET" | cut -d'/' -f2)"
        PVE_PRIVATE_IP_CIDR="${PVE_PRIVATE_IP}/${mask}"
    fi

    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        local ipv6_prefix
        ipv6_prefix="$(echo "$PVE_IPV6_CIDR" | cut -d'/' -f1 | cut -d':' -f1-4)"
        PVE_FIRST_IPV6_CIDR="${ipv6_prefix}:1::1/80"
    else
        PVE_FIRST_IPV6_CIDR=""
    fi

    # Try to predict the real interface name for post-install config
    if command -v predict-check &>/dev/null; then
        PVE_PREDICTED_IFACE="$(predict-check 2>/dev/null | awk -F' -> ' '{print $2}' | head -n1)"
    fi
    if [[ -z "$PVE_PREDICTED_IFACE" ]]; then
        PVE_PREDICTED_IFACE="$PVE_INTERFACE"
    fi

    log_debug "Derived: PRIVATE_IP_CIDR=${PVE_PRIVATE_IP_CIDR}"
    log_debug "Derived: PREDICTED_IFACE=${PVE_PREDICTED_IFACE}"
    log_debug "Derived: FIRST_IPV6_CIDR=${PVE_FIRST_IPV6_CIDR}"
}
