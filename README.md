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
