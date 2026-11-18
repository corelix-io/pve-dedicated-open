#!/usr/bin/env bash
# Generation tests for answer.toml and the first-boot script
# Single-quoted needles are literal on purpose.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4
LOG_QUIET=true
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/disk.sh"
source "${SCRIPT_DIR}/lib/answer.sh"
source "${SCRIPT_DIR}/lib/firstboot.sh"
source "${SCRIPT_DIR}/lib/providers/common.sh"
source "${SCRIPT_DIR}/lib/providers/hetzner.sh"
source "${SCRIPT_DIR}/lib/providers/ovh.sh"
source "${SCRIPT_DIR}/tests/helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== answer.toml / first-boot tests ==="

# --- TOML escaping -----------------------------------------------------------
assert_eq "toml escapes quote and backslash" 'a\"b\\c' "$(answer_toml_escape 'a"b\c')"
assert_eq "toml escapes newline" 'a\nb' "$(answer_toml_escape $'a\nb')"

keys_block="$(answer_render_ssh_keys $'ssh-ed25519 AAAAC3Nz user@a\nssh-rsa AAAAB3Nz my laptop')"
assert_contains "ssh keys rendered whole (not word-split)" '"ssh-ed25519 AAAAC3Nz user@a",' "$keys_block"
assert_contains "comment with spaces kept" '"ssh-rsa AAAAB3Nz my laptop"' "$keys_block"
assert_eq "no keys -> empty block" "" "$(answer_render_ssh_keys "")"

# --- Shared sample state -------------------------------------------------------
PVE_WORKING_DIR="$TMP"
PVE_PROVIDER="hetzner"
PVE_HOSTNAME="pve1"
PVE_FQDN="pve1.example.com"
PVE_TIMEZONE="Europe/Berlin"
PVE_EMAIL="ops@example.com"
PVE_ROOT_PASSWORD='s3cret "pass" \ $x'
PVE_SSH_KEYS=$'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx user@a\nssh-rsa AAAAB3NzaC1yc2EAAAADAQAB my laptop'
PVE_KEYBOARD="de"
PVE_COUNTRY="de"
PVE_FILESYSTEM="zfs"
PVE_ZFS_RAID="raid1"
PVE_ZFS_COMPRESS="lz4"
PVE_ZFS_ARC_MAX="8192"
PVE_INTERFACE="eth0"
PVE_PREDICTED_IFACE="enp7s0"
PVE_MAIN_IPV4="203.0.113.10"
PVE_MAIN_IPV4_CIDR="203.0.113.10/26"
PVE_MAIN_IPV4_GW="203.0.113.1"
PVE_MAC_ADDRESS="AA:BB:CC:DD:EE:FF"
PVE_IPV6="2a01:4f8:1:2::2"
PVE_IPV6_CIDR="2a01:4f8:1:2::2/64"
PVE_NETWORK_MODE="nat"
PVE_PRIVATE_SUBNET="192.168.26.0/24"
PVE_ENABLE_DHCP=true
PVE_DNS_SERVERS="185.12.64.1 2a01:4ff:ff00::add:1"
PVE_DEBIAN_SUITE="trixie"
SELECTED_DISKS=(nvme0n1 nvme1n1)
config_derive_values >/dev/null

# --- first-boot script ---------------------------------------------------------
firstboot_generate >/dev/null
fb="$TMP/generated/first-boot.sh"
fb_text="$(cat "$fb")"
assert_pass "first-boot script exists" test -f "$fb"
assert_pass "first-boot script parses (bash -n)" bash -n "$fb"
if command -v shellcheck >/dev/null 2>&1; then
    assert_pass "first-boot script passes shellcheck" shellcheck "$fb"
fi
assert_eq "first-boot script is owner-only" "700" "$(stat -c %a "$fb")"
assert_contains "WAN resolved by MAC at runtime" "FB_WAN_MAC=aa:bb:cc:dd:ee:ff" "$fb_text"
assert_contains "interfaces use the placeholder" "bridge-ports __PVE_WAN_IFACE__" "$fb_text"
assert_contains "placeholder substituted at runtime" 's/${FB_WAN_PLACEHOLDER}/${WAN_IFACE}/g' "$fb_text"
assert_contains "WAN name pinned via .link" "10-pve-dedicated-wan.link" "$fb_text"
assert_not_contains "no generation-time timestamps" "$(date +%Y)-" "$fb_text"
assert_contains "trixie uses deb822 proxmox.sources" "/etc/apt/sources.list.d/proxmox.sources" "$fb_text"
assert_contains "ceph tentacle for trixie" "FB_CEPH_RELEASE=ceph-tentacle" "$fb_text"
assert_contains "dnsmasq never serves DNS" "port=0" "$fb_text"
assert_contains "dhcp range from subnet" "dhcp-range=192.168.26.100,192.168.26.200,255.255.255.0,12h" "$fb_text"
assert_contains "dhcp DNS skips IPv6 servers" "dhcp-option=option:dns-server,185.12.64.1"$'\n' "$fb_text"
assert_contains "resolv.conf has search domain" "search example.com" "$fb_text"
assert_contains "sshd config validated before restart" "sshd -t" "$fb_text"
assert_contains "ssh keys kept one per line" $'AAAAIGx user@a\nssh-rsa AAAAB3NzaC1yc2EAAAADAQAB my laptop' "$fb_text"
assert_contains "conntrack module loaded before sysctl" "nf_conntrack" "$fb_text"
assert_contains "ARC max from override (8 GiB)" "FB_ARC_MAX=8589934592" "$fb_text"
assert_contains "nag removal via dpkg hook" "DPkg::Post-Invoke" "$fb_text"
assert_not_contains "no cron.daily nag job" "cron.daily" "$fb_text"

PVE_DEBIAN_SUITE="bookworm"
firstboot_generate >/dev/null
assert_contains "bookworm keeps .list + ceph-squid" "FB_CEPH_RELEASE=ceph-squid" "$(cat "$fb")"
PVE_DEBIAN_SUITE="trixie"

# --- answer.toml -------------------------------------------------------------
firstboot_generate >/dev/null
answer_generate >/dev/null
ans="$TMP/generated/answer.toml"
ans_text="$(cat "$ans")"
assert_eq "answer.toml is owner-only" "600" "$(stat -c %a "$ans")"
if command -v openssl >/dev/null 2>&1; then
    assert_contains "root password stored hashed" 'root-password-hashed = "$6$' "$ans_text"
    assert_not_contains "plaintext password absent" 's3cret' "$ans_text"
fi
assert_contains "fqdn set" 'fqdn = "pve1.example.com"' "$ans_text"
assert_contains "disk list uses virtio names" 'disk-list = ["vda","vdb"]' "$ans_text"
assert_contains "zfs arc-max numeric" 'zfs.arc-max = 8192' "$ans_text"
assert_contains "first-boot section present" 'ordering = "fully-up"' "$ans_text"
assert_contains "whole ssh key entries" '"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx user@a",' "$ans_text"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    assert_pass "answer.toml is valid TOML" python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$ans"
    PVE_ROOT_PASSWORD_SAVED="$PVE_ROOT_PASSWORD"
    answer_hash_password() { return 1; }
    answer_generate >/dev/null 2>&1
    assert_pass "plaintext fallback stays valid TOML with quotes/backslashes" \
        python3 -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); assert d["global"]["root-password"] == sys.argv[2]' "$ans" "$PVE_ROOT_PASSWORD_SAVED"
fi

# --- ZFS ARC limits ----------------------------------------------------------
GIB=1073741824
assert_eq "64 GiB host default" "$(( 65536 * 1048576 * 5 / 100 )) $(( 65536 * 1048576 * 15 / 100 ))" "$(firstboot_zfs_arc_limits 65536 "")"
assert_eq "small override clamps min to half" "$(( 256 * 1048576 )) $(( 512 * 1048576 ))" "$(firstboot_zfs_arc_limits 131072 512)"
assert_eq "tiny host floors" "${GIB} $(( 2 * GIB ))" "$(firstboot_zfs_arc_limits 4096 "")"

tests_summary
