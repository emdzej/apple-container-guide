#!/usr/bin/env bash
# Source this before running a Testcontainers suite:
#     source examples/06-testcontainers/env.sh
#
# Sets DOCKER_HOST explicitly rather than relying on the docker context, because
# most Testcontainers clients read DOCKER_HOST and ignore contexts entirely.
SOCK="$HOME/.socktainer/container.sock"

if [ ! -S "$SOCK" ]; then
  echo "socktainer is not running. Start it:" >&2
  echo "  \"$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/socktainer-service.sh\" start" >&2
  return 1 2>/dev/null || exit 1
fi

export DOCKER_HOST="unix://$SOCK"
export TESTCONTAINERS_RYUK_DISABLED=true
# Reuse across runs is unreliable without Ryuk bookkeeping; keep it off.
export TESTCONTAINERS_REUSE_ENABLE=false

echo "DOCKER_HOST=$DOCKER_HOST"
echo "TESTCONTAINERS_RYUK_DISABLED=$TESTCONTAINERS_RYUK_DISABLED"
echo
echo "Reminder: nothing reaps leftovers with Ryuk off. After a crashed run:"
echo "  container ls -a -q | grep -E '^testcontainers' | xargs -r container rm -f"
