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

# --- dotenv parser (regression: inline comments leaked into values) -------
TMPENV="$(mktemp)"
cat > "$TMPENV" <<'ENVFILE'
# full-line comment
PVE_DISK_MODE="auto"         # auto = use all detected disks
PVE_NETWORK_MODE=routed   # nat, routed, bridged
export PVE_TIMEZONE='Europe/Paris'
PVE_ROOT_PASSWORD="it's \"quoted\" \\ $HOME #kept"
PVE_EMAIL=a#b@example.com
PVE_LOG_LEVEL=1 # info
PVE_SSH_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx user@a
ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB user b"
ENVFILE
config_load_file "$TMPENV" >/dev/null 2>&1
assert_eq "dotenv strips comment after quoted value" "auto" "$PVE_DISK_MODE"
assert_eq "dotenv strips comment after bare value" "routed" "$PVE_NETWORK_MODE"
assert_eq "dotenv export + single quotes" "Europe/Paris" "$PVE_TIMEZONE"
assert_eq "dotenv keeps quotes, backslash, literal \$ and #" "it's \"quoted\" \\ \$HOME #kept" "$PVE_ROOT_PASSWORD"
assert_eq "dotenv keeps # inside bare value" "a#b@example.com" "$PVE_EMAIL"
assert_eq "dotenv numeric with comment" "1" "$PVE_LOG_LEVEL"
assert_eq "dotenv multi-line value" $'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx user@a\nssh-rsa AAAAB3NzaC1yc2EAAAADAQAB user b' "$PVE_SSH_KEYS"
assert_eq "file values are explicit" "0" "$(config_is_explicit PVE_TIMEZONE; echo $?)"
printf 'PVE_SSH_KEYS="unterminated\n' > "$TMPENV"
assert_eq "unterminated quote is fatal" "1" "$( (config_load_file "$TMPENV") >/dev/null 2>&1; echo $?)"
rm -f "$TMPENV"

# defaults are not explicit
PVE_CONFIG_EXPLICIT=()
config_load_file "${SCRIPT_DIR}/configs/default.env" false >/dev/null 2>&1
assert_eq "default.env network mode parses" "nat" "$PVE_NETWORK_MODE"
assert_eq "default.env DHCP parses" "true" "$PVE_ENABLE_DHCP"
assert_eq "default.env values are not explicit" "1" "$(config_is_explicit PVE_HOSTNAME; echo $?)"

# --- CLI parsing --------------------------------------------------------
config_parse_args --vswitch-vlan 4000 --vswitch-ip=10.0.1.3/24 \
    --hetzner-vswitch-routes 10.0.0.0/16 --vswitch-gateway 10.0.1.1 --vswitch-mtu 1400 --vswitch-bridge
assert_eq "vswitch vlan flag" "4000" "$PVE_HETZNER_VSWITCH_VLAN"
assert_eq "vswitch ip flag (--opt=value)" "10.0.1.3/24" "$PVE_HETZNER_VSWITCH_IP"
assert_eq "vswitch routes long form" "10.0.0.0/16" "$PVE_HETZNER_VSWITCH_ROUTES"
assert_eq "vswitch gateway flag" "10.0.1.1" "$PVE_HETZNER_VSWITCH_GATEWAY"
assert_eq "vswitch bridge switch" "true" "$PVE_HETZNER_VSWITCH_BRIDGE"
assert_eq "vswitch keys are known" "0" "$(_config_is_known_key PVE_HETZNER_VSWITCH_ROUTES; echo $?)"
config_parse_args --hostname=eqhost
assert_eq "--opt=value form" "eqhost" "$PVE_HOSTNAME"
assert_eq "missing option value is fatal" "1" "$( (config_parse_args --hostname) >/dev/null 2>&1; echo $?)"
assert_eq "unknown option is fatal" "1" "$( (config_parse_args --bogus) >/dev/null 2>&1; echo $?)"
config_parse_args --additional-ips "198.51.100.7" --pve-version 9.1 --no-iso-verify --ovh-ipv6-gateway fe80::1
assert_eq "parse --additional-ips" "198.51.100.7" "$PVE_ADDITIONAL_IPS"
assert_eq "parse --pve-version" "9.1" "$PVE_ISO_VERSION"
assert_eq "parse --no-iso-verify" "false" "$PVE_ISO_VERIFY"
assert_eq "parse --ovh-ipv6-gateway" "fe80::1" "$PVE_OVH_IPV6_GATEWAY"

# --- Hostname / FQDN derivation ------------------------------------------
PVE_CONFIG_EXPLICIT=(); PVE_HOSTNAME="proxmox"; PVE_FQDN="proxmox.example.com"
config_parse_args --fqdn node7.corp.example
config_derive_values
assert_eq "hostname derived from explicit FQDN" "node7" "$PVE_HOSTNAME"
PVE_CONFIG_EXPLICIT=(); PVE_HOSTNAME="proxmox"; PVE_FQDN="proxmox.example.com"
config_parse_args --hostname node8
config_derive_values
assert_eq "FQDN derived from explicit hostname" "node8.example.com" "$PVE_FQDN"

# --- SSH key normalization (regression: keys were word-split) ------------
norm="$(config_normalize_ssh_keys "ssh-ed25519 AAAAC3Nza c1 ssh-rsa AAAAB3Nz my laptop ssh-ed25519 AAAAC3Nza dup")"
assert_eq "space-separated keys split per key, dup removed" $'ssh-ed25519 AAAAC3Nza c1\nssh-rsa AAAAB3Nz my laptop' "$norm"
assert_eq "options prefix and FIDO key kept" 'no-pty sk-ssh-ed25519@openssh.com AAAAGnNr yubi' \
    "$(config_normalize_ssh_keys 'no-pty sk-ssh-ed25519@openssh.com AAAAGnNr yubi')"
assert_eq "comment lines ignored" "ecdsa-sha2-nistp256 AAAAE2Vj" \
    "$(config_normalize_ssh_keys $'# my keys\necdsa-sha2-nistp256 AAAAE2Vj')"
assert_eq "garbage yields nothing" "" "$(config_normalize_ssh_keys "not a key")"

# --- Derived values -------------------------------------------------------
PVE_IPV6_CIDR="2a01:4f8:1::2/64"
config_derive_values
assert_eq "vmbr1 IPv6 from compressed /64" "2a01:4f8:1:0:1::1/80" "$PVE_FIRST_IPV6_CIDR"
PVE_PRIVATE_SUBNET="10.20.0.0/16"
config_derive_values
assert_eq "private IP for /16" "10.20.0.1/16" "$PVE_PRIVATE_IP_CIDR"

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

exit "$TESTS_FAILED"
