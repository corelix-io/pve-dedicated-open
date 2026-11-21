# Disk discovery, selection, RAID validation, and QEMU argument building
# shellcheck shell=bash

declare -ga DETECTED_DISKS=()
declare -ga SELECTED_DISKS=()
declare -ga QEMU_DISK_ARGS=()

# Sanity floor: a disk below 8 GiB cannot host Proxmox VE.
readonly DISK_MIN_BYTES=$(( 8 * 1024 * 1024 * 1024 ))

# Pure filter used by disk_detect. Echoes "keep", "skip-name" (virtual or
# placeholder device), "skip-zero" (no readable size) or "skip-small".
# OVH rescue loads `nbd` by default, which registers 16 empty network block
# devices that would otherwise be auto-selected for the install pool.
disk_filter_reason() {
    local name="$1"
    local size_b="$2"
    case "$name" in
        loop*|sr*|fd*|nbd*|ram*|md*|dm-*|zd*|zram*|nullb*) echo "skip-name"; return 0 ;;
    esac
    if [[ ! "$size_b" =~ ^[0-9]+$ ]] || (( size_b == 0 )); then
        echo "skip-zero"
    elif (( size_b < DISK_MIN_BYTES )); then
        echo "skip-small"
    else
        echo "keep"
    fi
}

# Extract KEY="value" from one line of `lsblk -P` output.
_disk_pair() {
    local line="$1" key="$2"
    if [[ "$line" =~ (^|[[:space:]])${key}=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

# Field N (1-based) of a DETECTED_DISKS entry "name|size|tran|model".
_disk_field() {
    local entry="$1" n="$2"
    local -a f
    IFS='|' read -ra f <<< "$entry"
    printf '%s' "${f[n-1]:-}"
}

disk_detect() {
    log_info "Detecting available disks..."
    DETECTED_DISKS=()

    local line name size_b type tran model
    while IFS= read -r line; do
        name="$(_disk_pair "$line" NAME)"
        size_b="$(_disk_pair "$line" SIZE)"
        type="$(_disk_pair "$line" TYPE)"
        tran="$(_disk_pair "$line" TRAN)"
        model="$(_disk_pair "$line" MODEL)"
        model="${model//\\x20/ }"
        model="${model#"${model%%[![:space:]]*}"}"
        model="${model%"${model##*[![:space:]]}"}"

        [[ "$type" != "disk" ]] && continue

        local reason
        reason="$(disk_filter_reason "$name" "$size_b")"
        if [[ "$reason" != "keep" ]]; then
            log_debug "Skipping ${name}: ${reason} (size: ${size_b:-none})"
            continue
        fi

        DETECTED_DISKS+=("${name}|$(_disk_fmt_size "$size_b")|${tran:-unknown}|${model:-Unknown}")
    done < <(lsblk -dnbP -o NAME,SIZE,TYPE,TRAN,MODEL 2>/dev/null)

    if [[ ${#DETECTED_DISKS[@]} -eq 0 ]]; then
        die "No disks detected. Check that drives are connected."
    fi

    ui_success "Found ${#DETECTED_DISKS[@]} disk(s):"
    local idx=1 entry
    for entry in "${DETECTED_DISKS[@]}"; do
        ui_detail "[${idx}] /dev/$(_disk_field "$entry" 1) -- $(_disk_field "$entry" 2) ($(_disk_field "$entry" 3)) $(_disk_field "$entry" 4)"
        idx=$(( idx + 1 ))
    done
}

_disk_is_detected() {
    local want="$1" entry
    for entry in "${DETECTED_DISKS[@]}"; do
        if [[ "$(_disk_field "$entry" 1)" == "$want" ]]; then
            return 0
        fi
    done
    return 1
}

_disk_add_selected() {
    local disk="$1" d
    for d in "${SELECTED_DISKS[@]}"; do
        [[ "$d" == "$disk" ]] && return 0
    done
    SELECTED_DISKS+=("$disk")
}

disk_select() {
    SELECTED_DISKS=()
    local entry name

    if [[ -n "$PVE_DISKS" ]]; then
        local -a user_disks
        local ud
        IFS=', ' read -ra user_disks <<< "${PVE_DISKS//,/ }"
        for ud in "${user_disks[@]}"; do
            [[ -z "$ud" ]] && continue
            ud="${ud#/dev/}"
            if ! _disk_is_detected "$ud"; then
                die "Specified disk not found (or too small/virtual): ${ud}"
            fi
            _disk_add_selected "$ud"
        done
        ui_success "Using specified disks: ${SELECTED_DISKS[*]}"
        return 0
    fi

    # Auto-select when unattended, auto mode, or stdin is not a terminal.
    # USB devices (rescue sticks, virtual media) are never auto-selected.
    if [[ "$PVE_DISK_MODE" == "auto" ]] || [[ "${PVE_UNATTENDED:-false}" == true ]] || [[ ! -t 0 ]]; then
        for entry in "${DETECTED_DISKS[@]}"; do
            name="$(_disk_field "$entry" 1)"
            if [[ "$(_disk_field "$entry" 3)" == "usb" ]]; then
                ui_warn "Skipping USB disk /dev/${name} in auto mode (use --disks to force)"
                continue
            fi
            _disk_add_selected "$name"
        done
        if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
            die "No eligible disks for auto-selection (use --disks to choose explicitly)"
        fi
        ui_success "Auto-selected ${#SELECTED_DISKS[@]} disk(s): ${SELECTED_DISKS[*]}"
        disk_warn_size_mismatch
        return 0
    fi

    echo ""
    ui_info "Select disks for installation (space-separated numbers, or 'all'):"
    local answer=""
    ui_read answer "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Disks: ")" "all"

    if [[ -z "$answer" ]] || [[ "$answer" == "all" ]]; then
        for entry in "${DETECTED_DISKS[@]}"; do
            _disk_add_selected "$(_disk_field "$entry" 1)"
        done
    else
        local num
        for num in ${answer//,/ }; do
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                die "Invalid disk number: ${num}"
            fi
            local idx=$(( 10#$num - 1 ))
            if (( idx >= 0 && idx < ${#DETECTED_DISKS[@]} )); then
                _disk_add_selected "$(_disk_field "${DETECTED_DISKS[$idx]}" 1)"
            else
                die "Invalid disk number: ${num}"
            fi
        done
    fi

    if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
        die "No disks selected"
    fi

    ui_success "Selected ${#SELECTED_DISKS[@]} disk(s): ${SELECTED_DISKS[*]}"
    disk_warn_size_mismatch
}

# Get raw disk size in bytes for capacity calculations
_disk_size_bytes() {
    local disk="$1"
    lsblk -bdno SIZE "/dev/${disk}" 2>/dev/null | head -1 | tr -d ' '
}

# Format bytes to human-readable using pure bash integer math
_disk_fmt_size() {
    local bytes="${1:-0}"
    if [[ -z "$bytes" ]] || [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
        echo "? GB"
        return 0
    fi

    local gb=$(( bytes / 1073741824 ))
    if (( gb >= 1024 )); then
        local tb_whole=$(( gb / 1024 ))
        local tb_frac=$(( (gb % 1024) * 10 / 1024 ))
        echo "${tb_whole}.${tb_frac} TB"
    elif (( gb > 0 )); then
        echo "${gb} GB"
    else
        echo "$(( bytes / 1048576 )) MB"
    fi
}

# Smallest selected disk in bytes (ZFS vdevs are sized by their smallest member).
_disk_min_selected_bytes() {
    local min=0 disk sz
    for disk in "${SELECTED_DISKS[@]}"; do
        sz="$(_disk_size_bytes "$disk")"
        [[ "$sz" =~ ^[0-9]+$ ]] || continue
        if (( min == 0 || sz < min )); then
            min="$sz"
        fi
    done
    echo "$min"
}

disk_warn_size_mismatch() {
    local min=0 max=0 disk sz
    for disk in "${SELECTED_DISKS[@]}"; do
        sz="$(_disk_size_bytes "$disk")"
        [[ "$sz" =~ ^[0-9]+$ ]] || continue
        if (( min == 0 || sz < min )); then min="$sz"; fi
        if (( sz > max )); then max="$sz"; fi
    done
    if (( max > 0 && min * 10 < max * 9 )); then
        ui_warn "Selected disks differ in size ($(_disk_fmt_size "$min") vs $(_disk_fmt_size "$max")); a redundant pool only uses the smallest size per disk"
    fi
}

# Usable capacity (bytes) for a ZFS layout across COUNT disks of MIN bytes.
_disk_raid_capacity() {
    local raid="$1" min="$2" count="$3"
    case "$raid" in
        raid0)   echo $(( min * count )) ;;
        raid1)   echo "$min" ;;
        raid10)  echo $(( min * count / 2 )) ;;
        raidz-1) echo $(( min * (count - 1) )) ;;
        raidz-2) echo $(( min * (count - 2) )) ;;
        raidz-3) echo $(( min * (count - 3) )) ;;
        *)       echo 0 ;;
    esac
}

# Interactive RAID level selection with capacity and reliability info
disk_select_raid() {
    if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
        return 0
    fi

    local num_disks=${#SELECTED_DISKS[@]}
    local min_bytes
    min_bytes="$(_disk_min_selected_bytes)"
    local single_size
    single_size="$(_disk_fmt_size "$min_bytes")"

    if [[ -n "$PVE_ZFS_RAID" ]] && [[ "${PVE_UNATTENDED:-false}" == true ]]; then
        validate_disk_count_for_raid "$PVE_ZFS_RAID" "$num_disks" \
            || die "ZFS ${PVE_ZFS_RAID} is not possible with ${num_disks} disk(s)"
        ui_success "ZFS RAID: ${PVE_ZFS_RAID} (set via config)"
        return 0
    fi

    # name|min-disks|redundancy|description
    local -a catalog=(
        "raid0|1|NONE|Striped, max speed. ANY disk failure = total data loss."
        "raid1|2|1 disk|Mirror. Survives 1 disk failure. RECOMMENDED."
        "raid10|4|1 per pair|Striped mirrors. Speed + redundancy (even count)."
        "raidz-1|3|1 disk|Single parity. Good capacity/safety balance."
        "raidz-2|4|2 disks|Double parity. Survives 2 simultaneous failures."
        "raidz-3|5|3 disks|Triple parity. Maximum protection."
    )

    local -a options=()
    local item level min_n redundancy desc
    for item in "${catalog[@]}"; do
        IFS='|' read -r level min_n redundancy desc <<< "$item"
        (( num_disks >= min_n )) || continue
        if [[ "$level" == "raid10" ]] && (( num_disks % 2 != 0 )); then
            continue
        fi
        options+=("$item")
    done

    if [[ ${#options[@]} -eq 1 ]]; then
        PVE_ZFS_RAID="${options[0]%%|*}"
        ui_success "Only one RAID level available: ${PVE_ZFS_RAID}"
        return 0
    fi

    echo ""
    ui_section "ZFS RAID Level"
    echo ""
    echo -e "  ${CLR_DIM}You have ${CLR_RESET}${CLR_BOLD}${num_disks} disk(s)${CLR_RESET}${CLR_DIM} of ${single_size} each. Choose a RAID level:${CLR_RESET}"
    echo ""
    printf "  ${CLR_BOLD}%-3s %-10s %-14s %-12s %-8s %s${CLR_RESET}\n" \
        "#" "Level" "Usable Space" "Redundancy" "Min" "Description"
    ui_hr 72

    local i color default_num=1 preferred="raid1"
    if config_is_explicit PVE_ZFS_RAID; then
        preferred="$PVE_ZFS_RAID"
    fi
    for i in "${!options[@]}"; do
        IFS='|' read -r level min_n redundancy desc <<< "${options[$i]}"
        color="$CLR_GREEN"
        [[ "$level" == "raid0" ]] && color="$CLR_RED"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${color}%-12s${CLR_RESET} %-8s %s\n" \
            "$(( i + 1 ))" "$level" \
            "$(_disk_fmt_size "$(_disk_raid_capacity "$level" "$min_bytes" "$num_disks")")" \
            "$redundancy" "${min_n} disk$([[ "$min_n" -gt 1 ]] && echo s)" "$desc"
        if [[ "$level" == "$preferred" ]]; then
            default_num=$(( i + 1 ))
        fi
    done
    echo ""

    local choice=""
    ui_read choice "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Select RAID level [1-${#options[@]}]: ")" "$default_num"
    choice="${choice:-$default_num}"

    local picked=""
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$(( 10#$choice - 1 ))
        if (( idx >= 0 && idx < ${#options[@]} )); then
            picked="${options[$idx]%%|*}"
        fi
    else
        for item in "${options[@]}"; do
            if [[ "${item%%|*}" == "$choice" ]]; then
                picked="$choice"
                break
            fi
        done
    fi
    [[ -n "$picked" ]] || die "Invalid RAID selection: ${choice}"
    PVE_ZFS_RAID="$picked"

    echo ""
    ui_success "Selected ZFS ${PVE_ZFS_RAID} -- usable capacity: ~$(_disk_fmt_size "$(_disk_raid_capacity "$PVE_ZFS_RAID" "$min_bytes" "$num_disks")")"
}

disk_validate_raid() {
    if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
        return 0
    fi

    validate_disk_count_for_raid "$PVE_ZFS_RAID" "${#SELECTED_DISKS[@]}" \
        || die "ZFS ${PVE_ZFS_RAID} is not possible with ${#SELECTED_DISKS[@]} disk(s)"
}

# Release everything in the rescue system that holds the selected disks
# (auto-assembled mdadm arrays from a previous install, LVM, swap), refuse
# mounted disks, and wipe old signatures so stale md/ZFS/LVM metadata cannot
# resurface on first boot. Hetzner rescue routinely auto-assembles old md
# arrays; a resync running underneath QEMU would corrupt the new install.
disk_release_selected() {
    local disk part mounts md slave
    for disk in "${SELECTED_DISKS[@]}"; do
        mounts="$(lsblk -nro MOUNTPOINT "/dev/${disk}" 2>/dev/null | grep -v '^$' | grep -v '^\[SWAP\]$' || true)"
        if [[ -n "$mounts" ]]; then
            die "/dev/${disk} has mounted filesystems (${mounts//$'\n'/, }); unmount them first"
        fi
    done

    for md in /sys/block/md*; do
        [[ -d "$md/slaves" ]] || continue
        for slave in "$md"/slaves/*; do
            [[ -e "$slave" ]] || continue
            for disk in "${SELECTED_DISKS[@]}"; do
                if [[ "$(basename "$slave")" =~ ^${disk}(p?[0-9]+)?$ ]]; then
                    ui_info "Stopping mdadm array /dev/$(basename "$md") (uses ${disk})"
                    mdadm --stop "/dev/$(basename "$md")" >>"${LOG_FILE:-/dev/null}" 2>&1 \
                        || die "Failed to stop /dev/$(basename "$md"); stop it manually and retry"
                    continue 3
                fi
            done
        done
    done

    for disk in "${SELECTED_DISKS[@]}"; do
        while IFS= read -r part; do
            [[ -z "$part" ]] && continue
            swapoff "/dev/${part}" 2>/dev/null || true
        done < <(lsblk -nro NAME "/dev/${disk}" 2>/dev/null)
    done

    if command -v pvs >/dev/null 2>&1; then
        local vg
        while IFS= read -r vg; do
            [[ -z "$vg" ]] && continue
            ui_info "Deactivating LVM volume group ${vg}"
            vgchange -an "$vg" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        done < <(for disk in "${SELECTED_DISKS[@]}"; do
                    pvs --noheadings -o vg_name "/dev/${disk}"* 2>/dev/null
                 done | awk 'NF {print $1}' | sort -u)
    fi

    for disk in "${SELECTED_DISKS[@]}"; do
        while IFS= read -r part; do
            [[ -z "$part" || "$part" == "$disk" ]] && continue
            wipefs -af "/dev/${part}" >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        done < <(lsblk -nro NAME "/dev/${disk}" 2>/dev/null)
        wipefs -af "/dev/${disk}" >>"${LOG_FILE:-/dev/null}" 2>&1 \
            || log_warn "wipefs failed on /dev/${disk} (the installer will repartition anyway)"
    done
    udevadm settle 2>/dev/null || true
    ui_success "Released and wiped ${#SELECTED_DISKS[@]} disk(s)"
}

# Build QEMU drive arguments for all selected disks into QEMU_DISK_ARGS.
# Logical/physical block sizes are passed through so 4Kn disks get a GPT
# and partition alignment that the real firmware can read.
disk_build_qemu_args() {
    QEMU_DISK_ARGS=()
    local disk idx=0 lbs pbs
    for disk in "${SELECTED_DISKS[@]}"; do
        lbs="$(cat "/sys/block/${disk}/queue/logical_block_size" 2>/dev/null || echo 512)"
        pbs="$(cat "/sys/block/${disk}/queue/physical_block_size" 2>/dev/null || echo "$lbs")"
        [[ "$lbs" =~ ^[0-9]+$ ]] || lbs=512
        [[ "$pbs" =~ ^[0-9]+$ ]] || pbs="$lbs"
        # QEMU rejects odd physical sizes some NVMe drives report; ZFS
        # only cares about 4K vs 512 here.
        if (( pbs > 4096 )); then pbs=4096; fi
        if (( pbs < lbs )); then pbs="$lbs"; fi
        QEMU_DISK_ARGS+=(
            -drive "file=/dev/${disk},format=raw,if=none,id=disk${idx},cache=none,aio=native,discard=unmap"
            -device "virtio-blk-pci,drive=disk${idx},logical_block_size=${lbs},physical_block_size=${pbs}"
        )
        idx=$(( idx + 1 ))
    done
}

# Build the disk-list for answer.toml using virtio names
disk_build_answer_list() {
    local -a virt_names=()
    local idx=0
    local letters="abcdefghijklmnopqrstuvwxyz"
    local _
    for _ in "${SELECTED_DISKS[@]}"; do
        virt_names+=("\"vd${letters:$idx:1}\"")
        idx=$(( idx + 1 ))
    done

    local IFS=','
    echo "[${virt_names[*]}]"
}

# Get a human-readable disk summary for reports
disk_summary() {
    local count="${#SELECTED_DISKS[@]}"
    local first_entry="" entry
    for entry in "${DETECTED_DISKS[@]}"; do
        if [[ "$(_disk_field "$entry" 1)" == "${SELECTED_DISKS[0]:-}" ]]; then
            first_entry="$entry"
            break
        fi
    done

    local d_size d_tran
    d_size="$(_disk_field "$first_entry" 2)"
    d_tran="$(_disk_field "$first_entry" 3)"

    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        echo "${count}x ${d_tran} ${d_size} (ZFS ${PVE_ZFS_RAID})"
    else
        echo "${count}x ${d_tran} ${d_size} (${PVE_FILESYSTEM})"
    fi
}
