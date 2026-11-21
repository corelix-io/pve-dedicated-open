#!/usr/bin/env bash
# Unit tests for lib/validate.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4  # suppress all output during tests
source "${SCRIPT_DIR}/lib/validate.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_pass() {
    local desc="$1"; shift
    (( TESTS_RUN++ )) || true
    if "$@" 2>/dev/null; then
        (( TESTS_PASSED++ )) || true
        echo "  PASS: ${desc}"
    else
        (( TESTS_FAILED++ )) || true
        echo "  FAIL: ${desc}"
    fi
}

assert_fail() {
    local desc="$1"; shift
    (( TESTS_RUN++ )) || true
    if ! "$@" 2>/dev/null; then
        (( TESTS_PASSED++ )) || true
        echo "  PASS: ${desc}"
    else
        (( TESTS_FAILED++ )) || true
        echo "  FAIL: ${desc} (expected failure, got success)"
    fi
}

echo "=== validate.sh tests ==="

# IPv4
assert_pass "valid IPv4" validate_ipv4 "192.168.1.1"
assert_pass "valid IPv4 loopback" validate_ipv4 "127.0.0.1"
assert_fail "invalid IPv4 too many octets" validate_ipv4 "1.2.3.4.5"
assert_fail "invalid IPv4 octet > 255" validate_ipv4 "256.1.1.1"
assert_fail "invalid IPv4 letters" validate_ipv4 "abc.def.ghi.jkl"

# CIDR
assert_pass "valid CIDR /24" validate_cidr "192.168.1.0/24"
assert_pass "valid CIDR /32" validate_cidr "10.0.0.1/32"
assert_fail "invalid CIDR no mask" validate_cidr "192.168.1.0"
assert_fail "invalid CIDR mask > 32" validate_cidr "10.0.0.1/33"

# FQDN
assert_pass "valid FQDN" validate_fqdn "pve.example.com"
assert_pass "valid FQDN with subdomain" validate_fqdn "pve1.dc1.example.com"
assert_fail "invalid FQDN no dot" validate_fqdn "justahostname"
assert_fail "invalid FQDN starts with dash" validate_fqdn "-bad.example.com"

# Hostname
assert_pass "valid hostname" validate_hostname "pve1"
assert_pass "valid hostname with dash" validate_hostname "my-server"
assert_fail "invalid hostname with dot" validate_hostname "has.dot"
assert_fail "invalid hostname starts with dash" validate_hostname "-bad"

# Email
assert_pass "valid email" validate_email "admin@example.com"
assert_fail "invalid email no @" validate_email "noemail"
assert_fail "invalid email no domain" validate_email "user@"

# Timezone
assert_pass "valid timezone UTC" validate_timezone "UTC"
assert_pass "valid timezone Europe/Berlin" validate_timezone "Europe/Berlin"
assert_fail "invalid timezone" validate_timezone "NotATimezone"

# Password
assert_pass "valid password" validate_password "securepass"
assert_fail "empty password" validate_password ""
assert_fail "short password" validate_password "ab"

# Filesystem
assert_pass "valid fs zfs" validate_filesystem "zfs"
assert_pass "valid fs ext4" validate_filesystem "ext4"
assert_fail "invalid fs" validate_filesystem "ntfs"

# ZFS RAID
assert_pass "valid raid1" validate_zfs_raid "raid1"
assert_pass "valid raidz-1" validate_zfs_raid "raidz-1"
assert_fail "invalid raid level" validate_zfs_raid "raid5"

# Disk count for RAID
assert_pass "raid1 with 2 disks" validate_disk_count_for_raid "raid1" 2
assert_fail "raid1 with 1 disk" validate_disk_count_for_raid "raid1" 1
assert_pass "raid10 with 4 disks" validate_disk_count_for_raid "raid10" 4
assert_fail "raid10 with 3 disks" validate_disk_count_for_raid "raid10" 3

# Keyboard
assert_pass "valid keyboard en-us" validate_keyboard "en-us"
assert_pass "valid keyboard de" validate_keyboard "de"
assert_fail "invalid keyboard" validate_keyboard "xyz"

# Boot mode
assert_pass "valid boot auto" validate_boot_mode "auto"
assert_pass "valid boot uefi" validate_boot_mode "uefi"
assert_fail "invalid boot mode" validate_boot_mode "bios"

# Network mode
assert_pass "valid net nat" validate_network_mode "nat"
assert_pass "valid net routed" validate_network_mode "routed"
assert_fail "invalid net mode" validate_network_mode "vlan"

# Provider
assert_pass "valid provider hetzner" validate_provider "hetzner"
assert_pass "valid provider ovh" validate_provider "ovh"
assert_fail "invalid provider aws" validate_provider "aws"
assert_fail "empty provider" validate_provider ""

# OVH gateway model
assert_pass "valid ovh model auto" validate_ovh_gateway_model "auto"
assert_pass "valid ovh model classic" validate_ovh_gateway_model "classic"
assert_pass "valid ovh model scale" validate_ovh_gateway_model "scale"
assert_fail "invalid ovh model" validate_ovh_gateway_model "elite"

# LUKS unlock modes
assert_pass "valid luks passphrase" validate_luks_unlock_modes "passphrase"
assert_pass "valid luks combo" validate_luks_unlock_modes "passphrase,ssh,tpm"
assert_pass "valid luks tpm only" validate_luks_unlock_modes "tpm"
assert_fail "invalid luks mode token" validate_luks_unlock_modes "passphrase,bogus"
assert_fail "empty luks unlock modes" validate_luks_unlock_modes ""

# MAC address
assert_pass "valid lowercase MAC" validate_mac "aa:bb:cc:dd:ee:ff"
assert_pass "valid uppercase MAC" validate_mac "AA:BB:CC:DD:EE:FF"
assert_pass "valid mixed MAC"     validate_mac "Aa:Bb:Cc:00:11:22"
assert_fail "invalid MAC short" validate_mac "aa:bb:cc:dd:ee"
assert_fail "invalid MAC dashes" validate_mac "aa-bb-cc-dd-ee-ff"

# --- Regressions and new validators ------------------------------------
source "${SCRIPT_DIR}/lib/network.sh"
assert_pass "octet with leading zero" validate_ipv4 "10.0.0.08"
assert_pass "multi-segment timezone" validate_timezone "America/Argentina/Buenos_Aires"
assert_pass "timezone with dash" validate_timezone "America/Port-au-Prince"
assert_fail "unknown timezone" validate_timezone "Mars/Olympus_Mons"
assert_fail "password 7 chars" validate_password "1234567"
assert_fail "placeholder password" validate_password "CHANGE_ME_BEFORE_USE"
assert_pass "hostname matches fqdn" validate_hostname_matches_fqdn pve1 pve1.example.com
assert_fail "hostname mismatch" validate_hostname_matches_fqdn pve1 pve2.example.com
assert_fail "raid10 odd disks" validate_disk_count_for_raid raid10 5
assert_pass "raid10 even disks" validate_disk_count_for_raid raid10 6
assert_pass "ashift 12" validate_zfs_ashift 12
assert_fail "ashift 20" validate_zfs_ashift 20
assert_pass "zstd compression" validate_zfs_compress zstd
assert_fail "bogus compression" validate_zfs_compress brotli
assert_pass "country de" validate_country de
assert_fail "country DEU" validate_country DEU
assert_pass "port 2222" validate_port 2222
assert_fail "port 70000" validate_port 70000
assert_pass "ipv6 address" validate_ipv6 "2001:db8::1"
assert_fail "bad ipv6" validate_ipv6 "2001:::1"
assert_pass "ed25519 key" validate_ssh_keys "ssh-ed25519 AAAAC3Nz user"
assert_fail "dsa key rejected" validate_ssh_keys "ssh-dss AAAAB3Nz user"
assert_pass "ip or cidr" validate_ipv4_or_cidr "198.51.100.7/32"


# --- ZFS native encryption validation ---------------------------------------
# Invoked through assert_pass/assert_fail.
# shellcheck disable=SC2329
zfs_validate_errors() {
    (
        source "${SCRIPT_DIR}/lib/config.sh"
        PVE_PROVIDER=hetzner PVE_HOSTNAME=pve1 PVE_FQDN=pve1.example.com PVE_EMAIL=a@example.com
        PVE_TIMEZONE=UTC PVE_ROOT_PASSWORD=longenough1 PVE_FILESYSTEM="${1}" PVE_KEYBOARD=en-us
        PVE_COUNTRY=us PVE_DISK_MODE=auto PVE_NETWORK_MODE=nat PVE_ENABLE_DHCP=true PVE_ISO_VERIFY=true
        PVE_DNS_SERVERS=1.1.1.1 PVE_PRIVATE_SUBNET=192.168.26.0/24 PVE_ZFS_RAID=raid0 PVE_ZFS_COMPRESS=lz4
        PVE_BOOT_MODE=auto PVE_SSH_KEYS="" PVE_ADDITIONAL_IPS="" PVE_FEATURE_LUKS="${2}"
        PVE_ZFS_ENCRYPTION=true PVE_ZFS_UNLOCK_MODES="${3}" PVE_LUKS_TANG_URLS="${4:-}"
        PVE_ZFS_ENCRYPT_LOCAL=true PVE_LUKS_TPM_PCRS=0,1,2,7
        ui_success() { :; }
        validate_all
    ) >/dev/null 2>&1
}
assert_pass "zfs-encrypt + raid0 valid" zfs_validate_errors zfs false passphrase,tpm
assert_fail "zfs-encrypt needs zfs" zfs_validate_errors ext4 false passphrase
assert_fail "zfs-encrypt + LUKS rejected" zfs_validate_errors zfs true passphrase
assert_fail "zfs tang needs URL" zfs_validate_errors zfs false passphrase,tang
assert_pass "zfs tang with URL" zfs_validate_errors zfs false passphrase,tang http://tang.example.net
assert_fail "zfs ssh mode rejected" zfs_validate_errors zfs false passphrase,ssh

# Hetzner vSwitch
# shellcheck disable=SC2329  # invoked through assert_pass/assert_fail
vsw() {
    (
        PVE_PROVIDER="${1}" PVE_HETZNER_VSWITCH_VLAN="${2}" PVE_HETZNER_VSWITCH_IP="${3}"
        PVE_HETZNER_VSWITCH_GATEWAY="${4}" PVE_HETZNER_VSWITCH_ROUTES="${5}"
        PVE_HETZNER_VSWITCH_MTU="${6:-1400}" PVE_HETZNER_VSWITCH_BRIDGE="${7:-false}"
        PVE_PRIVATE_SUBNET=192.168.26.0/24 PVE_NETWORK_MODE=nat
        validate_hetzner_vswitch
    )
}
assert_pass "vswitch: unset is valid" vsw hetzner "" "" "" ""
assert_pass "vswitch: VLAN + IP" vsw hetzner 4000 10.0.1.3/24 "" ""
assert_pass "vswitch: routes with derived gateway" vsw hetzner 4000 10.0.1.3/24 "" 10.0.0.0/16
assert_pass "vswitch: explicit gateway" vsw hetzner 4091 10.0.1.3/24 10.0.1.1 "10.0.0.0/16,172.16.0.0/12"
assert_pass "vswitch: bridge only, no host IP" vsw hetzner 4000 "" "" "" 1400 true
assert_fail "vswitch: VLAN below 4000" vsw hetzner 100 10.0.1.3/24 "" ""
assert_fail "vswitch: VLAN above 4091" vsw hetzner 4092 10.0.1.3/24 "" ""
assert_fail "vswitch: OVH provider" vsw ovh 4000 10.0.1.3/24 "" ""
assert_fail "vswitch: IP without VLAN" vsw hetzner "" 10.0.1.3/24 "" ""
assert_fail "vswitch: VLAN without IP or bridge" vsw hetzner 4000 "" "" ""
assert_fail "vswitch: /32 host address" vsw hetzner 4000 10.0.1.3/32 "" ""
assert_fail "vswitch: MTU above 1400" vsw hetzner 4000 10.0.1.3/24 "" "" 1500
assert_fail "vswitch: gateway outside subnet" vsw hetzner 4000 10.0.1.3/24 10.0.2.1 10.0.0.0/16
assert_fail "vswitch: gateway is own address" vsw hetzner 4000 10.0.1.3/24 10.0.1.3 10.0.0.0/16
assert_fail "vswitch: own IP is the derived gateway" vsw hetzner 4000 10.0.1.1/24 "" 10.0.0.0/16
assert_fail "vswitch: bad route" vsw hetzner 4000 10.0.1.3/24 "" 10.0.0.0
assert_fail "vswitch: overlaps NAT subnet" vsw hetzner 4000 192.168.26.5/24 "" ""
assert_fail "vswitch: routes without IP" vsw hetzner 4000 "" "" 10.0.0.0/16 1400 true

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

exit "$TESTS_FAILED"
