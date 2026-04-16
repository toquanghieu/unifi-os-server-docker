ARG BASE_IMAGE=uosserver-base:latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/toquanghieu/unifi-os-server-docker"
LABEL org.opencontainers.image.description="Self-hosted UniFi OS Server in Docker - single volume, no privileged mode, multi-arch (amd64/arm64), auto-updated"
LABEL org.opencontainers.image.licenses="MIT"

ARG UOS_SERVER_VERSION=5.0.6
ENV UOS_SERVER_VERSION=${UOS_SERVER_VERSION}

STOPSIGNAL SIGRTMIN+3

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/update-network.sh /usr/local/bin/update-network.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/update-network.sh

ENTRYPOINT ["/entrypoint.sh"]
