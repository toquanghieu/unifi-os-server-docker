# UniFi OS Server - Docker

[![Build and Push](https://github.com/toquanghieu/unifi-os-server-docker/actions/workflows/build.yml/badge.svg)](https://github.com/toquanghieu/unifi-os-server-docker/actions/workflows/build.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/hieutq/unifi-os-server)](https://hub.docker.com/r/hieutq/unifi-os-server)

Self-hosted [UniFi OS Server](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi) in Docker with a single volume, no privileged mode, and automatic updates.

**Features:**

- Single volume mount for all data (database, config, logs)
- No `privileged: true` - uses explicit Linux capabilities
- Multi-arch: `linux/amd64` and `linux/arm64`
- Auto-updated weekly from official Ubiquiti releases
- Built from the official UniFi OS Server installer

## Supported Tags

- `latest` - latest stable release
- `5.0.6` - version-specific

## Quick Start

### Docker Compose (recommended)

```bash
git clone https://github.com/toquanghieu/unifi-os-server-docker.git
cd unifi-os-server-docker
cp .env.example .env
# Edit .env and set UOS_SYSTEM_IP to your server's hostname or IP
docker compose up -d
```

### Docker Run

```bash
docker run -d \
  --name unifi-os-server \
  --cgroupns host \
  --cap-drop ALL \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add NET_RAW \
  --cap-add NET_BIND_SERVICE --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH \
  --cap-add FOWNER --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --cap-add KILL --cap-add SYS_CHROOT --cap-add SYS_PTRACE \
  --cap-add SYS_RESOURCE --cap-add AUDIT_WRITE --cap-add MKNOD \
  --tmpfs /run:exec --tmpfs /run/lock --tmpfs /tmp:exec \
  --tmpfs /var/lib/journal --tmpfs /var/opt/unifi/tmp:size=64m \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v unifi_data:/unifi \
  -e UOS_SYSTEM_IP=your-server-ip \
  -p 11443:443 -p 8080:8080 -p 3478:3478/udp -p 10003:10003/udp \
  --restart unless-stopped \
  hieutq/unifi-os-server:latest
```

Then open `https://<your-server-ip>:11443` to complete setup.

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
| TCP | 8880-8882 | Optional | Hotspot redirect |

## Data Persistence

All data is stored in a single Docker volume (`unifi_data`), organized as:

| Subdirectory | Contents |
|---|---|
| `data/` | Application data and UUID |
| `db/` | MongoDB database files |
| `config/` | UniFi configuration and system.properties |
| `logs/` | Service logs (nginx, mongodb, rabbitmq) |
| `srv/` | Service-specific data |
| `persistent/` | Package manager state |
| `rabbitmq-ssl/` | RabbitMQ SSL certificates |

To use a bind mount instead, replace `unifi_data:/unifi` with `./unifi:/unifi` in the compose file and remove the `volumes:` section at the bottom.

## Device Adoption

1. SSH into the UniFi device (default credentials: `ubnt`/`ubnt`)
2. Set the inform URL:

```bash
set-inform http://<UOS_SYSTEM_IP>:8080/inform
```

## Security

This image does not use `privileged: true`. Instead:

- `cap_drop: ALL` as baseline
- Explicit capabilities added: `SYS_ADMIN`, `NET_ADMIN`, `NET_RAW`, `NET_BIND_SERVICE`, `DAC_OVERRIDE`, `DAC_READ_SEARCH`, `FOWNER`, `CHOWN`, `SETUID`, `SETGID`, `KILL`, `SYS_CHROOT`, `SYS_PTRACE`, `SYS_RESOURCE`, `AUDIT_WRITE`, `MKNOD`
- `cgroup: host` required for systemd

These capabilities are needed because UniFi OS Server runs 10+ internal services (MongoDB, PostgreSQL, RabbitMQ, Nginx, etc.) via systemd, each under different system users.

## Building Locally

```bash
# Install dependencies: binwalk, podman, docker
# Then extract and build:
./scripts/extract-image.sh uosserver-base:latest
docker build --build-arg BASE_IMAGE=uosserver-base:latest -t hieutq/unifi-os-server:local .
```

The extraction script automatically queries the Ubiquiti firmware API to find and download the latest installer for your architecture.

## How It Works

1. The official UniFi OS Server installer embeds an OCI container image
2. Our CI pipeline downloads the installer, extracts the embedded image, and converts it from OCI to Docker format
3. A thin Dockerfile layers an entrypoint script on top that manages volume symlinks, UUID persistence, network setup, and launches systemd
4. The image is published to Docker Hub weekly with automatic version detection

## License

MIT
