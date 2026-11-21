#!/usr/bin/env bash
# pve-dedicated -- Bootstrap one-liner
# Downloads the latest release bundle, verifies it, and runs the installer.
#
# PUBLIC build (one-liner, no auth):
#   curl -4fsSL https://github.com/corelix-io/pve-dedicated-open/releases/latest/download/install.sh | bash
#
# PREMIUM build (private source repo, requires a fine-grained PAT with
# Contents: Read on the repo, exposed as the GITHUB_TOKEN env var):
#   export GITHUB_TOKEN="github_pat_..."
#   curl -4fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
#       https://raw.githubusercontent.com/corelix-io/pve-dedicated/main/install.sh \
#       | bash -s -- --provider ovh --enable-luks --unattended --config myserver.env
#
# Environment:
#   PVE_DEDICATED_REPO     owner/repo to install from (default below)
#   PVE_DEDICATED_VERSION  release tag to install (default: latest)
#   PVE_DEDICATED_DIR      where to unpack (default: /root)
#   GITHUB_TOKEN           PAT for private repositories
#
# Provided freely by Corelix.io - Made in France
# Author: Amir Moradi
set -euo pipefail

# - Public mirror:  corelix-io/pve-dedicated-open
# - Private source: corelix-io/pve-dedicated  (premium; requires GITHUB_TOKEN)
REPO="${PVE_DEDICATED_REPO:-corelix-io/pve-dedicated-open}"
VERSION="${PVE_DEDICATED_VERSION:-latest}"
INSTALL_DIR="${PVE_DEDICATED_DIR:-/root}"

if [[ "$VERSION" == "latest" ]]; then
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
else
    API_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
fi

CURL=(curl -4 -fsSL --retry 3 --connect-timeout 20 --proto '=https')
API_HEADERS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

fail() {
    echo "" >&2
    echo "  ERROR: $*" >&2
    exit 1
}

# Echo the asset API URL for NAME from a GitHub release JSON document.
# Pure sed/awk so the rescue system needs neither python3 nor jq. Each asset
# object lists its API "url" before its "name"; nested uploader URLs point at
# /users/ and are ignored.
asset_api_url() {
    local json="$1" name="$2"
    sed -e 's/"url": *"/\n&/g' -e 's/"name": *"/\n&/g' <<< "$json" \
        | awk -v want="$name" '
            /^"url": *"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]+"/ {
                match($0, /https:[^"]*/); last = substr($0, RSTART, RLENGTH)
            }
            /^"name": *"/ {
                v = $0; sub(/^"name": *"/, "", v); sub(/".*/, "", v)
                if (v == want && last != "") { print last; exit }
            }'
}

download_asset() {
    local name="$1" out="$2"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        # Private repos: browser download URLs redirect to S3 and drop the
        # auth header, so go through the asset API with octet-stream.
        local url
        url="$(asset_api_url "$RELEASE_JSON" "$name")"
        [[ -n "$url" ]] || return 1
        "${CURL[@]}" "${AUTH_HEADER[@]}" -H "Accept: application/octet-stream" -o "$out" "$url"
    else
        "${CURL[@]}" -o "$out" "https://github.com/${REPO}/releases/download/${TAG}/${name}"
    fi
}

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  pve-dedicated -- Proxmox VE Installer (Hetzner | OVH)   ║"
echo "  ║  Provided freely by Corelix.io - Made in France          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "  Auth: GITHUB_TOKEN present (private/premium build mode)"
else
    echo "  Auth: anonymous (public build mode)"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "  Resolving ${VERSION} release of ${REPO}..."
RELEASE_JSON="$("${CURL[@]}" "${API_HEADERS[@]}" "${AUTH_HEADER[@]}" "$API_URL" 2>/dev/null || true)"
if [[ -z "$RELEASE_JSON" ]] || ! grep -q '"tag_name"' <<< "$RELEASE_JSON"; then
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        fail "Could not fetch release info from ${API_URL}
         Hint: for the private/premium repo, set GITHUB_TOKEN to a fine-grained
         PAT with 'Contents: Read' on ${REPO}, then re-run."
    fi
    fail "Could not fetch release info from ${API_URL}
         Hint: the token may be expired, scoped wrong, or lack access to ${REPO}."
fi

TAG="$(grep -o '"tag_name": *"[^"]*"' <<< "$RELEASE_JSON" | head -n1 | sed 's/.*: *"//; s/"$//')"
[[ "$TAG" =~ ^v[0-9A-Za-z.+-]+$ ]] || fail "Unexpected release tag: '${TAG}'"
echo "  Version: ${TAG}"
BUNDLE="pve-dedicated-${TAG}"

WORK="$(mktemp -d "${INSTALL_DIR}/.pve-dedicated-download.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "  Downloading ${BUNDLE}.tar.gz..."
download_asset "${BUNDLE}.tar.gz" "${WORK}/${BUNDLE}.tar.gz" \
    || fail "Download of ${BUNDLE}.tar.gz failed (private repo? export GITHUB_TOKEN)."

if download_asset "SHA256SUMS" "${WORK}/SHA256SUMS" 2>/dev/null; then
    ( cd "$WORK" && awk -v f="${BUNDLE}.tar.gz" '$2 == f || $2 == "*" f' SHA256SUMS \
        | grep -q . && awk -v f="${BUNDLE}.tar.gz" '$2 == f || $2 == "*" f' SHA256SUMS | sha256sum -c --quiet - ) \
        || fail "Checksum verification of ${BUNDLE}.tar.gz FAILED -- refusing to run it."
    echo "  Checksum verified (SHA-256)."
else
    echo "  WARNING: release has no SHA256SUMS asset; skipping bundle verification."
fi

echo "  Extracting..."
rm -rf "${INSTALL_DIR:?}/${BUNDLE}"
tar -xzf "${WORK}/${BUNDLE}.tar.gz" -C "$INSTALL_DIR" --no-same-owner
cd "${INSTALL_DIR}/${BUNDLE}"

echo "  Starting installer..."
echo ""

# Under `curl | bash` stdin is the pipe; reattach the terminal so prompts
# work. Without a usable terminal (CI, nohup) run with stdin as-is.
if { : </dev/tty; } 2>/dev/null; then
    exec bash pve-dedicated.sh "$@" </dev/tty
fi
exec bash pve-dedicated.sh "$@"
