#!/usr/bin/env bash
# Unit tests for the pure address helpers in lib/network.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/tests/helpers.sh"

echo "=== network.sh tests ==="

# IPv4 integer conversion
assert_eq "ipv4 to int" "3232235777" "$(net_ipv4_to_int 192.168.1.1)"
assert_eq "int to ipv4" "10.0.0.255" "$(net_int_to_ipv4 167772415)"
assert_eq "leading zeros are decimal" "134744072" "$(net_ipv4_to_int 008.008.008.008)"
assert_fail "reject octet > 255" net_ipv4_to_int 1.2.3.256
assert_fail "reject garbage" net_ipv4_to_int not-an-ip

# Netmasks
assert_eq "netmask /24" "255.255.255.0" "$(net_prefix_to_netmask 24)"
assert_eq "netmask /16" "255.255.0.0" "$(net_prefix_to_netmask 16)"
assert_eq "netmask /32" "255.255.255.255" "$(net_prefix_to_netmask 32)"
assert_eq "netmask /0" "0.0.0.0" "$(net_prefix_to_netmask 0)"

# Subnet membership (drives pointopoint / on-link decisions)
assert_pass "gw inside /24" net_ipv4_in_subnet 203.0.113.254 203.0.113.10/24
assert_fail "gw outside /32" net_ipv4_in_subnet 203.0.113.1 203.0.113.10/32
assert_fail "scale gw outside /24" net_ipv4_in_subnet 100.64.0.1 51.255.10.20/24
assert_pass "hetzner /26 gw inside" net_ipv4_in_subnet 88.99.10.1 88.99.10.50/26

# Network / host addresses
assert_eq "network of /24" "192.168.26.0" "$(net_ipv4_network 192.168.26.77/24)"
assert_eq "host 1 of /24" "192.168.26.1" "$(net_ipv4_host 192.168.26.0/24 1)"
assert_eq "host 100 of /16" "10.20.0.100" "$(net_ipv4_host 10.20.0.0/16 100)"
assert_eq "host 1 of unaligned /24" "192.168.50.1" "$(net_ipv4_host 192.168.50.9/24 1)"

# IPv6 expansion
assert_eq "expand compressed" "2a01:04f8:0001:0000:0000:0000:0000:0002" "$(net_ipv6_expand 2a01:4f8:1::2)"
assert_eq "expand with prefix" "2001:0db8:0000:0000:0000:0000:0000:0001" "$(net_ipv6_expand 2001:db8::1/64)"
assert_eq "expand full form" "2001:41d0:1510:1c89:0000:0000:0000:0001" "$(net_ipv6_expand 2001:41d0:1510:1c89:0:0:0:1)"
assert_eq "expand uppercase" "2001:0db8:0000:0000:0000:0000:0000:00ff" "$(net_ipv6_expand 2001:DB8::FF)"
assert_eq "expand ::" "0000:0000:0000:0000:0000:0000:0000:0000" "$(net_ipv6_expand ::)"
assert_fail "reject double ::" net_ipv6_expand 2001::db8::1
assert_fail "reject too many groups" net_ipv6_expand 1:2:3:4:5:6:7:8:9
assert_fail "reject non-hex" net_ipv6_expand 2001:zz::1

# /64 prefix (vmbr1 IPv6 + OVH gateway derivation)
assert_eq "prefix64 full" "2a01:4f8:c17:1a2b" "$(net_ipv6_prefix64 2a01:4f8:c17:1a2b::2/64)"
assert_eq "prefix64 compressed" "2a01:4f8:1:0" "$(net_ipv6_prefix64 2a01:4f8:1::2/64)"
assert_eq "prefix64 short" "2001:db8:0:0" "$(net_ipv6_prefix64 2001:db8::1)"

tests_summary
