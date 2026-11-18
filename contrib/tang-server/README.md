# Tang server in Docker

A [Tang](https://github.com/latchset/tang) server lets encrypted disks
unlock themselves at boot while they can reach it ("network-bound disk
encryption"). `pve-dedicated` uses it through Clevis for LUKS
(`--luks-unlock-modes ...,tang`) and ZFS native encryption
(`--zfs-unlock-modes ...,tang`).

This directory builds a small image from Debian trixie's `tang-common`
(Tang 15, built-in listener, no inetd or socat).

## Contents

1. [Recommended layout: Tang over a Hetzner vSwitch](#recommended-layout-tang-over-a-hetzner-vswitch)
2. [Run the container](#run-the-container)
3. [Firewall](#firewall)
4. [Point the installer at it](#point-the-installer-at-it)
5. [Operations](#operations)
6. [Security notes](#security-notes)

## Recommended layout: Tang over a Hetzner vSwitch

Tang hands out its key-exchange answer to anyone who asks. The protection
comes from *who can reach it*: a disk that has left your servers must not
be able to talk to your Tang server. The strongest way to do that on
Hetzner is to keep Tang off the internet entirely:

```
 Robot dedicated servers                         Hetzner Cloud
 ┌──────────────┐  VLAN 4000                     ┌─────────────────────┐
 │ pve3         │  10.0.1.3/24 ──┐               │ Tang VPS            │
 │  (LUKS, Tang │                │  vSwitch      │  10.0.0.2 (private) │
 │   unlock)    │                ├── subnet ─────┤  tang :7500         │
 └──────────────┘                │  10.0.1.0/24  │  firewall: allow    │
 ┌──────────────┐                │  gw 10.0.1.1  │  10.0.1.0/24 only   │
 │ pve4 ...     │  10.0.1.4/24 ──┘               └─────────────────────┘
 └──────────────┘          Cloud Network 10.0.0.0/16
```

- Only servers you add to the vSwitch in Robot can reach Tang. Stolen or
  returned disks booted anywhere else cannot.
- Tang has no public port, so there is nothing to scan or attack.
- The installer configures the vSwitch VLAN both on the installed host
  and in the pre-boot environment (initramfs), where the unlock happens.

### Hetzner setup

1. **Robot > vSwitches**: create a vSwitch (VLAN ID 4000-4091, e.g.
   4000) and add every dedicated server that should unlock through Tang.
2. **Cloud Console > Networks**: create a network (e.g. `10.0.0.0/16`)
   with a cloud subnet (e.g. `10.0.0.0/24`), then add a subnet of type
   **vSwitch** (e.g. `10.0.1.0/24`) linked to the vSwitch from step 1.
   The Cloud Network gateway for that subnet is its first address
   (`10.0.1.1`).
3. **Cloud server** for Tang (the smallest one is plenty): attach it to
   the network. It gets a private address such as `10.0.0.2` and a route
   to the whole network range, vSwitch subnet included.
4. **Dedicated servers**: install with
   `--vswitch-vlan 4000 --vswitch-ip 10.0.1.3/24 --vswitch-routes 10.0.0.0/16`
   (one address per server). See
   [`docs/providers/hetzner.md`](../../docs/providers/hetzner.md#vswitch).

Hetzner Cloud Firewalls do **not** filter private-network traffic, so the
allow list below must be on the VPS itself.

Without a vSwitch (other providers, or a Tang server elsewhere), use a
public address and allow only your servers' public IPs.

## Run the container

On the Tang VPS (Docker with the compose plugin):

```bash
git clone --depth 1 https://github.com/corelix-io/pve-dedicated-open.git
cd pve-dedicated-open/contrib/tang-server
docker compose up -d --build
docker exec tang tang-show-keys 7500     # the thumbprint for the installer
```

- Keys are generated on first start into the `tang-keys` volume and kept
  across restarts and image rebuilds.
- The container uses the **host network**, so the host firewall filters
  it directly. (Docker-published ports bypass ufw/INPUT rules.)
- It listens on port 7500 on all addresses (change `TANG_PORT` in
  `compose.yaml`); the firewall decides who gets in.
- Read-only root filesystem, no capabilities, unprivileged user.

## Firewall

ufw on the VPS, private interface `enp7s0` (check with `ip -br a`):

```bash
ufw default deny incoming
ufw allow 22/tcp                       # or restrict to your admin IP
ufw allow in on enp7s0 from 10.0.1.0/24 to any port 7500 proto tcp
ufw enable
```

Allow only the **vSwitch subnet** (the Robot servers), not the whole
Cloud Network, unless cloud servers also need to unlock. Traffic from the
vSwitch is routed, not NATed, so the VPS sees each server's own
`10.0.1.x` address; for a tighter list, allow single addresses instead.

Check from a dedicated server (installed host, or the rescue system after
creating the VLAN by hand): `curl -fsS http://10.0.0.2:7500/adv`.

## Point the installer at it

```bash
PVE_LUKS_UNLOCK_MODES="passphrase,ssh,tang"
PVE_LUKS_TANG_URLS="http://10.0.0.2:7500"
PVE_LUKS_TANG_THUMBPRINTS="<output of tang-show-keys>"
PVE_HETZNER_VSWITCH_VLAN="4000"
PVE_HETZNER_VSWITCH_IP="10.0.1.3/24"
PVE_HETZNER_VSWITCH_ROUTES="10.0.0.0/16"
```

- **Plain HTTP is fine.** The Tang exchange never sends the disk key or
  anything that reveals it; the thumbprint pins the server's identity.
- **Two Tang servers** (comma-separated URLs and thumbprints, same order)
  give redundancy: either one answering unlocks. Put the second VPS in
  another Hetzner location, attached to the same Cloud Network.
- **Keep `ssh` in the unlock modes** as the fallback when no Tang server
  answers (VPS down, vSwitch outage): `ssh -p 2222 root@<public IP>`,
  then `cryptroot-unlock`.
- During installation (premium build) the installer brings the vSwitch up temporarily in
  rescue and checks that Tang answers, before touching the disks.

## Operations

| Task | Command |
|---|---|
| Thumbprint | `docker exec tang tang-show-keys 7500` |
| Health | `docker inspect -f '{{.State.Health.Status}}' tang`, or an HTTP check on `/adv` from your monitoring |
| Logs | `docker logs tang` (one line per request) |
| Back up the keys | `docker run --rm -v tang-server_tang-keys:/k:ro -v "$PWD":/b debian:trixie-slim tar -C /k -czf /b/tang-keys.tgz .` |
| Rotate keys | `docker exec tang /usr/libexec/tangd-rotate-keys -d /var/lib/tang`, then on every client `pve-luks reseal` (or `pve-zfs-crypt reseal`) and update the thumbprint you keep |

The volume name is prefixed with the compose project name (the directory
name by default); `docker volume ls` shows it.

After a rotation the old keys stay available (renamed to `.*.jwk`), so
clients that have not re-sealed yet still unlock. Delete the old files
once every client has re-sealed.

**Losing the Tang keys does not lose data**: affected servers fall back
to the passphrase (SSH unlock). Still, keep the backup off the VPS.

There is no web UI for Tang, and little to manage: it holds only its key
files. An uptime check on `http://10.0.0.2:7500/adv` tells you it is up
before a server reboots.

## Security notes

- **Do not run Tang on a server that unlocks through it**, nor in a VM on
  that server: it cannot answer while its host is locked.
- **Avoid circular unlocks**: two servers that each host the other's Tang
  both need SSH unlock if they reboot together. A small Cloud VPS has no
  disks to unlock and avoids this.
- **Anyone who controls a vSwitch member can query Tang.** That alone is
  not enough: they also need a copy of the disks' LUKS header. Keep the
  vSwitch limited to your own servers.
- Tang does not log *which* disk asked. If a server is decommissioned or
  its disks are swapped, rotate the Tang keys and re-seal the remaining
  servers.
