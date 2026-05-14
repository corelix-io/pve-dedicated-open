#!/usr/bin/env bash
# pve-dedicated -- Bootstrap one-liner
# Downloads the latest release bundle and runs the installer.
#
# PUBLIC build (one-liner, no auth):
#   curl -4fsSL https://github.com/corelix-io/pve-dedicated-public/releases/latest/download/install.sh | bash
#
# PREMIUM build (private source repo, requires a fine-grained PAT with
# Contents: Read on the repo, exposed as the GITHUB_TOKEN env var):
#   export GITHUB_TOKEN="github_pat_..."
#   curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
#       https://raw.githubusercontent.com/corelix-io/pve-dedicated/main/install.sh \
#       | bash -s -- --provider ovh --enable-luks --unattended --config myserver.env
#
# The PAT is forwarded into bash's environment so the asset download below
# can authenticate against api.github.com.
#
# Provided freely by Corelix.io - Made in France
# Author: Amir Moradi
set -euo pipefail

# Source repo. Override with PVE_DEDICATED_REPO=owner/repo.
# - Public mirror:  corelix-io/pve-dedicated-public
# - Private source: corelix-io/pve-dedicated  (premium; requires GITHUB_TOKEN)
REPO="${PVE_DEDICATED_REPO:-corelix-io/pve-dedicated-public}"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

# Auth header used for all GitHub API/asset calls when GITHUB_TOKEN is set.
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: token ${GITHUB_TOKEN}")
fi

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  pve-dedicated -- Proxmox VE Installer (Hetzner | OVH)  ║"
echo "  ║  Provided freely by Corelix.io - Made in France         ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "  Auth: GITHUB_TOKEN present (private/premium build mode)"
else
    echo "  Auth: anonymous (public build mode)"
fi

cd /root

echo "  Discovering latest release of ${REPO}..."
RELEASE_JSON="$(curl -4fsSL "${AUTH_HEADER[@]}" "$API_URL" 2>/dev/null || true)"

if [[ -z "$RELEASE_JSON" ]] || ! echo "$RELEASE_JSON" | grep -q '"tag_name"'; then
    echo ""
    echo "  ERROR: Could not fetch release info from ${API_URL}"
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "  Hint: For the private/premium repo, set GITHUB_TOKEN to a"
        echo "        fine-grained PAT with 'Contents: Read' on ${REPO}, then re-run."
    else
        echo "  Hint: Token may be expired, scoped wrong, or lack access to ${REPO}."
    fi
    exit 1
fi

TAG="$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name": *"//;s/".*//')"
echo "  Latest version: ${TAG}"
BUNDLE="pve-dedicated-${TAG}"

# Private repo asset downloads MUST go through the asset API URL with
# Accept: application/octet-stream. Browser download URLs (github.com/.../
# releases/download/...) issue an S3 redirect that drops the auth header.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  Installing python3 (required for private asset URL extraction)..."
        apt-get -qq update >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -yq install python3 >/dev/null 2>&1 \
            || { echo "  ERROR: python3 not available, cannot parse release JSON"; exit 1; }
    fi
    ASSET_API_URL="$(ASSET_NAME="${BUNDLE}.tar.gz" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
target = os.environ["ASSET_NAME"]
for a in d.get("assets", []):
    if a["name"] == target:
        print(a["url"]); break
' <<< "$RELEASE_JSON")"
    if [[ -z "$ASSET_API_URL" ]]; then
        echo "  ERROR: Asset ${BUNDLE}.tar.gz not found in release ${TAG}"
        echo "  Available assets:"
        echo "$RELEASE_JSON" | python3 -c "
import json, sys
for a in json.load(sys.stdin).get('assets', []):
    print('   -', a['name'])
" 2>/dev/null || true
        exit 1
    fi
    echo "  Downloading (authenticated asset API)..."
    curl -4fsSL "${AUTH_HEADER[@]}" -H "Accept: application/octet-stream" \
        -o pve-dedicated.tar.gz "$ASSET_API_URL" || {
        echo "  ERROR: Authenticated download failed (asset URL rejected)."
        exit 1
    }
else
    BUNDLE_URL="https://github.com/${REPO}/releases/download/${TAG}/${BUNDLE}.tar.gz"
    echo "  Downloading: ${BUNDLE_URL}"
    curl -4fsSL -o pve-dedicated.tar.gz "$BUNDLE_URL" || {
        echo "  ERROR: Download failed."
        echo "  Hint: If ${REPO} is private, export GITHUB_TOKEN and re-run."
        exit 1
    }
fi

echo "  Extracting..."
tar xzf pve-dedicated.tar.gz
rm -f pve-dedicated.tar.gz

cd "${BUNDLE}"

echo "  Starting installer..."
echo ""

# Reconnect stdin to the terminal so interactive prompts work
# (when invoked via 'curl | bash', stdin is the pipe, not the terminal)
exec bash pve-dedicated.sh "$@" </dev/tty
