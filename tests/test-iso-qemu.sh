#!/usr/bin/env bash
# Unit tests for the pure helpers in lib/iso.sh, lib/hardware.sh, lib/qemu.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
LOG_LEVEL=4
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/iso.sh"
source "${SCRIPT_DIR}/lib/hardware.sh"
source "${SCRIPT_DIR}/lib/disk.sh"
source "${SCRIPT_DIR}/lib/qemu.sh"
source "${SCRIPT_DIR}/tests/helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== iso/hardware/qemu tests ==="

# --- ISO selection from an index page -----------------------------------------
INDEX='<a href="./proxmox-ve_8.4-1.iso">x</a>
<a href="./proxmox-ve_9.0-1.iso">x</a>
<a href="./proxmox-ve_9.1-1.iso">x</a>
<a href="./proxmox-ve_9.1-2.iso">x</a>
<a href="./proxmox-ve_9.10-1.iso">x</a>
<a href="./proxmox-ve_9.2-1-arm64.iso">x</a>
<a href="./proxmox-backup-server_4.0-1.iso">x</a>'
assert_eq "latest uses version sort" "proxmox-ve_9.10-1.iso" "$(iso_pick_latest <<< "$INDEX")"
assert_eq "arm64 ISO is never picked" "proxmox-ve_9.1-2.iso" "$(iso_pick_latest 9.1 <<< "$INDEX")"
assert_eq "pin major 8" "proxmox-ve_8.4-1.iso" "$(iso_pick_latest 8 <<< "$INDEX")"
assert_eq "pin exact release" "proxmox-ve_9.1-1.iso" "$(iso_pick_latest 9.1-1 <<< "$INDEX")"
assert_eq "pin 9.1 does not match 9.10" "proxmox-ve_9.1-2.iso" "$(iso_pick_latest 9.1 <<< "$INDEX")"
assert_fail "unknown pin fails" iso_pick_latest 7 <<< "$INDEX"

assert_eq "version from name" "9.2-1" "$(iso_extract_version proxmox-ve_9.2-1.iso)"
assert_eq "version unknown" "unknown" "$(iso_extract_version custom.iso)"
assert_eq "suite for 9.x" "trixie" "$(iso_debian_suite_for_version 9.2-1)"
assert_eq "suite for 8.x" "bookworm" "$(iso_debian_suite_for_version 8.4-1)"
assert_fail "suite for unknown" iso_debian_suite_for_version unknown

# Suite derivation honours an explicit --debian-suite
PVE_DEBIAN_SUITE="trixie"; PVE_CONFIG_EXPLICIT=()
_iso_set_version_facts proxmox-ve_8.4-1.iso
assert_eq "non-explicit suite is derived" "bookworm" "$PVE_DEBIAN_SUITE"
PVE_DEBIAN_SUITE="trixie"; PVE_CONFIG_EXPLICIT=([PVE_DEBIAN_SUITE]=1)
_iso_set_version_facts proxmox-ve_8.4-1.iso
assert_eq "explicit suite is kept" "trixie" "$PVE_DEBIAN_SUITE"

# --- QEMU RAM sizing -----------------------------------------------------------
assert_eq "8 GiB host -> 3 GiB guest" "3072" "$(hw_qemu_ram_mb 8192)"
assert_eq "16 GiB host keeps 5 GiB" "11264" "$(hw_qemu_ram_mb 16384)"
assert_eq "64 GiB host capped at 16 GiB" "16384" "$(hw_qemu_ram_mb 65536)"
assert_eq "4 GiB host floor 2 GiB" "2048" "$(hw_qemu_ram_mb 4096)"
assert_eq "garbage -> floor" "2048" "$(hw_qemu_ram_mb abc)"

# --- OVMF discovery --------------------------------------------------------------
mkdir -p "$TMP/fw/usr/share/OVMF" "$TMP/fw/usr/share/ovmf"
touch "$TMP/fw/usr/share/ovmf/OVMF.fd"
assert_eq "combined image fallback" "bios|$TMP/fw/usr/share/ovmf/OVMF.fd|" \
    "$(PVE_FIRMWARE_ROOT="$TMP/fw" hw_find_uefi_firmware)"
touch "$TMP/fw/usr/share/OVMF/OVMF_CODE_4M.fd" "$TMP/fw/usr/share/OVMF/OVMF_VARS_4M.fd"
assert_eq "trixie 4M pflash pair preferred" \
    "pflash|$TMP/fw/usr/share/OVMF/OVMF_CODE_4M.fd|$TMP/fw/usr/share/OVMF/OVMF_VARS_4M.fd" \
    "$(PVE_FIRMWARE_ROOT="$TMP/fw" hw_find_uefi_firmware)"
assert_fail "no firmware" env PVE_FIRMWARE_ROOT="$TMP/none" bash -c \
    "source '${SCRIPT_DIR}/lib/hardware.sh'; hw_find_uefi_firmware"

# --- QEMU disk arguments -----------------------------------------------------------
SELECTED_DISKS=(nvme0n1 nvme1n1)
disk_build_qemu_args
args="${QEMU_DISK_ARGS[*]}"
assert_eq "two -drive and two -device per disk pair" "8" "${#QEMU_DISK_ARGS[@]}"
assert_contains "raw disk, no host cache" "file=/dev/nvme0n1,format=raw,if=none,id=disk0,cache=none" "$args"
assert_contains "virtio-blk with block sizes" "virtio-blk-pci,drive=disk1,logical_block_size=" "$args"
assert_eq "answer disk list" '["vda","vdb"]' "$(disk_build_answer_list)"

# --- Serial-log phase detection --------------------------------------------------
assert_eq "no output yet" "0|Waiting for installer to start" "$(printf '' | qemu_detect_phase)"
assert_eq "zpool phase" "2|Creating filesystems" "$(printf 'boot\ncreating zpool rpool\n' | qemu_detect_phase)"
assert_eq "complete phase" "6|Installation complete" "$(printf 'Installation finished\n' | qemu_detect_phase)"

tests_summary
