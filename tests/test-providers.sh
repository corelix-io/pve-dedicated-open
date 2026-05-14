#!/usr/bin/env bash
# Provider rendering and dispatch tests
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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: ${desc}"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: ${desc} (missing: '${needle}')"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: ${desc}"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: ${desc} (unexpectedly contains: '${needle}')"
    fi
}

echo "=== providers tests ==="

# Setup baseline state used by all renderers
PVE_INTERFACE="eth0"
PVE_PREDICTED_IFACE="enp0s31f6"
PVE_MAIN_IPV4="203.0.113.10"
PVE_MAIN_IPV4_CIDR="203.0.113.10/24"
PVE_MAIN_IPV4_GW="203.0.113.254"
PVE_MAC_ADDRESS="aa:bb:cc:dd:ee:ff"
PVE_IPV6_CIDR="2001:db8::1/64"
PVE_PRIVATE_SUBNET="192.168.50.0/24"
PVE_PRIVATE_IP_CIDR="192.168.50.1/24"
PVE_FIRST_IPV6_CIDR=""
PVE_NETWORK_MODE="nat"

# --- Hetzner renderer ----------------------------------------------------
PVE_PROVIDER="hetzner"
hetzner_out="$(provider_render_interfaces)"
assert_contains "hetzner: bridge-ports uses predicted iface" "bridge-ports enp0s31f6" "$hetzner_out"
assert_contains "hetzner: vmbr0 has main IP CIDR" "address 203.0.113.10/24" "$hetzner_out"
assert_contains "hetzner: vmbr0 has gateway" "gateway 203.0.113.254" "$hetzner_out"
assert_contains "hetzner: IPv6 uses fe80::1" "gateway fe80::1" "$hetzner_out"
assert_contains "hetzner: vmbr1 has MASQUERADE" "MASQUERADE" "$hetzner_out"
assert_not_contains "hetzner: no OVH 100.64 gateway" "100.64.0.1" "$hetzner_out"

# --- OVH renderer: NAT (classic gateway) ---------------------------------
PVE_PROVIDER="ovh"
PVE_OVH_GATEWAY_MODEL="classic"
PVE_NETWORK_MODE="nat"
ovh_nat_classic="$(provider_render_interfaces)"
assert_contains "ovh nat classic: vmbr0 bridge-ports physical" "bridge-ports enp0s31f6" "$ovh_nat_classic"
assert_contains "ovh nat classic: main IP CIDR" "address 203.0.113.10/24" "$ovh_nat_classic"
assert_not_contains "ovh nat classic: no pointopoint (in-subnet gw)" "pointopoint" "$ovh_nat_classic"
assert_contains "ovh nat classic: vmbr1 NAT" "MASQUERADE" "$ovh_nat_classic"
assert_not_contains "ovh nat classic: no fe80::1" "fe80::1" "$ovh_nat_classic"
assert_contains "ovh nat classic: IPv6 derived gateway" "2001:db8:0:00FF:FF:FF:FF:FF" "$ovh_nat_classic"

# --- OVH renderer: NAT (Scale/HG) ----------------------------------------
PVE_OVH_GATEWAY_MODEL="scale"
PVE_MAIN_IPV4_GW="100.64.0.1"
ovh_nat_scale="$(provider_render_interfaces)"
assert_contains "ovh nat scale: pointopoint" "pointopoint 100.64.0.1" "$ovh_nat_scale"
assert_contains "ovh nat scale: gateway 100.64.0.1" "gateway 100.64.0.1" "$ovh_nat_scale"

# --- OVH renderer: routed mode -------------------------------------------
PVE_NETWORK_MODE="routed"
PVE_OVH_ADDITIONAL_IPS="203.0.113.41/32,203.0.113.42/32"
ovh_routed="$(provider_render_interfaces)"
assert_contains "ovh routed: vmbr0 has bridge-ports none" "bridge-ports none" "$ovh_routed"
assert_contains "ovh routed: extra IP route 41" "ip route add 203.0.113.41/32 dev vmbr0" "$ovh_routed"
assert_contains "ovh routed: extra IP route 42" "ip route add 203.0.113.42/32 dev vmbr0" "$ovh_routed"

# --- OVH renderer: bridged mode (with hwaddress) -------------------------
PVE_NETWORK_MODE="bridged"
PVE_OVH_GATEWAY_MODEL="classic"
PVE_MAIN_IPV4_GW="203.0.113.254"
ovh_bridged="$(provider_render_interfaces)"
assert_contains "ovh bridged: hwaddress" "hwaddress aa:bb:cc:dd:ee:ff" "$ovh_bridged"
assert_contains "ovh bridged: bridge-ports physical" "bridge-ports enp0s31f6" "$ovh_bridged"

# --- OVH renderer: vRack block -------------------------------------------
PVE_NETWORK_MODE="nat"
PVE_OVH_VRACK_INTERFACE="enp4s0f1np1"
PVE_OVH_VRACK_IP_CIDR="10.0.0.10/24"
ovh_vrack="$(provider_render_interfaces)"
assert_contains "ovh vrack: vmbr2 declared" "auto vmbr2" "$ovh_vrack"
assert_contains "ovh vrack: vrack iface bridge-port" "bridge-ports enp4s0f1np1" "$ovh_vrack"
assert_contains "ovh vrack: vrack IP" "address 10.0.0.10/24" "$ovh_vrack"

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
exit "$TESTS_FAILED"
