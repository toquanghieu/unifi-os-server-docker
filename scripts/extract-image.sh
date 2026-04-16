#!/bin/bash
set -euo pipefail

# Extract UniFi OS Server base image for Docker.
#
# Usage:
#   ./scripts/extract-image.sh <output-tag> [--platform <arch>]
#
# Examples:
#   ./scripts/extract-image.sh uosserver-base:latest
#   ./scripts/extract-image.sh uosserver-base:5.0.6 --platform arm64
#
# The script queries the Ubiquiti firmware API to find the latest
# installer URL, downloads it, extracts the embedded OCI image
# using binwalk, and loads it into Docker.

FIRMWARE_API="https://fw-update.ubnt.com/api/firmware-latest"

OUTPUT_TAG="${1:?Usage: extract-image.sh <output-tag> [--platform <arch>]}"
shift

# Parse optional --platform flag
PLATFORM="$(dpkg --print-architecture 2>/dev/null || uname -m)"
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform) PLATFORM="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Normalize platform name for the API
case "$PLATFORM" in
    amd64|x86_64|x64) API_PLATFORM="linux-x64" ;;
    arm64|aarch64)     API_PLATFORM="linux-arm64" ;;
    *) echo "ERROR: Unsupported platform: $PLATFORM"; exit 1 ;;
esac

echo "==> Querying Ubiquiti firmware API for $API_PLATFORM..."
RESPONSE=$(curl -fsSL "$FIRMWARE_API?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~$API_PLATFORM&filter=eq~~channel~~release")

DOWNLOAD_URL=$(echo "$RESPONSE" | jq -r '._embedded.firmware[0]._links.data.href')
VERSION=$(echo "$RESPONSE" | jq -r '._embedded.firmware[0].version' | sed 's/^v//')

echo "==> Found version: $VERSION"
echo "==> Download URL: $DOWNLOAD_URL"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Downloading installer..."
curl -fSL -o "$WORK_DIR/installer" "$DOWNLOAD_URL"
chmod +x "$WORK_DIR/installer"

echo "==> Extracting OCI image with binwalk..."
cd "$WORK_DIR"
binwalk -e installer

# Find the image.tar in extracted files
IMAGE_TAR=$(find "$WORK_DIR" -name "image.tar" | head -1)
if [ -z "$IMAGE_TAR" ]; then
    echo "ERROR: Could not find image.tar in extracted files"
    find "$WORK_DIR" -type f -name "*.tar" 2>/dev/null
    exit 1
fi

echo "==> Found image: $IMAGE_TAR"

echo "==> Loading OCI image into podman..."
PODMAN_IMAGE=$(podman load -i "$IMAGE_TAR" 2>&1 | grep -oP 'Loaded image: \K.*' || true)

if [ -z "$PODMAN_IMAGE" ]; then
    PODMAN_IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" | head -1)
fi

echo "==> Podman image: $PODMAN_IMAGE"

echo "==> Converting to Docker archive format..."
DOCKER_TAR="$WORK_DIR/docker-image.tar"
podman save --format docker-archive -o "$DOCKER_TAR" "$PODMAN_IMAGE"

echo "==> Loading into Docker and tagging as $OUTPUT_TAG..."
docker load -i "$DOCKER_TAR"

LOADED_IMAGE=$(docker images --format "{{.ID}}" | head -1)
docker tag "$LOADED_IMAGE" "$OUTPUT_TAG"

echo "==> Done: $OUTPUT_TAG (version $VERSION)"
docker images "$OUTPUT_TAG"
