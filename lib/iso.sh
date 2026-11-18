# ISO download with checksum verification, dependency installation
# shellcheck shell=bash

readonly ISO_BASE_URL="https://enterprise.proxmox.com/iso"
readonly PVE_KEY_BASE_URL="https://enterprise.proxmox.com/debian"

# Release keys for the rescue system's APT source (pve-no-subscription),
# pinned to the checksums published on pve.proxmox.com.
#   codename|key file|install path|checksum tool|checksum
readonly -a PVE_REPO_KEYS=(
    "trixie|proxmox-archive-keyring-trixie.gpg|/usr/share/keyrings/proxmox-archive-keyring.gpg|sha256sum|136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"
    "bookworm|proxmox-release-bookworm.gpg|/usr/share/keyrings/proxmox-release-bookworm.gpg|sha512sum|7da6fe34168adc6e479327ba517796d4702fa2f8b4f0a9833f5ea6e6b48f6507a6da403a274fe201595edc86a84463d50383d07f64bdde2e3658108db7d6dc87"
)

# Minimum free space (GiB) we need in the working directory for the ISO
# (~1.7 GB), the autoinstall copy (~1.7 GB), generated configs, and logs.
readonly ISO_WORKSPACE_MIN_FREE_GIB=5
readonly ISO_WORKSPACE_TMPFS_MOUNT="/mnt/pve-dedicated-work"

declare -g PVE_ISO_NAME=""

# Rescue IPv6 is unreliable on both providers; force IPv4 for all downloads.
_iso_curl() {
    curl -4 --proto '=https,http' --connect-timeout 20 "$@"
}

# Pure helper: given available bytes and a min-GiB threshold, decide if the
# workspace has enough room. Returns "ok" or "switch" on stdout. Tested in
# tests/test-workspace-capacity.sh -- keep behavior in sync.
_iso_workspace_decision() {
    local avail_bytes="$1"
    local min_free_gib="${2:-${ISO_WORKSPACE_MIN_FREE_GIB}}"
    if [[ ! "$avail_bytes" =~ ^[0-9]+$ ]]; then
        avail_bytes=0
    fi
    local avail_gib=$(( avail_bytes / 1073741824 ))
    if (( avail_gib >= min_free_gib )); then
        echo "ok"
    else
        echo "switch"
    fi
}

# Pure helper: pick a tmpfs size (GiB) given total RAM (KiB).
# Floor 8 GiB (enough for two ISO copies + headroom), cap 16 GiB.
_iso_tmpfs_size_gib() {
    local total_ram_kib="$1"
    if [[ ! "$total_ram_kib" =~ ^[0-9]+$ ]] || (( total_ram_kib == 0 )); then
        echo 8
        return 0
    fi
    local size_gib=$(( total_ram_kib / 1024 / 1024 / 4 ))
    if (( size_gib < 8 )); then size_gib=8; fi
    if (( size_gib > 16 )); then size_gib=16; fi
    echo "$size_gib"
}

# Pure helper: Debian suite for a Proxmox VE ISO version ("9.2-1" -> trixie).
iso_debian_suite_for_version() {
    case "${1%%.*}" in
        7)  echo "bullseye" ;;
        8)  echo "bookworm" ;;
        9)  echo "trixie" ;;
        10) echo "forky" ;;
        *)  return 1 ;;
    esac
}

# Pure helper: pick the newest amd64 PVE ISO name from an index page on
# stdin, optionally restricted to a version prefix ("9", "9.2", "9.2-1").
iso_pick_latest() {
    local want="${1:-}"
    local re='proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso'
    local names
    names="$(grep -oE "$re" | sort -uV)"
    if [[ -n "$want" ]]; then
        local w="${want//./\\.}"
        if [[ "$want" == *-* ]]; then
            names="$(grep -E "^proxmox-ve_${w}\.iso$" <<< "$names" || true)"
        else
            names="$(grep -E "^proxmox-ve_${w}[.-]" <<< "$names" || true)"
        fi
    fi
    [[ -n "$names" ]] || return 1
    tail -n1 <<< "$names"
}

iso_extract_version() {
    local iso_name="$1"
    if [[ "$iso_name" =~ proxmox-ve_([0-9]+\.[0-9]+-[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# Probe PVE_WORKING_DIR free space; if too small (or `df` reports garbage,
# common on rescue rootfs which shows 0/0/0), mount a sized tmpfs at
# /mnt/pve-dedicated-work and switch PVE_WORKING_DIR to it. Idempotent:
# safe to call from re-runs (re-uses an existing mount).
iso_ensure_workspace_capacity() {
    local current_dir="${PVE_WORKING_DIR:-/root}"
    local mount="$ISO_WORKSPACE_TMPFS_MOUNT"

    local avail_bytes=0
    if [[ -d "$current_dir" ]]; then
        avail_bytes="$(df -P -B1 "$current_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    fi
    avail_bytes="${avail_bytes:-0}"

    local decision
    decision="$(_iso_workspace_decision "$avail_bytes")"
    log_debug "Workspace check: ${current_dir} has ${avail_bytes} bytes free -> ${decision}"

    if [[ "$decision" == "ok" ]]; then
        return 0
    fi

    local avail_gib=$(( avail_bytes / 1073741824 ))
    ui_warn "Workspace '${current_dir}' has only ${avail_gib} GiB free (need >= ${ISO_WORKSPACE_MIN_FREE_GIB} GiB)"

    if mountpoint -q "$mount" 2>/dev/null; then
        ui_info "Re-using existing tmpfs at ${mount}"
    else
        local total_ram_kib size_gib
        total_ram_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
        size_gib="$(_iso_tmpfs_size_gib "${total_ram_kib:-0}")"

        ui_info "Mounting ${size_gib} GiB tmpfs at ${mount} for build artifacts"
        mkdir -p "$mount" || die "Could not create ${mount}"
        if ! mount -t tmpfs -o "size=${size_gib}G,mode=0700" tmpfs "$mount"; then
            die "Failed to mount ${size_gib} GiB tmpfs at ${mount}"
        fi
        ui_success "Mounted ${size_gib} GiB tmpfs at ${mount}"
    fi

    # Migrate an already-downloaded ISO so we don't burn another download.
    local f
    for f in pve.iso pve.iso.name; do
        if [[ -f "${current_dir}/${f}" ]] && [[ ! -f "${mount}/${f}" ]]; then
            log_info "Moving cached ${f} from ${current_dir} to ${mount}"
            mv "${current_dir}/${f}" "${mount}/${f}" 2>/dev/null \
                || cp "${current_dir}/${f}" "${mount}/${f}"
        fi
    done
    if [[ -d "${current_dir}/generated" ]] && [[ ! -d "${mount}/generated" ]]; then
        mv "${current_dir}/generated" "${mount}/generated" 2>/dev/null || true
    fi

    PVE_WORKING_DIR="$mount"
    cd "$PVE_WORKING_DIR" || die "Cannot cd to new workspace ${mount}"
    ui_kv "Workspace" "$PVE_WORKING_DIR"
}

# Debian codename of the rescue system (bookworm, trixie, ...).
_iso_rescue_codename() {
    local codename=""
    if [[ -r /etc/os-release ]]; then
        codename="$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)"
    fi
    echo "${codename:-unknown}"
}

# Configure the Proxmox APT repository in the rescue system with a
# checksum-pinned keyring and a deb822 source (Signed-By, no global trust).
iso_setup_rescue_repo() {
    local codename entry key_file key_path sum_tool sum_expected
    codename="$(_iso_rescue_codename)"

    for entry in "${PVE_REPO_KEYS[@]}"; do
        if [[ "${entry%%|*}" == "$codename" ]]; then
            IFS='|' read -r _ key_file key_path sum_tool sum_expected <<< "$entry"
            break
        fi
    done
    if [[ -z "${key_file:-}" ]]; then
        log_warn "Rescue system is Debian '${codename}'; using the trixie Proxmox repository"
        codename="trixie"
        IFS='|' read -r _ key_file key_path sum_tool sum_expected <<< "${PVE_REPO_KEYS[0]}"
    fi

    local tmp_key
    tmp_key="$(mktemp)"
    cleanup_register_temp "$tmp_key"
    ui_spinner_start "Fetching Proxmox release key (${codename})"
    if ! _iso_curl -fsSL --retry 3 -o "$tmp_key" "${PVE_KEY_BASE_URL}/${key_file}" 2>>"${LOG_FILE:-/dev/null}"; then
        ui_spinner_stop false
        die "Could not download ${PVE_KEY_BASE_URL}/${key_file}"
    fi
    local sum_actual
    sum_actual="$("$sum_tool" "$tmp_key" | awk '{print $1}')"
    if [[ "$sum_actual" != "$sum_expected" ]]; then
        ui_spinner_stop false
        die "Proxmox release key checksum mismatch (${sum_tool}): got ${sum_actual}"
    fi
    install -m 0644 "$tmp_key" "$key_path"
    ui_spinner_stop true

    rm -f /etc/apt/sources.list.d/pve-installer.list
    cat > /etc/apt/sources.list.d/pve-installer.sources <<SOURCES
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${codename}
Components: pve-no-subscription
Signed-By: ${key_path}
SOURCES
    chmod 644 /etc/apt/sources.list.d/pve-installer.sources
}

iso_install_dependencies() {
    iso_ensure_workspace_capacity

    log_info "Installing required packages..."

    # Force apt to use IPv4 only (rescue IPv6 is unreliable)
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    chmod 644 /etc/apt/apt.conf.d/99force-ipv4

    iso_setup_rescue_repo

    ui_spinner_start "Updating package lists"
    if ! ( umask 022 && apt-get -q update ) >>"${LOG_FILE:-/dev/null}" 2>&1; then
        ui_spinner_stop false
        die "apt-get update failed (see ${LOG_FILE:-the log})"
    fi
    ui_spinner_stop true

    # Recommends stay enabled: qemu-system-x86 pulls the iPXE option ROMs
    # its default NIC needs from there.
    local packages=(
        qemu-system-x86
        proxmox-auto-install-assistant
        xorriso
        ovmf
        curl
        socat
        openssl
        jq
        molly-guard
    )

    ui_spinner_start "Installing packages: ${packages[*]}"
    if ! ( umask 022 && DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        "${packages[@]}" ) >>"${LOG_FILE:-/dev/null}" 2>&1; then
        ui_spinner_stop false
        die "Package installation failed (see ${LOG_FILE:-the log})"
    fi
    ui_spinner_stop true

    local missing=() bin
    for bin in qemu-system-x86_64 proxmox-auto-install-assistant xorriso socat; do
        command -v "$bin" >/dev/null || missing+=("$bin")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required binaries after install: ${missing[*]}"
    fi

    ui_success "All dependencies installed"
}

iso_get_latest_url() {
    log_debug "Fetching ISO list from ${ISO_BASE_URL}/"

    local page
    page="$(_iso_curl -fsSL --retry 3 "${ISO_BASE_URL}/" 2>/dev/null)" || die "Failed to fetch ISO listing from ${ISO_BASE_URL}/"

    local latest_iso
    if ! latest_iso="$(iso_pick_latest "${PVE_ISO_VERSION:-}" <<< "$page")"; then
        die "No Proxmox VE ISO matching '${PVE_ISO_VERSION:-latest}' at ${ISO_BASE_URL}/"
    fi

    echo "${ISO_BASE_URL}/${latest_iso}"
}

# Expected SHA-256 for ISO_NAME, from SHA256SUMS (or the per-file .sha256).
iso_expected_sha256() {
    local iso_name="$1"
    local sums hash=""
    if sums="$(_iso_curl -fsSL --retry 3 "${ISO_BASE_URL}/SHA256SUMS" 2>/dev/null)"; then
        hash="$(awk -v n="$iso_name" '$2 == n || $2 == "*"n {print $1; exit}' <<< "$sums")"
    fi
    if [[ -z "$hash" ]] && sums="$(_iso_curl -fsSL --retry 3 "${ISO_BASE_URL}/${iso_name}.sha256" 2>/dev/null)"; then
        hash="$(awk 'NR == 1 {print $1}' <<< "$sums")"
    fi
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    echo "$hash"
}

# Verify FILE against the published checksum of ISO_NAME. Returns 0 on
# match, 1 on mismatch; dies when no checksum can be obtained.
iso_verify_checksum() {
    local iso_name="$1"
    local iso_file="$2"

    local expected
    if ! expected="$(iso_expected_sha256 "$iso_name")"; then
        die "No published SHA-256 found for ${iso_name}; re-run with --no-iso-verify to skip verification"
    fi

    ui_spinner_start "Verifying ISO checksum (SHA-256)"
    local actual
    actual="$(sha256sum "$iso_file" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
        ui_spinner_stop true
        return 0
    fi
    ui_spinner_stop false
    log_error "Checksum mismatch for ${iso_name}: expected ${expected}, got ${actual}"
    return 1
}

_iso_set_version_facts() {
    local iso_name="$1"
    # shellcheck disable=SC2034  # read by lib/report.sh
    PVE_ISO_NAME="$iso_name"
    local version suite
    version="$(iso_extract_version "$iso_name")"
    if [[ -z "$PVE_DEBIAN_SUITE" ]] || ! config_is_explicit PVE_DEBIAN_SUITE; then
        if suite="$(iso_debian_suite_for_version "$version")"; then
            PVE_DEBIAN_SUITE="$suite"
        elif [[ -z "$PVE_DEBIAN_SUITE" ]]; then
            PVE_DEBIAN_SUITE="trixie"
            log_warn "Cannot derive the Debian suite from '${iso_name}'; assuming trixie (override with --debian-suite)"
        fi
    fi
    log_info "Proxmox VE ${version} -> Debian suite ${PVE_DEBIAN_SUITE}"
}

iso_download() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local iso_file="${working_dir}/pve.iso"
    local name_file="${working_dir}/pve.iso.name"

    if [[ -n "$PVE_ISO_PATH" ]]; then
        [[ -f "$PVE_ISO_PATH" ]] || die "Specified ISO not found: ${PVE_ISO_PATH}"
        if [[ "$(readlink -f "$PVE_ISO_PATH")" != "$(readlink -f "$iso_file")" ]]; then
            cp "$PVE_ISO_PATH" "$iso_file"
        fi
        _iso_set_version_facts "$(basename "$PVE_ISO_PATH")"
        ui_success "Using provided ISO: ${PVE_ISO_PATH}"
        return 0
    fi

    ui_spinner_start "Discovering Proxmox VE ISO (${PVE_ISO_VERSION:-latest})"
    local iso_url
    iso_url="$(iso_get_latest_url)"
    ui_spinner_stop true

    local iso_name
    iso_name="$(basename "$iso_url")"
    ui_info "Selected: Proxmox VE $(iso_extract_version "$iso_name") (${iso_url})"

    if [[ -f "$iso_file" ]] && [[ "$(cat "$name_file" 2>/dev/null)" == "$iso_name" ]]; then
        if [[ "$PVE_ISO_VERIFY" != true ]] || iso_verify_checksum "$iso_name" "$iso_file"; then
            ui_success "Cached ISO ${iso_name} is valid, skipping download"
            _iso_set_version_facts "$iso_name"
            return 0
        fi
        ui_warn "Cached ISO is corrupt; downloading again"
        rm -f "$iso_file" "$name_file"
    elif [[ -f "$iso_file" ]]; then
        ui_info "Cached ISO is not ${iso_name}; downloading the selected version"
        rm -f "$iso_file" "$name_file"
    fi

    local part="${working_dir}/${iso_name}.part"
    ui_info "Downloading ${iso_name}..."
    local -a progress=(-sS)
    if [[ -t 1 ]]; then
        progress=(--progress-bar)
    fi
    if ! _iso_curl -fL --retry 5 --retry-delay 5 --retry-all-errors -C - \
        "${progress[@]}" -o "$part" "$iso_url"; then
        die "ISO download failed: ${iso_url} (partial file kept at ${part} for resume)"
    fi

    if [[ "$PVE_ISO_VERIFY" == true ]]; then
        if ! iso_verify_checksum "$iso_name" "$part"; then
            rm -f "$part"
            die "Downloaded ISO failed checksum verification; it has been deleted, please retry"
        fi
        ui_success "Checksum verified: SHA-256 matches"
    else
        ui_warn "ISO checksum verification skipped (--no-iso-verify)"
    fi

    mv "$part" "$iso_file"
    echo "$iso_name" > "$name_file"
    ui_success "ISO ready: ${iso_name} ($(du -h "$iso_file" | awk '{print $1}'))"
    _iso_set_version_facts "$iso_name"
}

iso_prepare_autoinstall() {
    local working_dir="${PVE_WORKING_DIR:-/root}"
    local iso_file="${working_dir}/pve.iso"
    local answer_file="${working_dir}/generated/answer.toml"
    local output_file="${working_dir}/pve-autoinstall.iso"
    local firstboot_file="${working_dir}/generated/first-boot.sh"

    [[ -f "$iso_file" ]] || die "ISO file not found: ${iso_file}"
    [[ -f "$answer_file" ]] || die "Answer file not found: ${answer_file}"

    rm -f "$output_file"
    ui_spinner_start "Preparing auto-install ISO"

    local -a cmd=(
        proxmox-auto-install-assistant prepare-iso "$iso_file"
        --fetch-from iso
        --answer-file "$answer_file"
        --output "$output_file"
    )

    if [[ -f "$firstboot_file" ]]; then
        chmod 700 "$firstboot_file"
        cmd+=(--on-first-boot "$firstboot_file")
        log_info "First-boot hook included in ISO"
    fi

    if ! "${cmd[@]}" >>"${LOG_FILE:-/dev/null}" 2>&1; then
        ui_spinner_stop false
        die "Failed to prepare auto-install ISO (see ${LOG_FILE:-the log})"
    fi
    chmod 600 "$output_file"

    ui_spinner_stop true
    ui_success "Auto-install ISO created: ${output_file}"
}
