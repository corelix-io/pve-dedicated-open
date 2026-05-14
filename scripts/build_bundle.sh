#!/usr/bin/env bash
# build_bundle.sh -- Build a pve-dedicated release tarball locally.
#
# Mirrors the inline build step in .github/workflows/release.yml so you can
# produce the same bundle on your laptop, then `scp` it to a rescue shell.
#
# Usage:
#   scripts/build_bundle.sh                                 # premium, v0.0.0-dev
#   scripts/build_bundle.sh --version v3.0.2-rc1
#   scripts/build_bundle.sh --version v3.0.2 --flavor public
#   scripts/build_bundle.sh --version v3.0.2 --output /tmp
#
# Output:
#   <output>/pve-dedicated-<version>/                 (extracted tree)
#   <output>/pve-dedicated-<version>.tar.gz           (tarball ready to scp)
#
# Provided freely by Corelix.io - Made in France
# Author: Amir Moradi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="v0.0.0-dev"
FLAVOR="premium"
OUTPUT_DIR="${REPO_ROOT}/dist"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--version TAG] [--flavor premium|public] [--output DIR]

  --version TAG    Version stamped into the bundle (default: v0.0.0-dev)
  --flavor F       premium (default) keeps lib/premium/ and templates/premium/;
                   public strips them (matches the public mirror artifact).
  --output DIR     Output directory (default: ./dist)
  -h, --help       Show this help

Examples:
  # Quick dev build for SCP testing
  $(basename "$0") --version v3.0.2-dev

  # Identical to what the release workflow uploads to R2
  $(basename "$0") --version v3.0.2 --flavor premium

  # Identical to what gets pushed to the public mirror
  $(basename "$0") --version v3.0.2 --flavor public
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --flavor)  FLAVOR="${2:-}";  shift 2 ;;
        --output)  OUTPUT_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$FLAVOR" in
    premium|public) ;;
    *) echo "ERROR: --flavor must be 'premium' or 'public' (got: ${FLAVOR})" >&2; exit 2 ;;
esac

BUNDLE_NAME="pve-dedicated-${VERSION}"
STAGE="${OUTPUT_DIR}/${BUNDLE_NAME}"
TARBALL="${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"

echo "==> Repo:    ${REPO_ROOT}"
echo "==> Version: ${VERSION}"
echo "==> Flavor:  ${FLAVOR}"
echo "==> Output:  ${OUTPUT_DIR}"

mkdir -p "$STAGE"

echo "==> Staging files..."
cp "${REPO_ROOT}/pve-dedicated.sh" "$STAGE/"
cp -r "${REPO_ROOT}/lib"           "$STAGE/lib"
cp -r "${REPO_ROOT}/templates"     "$STAGE/templates"
cp -r "${REPO_ROOT}/configs"       "$STAGE/configs"
[[ -f "${REPO_ROOT}/LICENSE" ]] && cp "${REPO_ROOT}/LICENSE" "$STAGE/"
[[ -f "${REPO_ROOT}/README.md" ]] && cp "${REPO_ROOT}/README.md" "$STAGE/"

if [[ "$FLAVOR" == "public" ]]; then
    echo "==> Stripping premium content for public flavor..."
    rm -rf "$STAGE/lib/premium" || true
    rm -rf "$STAGE/templates/premium" || true
    rm -f  "$STAGE/configs/example-premium-luks.env" || true
fi

echo "==> Stamping version into lib/ui.sh: ${VERSION#v}"
sed -i "s/PVE_INSTALLER_VERSION=\".*\"/PVE_INSTALLER_VERSION=\"${VERSION#v}\"/" \
    "$STAGE/lib/ui.sh"

chmod +x "$STAGE/pve-dedicated.sh"

echo "==> Creating tarball..."
( cd "$OUTPUT_DIR" && tar czf "$(basename "$TARBALL")" "$BUNDLE_NAME/" )

ls -lh "$TARBALL"

cat <<DONE

OK: bundle built

  Tree:    ${STAGE}
  Tarball: ${TARBALL}

Next steps to test on a remote rescue shell:

  scp '${TARBALL}' root@<rescue-host>:/root/
  ssh root@<rescue-host>
    cd /root && tar xzf '$(basename "$TARBALL")' && cd '${BUNDLE_NAME}'
    ./pve-dedicated.sh --provider ovh \\
        --hostname pve1 --fqdn pve1.example.com --email admin@example.com \\
        --ssh-keys "\$(cat ~/.ssh/authorized_keys)"

Without --enable-luks, the LUKS premium path (and its license check) is
skipped entirely. The install otherwise runs the full 11-phase pipeline.
DONE
