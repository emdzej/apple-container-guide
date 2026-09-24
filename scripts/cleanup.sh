#!/usr/bin/env bash
# cleanup.sh - reclaim disk from Apple container.
#
#   ./scripts/cleanup.sh              # stopped containers + dangling images + unused volumes
#   ./scripts/cleanup.sh --aggressive # also all unused images and the builder's layer cache
#   ./scripts/cleanup.sh --df         # just show usage
#
# Apple container gives every container and every volume its own sparse disk
# image. Deleting files inside a container does not shrink its image, so disk
# use only ever goes up until you prune.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

AGGRESSIVE=0; DF_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --aggressive|-a) AGGRESSIVE=1 ;;
    --df)            DF_ONLY=1 ;;
    -h|--help)       sed -n '2,10p' "$0"; exit 0 ;;
    *)               die "unknown flag: $arg" ;;
  esac
done

require_container_cli
ensure_container_running

head1 "Before"
container system df

if (( DF_ONLY )); then exit 0; fi

head1 "Stopped containers"
container prune || warn "container prune failed"

head1 "Dangling images"
container image prune || warn "image prune failed"

head1 "Unused volumes"
warn "container volume prune deletes volume contents immediately and permanently."
container volume ls
if confirm "Prune volumes with no container references?"; then
  container volume prune || warn "volume prune failed"
else
  note "skipped"
fi

head1 "Unused networks"
container network prune || warn "network prune failed"

if (( AGGRESSIVE )); then
  head1 "All unused images"
  if confirm "Remove every image not used by a container (not just dangling ones)?"; then
    container image prune --all || warn "failed"
  fi
  head1 "Builder layer cache"
  note "The builder keeps its BuildKit cache inside its own VM; replacing the VM is the only way to reclaim it."
  if confirm "Stop and delete the builder? (it is recreated on your next build)"; then
    container builder stop 2>/dev/null || true
    container builder delete 2>/dev/null || true
    ok "builder removed - next 'container build' will be slower while the cache refills"
  fi
fi

head1 "After"
container system df
