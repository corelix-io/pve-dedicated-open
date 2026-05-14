# Migrating from `pve-hetzner` to `pve-dedicated`

`pve-hetzner` was renamed to `pve-dedicated` in the 3.0 release. The
project now installs Proxmox VE on multiple bare-metal providers
(Hetzner and OVH today, more to come). This is a **clean break** --
there are no legacy aliases, and the one-liner URL, script name,
banner and CLI have all changed.

If you are running the v2.x Hetzner-only installer, you do not need
to reinstall anything already in production. The rename only affects
**new installations** and **the automation** that triggers them. Your
existing Proxmox nodes are untouched.

This guide explains the changes and gives you exact before/after
commands and config diffs.

## What Changed

| Thing | Before (v2.x) | After (v3.0) |
|-------|---------------|--------------|
| Project name | `pve-hetzner` | `pve-dedicated` |
| Repository | `corelix-io/pve-hetzner` | `corelix-io/pve-dedicated` (private) + `corelix-io/pve-dedicated-open` (mirror) |
| Orchestrator | `pve-install.sh` | `pve-dedicated.sh` |
| One-liner URL | `releases/latest/download/install.sh` at the old repo | `releases/latest/download/install.sh` at the new repo |
| Banner / help text | "PVE HET" ASCII, Hetzner-only wording | "pve-dedicated", multi-provider wording |
| CLI | Implicit Hetzner | `--provider hetzner\|ovh` is required in unattended mode (auto-detected interactively) |
| Env key | n/a | `PVE_PROVIDER=hetzner\|ovh` |
| Docs layout | `docs/` + a Hetzner networking note | `docs/providers/*`, `docs/migration/*`, `docs/premium/*` |
| Premium features | n/a | Host-level LUKS encryption lives in the premium (private) repo; the public build calls the upgrade URL CTA |

There are no behavioural changes on existing Hetzner nodes -- the
Hetzner provider module (`lib/providers/hetzner.sh`) reproduces the
v2.x rendering of `/etc/network/interfaces` exactly.

## One-Liner Replacement

### Before (v2.x -- Hetzner-only)

```bash
curl -4fsSL https://github.com/corelix-io/pve-hetzner/releases/latest/download/install.sh \
    | bash
```

### After (v3.0 -- Hetzner)

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated/releases/latest/download/install.sh \
    | bash -s -- --provider hetzner
```

### After (v3.0 -- OVH)

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated/releases/latest/download/install.sh \
    | bash -s -- --provider ovh
```

For OVH on a Scale, High Grade or Advance range, add
`--ovh-gateway-model scale` (the installer auto-detects it on
auto, but pinning it explicitly makes unattended runs bulletproof).

## CLI Example Mapping (v2.x -> v3.0)

### Unattended Hetzner install

Before:

```bash
bash pve-install.sh \
    --hostname pve1 --fqdn pve1.example.com --password 'S3cret!' \
    --timezone UTC --email admin@example.com \
    --unattended --yes
```

After:

```bash
bash pve-dedicated.sh \
    --provider hetzner \
    --hostname pve1 --fqdn pve1.example.com --password 'S3cret!' \
    --timezone UTC --email admin@example.com \
    --unattended --yes
```

Only the script name and the new `--provider` flag change.

### Using a config file

Before (`myserver.env`):

```bash
PVE_HOSTNAME="pve1"
PVE_FQDN="pve1.example.com"
PVE_ROOT_PASSWORD="S3cret!"
PVE_TIMEZONE="UTC"
PVE_EMAIL="admin@example.com"
PVE_FILESYSTEM="zfs"
PVE_ZFS_RAID="raid1"
PVE_PRIVATE_SUBNET="192.168.26.0/24"
PVE_NETWORK_MODE="nat"
```

Config diff -- add exactly one line:

```diff
+PVE_PROVIDER="hetzner"
 PVE_HOSTNAME="pve1"
 PVE_FQDN="pve1.example.com"
 PVE_ROOT_PASSWORD="S3cret!"
 PVE_TIMEZONE="UTC"
 PVE_EMAIL="admin@example.com"
 PVE_FILESYSTEM="zfs"
 PVE_ZFS_RAID="raid1"
 PVE_PRIVATE_SUBNET="192.168.26.0/24"
 PVE_NETWORK_MODE="nat"
```

v2.x `.env` files are forward-compatible with v3.0 -- once
`PVE_PROVIDER` is set, every other key is read unchanged.

### Unattended OVH install (Scale / High Grade / Advance)

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated/releases/latest/download/install.sh \
    | bash -s -- \
        --provider ovh --ovh-gateway-model scale \
        --hostname pve1 --fqdn pve1.example.com --password 'S3cret!' \
        --timezone UTC --email admin@example.com \
        --unattended --yes
```

### Unattended OVH install with vRack

```bash
curl -4fsSL https://github.com/corelix-io/pve-dedicated/releases/latest/download/install.sh \
    | bash -s -- \
        --provider ovh --ovh-gateway-model scale \
        --ovh-vrack-interface eno2 \
        --ovh-vrack-ip 10.42.0.10/24 \
        --hostname pve1 --fqdn pve1.example.com --password 'S3cret!' \
        --timezone UTC --email admin@example.com \
        --unattended --yes
```

## Things That Did NOT Change

- Installation phases are still 11 (see
  [`README.md`](../../README.md)).
- Hetzner network rendering is byte-for-byte identical (same
  `pointopoint`, `bridge-fd 1`, `fe80::1` handling).
- All `PVE_*` environment variables from v2.x are still recognised by
  `config_load_file` in
  [`lib/config.sh`](../../lib/config.sh).
- First-boot hook support requirements (PVE 8.3+) are unchanged.
- The QEMU serial/monitor observability and the SHA256 ISO
  verification are unchanged.

## What Is New in v3.0

Follow the links for full details:

- Multi-provider abstraction in `lib/providers/` --
  [`.claude/docs/ARCHITECTURE.md`](../../.claude/docs/ARCHITECTURE.md).
- First-class OVH support --
  [`docs/providers/ovh.md`](../providers/ovh.md).
- Premium LUKS host encryption (private build) --
  [`docs/premium/luks.md`](../premium/luks.md).
- Full changelog --
  [`docs/CHANGELOG.md`](../CHANGELOG.md).

## Why a Clean Break Instead of Aliases

Keeping a `pve-hetzner` alias in the new repo would have meant:

- Two sets of docs to keep in sync.
- A one-liner URL that silently works but no longer reflects the
  project identity.
- A subtle trap for scripts that pipe `install.sh` from the old repo
  expecting Hetzner defaults that no longer match the orchestrator's
  provider-resolve step.

A clean break forces automations to be updated once, explicitly, and
produces correct behaviour for both providers going forward. The
mapping table above is intentionally exhaustive so a mechanical
replacement is straightforward.

## Getting Premium

The premium module (LUKS host encryption with passphrase, remote SSH
unlock via dropbear-initramfs, TPM auto-unlock, and recovery helpers)
is available at
[`https://corelix.io/pve-dedicated-premium`](https://corelix.io/pve-dedicated-premium).

Premium is additive: your public-build installs keep working
exactly as they do today, and upgrading to premium only gates the
`--enable-luks` flag. See [`docs/premium/luks.md`](../premium/luks.md)
for operational details.

## Branding

The "Provided freely by Corelix.io - Made in France" line and the
"Author: Amir Moradi" attribution are preserved across the rename.
They appear in the banner, the help text, the install report, and
the README footer. The branding clause in the
[`LICENSE`](../../LICENSE) continues to apply to both the public and
premium builds.
