# Contributing

Contributions are welcome. This document explains how to contribute
effectively to **`pve-dedicated`** (the multi-provider Proxmox VE
installer formerly known as `pve-hetzner`).

## Getting Started

1. Fork the repository.
2. Create a feature branch: `git checkout -b feat/my-feature`.
3. Make your changes following the code style guidelines below.
4. Test your changes (see Testing section).
5. Commit with a clear message: `feat(ovh): add vrack vlan-aware bridge`.
6. Open a pull request with a description of what changed and why.

## Repository Layout

The orchestrator and core libraries are provider-agnostic. Anything
provider-specific belongs in `lib/providers/<name>.sh`. Anything
premium-only belongs in `lib/premium/<feature>_*.sh` and ships only in
the private repository.

```
pve-dedicated.sh         # Orchestrator entry point (do not put provider logic here)
install.sh               # Bootstrap one-liner
lib/                     # Generic library modules
  providers/
    common.sh            # Provider registry, dispatch, premium gate stubs
    hetzner.sh           # Hetzner provider hooks
    ovh.sh               # OVH provider hooks
  premium/               # PRIVATE -- premium feature implementations
templates/               # Configuration templates with {{PLACEHOLDER}}
configs/                 # Example .env configuration files
docs/                    # User-facing documentation
  providers/             # One file per provider
  migration/             # Migration / rename guides
  premium/               # Premium-only docs (stripped from public mirror)
.claude/                 # Agent instructions and internal references
.github/workflows/       # CI: tests, release bundle, public-mirror strip
```

## Adding a New Provider

The provider abstraction is intentionally small so that adding a new
provider does not require editing the orchestrator. To add e.g.
`hivelocity`:

1. **Register the provider** in `lib/providers/common.sh`:

   ```bash
   declare -ga PROVIDER_REGISTRY=("hetzner" "ovh" "hivelocity")
   ```

   And add a branch in `provider_autodetect()` for any rescue
   fingerprints you can rely on (e.g. a marker file, a motd line, a
   characteristic resolv.conf).

2. **Create `lib/providers/hivelocity.sh`** implementing the hook
   contract:

   | Hook | Required | Purpose |
   |------|----------|---------|
   | `<p>_check_rescue` | yes | Detect provider's rescue/recovery environment, log a confirmation. |
   | `<p>_default_dns` | yes | Echo a space-separated DNS list used as default. |
   | `<p>_predict_iface` | yes | Echo the post-install interface name for the active NIC. |
   | `<p>_render_interfaces` | yes | Write `/etc/network/interfaces` to stdout for the current `PVE_*` state. |
   | `<p>_post_network_detect` | optional | Refine derived facts after `net_detect_all` (e.g. classify a gateway model). |
   | `<p>_post_install_notes` | optional | Lines appended to the install report (firewall, reboot toggles). |

3. **Source the new module** in `pve-dedicated.sh` next to the existing
   `lib/providers/hetzner.sh` and `lib/providers/ovh.sh` source lines.

4. **Add provider-specific config knobs** in `lib/config.sh`:
   - Declare any `PVE_<PROVIDER>_*` variables at the top of the file.
   - Add `--<provider>-*` cases to `config_parse_args()`.
   - Add the same keys to `config_load_file()` so they round-trip
     through `.env`.
   - Update `config_show_help()` with a new section.

5. **Document the provider** under `docs/providers/<name>.md` following
   the structure of [providers/hetzner.md](providers/hetzner.md) and
   [providers/ovh.md](providers/ovh.md): rescue mode, NIC naming,
   network topology, IPv6 specifics, additional IPs, firewall, links to
   official docs.

6. **Update README**: add the provider to the compatible-server matrix
   and to the quick-start examples.

7. **Tests**: add a `tests/test-provider-<name>.sh` covering at least
   the `_render_interfaces` output for the canonical config. Use
   golden-file comparisons against snippets under `tests/fixtures/`.

The orchestrator itself should not change when a provider is added. If
you find yourself touching `pve-dedicated.sh` to support a new
provider, the abstraction probably needs a new hook -- discuss it in
the PR before coding.

## Premium Code

`pve-dedicated` is dual-track: a public open-source build and a private
premium build. The split is enforced by tooling, not by trust:

- **Public-only files** -- everything outside `lib/premium/` and
  `docs/premium/`.
- **Premium-only files** -- everything inside `lib/premium/` and
  `docs/premium/`. These exist **only** in the private
  `corelix-io/pve-dedicated` repository.
- The public mirror at `corelix-io/pve-dedicated-open` is generated
  by a strip pipeline that removes those paths from the published
  history.

What this means for contributors:

- **Do NOT put premium code in public PRs.** If you have a feature
  that requires premium behavior (e.g. host LUKS, LDAP integration,
  paid backup integrations), implement it under `lib/premium/`.
- **The public build must work without `lib/premium/`.** Premium
  features must be opt-in via flags that, in the public build, trigger
  the premium gate (`premium_announce_cta`) -- a clear notice with the
  upgrade URL `https://corelix.io/pve-dedicated-premium`.
- **Do NOT reference premium internals from public docs.** Public docs
  may mention that a feature is premium and link to
  [docs/premium/luks.md](premium/luks.md) (which exists in the premium
  build), but they must not depend on premium files being present at
  install time.

### How the strip pipeline works (briefly)

The release CI maintains the public mirror by:

1. Cloning the private repository.
2. Removing `lib/premium/`, `docs/premium/`, and any file whose path
   matches a configured strip pattern (e.g. `*.private.md`).
3. Removing premium hook overrides via path-based filtering -- the
   stub implementations in `lib/providers/common.sh` (e.g.
   `premium_announce_cta`) remain and continue to provide the
   "upgrade to premium" CTA.
4. Force-pushing the cleaned tree to `corelix-io/pve-dedicated-open`.
5. Cutting a release on the public mirror that bundles only the
   public-side files.

If you are unsure whether a change belongs in the public or premium
side, ask in the PR before pushing.

## Code Style

### Bash Standards

- All scripts use `#!/usr/bin/env bash` and `set -euo pipefail`.
- All code must pass `shellcheck` with zero warnings.
- Always double-quote variable expansions: `"$VAR"`, `"${ARRAY[@]}"`.
- Use `local` for all variables inside functions.
- IPv4-only for any rescue-side `curl`/`wget`: pass `-4`.

### Naming Conventions

- **Provider hooks**: prefixed with the provider name in
  `lower_snake_case`, e.g. `hetzner_render_interfaces`,
  `ovh_compute_ipv6_gateway`.
- **Generic functions**: prefixed with the module name in
  `lower_snake_case`, e.g. `disk_detect`, `net_get_active_interface`.
- **Config variables**: `UPPER_SNAKE_CASE` prefixed with `PVE_`
  (e.g. `PVE_HOSTNAME`, `PVE_OVH_GATEWAY_MODEL`).
- **Local variables**: `lower_snake_case`.
- **Files**: `lower-kebab-case` for scripts, `UPPER-KEBAB-CASE.md` for
  reference docs, `lower-kebab-case.md` for user-facing guides.

### Module Pattern

Each `lib/*.sh` and `lib/providers/*.sh` file:

1. Starts with a one-line description comment.
2. Only defines functions (no code executed at source time).
3. Functions are prefixed with the module/provider name.
4. Returns non-zero on failure with descriptive stderr output.

Provider modules must additionally not reference each other directly --
all cross-cutting state lives in `PVE_*` variables and the dispatch
table in `lib/providers/common.sh`.

### Comments

- Only for non-obvious logic, constraints, or workarounds.
- Never narrate what the code does ("increment counter", "return
  result").
- Template files document available placeholders at the top.

## Commit Messages

Format: `type(scope): short description`

Types:

- `feat` -- new feature
- `fix` -- bug fix
- `refactor` -- code restructuring
- `docs` -- documentation only
- `test` -- test additions/changes
- `chore` -- maintenance tasks

Common scopes: `hetzner`, `ovh`, `provider`, `premium`, `qemu`,
`firstboot`, `ci`, `docs`.

The commit body should explain *why*, not *what*.

## Testing

### Running Tests

```bash
bash tests/run-all.sh
```

### Writing Tests

- Add test files under `tests/` named `test-<module>.sh`.
- Each test function should be named `test_<description>`.
- Use `assert_equals`, `assert_true` from the test helper.
- Test edge cases and error conditions.
- For new providers, add a `test-provider-<name>.sh` that exercises
  `<p>_render_interfaces` against golden fixtures under
  `tests/fixtures/<name>/`.

### Manual Testing

- Test in an actual rescue environment (Hetzner Robot rescue or OVH
  netboot rescue) when possible.
- For local development, verify individual module functions and use
  the `_render_interfaces` golden fixtures.
- Always test both interactive and unattended modes.
- For OVH, exercise both the `classic` and `scale` gateway models.

## Reporting Issues

Include:

1. Provider and server model (e.g., Hetzner AX-102, OVH SCALE-3).
2. Output of:
   - Hetzner: `predict-check` + `lsblk`.
   - OVH: `ip link show` + `ip route show` + `lsblk`.
3. The full log file from `logs/pve-install-*.log`.
4. The generated `answer.toml` (with password redacted).
5. The CLI invocation (one-liner or local script call).

## Branding

This project is branded as a Corelix.io product. When contributing:

- Do not remove or alter the "Provided freely by Corelix.io - Made in
  France" attribution.
- Do not change the project name (`pve-dedicated`) or branding in the
  UI, banner, or reports.
- Derivative works and forks must comply with the branding protection
  clause in the LICENSE.

## License

By contributing, you agree that your contributions will be licensed
under the BSD 3-Clause License with Branding Protection. See
[LICENSE](../LICENSE) for details.
