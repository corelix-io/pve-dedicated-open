#!/usr/bin/env bash
# Unit tests for the virtual-block-device filter inside disk_detect.
# We can't drive lsblk in CI, so we test the filter logic directly by
# replicating the case statement and the size guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4
LOG_QUIET=true

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$(( TESTS_PASSED + 1 ))
        echo "  PASS: ${desc}"
    else
        TESTS_FAILED=$(( TESTS_FAILED + 1 ))
        echo "  FAIL: ${desc} (expected '${expected}', got '${actual}')"
    fi
}

# Replicate disk_detect's filter (must stay in sync with lib/disk.sh).
should_keep_disk() {
    local name="$1"
    local size_b="$2"
    case "$name" in
        loop*|sr*|fd*|nbd*|ram*|md*|dm-*|zd*|zram*|nullb*) echo "skip-name"; return ;;
    esac
    if [[ -z "$size_b" ]] || [[ ! "$size_b" =~ ^[0-9]+$ ]] || (( size_b == 0 )); then
        echo "skip-zero"; return
    fi
    if (( size_b < 4294967296 )); then
        echo "skip-small"; return
    fi
    echo "keep"
}

echo "=== disk-filter tests ==="

# Real disks should be kept
assert_eq "nvme0n1 512G keep"  "keep" "$(should_keep_disk nvme0n1 512110190592)"
assert_eq "sda 2TB keep"       "keep" "$(should_keep_disk sda      2000398934016)"
assert_eq "nvme1n1 1.8T keep"  "keep" "$(should_keep_disk nvme1n1  1979120929280)"

# OVH/Hetzner rescue phantoms must be skipped by name
assert_eq "nbd0  is virtual"   "skip-name" "$(should_keep_disk nbd0  0)"
assert_eq "nbd15 is virtual"   "skip-name" "$(should_keep_disk nbd15 0)"
assert_eq "loop0 is virtual"   "skip-name" "$(should_keep_disk loop0 1234567)"
assert_eq "ram0 is virtual"    "skip-name" "$(should_keep_disk ram0  16777216)"
assert_eq "md0 is virtual"     "skip-name" "$(should_keep_disk md0   2000000000000)"
assert_eq "dm-0 is virtual"    "skip-name" "$(should_keep_disk dm-0  500000000000)"
assert_eq "zd0 is virtual"     "skip-name" "$(should_keep_disk zd0   100000000000)"
assert_eq "sr0 is virtual"     "skip-name" "$(should_keep_disk sr0   0)"
assert_eq "zram0 is virtual"   "skip-name" "$(should_keep_disk zram0 1073741824)"
assert_eq "nullb0 is virtual"  "skip-name" "$(should_keep_disk nullb0 1000000000000)"

# Zero-sized real-looking devices (empty card readers, hot-plugged USB) skipped
assert_eq "sda zero size"      "skip-zero" "$(should_keep_disk sda 0)"
assert_eq "sdb empty string"   "skip-zero" "$(should_keep_disk sdb "")"
assert_eq "sdc non-numeric"    "skip-zero" "$(should_keep_disk sdc xyz)"

# Floor: < 4 GiB cannot host Proxmox
assert_eq "sda 1G too small"   "skip-small" "$(should_keep_disk sda 1073741824)"
assert_eq "sda 4G is enough"   "keep"       "$(should_keep_disk sda 4294967296)"

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
exit "$TESTS_FAILED"
