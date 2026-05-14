# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Interactive LUKS unlock-mode picker.** When `--enable-luks` is used
  without `--luks-unlock-modes`, the LUKS pre-flight now prompts the
  operator with a 4-option menu (passphrase / passphrase+ssh /
  passphrase+ssh+tpm / passphrase+tpm). Default is `passphrase,ssh`
  when SSH keys are available, otherwise `passphrase`. Unattended
  installs without an explicit `--luks-unlock-modes` use the same safe
  default silently. Existing `--luks-unlock-modes` and config-file
  `PVE_LUKS_UNLOCK_MODES=...` continue to win unchanged. The menu hides
  `ssh`-bearing options when no SSH keys are configured (would have
  failed validation downstream anyway).

### Fixed

- **LUKS keyfile no longer carries a trailing newline.** The keyfile was
  written via a single-quoted heredoc, which always appends `\n` after
  the passphrase. cryptsetup `--key-file FILE` (without `--keyfile-size`)
  reads ALL bytes including that `\n` as the LUKS key, so the stored key
  was `passphrase\n` (66 bytes for a 65-char passphrase). At unlock time
  the user types `passphrase` and presses Enter -- the Enter is the
  input terminator, not part of the input -- so cryptsetup compared
  `passphrase\n` against `passphrase` and the keys never matched. This
  affected ALL passphrases, not just ones with special characters; users
  with simple test passphrases probably never noticed because typing an
  extra Enter or copy-pasting with a trailing space accidentally
  re-added the missing byte. Fix: `truncate -s -1 "$LUKS_KEYFILE"`
  immediately after the heredoc, plus a log line recording the byte
  length so operators can verify.
- **Bash history expansion disabled in the installer's own shell
  (`set +H`).** Otherwise `--luks-passphrase "h!3..."` with double
  quotes triggers `!3...` history substitution BEFORE the script's CLI
  parser sees the value, silently corrupting the captured passphrase.
  Single-quoting on the CLI is still recommended (and the new
  passphrase sanity check warns operators about `!` characters).
- **LUKS pre-flight passphrase sanity check.** Before locking the
  passphrase into the LUKS header (a 30-min one-way operation), the
  pre-flight now warns about leading/trailing whitespace, embedded
  newlines/tabs, length under 8 chars, and `!` characters (history-
  expansion gotcha). Each warning asks for re-confirmation rather
  than aborting -- determined operators can override. Also echoes the
  captured passphrase LENGTH (not content) so the operator can verify
  it matches what they expect to type at the unlock prompt.

- **First-boot waits for actual network reachability, not just a default
  route.** The previous wait loop checked only for the presence of a
  `default via` line in the routing table, which `ifreload -a` installs
  immediately even when the underlying NIC has no carrier. On OVH, the
  switch port can take 10-60s to authorise after the interface comes
  online; during that window every `apt-get` opens TCP connections that
  hang for ~70s before timing out. The new wait loop verifies that
  `vmbr0` is in `state UP` AND that a `ping -c 1 -W 2 <gateway>` succeeds
  before continuing. Times out at 120s with a clear WARN.
- **LUKS first-boot apt installs use the same retry-with-backoff pattern
  as `dnsmasq`.** `cryptsetup`, `dropbear-initramfs`, `tpm2-tools` were
  installed via plain `apt-get install ... || luks_die` -- one transient
  network blip at first boot killed the entire encryption path. Now
  retried 6 times with 15s backoff. `tpm2-tools` is also non-fatal (TPM
  is opportunistic; passphrase + ssh unlock keep working without it).
- **First-boot script no longer aborts on a `cp` self-copy in the SSH key
  sync step.** Proxmox makes `/root/.ssh/authorized_keys` a symlink to
  `/etc/pve/priv/authorized_keys` (cluster sync via pmxcfs). The previous
  `cp /root/.ssh/authorized_keys /etc/pve/priv/authorized_keys` then
  failed with `'X' and 'X' are the same file`, exit 1, killing the entire
  first-boot under `set -e`. The cp is now guarded by a `readlink -f`
  comparison: skip when both paths resolve to the same file. Symptom:
  premium LUKS post-install block (which is appended at the END of
  first-boot) silently never ran -- system rebooted unencrypted.
- **First-boot script no longer uses `set -e`.** First-boot is a
  best-effort post-install configurator; a transient failure in one
  optional step (apt mirror flake, pmxcfs symlink clash, kernel module
  already loaded, ...) was aborting the whole sequence and leaving the
  system half-configured. Switched to `set -uo pipefail` -- variable
  typos and silent pipeline errors are still caught, individual command
  failures are not. Critical operations (network apply, etc.) already
  use explicit `|| die` patterns.
- **Premium LUKS pre-flight no longer fails before SSH key auto-detection.**
  `premium_announce_cta` ran in Phase 1 (right after rescue/KVM checks)
  but `_config_detect_ssh_keys` only runs in Phase 5 (interactive
  config). Users running with `--enable-luks --luks-unlock-modes
  passphrase,ssh` (without an explicit `--ssh-keys` flag) hit
  "LUKS 'ssh' unlock mode requires PVE_SSH_KEYS to be set" even when
  their rescue session had keys available. The pre-flight is now called
  at the END of Phase 5, after CLI args + config file + interactive
  prompts have all populated `PVE_SSH_KEYS`.
- **First-boot script now applies the new network config before any apt
  call.** The Proxmox auto-installer captures the QEMU install-time DHCP
  lease (typically `10.0.2.15` from QEMU user-mode networking) as the
  installed system's `/etc/network/interfaces`. Our first-boot script
  rewrote that file with the real provider config but never reloaded the
  network. Subsequent `apt-get install dnsmasq` then died with
  `apt status 100` because `10.0.2.0/24` has no path to the internet on
  bare metal. Symptom: `[FAILED] proxmox-first-boot-multi-user.service`,
  unreachable server after first reboot. `lib/firstboot.sh` now calls
  `ifreload -a` (or `ifup -a` / `systemctl restart networking` as
  fallbacks) immediately after writing the file, then waits up to 60s
  for a default route before continuing.
- **Optional `dnsmasq` install no longer kills first-boot.** The
  vmbr1-DHCP setup runs `apt-get install dnsmasq`; before this fix the
  call was missing `|| true` and any transient failure aborted the
  entire first-boot under `set -euo pipefail`. The install is now
  retried 3x with backoff, and on permanent failure logs a clear WARN
  with manual recovery steps. The rest of first-boot continues so the
  system is reachable.
- **Disk filter ignores OVH/Hetzner rescue phantoms.** OVH rescue
  loads the `nbd` kernel module which registers 16 empty network
  block devices (`nbd0`-`nbd15`) that previously appeared as `disk`
  to `lsblk` and were auto-selected for the install pool. Real
  installs would either fail outright or stripe across phantoms.
  `lib/disk.sh` now skips `nbd*`, `ram*`, `md*`, `dm-*`, `zd*`,
  `zram*`, `nullb*` and any device under 4 GiB. Covered by
  [`tests/test-disk-filter.sh`](../tests/test-disk-filter.sh).
- **Interactive prompts are visible again.** `ui_read` was calling
  `read -p "..." 2>/dev/null` -- and `read -p` writes the prompt to
  **stderr**, so the redirect was silently eating it. Users would
  see "Provider Selection" and a list of options, then a blinking
  cursor with no prompt. Stderr is no longer suppressed; errors are
  handled by the existing `|| _result="$default"` fallback.
- **Numeric menus no longer concatenate the default with input.**
  `ui_read` previously used `read -e -i "$_default"` which pre-fills
  the input buffer. For numeric menus (provider, RAID level, disk
  pick), users typing a different choice ended up with the default
  + their input merged ("1" + "2" = "12") and the script died with
  "invalid selection". The default is now displayed in `[brackets]`
  in the prompt; `-e` is kept for readline editing on free-form
  fields.
- **Box-drawing characters render correctly on rescue terminals.**
  `ui_hr` and three other UI helpers used `tr ' ' "$char"` to repeat
  multi-byte UTF-8 box chars. `tr` is byte-oriented and substituted
  one byte per space, producing invalid UTF-8 that terminals
  rendered as `��������`. Replaced with bash string concat via a
  new `_ui_repeat` helper.
- **Workspace auto-relocation on small rescue tmpfs.** OVH rescue
  puts `/root` on the kernel's in-memory `rootfs` which `df` reports
  as `0 0 0`. `proxmox-auto-install-assistant`'s xorriso step then
  fails with `Image size 320s exceeds free space on media 0s` after
  copying the 1.7 GB ISO. New `iso_ensure_workspace_capacity` (in
  [`lib/iso.sh`](../lib/iso.sh), runs at the start of phase 7)
  detects this case, mounts a sized tmpfs at
  `/mnt/pve-dedicated-work` (8-16 GiB based on host RAM), migrates
  any pre-downloaded ISO, and re-points `PVE_WORKING_DIR`.
  Customers never see the error. Covered by
  [`tests/test-workspace-capacity.sh`](../tests/test-workspace-capacity.sh).

### Added

- `scripts/build_bundle.sh` -- builds the release tarball locally
  with the same logic the GitHub Actions release workflow uses,
  for SCP-and-test flows that don't need CI.
- `scripts/upload_premium_to_r2.sh` -- now supports R2 jurisdictions
  (`R2_JURISDICTION=default|eu|fedramp`) and an `R2_ENDPOINT_URL`
  full override. EU buckets are silently invisible from the default
  endpoint with a misleading 403, this surfaces it explicitly.

## [3.0.0] - 2026-05-01

### Project rename

- **Renamed `pve-hetzner` to `pve-dedicated`** -- the project now installs
  Proxmox VE on multiple bare-metal providers, not just Hetzner.
- Repository moved to `corelix-io/pve-dedicated` (premium / private) with a
  public mirror at `corelix-io/pve-dedicated-open`.
- Orchestrator entry point renamed from `pve-install.sh` to
  `pve-dedicated.sh`. The `install.sh` bootstrap and one-liner URLs were
  updated accordingly.
- **Clean break, no legacy aliases.** Old script names, old repo URL, and
  the implicit "Hetzner" assumption are all removed. Existing automation
  must be updated -- see
  [docs/migration/renaming-to-pve-dedicated.md](migration/renaming-to-pve-dedicated.md).
- Banner / help text / report header updated to "Proxmox VE Installer for
  Dedicated Servers (Hetzner, OVH)".

### Added

- **Multi-provider abstraction** in `lib/providers/`:
  - `lib/providers/common.sh` -- registry, dispatch table, auto-detection,
    interactive provider selection, premium feature gate stubs.
  - `lib/providers/hetzner.sh` -- preserves existing Hetzner behavior
    (rescue detection, `predict-check`-based interface prediction, NAT
    rendering with `pointopoint`, IPv6 over `fe80::1`).
  - `lib/providers/ovh.sh` -- new OVH support: rescue detection
    (`/etc/ovhrescue`, motd, hostname), udev-based interface prediction,
    classic vs Scale/HG/Advance gateway models, OVH-form IPv6 gateway
    derivation (`<prefix>:FF:FF:FF:FF:FF`), additional IPs in routed
    mode, and vRack as a second bridge (`vmbr2`).
- New CLI flag: `--provider hetzner|ovh` (mandatory in unattended mode;
  auto-detected interactively).
- New OVH-specific CLI flags (and matching `PVE_OVH_*` config keys):
  - `--ovh-gateway-model` (`auto` | `classic` | `scale`).
  - `--ovh-vrack-interface` -- second NIC for the `vmbr2` vRack bridge.
  - `--ovh-vrack-ip` -- static IP/CIDR on `vmbr2`.
  - `--ovh-additional-ips` -- comma/space-separated `/32`s routed on
    `vmbr0` in routed mode.
- New provider hook contract (each provider implements):
  - `<p>_check_rescue` -- detect provider's rescue/recovery environment.
  - `<p>_default_dns` -- provider DNS defaults (Hetzner: `185.12.64.*`;
    OVH: `213.186.33.99 1.1.1.1`).
  - `<p>_predict_iface` -- post-install interface name.
  - `<p>_render_interfaces` -- write `/etc/network/interfaces`.
  - `<p>_post_network_detect` *(optional)* -- refine derived facts
    (e.g. classify OVH gateway model).
  - `<p>_post_install_notes` *(optional)* -- provider-specific lines
    appended to the installation report.
- **Premium feature gate** (`premium_announce_cta`) called in Phase 1.
  In the public build this announces the LUKS premium with the upgrade
  URL and continues the install; in the premium build,
  `lib/premium/luks_*.sh` overrides the stub and runs the real LUKS
  pre-flight.
- Premium CLI flags (no-op in public build, fully implemented in premium):
  - `--enable-luks`
  - `--luks-passphrase`
  - `--luks-unlock-modes` (csv: `passphrase,ssh,tpm`)
  - `--luks-dropbear-port`
  - `--luks-wan-mac`
- New documentation structure:
  - `docs/providers/hetzner.md`, `docs/providers/ovh.md`.
  - `docs/migration/renaming-to-pve-dedicated.md`.
  - `docs/premium/luks.md` *(premium build only; stripped from the
    public mirror by the release pipeline)*.
- `.claude/docs/ARCHITECTURE.md` rewritten for the new module layout
  (`lib/providers/`, `lib/premium/`), updated phases, hook contracts,
  premium gate.
- `.claude/docs/TROUBLESHOOTING.md` is now provider-aware: rescue path,
  reboot toggle and post-install reachability are split per provider
  where the steps differ; generic sections are shared.

### Changed

- **README** is provider-first. OVH is presented as a first-class
  provider, not a footnote. Compatible-server matrix covers Hetzner
  AX/EX/SX *and* OVH Eco/Rise/Advance/Scale/HG/SoYouStart/Kimsufi.
- **`pve-dedicated.sh` orchestrator** sources `lib/providers/common.sh`,
  `lib/providers/hetzner.sh`, `lib/providers/ovh.sh`, and any
  `lib/premium/*.sh` if present.
- **`provider_resolve`** runs after CLI parsing and before any
  rescue-specific logic; it auto-detects, validates, applies provider
  DNS defaults (only when the user did not override), and prompts
  interactively when needed.
- **Phase 1 (Preflight)** now calls `provider_check_rescue` instead of
  the hardcoded Hetzner rescue check.
- **Phase 4 (Network Detection)** now calls
  `provider_post_network_detect` after `net_detect_all` so providers
  can refine derived facts (OVH classifies the gateway model here).
- **Phase 9 (firstboot generation)** delegates
  `/etc/network/interfaces` rendering to
  `provider_render_interfaces`.
- **Installation report** appends `provider_post_install_notes` so
  each provider shows the right post-install actions (Hetzner Robot
  reset; OVH netboot toggle and Virtual MAC reminders).
- ASCII banner simplified -- the "PVE HET" wordmark was removed in
  favor of the cleaner "pve-dedicated" branding.

### Removed

- `.claude/docs/HETZNER-NETWORKING.md` -- content moved and expanded in
  [docs/providers/hetzner.md](providers/hetzner.md).
- Hardcoded Hetzner rescue detection and Hetzner-only DNS defaults from
  the orchestrator (now provider-dispatched).

### Migration

See [docs/migration/renaming-to-pve-dedicated.md](migration/renaming-to-pve-dedicated.md)
for the full mapping. TL;DR:

- Replace the one-liner URL host segment from
  `corelix-io/pve-hetzner` to `corelix-io/pve-dedicated`.
- Add `--provider hetzner` (or `ovh`) to every invocation, or set
  `PVE_PROVIDER=hetzner` in your `.env`.
- v2.x `.env` files are forward-compatible once `PVE_PROVIDER` is set.

## [2.0.0] - 2026-04-15

### Added
- Complete rewrite with modular architecture (`lib/*.sh` modules).
- Dynamic hardware detection: CPU, RAM, disks, network interfaces, boot mode.
- Interactive RAID level selection with usable capacity and redundancy info.
- QEMU serial console output for real-time installation progress monitoring.
- QEMU monitor socket for programmatic VM control and clean shutdown.
- First-boot hook support (PVE 8.3+) eliminating the need for SSH-based config.
- CLI argument parsing with 30+ options for fully unattended deployments.
- Configuration file support (`.env` format) with example configs.
- Input validation for all user-provided values.
- ISO checksum verification (SHA256).
- Comprehensive installation report (terminal + JSON).
- Structured logging with levels (DEBUG, INFO, WARN, ERROR, FATAL).
- Branded terminal UI with progress bars, spinners, and phase tracking.
- Trap-based cleanup for QEMU processes and temporary files.
- Support for SATA, NVMe, and mixed disk configurations.
- Automatic QEMU resource allocation based on host hardware.
- `predict-check` integration for correct post-install interface naming.
- GitHub Actions workflow for building self-contained release bundles.
- One-liner bootstrap installer (`install.sh`).
- IPv4-only networking to avoid Hetzner rescue IPv6 timeout issues.
- SSH key auto-detection from rescue system authorized_keys.
- SSH hardening via first-boot: key-only auth, `PermitRootLogin prohibit-password`.
- DHCP server (dnsmasq) on NAT bridge (vmbr1) for automatic VM connectivity.
- `--dhcp` / `--no-dhcp` CLI flags and `PVE_ENABLE_DHCP` config option.
- `--ssh-keys` CLI flag and interactive SSH key prompt.
- `--keyboard`, `--country`, `--dns`, `--debian-suite` CLI options.
- `--zfs-ashift`, `--zfs-arc-max` for ZFS tuning via CLI.
- `--quiet`, `--version`, `-v`, `-y` CLI convenience flags.
- Performance tuning in first-boot:
  - TCP BBR congestion control.
  - TCP Fast Open.
  - Swappiness reduced to 10.
  - Kernel panic auto-reboot (10s).
  - inotify watches increased to 1M.
  - Journald size limited to 64M.
  - ZFS ARC dynamically tuned based on host RAM.
  - nf_conntrack tuned for NAT (1M max, 8h timeout).
  - pigz for faster vzdump backup compression.
  - vzdump bandwidth limit removed.
- Subscription nag removal with daily cron to persist across apt upgrades.
- Security advisory in install report (Hetzner firewall guidance).
- Ceph no-subscription repo alongside PVE no-subscription repo.
- Content-based enterprise repo detection (catches `ceph.sources` and future files).
- Branding: "Provided freely by Corelix.io - Made in France".
- Complete project documentation and `.claude` agent instructions.

### Changed
- Moved from single-script to modular library architecture.
- Disk paths are now auto-detected instead of hardcoded to `/dev/nvme0n1`.
- QEMU is no longer a black box (serial + monitor output).
- Templates are now shipped in-repo instead of fetched from GitHub at runtime.
- answer.toml uses kebab-case keys (PVE 8.4+ compatible).
- Network configuration uses `predict-check` for correct interface names.
- License changed from MIT to BSD 3-Clause with branding protection.
- All curl/wget calls use `-4` flag to force IPv4.
- apt configured with `Acquire::ForceIPv4 "true"` during installation.
- All `read` calls use safe `ui_read` wrapper (handles `set -e` and pipe stdin).
- All `(( var++ ))` replaced with `var=$(( var + 1 ))` to avoid `set -e` traps.
- Enterprise repo disabling handles both `.list` and `.sources` (DEB822) formats.

### Removed
- Legacy `sshpass -p` password exposure (uses `SSHPASS` env var or SSH keys).
- Hardcoded disk paths and QEMU resource values.
- Runtime template downloads from GitHub.
- Multiple redundant README files (v0, v1, v2).
- Old repo references (`ariadata/proxmox-hetzner`).

### Fixed
- Missing `qemu-system-x86_64` and `nc` in dependency installation.
- No cleanup of QEMU processes on script failure.
- Password visible in process list via `sshpass -p`.
- `set -e` without `pipefail` allowing silent pipeline failures.
- Version skew between bookworm (rescue) and trixie (install) repos.
- IPv6 timeout delays in Hetzner rescue mode for all network operations.
- `read -e` hanging when stdin is a pipe (`curl | bash`).
- `(( 0++ ))` returning exit code 1 under `set -e`.
- `[[ ]] &&` as last function statement causing silent exit under `set -e`.
- QEMU global variables lost in `$()` subshell.
- `bc` not available in Hetzner rescue (pure bash arithmetic).
- Hetzner rescue detection (multiple methods: installimage, motd, resolv.conf, hostname).
- `ceph.sources` enterprise repo not disabled (DEB822 format with non-obvious filename).
- Subscription nag returning after apt upgrades (daily cron fix).

## [1.0.0] - 2025-01-01

### Added
- Initial release with single-script automated Proxmox VE installation.
- Support for Hetzner AX/EX/SX server series.
- ZFS RAID-1 installation via QEMU in rescue mode.
- Basic network configuration templates.
