#!/usr/bin/env bash
# Shared helpers for the scripts in this repo. Source, don't execute.

# shellcheck disable=SC2034
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

ok()    { printf '%s  ok  %s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s warn %s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()  { printf '%s fail %s %s\n' "$C_RED" "$C_RESET" "$*"; }
info()  { printf '%s info %s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
note()  { printf '       %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

die() { fail "$*"; exit 1; }

# Print the leading comment block of a script as its help text, so --help stays
# correct when the header changes. Skips the shebang, stops at the first
# non-comment line.
usage() {
  local f="${1:-$SELF}"
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$f"
}

have() { command -v "$1" >/dev/null 2>&1; }

# confirm "question" -> returns 0 on yes. Honours ASSUME_YES=1.
confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  local reply
  printf '%s%s%s [y/N] ' "$C_BOLD" "$1" "$C_RESET"
  read -r reply || return 1
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" ]]
}

# run "description" cmd...   -- respects DRY_RUN=1
run() {
  local desc="$1"; shift
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s would run %s %s\n' "$C_DIM" "$C_RESET" "$*"
    return 0
  fi
  info "$desc"
  "$@"
}

require_apple_silicon() {
  [[ "$(uname -m)" == "arm64" ]] || die "Apple container requires Apple silicon (got $(uname -m))."
}

macos_major() { sw_vers -productVersion | cut -d. -f1; }

require_macos() {
  local want="${1:-26}"
  local got; got="$(macos_major)"
  if (( got < want )); then
    die "Apple container needs macOS ${want}+ (you are on $(sw_vers -productVersion))."
  fi
}

require_container_cli() {
  have container || die "'container' not found. Run scripts/bootstrap.sh first."
}

container_running() { container system status >/dev/null 2>&1; }

ensure_container_running() {
  if ! container_running; then
    run "starting container system services" container system start
  fi
}

SOCKTAINER_SOCK="${SOCKTAINER_SOCK:-$HOME/.socktainer/container.sock}"

socktainer_up() { [[ -S "$SOCKTAINER_SOCK" ]] && curl -s --unix-socket "$SOCKTAINER_SOCK" http://localhost/_ping >/dev/null 2>&1; }

# Best guess at the Docker context that points at Docker Desktop.
docker_desktop_context() {
  docker context ls --format '{{.Name}} {{.DockerEndpoint}}' 2>/dev/null \
    | awk '/\.docker\/run\/docker\.sock/ {print $1; exit}'
}
