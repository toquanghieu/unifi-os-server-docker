#!/bin/bash
set -e

# --- Volume Symlinks ---
# Move existing content to /unifi subdirectories and symlink back.
# This lets us expose a single /unifi volume while internal services
# find their files at the expected paths.

declare -A SYMLINK_MAP=(
    ["/data"]="/unifi/data"
    ["/var/lib/mongodb"]="/unifi/db"
    ["/var/lib/unifi"]="/unifi/config"
    ["/var/log"]="/unifi/logs"
    ["/srv"]="/unifi/srv"
    ["/persistent"]="/unifi/persistent"
    ["/etc/rabbitmq/ssl"]="/unifi/rabbitmq-ssl"
)

for ORIG in "${!SYMLINK_MAP[@]}"; do
    TARGET="${SYMLINK_MAP[$ORIG]}"

    # Create target dir if it doesn't exist
    mkdir -p "$TARGET"

    # If original is a real directory (not already a symlink), seed target
    if [ -d "$ORIG" ] && [ ! -L "$ORIG" ]; then
        # Copy existing content to target (don't overwrite existing files)
        cp -a --no-clobber "$ORIG/." "$TARGET/" 2>/dev/null || true
        rm -rf "$ORIG"
    fi

    # Create parent dir if needed and symlink
    mkdir -p "$(dirname "$ORIG")"
    ln -sfn "$TARGET" "$ORIG"

    # Ensure target dir is writable
    chmod 755 "$TARGET"
done

# --- UUID Management ---
if [ ! -f /unifi/data/uos_uuid ]; then
    if [ -n "${UOS_UUID+1}" ]; then
        echo "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /unifi/data/uos_uuid
    else
        echo "No UOS_UUID provided, generating..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        # Spoof a v5 UUID
        UOS_UUID=$(echo "$UUID" | sed 's/./5/15')
        echo "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /unifi/data/uos_uuid
    fi
fi

# --- Architecture Detection ---
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [ "$ARCH" == "amd64" ] || [ "$ARCH" == "x86_64" ]; then
    FIRMWARE_PLATFORM=linux-x64
elif [ "$ARCH" == "arm64" ] || [ "$ARCH" == "aarch64" ]; then
    FIRMWARE_PLATFORM=arm64
else
    echo "ERROR: Unsupported architecture: $ARCH"
    exit 1
fi
echo "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# --- Version Stamp ---
echo "Setting UOS_SERVER_VERSION to $UOS_SERVER_VERSION"
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version

# --- Network Setup ---
# Create eth0 macvlan alias from tap0 if needed (requires NET_ADMIN)
if [ ! -d "/sys/devices/virtual/net/eth0" ] && [ -d "/sys/devices/virtual/net/tap0" ]; then
    ip link add name eth0 link tap0 type macvlan
    ip link set eth0 up
fi

# --- Service Directories ---
# Initialize log and lib dirs with correct ownership

for DIR_SPEC in "nginx:nginx:nginx:/var/log/nginx" \
                "mongodb:mongodb:mongodb:/var/log/mongodb" \
                "rabbitmq:rabbitmq:rabbitmq:/var/log/rabbitmq"; do
    IFS=':' read -r NAME OWNER GROUP DIR <<< "$DIR_SPEC"
    if [ ! -d "$DIR" ]; then
        mkdir -p "$DIR"
        chown "$OWNER:$GROUP" "$DIR"
        chmod 755 "$DIR"
    fi
done

# Fix mongodb lib ownership
chown -R mongodb:mongodb /var/lib/mongodb

# --- System IP ---
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
if [ -n "${UOS_SYSTEM_IP+1}" ] && [ -n "$UOS_SYSTEM_IP" ]; then
    echo "Setting UOS_SYSTEM_IP to $UOS_SYSTEM_IP"
    if [ ! -f "$UNIFI_SYSTEM_PROPERTIES" ]; then
        mkdir -p "$(dirname "$UNIFI_SYSTEM_PROPERTIES")"
        echo "system_ip=$UOS_SYSTEM_IP" > "$UNIFI_SYSTEM_PROPERTIES"
    else
        if grep -q "^system_ip=.*" "$UNIFI_SYSTEM_PROPERTIES"; then
            TMP_FILE=$(mktemp /tmp/system.properties.XXXXXX)
            sed "s/^system_ip=.*/system_ip=$UOS_SYSTEM_IP/" "$UNIFI_SYSTEM_PROPERTIES" > "$TMP_FILE"
            cat "$TMP_FILE" > "$UNIFI_SYSTEM_PROPERTIES"
            rm -f "$TMP_FILE"
        else
            echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
        fi
    fi
fi

# --- Launch systemd ---
exec /sbin/init
