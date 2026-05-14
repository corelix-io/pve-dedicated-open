# Disk discovery, selection, RAID validation, and QEMU argument building
# shellcheck shell=bash

declare -ga DETECTED_DISKS=()
declare -ga SELECTED_DISKS=()

disk_detect() {
    log_info "Detecting available disks..."
    DETECTED_DISKS=()

    local name size size_b type tran model
    while IFS= read -r line; do
        name="$(echo "$line" | awk '{print $1}')"
        size="$(echo "$line" | awk '{print $2}')"
        type="$(echo "$line" | awk '{print $3}')"
        tran="$(echo "$line" | awk '{print $4}')"

        [[ "$type" != "disk" ]] && continue

        # Skip virtual / placeholder block devices that show up as type=disk
        # in rescue environments. OVH rescue loads `nbd` by default, which
        # registers 16 empty network block devices that would otherwise be
        # auto-selected for the install pool and either kill the install
        # or stripe across phantom drives.
        case "$name" in
            loop*|sr*|fd*|nbd*|ram*|md*|dm-*|zd*|zram*|nullb*) continue ;;
        esac

        # Skip zero-sized devices (nbd-style placeholders, empty card readers, etc.)
        # Use raw bytes so we are robust against locale-dependent size formats.
        size_b="$(lsblk -bdno SIZE "/dev/${name}" 2>/dev/null | head -1 | tr -d ' \t')"
        if [[ -z "$size_b" ]] || [[ ! "$size_b" =~ ^[0-9]+$ ]] || (( size_b == 0 )); then
            log_debug "Skipping ${name}: empty / unreadable size (${size_b:-none})"
            continue
        fi
        # Sanity floor: a 4 GiB disk cannot host Proxmox; skip below that.
        if (( size_b < 4294967296 )); then
            log_debug "Skipping ${name}: too small for Proxmox (${size_b} bytes)"
            continue
        fi

        # Get model info
        model="$(lsblk -dno MODEL "/dev/${name}" 2>/dev/null | xargs || echo "Unknown")"

        DETECTED_DISKS+=("${name}|${size}|${tran:-unknown}|${model}")
    done < <(lsblk -dpno NAME,SIZE,TYPE,TRAN 2>/dev/null | sed 's|/dev/||')

    if [[ ${#DETECTED_DISKS[@]} -eq 0 ]]; then
        die "No disks detected. Check that drives are connected."
    fi

    ui_success "Found ${#DETECTED_DISKS[@]} disk(s):"
    local idx=1
    for entry in "${DETECTED_DISKS[@]}"; do
        local d_name d_size d_tran d_model
        IFS='|' read -r d_name d_size d_tran d_model <<< "$entry"
        ui_detail "[${idx}] /dev/${d_name} -- ${d_size} (${d_tran}) ${d_model}"
        (( idx++ ))
    done
}

disk_select() {
    SELECTED_DISKS=()

    if [[ -n "$PVE_DISKS" ]]; then
        IFS=',' read -ra user_disks <<< "$PVE_DISKS"
        for ud in "${user_disks[@]}"; do
            ud="$(echo "$ud" | xargs)"
            local found=false
            for entry in "${DETECTED_DISKS[@]}"; do
                local d_name
                d_name="$(echo "$entry" | cut -d'|' -f1)"
                if [[ "$d_name" == "$ud" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                die "Specified disk not found: ${ud}"
            fi
            SELECTED_DISKS+=("$ud")
        done
        ui_success "Using specified disks: ${SELECTED_DISKS[*]}"
        return 0
    fi

    # Auto-select when unattended, auto mode, or stdin is not a terminal
    if [[ "$PVE_DISK_MODE" == "auto" ]] || [[ "${PVE_UNATTENDED:-false}" == true ]] || [[ ! -t 0 ]]; then
        for entry in "${DETECTED_DISKS[@]}"; do
            local d_name
            d_name="$(echo "$entry" | cut -d'|' -f1)"
            SELECTED_DISKS+=("$d_name")
        done
        ui_success "Auto-selected ${#SELECTED_DISKS[@]} disk(s): ${SELECTED_DISKS[*]}"
        return 0
    fi

    # Interactive disk selection (only when terminal is available)
    echo ""
    ui_info "Select disks for installation (space-separated numbers, or 'all'):"
    local answer=""
    ui_read answer "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Disks: ")" "all"

    if [[ -z "$answer" ]] || [[ "$answer" == "all" ]]; then
        for entry in "${DETECTED_DISKS[@]}"; do
            local d_name
            d_name="$(echo "$entry" | cut -d'|' -f1)"
            SELECTED_DISKS+=("$d_name")
        done
    else
        for num in $answer; do
            local idx=$(( num - 1 ))
            if (( idx >= 0 && idx < ${#DETECTED_DISKS[@]} )); then
                local d_name
                d_name="$(echo "${DETECTED_DISKS[$idx]}" | cut -d'|' -f1)"
                SELECTED_DISKS+=("$d_name")
            else
                die "Invalid disk number: ${num}"
            fi
        done
    fi

    if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
        die "No disks selected"
    fi

    ui_success "Selected ${#SELECTED_DISKS[@]} disk(s): ${SELECTED_DISKS[*]}"
}

# Get raw disk size in bytes for capacity calculations
_disk_size_bytes() {
    local disk="$1"
    lsblk -bdno SIZE "/dev/${disk}" 2>/dev/null | head -1 | tr -d ' '
}

# Format bytes to human-readable using pure bash integer math
_disk_fmt_size() {
    local bytes="${1:-0}"
    # Guard against empty or non-numeric input
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
        local mb=$(( bytes / 1048576 ))
        echo "${mb} MB"
    fi
}

# Interactive RAID level selection with capacity and reliability info
disk_select_raid() {
    if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
        return 0
    fi

    local num_disks=${#SELECTED_DISKS[@]}

    # Get the size of the smallest disk (ZFS uses smallest as baseline)
    local min_bytes=0
    for disk in "${SELECTED_DISKS[@]}"; do
        local sz
        sz="$(_disk_size_bytes "$disk")"
        sz="${sz:-0}"
        if (( min_bytes == 0 )) || (( sz > 0 && sz < min_bytes )); then
            min_bytes="$sz"
        fi
    done

    local single_size
    single_size="$(_disk_fmt_size "$min_bytes")"

    # If already set via CLI/config and valid, just validate and show
    if [[ -n "$PVE_ZFS_RAID" ]] && [[ "${PVE_UNATTENDED:-false}" == true ]]; then
        validate_disk_count_for_raid "$PVE_ZFS_RAID" "$num_disks"
        ui_success "ZFS RAID: ${PVE_ZFS_RAID} (set via config)"
        return 0
    fi

    echo ""
    ui_section "ZFS RAID Level"
    echo ""
    echo -e "  ${CLR_DIM}You have ${CLR_RESET}${CLR_BOLD}${num_disks} disk(s)${CLR_RESET}${CLR_DIM} of ${single_size} each. Choose a RAID level:${CLR_RESET}"
    echo ""

    # Table header
    printf "  ${CLR_BOLD}%-3s %-10s %-14s %-12s %-8s %s${CLR_RESET}\n" \
        "#" "Level" "Usable Space" "Redundancy" "Min" "Description"
    ui_hr 72

    local -a options=()
    local opt_num=1

    # raid0
    if (( num_disks >= 1 )); then
        local cap
        cap="$(_disk_fmt_size $(( min_bytes * num_disks )) )"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${CLR_RED}%-12s${CLR_RESET} %-8s %s\n" \
            "$opt_num" "raid0" "$cap" "NONE" "1 disk" "Striped, max speed. ANY disk failure = total data loss."
        options+=("raid0")
        opt_num=$(( opt_num + 1 ))
    fi

    # raid1
    if (( num_disks >= 2 )); then
        local cap
        cap="$(_disk_fmt_size "$min_bytes")"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${CLR_GREEN}%-12s${CLR_RESET} %-8s %s\n" \
            "$opt_num" "raid1" "$cap" "1 disk" "2 disks" "Mirror. Survives 1 disk failure. RECOMMENDED."
        options+=("raid1")
        opt_num=$(( opt_num + 1 ))
    fi

    # raid10
    if (( num_disks >= 4 )); then
        local cap
        cap="$(_disk_fmt_size $(( min_bytes * num_disks / 2 )) )"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${CLR_GREEN}%-12s${CLR_RESET} %-8s %s\n" \
            "$opt_num" "raid10" "$cap" "1 per pair" "4 disks" "Striped mirrors. Speed + redundancy."
        options+=("raid10")
        opt_num=$(( opt_num + 1 ))
    fi

    # raidz-1
    if (( num_disks >= 3 )); then
        local cap
        cap="$(_disk_fmt_size $(( min_bytes * (num_disks - 1) )) )"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${CLR_GREEN}%-12s${CLR_RESET} %-8s %s\n" \
            "$opt_num" "raidz-1" "$cap" "1 disk" "3 disks" "Single parity. Good capacity/safety balance."
        options+=("raidz-1")
        opt_num=$(( opt_num + 1 ))
    fi

    # raidz-2
    if (( num_disks >= 4 )); then
        local cap
        cap="$(_disk_fmt_size $(( min_bytes * (num_disks - 2) )) )"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${CLR_GREEN}%-12s${CLR_RESET} %-8s %s\n" \
            "$opt_num" "raidz-2" "$cap" "2 disks" "4 disks" "Double parity. Survives 2 simultaneous failures."
        options+=("raidz-2")
        opt_num=$(( opt_num + 1 ))
    fi

    # raidz-3
    if (( num_disks >= 5 )); then
        local cap
        cap="$(_disk_fmt_size $(( min_bytes * (num_disks - 3) )) )"
        printf "  ${CLR_YELLOW}%-3s${CLR_RESET} %-10s %-14s ${CLR_GREEN}%-12s${CLR_RESET} %-8s %s\n" \
            "$opt_num" "raidz-3" "$cap" "3 disks" "5 disks" "Triple parity. Maximum protection."
        options+=("raidz-3")
        opt_num=$(( opt_num + 1 ))
    fi

    echo ""

    # Determine default option (raid1 if 2 disks, else first available)
    local default_num=1
    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "raid1" ]]; then
            default_num=$(( i + 1 ))
            break
        fi
    done

    if [[ ${#options[@]} -eq 1 ]]; then
        PVE_ZFS_RAID="${options[0]}"
        ui_success "Only one RAID level available: ${PVE_ZFS_RAID}"
        return 0
    fi

    local choice=""
    ui_read choice "$(echo -e "  ${CLR_CYAN}?${CLR_RESET} Select RAID level [1-${#options[@]}]: ")" "$default_num"

    if [[ -z "$choice" ]]; then
        choice="$default_num"
    fi

    # Accept either the number or the level name directly
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$(( choice - 1 ))
        if (( idx >= 0 && idx < ${#options[@]} )); then
            PVE_ZFS_RAID="${options[$idx]}"
        else
            die "Invalid selection: ${choice}"
        fi
    else
        # User typed the level name directly
        local valid=false
        for opt in "${options[@]}"; do
            if [[ "$opt" == "$choice" ]]; then
                PVE_ZFS_RAID="$choice"
                valid=true
                break
            fi
        done
        if [[ "$valid" != true ]]; then
            die "Invalid RAID level: ${choice}"
        fi
    fi

    # Show what they picked
    local picked_cap=""
    case "$PVE_ZFS_RAID" in
        raid0)   picked_cap="$(_disk_fmt_size $(( min_bytes * num_disks )) )" ;;
        raid1)   picked_cap="$(_disk_fmt_size "$min_bytes")" ;;
        raid10)  picked_cap="$(_disk_fmt_size $(( min_bytes * num_disks / 2 )) )" ;;
        raidz-1) picked_cap="$(_disk_fmt_size $(( min_bytes * (num_disks - 1) )) )" ;;
        raidz-2) picked_cap="$(_disk_fmt_size $(( min_bytes * (num_disks - 2) )) )" ;;
        raidz-3) picked_cap="$(_disk_fmt_size $(( min_bytes * (num_disks - 3) )) )" ;;
    esac

    echo ""
    ui_success "Selected ZFS ${PVE_ZFS_RAID} -- usable capacity: ~${picked_cap}"
}

disk_validate_raid() {
    if [[ "$PVE_FILESYSTEM" != "zfs" ]]; then
        return 0
    fi

    validate_disk_count_for_raid "$PVE_ZFS_RAID" "${#SELECTED_DISKS[@]}"
}

# Build QEMU -drive arguments for all selected disks
disk_build_qemu_args() {
    local -a args=()
    for disk in "${SELECTED_DISKS[@]}"; do
        args+=("-drive" "file=/dev/${disk},format=raw,media=disk,if=virtio")
    done
    echo "${args[@]}"
}

# Build the disk-list for answer.toml using virtio names
disk_build_answer_list() {
    local -a virt_names=()
    local idx=0
    local letters="abcdefghijklmnopqrstuvwxyz"
    for _ in "${SELECTED_DISKS[@]}"; do
        local letter="${letters:$idx:1}"
        virt_names+=("\"vd${letter}\"")
        idx=$(( idx + 1 ))
    done

    local IFS=','
    echo "[${virt_names[*]}]"
}

# Get a human-readable disk summary for reports
disk_summary() {
    local count="${#SELECTED_DISKS[@]}"
    local first_entry=""
    for entry in "${DETECTED_DISKS[@]}"; do
        local d_name
        d_name="$(echo "$entry" | cut -d'|' -f1)"
        if [[ "$d_name" == "${SELECTED_DISKS[0]}" ]]; then
            first_entry="$entry"
            break
        fi
    done

    local d_size d_tran d_model
    IFS='|' read -r _ d_size d_tran d_model <<< "$first_entry"

    if [[ "$PVE_FILESYSTEM" == "zfs" ]]; then
        echo "${count}x ${d_tran} ${d_size} (ZFS ${PVE_ZFS_RAID})"
    else
        echo "${count}x ${d_tran} ${d_size} (${PVE_FILESYSTEM})"
    fi
}
