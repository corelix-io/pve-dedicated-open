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

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

exit "$TESTS_FAILED"
