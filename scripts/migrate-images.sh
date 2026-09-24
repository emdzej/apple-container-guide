#!/usr/bin/env bash
# migrate-images.sh - move images from Docker Desktop into Apple container's store.
#
#   ./scripts/migrate-images.sh --list                 # what Docker Desktop is holding
#   ./scripts/migrate-images.sh --all                  # migrate everything (skips <none>)
#   ./scripts/migrate-images.sh myapp:dev postgres:17  # migrate specific references
#   ./scripts/migrate-images.sh --all --prefer-pull    # re-pull from the registry where possible
#
# Two transports, tried in this order per image:
#   1. registry pull   - fastest and most correct for anything that came from a registry.
#                        Apple container pulls only your local platform's blobs.
#   2. tar handoff     - `docker save` piped into socktainer's `docker load`. Needed for
#                        images you built locally and never pushed. Requires socktainer.
#
# Note: `container image load` wants an OCI archive. `docker save` on Docker Desktop
# emits a Docker archive, which is why the tar path goes through socktainer's
# Docker-compatible /images/load endpoint instead of the container CLI directly.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

MODE=""; PREFER_PULL=0; REFS=()
for arg in "$@"; do
  case "$arg" in
    --list)        MODE=list ;;
    --all)         MODE=all ;;
    --prefer-pull) PREFER_PULL=1 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    -*)            die "unknown flag: $arg" ;;
    *)             REFS+=("$arg"); MODE="${MODE:-some}" ;;
  esac
done
[[ -n "$MODE" ]] || { sed -n '2,20p' "$0"; exit 1; }

have docker || die "docker CLI not installed"
require_container_cli
SRC_CTX="$(docker_desktop_context)"
[[ -n "$SRC_CTX" ]] || die "no Docker Desktop context found - nothing to migrate from"
docker --context "$SRC_CTX" info >/dev/null 2>&1 || die "Docker Desktop is not running (context: $SRC_CTX). Start it first."
info "source: Docker Desktop (context '$SRC_CTX')"

dlist() { docker --context "$SRC_CTX" image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u; }

if [[ "$MODE" == "list" ]]; then
  head1 "Images in Docker Desktop"
  docker --context "$SRC_CTX" image ls
  head1 "Images already in Apple container"
  ensure_container_running; container image ls
  exit 0
fi

ensure_container_running
[[ "$MODE" == "all" ]] && mapfile -t REFS < <(dlist)
(( ${#REFS[@]} )) || die "nothing to migrate"

# The tar path needs socktainer; find out once rather than per image.
TAR_OK=0
if socktainer_up && docker context ls --format '{{.Name}}' | grep -qx socktainer; then
  TAR_OK=1
else
  warn "socktainer is not running - only the registry-pull path is available."
  note "Start it with ./scripts/socktainer-service.sh start to migrate locally-built images."
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DONE=(); SKIPPED=(); FAILED=()

for ref in "${REFS[@]}"; do
  head1 "$ref"
  if container image inspect "$ref" >/dev/null 2>&1 && (( ! PREFER_PULL )); then
    ok "already present in Apple container - skipping"
    SKIPPED+=("$ref"); continue
  fi

  # A reference is pullable if it is not purely local. Anything Docker reports
  # with a RepoDigest came from a registry, so the registry has it.
  HAS_DIGEST="$(docker --context "$SRC_CTX" image inspect "$ref" --format '{{len .RepoDigests}}' 2>/dev/null || echo 0)"
  if [[ "$HAS_DIGEST" != "0" ]]; then
    info "pulling from the registry"
    if container image pull "$ref"; then ok "pulled"; DONE+=("$ref"); continue; fi
    warn "pull failed, falling back to the tar handoff"
  else
    note "no registry digest - this image only exists locally, using the tar handoff"
  fi

  if (( ! TAR_OK )); then fail "cannot migrate without socktainer"; FAILED+=("$ref"); continue; fi
  info "docker save -> socktainer docker load"
  if docker --context "$SRC_CTX" save "$ref" | docker --context socktainer load; then
    ok "loaded"; DONE+=("$ref")
  else
    fail "transfer failed"; FAILED+=("$ref")
    note "Try manually: docker --context $SRC_CTX save '$ref' -o $TMP/img.tar"
    note "              docker --context socktainer load -i $TMP/img.tar"
    note "Or with skopeo: skopeo copy docker-daemon:$ref oci-archive:$TMP/img.tar && container image load -i $TMP/img.tar"
  fi
done

head1 "Result"
(( ${#DONE[@]} ))    && { ok "migrated ${#DONE[@]}:";  printf '       %s\n' "${DONE[@]}"; }
(( ${#SKIPPED[@]} )) && { info "already there ${#SKIPPED[@]}"; }
(( ${#FAILED[@]} ))  && { fail "failed ${#FAILED[@]}:"; printf '       %s\n' "${FAILED[@]}"; }
note "Verify with: container image ls"
exit $(( ${#FAILED[@]} > 0 ? 1 : 0 ))
