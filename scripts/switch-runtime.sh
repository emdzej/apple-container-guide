#!/usr/bin/env bash
# switch-runtime.sh - point the 'docker' CLI at a specific runtime.
#
#   ./scripts/switch-runtime.sh            # show what docker is talking to
#   ./scripts/switch-runtime.sh apple      # Apple container (starts socktainer)
#   ./scripts/switch-runtime.sh desktop    # Docker Desktop
#   ./scripts/switch-runtime.sh colima     # Colima
#   ./scripts/switch-runtime.sh list       # every context
#
# This only moves the Docker *context*. Nothing is uninstalled, so you can
# flip back and forth while you migrate. DOCKER_HOST, if set, wins over the
# context - the script warns you when that is the case.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

have docker || die "docker CLI not installed: brew install docker"

show() {
  local ctx endpoint
  ctx="$(docker context show 2>/dev/null)"
  endpoint="$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
  info "context: ${ctx:-none}"
  info "endpoint: ${endpoint:-unknown}"
  case "$endpoint" in
    *socktainer*)             ok "runtime: Apple container (via socktainer)" ;;
    *.docker/run/docker.sock) ok "runtime: Docker Desktop" ;;
    *colima*)                 ok "runtime: Colima" ;;
    *) warn "runtime: unrecognised" ;;
  esac
  [[ -n "${DOCKER_HOST:-}" ]] && warn "DOCKER_HOST=$DOCKER_HOST is set in this shell and overrides the context. unset it."
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    && ok "the endpoint is reachable" \
    || fail "the endpoint is NOT reachable - the runtime is probably stopped"
}

case "${1:-show}" in
  apple|container|socktainer)
    ./socktainer-service.sh start || exit 1
    run "selecting the socktainer context" docker context use socktainer
    show
    note "Apple container has no equivalent for --privileged, --pause, static IPs or CPU shares."
    note "See docs/05-docker-compat.md for the full list before you hit it."
    ;;
  desktop|docker-desktop)
    ctx="$(docker_desktop_context)"
    [[ -n "$ctx" ]] || die "no Docker Desktop context found (is Docker Desktop installed?)"
    open -ga Docker 2>/dev/null || true
    run "selecting the $ctx context" docker context use "$ctx"
    show
    ;;
  colima)
    have colima || die "colima not installed"
    colima status >/dev/null 2>&1 || run "starting colima" colima start
    run "selecting the colima context" docker context use colima
    show
    ;;
  list) docker context ls ;;
  show) show ;;
  -h|--help) sed -n '2,13p' "$0" ;;
  *) die "unknown target: $1 (apple|desktop|colima|list|show)" ;;
esac
