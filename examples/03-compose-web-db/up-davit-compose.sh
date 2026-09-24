#!/usr/bin/env bash
# Path 3: `davit compose` - Davit's headless compose implementation.
# Talks to the apiserver over XPC directly (no Docker API, no socktainer) and
# solves service discovery by writing managed /etc/hosts entries into each
# running container.
set -euo pipefail
cd "$(dirname "$0")"

DAVIT="${DAVIT:-$(command -v davit || echo /Applications/Davit.app/Contents/MacOS/Davit)}"
[[ -x "$DAVIT" ]] || { echo "Davit not installed: brew install wouterdebie/tap/davit"; exit 1; }

echo "==> what will be created (dry run)"
"$DAVIT" compose plan -f compose.yaml

echo
echo "==> up"
"$DAVIT" compose up -d --down-on-failure -f compose.yaml

echo
"$DAVIT" compose ps -f compose.yaml
echo
"$DAVIT" compose logs --tail 20 -f compose.yaml api

cat <<'NOTE'

Distinctive to this path:
  - `plan` shows the equivalent `container run` per service plus warnings for
    anything unsupported, before anything is created
  - --down-on-failure rolls back only what this invocation created
  - discovery is /etc/hosts based, re-synced on every up/start/restart. A service
    recreated outside compose keeps stale entries until the next up.
  - images without /bin/sh cannot be patched, so they get no discovery entries

Down:  davit compose down -v -f compose.yaml

Note the argument order: the subcommand comes first, then -f. `davit compose -f x plan`
is rejected. Also note -f is overloaded: `compose logs -f` is --follow, so pass the
file as `logs --tail 20 -f compose.yaml <service>` or rely on autodiscovery.
NOTE
