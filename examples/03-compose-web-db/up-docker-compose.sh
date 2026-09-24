#!/usr/bin/env bash
# Path 2: real `docker compose` through socktainer.
# Widest Compose coverage, because it IS Docker Compose - socktainer just answers
# the Docker API on Apple container's behalf.
set -euo pipefail
cd "$(dirname "$0")"

command -v docker >/dev/null || { echo "brew install docker"; exit 1; }
../../scripts/socktainer-service.sh start
docker context use socktainer >/dev/null

echo "==> docker compose up -d"
docker compose -f compose.yaml up -d

echo
echo "==> docker compose ps"
docker compose -f compose.yaml ps

echo
echo "==> did the api reach the db by name?"
docker compose -f compose.yaml logs api | tail -5

cat <<'NOTE'

Verified on this stack: ps with health status, logs -f, exec, healthcheck-gated
depends_on (`db Waiting` -> `db Healthy` -> `api Starting`), published ports,
named volumes with driver_opts, and real DNS - `db` AND `db.acdemo` both resolve
from inside a container, with no [dns] domain configured on the host.

Discovery here is a real DNS server (socktainer listens on port 2054), not
/etc/hosts rewriting, so it keeps working for containers started later.

Still absent, because the platform has no equivalent:
  - privileged: true      -> approximated as --cap-add=ALL
  - static ipv4_address   -> ignored, use service names
  - pause/unpause         -> unsupported
  - restart: policies     -> only enforced while socktainer is running

Down:  docker compose -f compose.yaml down -v
NOTE
