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

# --- Provider DNS defaults --------------------------------------------------
PVE_DNS_SERVERS=""; PVE_PROVIDER="ovh"
provider_resolve >/dev/null 2>&1
assert_contains "ovh DNS applied when unset" "213.186.33.99" "$PVE_DNS_SERVERS"
PVE_DNS_SERVERS="185.12.64.1 185.12.64.2"; PVE_PROVIDER="ovh"
provider_resolve >/dev/null 2>&1
assert_contains "explicit DNS never replaced" "185.12.64.1" "$PVE_DNS_SERVERS"

# --- Common baseline for the checks below -----------------------------------
PVE_PREDICTED_IFACE="enp0s31f6"
PVE_MAIN_IPV4="203.0.113.10"
PVE_MAIN_IPV4_CIDR="203.0.113.10/24"
PVE_MAIN_IPV4_GW="203.0.113.254"
PVE_IPV6="2001:41d0:1510:1c89::1"
PVE_IPV6_CIDR="2001:41d0:1510:1c89::1/64"
PVE_IPV6_GW_DETECTED=""
PVE_OVH_IPV6_GATEWAY=""
PVE_OVH_VRACK_INTERFACE=""
PVE_OVH_VRACK_IP_CIDR=""
PVE_ADDITIONAL_IPS="198.51.100.7"
PVE_OVH_ADDITIONAL_IPS=""

# --- OVH routed, classic range (regression: no on-link gateway) -------------
PVE_PROVIDER="ovh"; PVE_OVH_GATEWAY_MODEL="classic"; PVE_NETWORK_MODE="routed"
out="$(provider_render_interfaces)"
assert_contains "ovh routed classic: /32 on NIC" "address 203.0.113.10/32" "$out"
assert_contains "ovh routed classic: pointopoint" "pointopoint 203.0.113.254" "$out"
assert_contains "ovh routed: IPv6 /128 on the NIC" $'iface enp0s31f6 inet6 static\n    address 2001:41d0:1510:1c89::1/128' "$out"
assert_contains "ovh routed: IPv6 route via NIC" "route add default via 2001:41d0:1510:1cFF:FF:FF:FF:FF dev enp0s31f6" "$out"
assert_contains "ovh routed: /64 on vmbr0" $'iface vmbr0 inet6 static\n    address 2001:41d0:1510:1c89::1/64' "$out"
assert_contains "generic additional IPs routed" "ip route add 198.51.100.7/32 dev vmbr0" "$out"

# --- OVH bridged on Scale (regression: missing on-link gateway) -------------
PVE_NETWORK_MODE="bridged"; PVE_OVH_GATEWAY_MODEL="scale"
PVE_MAIN_IPV4_CIDR="203.0.113.10/32"; PVE_MAIN_IPV4_GW="100.64.0.1"
out="$(provider_render_interfaces)"
assert_contains "ovh bridged scale: pointopoint" "pointopoint 100.64.0.1" "$out"
assert_not_contains "ovh bridged: no vmbr1" "vmbr1" "$out"

# --- OVH IPv6 gateway precedence ----------------------------------------------
PVE_NETWORK_MODE="nat"; PVE_OVH_GATEWAY_MODEL="classic"
PVE_MAIN_IPV4_CIDR="203.0.113.10/24"; PVE_MAIN_IPV4_GW="203.0.113.254"
PVE_IPV6_GW_DETECTED="fe80::1"
out="$(provider_render_interfaces)"
assert_contains "ovh: detected link-local gw uses gateway line" "    gateway fe80::1" "$out"
assert_not_contains "ovh: no derived gw when detected" "1cFF:FF" "$out"
PVE_OVH_IPV6_GATEWAY="2001:41d0:1510:1cff:ff:ff:ff:fe"
assert_eq "ovh: explicit gw wins" "2001:41d0:1510:1cff:ff:ff:ff:fe" "$(ovh_ipv6_gateway)"
PVE_OVH_IPV6_GATEWAY=""; PVE_IPV6_GW_DETECTED=""
assert_eq "ovh: derived gw fallback" "2001:41d0:1510:1cFF:FF:FF:FF:FF" "$(ovh_ipv6_gateway)"

# --- OVH vRack without IP is inet manual ---------------------------------------
PVE_OVH_VRACK_INTERFACE="enp4s0f1"; PVE_OVH_VRACK_IP_CIDR=""
out="$(provider_render_interfaces)"
assert_contains "vrack without IP is manual" "iface vmbr2 inet manual" "$out"
PVE_OVH_VRACK_INTERFACE=""

# --- Hetzner routed / bridged (previously ignored --network-mode) ------------
PVE_PROVIDER="hetzner"; PVE_MAIN_IPV4_CIDR="203.0.113.10/26"; PVE_MAIN_IPV4_GW="203.0.113.1"
PVE_IPV6="2a01:4f8:1:2::2"; PVE_IPV6_CIDR="2a01:4f8:1:2::2/64"
PVE_NETWORK_MODE="routed"
out="$(provider_render_interfaces)"
assert_contains "hetzner routed: NIC /32 + pointopoint" $'address 203.0.113.10/32\n    gateway 203.0.113.1\n    pointopoint 203.0.113.1' "$out"
assert_contains "hetzner routed: vmbr0 no ports" "bridge-ports none" "$out"
assert_contains "hetzner routed: additional IP route" "ip route add 198.51.100.7/32 dev vmbr0" "$out"
assert_contains "hetzner routed: IPv6 /128 on NIC with fe80::1" $'address 2a01:4f8:1:2::2/128\n    gateway fe80::1' "$out"
assert_not_contains "hetzner routed: no NAT bridge" "MASQUERADE" "$out"
PVE_NETWORK_MODE="bridged"
out="$(provider_render_interfaces)"
assert_contains "hetzner bridged: vmbr0 bridges NIC" "bridge-ports enp0s31f6" "$out"
assert_not_contains "hetzner bridged: no NAT bridge" "MASQUERADE" "$out"

# --- WAN placeholder for first-boot --------------------------------------------
PVE_NETWORK_MODE="nat"
out="$(provider_render_interfaces __PVE_WAN_IFACE__)"
assert_contains "explicit iface argument used" "bridge-ports __PVE_WAN_IFACE__" "$out"
assert_not_contains "predicted name not used with explicit arg" "enp0s31f6" "$out"

# --- Hetzner vSwitch -------------------------------------------------------------
PVE_HETZNER_VSWITCH_VLAN="4000"; PVE_HETZNER_VSWITCH_IP="10.0.1.3/24"
PVE_HETZNER_VSWITCH_ROUTES="10.0.0.0/16"; PVE_HETZNER_VSWITCH_GATEWAY=""
PVE_HETZNER_VSWITCH_MTU="1400"; PVE_HETZNER_VSWITCH_BRIDGE=false
out="$(provider_render_interfaces __PVE_WAN_IFACE__)"
assert_contains "vswitch nat: VLAN on vlan-aware vmbr0" $'auto vlan4000\niface vlan4000 inet static\n    address 10.0.1.3/24\n    vlan-raw-device vmbr0\n    vlan-id 4000\n    mtu 1400' "$out"
assert_contains "vswitch: route via derived gateway" "up   ip route replace 10.0.0.0/16 via 10.0.1.1 dev vlan4000" "$out"
assert_contains "vswitch: route removed on down" "down ip route del 10.0.0.0/16 via 10.0.1.1 dev vlan4000 || true" "$out"
assert_contains "vswitch nat: NAT bridge still rendered" "MASQUERADE" "$out"
PVE_NETWORK_MODE="routed"
out="$(provider_render_interfaces __PVE_WAN_IFACE__)"
assert_contains "vswitch routed: VLAN on the NIC" "vlan-raw-device __PVE_WAN_IFACE__" "$out"
PVE_HETZNER_VSWITCH_BRIDGE=true; PVE_HETZNER_VSWITCH_GATEWAY="10.0.1.254"
out="$(provider_render_interfaces __PVE_WAN_IFACE__)"
assert_contains "vswitch bridge: VLAN is manual" $'iface vlan4000 inet manual\n    vlan-raw-device __PVE_WAN_IFACE__' "$out"
assert_contains "vswitch bridge: vmbr4000 holds the IP" $'iface vmbr4000 inet static\n    address 10.0.1.3/24\n    bridge-ports vlan4000' "$out"
assert_contains "vswitch bridge: explicit gateway, route on bridge" "ip route replace 10.0.0.0/16 via 10.0.1.254 dev vmbr4000" "$out"
PVE_HETZNER_VSWITCH_IP=""; PVE_HETZNER_VSWITCH_ROUTES=""
out="$(provider_render_interfaces __PVE_WAN_IFACE__)"
assert_contains "vswitch bridge without IP: manual bridge" "iface vmbr4000 inet manual" "$out"
assert_not_contains "vswitch bridge without IP: no routes" "ip route replace" "$out"
PVE_HETZNER_VSWITCH_IP="10.0.1.3/24"; PVE_HETZNER_VSWITCH_ROUTES="10.0.0.0/16,172.16.0.0/12"
PVE_HETZNER_VSWITCH_GATEWAY=""
TESTS_RUN=$(( TESTS_RUN + 1 ))
if hetzner_vswitch_reaches 10.0.1.9 && hetzner_vswitch_reaches 10.0.0.2 \
    && hetzner_vswitch_reaches 172.20.1.1 && ! hetzner_vswitch_reaches 203.0.113.7 \
    && ! hetzner_vswitch_reaches tang.example.net; then
    TESTS_PASSED=$(( TESTS_PASSED + 1 )); echo "  PASS: vswitch reaches: subnet + routes only"
else
    TESTS_FAILED=$(( TESTS_FAILED + 1 )); echo "  FAIL: vswitch reaches: subnet + routes only"
fi
assert_contains "vswitch gateway: first host" "10.0.1.1" "$(hetzner_vswitch_gateway)"
assert_contains "vswitch notes mention Robot membership" "member of the vSwitch" "$(hetzner_post_install_notes)"
PVE_HETZNER_VSWITCH_VLAN=""
out="$(provider_render_interfaces __PVE_WAN_IFACE__)"
assert_not_contains "no vswitch: no VLAN device" "vlan-raw-device" "$out"
PVE_HETZNER_VSWITCH_IP=""; PVE_HETZNER_VSWITCH_ROUTES=""; PVE_HETZNER_VSWITCH_BRIDGE=false
PVE_NETWORK_MODE="nat"


# --- Public build: encryption requests degrade to a CTA ----------------------
if ! declare -F _premium_luks_real_announce >/dev/null && ! declare -F _premium_zfs_crypt_real_announce >/dev/null; then
    PVE_UNATTENDED=true; PVE_FEATURE_LUKS=false; PVE_ZFS_ENCRYPTION=true
    premium_announce_cta >/dev/null 2>&1
    assert_contains "public stub disables ZFS encryption" "false" "$PVE_ZFS_ENCRYPTION"
    PVE_FEATURE_LUKS=true
    premium_announce_cta >/dev/null 2>&1
    assert_contains "public stub disables LUKS" "false" "$PVE_FEATURE_LUKS"
fi

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
exit "$TESTS_FAILED"
