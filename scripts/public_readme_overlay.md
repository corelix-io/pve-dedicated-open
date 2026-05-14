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
