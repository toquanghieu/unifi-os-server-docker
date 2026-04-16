#!/bin/bash
# Update UniFi Network application to a specific or latest version.
# Usage: update-network.sh [version]
#   version: e.g. "8.5.6", or "latest" (default)
#
# Can also be driven by the UNIFI_NETWORK_VERSION environment variable.

set -e

TARGET="${UNIFI_NETWORK_VERSION:-${1:-latest}}"

# ---- helpers ----------------------------------------------------------------

installed_version() {
    dpkg -s unifi 2>/dev/null | grep '^Version:' | awk '{print $2}' || true
}

latest_version() {
    # 1. Try apt (repo already configured by UOS)
    local apt_ver
    apt_ver=$(apt-cache policy unifi 2>/dev/null | grep 'Candidate:' | awk '{print $2}')
    if [ -n "$apt_ver" ] && [ "$apt_ver" != "(none)" ]; then
        echo "$apt_ver"
        return
    fi

    # 2. Try Ubiquiti firmware API (unifi-network-server product)
    local api_ver
    api_ver=$(curl -fsSL \
        "https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-network-server&filter=eq~~channel~~release" \
        2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['_embedded']['firmware'][0]['version'].lstrip('v'))" \
        2>/dev/null || true)
    if [ -n "$api_ver" ]; then
        echo "$api_ver"
        return
    fi

    echo ""
}

# ---- resolve target version -------------------------------------------------

CURRENT=$(installed_version)
echo "Installed UniFi Network version: ${CURRENT:-none}"

if [ "$TARGET" = "latest" ]; then
    echo "Querying latest version..."
    TARGET=$(latest_version)
    if [ -z "$TARGET" ]; then
        echo "ERROR: Could not determine latest version."
        echo "  - Check internet connectivity from the container"
        echo "  - Or pass an explicit version: update-network.sh 8.5.6"
        exit 1
    fi
fi

echo "Target version: $TARGET"

if [ "$CURRENT" = "$TARGET" ]; then
    echo "Already on $TARGET — nothing to do."
    exit 0
fi

# ---- install ----------------------------------------------------------------

# Try apt first (fastest, handles deps automatically)
APT_CANDIDATE=$(apt-cache policy unifi 2>/dev/null | grep "Candidate:" | awk '{print $2}')
if [ "$APT_CANDIDATE" = "$TARGET" ]; then
    echo "Installing via apt..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "unifi=$TARGET"
else
    # Direct .deb download from Ubiquiti CDN
    DEB_URL="https://dl.ui.com/unifi/${TARGET}/unifi_sysvinit_all.deb"
    echo "Downloading: $DEB_URL"
    curl -fSL -o /tmp/unifi-update.deb "$DEB_URL"
    echo "Installing .deb..."
    DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/unifi-update.deb || true
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y
    rm -f /tmp/unifi-update.deb
fi

# ---- report -----------------------------------------------------------------

NEW=$(installed_version)
echo "UniFi Network is now: ${NEW}"

# Restart the service if systemd is already running (i.e. called post-boot)
if [ "$$" != "1" ] && pidof systemd > /dev/null 2>&1; then
    echo "Restarting unifi service..."
    systemctl restart unifi || true
fi
