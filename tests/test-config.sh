#!/usr/bin/env bash
# Unit tests for lib/config.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4
LOG_QUIET=true
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/validate.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/providers/common.sh"
source "${SCRIPT_DIR}/lib/providers/hetzner.sh"
source "${SCRIPT_DIR}/lib/providers/ovh.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    (( TESTS_RUN++ )) || true
    if [[ "$expected" == "$actual" ]]; then
        (( TESTS_PASSED++ )) || true
        echo "  PASS: ${desc}"
    else
        (( TESTS_FAILED++ )) || true
        echo "  FAIL: ${desc} (expected '${expected}', got '${actual}')"
    fi
}

echo "=== config.sh tests ==="

# Test CLI argument parsing
config_parse_args --hostname "testhost" --fqdn "test.example.com" --timezone "UTC"
assert_eq "parse --hostname" "testhost" "$PVE_HOSTNAME"
assert_eq "parse --fqdn" "test.example.com" "$PVE_FQDN"
assert_eq "parse --timezone" "UTC" "$PVE_TIMEZONE"

# Test --unattended flag
config_parse_args --unattended
assert_eq "parse --unattended" "true" "$PVE_UNATTENDED"

# Test --yes flag
config_parse_args --yes
assert_eq "parse --yes" "true" "$PVE_SKIP_CONFIRM"

# Test --debug flag
config_parse_args --debug
assert_eq "parse --debug" "0" "$PVE_LOG_LEVEL"

# Test config file loading
TMPFILE="$(mktemp)"
cat > "$TMPFILE" <<'EOF'
PVE_HOSTNAME="fromfile"
PVE_EMAIL="test@test.com"
PVE_FILESYSTEM="ext4"
EOF
config_load_file "$TMPFILE"
assert_eq "load file hostname" "fromfile" "$PVE_HOSTNAME"
assert_eq "load file email" "test@test.com" "$PVE_EMAIL"
assert_eq "load file filesystem" "ext4" "$PVE_FILESYSTEM"
rm -f "$TMPFILE"

# Test derive_values
PVE_PRIVATE_SUBNET="192.168.50.0/24"
PVE_IPV6_CIDR=""
config_derive_values
assert_eq "derive private IP" "192.168.50.1" "$PVE_PRIVATE_IP"
assert_eq "derive private CIDR" "192.168.50.1/24" "$PVE_PRIVATE_IP_CIDR"
assert_eq "derive first IPv6 (empty)" "" "$PVE_FIRST_IPV6_CIDR"

# --- Provider parsing -----------------------------------------------------
config_parse_args --provider hetzner
assert_eq "parse --provider hetzner" "hetzner" "$PVE_PROVIDER"
config_parse_args --provider ovh
assert_eq "parse --provider ovh" "ovh" "$PVE_PROVIDER"

# --- OVH-specific flag parsing -------------------------------------------
config_parse_args --ovh-gateway-model scale --ovh-vrack-interface enp4s0f1np1 \
    --ovh-vrack-ip 10.0.0.10/24 --ovh-additional-ips "203.0.113.41/32,203.0.113.42/32"
assert_eq "parse --ovh-gateway-model" "scale" "$PVE_OVH_GATEWAY_MODEL"
assert_eq "parse --ovh-vrack-interface" "enp4s0f1np1" "$PVE_OVH_VRACK_INTERFACE"
assert_eq "parse --ovh-vrack-ip" "10.0.0.10/24" "$PVE_OVH_VRACK_IP_CIDR"
assert_eq "parse --ovh-additional-ips" "203.0.113.41/32,203.0.113.42/32" "$PVE_OVH_ADDITIONAL_IPS"

# --- Premium LUKS flag parsing -------------------------------------------
PVE_FEATURE_LUKS=false
PVE_LUKS_PASSPHRASE=""
PVE_LUKS_UNLOCK_MODES="passphrase"
config_parse_args --enable-luks --luks-passphrase "S3cret-pass" \
    --luks-unlock-modes "passphrase,ssh,tpm" --luks-dropbear-port 2233 \
    --luks-wan-mac "aa:bb:cc:dd:ee:ff"
assert_eq "parse --enable-luks" "true" "$PVE_FEATURE_LUKS"
assert_eq "parse --luks-passphrase" "S3cret-pass" "$PVE_LUKS_PASSPHRASE"
assert_eq "parse --luks-unlock-modes" "passphrase,ssh,tpm" "$PVE_LUKS_UNLOCK_MODES"
assert_eq "parse --luks-dropbear-port" "2233" "$PVE_LUKS_DROPBEAR_PORT"
assert_eq "parse --luks-wan-mac" "aa:bb:cc:dd:ee:ff" "$PVE_LUKS_WAN_MAC"

# --- Provider registry / dispatch ----------------------------------------
assert_eq "provider hetzner is known" "0" "$(provider_is_known hetzner; echo $?)"
assert_eq "provider ovh is known" "0" "$(provider_is_known ovh; echo $?)"
assert_eq "provider bogus is unknown" "1" "$(provider_is_known nope; echo $?)"
assert_eq "hetzner default DNS" "185.12.64.1 185.12.64.2" "$(hetzner_default_dns)"
assert_eq "ovh default DNS" "213.186.33.99 1.1.1.1" "$(ovh_default_dns)"

# --- OVH IPv6 gateway derivation -----------------------------------------
# Canonical OVH form (full prefix written out)
assert_eq "OVH IPv6 gw derive (full prefix)" "2001:41d0:1510:1cFF:FF:FF:FF:FF" \
    "$(ovh_compute_ipv6_gateway 2001:41d0:1510:1c89::1/64)"
# Short form with :: collapsing
assert_eq "OVH IPv6 gw derive (short form)" "2001:db8:0:00FF:FF:FF:FF:FF" \
    "$(ovh_compute_ipv6_gateway 2001:db8::1/64)"

# --- OVH gateway model auto-detect ---------------------------------------
PVE_OVH_GATEWAY_MODEL="auto"
PVE_MAIN_IPV4_GW="100.64.0.1"
assert_eq "OVH gw model scale (100.64.0.1)" "scale" "$(ovh_detect_gateway_model)"
PVE_MAIN_IPV4_GW="51.255.10.254"
PVE_OVH_GATEWAY_MODEL="auto"
assert_eq "OVH gw model classic" "classic" "$(ovh_detect_gateway_model)"

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

exit "$TESTS_FAILED"
