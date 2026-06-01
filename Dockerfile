ARG BASE_IMAGE=uosserver-base:latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/toquanghieu/unifi-os-server-docker"
LABEL org.opencontainers.image.description="Self-hosted UniFi OS Server in Docker - single volume, no privileged mode, multi-arch (amd64/arm64), auto-updated"
LABEL org.opencontainers.image.licenses="MIT"

ARG UOS_SERVER_VERSION=5.1.15
ENV UOS_SERVER_VERSION=${UOS_SERVER_VERSION}

# Pinned UniFi Network application version baked into the image.
# check-update.yml bumps this when a newer release ships.
ARG UNIFI_NETWORK_VERSION=10.4.57

STOPSIGNAL SIGRTMIN+3

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/update-network.sh /usr/local/bin/update-network.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/update-network.sh

# Bake the pinned UniFi Network application into the image at build time.
# policy-rc.d (exit 101) stops dpkg/apt from starting the unifi service during
# build (no systemd here); it is removed once the install finishes.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update \
    && /usr/local/bin/update-network.sh "$UNIFI_NETWORK_VERSION" \
    && rm -f /usr/sbin/policy-rc.d \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/entrypoint.sh"]
