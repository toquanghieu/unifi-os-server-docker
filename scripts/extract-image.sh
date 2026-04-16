#!/bin/bash
set -euo pipefail

# Usage: ./scripts/extract-image.sh <installer-url> <output-tag>
# Example: ./scripts/extract-image.sh https://fw-download.ubnt.com/data/unifi-os-server/... uosserver-base:5.0.6-amd64

INSTALLER_URL="${1:?Usage: extract-image.sh <installer-url> <output-tag>}"
OUTPUT_TAG="${2:?Usage: extract-image.sh <installer-url> <output-tag>}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Downloading installer from $INSTALLER_URL"
curl -fSL -o "$WORK_DIR/installer" "$INSTALLER_URL"
chmod +x "$WORK_DIR/installer"

echo "==> Extracting OCI image with binwalk"
cd "$WORK_DIR"
binwalk --run-as=root -e installer

# Find the OCI tar archive in extracted files
OCI_TAR=$(find "$WORK_DIR" -name "*.tar" -path "*/_installer.extracted/*" | head -1)
if [ -z "$OCI_TAR" ]; then
    echo "ERROR: Could not find OCI tar in extracted files"
    ls -lR "$WORK_DIR/_installer.extracted/" || true
    exit 1
fi

echo "==> Found OCI image: $OCI_TAR"

echo "==> Loading OCI image into podman"
PODMAN_IMAGE=$(podman load -i "$OCI_TAR" 2>&1 | grep -oP 'Loaded image: \K.*' || true)

if [ -z "$PODMAN_IMAGE" ]; then
    # Fallback: list images and pick the most recent
    PODMAN_IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" | head -1)
fi

echo "==> Podman image: $PODMAN_IMAGE"

echo "==> Converting to Docker archive format"
DOCKER_TAR="$WORK_DIR/docker-image.tar"
podman save --format docker-archive -o "$DOCKER_TAR" "$PODMAN_IMAGE"

echo "==> Loading into Docker and tagging as $OUTPUT_TAG"
docker load -i "$DOCKER_TAR"

# Get the loaded image ID
LOADED_IMAGE=$(docker images --format "{{.ID}}" | head -1)
docker tag "$LOADED_IMAGE" "$OUTPUT_TAG"

echo "==> Done: $OUTPUT_TAG"
docker images "$OUTPUT_TAG"
