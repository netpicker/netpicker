#!/bin/bash
# Bring up Netpicker under rootless Podman. Run from the repo root: ./podman/up.sh
set -e

# The api/celery "system services" panel talks to the Podman socket.
systemctl --user enable --now podman.socket
# Keep the user services running after logout.
loginctl enable-linger "$USER" 2>/dev/null || true

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

PROJECT=netpicker
COMPOSE=(podman compose -p "$PROJECT" -f podman/compose.yml)

"${COMPOSE[@]}" down

# These volumes are written by services running as uid 911, but rootless Podman
# creates volumes owned by root. Create and chown them before starting.
for v in git policy-data secret dc-vol transferium kibbitzer syslog; do
  podman volume exists "${PROJECT}_$v" || podman volume create "${PROJECT}_$v" >/dev/null
  podman run --rm -v "${PROJECT}_$v":/v docker.io/library/alpine chown -R 911:911 /v
done

"${COMPOSE[@]}" up -d

echo
echo "Netpicker is starting. Frontend: http://localhost:8081"
