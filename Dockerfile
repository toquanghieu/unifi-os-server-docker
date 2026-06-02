ARG BASE_IMAGE=uosserver-base:latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/toquanghieu/unifi-os-server-docker"
LABEL org.opencontainers.image.description="Self-hosted UniFi OS Server in Docker - single volume, no privileged mode, multi-arch (amd64/arm64), auto-updated"
LABEL org.opencontainers.image.licenses="MIT"

ARG UOS_SERVER_VERSION=5.1.15
ENV UOS_SERVER_VERSION=${UOS_SERVER_VERSION}

STOPSIGNAL SIGRTMIN+3

# The UniFi Network application ships *inside* the UOS Server firmware base
# image as the UniFi-OS-integrated build (UNIFI_CORE_ENABLED=true, serves the
# ucore API on :8081). Do NOT reinstall it from the public standalone .deb —
# that variant runs standalone (no ucore) and breaks first-boot setup.
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
