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
  NIC name (one `eth0 -> enp7s0` line per NIC).
- `netdata` (Hetzner's tool, not the monitoring stack) reports link,
  MAC and driver.
- KVM modules ship but may need loading:
  `modprobe kvm kvm_intel 2>/dev/null || modprobe kvm kvm_amd`.
- OVMF firmware comes from the `ovmf` package (installed in Phase 7).
  The installer prefers the split pair `OVMF_CODE_4M.fd` /
  `OVMF_VARS_4M.fd` (Debian trixie) or `OVMF_CODE.fd` /
  `OVMF_VARS.fd` under `/usr/share/OVMF/`, and falls back to a
  combined `OVMF.fd`.
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
so logs are accessible. To opt out, point the working directory at a
roomy path with `--working-dir` (or `PVE_WORKING_DIR` in a
`--config` file):

```bash
./pve-dedicated.sh --provider hetzner --working-dir /tmp ...
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
uses the `predict-check` line for the selected NIC and falls back to
udev, following systemd's NamePolicy order (`ID_NET_NAME_ONBOARD`,
then `ID_NET_NAME_SLOT`, then `ID_NET_NAME_PATH`):

```bash
predict-check
# eth0 -> enp0s31f6

udevadm info /sys/class/net/eth0 | grep ID_NET_NAME_
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

The prediction is only used for the install summary and as a
fallback. On first boot, the generated script finds the NIC whose
MAC matches the one seen in rescue, writes that name into
`/etc/network/interfaces`, and pins it with
`/etc/systemd/network/10-pve-dedicated-wan.link`, so a model with an
unexpected name still comes up correctly.

## Network Topologies

`pve-dedicated` supports three modes, selected with `--network-mode`.
All three are rendered by
[`hetzner_render_interfaces`](../../lib/providers/hetzner.sh). The
private NAT bridge `vmbr1` exists only in NAT mode.

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

- The physical NIC owns the main IP as a `/32` with
  `pointopoint <gateway>`.
- `vmbr0` has `bridge-ports none` and carries the main IP as `/32`;
  it is the gateway for the VMs.
- Each address passed with `--additional-ips` (comma- or
  space-separated; a bare IP means `/32`) is routed onto `vmbr0` via
  `up ip route add <ip>/32 dev vmbr0`.
- The VM binds its guest IP inside itself, uses the host's main IP
  as its gateway, and egresses through the host.
- No virtual MAC required.

```bash
./pve-dedicated.sh --provider hetzner --network-mode routed \
    --additional-ips "203.0.113.10,203.0.113.11" ...
```

### Bridged (`--network-mode bridged`)

Required when the VMs truly need to own their public IP at L2 (e.g.
running their own neighbour discovery).

- Same `vmbr0` as NAT mode (physical NIC `inet manual`, `vmbr0`
  bridged to it and owning the main IP), but no `vmbr1`.
- Each VM NIC MUST be configured with a Virtual MAC from Robot Panel
  (the install report repeats this).

## IPv6

- Every Hetzner server gets a `/64` IPv6 subnet.
- The gateway is always `fe80::1` on the physical link.
- NAT / bridged mode: the main IPv6 (as configured in rescue) goes
  on `vmbr0` with `gateway fe80::1`.
- Routed mode: the main IPv6 is `/128` on the physical interface
  (with `gateway fe80::1`) and `/64` on `vmbr0`, so the rest of the
  `/64` is reachable through the bridge.
- NAT mode only: a `/80` slice of the `/64` (`<prefix>:1::1/80`) is
  assigned to the NAT bridge (`vmbr1`) so VMs can have IPv6 without
  eating into the routable pool.

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

iface vmbr1 inet6 static
    address <IPV6_PREFIX>:1::1/80
```

The IPv6 stanzas are present only when the rescue system had a
global IPv6 address. The installer writes this file on first boot
from a template whose `<IFACE>` is resolved by MAC on the real
hardware (see "Discovering the post-install name" above).

## vSwitch

A Hetzner [vSwitch](https://docs.hetzner.com/robot/dedicated-server/network/vswitch)
is a tagged VLAN (ID 4000-4091) between your Robot servers. It can be
coupled to a Hetzner Cloud Network so that dedicated servers and cloud
servers share a private network. The installer configures it when you
pass a VLAN ID; it is optional.

| CLI flag | `.env` key | Default | Purpose |
|---|---|---|---|
| `--vswitch-vlan ID` | `PVE_HETZNER_VSWITCH_VLAN` | -- | VLAN ID from Robot > vSwitches; enables the vSwitch |
| `--vswitch-ip CIDR` | `PVE_HETZNER_VSWITCH_IP` | -- | This server's address, e.g. `10.0.1.3/24` |
| `--vswitch-routes L` | `PVE_HETZNER_VSWITCH_ROUTES` | -- | Networks reached through the gateway, e.g. the Cloud Network `10.0.0.0/16` |
| `--vswitch-gateway IP` | `PVE_HETZNER_VSWITCH_GATEWAY` | first host of the subnet | Gateway for those routes (`10.0.1.1` for a Cloud Network vSwitch subnet) |
| `--vswitch-mtu N` | `PVE_HETZNER_VSWITCH_MTU` | `1400` | Hetzner requires at most 1400 |
| `--vswitch-bridge` | `PVE_HETZNER_VSWITCH_BRIDGE=true` | off | Also create `vmbr<VLAN>` for guests |

`--hetzner-vswitch-*` are accepted as long forms.

What gets written to `/etc/network/interfaces`:

```
auto vlan4000
iface vlan4000 inet static
    address 10.0.1.3/24
    vlan-raw-device vmbr0          # the NIC itself in routed mode
    vlan-id 4000
    mtu 1400
    up   ip route replace 10.0.0.0/16 via 10.0.1.1 dev vlan4000
    down ip route del 10.0.0.0/16 via 10.0.1.1 dev vlan4000 || true
```

- In `nat` and `bridged` mode the NIC is a port of the VLAN-aware
  `vmbr0`, so the VLAN sits on `vmbr0`; guests can also use the vSwitch
  directly with VLAN tag 4000 on `vmbr0`.
- With `--vswitch-bridge`, `vlan4000` carries no address and the bridge
  `vmbr4000` holds it; attach guests to `vmbr4000` without a tag.
- Guests on the vSwitch need MTU 1400 inside the guest as well.
- The server must be a member of the vSwitch in **Robot > vSwitches**,
  otherwise the VLAN stays silent.

To couple the vSwitch with a Cloud Network, add a subnet of type
**vSwitch** in the Cloud Console
([Hetzner guide](https://docs.hetzner.com/networking/networks/connect-dedi-vswitch)).
Its gateway is the first address of that subnet, which is the default
for `--vswitch-gateway`. Hetzner Cloud Firewalls do not filter
private-network traffic: filter on the hosts.

### Tang over the vSwitch (recommended for encrypted servers)

With premium LUKS (`--enable-luks`) and Tang unlock, the installer also
brings the vSwitch VLAN up in the **pre-boot environment**, where the
disks are unlocked. A Tang server on a small Cloud VPS in the coupled
Cloud Network then needs no public port, and disks that leave your
servers cannot reach it. Setup, Docker image and firewall:
[`contrib/tang-server/README.md`](../../contrib/tang-server/README.md).

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
Node > Firewall) for defence in depth. In NAT mode `pve-dedicated`
loads `nf_conntrack` at boot and raises its limits, so stateful
rules work out of the box.

Troubleshooting: if packets still arrive despite your rules, see
[Hetzner firewall not blocking traffic](../../.claude/docs/TROUBLESHOOTING.md#hetzner-firewall-not-blocking-traffic).

## DNS Defaults

When `--dns` / `PVE_DNS_SERVERS` is not set (it is empty by
default), the installer applies Hetzner's recursive resolvers:

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
- [vSwitch](https://docs.hetzner.com/robot/dedicated-server/network/vswitch) and
  [connecting it to a Cloud Network](https://docs.hetzner.com/networking/networks/connect-dedi-vswitch)

For troubleshooting scenarios that are specific to Hetzner (rescue
mount for ZFS, SSH lockout recovery, Robot firewall not applied),
see the Hetzner sections of
[`.claude/docs/TROUBLESHOOTING.md`](../../.claude/docs/TROUBLESHOOTING.md).
