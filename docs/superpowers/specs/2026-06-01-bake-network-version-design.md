# Design: Bake UniFi Network version into image + auto-track Network & UOS

Date: 2026-06-01

## Problem

The image currently bakes only the UniFi OS Server version. The UniFi Network
application version is installed at *runtime* via the `UNIFI_NETWORK_VERSION`
env var (`entrypoint.sh` → `update-network.sh`), which means:

- A fresh container has to download the ~130 MB `.deb` on first boot before the
  Network app is usable.
- The published image does not carry a known, pinned Network version.
- `check-update.yml` only watches the UOS Server version, so a new Network
  release never triggers a rebuild.

We want the Network version **baked into the image at build time**, and we want
CI to **rebuild automatically when either** UniFi OS Server **or** the Network
application publishes a new release.

## Decisions (from brainstorming)

1. Track **both** Network and UOS Server versions for auto-rebuild.
2. Tagging is **dual**: `UOS-netNETWORK` (e.g. `5.1.15-net10.4.57`) plus `latest`.
3. Build-time install **reuses `update-network.sh`** (option A) with a
   `policy-rc.d` guard, rather than duplicating install logic in the Dockerfile.

## Architecture

Four files change. Each has one clear responsibility:

### 1. `Dockerfile` — source of truth + build-time install

- Add `ARG UNIFI_NETWORK_VERSION=10.4.57` alongside the existing
  `ARG UOS_SERVER_VERSION`. This pinned value is the single source of truth that
  `check-update.yml` bumps over time.
- Add a `RUN` step (after the script COPY/chmod) that:
  1. Writes `/usr/sbin/policy-rc.d` returning exit 101 and makes it executable,
     so dpkg/apt do **not** try to start the `unifi` service during build (no
     systemd is running at build time).
  2. Runs `/usr/local/bin/update-network.sh "$UNIFI_NETWORK_VERSION"`.
  3. Removes `/usr/sbin/policy-rc.d`.
- `update-network.sh` is already build-safe in spirit: `dpkg -i ... || true`
  then `apt-get install -f -y`, and its `systemctl restart` is guarded by
  `pidof systemd` (absent during build, so skipped). The policy-rc.d guard is
  the only addition needed to make the postinst service-start a no-op.

The Network files land in the image's real `/usr/lib/unifi`. At runtime
`entrypoint.sh` already seeds `/usr/lib/unifi` → `/unifi/app` via
`cp -a --no-clobber`, so the baked version populates **fresh** volumes.

### 2. `entrypoint.sh` — keep runtime override (no change required)

The runtime `UNIFI_NETWORK_VERSION` path stays. It remains useful for upgrading
the Network app on an **existing** volume (where `--no-clobber` means the baked
version would not overwrite the volume's older copy). Baked = default for new
installs; runtime env = explicit upgrade/override.

### 3. `build.yml` — read both versions, build, dual-tag

For each arch job (`build-amd64`, `build-arm64`):

- Determine both versions from the Dockerfile ARGs:
  - `UOS=$(grep -oP '^ARG UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile)`
  - `NET=$(grep -oP '^ARG UNIFI_NETWORK_VERSION=\K[0-9.]+' Dockerfile)`
  - (The manual `workflow_dispatch` `version` input keeps overriding `UOS`.)
- Build with the extra arg: `--build-arg UNIFI_NETWORK_VERSION=$NET`.
- Tag per-arch: `$IMAGE:$UOS-net$NET-$ARCH`.
- Push that per-arch tag.

`manifest` job:

- Create/push `$IMAGE:$UOS-net$NET` from the two per-arch tags.
- Create/push `$IMAGE:latest` from the two per-arch tags.

### 4. `check-update.yml` — watch both products

- Keep the existing UOS check (`unifi-os-server` product).
- Add a Network check using the firmware API product **`unifi`**, channel
  `release`. (Verified: product `unifi-network-server` returns null; `unifi`
  returns `v10.4.57-34628-1`, matching the apt repo.) Normalize the marketing
  version: strip leading `v`, take the part before the first `-`
  (`v10.4.57-34628-1` → `10.4.57`), which is what the `.deb` URL uses.
- Also fix `update-network.sh::latest_version()` fallback #2: it currently
  queries the dead `unifi-network-server` product. Point it at `unifi` with the
  same normalization so the in-container fallback works too.
- Read current pinned values from the Dockerfile ARGs (anchored greps).
- If **either** product is newer than its pinned ARG:
  - `sed` bump the corresponding `^ARG ...=` line (anchored, `[0-9.]\+`, only the
    ARG line — same safe pattern as the prior fix).
  - Commit + tag + push.
  - Dispatch `build.yml` (needs `actions: write`, already granted).
- The dispatched build re-reads both versions from the now-bumped Dockerfile.

## Data flow

```
check-update (cron)
  ├─ UOS latest  vs  ARG UOS_SERVER_VERSION
  └─ NET latest  vs  ARG UNIFI_NETWORK_VERSION
        │ (either newer)
        ▼
  sed-bump ARG(s) → commit → tag → dispatch build.yml
        │
        ▼
build.yml: grep UOS+NET from Dockerfile
        │  docker build --build-arg UOS_SERVER_VERSION --build-arg UNIFI_NETWORK_VERSION
        │     └─ Dockerfile RUN: policy-rc.d guard → update-network.sh $NET → remove guard
        ▼
  tags: $UOS-net$NET-amd64 / -arm64  →  manifest $UOS-net$NET + latest
```

## Error handling

- **Build-time service start**: blocked by `policy-rc.d` (exit 101) so dpkg
  postinst never invokes the service; removed after install.
- **`.deb` not found for a version**: `update-network.sh` already `curl -fSL`
  (fails the build loudly) — correct, a bad pin should fail CI rather than ship
  a broken image.
- **Network API returns nothing in check-update**: skip the Network bump for
  that run (mirror the existing `skip=true` guard for the UOS check); do not fail
  the whole workflow.
- **Both bump in the same run**: a single commit bumps both ARGs, one build runs,
  one combined tag is produced.

## Testing / verification

- Local: `docker build --build-arg UNIFI_NETWORK_VERSION=10.4.57 ...` is not
  feasible offline (needs the proprietary base image), so verification is via CI:
  - Confirm `build.yml` "Determine version" emits both `UOS` and `NET`.
  - Confirm the build's install step logs `UniFi Network is now: 10.4.57`.
  - Confirm Docker Hub shows `5.1.15-net10.4.57` and `latest` after the run.
- Simulate the `check-update` greps/seds locally against a sample Dockerfile to
  confirm only the intended ARG lines change (regression guard for the earlier
  corruption bug).

## Trade-offs / non-goals

- Image grows ~300–500 MB (Network app + deps). Accepted.
- Every new Network release costs one build+push. Accepted (that is the goal).
- Not baking multiple Network versions; exactly one pinned version per image.
- Not changing the volume-symlink scheme or runtime override behavior.
