# UniFi OS Server Docker Image - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish a public multi-arch Docker image (`hieutq/unifi-os-server`) that repackages the official UniFi OS Server with a single volume mount, capability-based security, and automated CI/CD.

**Architecture:** Extract the official OCI image from Ubiquiti's installer binary, convert to Docker format, overlay a thin Dockerfile with a custom entrypoint that manages volume symlinks and systemd init. Automated GitHub Actions pipeline handles extraction, multi-arch build, and Docker Hub publishing.

**Tech Stack:** Docker, Docker Buildx, Podman, binwalk, GitHub Actions, Bash

---

## File Structure

| File | Responsibility |
|---|---|
| `Dockerfile` | Thin overlay on extracted base image: labels, env vars, entrypoint |
| `docker-compose.yml` | Ready-to-use deployment with single volume, security caps, ports |
| `.env.example` | Example environment variables for user configuration |
| `scripts/entrypoint.sh` | Container init: volume symlinks, UUID, network, service dirs, systemd launch |
| `scripts/extract-image.sh` | CI script: download installer, extract OCI image, convert to Docker format |
| `.github/workflows/build.yml` | CI: extract, build multi-arch image, push to Docker Hub |
| `.github/workflows/check-update.yml` | CI: weekly version check, auto-trigger build on new release |
| `LICENSE` | MIT license |
| `README.md` | Usage documentation |
| `.dockerignore` | Exclude non-build files from Docker context |
| `.gitignore` | Ignore build artifacts and local data |

---

### Task 1: Repository Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `.dockerignore`
- Create: `LICENSE`
- Create: `.env.example`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Build artifacts
*.tar
*.tar.gz
_binwalk*/
build/

# Local data
unifi/

# OS files
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/
```

- [ ] **Step 2: Create `.dockerignore`**

```dockerignore
.git
.github
docs
*.md
*.tar
*.tar.gz
_binwalk*/
build/
unifi/
.env
.env.example
LICENSE
.gitignore
```

- [ ] **Step 3: Create `LICENSE`**

Create an MIT license file with copyright holder `hieutq` and year `2026`.

- [ ] **Step 4: Create `.env.example`**

```env
# Required: hostname or IP address for device adoption
# Devices use this address to connect back to the controller
UOS_SYSTEM_IP=unifi.example.com

# Optional: set a fixed UUID for this instance
# If not set, a UUID is auto-generated on first run and persisted
# UOS_UUID=
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore .dockerignore LICENSE .env.example
git commit -m "chore: add repository scaffolding files"
```

---

### Task 2: Entrypoint Script

**Files:**
- Create: `scripts/entrypoint.sh`

- [ ] **Step 1: Create `scripts/entrypoint.sh`**

```bash
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
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" == "amd64" ]; then
    FIRMWARE_PLATFORM=linux-x64
elif [ "$ARCH" == "arm64" ]; then
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
            sed -i "s/^system_ip=.*/system_ip=$UOS_SYSTEM_IP/" "$UNIFI_SYSTEM_PROPERTIES"
        else
            echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
        fi
    fi
fi

# --- Launch systemd ---
exec /sbin/init
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/entrypoint.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/entrypoint.sh
git commit -m "feat: add entrypoint script with volume symlinks and systemd init"
```

---

### Task 3: Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Create `Dockerfile`**

```dockerfile
ARG BASE_IMAGE=uosserver-base:latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/hieutq/unifi-os-server-docker"
LABEL org.opencontainers.image.description="UniFi OS Server for Docker"
LABEL org.opencontainers.image.licenses="MIT"

ARG UOS_SERVER_VERSION=5.0.6
ENV UOS_SERVER_VERSION=${UOS_SERVER_VERSION}

STOPSIGNAL SIGRTMIN+3

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

Note: `BASE_IMAGE` is a build arg passed by CI after extracting the official image. For local builds, users must first extract and tag the base image.

- [ ] **Step 2: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile with build-arg base image and entrypoint"
```

---

### Task 4: Docker Compose

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Create `docker-compose.yml`**

```yaml
services:
  unifi-os-server:
    image: hieutq/unifi-os-server:latest
    container_name: unifi-os-server
    cgroup: host
    cap_add:
      - NET_RAW
      - NET_ADMIN
      - SYS_ADMIN
    cap_drop:
      - ALL
    tmpfs:
      - /run:exec
      - /run/lock
      - /tmp:exec
      - /var/lib/journal
      - /var/opt/unifi/tmp:size=64m
    environment:
      - UOS_SYSTEM_IP=${UOS_SYSTEM_IP:-}
      - UOS_UUID=${UOS_UUID:-}
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - ./unifi:/unifi
    ports:
      - "11443:443"        # GUI/API
      - "8080:8080"        # Device communication
      - "3478:3478/udp"    # STUN
      - "10003:10003/udp"  # Device discovery
      # Optional - uncomment as needed:
      # - "8443:8443"      # Network app GUI
      # - "8444:8444"      # Hotspot portal
      # - "5514:5514/udp"  # Syslog
      # - "6789:6789"      # Mobile speed test
      # - "5005:5005"      # RTP
      # - "9543:9543"      # Identity Hub
      # - "11084:11084"    # Site Supervisor
      # - "5671:5671"      # AMQPS
      # - "8880:8880"      # Hotspot redirect (HTTP)
      # - "8881:8881"      # Hotspot redirect (HTTP)
      # - "8882:8882"      # Hotspot redirect (HTTP)
    restart: unless-stopped
```

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose with single volume and capability-based security"
```

---

### Task 5: Image Extraction Script

**Files:**
- Create: `scripts/extract-image.sh`

- [ ] **Step 1: Create `scripts/extract-image.sh`**

This script is run in CI to download the UniFi OS Server installer, extract the OCI image, and convert it to Docker format.

```bash
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
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/extract-image.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/extract-image.sh
git commit -m "feat: add image extraction script for CI pipeline"
```

---

### Task 6: Build Workflow

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Create `.github/workflows/build.yml`**

```yaml
name: Build and Push

on:
  push:
    branches: [main]
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      version:
        description: "UOS Server version to build"
        required: false
        default: ""

env:
  DOCKER_IMAGE: hieutq/unifi-os-server

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - arch: amd64
            platform: linux/amd64
            installer_suffix: x64
          - arch: arm64
            platform: linux/arm64
            installer_suffix: arm64

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Determine version
        id: version
        run: |
          if [ -n "${{ github.event.inputs.version }}" ]; then
            echo "version=${{ github.event.inputs.version }}" >> "$GITHUB_OUTPUT"
          else
            echo "version=$(grep -oP 'UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile)" >> "$GITHUB_OUTPUT"
          fi

      - name: Install extraction tools
        run: |
          sudo apt-get update
          sudo apt-get install -y binwalk podman

      - name: Download and extract base image
        run: |
          # Fetch the installer URL for this architecture
          INSTALLER_URL="https://fw-download.ubnt.com/data/unifi-os-server/0a39-uosserver-${{ steps.version.outputs.version }}-${{ matrix.installer_suffix }}.bin"
          ./scripts/extract-image.sh "$INSTALLER_URL" "uosserver-base:${{ steps.version.outputs.version }}-${{ matrix.arch }}"

      - name: Save extracted base image
        run: |
          docker save "uosserver-base:${{ steps.version.outputs.version }}-${{ matrix.arch }}" \
            -o base-image-${{ matrix.arch }}.tar

      - name: Upload base image artifact
        uses: actions/upload-artifact@v4
        with:
          name: base-image-${{ matrix.arch }}
          path: base-image-${{ matrix.arch }}.tar
          retention-days: 1

  push:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Determine version
        id: version
        run: |
          if [ -n "${{ github.event.inputs.version }}" ]; then
            echo "version=${{ github.event.inputs.version }}" >> "$GITHUB_OUTPUT"
          else
            echo "version=$(grep -oP 'UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile)" >> "$GITHUB_OUTPUT"
          fi

      - name: Download all base image artifacts
        uses: actions/download-artifact@v4

      - name: Load base images
        run: |
          docker load -i base-image-amd64/base-image-amd64.tar
          docker load -i base-image-arm64/base-image-arm64.tar

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push multi-arch image
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          build-args: |
            BASE_IMAGE=uosserver-base:${{ steps.version.outputs.version }}
            UOS_SERVER_VERSION=${{ steps.version.outputs.version }}
          tags: |
            ${{ env.DOCKER_IMAGE }}:latest
            ${{ env.DOCKER_IMAGE }}:${{ steps.version.outputs.version }}

      - name: Create GitHub Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
```

Note: The installer URL pattern (`0a39-uosserver-...`) may need adjustment based on the actual Ubiquiti firmware download URL format. The `check-update.yml` workflow (Task 7) will discover the actual URL.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: add multi-arch build and push workflow"
```

---

### Task 7: Version Check Workflow

**Files:**
- Create: `.github/workflows/check-update.yml`

- [ ] **Step 1: Create `.github/workflows/check-update.yml`**

```yaml
name: Check for Updates

on:
  schedule:
    - cron: "0 6 * * 1" # Every Monday at 06:00 UTC
  workflow_dispatch:

permissions:
  contents: write

env:
  DOCKER_IMAGE: hieutq/unifi-os-server

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Get current version from Dockerfile
        id: current
        run: |
          VERSION=$(grep -oP 'UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile)
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "Current version: $VERSION"

      - name: Check latest version from Ubiquiti
        id: latest
        run: |
          # Query Ubiquiti firmware API for latest version
          # The firmware page lists available downloads; parse for the latest version
          LATEST=$(curl -fsSL "https://fw-download.ubnt.com/data/unifi-os-server" \
            | grep -oP 'uosserver-\K[0-9]+\.[0-9]+\.[0-9]+' \
            | sort -V \
            | tail -1 || echo "")

          if [ -z "$LATEST" ]; then
            echo "WARNING: Could not determine latest version, skipping"
            echo "skip=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          echo "version=$LATEST" >> "$GITHUB_OUTPUT"
          echo "Latest version: $LATEST"

      - name: Compare versions
        id: compare
        if: steps.latest.outputs.skip != 'true'
        run: |
          CURRENT="${{ steps.current.outputs.version }}"
          LATEST="${{ steps.latest.outputs.version }}"

          if [ "$CURRENT" = "$LATEST" ]; then
            echo "Already up to date ($CURRENT)"
            echo "update=false" >> "$GITHUB_OUTPUT"
          else
            echo "New version available: $CURRENT -> $LATEST"
            echo "update=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Update Dockerfile version
        if: steps.compare.outputs.update == 'true'
        run: |
          LATEST="${{ steps.latest.outputs.version }}"
          sed -i "s/UOS_SERVER_VERSION=[0-9.]*/UOS_SERVER_VERSION=$LATEST/" Dockerfile

      - name: Commit and tag
        if: steps.compare.outputs.update == 'true'
        run: |
          LATEST="${{ steps.latest.outputs.version }}"
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Dockerfile
          git commit -m "chore: bump UOS Server version to $LATEST"
          git tag "v$LATEST"
          git push origin main --tags

      - name: Trigger build workflow
        if: steps.compare.outputs.update == 'true'
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.actions.createWorkflowDispatch({
              owner: context.repo.owner,
              repo: context.repo.repo,
              workflow_id: 'build.yml',
              ref: 'main',
              inputs: {
                version: '${{ steps.latest.outputs.version }}'
              }
            });
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/check-update.yml
git commit -m "ci: add weekly version check with auto-trigger build"
```

---

### Task 8: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

```markdown
# UniFi OS Server - Docker

[![Build and Push](https://github.com/hieutq/unifi-os-server-docker/actions/workflows/build.yml/badge.svg)](https://github.com/hieutq/unifi-os-server-docker/actions/workflows/build.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/hieutq/unifi-os-server)](https://hub.docker.com/r/hieutq/unifi-os-server)

Run [UniFi OS Server](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi) in Docker with a single volume mount and without privileged mode.

## Quick Start

1. Clone and configure:

```bash
git clone https://github.com/hieutq/unifi-os-server-docker.git
cd unifi-os-server-docker
cp .env.example .env
# Edit .env and set UOS_SYSTEM_IP to your server's hostname or IP
```

2. Start the container:

```bash
docker compose up -d
```

3. Access the management UI at `https://<your-server-ip>:11443`

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `UOS_SYSTEM_IP` | Yes | Hostname or IP for device adoption |
| `UOS_UUID` | No | Fixed UUID (auto-generated if not set) |

## Ports

| Protocol | Port | Description |
|---|---|---|
| TCP | 11443 | GUI/API (mapped from container port 443) |
| TCP | 8080 | Device communication |
| UDP | 3478 | STUN |
| UDP | 10003 | Device discovery |

Additional optional ports can be enabled in `docker-compose.yml`:
8443, 8444, 5514/udp, 6789, 5005, 9543, 11084, 5671, 8880, 8881, 8882

## Data Persistence

All data is stored in a single `./unifi` directory, organized as:

| Subdirectory | Contents |
|---|---|
| `data/` | Application data |
| `db/` | MongoDB database files |
| `config/` | UniFi configuration |
| `logs/` | Service logs |
| `srv/` | Service-specific data |
| `persistent/` | Package manager state |
| `rabbitmq-ssl/` | RabbitMQ SSL certificates |

## Device Adoption

1. SSH into the UniFi device (default credentials: `ubnt`/`ubnt`)
2. Set the inform URL:

```bash
set-inform http://<UOS_SYSTEM_IP>:8080/inform
```

## Security

This image avoids `privileged: true`. Instead it uses:

- `cap_drop: ALL` as baseline
- Only `NET_RAW`, `NET_ADMIN`, `SYS_ADMIN` capabilities added
- `cgroup: host` (required for systemd)

## Building Locally

To build the image locally, you need to first extract the base image from the official installer:

```bash
# Download the installer from Ubiquiti
# Then extract and build:
./scripts/extract-image.sh <installer-path-or-url> uosserver-base:latest
docker build --build-arg BASE_IMAGE=uosserver-base:latest -t hieutq/unifi-os-server:local .
```

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage instructions"
```

---

### Task 9: Final Review and Tag

- [ ] **Step 1: Verify all files exist**

```bash
ls -la Dockerfile docker-compose.yml .env.example LICENSE README.md .gitignore .dockerignore
ls -la scripts/entrypoint.sh scripts/extract-image.sh
ls -la .github/workflows/build.yml .github/workflows/check-update.yml
```

Expected: All 10 files listed without errors.

- [ ] **Step 2: Validate docker-compose syntax**

```bash
docker compose config --quiet
```

Expected: No output (valid syntax). If `docker compose` is not available locally, this can be skipped - CI will validate.

- [ ] **Step 3: Validate Dockerfile syntax**

```bash
docker build --check . 2>&1 || echo "Dockerfile syntax check requires BuildKit 0.15+ - skip if not available"
```

- [ ] **Step 4: Validate workflow YAML syntax**

```bash
python3 -c "
import yaml, sys
for f in ['.github/workflows/build.yml', '.github/workflows/check-update.yml']:
    with open(f) as fh:
        yaml.safe_load(fh)
    print(f'{f}: valid YAML')
"
```

Expected: Both files report valid YAML.

- [ ] **Step 5: Tag initial release**

```bash
git tag v5.0.6
```

- [ ] **Step 6: Final commit (if any uncommitted changes remain)**

```bash
git status
# If clean: no action needed
# If changes: git add -A && git commit -m "chore: final cleanup"
```
