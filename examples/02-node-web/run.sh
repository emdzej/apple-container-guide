#!/usr/bin/env bash
# Port publishing, bind mounts, and per-container resource sizing.
set -euo pipefail
cd "$(dirname "$0")"
NAME=node-web
PORT=${PORT:-8088}

container system status >/dev/null 2>&1 || container system start
container rm -f "$NAME" 2>/dev/null || true

container build --tag "$NAME:dev" --file Dockerfile .

# --publish binds on the HOST loopback and forwards into the container's VM.
#   bind to 0.0.0.0 to expose to your LAN, 127.0.0.1 to keep it local
# --volume is a virtiofs bind mount; edits on either side are visible immediately
# --cpus / --memory are VM reservations made at boot, not elastic cgroup limits.
#   1 GiB is the default; too low means the process is OOM-killed inside the guest.
container run --detach --name "$NAME" \
  --publish "127.0.0.1:${PORT}:8000" \
  --volume "$PWD/message.txt:/app/message.txt" \
  --cpus 2 --memory 512m \
  --env PORT=8000 \
  "$NAME:dev"

# The VM has to boot before the port answers; a couple of hundred ms, not instant.
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null && break
  sleep 0.25
done

echo
curl -s "http://127.0.0.1:${PORT}/"
echo
echo "container IP (reachable directly from the host, no publish needed):"
container inspect "$NAME" | grep -m1 ipv4Address
echo
echo "open   http://127.0.0.1:${PORT}"
echo "logs   container logs -f $NAME"
echo "stop   container rm -f $NAME"
