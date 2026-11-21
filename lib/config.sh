# CLI argument parsing, config file loading, and defaults
# shellcheck shell=bash
# The PVE_* globals declared here are consumed by the other modules, which
# the linter cannot see when checking this file on its own.
# shellcheck disable=SC2034

# All config variables are prefixed with PVE_
# Precedence: built-in defaults < configs/default.env < --config FILE < CLI args
#             < interactive prompts (only for values not set explicitly)

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
declare -g PVE_ISO_VERSION=""      # pin e.g. "9", "9.2" or "9.2-1"; empty = latest
declare -g PVE_ISO_VERIFY=true     # verify the downloaded ISO's SHA-256
declare -g PVE_BOOT_MODE="auto"    # auto, uefi, legacy
declare -g PVE_DNS_SERVERS=""      # empty = provider default (provider_resolve)
declare -g PVE_UNATTENDED=false
declare -g PVE_CONFIG_FILE=""
declare -g PVE_SKIP_CONFIRM=false
declare -g PVE_LOG_LEVEL=1
declare -g PVE_WORKING_DIR="${PVE_WORKING_DIR:-/root}"
declare -g PVE_DEBIAN_SUITE=""     # empty = derived from the ISO major version
declare -g PVE_NETWORK_MODE="nat"  # nat, routed, bridged
declare -g PVE_ENABLE_DHCP=true    # dnsmasq DHCP on vmbr1 (NAT mode only)
declare -g PVE_ADDITIONAL_IPS=""   # routed mode: space/comma separated IPs routed onto vmbr0

# Hetzner vSwitch: tagged VLAN between Robot servers, optionally coupled to a
# Hetzner Cloud Network. Empty VLAN = no vSwitch.
declare -g PVE_HETZNER_VSWITCH_VLAN="${PVE_HETZNER_VSWITCH_VLAN:-}"       # 4000-4091
declare -g PVE_HETZNER_VSWITCH_IP="${PVE_HETZNER_VSWITCH_IP:-}"           # this host, CIDR
declare -g PVE_HETZNER_VSWITCH_GATEWAY="${PVE_HETZNER_VSWITCH_GATEWAY:-}" # default: first host
declare -g PVE_HETZNER_VSWITCH_ROUTES="${PVE_HETZNER_VSWITCH_ROUTES:-}"   # CIDRs via the gateway
declare -g PVE_HETZNER_VSWITCH_MTU="${PVE_HETZNER_VSWITCH_MTU:-1400}"
declare -g PVE_HETZNER_VSWITCH_BRIDGE="${PVE_HETZNER_VSWITCH_BRIDGE:-false}" # vmbr<VLAN> for guests

# Premium feature flags (gated; LUKS implementation only ships in premium build)
declare -g PVE_FEATURE_LUKS="${PVE_FEATURE_LUKS:-false}"
declare -g PVE_LUKS_PASSPHRASE="${PVE_LUKS_PASSPHRASE:-}"
# Empty = "not explicitly set". The premium LUKS pre-flight resolver will
# prompt interactively (default `passphrase,ssh`) or pick a sensible default
# in unattended mode. CLI/config-file values continue to win unchanged.
declare -g PVE_LUKS_UNLOCK_MODES="${PVE_LUKS_UNLOCK_MODES:-}"
declare -g PVE_LUKS_DROPBEAR_PORT="${PVE_LUKS_DROPBEAR_PORT:-2222}"
declare -g PVE_LUKS_WAN_MAC="${PVE_LUKS_WAN_MAC:-}"
# Automatic unlock via Clevis (unlock modes `tpm` and/or `tang`).
declare -g PVE_LUKS_TPM_PCRS="${PVE_LUKS_TPM_PCRS:-0,1,2,7}"
declare -g PVE_LUKS_TANG_URLS="${PVE_LUKS_TANG_URLS:-}"
declare -g PVE_LUKS_TANG_THUMBPRINTS="${PVE_LUKS_TANG_THUMBPRINTS:-}"
declare -g PVE_LUKS_AUTO_UNLOCK_POLICY="${PVE_LUKS_AUTO_UNLOCK_POLICY:-all}"   # all | any
declare -g PVE_LUKS_WIPE_FREE_SPACE="${PVE_LUKS_WIPE_FREE_SPACE:-true}"
# LUKS on a ZFS stripe (raid0): converted by evacuating one disk at a time.
declare -g PVE_LUKS_ALLOW_RAID0="${PVE_LUKS_ALLOW_RAID0:-false}"

# Premium: ZFS native encryption of the VM data datasets (any RAID level).
# Shares PVE_LUKS_TPM_PCRS / _TANG_URLS / _TANG_THUMBPRINTS / _AUTO_UNLOCK_POLICY.
declare -g PVE_ZFS_ENCRYPTION="${PVE_ZFS_ENCRYPTION:-false}"
declare -g PVE_ZFS_ENCRYPTION_PASSPHRASE="${PVE_ZFS_ENCRYPTION_PASSPHRASE:-}"
declare -g PVE_ZFS_UNLOCK_MODES="${PVE_ZFS_UNLOCK_MODES:-}"     # passphrase,tpm,tang
declare -g PVE_ZFS_ENCRYPT_LOCAL="${PVE_ZFS_ENCRYPT_LOCAL:-true}" # also /var/lib/vz

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
declare -g PVE_IPV6_GW_DETECTED=""
declare -g PVE_PRIVATE_IP=""
declare -g PVE_PRIVATE_IP_CIDR=""
declare -g PVE_PREDICTED_IFACE=""
declare -g PVE_FIRST_IPV6_CIDR=""
declare -g PVE_QEMU_CPUS=""
declare -g PVE_QEMU_RAM_MB=""

# Keys set by the user (CLI or --config file), as opposed to built-in or
# configs/default.env defaults. Interactive mode only prompts for the rest.
declare -gA PVE_CONFIG_EXPLICIT=()

# --- Key registry ------------------------------------------------------------

# Return 0 when KEY is a config variable this installer understands.
_config_is_known_key() {
    case "$1" in
        PVE_PROVIDER|PVE_HOSTNAME|PVE_FQDN|PVE_TIMEZONE|PVE_EMAIL|\
        PVE_ROOT_PASSWORD|PVE_SSH_KEYS|PVE_PRIVATE_SUBNET|PVE_INTERFACE|\
        PVE_DISK_MODE|PVE_DISKS|PVE_FILESYSTEM|PVE_ZFS_RAID|PVE_ZFS_COMPRESS|\
        PVE_ZFS_ASHIFT|PVE_ZFS_ARC_MAX|PVE_KEYBOARD|PVE_COUNTRY|PVE_ISO_PATH|\
        PVE_ISO_VERSION|PVE_ISO_VERIFY|PVE_BOOT_MODE|PVE_DNS_SERVERS|\
        PVE_NETWORK_MODE|PVE_ENABLE_DHCP|PVE_DEBIAN_SUITE|PVE_LOG_LEVEL|\
        PVE_ADDITIONAL_IPS|PVE_OVH_GATEWAY_MODEL|PVE_OVH_VRACK_INTERFACE|\
        PVE_OVH_VRACK_IP_CIDR|PVE_OVH_ADDITIONAL_IPS|PVE_OVH_IPV6_GATEWAY|\
        PVE_HETZNER_VSWITCH_VLAN|PVE_HETZNER_VSWITCH_IP|\
        PVE_HETZNER_VSWITCH_GATEWAY|PVE_HETZNER_VSWITCH_ROUTES|\
        PVE_HETZNER_VSWITCH_MTU|PVE_HETZNER_VSWITCH_BRIDGE|\
        PVE_FEATURE_LUKS|PVE_LUKS_PASSPHRASE|PVE_LUKS_UNLOCK_MODES|\
        PVE_LUKS_DROPBEAR_PORT|PVE_LUKS_WAN_MAC|PVE_LUKS_TPM_PCRS|\
        PVE_LUKS_TANG_URLS|PVE_LUKS_TANG_THUMBPRINTS|\
        PVE_LUKS_AUTO_UNLOCK_POLICY|PVE_LUKS_WIPE_FREE_SPACE|PVE_LUKS_ALLOW_RAID0|\
        PVE_ZFS_ENCRYPTION|PVE_ZFS_ENCRYPTION_PASSPHRASE|PVE_ZFS_UNLOCK_MODES|\
        PVE_ZFS_ENCRYPT_LOCAL|PVE_LICENSE_KEY|\
        PVE_LICENSE_INSTANCE_ID|PVE_LICENSE_ENDPOINT|PVE_WORKING_DIR)
            return 0 ;;
    esac
    return 1
}

# Assign a config value. EXPLICIT=true records that the user chose it.
_config_set() {
    local key="$1"
    local value="$2"
    local explicit="${3:-true}"

    printf -v "$key" '%s' "$value"
    if [[ "$key" == "PVE_LOG_LEVEL" ]]; then
        LOG_LEVEL="$value"
    fi
    if [[ "$explicit" == true ]]; then
        PVE_CONFIG_EXPLICIT["$key"]=1
    fi
}

config_is_explicit() {
    [[ -n "${PVE_CONFIG_EXPLICIT[$1]:-}" ]]
}

# --- dotenv parsing ----------------------------------------------------------

# Scan the body of a double-quoted value (text after the opening quote).
# Sets _CFG_DQ_VALUE and _CFG_DQ_CLOSED. Supports \" \\ \$ and \` escapes;
# any other backslash is kept literally (so Windows-ish paths survive).
_config_scan_dquoted() {
    local raw="$1"
    local out="" ch next i len="${#raw}"
    _CFG_DQ_CLOSED=false
    for (( i = 0; i < len; i++ )); do
        ch="${raw:i:1}"
        if [[ "$ch" == "\\" ]] && (( i + 1 < len )); then
            next="${raw:i+1:1}"
            case "$next" in
                '"'|"\\"|'$'|'`') out+="$next"; i=$(( i + 1 )); continue ;;
            esac
            out+="$ch"
            continue
        fi
        if [[ "$ch" == '"' ]]; then
            _CFG_DQ_CLOSED=true
            break
        fi
        out+="$ch"
    done
    _CFG_DQ_VALUE="$out"
}

# Parse a dotenv-style file without executing it. Supported syntax:
#   KEY=value              unquoted; trailing "  # comment" is stripped
#   KEY="value"            double-quoted; may span lines; \" \\ \$ escapes
#   KEY='value'            single-quoted; literal; may span lines
#   export KEY=value       optional export prefix
# Lines starting with # and blank lines are ignored.
# The file is only read; _config_apply_file_key merely reports its name.
# shellcheck disable=SC2094
config_load_file() {
    local file="$1"
    local explicit="${2:-true}"

    [[ -f "$file" ]] || die "Config file not found: ${file}"
    [[ -r "$file" ]] || die "Config file not readable: ${file}"

    log_info "Loading configuration from ${file}"

    local line key rest lineno=0
    local pending_key="" pending_quote="" pending_raw="" pending_line=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 ))
        line="${line%$'\r'}"

        if [[ -n "$pending_key" ]]; then
            pending_raw+=$'\n'"$line"
            if [[ "$pending_quote" == '"' ]]; then
                _config_scan_dquoted "$pending_raw"
                if [[ "$_CFG_DQ_CLOSED" == true ]]; then
                    _config_apply_file_key "$pending_key" "$_CFG_DQ_VALUE" "$explicit" "$file" "$pending_line"
                    pending_key=""
                fi
            elif [[ "$pending_raw" == *"'"* ]]; then
                _config_apply_file_key "$pending_key" "${pending_raw%%\'*}" "$explicit" "$file" "$pending_line"
                pending_key=""
            fi
            continue
        fi

        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^export[[:space:]]+(.*)$ ]]; then
            line="${BASH_REMATCH[1]}"
        fi
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            log_warn "${file}:${lineno}: ignoring malformed line"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        rest="${rest#"${rest%%[![:space:]]*}"}"

        case "$rest" in
            '"'*)
                _config_scan_dquoted "${rest:1}"
                if [[ "$_CFG_DQ_CLOSED" == true ]]; then
                    _config_apply_file_key "$key" "$_CFG_DQ_VALUE" "$explicit" "$file" "$lineno"
                else
                    pending_key="$key"; pending_quote='"'; pending_raw="${rest:1}"; pending_line="$lineno"
                fi
                ;;
            "'"*)
                local body="${rest:1}"
                if [[ "$body" == *"'"* ]]; then
                    _config_apply_file_key "$key" "${body%%\'*}" "$explicit" "$file" "$lineno"
                else
                    pending_key="$key"; pending_quote="'"; pending_raw="$body"; pending_line="$lineno"
                fi
                ;;
            *)
                if [[ "$rest" == \#* ]]; then
                    rest=""
                elif [[ "$rest" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
                    rest="${BASH_REMATCH[1]}"
                fi
                rest="${rest%"${rest##*[![:space:]]}"}"
                _config_apply_file_key "$key" "$rest" "$explicit" "$file" "$lineno"
                ;;
        esac
    done < "$file"

    if [[ -n "$pending_key" ]]; then
        die "${file}:${pending_line}: unterminated quoted value for ${pending_key}"
    fi
}

_config_apply_file_key() {
    local key="$1" value="$2" explicit="$3" file="$4" lineno="$5"
    if ! _config_is_known_key "$key"; then
        log_warn "${file}:${lineno}: unknown config key '${key}' (ignored)"
        return 0
    fi
    _config_set "$key" "$value" "$explicit"
}

config_load_defaults() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local defaults_file="${script_dir}/configs/default.env"

    if [[ -f "$defaults_file" ]]; then
        log_debug "Loading defaults from ${defaults_file}"
        config_load_file "$defaults_file" false
    fi
}

# --- CLI parsing -------------------------------------------------------------

# Map a value-taking CLI option to its config variable.
_config_opt_var() {
    case "$1" in
        --provider)            echo PVE_PROVIDER ;;
        --hostname)            echo PVE_HOSTNAME ;;
        --fqdn)                echo PVE_FQDN ;;
        --timezone)            echo PVE_TIMEZONE ;;
        --email)               echo PVE_EMAIL ;;
        --password)            echo PVE_ROOT_PASSWORD ;;
        --ssh-keys)            echo PVE_SSH_KEYS ;;
        --private-subnet)      echo PVE_PRIVATE_SUBNET ;;
        --interface)           echo PVE_INTERFACE ;;
        --disk-mode)           echo PVE_DISK_MODE ;;
        --disks)               echo PVE_DISKS ;;
        --filesystem)          echo PVE_FILESYSTEM ;;
        --zfs-raid)            echo PVE_ZFS_RAID ;;
        --zfs-compress)        echo PVE_ZFS_COMPRESS ;;
        --zfs-ashift)          echo PVE_ZFS_ASHIFT ;;
        --zfs-arc-max)         echo PVE_ZFS_ARC_MAX ;;
        --keyboard)            echo PVE_KEYBOARD ;;
        --country)             echo PVE_COUNTRY ;;
        --iso)                 echo PVE_ISO_PATH ;;
        --pve-version)         echo PVE_ISO_VERSION ;;
        --boot-mode)           echo PVE_BOOT_MODE ;;
        --dns)                 echo PVE_DNS_SERVERS ;;
        --network-mode)        echo PVE_NETWORK_MODE ;;
        --additional-ips)      echo PVE_ADDITIONAL_IPS ;;
        --debian-suite)        echo PVE_DEBIAN_SUITE ;;
        --config)              echo PVE_CONFIG_FILE ;;
        --working-dir)         echo PVE_WORKING_DIR ;;
        --ovh-gateway-model)   echo PVE_OVH_GATEWAY_MODEL ;;
        --hetzner-vswitch-vlan|--vswitch-vlan)       echo PVE_HETZNER_VSWITCH_VLAN ;;
        --hetzner-vswitch-ip|--vswitch-ip)           echo PVE_HETZNER_VSWITCH_IP ;;
        --hetzner-vswitch-gateway|--vswitch-gateway) echo PVE_HETZNER_VSWITCH_GATEWAY ;;
        --hetzner-vswitch-routes|--vswitch-routes)   echo PVE_HETZNER_VSWITCH_ROUTES ;;
        --hetzner-vswitch-mtu|--vswitch-mtu)         echo PVE_HETZNER_VSWITCH_MTU ;;
        --ovh-vrack-interface) echo PVE_OVH_VRACK_INTERFACE ;;
        --ovh-vrack-ip)        echo PVE_OVH_VRACK_IP_CIDR ;;
        --ovh-additional-ips)  echo PVE_OVH_ADDITIONAL_IPS ;;
        --ovh-ipv6-gateway)    echo PVE_OVH_IPV6_GATEWAY ;;
        --luks-passphrase)     echo PVE_LUKS_PASSPHRASE ;;
        --luks-unlock-modes)   echo PVE_LUKS_UNLOCK_MODES ;;
        --luks-dropbear-port)  echo PVE_LUKS_DROPBEAR_PORT ;;
        --luks-wan-mac)        echo PVE_LUKS_WAN_MAC ;;
        --luks-tpm-pcrs|--tpm-pcrs) echo PVE_LUKS_TPM_PCRS ;;
        --luks-tang-url|--tang-url) echo PVE_LUKS_TANG_URLS ;;
        --luks-tang-thumbprint|--tang-thumbprint) echo PVE_LUKS_TANG_THUMBPRINTS ;;
        --luks-auto-unlock-policy|--auto-unlock-policy) echo PVE_LUKS_AUTO_UNLOCK_POLICY ;;
        --zfs-encryption-passphrase) echo PVE_ZFS_ENCRYPTION_PASSPHRASE ;;
        --zfs-unlock-modes)    echo PVE_ZFS_UNLOCK_MODES ;;
        --license-key)         echo PVE_LICENSE_KEY ;;
        --license-instance-id) echo PVE_LICENSE_INSTANCE_ID ;;
        --license-endpoint)    echo PVE_LICENSE_ENDPOINT ;;
        *) return 1 ;;
    esac
}

config_parse_args() {
    local opt var
    while [[ $# -gt 0 ]]; do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then
            set -- "${opt%%=*}" "${opt#*=}" "${@:2}"
            opt="$1"
        fi

        if var="$(_config_opt_var "$opt")"; then
            if [[ $# -lt 2 ]]; then
                die "Option ${opt} requires a value (use --help for usage)"
            fi
            _config_set "$var" "$2" true
            shift 2
            continue
        fi

        case "$opt" in
            --dhcp)          _config_set PVE_ENABLE_DHCP true ;;
            --no-dhcp)       _config_set PVE_ENABLE_DHCP false ;;
            --no-iso-verify) _config_set PVE_ISO_VERIFY false ;;
            --unattended)    PVE_UNATTENDED=true ;;
            --yes|-y)        PVE_SKIP_CONFIRM=true ;;
            --debug)         _config_set PVE_LOG_LEVEL 0 ;;
            --quiet)         _config_set PVE_LOG_LEVEL 2 ;;
            --enable-luks)   _config_set PVE_FEATURE_LUKS true ;;
            --luks-no-wipe-free-space|--no-wipe-free-space) _config_set PVE_LUKS_WIPE_FREE_SPACE false ;;
            --luks-allow-raid0) _config_set PVE_LUKS_ALLOW_RAID0 true ;;
            --hetzner-vswitch-bridge|--vswitch-bridge) _config_set PVE_HETZNER_VSWITCH_BRIDGE true ;;
            --zfs-encrypt)   _config_set PVE_ZFS_ENCRYPTION true ;;
            --no-zfs-encrypt-local) _config_set PVE_ZFS_ENCRYPT_LOCAL false ;;
            --help|-h)       config_show_help; exit 0 ;;
            --version|-v)    echo "pve-dedicated ${PVE_INSTALLER_VERSION}"; exit 0 ;;
            *)               die "Unknown option: ${opt} (use --help for usage)" ;;
        esac
        shift
    done
}

config_show_help() {
    cat <<'HELP'
Usage: pve-dedicated.sh [OPTIONS]

Proxmox VE Installer for Dedicated Servers (Hetzner, OVH)
Provided freely by Corelix.io - Made in France
Author: Amir Moradi

Every OPTION VALUE can also be written as --option=value.

PROVIDER:
  --provider NAME        Provider: hetzner | ovh (auto-detected if omitted)

SYSTEM:
  --hostname NAME        Short hostname (default: first label of --fqdn)
  --fqdn FQDN            Fully qualified domain name (must start with hostname)
  --timezone TZ          Timezone (e.g., UTC, Europe/Berlin)
  --email EMAIL          Admin email address
  --password PASS        Root password (min. 8 characters; stored hashed)
  --ssh-keys "KEYS"      SSH public keys, newline- or space-separated
  --keyboard LAYOUT      Keyboard layout (default: en-us)
  --country CODE         Two-letter country code (default: us)

DISK:
  --disk-mode MODE       Disk selection: auto, manual (default: auto)
  --disks LIST           Comma-separated disk list (e.g., nvme0n1,nvme1n1)
  --filesystem FS        Filesystem: zfs, ext4, xfs, btrfs (default: zfs)
  --zfs-raid LEVEL       ZFS RAID: raid0, raid1, raid10, raidz-1/2/3
  --zfs-compress ALG     ZFS compression: on, off, lz4, zstd, gzip, lzjb, zle
  --zfs-ashift N         ZFS ashift value (9-16)
  --zfs-arc-max MiB      ZFS ARC max memory in MiB

NETWORK:
  --interface NAME       Network interface to use (rescue-side name)
  --network-mode MODE    Network: nat, routed, bridged (default: nat)
  --private-subnet CIDR  Private NAT subnet for vmbr1 (e.g., 192.168.26.0/24)
  --dhcp                 Enable DHCP server on NAT bridge (default)
  --no-dhcp              Disable DHCP server on NAT bridge
  --additional-ips L     Routed mode: comma/space-separated IPs routed onto vmbr0
  --dns SERVERS          DNS servers (space-separated; default: provider DNS)

HETZNER vSWITCH (private VLAN; recommended path to Tang servers):
  --vswitch-vlan ID      vSwitch VLAN ID from Robot (4000-4091)
  --vswitch-ip CIDR      This server's vSwitch address (e.g. 10.0.1.3/24)
  --vswitch-routes L     CIDRs reached through the vSwitch gateway, e.g. the
                         Cloud Network range 10.0.0.0/16
  --vswitch-gateway IP   Gateway for those routes (default: first host of
                         the vSwitch subnet, as Hetzner Cloud Networks use)
  --vswitch-mtu N        MTU (default: 1400, required by Hetzner)
  --vswitch-bridge       Also create bridge vmbr<VLAN> for guests
  (--hetzner-vswitch-* are accepted as long forms)

OVH-SPECIFIC:
  --ovh-gateway-model M  auto | classic | scale (HG/Scale/Advance use 100.64.0.1)
  --ovh-vrack-interface  Second NIC name for vRack bridge (vmbr2)
  --ovh-vrack-ip CIDR    Static IP/CIDR on vRack bridge (vmbr2)
  --ovh-ipv6-gateway GW  IPv6 gateway from the OVH Control Panel (default:
                         detected from rescue, else derived from the prefix)
  --ovh-additional-ips L Alias of --additional-ips

PREMIUM (LUKS host encryption -- requires premium build):
  --enable-luks          Request host-level LUKS full-disk encryption
  --luks-passphrase P    Passphrase (prompted interactively when omitted)
  --luks-unlock-modes L  Comma-separated: passphrase,ssh,tpm,tang
                         (default: passphrase; passphrase is always kept)
  --luks-dropbear-port N Pre-boot SSH port for cryptroot-unlock (default: 2222)
  --luks-wan-mac MAC     Pin pre-boot NIC by MAC (resilient across rename)
  --luks-tpm-pcrs L      PCRs the TPM key is sealed to (default: 0,1,2,7)
  --luks-tang-url L      Tang server URL(s), comma-separated (adds mode tang)
  --luks-tang-thumbprint L  Tang signing-key thumbprint(s), same order as URLs
  --luks-auto-unlock-policy P  With tpm AND tang: all = both required
                         (default), any = either one is enough
  --luks-no-wipe-free-space  Skip overwriting free pool space after
                         encryption (see docs/premium/luks.md)
  --luks-allow-raid0     Allow LUKS on a ZFS raid0 stripe (no redundancy;
                         converted by evacuating one disk at a time)

PREMIUM (ZFS native encryption of VM data -- requires premium build):
  --zfs-encrypt          Encrypt rpool/data (VM disks) and /var/lib/vz with
                         ZFS native encryption; works with any RAID level
  --zfs-encryption-passphrase P  Recovery passphrase (prompted if omitted)
  --zfs-unlock-modes L   passphrase,tpm,tang (default: passphrase; the host
                         boots normally and you run `pve-zfs-crypt unlock`)
  --no-zfs-encrypt-local Keep /var/lib/vz (local backups, ISOs) unencrypted
  --tang-url, --tang-thumbprint, --tpm-pcrs, --auto-unlock-policy,
  --no-wipe-free-space   Same as the --luks-* forms; shared by LUKS and ZFS
                         encryption

LICENSE (premium build):
  --license-key K        Creem.io license key (auto-set when launched via the
                         license bootstrap one-liner). Required for premium.
  --license-instance-id  Instance id returned by Creem activation; auto-set by
                         the bootstrap, persisted to /etc/pve-dedicated/license.json.
  --license-endpoint URL Override the license validation endpoint
                         (default: https://get.corelix.io/products/pve-dedicated/license)

INSTALL:
  --iso PATH             Path to a Proxmox VE ISO (skip download)
  --pve-version V        Pin the downloaded ISO: 9, 9.2 or 9.2-1 (default: latest)
  --no-iso-verify        Skip SHA-256 verification of the downloaded ISO
  --boot-mode MODE       Boot mode: auto, uefi, legacy
  --debian-suite SUITE   APT suite for the installed system
                         (default: derived from the ISO, e.g. 9.x -> trixie)
  --working-dir DIR      Working directory for ISO, logs and generated files
                         (default: /root)
  --config FILE          Load configuration from .env file
  --unattended           Run without interactive prompts
  --yes, -y              Skip confirmation prompts
  --debug                Enable debug logging
  --quiet                Suppress info-level output
  --help, -h             Show this help message
  --version, -v          Show version

ENVIRONMENT:
  NO_COLOR=1             Disable colored output

EXAMPLES:
  # Interactive mode (auto-detects provider)
  ./pve-dedicated.sh

  # Hetzner unattended
  ./pve-dedicated.sh --provider hetzner \
      --config configs/example-hetzner-ax102.env --unattended --yes

  # OVH unattended (Scale/HG range)
  ./pve-dedicated.sh --provider ovh --ovh-gateway-model scale \
      --fqdn pve1.example.com --password 's3cret-pass' \
      --timezone UTC --email admin@example.com --unattended --yes
HELP
}

# --- SSH keys ----------------------------------------------------------------

# Return 0 when TOKEN is an OpenSSH public key type (incl. FIDO and certs).
_config_is_ssh_key_type() {
    [[ "$1" =~ ^(sk-)?(ssh-[a-z0-9]+|ecdsa-sha2-nistp(256|384|521))(@openssh\.com)?(-cert-v01@openssh\.com)?$ ]]
}

# Normalize SSH public keys to one key per line. Accepts keys separated by
# newlines or by spaces (as the --ssh-keys help text always promised), keeps
# comments, drops duplicates (same type + blob) and ignores # comment lines.
config_normalize_ssh_keys() {
    local raw="$1"
    local -a keys=()
    local -A seen=()
    local line tok current="" current_id="" prefix=""

    _config_flush_key() {
        if [[ -n "$current" ]] && [[ -z "${seen[$current_id]:-}" ]]; then
            seen["$current_id"]=1
            keys+=("$current")
        fi
        current=""
        current_id=""
    }

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        local -a toks=()
        read -ra toks <<< "$line"
        local i
        for (( i = 0; i < ${#toks[@]}; i++ )); do
            tok="${toks[i]}"
            if _config_is_ssh_key_type "$tok" && (( i + 1 < ${#toks[@]} )) \
                && [[ "${toks[i+1]}" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
                _config_flush_key
                current="${prefix:+${prefix} }${tok} ${toks[i+1]}"
                current_id="${tok} ${toks[i+1]}"
                prefix=""
                i=$(( i + 1 ))
            elif [[ -n "$current" ]]; then
                current+=" ${tok}"
            else
                prefix+="${prefix:+ }${tok}"
            fi
        done
        _config_flush_key
        prefix=""
    done <<< "$raw"

    unset -f _config_flush_key
    if [[ ${#keys[@]} -gt 0 ]]; then
        printf '%s\n' "${keys[@]}"
    fi
}

# --- Interactive configuration -----------------------------------------------

_config_prompt() {
    local var="$1" label="$2" default="$3"
    if config_is_explicit "$var" && [[ -n "${!var}" ]]; then
        return 0
    fi
    local answer=""
    ui_read answer "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} ${label}: ")" "$default"
    _config_set "$var" "$answer" true
}

config_interactive() {
    log_info "Starting interactive configuration..."
    echo ""

    if [[ -z "$PVE_INTERFACE" ]]; then
        local default_iface iface_list
        default_iface="$(net_get_active_interface 2>/dev/null || echo "eth0")"
        iface_list="$(net_list_interfaces_display 2>/dev/null || echo "eth0")"
        ui_read PVE_INTERFACE "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Network interface (${iface_list}): ")" "$default_iface"
        net_extract_info "$PVE_INTERFACE"
        PVE_PREDICTED_IFACE="$(net_get_predicted_name)"
    fi

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

    # FQDN is the source of truth for the auto-installer; hostname is its
    # first label. Offer the hostname first because that is what people
    # think in, then propose an FQDN in the same domain.
    local default_host="${PVE_HOSTNAME:-${PVE_FQDN%%.*}}"
    if config_is_explicit PVE_FQDN && ! config_is_explicit PVE_HOSTNAME; then
        _config_set PVE_HOSTNAME "${PVE_FQDN%%.*}" true
    fi
    _config_prompt PVE_HOSTNAME "Hostname" "${default_host:-proxmox}"

    local domain="example.com"
    if [[ "$PVE_FQDN" == *.* ]]; then
        domain="${PVE_FQDN#*.}"
    fi
    _config_prompt PVE_FQDN "FQDN" "${PVE_HOSTNAME}.${domain}"
    _config_prompt PVE_TIMEZONE "Timezone" "${PVE_TIMEZONE:-UTC}"
    _config_prompt PVE_EMAIL "Admin email" "${PVE_EMAIL:-admin@example.com}"

    if [[ "$PVE_NETWORK_MODE" == "nat" ]]; then
        _config_prompt PVE_PRIVATE_SUBNET "Private NAT subnet (vmbr1)" "${PVE_PRIVATE_SUBNET:-192.168.26.0/24}"

        if ! config_is_explicit PVE_ENABLE_DHCP; then
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
    fi

    while [[ -z "$PVE_ROOT_PASSWORD" ]]; do
        local pass1="" pass2=""
        ui_read pass1 "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Root password (min. 8 chars): ")" "" "-s"
        if [[ ${#pass1} -lt 8 ]]; then
            ui_warn "Password must be at least 8 characters"
            continue
        fi
        ui_read pass2 "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Confirm root password: ")" "" "-s"
        if [[ "$pass1" != "$pass2" ]]; then
            ui_warn "Passwords do not match -- try again"
            continue
        fi
        PVE_ROOT_PASSWORD="$pass1"
    done

    if [[ -z "$PVE_SSH_KEYS" ]]; then
        _config_detect_ssh_keys
    fi

    config_derive_values
}

# Auto-detect SSH public keys from the rescue system and prompt user
_config_detect_ssh_keys() {
    local raw="" keyfile
    for keyfile in /root/.ssh/authorized_keys /root/.ssh/authorized_keys2 /root/.ssh/id_*.pub; do
        if [[ -f "$keyfile" ]]; then
            raw+="$(cat "$keyfile")"$'\n'
        fi
    done

    local detected_keys
    detected_keys="$(config_normalize_ssh_keys "$raw")"

    echo ""
    ui_section "SSH Security"

    if [[ -n "$detected_keys" ]]; then
        local key_count
        key_count="$(grep -c . <<< "$detected_keys")"
        ui_success "Found ${key_count} SSH public key(s) from rescue system"

        local k key_type key_comment
        while IFS= read -r k; do
            key_type="$(awk '{print $1}' <<< "$k")"
            key_comment="$(awk '{ if (NF > 2) { for (i = 3; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "") } else printf "(no comment)" }' <<< "$k")"
            ui_detail "${key_type} ${key_comment}"
        done <<< "$detected_keys"
        echo ""

        if ui_confirm "Use these keys for Proxmox root access and harden SSH (disable password login)?"; then
            PVE_SSH_KEYS="$detected_keys"
            ui_success "SSH keys will be installed and password login disabled"
        else
            ui_warn "SSH password login will remain enabled (less secure)"
        fi
        return 0
    fi

    ui_warn "No SSH public keys detected in rescue system"
    echo ""
    echo -e "  ${CLR_DIM}To enable key-only SSH (recommended), provide your public key.${CLR_RESET}"
    echo -e "  ${CLR_DIM}Paste it below, or press Enter to skip.${CLR_RESET}"
    echo ""

    local manual_key=""
    ui_read manual_key "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} SSH public key (or Enter to skip): ")" ""
    local normalized=""
    if [[ -n "$manual_key" ]]; then
        normalized="$(config_normalize_ssh_keys "$manual_key")"
    fi

    if [[ -n "$normalized" ]]; then
        PVE_SSH_KEYS="$normalized"
        ui_success "SSH key accepted -- password login will be disabled"
    else
        if [[ -n "$manual_key" ]]; then
            ui_warn "Invalid key format (expected e.g. 'ssh-ed25519 AAAA... comment')"
        fi
        ui_warn "No SSH keys configured -- password login will remain enabled"
        echo -e "  ${CLR_DIM}You can harden SSH later: see .claude/docs/TROUBLESHOOTING.md${CLR_RESET}"
    fi
}

# Calculate derived values from user inputs. Safe to call more than once.
config_derive_values() {
    if [[ -n "$PVE_FQDN" ]] && { [[ -z "$PVE_HOSTNAME" ]] || ! config_is_explicit PVE_HOSTNAME; } \
        && config_is_explicit PVE_FQDN; then
        PVE_HOSTNAME="${PVE_FQDN%%.*}"
    fi
    if [[ -n "$PVE_HOSTNAME" ]] && ! config_is_explicit PVE_FQDN; then
        local domain="example.com"
        [[ "$PVE_FQDN" == *.* ]] && domain="${PVE_FQDN#*.}"
        PVE_FQDN="${PVE_HOSTNAME}.${domain}"
    fi

    PVE_PRIVATE_IP=""
    PVE_PRIVATE_IP_CIDR=""
    if [[ -n "$PVE_PRIVATE_SUBNET" ]] && [[ "$PVE_PRIVATE_SUBNET" == */* ]]; then
        local mask="${PVE_PRIVATE_SUBNET#*/}"
        if PVE_PRIVATE_IP="$(net_ipv4_host "$PVE_PRIVATE_SUBNET" 1 2>/dev/null)"; then
            PVE_PRIVATE_IP_CIDR="${PVE_PRIVATE_IP}/${mask}"
        else
            PVE_PRIVATE_IP=""
        fi
    fi

    PVE_FIRST_IPV6_CIDR=""
    if [[ -n "$PVE_IPV6_CIDR" ]]; then
        local ipv6_prefix
        if ipv6_prefix="$(net_ipv6_prefix64 "$PVE_IPV6_CIDR" 2>/dev/null)"; then
            PVE_FIRST_IPV6_CIDR="${ipv6_prefix}:1::1/80"
        fi
    fi

    if [[ -z "$PVE_ADDITIONAL_IPS" ]] && [[ -n "${PVE_OVH_ADDITIONAL_IPS:-}" ]]; then
        PVE_ADDITIONAL_IPS="$PVE_OVH_ADDITIONAL_IPS"
    fi

    if [[ -n "$PVE_SSH_KEYS" ]]; then
        local normalized
        normalized="$(config_normalize_ssh_keys "$PVE_SSH_KEYS")"
        if [[ -z "$normalized" ]]; then
            log_warn "PVE_SSH_KEYS contains no valid public key; SSH hardening will be skipped"
        fi
        PVE_SSH_KEYS="$normalized"
    fi

    if [[ -z "$PVE_PREDICTED_IFACE" ]]; then
        PVE_PREDICTED_IFACE="$PVE_INTERFACE"
    fi

    log_debug "Derived: HOSTNAME=${PVE_HOSTNAME} FQDN=${PVE_FQDN}"
    log_debug "Derived: PRIVATE_IP_CIDR=${PVE_PRIVATE_IP_CIDR}"
    log_debug "Derived: PREDICTED_IFACE=${PVE_PREDICTED_IFACE}"
    log_debug "Derived: FIRST_IPV6_CIDR=${PVE_FIRST_IPV6_CIDR}"
}
