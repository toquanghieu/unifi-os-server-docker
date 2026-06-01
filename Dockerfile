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
# Two build-only guards are installed first and removed afterwards:
#   - policy-rc.d (exit 101): stops dpkg/apt from starting the unifi service
#     during build (no systemd running here).
#   - systemd-cat shim: UBNT ships a dpkg status hook that pipes through
#     `systemd-cat`, which needs the journal socket that does not exist during
#     build. The shim strips `-t TAG`, runs the hook command directly, and never
#     fails dpkg. The real systemd-cat is restored before the layer ends.
# Finally, fail the build loudly if the Network app did not actually install.
RUN set -eu; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod +x /usr/sbin/policy-rc.d; \
    cp -a /usr/bin/systemd-cat /usr/bin/systemd-cat.real; \
    printf '%s\n' \
      '#!/bin/sh' \
      'while [ $# -gt 0 ]; do case "$1" in -t|--identifier) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac; done' \
      '"$@" || true' \
      'exit 0' > /usr/bin/systemd-cat; \
    chmod +x /usr/bin/systemd-cat; \
    apt-get update; \
    /usr/local/bin/update-network.sh "$UNIFI_NETWORK_VERSION"; \
    mv -f /usr/bin/systemd-cat.real /usr/bin/systemd-cat; \
    rm -f /usr/sbin/policy-rc.d; \
    rm -rf /var/lib/apt/lists/*; \
    INSTALLED="$(dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d- -f1 || true)"; \
    if [ "$INSTALLED" != "$UNIFI_NETWORK_VERSION" ]; then \
      echo "ERROR: expected unifi $UNIFI_NETWORK_VERSION, got '${INSTALLED:-none}'"; exit 1; \
    fi; \
    echo "OK: unifi $INSTALLED baked into image"

ENTRYPOINT ["/entrypoint.sh"]
