# Hetzner Provider Guide

This page covers everything Hetzner-specific that
[`pve-dedicated`](../../README.md) needs you (or your CI) to know:
how to enter rescue, how interfaces map, how IP/MAC binding shapes
your network design, and what the installer produces on each supported
topology.

For the multi-provider overview, start at
[`README.md`](../../README.md). For the end-to-end architecture, read
[`.claude/docs/ARCHITECTURE.md`](../../.claude/docs/ARCHITECTURE.md).

## Supported Ranges

Validated end-to-end on modern Hetzner dedicated ranges (see the
compatible-server matrix in the README for exact models):

| Range | Typical NIC | Disks | Boot mode |
|-------|-------------|-------|-----------|
| [AX](https://www.hetzner.com/dedicated-rootserver/matrix-ax) | `enp0s31f6`, `eno1`, `enp35s0` | NVMe (x2-x4) | UEFI (default) |
| [EX](https://www.hetzner.com/dedicated-rootserver/matrix-ex) | `enp0s31f6`, `eno1` | Mixed NVMe/SSD | UEFI |
| [SX](https://www.hetzner.com/dedicated-rootserver/matrix-sx) | `eno1`, `enp0s31f6` | SATA (storage-heavy) | UEFI |

The installer probes disks, boot mode and NIC at runtime -- you do not
need to hardcode any of the above.

## Entering Rescue Mode

1. Open [`robot.hetzner.com`](https://robot.hetzner.com) and pick your
   server.
2. Go to the **Rescue** tab, select **Linux 64-bit**, optionally add
   an SSH key, click **Activate**.
3. Switch to the **Reset** tab and click **Execute an automatic
   hardware reset**. Do not rely on a software reboot from the
   currently running system -- the `reboot` command may not leave
   rescue.
4. Within ~2 minutes, SSH in as `root` to the server's primary IP.

The rescue password is shown in the Robot Panel activation dialog
and emailed to you if you requested it. If you added an SSH key when
activating rescue, it is automatically pushed to
`/root/.ssh/authorized_keys` and `pve-dedicated` will re-use it.

### Rescue environment facts

- Debian-based minimal Linux.
- Root filesystem is tmpfs (`df /` reports `tmpfs` / `rootfs`).
- NIC in rescue is always `eth0` (or similar legacy name) -- the
  post-install name is different and the installer discovers it.
- Marker: `/etc/hetzner-rescue` is present, and `installimage` is on
  `$PATH`.
- `predict-check` is installed and returns the expected post-install
  NIC name.
- `netdata` (Hetzner's tool, not the monitoring stack) reports link,
  MAC and driver.
- KVM modules ship but may need loading:
  `modprobe kvm kvm_intel 2>/dev/null || modprobe kvm kvm_amd`.
- OVMF firmware is at `/usr/share/OVMF/OVMF_CODE.fd`.
- `bc` is **not** installed -- avoid in rescue-side scripts.
- IPv6 is frequently slow/unreliable in rescue. All installer
  downloads force IPv4 (`curl -4`, `Acquire::ForceIPv4 "true"` for
  apt).
- The rescue tmpfs sized to a fraction of RAM. On smaller machines
  (EX-44 with 64 GiB RAM is fine, but tighter SX/EX configs can
  surprise you), the working dir may not have room for the 1.7 GB
  Proxmox ISO + 1.7 GB autoinstall `.tmp` copy. The installer
  auto-detects this and mounts a sized tmpfs at
  `/mnt/pve-dedicated-work` -- see "Workspace auto-relocation"
  below.

### Workspace auto-relocation

In phase 7, [`iso_ensure_workspace_capacity`](../../lib/iso.sh)
checks `df -P -B1 "$PVE_WORKING_DIR"`. If less than 5 GiB free, it
mounts a tmpfs at `/mnt/pve-dedicated-work` sized
`min(16 GiB, max(8 GiB, RAM/4))`, migrates any pre-downloaded ISO,
and re-points `PVE_WORKING_DIR` at it. The mount stays after install
so logs are accessible. To opt out, pre-set `PVE_WORKING_DIR` to a
roomy path:

```bash
PVE_WORKING_DIR=/tmp ./pve-dedicated.sh --provider hetzner ...
```

## IP/MAC Binding

Hetzner enforces strict IP-to-MAC pairing at the network edge. Packets
leaving your server with a source MAC that does not match a MAC
registered to one of your IPs are flagged as abuse and may lead to
port blocking.

Consequences for Proxmox:

- **Bridged mode** (VMs publish their own public IPs) requires a
  **Virtual MAC** per additional IP from the Robot Panel. Without
  them, traffic from VMs will be blocked.
- **Routed mode** (main IP on the host, additional IPs as `/32`s
  routed onto `vmbr0`) does not require virtual MACs because the
  traffic always egresses with the host MAC.
- **NAT mode** (the installer's default) sidesteps the issue entirely
  for VMs running on the NAT bridge (`vmbr1`), because those packets
  are source-NATed to the host IP and MAC before leaving.

If you do go bridged, add the virtual MACs in Robot Panel > **IPs** >
pick the additional IP > **Virtual MAC**. Use the exact MAC shown
there for your VM's NIC.

## Interface Naming

### In rescue

Always `eth0` (or similar legacy single-NIC name). Do not copy the
rescue interface name into `/etc/network/interfaces` -- the installed
kernel will rename it.

### Discovering the post-install name

The installer calls
[`hetzner_predict_iface`](../../lib/providers/hetzner.sh) which
prefers Hetzner's `predict-check` tool and falls back to udev
`ID_NET_NAME_PATH`:

```bash
predict-check
# eth0 -> enp0s31f6

udevadm info /sys/class/net/eth0 | grep ID_NET_NAME_PATH
# ID_NET_NAME_PATH=enp0s31f6
```

For debugging you can also list active links and MACs:

```bash
netdata
ip -br link show
```

### Common post-install names

| Server Series | Typical Interface |
|---------------|-------------------|
| AX series     | `enp0s31f6`, `eno1`, `enp35s0` |
| EX series     | `enp0s31f6`, `eno1` |
| SX series     | `eno1`, `enp0s31f6` |

If a model uses a different name, the installer still gets it right
because the prediction step runs on the actual hardware.

## Network Topologies

`pve-dedicated` supports three modes, selected with `--network-mode`.
All three are exercised by
[`hetzner_render_interfaces`](../../lib/providers/hetzner.sh).

### NAT / Masquerading (default -- `--network-mode nat`)

Best for single-IP servers running purely internal workloads.

- `vmbr0` owns the public IPv4 (and IPv6 when available), with
  `bridge-ports <predicted-iface>`.
- `bridge-fd 1` and `pointopoint <gateway>` are required for Hetzner
  routing.
- `vmbr1` is a private bridge with `bridge-ports none` on a subnet you
  choose (default `192.168.26.0/24`), and an iptables MASQUERADE rule
  so VM traffic source-NATs to the host.
- If `--dhcp` is left on (the default), `dnsmasq` hands out
  `.100 - .200` on `vmbr1`, so VMs get connectivity with zero VM-side
  configuration.

### Routed (`--network-mode routed`)

Best when you have additional Hetzner IPs that you want to route to
individual VMs without the virtual-MAC song and dance.

- Main IP stays on `vmbr0` as in NAT mode.
- Each additional `/32` is routed onto `vmbr0` via
  `up ip route add <ip>/32 dev vmbr0`.
- The VM binds its guest IP inside itself and egresses through
  `vmbr0`.
- No virtual MAC required.

### Bridged (`--network-mode bridged`)

Required when the VMs truly need to own their public IP at L2 (e.g.
running their own neighbour discovery).

- Physical NIC is `inet manual`.
- `vmbr0` has `bridge-ports <predicted-iface>`.
- Each VM NIC MUST be configured with a Virtual MAC from Robot Panel.

## IPv6

- Every Hetzner server gets a `/64` IPv6 subnet.
- The gateway is always `fe80::1` on the physical link.
- The installer writes the main IPv6 on `vmbr0` (as `/128` on the
  physical interface when applicable, `/64` on the bridge) and adds
  `gateway fe80::1` to the `inet6` stanza.
- A `/80` slice of the `/64` is reserved for the NAT bridge
  (`vmbr1`) so VMs can have IPv6 without eating into the routable
  pool.

## Example `/etc/network/interfaces` (NAT mode)

This is the exact shape produced by
[`hetzner_render_interfaces`](../../lib/providers/hetzner.sh), with
placeholders for values the installer derives at runtime.

```ini
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

iface <IFACE> inet manual

auto vmbr0
iface vmbr0 inet static
    address <PUBLIC_IP>/<MASK>
    gateway <GATEWAY>
    bridge-ports <IFACE>
    bridge-stp off
    bridge-fd 1
    bridge-vlan-aware yes
    bridge-vids 2-4094
    pointopoint <GATEWAY>

iface vmbr0 inet6 static
    address <IPV6>/<MASK>
    gateway fe80::1

auto vmbr1
iface vmbr1 inet static
    address <PRIVATE_IP>/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '<PRIVATE_SUBNET>' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '<PRIVATE_SUBNET>' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

## Robot Firewall

Hetzner offers a stateful firewall at the network edge (applied on
the switch, not inside your server). This is the most effective layer
for Hetzner deployments because traffic that is DROPped never reaches
your server at all.

Recommended baseline after install:

1. `robot.hetzner.com` > Server > **Firewall**.
2. Create ALLOW rules for:
   - TCP 22 from your management IPs.
   - TCP 8006 from your management IPs.
   - Any VM-service ports you explicitly want to expose.
3. Default incoming policy: **DROP**.
4. Apply the firewall to your server (toggle must be green).

Layer the Proxmox firewall on top of this (Datacenter > Firewall and
Node > Firewall) for defence in depth. `pve-dedicated` enables
`nf_conntrack` and tunes it for NAT, so stateful rules work out of
the box.

Troubleshooting: if packets still arrive despite your rules, see
[Hetzner firewall not blocking traffic](../../.claude/docs/TROUBLESHOOTING.md#hetzner-firewall-not-blocking-traffic).

## DNS Defaults

When the user does not override `--dns`, the installer applies
Hetzner's recursive resolvers:

- `185.12.64.1` (primary)
- `185.12.64.2` (secondary)

Alternatives that work equally well on Hetzner's network:
`1.1.1.1` (Cloudflare), `8.8.8.8` (Google), `9.9.9.9` (Quad9).

## Rebooting Out of Rescue

Use Robot Panel > Server > **Reset** > **Execute an automatic
hardware reset**. A plain `reboot` from the rescue shell sometimes
loops back into rescue instead of booting from disk. The install
report prints this reminder at the end of the run.

## Upstream References

- [Hetzner Robot Panel](https://robot.hetzner.com)
- [Rescue System docs](https://docs.hetzner.com/robot/dedicated-server/troubleshooting/hetzner-rescue-system)
- [IP/MAC binding tutorial](https://docs.hetzner.com/robot/dedicated-server/ip/additional-ipv4-addresses)
- [Proxmox on Hetzner community tutorial](https://community.hetzner.com/tutorials/install-proxmox-ve)

For troubleshooting scenarios that are specific to Hetzner (rescue
mount for ZFS, SSH lockout recovery, Robot firewall not applied),
see the Hetzner sections of
[`.claude/docs/TROUBLESHOOTING.md`](../../.claude/docs/TROUBLESHOOTING.md).
