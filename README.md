<!--
  This file is prepended to README.md by .github/workflows/sync-public.yml
  when the public mirror is regenerated. Edit it in the source repo only.
-->

# pve-dedicated (public mirror)

> **Repository status**
>
> This is the **PUBLIC mirror** of `corelix-io/pve-dedicated`. It is auto-generated
> from the source repository on every push to `main` and on every release tag.
> **Pull requests should be opened against the source repository, not this mirror.**
> Issues are accepted on either repository.
>
> Source of truth: <https://github.com/corelix-io/pve-dedicated> (private).

---

## Premium: host-level LUKS encryption

The public installer ships the full Hetzner and OVH provisioning pipeline, but
**host-level full-disk encryption is a premium feature** delivered as a signed
binary tarball to paying clients.

Premium adds:

- LUKS2 root encryption with a passphrase the operator controls
- `dropbear-initramfs` SSH unlock for remote reboot recovery
- TPM2-bound auto-unlock for trusted hardware (sealed against PCR state)
- Recovery tooling and a documented disaster-recovery runbook

Get premium access: <https://corelix.io/pve-dedicated-premium>

### FAQ

**Why isn't this in the public repo?**

Premium underwrites the maintenance of the free public installer. Host-level
encryption keying material, dropbear-initramfs hardening, and the TPM2 sealing
flow are sensitive enough that they ship as a signed artifact rather than
plaintext source. Shipping them out-of-band also lets us push security fixes
on a cadence independent from the public release schedule.

**How do clients receive it?**

After purchase, clients are added to the private source repository's release
feed and receive a signed tarball through private GitHub Releases. The premium
tarball unpacks an additional set of premium modules, templates, and a sample
LUKS configuration alongside the existing public install tree. No fork is
required and the public installer keeps working as-is.

**Can I get a trial?**

Yes. Request a time-limited evaluation key at the link above. Trials include
the full premium pipeline and can be exercised against a staging server before
purchase.

---

# pve-dedicated -- Proxmox VE Installer for Dedicated Servers

<div align="center">

**One Proxmox VE installer for Hetzner AND OVH dedicated servers.**

*Provided freely by [Corelix.io](https://corelix.io) - Made in France*

*Author: Amir Moradi*

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](LICENSE)
![Shell](https://img.shields.io/badge/Shell-Bash%205%2B-green)
![Proxmox](https://img.shields.io/badge/Proxmox-8.2%2B-orange)
![Providers](https://img.shields.io/badge/Providers-Hetzner%20%7C%20OVH-blueviolet)

</div>

> **Heads up: `pve-hetzner` was renamed to `pve-dedicated` in 3.0.**
> The repo, the script entry point and the one-liner URL all changed. There are
> **no legacy aliases** -- your existing automation must update both the URL
> and the new mandatory `--provider` flag (or set `PVE_PROVIDER` in your
> config). See the dedicated migration guide:
> [docs/migration/renaming-to-pve-dedicated.md](docs/migration/renaming-to-pve-dedicated.md).

## Overview

`pve-dedicated` is an enterprise-grade automation tool for installing
**Proxmox VE** on **Hetzner** and **OVH** dedicated servers, directly from the
provider's rescue/recovery environment -- no KVM console, no IPMI, no manual
ISO juggling. It boots the official Proxmox auto-install ISO inside QEMU on the
rescue host, writes to your server's physical disks, and configures networking
the way each provider expects it.

OVH is a first-class provider in this release: NAT, routed (additional IPs)
and bridged modes are all supported, plus vRack as an optional second bridge.

### Key Features

- **Provider abstraction** -- a single codebase with per-provider modules in
  `lib/providers/` and a stable hook contract (rescue detection, DNS defaults,
  interface prediction, `/etc/network/interfaces` rendering, post-install
  notes).
- **One-liner install** with mandatory `--provider hetzner|ovh` selection
  (auto-detected when possible).
- **Hetzner**: NAT/routed/bridged, IP/MAC binding aware, `predict-check`
  integration, Robot firewall guidance, optional vSwitch VLAN (with routes
  to a coupled Cloud Network).
- **OVH**: classic /24-style and Scale/HG/Advance `/32` + `100.64.0.1`
  gateway models, IPv6 gateway taken from the rescue system (or
  `--ovh-ipv6-gateway`, or the derived `<prefix>FF:FF:FF:FF:FF` form),
  additional IPs (with vMAC reminders) and vRack on a second bridge (`vmbr2`).
- **NIC rename proof** -- first boot finds the WAN NIC by MAC on the real
  hardware and pins its name with a systemd `.link` file.
- **IPv4-only networking** during install (rescue images of both providers
  have unreliable IPv6).
- **Dynamic hardware detection** -- auto-discovers disks, network interfaces,
  CPU, RAM, and boot mode (UEFI / legacy BIOS).
- **Interactive RAID selection** with usable capacity and redundancy
  per RAID level.
- **Full QEMU observability** -- serial console output and monitor socket;
  installer phases tracked in real time.
- **SSH hardening** -- auto-detects keys from rescue, disables password login
  (cluster-safe `PermitRootLogin prohibit-password`).
- **DHCP on NAT bridge** -- VMs get automatic connectivity via dnsmasq on
  `vmbr1` (`.100-.200`).
- **First-boot hooks** -- all configuration applied on first boot (PVE 8.3+).
- **Unattended mode** -- configure via CLI arguments or `.env` files.
- **Verified downloads** -- ISO checked against Proxmox's `SHA256SUMS`
  (fails closed), release bundle checked against the release `SHA256SUMS`,
  rescue APT key checked against its published checksum.
- **Safe disk handover** -- stops mdadm/LVM/swap on the target disks and
  wipes old signatures before QEMU touches them.
- **Performance tuning** -- TCP BBR, swappiness, journald limits, pigz
  backups, ZFS ARC.
- **Enterprise logging** -- structured log levels, JSON reports.
- **Self-contained bundle** -- no runtime downloads of templates or scripts.
- **Tested** -- ShellCheck-clean, unit tests for parsing, validation,
  address math, network rendering and generated scripts; CI on every push.

> **Premium**: Host-level **LUKS full-disk encryption**
> (passphrase + remote SSH unlock via dropbear-initramfs + automatic unlock
> with TPM2 and/or a Tang server)
> is a separately licensed module. See the
> [Premium](#premium-features) section below.

### Compatible Servers

`pve-dedicated` is provider-aware, not model-specific. The matrix below
shows the ranges that have been validated end-to-end. Other models in the
same range generally work; please open an issue if a specific model needs
attention.

| Provider | Range | Examples | Tested | Notes |
|----------|-------|----------|--------|-------|
| Hetzner | [AX](https://www.hetzner.com/dedicated-rootserver/matrix-ax) | AX-52, AX-102, AX-162 | Yes | NVMe; UEFI by default |
| Hetzner | [EX](https://www.hetzner.com/dedicated-rootserver/matrix-ex) | EX-44, EX-101 | Yes | Mixed NVMe/SSD |
| Hetzner | [SX](https://www.hetzner.com/dedicated-rootserver/matrix-sx) | SX-64, SX-134 | Yes | Storage-heavy SATA |
| OVH | [Eco / Kimsufi / SoYouStart](https://eco.ovhcloud.com/) | KS-A, KS-LE, SYS series | Yes | Classic /24-style gateway, NAT mode default |
| OVH | [Rise](https://www.ovhcloud.com/en/bare-metal/rise/) | RISE-1, RISE-2, RISE-3 | Yes | Classic /24-style gateway |
| OVH | [Advance](https://www.ovhcloud.com/en/bare-metal/advance/) | ADV-1, ADV-2, ADV-3 | Yes | `/32` + `100.64.0.1` gateway -- pass `--ovh-gateway-model scale` |
| OVH | [Scale](https://www.ovhcloud.com/en/bare-metal/scale/) | SCALE-GPU, SCALE-* | Yes | `/32` + `100.64.0.1` gateway, vRack-ready |
| OVH | [High Grade](https://www.ovhcloud.com/en/bare-metal/high-grade/) | HGR-HCI, HGR-STOR | Yes | `/32` + `100.64.0.1` gateway, vRack-ready |

For provider specifics, see:

- [docs/providers/hetzner.md](docs/providers/hetzner.md)
- [docs/providers/ovh.md](docs/providers/ovh.md)

## Quick Start

### 1. Boot into Rescue Mode

| Provider | Steps |
|----------|-------|
| Hetzner | [Robot Panel](https://robot.hetzner.com) > Server > **Rescue** > Linux 64-bit > **Activate** > **Reset** > "Execute an automatic hardware reset" |
| OVH | [OVHcloud Manager](https://www.ovh.com/manager/) > Bare Metal Cloud > Server > **Netboot** > **Rescue** > save > Server > **Restart** |

After ~2 minutes, SSH in as `root` to the address shown in the rescue
notification email (OVH) or shown in the Robot panel (Hetzner).

### 2. Run the Installer

**One-liner (recommended)** -- the bootstrap script downloads the latest
release bundle and runs `pve-dedicated.sh`:

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated-open/releases/latest/download/install.sh \
    | bash -s -- --provider hetzner
```

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated-open/releases/latest/download/install.sh \
    | bash -s -- --provider ovh
```

**One-liner, fully unattended (Hetzner)**:

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated-open/releases/latest/download/install.sh \
    | bash -s -- \
        --provider hetzner \
        --fqdn pve1.example.com --password 'YourSecurePassword' \
        --timezone UTC --email admin@example.com \
        --ssh-keys "$(cat ~/.ssh/authorized_keys)" \
        --unattended --yes
```

**One-liner, fully unattended (OVH Scale / High Grade / Advance)**:

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated-open/releases/latest/download/install.sh \
    | bash -s -- \
        --provider ovh --ovh-gateway-model scale \
        --fqdn pve1.example.com --password 'YourSecurePassword' \
        --timezone UTC --email admin@example.com \
        --unattended --yes
```

**Manual download** (pin a release with `PVE_DEDICATED_VERSION=v3.1.1`):

```bash
curl -4fsSLO https://github.com/corelix-io/pve-dedicated-open/releases/latest/download/install.sh
bash install.sh --provider hetzner
```

The bootstrap verifies the bundle against the release's `SHA256SUMS` before
running it. Premium customers use the license one-liner instead (see
[Premium](#premium-features)).

### 3. Switch Boot Source and Reboot

| Provider | What to do |
|----------|------------|
| Hetzner | Robot Panel > Server > **Reset** > "Execute an automatic hardware reset". A plain `reboot` from the rescue shell may loop back into rescue. |
| OVH | OVHcloud Manager > Server > **Netboot** > **Boot from the hard disk** > save, then reboot the server. The default after rescue is to keep booting rescue. |

### 4. Access Proxmox

After reboot:

- **Web UI**: `https://YOUR-SERVER-IP:8006`
- **SSH**: `ssh root@YOUR-SERVER-IP`
- **Login**: `root` with the password you set during installation

## Architecture

`pve-dedicated` is a thin orchestrator on top of provider-specific modules
that implement a common contract. The orchestrator is generic; everything
provider-aware lives in `lib/providers/<name>.sh`.

```mermaid
flowchart TB
    User["User / CI"] --> Bootstrap["install.sh<br/>(downloads release bundle)"]
    Bootstrap --> Orchestrator["pve-dedicated.sh<br/>(11 phases)"]

    Orchestrator --> Core["lib/<br/>logging, ui, config,<br/>validate, hardware,<br/>disk, network, iso,<br/>answer, firstboot,<br/>qemu, report"]

    Orchestrator --> ProvCommon["lib/providers/common.sh<br/>(dispatch table)"]
    ProvCommon --> Hetzner["lib/providers/hetzner.sh"]
    ProvCommon --> OVH["lib/providers/ovh.sh"]

    Orchestrator -. "premium build only" .-> Premium["lib/premium/<br/>luks_*.sh"]

    Core --> QEMU["QEMU + Proxmox<br/>auto-install ISO"]
    QEMU --> Disks["Physical disks<br/>(ZFS / ext4 / xfs / btrfs)"]
```

### Repository Layout

```
pve-dedicated.sh                 Orchestrator entry point (11 phases)
install.sh                       Bootstrap one-liner (downloads release bundle)
lib/
├── logging.sh                   Structured logging with levels
├── ui.sh                        Colors, spinners, progress bars, ui_read
├── config.sh                    CLI parsing, .env loading, defaults
├── validate.sh                  Input validation
├── cleanup.sh                   Trap handlers, process cleanup
├── hardware.sh                  CPU, RAM, boot mode detection
├── disk.sh                      Disk discovery, RAID selection, validation
├── network.sh                   Interface detection, IP / MAC extraction
├── iso.sh                       ISO download and verification
├── answer.sh                    answer.toml generation
├── firstboot.sh                 First-boot script generation
├── qemu.sh                      QEMU with serial console + monitor
├── ssh-config.sh                Legacy SSH-based config (fallback)
├── report.sh                    Installation report generation
├── providers/
│   ├── common.sh                Provider dispatch and registry
│   ├── hetzner.sh               Hetzner provider hooks
│   └── ovh.sh                   OVH provider hooks
└── premium/                     PREMIUM ONLY (private repo)
    └── luks_*.sh                LUKS host encryption module
templates/premium/               Premium-only templates (private repo)
configs/                         Example .env configuration files
tests/                           Unit tests (bash tests/run-all.sh)
docs/                            User-facing documentation
workers/license-redirect/        Premium license Worker (private repo)
.github/workflows/               CI, release bundle, public-mirror strip
```

### Installation Phases

| Phase | Description | Module |
|-------|-------------|--------|
| 1 | Preflight (root, provider rescue, KVM, premium gate) | `hardware.sh`, `providers/*` |
| 2 | Hardware detection (CPU, RAM, boot mode) | `hardware.sh` |
| 3 | Disk detection, selection, RAID level choice | `disk.sh` |
| 4 | Network interface detection (provider hook may refine) | `network.sh`, `providers/*` |
| 5 | Configuration (interactive or unattended) | `config.sh` |
| 6 | Input validation, summary, confirmation | `validate.sh`, `answer.sh` |
| 7 | Dependency installation (checksum-pinned Proxmox repo key) | `iso.sh` |
| 8 | ISO download (resumable) with SHA-256 verification | `iso.sh` |
| 9 | Generate `answer.toml` + first-boot script (provider-rendered `/etc/network/interfaces`) | `answer.sh`, `firstboot.sh`, `providers/*` |
| 10 | Release disks (md/LVM/swap, wipefs), QEMU installation with progress monitoring | `disk.sh`, `qemu.sh` |
| 11 | Installation report and reboot prompt | `report.sh` |

For the full architectural reference -- module dependency graph, provider
hook contracts, premium gate -- see [.claude/docs/ARCHITECTURE.md](.claude/docs/ARCHITECTURE.md).

## Configuration Reference

### CLI Options

Every option that takes a value also accepts `--option=value`.

```
PROVIDER:
  --provider NAME         Provider: hetzner | ovh (auto-detected if omitted)

SYSTEM:
  --hostname NAME         Short hostname (default: first label of --fqdn)
  --fqdn FQDN             Fully qualified domain name (must start with hostname)
  --password PASS         Root password, min. 8 chars (stored hashed)
  --email EMAIL           Admin notification email
  --timezone TZ           Timezone (e.g., UTC, Europe/Berlin)
  --keyboard LAYOUT       Keyboard layout (default: en-us)
  --country CODE          Two-letter country code (default: us)
  --ssh-keys "KEYS"       SSH public keys, newline- or space-separated
                          (enables key-only SSH)

DISK:
  --disk-mode MODE        auto or manual (default: auto; USB disks skipped)
  --disks LIST            Comma-separated disk names (e.g., nvme0n1,nvme1n1)
  --filesystem FS         zfs, ext4, xfs, btrfs (default: zfs)
  --zfs-raid LEVEL        raid0, raid1, raid10, raidz-1/2/3 (default: raid1)
  --zfs-compress ALG      on, off, lz4, zstd, gzip, lzjb, zle (default: lz4)
  --zfs-ashift N          ZFS ashift value (9-16)
  --zfs-arc-max MiB       ZFS ARC max memory in MiB

NETWORK:
  --interface NAME        Network interface override (rescue-side name)
  --network-mode MODE     nat, routed, bridged (default: nat)
  --private-subnet CIDR   NAT subnet for vmbr1 (e.g., 192.168.26.0/24)
  --dhcp                  Enable DHCP server on NAT bridge (default)
  --no-dhcp               Disable DHCP server on NAT bridge
  --additional-ips L      Routed mode: comma/space-separated IPs routed onto vmbr0
  --dns SERVERS           DNS servers (space-separated; default: provider DNS)

HETZNER vSWITCH:
  --vswitch-vlan ID       vSwitch VLAN ID from Robot (4000-4091)
  --vswitch-ip CIDR       This server's vSwitch address (e.g. 10.0.1.3/24)
  --vswitch-routes L      CIDRs reached via the vSwitch gateway (e.g. the
                          Cloud Network 10.0.0.0/16)
  --vswitch-gateway IP    Gateway for the routes (default: first host)
  --vswitch-mtu N         MTU (default: 1400)
  --vswitch-bridge        Also create vmbr<VLAN> for guests

OVH-SPECIFIC:
  --ovh-gateway-model M   auto | classic | scale
                          Use 'scale' for High Grade / Scale / Advance
                          (/32 host IP with on-link 100.64.0.1 gateway)
  --ovh-vrack-interface I Second NIC name for vRack bridge (vmbr2)
  --ovh-vrack-ip CIDR     Static IP/CIDR on vRack bridge (vmbr2)
  --ovh-ipv6-gateway GW   IPv6 gateway shown in the OVH Control Panel
                          (default: detected in rescue, else derived)
  --ovh-additional-ips L  Alias of --additional-ips

PREMIUM (LUKS host encryption -- requires premium build):
  --enable-luks           Request host-level LUKS full-disk encryption
  --luks-passphrase P     Passphrase (or read interactively)
  --luks-unlock-modes L   Comma-separated: passphrase,ssh,tpm
                          (default: passphrase)
  --luks-dropbear-port N  Pre-boot SSH port for cryptroot-unlock
                          (default: 2222)
  --luks-wan-mac MAC      Pin pre-boot NIC by MAC (resilient across rename)

INSTALL:
  --iso PATH              Skip download, use local ISO
  --pve-version V         Pin the downloaded ISO: 9, 9.2 or 9.2-1 (default: latest)
  --no-iso-verify         Skip SHA-256 verification of the downloaded ISO
  --boot-mode MODE        auto, uefi, legacy (default: auto)
  --debian-suite SUITE    APT suite of the installed system
                          (default: derived from the ISO, 9.x -> trixie)
  --working-dir DIR       ISO, logs and generated files (default: /root)
  --config FILE           Load .env configuration file
  --unattended            No interactive prompts
  --yes, -y               Skip confirmation prompts
  --debug                 Enable debug logging
  --quiet                 Suppress info-level output
  --help, -h              Show help
  --version, -v           Show version

ENVIRONMENT:
  NO_COLOR=1                    Disable colored output
  PVE_QEMU_INSTALL_TIMEOUT=SEC  Installer timeout (default: 2400)
```

The OVH-specific flags are documented in detail in
[docs/providers/ovh.md](docs/providers/ovh.md). The premium LUKS flags are
documented in [docs/premium/luks.md](docs/premium/luks.md) (premium-only).

### Configuration File

Create a `.env` file (see `configs/` for examples). The file is parsed, never
executed: `KEY=value`, `KEY="value"` (may span lines; `\"`, `\\` and `\$`
escapes), `KEY='value'` and an optional `export` prefix are supported, as are
`# comments` after a value. Unknown keys produce a warning.

```bash
# Provider selection (mandatory in unattended mode)
PVE_PROVIDER="hetzner"   # or "ovh"

# System
PVE_HOSTNAME="pve1"
PVE_FQDN="pve1.example.com"        # must start with PVE_HOSTNAME
PVE_ROOT_PASSWORD="secure-password"   # min. 8 characters
PVE_TIMEZONE="UTC"
PVE_EMAIL="admin@example.com"
PVE_KEYBOARD="en-us"
PVE_COUNTRY="us"
PVE_SSH_KEYS="ssh-ed25519 AAAA... user@host
ssh-ed25519 AAAA... other@host"

# Disk
PVE_FILESYSTEM="zfs"
PVE_ZFS_RAID="raid1"
PVE_ZFS_COMPRESS="lz4"

# Network
PVE_PRIVATE_SUBNET="192.168.26.0/24"
PVE_NETWORK_MODE="nat"
PVE_ENABLE_DHCP=true
PVE_DNS_SERVERS="1.1.1.1 9.9.9.9"     # omit for the provider default
PVE_ADDITIONAL_IPS=""                  # routed mode, e.g. "203.0.113.10,203.0.113.11"

# ISO
PVE_ISO_VERSION=""                     # pin, e.g. "9.2"; empty = latest

# OVH-only (ignored on Hetzner)
PVE_OVH_GATEWAY_MODEL="auto"           # auto | classic | scale
PVE_OVH_VRACK_INTERFACE=""             # e.g. eno2
PVE_OVH_VRACK_IP_CIDR=""               # e.g. 10.42.0.10/24
PVE_OVH_IPV6_GATEWAY=""                # from the Control Panel, if needed
```

### Precedence

Configuration values are merged in this order (last wins):

1. Built-in defaults (`configs/default.env`)
2. Config file (`--config`)
3. CLI arguments (re-applied after the config file is loaded)
4. Interactive prompts (only when not in `--unattended`) for hostname,
   FQDN, timezone, email and NAT subnet -- *unless* you set them in steps
   2-3; values from `configs/default.env` are only offered as defaults.

Provider DNS servers are used when `PVE_DNS_SERVERS` is left empty. The
hostname is derived from `--fqdn` (or the FQDN from `--hostname`); setting
both to disagreeing values is a validation error. The installed system's
APT suite follows the ISO (Proxmox VE 9.x -> Debian trixie) unless
`--debian-suite` is given.

## What Gets Configured

The first-boot script applies these configurations automatically. The
**network rendering is provider-specific** -- the same generic phases
produce a Hetzner-correct or OVH-correct `/etc/network/interfaces`
depending on `PVE_PROVIDER`.

### Networking

- **nat** (default): `vmbr0` bridges the physical NIC and owns the main
  IPv4/IPv6; `vmbr1` is a private NAT bridge with `MASQUERADE`, and
  `dnsmasq` hands out `.100-.200` on it (DHCP only -- `port=0`, it never
  answers DNS).
- **routed**: the NIC owns the main IP as `/32` with an on-link gateway;
  `vmbr0` has no ports and routes `--additional-ips` to VMs (no virtual
  MACs needed).
- **bridged**: as nat without `vmbr1`; VMs on `vmbr0` need a virtual MAC
  from the provider for each additional IP.
- Gateways outside the address prefix (Hetzner, OVH Scale/HG/Advance
  `100.64.0.1`) are declared on-link with `pointopoint`.
- IPv6: Hetzner uses `fe80::1`; OVH uses the gateway the rescue system was
  configured with, `--ovh-ipv6-gateway`, or the derived
  `<prefix>FF:FF:FF:FF:FF` form (see [docs/providers/ovh.md](docs/providers/ovh.md)).
- The WAN NIC is located **by MAC** at first boot and its name is pinned in
  `/etc/systemd/network/10-pve-dedicated-wan.link`, so a naming difference
  between rescue and the installed kernel (or a future upgrade) cannot cut
  the server off.

### SSH Security

When SSH keys are provided (auto-detected from rescue or manually entered):

- Keys installed to `/root/.ssh/authorized_keys` and
  `/etc/pve/priv/authorized_keys` (cluster-synced).
- `PermitRootLogin prohibit-password` (safe for Proxmox clustering).
- `PasswordAuthentication no`, `KbdInteractiveAuthentication no`.
- Drop-in config at `/etc/ssh/sshd_config.d/99-hardening.conf`, validated
  with `sshd -t` before SSH is restarted.
- The root password is written to `answer.toml` as a SHA-512 crypt hash
  (`root-password-hashed`), never in plaintext.

### Performance Tuning

- **TCP BBR** congestion control (better throughput on fast links).
- **TCP Fast Open** (reduced connection latency).
- **Swappiness = 10** (prevents aggressive swapping on hypervisors).
- **Kernel panic auto-reboot** after 10s (critical for unattended servers).
- **inotify watches** increased to 1M (fixes "no space left" with many
  containers).
- **Journald** limited to 64MB (prevents log bloat).
- **ZFS ARC** tuned dynamically based on RAM (5% min, 15% max, or
  `--zfs-arc-max`; min never exceeds half of max).
- **nf_conntrack** tuned for NAT (1M max entries, 8h timeout).
- **pigz** installed for 2-4x faster vzdump backups.
- **vzdump** bandwidth limit removed, IO priority set.

### APT Repositories

- All enterprise repos disabled (PVE + Ceph, both `.list` and `.sources`
  formats).
- No-subscription repos added for PVE and Ceph -- deb822
  `proxmox.sources` / `ceph.sources` (Ceph Tentacle) on Proxmox VE 9,
  `.list` files (Ceph Squid) on Proxmox VE 8.
- Subscription notice removed; a dpkg hook re-applies it after upgrades.

## QEMU Observability

- **Serial console**: installer output captured to
  `logs/qemu-install-serial.log`.
- **Progress tracking**: real-time phase detection from serial output.
- **Monitor socket**: programmatic QEMU control via `socat`
  (`/run/pve-dedicated-qemu-<pid>.sock`).
- **Timeout protection**: auto-kills after 40 minutes
  (`PVE_QEMU_INSTALL_TIMEOUT`).
- **Failure diagnostics**: QEMU's exit code and the last 20 lines of serial
  output are shown on error.
- **Disk passthrough**: virtio-blk with `cache=none` and the disks' real
  logical/physical block sizes (4Kn-safe); UEFI via OVMF pflash.

## Post-Installation Security

After reboot, **configure IP filtering before going to production**.

### Hetzner

1. `robot.hetzner.com` > Server > **Firewall**.
2. Create rules to ALLOW ports 22, 8006 only from your management IP(s).
3. Set default incoming policy to DROP.
4. Apply the firewall to your server.

### OVH

1. OVHcloud Manager > Bare Metal Cloud > **IP** > **Network firewall**
   on the relevant IP.
2. Activate the firewall, then create ALLOW rules for 22 and 8006 from
   your management IP(s) and a default DROP rule.
3. (Optional) Enable **Anti-DDoS Game** profile if your workload tolerates
   the latency profile.

In addition, enable the Proxmox built-in firewall at the Datacenter and
Node levels for defense in depth.

## Premium Features

`pve-dedicated` is open source. Some advanced features are shipped only
in the **premium** build (private repository) for sustainability of the
project.

### LUKS host encryption (premium)

Full-disk encryption of the Proxmox host (ZFS-on-LUKS) with these unlock
options, combinable:

- **Passphrase at console** -- always kept as the fallback.
- **Pre-boot SSH unlock** via dropbear-initramfs -- SSH into the
  pre-boot environment from anywhere and run `cryptroot-unlock`.
- **TPM2 automatic unlock** (Clevis) -- reboots unlock by themselves
  while firmware, firmware settings, PCIe cards and Secure Boot state
  are unchanged; anything else falls back to passphrase/SSH.
- **Tang automatic unlock** (Clevis) -- unlock only while the server
  can reach your Tang key server; can be required together with the TPM.
  On Hetzner, Tang can be reached over a vSwitch so it needs no public
  port (Docker image in [`contrib/tang-server/`](contrib/tang-server/README.md)).

LUKS works on mirrors/raidz and, with `--luks-allow-raid0`, on `raid0`
stripes.

### ZFS native encryption of VM data (premium)

`--zfs-encrypt` encrypts the VM/CT disks (`rpool/data`) and `/var/lib/vz`
with OpenZFS native encryption on any layout, including `raid0` for
maximum capacity. The host OS stays unencrypted, so it always boots and
stays reachable; the data unlocks automatically (TPM2/Tang via Clevis) or
with `pve-zfs-crypt unlock` over SSH. See the comparison with LUKS in
[docs/premium/zfs-encryption.md](docs/premium/zfs-encryption.md).

The premium module also wires in:

- A MAC-pinned initramfs network hook (resilient across NIC name
  changes between rescue and the installed system).
- `pve-luks` on the host to check, re-seal or disable automatic unlock,
  and a free-space wipe after encryption.
- Provider-specific glue for both Hetzner Robot rescue and OVH netboot
  rescue.

```text
+-------------------------------------------------------------+
|  PREMIUM: LUKS host encryption                              |
|  + Passphrase + Remote SSH unlock + TPM/Tang auto-unlock    |
|  + pve-luks helper + Provider-specific glue                 |
|                                                             |
|  Get premium access:                                        |
|    https://corelix.io/pve-dedicated-premium                 |
+-------------------------------------------------------------+
```

In the public build, passing `--enable-luks` triggers a clear premium
notice with the upgrade URL and continues the install without LUKS
(unless you cancel). Full operational documentation for the premium
module lives at [docs/premium/luks.md](docs/premium/luks.md) (premium
build only).

## Troubleshooting

See [.claude/docs/TROUBLESHOOTING.md](.claude/docs/TROUBLESHOOTING.md)
for common issues, organized by what is shared across providers vs.
what differs:

- Server unreachable after reboot (Hetzner vs OVH boot toggles)
- Locked out after SSH hardening
- QEMU fails to start or hangs
- ZFS pool not created
- Wrong boot mode
- Provider firewall not blocking traffic
- Hetzner vSwitch cannot reach the Cloud Network or Tang (tip: delete and
  re-add the vSwitch subnet in the Cloud Console; see
  [Troubleshooting the vSwitch](docs/providers/hetzner.md#troubleshooting-the-vswitch))
- OVH gateway model mis-classified (`/32` ranges)

## Documentation

- [Changelog](docs/CHANGELOG.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Migration: pve-hetzner -> pve-dedicated](docs/migration/renaming-to-pve-dedicated.md)
- Provider guides:
  - [Hetzner](docs/providers/hetzner.md)
  - [OVH](docs/providers/ovh.md)
- Premium:
  - [LUKS host encryption](docs/premium/luks.md) *(premium build only)*
- Internal references:
  - [Architecture](.claude/docs/ARCHITECTURE.md)
  - [Proxmox Auto-Install Reference](.claude/docs/PROXMOX-AUTOINSTALL.md)
  - [Troubleshooting](.claude/docs/TROUBLESHOOTING.md)

## License

[BSD 3-Clause with Branding Protection](LICENSE)

Copyright (c) 2025-2026, Amir Moradi / Corelix.io. Free to use, including
commercially. Derivative works must retain the original attribution and
may not reuse the project name or branding.

---

<div align="center">
<i>Provided freely by <a href="https://corelix.io">Corelix.io</a> - Made in France</i>
</div>
