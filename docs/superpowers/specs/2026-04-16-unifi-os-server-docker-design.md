# UniFi OS Server Docker Image - Design Spec

## Goal

Build a public Docker image (`hieutq/unifi-os-server`) that packages the official Ubiquiti UniFi OS Server for easy self-hosting with Docker. The image is published to Docker Hub, supports multi-arch (amd64/arm64), uses a single volume mount for data persistence, and avoids privileged mode.

## Background

Ubiquiti distributes UniFi OS Server as a binary installer embedding a Podman/OCI container image. It runs ~10 microservices (MongoDB, PostgreSQL, RabbitMQ, Nginx, UniFi Core, etc.) orchestrated by systemd. There is one existing open-source project (lemker/unifi-os-server) that repackages this for Docker, but it uses 7 volume mounts, runs in privileged mode, and only publishes to GHCR.

## Architecture

### Overview

The build pipeline extracts the official OCI image from Ubiquiti's installer binary, converts it to Docker format, and layers a thin Dockerfile on top that adds an entrypoint script. The entrypoint manages volume symlinks, UUID persistence, network setup, and launches systemd as PID 1.

### Repository Structure

```
unifi-os-server-docker/
├── Dockerfile
├── docker-compose.yml
├── scripts/
│   ├── extract-image.sh
│   └── entrypoint.sh
├── .github/
│   └── workflows/
│       ├── build.yml
│       └── check-update.yml
├── .env.example
├── LICENSE
└── README.md
```

## Image Extraction & Build Pipeline

### Extraction Flow (CI)

1. GitHub Actions runs on push to `main`, tag push, or manual dispatch
2. Downloads the latest UniFi OS Server installer from Ubiquiti's firmware endpoint
3. `extract-image.sh` uses `binwalk` to extract the embedded OCI tarball
4. `podman load` imports the OCI image
5. `podman save --format docker-archive` converts to Docker format
6. `docker load` imports the converted image as the base
7. `Dockerfile` builds on top, adding entrypoint and config

### Version Detection (check-update.yml)

1. Runs weekly on cron schedule + manual dispatch
2. Fetches latest version from Ubiquiti firmware API
3. Compares against latest git tag in the repo
4. If newer version exists:
   - Updates `UOS_SERVER_VERSION` in Dockerfile
   - Commits and tags
   - Triggers build workflow via `workflow_dispatch`

### Multi-Architecture

- Build matrix for `linux/amd64` and `linux/arm64`
- Separate extraction per architecture (different installer binaries)
- `docker buildx` creates and pushes multi-arch manifest

### Docker Hub Tags

- `hieutq/unifi-os-server:latest`
- `hieutq/unifi-os-server:5.0.6` (version-specific)
- `hieutq/unifi-os-server:5.0.6-amd64` / `5.0.6-arm64` (arch-specific)

## Dockerfile

```dockerfile
FROM uosserver-base:${VERSION}

LABEL org.opencontainers.image.source="https://github.com/hieutq/unifi-os-server-docker"
LABEL org.opencontainers.image.description="UniFi OS Server for Docker"

ENV UOS_SERVER_VERSION="5.0.6"

STOPSIGNAL SIGRTMIN+3

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

## Entrypoint Script

The entrypoint (`scripts/entrypoint.sh`) performs the following in order:

1. **Volume symlinks** - For each internal path, move existing content into the `/unifi` mount subdirectory (if not already present), remove the original, and create a symlink from the original path to `/unifi`:
   - `/data` -> `/unifi/data`
   - `/var/lib/mongodb` -> `/unifi/db`
   - `/var/lib/unifi` -> `/unifi/config`
   - `/var/log` -> `/unifi/logs`
   - `/srv` -> `/unifi/srv`
   - `/persistent` -> `/unifi/persistent`
   - `/etc/rabbitmq/ssl` -> `/unifi/rabbitmq-ssl`

2. **UUID management** - Persist or generate a v5-spoofed UUID at `/unifi/data/uos_uuid`, symlinked from `/data/uos_uuid`

3. **Architecture detection** - Set `FIRMWARE_PLATFORM` to `linux-x64` or `arm64` based on `dpkg --print-architecture`

4. **Version stamp** - Write version string to `/usr/lib/version`

5. **Network setup** - Create `eth0` macvlan alias from `tap0` if `eth0` doesn't exist but `tap0` does (requires `NET_ADMIN`)

6. **Service directories** - Initialize log/lib dirs for nginx, mongodb, rabbitmq with correct ownership and permissions

7. **System IP** - Write `UOS_SYSTEM_IP` to `/var/lib/unifi/system.properties` if the env var is set

8. **Launch systemd** - `exec /sbin/init`

## Docker Compose

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
    restart: unless-stopped
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `UOS_SYSTEM_IP` | Yes | Hostname or IP for device adoption |
| `UOS_UUID` | No | Fixed UUID (auto-generated if not set) |

## Ports

| Protocol | Port | Default | Description |
|---|---|---|---|
| TCP | 11443 | Exposed | GUI/API (mapped from container 443) |
| TCP | 8080 | Exposed | Device communication |
| UDP | 3478 | Exposed | STUN |
| UDP | 10003 | Exposed | Device discovery |
| TCP | 8443 | Optional | Network app GUI |
| TCP | 8444 | Optional | Hotspot portal |
| UDP | 5514 | Optional | Syslog |
| TCP | 6789 | Optional | Mobile speed test |
| TCP | 5005 | Optional | RTP |
| TCP | 9543 | Optional | Identity Hub |
| TCP | 11084 | Optional | Site Supervisor |
| TCP | 5671 | Optional | AMQPS |
| TCP | 8880 | Optional | Hotspot redirect (HTTP) |
| TCP | 8881 | Optional | Hotspot redirect (HTTP) |
| TCP | 8882 | Optional | Hotspot redirect (HTTP) |

## Security

- `cap_drop: ALL` baseline - no capabilities unless explicitly added
- Only `NET_RAW`, `NET_ADMIN`, `SYS_ADMIN` capabilities added (required for systemd + network)
- No `privileged: true`
- `cgroup: host` required for systemd (not avoidable without replacing systemd)
- Single volume reduces attack surface vs multiple bind mounts

## CI/CD

### build.yml

Triggers: push to `main`, tag push, manual `workflow_dispatch`

Steps:
1. Checkout repo
2. Install tools (`binwalk`, `podman`, `qemu-user-static` for cross-arch)
3. Run `extract-image.sh` for each architecture
4. `docker buildx build` multi-arch image
5. Push to Docker Hub with version + `latest` tags
6. Create GitHub release with changelog

### check-update.yml

Triggers: weekly cron, manual `workflow_dispatch`

Steps:
1. Fetch latest version from Ubiquiti firmware API
2. Compare against latest git tag
3. If newer: update Dockerfile, commit, tag, trigger build workflow

### Required GitHub Secrets

- `DOCKERHUB_USERNAME` - `hieutq`
- `DOCKERHUB_TOKEN` - Docker Hub access token

## Comparison with Existing Solutions

| Aspect | lemker/unifi-os-server | hieutq/unifi-os-server |
|---|---|---|
| Volume mounts | 7 separate | Single `/unifi` |
| Privileged mode | `privileged: true` | `cap_drop: ALL` + explicit caps |
| Default ports | All 15 exposed | 4 essential, rest optional |
| Docker Hub | No | Yes |
| Auto-update | Renovate (manual) | Weekly version check + auto-build |
| Image registry | GHCR only | Docker Hub + GHCR |

## Device Adoption

After starting the container, adopt UniFi devices:

1. SSH into the device with `ubnt`/`ubnt`
2. Run: `set-inform http://$UOS_SYSTEM_IP:8080/inform`

## Access

Management UI available at `https://<server-ip>:11443`
