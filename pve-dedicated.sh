#!/usr/bin/env bash
# pve-dedicated -- Proxmox VE Installer for Dedicated Servers
# Multi-provider (Hetzner, OVH) automated install from rescue mode.
#
# Provided freely by Corelix.io - Made in France
# Author: Amir Moradi
#
# Usage:
#   Interactive:   ./pve-dedicated.sh
#   Unattended:    ./pve-dedicated.sh --provider hetzner --config configs/myserver.env --unattended
#   Help:          ./pve-dedicated.sh --help
#
# https://github.com/corelix-io/pve-dedicated
set -euo pipefail

# Disable bash history expansion. The installer's own shell would otherwise
# expand `!` sequences in CLI args BEFORE the script's argument parser sees
# them -- a real footgun for --luks-passphrase containing `!`. This affects
# only the installer's interactive history features (which we don't use);
# every CLI arg, env var, and read prompt is unaffected.
set +H

# Resolve script directory for relative sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------
# Source library modules
# ------------------------------------------------------------------
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/ui.sh
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"
# shellcheck source=lib/hardware.sh
source "${SCRIPT_DIR}/lib/hardware.sh"
# shellcheck source=lib/disk.sh
source "${SCRIPT_DIR}/lib/disk.sh"
# shellcheck source=lib/network.sh
source "${SCRIPT_DIR}/lib/network.sh"
# shellcheck source=lib/iso.sh
source "${SCRIPT_DIR}/lib/iso.sh"
# shellcheck source=lib/answer.sh
source "${SCRIPT_DIR}/lib/answer.sh"
# shellcheck source=lib/firstboot.sh
source "${SCRIPT_DIR}/lib/firstboot.sh"
# shellcheck source=lib/qemu.sh
source "${SCRIPT_DIR}/lib/qemu.sh"
# shellcheck source=lib/ssh-config.sh
source "${SCRIPT_DIR}/lib/ssh-config.sh"
# shellcheck source=lib/report.sh
source "${SCRIPT_DIR}/lib/report.sh"

# Provider modules (provider abstraction layer)
# shellcheck source=lib/providers/common.sh
source "${SCRIPT_DIR}/lib/providers/common.sh"
# shellcheck source=lib/providers/hetzner.sh
source "${SCRIPT_DIR}/lib/providers/hetzner.sh"
# shellcheck source=lib/providers/ovh.sh
source "${SCRIPT_DIR}/lib/providers/ovh.sh"

# Premium feature modules (no-op stubs in public build)
if [[ -d "${SCRIPT_DIR}/lib/premium" ]]; then
    for _premium_mod in "${SCRIPT_DIR}/lib/premium/"*.sh; do
        # shellcheck disable=SC1090
        [[ -f "$_premium_mod" ]] && source "$_premium_mod"
    done
    unset _premium_mod
fi

# Total number of installation phases
readonly TOTAL_PHASES=11

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
main() {
    # Parse CLI arguments first (before anything else)
    config_parse_args "$@"

    # Initialize working directory
    PVE_WORKING_DIR="${PVE_WORKING_DIR:-/root}"
    cd "$PVE_WORKING_DIR"

    # Initialize logging
    log_init "${PVE_WORKING_DIR}/logs"
    log_start_timer
    PVE_INSTALL_START_TIME="$(date +%s)"

    # Register cleanup traps
    cleanup_register_trap

    # Load config file if specified
    config_load_defaults
    if [[ -n "$PVE_CONFIG_FILE" ]]; then
        config_load_file "$PVE_CONFIG_FILE"
    fi
    # Re-parse CLI args to override config file values
    config_parse_args "$@"

    # Resolve and activate the selected provider (Hetzner, OVH, ...)
    provider_resolve

    # Display banner
    clear
    ui_banner

    # ============================================================
    # Phase 1: Preflight Checks
    # ============================================================
    ui_phase 1 "$TOTAL_PHASES" "Preflight Checks"

    hw_check_root
    provider_check_rescue
    hw_check_kvm

    # ============================================================
    # Phase 2: Hardware Detection
    # ============================================================
    ui_phase 2 "$TOTAL_PHASES" "Hardware Detection"

    hw_detect_all

    # ============================================================
    # Phase 3: Disk Detection
    # ============================================================
    ui_phase 3 "$TOTAL_PHASES" "Disk Detection"

    disk_detect
    disk_select
    disk_select_raid
    disk_validate_raid

    # ============================================================
    # Phase 4: Network Detection
    # ============================================================
    ui_phase 4 "$TOTAL_PHASES" "Network Detection"

    if [[ "$PVE_UNATTENDED" != true ]] || [[ -z "$PVE_INTERFACE" ]]; then
        net_detect_all
    else
        net_extract_info "$PVE_INTERFACE"
        PVE_PREDICTED_IFACE="$(provider_predict_iface)"
        ui_success "Using interface: ${PVE_INTERFACE} (predicted: ${PVE_PREDICTED_IFACE})"
    fi
    provider_post_network_detect

    # ============================================================
    # Phase 5: Configuration
    # ============================================================
    ui_phase 5 "$TOTAL_PHASES" "Configuration"

    if [[ "$PVE_UNATTENDED" == true ]]; then
        config_derive_values
        ui_success "Using unattended configuration"
    else
        config_interactive
    fi

    # Premium feature gate runs HERE (not in Phase 1) so that all CLI
    # args, env defaults, config-file values and interactive auto-detected
    # SSH keys are populated before we check premium prerequisites. The
    # public stub also runs here so the upsell CTA reflects the final
    # state of --enable-luks after all sources have been merged.
    premium_announce_cta

    # ============================================================
    # Phase 6: Validation
    # ============================================================
    ui_phase 6 "$TOTAL_PHASES" "Validation"

    validate_all
    answer_show_summary

    if [[ "$PVE_SKIP_CONFIRM" != true ]] && [[ "$PVE_UNATTENDED" != true ]]; then
        echo ""
        if ! ui_confirm "Proceed with installation? This will ERASE all data on selected disks"; then
            die "Installation cancelled by user"
        fi
    fi

    # ============================================================
    # Phase 7: Dependencies
    # ============================================================
    ui_phase 7 "$TOTAL_PHASES" "Installing Dependencies"

    iso_install_dependencies

    # ============================================================
    # Phase 8: ISO Acquisition
    # ============================================================
    ui_phase 8 "$TOTAL_PHASES" "Acquiring Proxmox ISO"

    iso_download

    # ============================================================
    # Phase 9: Configuration Generation
    # ============================================================
    ui_phase 9 "$TOTAL_PHASES" "Generating Installation Config"

    local use_firstboot=false
    if firstboot_is_supported; then
        firstboot_generate
        use_firstboot=true
        ui_success "First-boot hook will be used (no SSH config needed)"
    else
        ui_warn "First-boot hooks not supported by this ISO version"
        ui_info "Will use SSH-based post-install configuration"
    fi

    answer_generate
    iso_prepare_autoinstall

    # ============================================================
    # Phase 10: Installation
    # ============================================================
    ui_phase 10 "$TOTAL_PHASES" "Installing Proxmox VE"

    qemu_run_install

    # Post-install configuration (if first-boot hook was not used)
    if [[ "$use_firstboot" != true ]]; then
        echo ""
        ui_info "Running SSH-based post-install configuration..."
        qemu_run_config
        sshcfg_configure
    fi

    # ============================================================
    # Phase 11: Report
    # ============================================================
    ui_phase 11 "$TOTAL_PHASES" "Installation Report"

    report_generate "SUCCESS"
    report_generate_json "SUCCESS"
    report_prompt_reboot
}

# Run main with all arguments
main "$@"
