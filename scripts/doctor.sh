#!/usr/bin/env bash
# doctor.sh - health check for an Apple container setup on macOS.
# Read-only: it inspects and reports, it never changes anything.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage "$SELF"; exit 0; fi

PROBLEMS=0
bad()  { fail "$*"; PROBLEMS=$((PROBLEMS + 1)); }

head1 "Host"
if [[ "$(uname -m)" == "arm64" ]]; then
  ok "Apple silicon ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64))"
else
  bad "Not Apple silicon ($(uname -m)). Apple container cannot run here."
fi
MACOS="$(sw_vers -productVersion)"
if (( $(macos_major) >= 26 )); then
  ok "macOS $MACOS"
else
  bad "macOS $MACOS - container needs macOS 26 (Tahoe) or later for networking/DNS to work properly."
fi
printf '       %sRAM: %s GiB, CPUs: %s%s\n' "$C_DIM" \
  "$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))" "$(sysctl -n hw.ncpu)" "$C_RESET"

head1 "Apple container runtime"
if have container; then
  ok "container CLI: $(container --version 2>&1 | head -1)"
  note "resolved from: $(command -v container)"
else
  bad "container CLI not installed. See scripts/bootstrap.sh"
fi

# Detect more than one platform install. Mixed client/server versions cannot talk over XPC.
ROOTS=()
[[ -x /usr/local/bin/container ]] && ROOTS+=("/usr/local (official .pkg installer)")
if have brew; then
  for keg in "$(brew --prefix 2>/dev/null)"/Cellar/container/*; do
    [[ -d "$keg" ]] && ROOTS+=("$keg (Homebrew)")
  done
fi
[[ -d "$HOME/Library/Application Support/dev.wouter.davit/platform" ]] && ROOTS+=("$HOME/Library/Application Support/dev.wouter.davit/platform (Davit-managed)")
if (( ${#ROOTS[@]} > 1 )); then
  warn "${#ROOTS[@]} platform installs found - version skew is the #1 cause of weird failures:"
  for r in "${ROOTS[@]}"; do note "- $r"; done
  note "Pick one. See docs/10-troubleshooting.md#multiple-installs"
elif (( ${#ROOTS[@]} == 1 )); then
  ok "single platform install: ${ROOTS[0]}"
fi

if have container; then
  if container system status >/dev/null 2>&1; then
    ok "container system services are running"
    # The value layout of these lines differs between releases: 1.0.0 printed
    # "server.version  container-apiserver version 1.0.0 (build: ...)" while 1.4.1
    # prints "server.version  1.4.1". Pull the first version-shaped token instead
    # of a fixed field number.
    ver_of() { container system status 2>/dev/null | awk -v k="$1" '$1==k{for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) {print $i; exit}}'; }
    CLIENT_V="$(ver_of client.version)"
    SERVER_V="$(ver_of server.version)"
    INSTALL_ROOT="$(container system status 2>/dev/null | awk '$1=="paths.installRoot"{print $2}')"
    note "install root in use: ${INSTALL_ROOT:-unknown}"
    if [[ -n "${CLIENT_V:-}" && -n "${SERVER_V:-}" && "${CLIENT_V%%.*}" != "${SERVER_V%%.*}" ]]; then
      bad "client $CLIENT_V vs apiserver $SERVER_V - major versions differ, XPC calls will fail or misbehave."
      note "Fix: container system stop, remove the stale install, then container system start."
    elif [[ -n "${CLIENT_V:-}" && "${CLIENT_V}" != "${SERVER_V:-}" ]]; then
      warn "client $CLIENT_V vs apiserver $SERVER_V - the CLI and the running daemon are different builds."
      note "Usually means the CLI comes from one install and the daemon from another ($(command -v container) vs ${INSTALL_ROOT:-?})."
      note "Fix: container system stop, keep one install, container system start. See docs/10-troubleshooting.md#multiple-installs"
    fi
    printf '       %s%s%s\n' "$C_DIM" "$(container system status 2>/dev/null | awk '/^containers\.|^images\./{printf "%s=%s  ", $1, $2}')" "$C_RESET"
  else
    warn "container system services are not running -> container system start"
  fi

  DNS_DOMAIN="$(container system property list 2>/dev/null | awk '/^\[dns\]/{f=1;next} /^\[/{f=0} f && $1=="domain"{gsub(/"/,"",$3); print $3}')"
  if [[ -n "${DNS_DOMAIN:-}" ]]; then
    ok "DNS domain configured: .$DNS_DOMAIN"
    if [[ -f "/etc/resolver/$DNS_DOMAIN" ]]; then
      ok "macOS resolver installed: /etc/resolver/$DNS_DOMAIN"
    else
      warn "macOS does not know about .$DNS_DOMAIN -> sudo container system dns create $DNS_DOMAIN"
    fi
  else
    warn "no [dns] domain set - you cannot reach containers by name from the host."
    note "Fix: scripts/setup-dns.sh"
  fi
fi

head1 "Container machines"
if have container && container system status >/dev/null 2>&1; then
  MACHINES="$(container machine list -q 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${MACHINES:-0}" == "0" ]]; then
    note "none. These are persistent Linux VMs with your home mounted - see docs/13-machines.md"
  else
    ok "$MACHINES machine(s)"
    container machine list 2>/dev/null | sed 's/^/       /'
    # A running machine reserves half the host RAM by default.
    container machine list --format json 2>/dev/null \
      | { have jq && jq -r '.[] | select(.status=="running") | "       running: \(.id) holds \((.memory/1073741824)|floor)G and \(.cpus) cpus"' || true; }
  fi
fi

head1 "Docker API compatibility (socktainer)"
if have socktainer; then
  ok "socktainer installed: $(socktainer --version 2>&1 | head -1)"
  if socktainer_up; then
    ok "socket is live: $SOCKTAINER_SOCK"
  elif [[ -S "$SOCKTAINER_SOCK" ]]; then
    bad "socket file exists but does not answer /_ping - stale socket from a crashed process."
    note "Fix: rm -f '$SOCKTAINER_SOCK' && scripts/socktainer-service.sh start"
  else
    warn "socktainer is not running -> scripts/socktainer-service.sh start"
  fi
else
  warn "socktainer not installed. Without it, 'docker', Testcontainers and IDE integrations cannot see Apple containers."
fi

head1 "Docker clients"
if have docker; then
  ok "docker CLI: $(docker --version)"
  CTX="$(docker context show 2>/dev/null)"
  ENDPOINT="$(docker context inspect "$CTX" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
  info "active context: ${CTX:-none} -> ${ENDPOINT:-?}"
  case "$ENDPOINT" in
    *socktainer*) ok "docker is talking to Apple container" ;;
    *.docker/run/docker.sock) warn "docker is talking to Docker Desktop -> scripts/switch-runtime.sh apple" ;;
    *colima*)     warn "docker is talking to Colima -> scripts/switch-runtime.sh apple" ;;
    *orbstack*)   warn "docker is talking to OrbStack -> scripts/switch-runtime.sh apple" ;;
    *)            warn "docker endpoint is not Apple container" ;;
  esac
  [[ -n "${DOCKER_HOST:-}" ]] && warn "DOCKER_HOST=$DOCKER_HOST is set and overrides the context you selected."
else
  warn "docker CLI not installed (brew install docker) - optional, but needed for compose/Testcontainers compatibility."
fi
have docker-compose || have docker && docker compose version >/dev/null 2>&1 && ok "docker compose plugin present: $(docker compose version 2>/dev/null | head -1)"

head1 "Compose and UI"
have container-compose && ok "container-compose: $(container-compose --version 2>&1 | head -1)" || warn "container-compose not installed (brew install container-compose)"
if [[ -d /Applications/Davit.app ]]; then
  ok "Davit installed: $(defaults read /Applications/Davit.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo '?')"
  have davit || note "Davit's headless CLI is not on PATH. Add it: ln -s '/Applications/Davit.app/Contents/MacOS/Davit' \"$(brew --prefix 2>/dev/null || echo /usr/local)/bin/davit\""
else
  warn "Davit (GUI) not installed (brew install wouterdebie/tap/davit)"
fi

head1 "Other container runtimes on this machine"
FOUND=0
[[ -d /Applications/Docker.app ]]          && { warn "Docker Desktop is installed"; FOUND=1; }
pgrep -qf 'Docker Desktop' 2>/dev/null     && { warn "Docker Desktop is RUNNING - it is holding RAM and a VM"; FOUND=1; }
[[ -d /Applications/Rancher\ Desktop.app ]] && { warn "Rancher Desktop is installed"; FOUND=1; }
if have colima; then
  if colima status >/dev/null 2>&1; then warn "Colima is installed and RUNNING"; else warn "Colima is installed (stopped)"; fi
  FOUND=1
fi
have podman                                && { warn "Podman is installed"; FOUND=1; }
[[ -d /Applications/OrbStack.app ]]        && { warn "OrbStack is installed (free tier is personal, non-commercial only)"; FOUND=1; }
if (( FOUND == 0 )); then
  ok "no competing runtimes found"
else
  note "Runtimes can coexist, but only one Docker context is active at a time. Use scripts/switch-runtime.sh."
fi

head1 "Disk"
if have container && container system status >/dev/null 2>&1; then
  container system df 2>/dev/null | sed 's/^/       /'
fi

head1 "Summary"
if (( PROBLEMS == 0 )); then
  ok "no blocking problems found"
else
  fail "$PROBLEMS blocking problem(s) - see above"
fi
exit $(( PROBLEMS > 0 ? 1 : 0 ))
