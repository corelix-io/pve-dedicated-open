#!/usr/bin/env bash
# Unit tests for the iso_ensure_workspace_capacity decision helpers.
# We test the pure functions; the mount/df interaction is exercised by
# real installs on rescue (covered in docs).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4
LOG_QUIET=true
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/iso.sh"

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

echo "=== workspace-capacity tests ==="

# --- _iso_workspace_decision ---------------------------------------------
GIB=1073741824
assert_eq "10 GiB free is ok"          "ok"     "$(_iso_workspace_decision $((10 * GIB)))"
assert_eq "5 GiB free is exactly ok"   "ok"     "$(_iso_workspace_decision $((5 * GIB)))"
assert_eq "4 GiB free needs switch"    "switch" "$(_iso_workspace_decision $((4 * GIB)))"
assert_eq "0 bytes needs switch"       "switch" "$(_iso_workspace_decision 0)"
assert_eq "empty -> 0 -> switch"       "switch" "$(_iso_workspace_decision "")"
assert_eq "garbage -> 0 -> switch"     "switch" "$(_iso_workspace_decision "abc")"
assert_eq "negative-looking -> switch" "switch" "$(_iso_workspace_decision "-1")"
# Custom threshold
assert_eq "custom thr 1 GiB ok"        "ok"     "$(_iso_workspace_decision $((2 * GIB)) 1)"
assert_eq "custom thr 100 GiB switch"  "switch" "$(_iso_workspace_decision $((50 * GIB)) 100)"

# --- _iso_tmpfs_size_gib --------------------------------------------------
KIB_PER_GIB=$((1024 * 1024))
# 4 GiB RAM -> 4/4 = 1 GiB, floored to 8
assert_eq "4 GiB RAM -> 8 GiB tmpfs"   "8"  "$(_iso_tmpfs_size_gib $((4 * KIB_PER_GIB)))"
# 16 GiB RAM -> 16/4 = 4 GiB, floored to 8
assert_eq "16 GiB RAM -> 8 GiB tmpfs"  "8"  "$(_iso_tmpfs_size_gib $((16 * KIB_PER_GIB)))"
# 32 GiB RAM -> 32/4 = 8 GiB, exactly
assert_eq "32 GiB RAM -> 8 GiB tmpfs"  "8"  "$(_iso_tmpfs_size_gib $((32 * KIB_PER_GIB)))"
# 48 GiB RAM -> 12 GiB tmpfs
assert_eq "48 GiB RAM -> 12 GiB tmpfs" "12" "$(_iso_tmpfs_size_gib $((48 * KIB_PER_GIB)))"
# 64 GiB RAM -> 16 GiB, capped
assert_eq "64 GiB RAM -> 16 GiB tmpfs" "16" "$(_iso_tmpfs_size_gib $((64 * KIB_PER_GIB)))"
# 256 GiB RAM -> 16 GiB, capped
assert_eq "256 GiB RAM -> capped 16"   "16" "$(_iso_tmpfs_size_gib $((256 * KIB_PER_GIB)))"
# Garbage -> safe default 8 GiB
assert_eq "0 RAM -> default 8"         "8"  "$(_iso_tmpfs_size_gib 0)"
assert_eq "empty RAM -> default 8"     "8"  "$(_iso_tmpfs_size_gib "")"
assert_eq "garbage RAM -> default 8"   "8"  "$(_iso_tmpfs_size_gib "abc")"

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
exit "$TESTS_FAILED"
