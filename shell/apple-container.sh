# shellcheck shell=bash
# Apple container shell integration - aliases and helpers for zsh and bash.
#
# Install:
#     echo 'source /path/to/apple-container-guide/shell/apple-container.sh' >> ~/.zshrc
#
# Options (set these BEFORE sourcing):
#     AC_NO_ALIASES=1     functions only, skip the two-letter aliases
#     AC_DOCKER_SHIM=1     wrap docker() so a dead socktainer fails loudly instead of hanging
#     AC_COMPOSE=...       which compose front end cup/cdown use (see the Compose section)
#     AC_SHELL_IMAGE=...   image used by helpers that need a throwaway container
#
# Run `achelp` after sourcing for the full list. Every helper shells out to the
# real CLI - `type <name>` shows you exactly what it does.
#
# Naming: nothing here shadows a real command. In particular there is no `cd`
# alias, and the "shell into a container" helper is `cinto`, not `csh` (which is
# the C shell). If you never use /bin/csh, `alias csh=cinto` is fair game.

: "${AC_SHELL_IMAGE:=docker.io/library/alpine:3.22}"
: "${AC_SOCK:=$HOME/.socktainer/container.sock}"

# ---------------------------------------------------------------------------
# jq is required by the inspection helpers only. Fail with a useful message
# rather than an empty result.
# ---------------------------------------------------------------------------
ac_jq() {
  if command -v jq >/dev/null 2>&1; then command jq "$@"
  else echo "this helper needs jq: brew install jq" >&2; return 127; fi
}

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
if [ -z "${AC_NO_ALIASES:-}" ]; then
  alias c='container'
  alias cr='container run --rm'
  alias cri='container run --rm -it'
  alias crd='container run -d'
  alias cls='container ls'
  alias cla='container ls -a'
  alias cb='container build'
  alias cim='container image ls'
  alias cvl='container volume ls'
  alias cnl='container network ls'
  alias cst='container stats'
  alias cdf='container system df'
  alias ci='container inspect'
  alias cpl='container image pull'
  alias cph='container image push'

  # System services. There is no always-on daemon: starting and stopping the
  # services is cheap, and `container system stop` really does release the RAM.
  alias csys='container system'
  alias csysup='container system start'
  alias csysdown='container system stop'
  alias csysst='container system status'
  alias cslog='container system logs'
fi

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

# Interactive shell in a running container. Tries bash, falls back to sh, so it
# works on alpine and ubuntu without you having to remember which.
cinto() {
  local ctr="${1:?usage: cinto <container> [shell]}"
  if [ -n "${2:-}" ]; then container exec -it "$ctr" "$2"; return; fi
  container exec -it "$ctr" bash 2>/dev/null || container exec -it "$ctr" sh
}

# One-off command, no TTY.
cx() {
  local ctr="${1:?usage: cx <container> <command...>}"; shift
  container exec "$ctr" "$@"
}

# Follow logs, last 100 lines by default.
clog() { container logs -f -n "${2:-100}" "${1:?usage: clog <container> [lines]}"; }

# Guest VM boot log. When a container "starts" and immediately dies with nothing
# in the normal logs, the reason is in here - this is the one diagnostic that has
# no Docker equivalent, because Docker has no per-container VM to boot.
cboot() { container logs --boot "${1:?usage: cboot <container>}"; }

# IP of a container, or a table of all of them. Every container is its own VM
# with its own address, so you look this up a lot.
cip() {
  if [ $# -eq 0 ]; then
    container ls --format json \
      | ac_jq -r '.[] | [.configuration.id, (.status.networks[0].ipv4Address // "-"), .status.state] | @tsv' \
      | column -t
  else
    container inspect "$1" | ac_jq -r '.[0].status.networks[0].ipv4Address // empty' | cut -d/ -f1
  fi
}

# Published host -> container port mappings.
cports() {
  container inspect "${1:?usage: cports <container>}" \
    | ac_jq -r '.[0].configuration.publishedPorts[]? | "\(.hostAddress):\(.hostPort) -> \(.containerPort)/\(.proto)"'
}

cenv() {
  container inspect "${1:?usage: cenv <container>}" \
    | ac_jq -r '.[0].configuration.initProcess.environment[]?'
}

# Open a container's first published port in the browser.
copen() {
  local port
  port="$(container inspect "${1:?usage: copen <container>}" \
          | ac_jq -r '.[0].configuration.publishedPorts[0].hostPort // empty')"
  [ -n "$port" ] || { echo "copen: $1 publishes no ports" >&2; return 1; }
  open "http://localhost:$port"
}

# Resources actually allocated to each container's VM. Useful because these are
# hard reservations at boot, not elastic limits.
cres() {
  container ls -a --format json \
    | ac_jq -r '["NAME","CPUS","MEM","STATE"], (.[] | [.configuration.id, (.configuration.resources.cpus|tostring), ((.configuration.resources.memoryInBytes/1073741824*10|round/10|tostring)+"G"), .status.state]) | @tsv' \
    | column -t
}

cstopall() { container stop --all; }

crmall() {
  printf 'Delete ALL containers (running ones are stopped first)? [y/N] '
  local r; read -r r
  case "$r" in
    y|Y|yes) container stop --all 2>/dev/null; container ls -a -q | xargs container rm 2>/dev/null; echo "done" ;;
    *) echo "aborted" ;;
  esac
}

# Prune what is safe to prune. Volumes are deliberately left alone: pruning them
# destroys their contents with no undo.
cprune() {
  container prune
  container image prune
  container network prune
  echo
  echo "Volumes untouched. 'container volume prune' deletes their contents permanently."
  container system df
}

# ---------------------------------------------------------------------------
# Images and builds
# ---------------------------------------------------------------------------

# Throwaway shell in any image: cshell node:22 bash
cshell() { container run --rm -it "${1:-$AC_SHELL_IMAGE}" "${2:-sh}"; }

# Same, with the current directory mounted at /work.
cwork() { container run --rm -it -v "$PWD:/work" -w /work "${1:-$AC_SHELL_IMAGE}" "${2:-sh}"; }

# The builder VM defaults to 2 CPUs / 2 GiB, which is not enough for most real
# images. Resources can only be set at builder start, so this recreates it.
cbigbuilder() {
  container builder stop 2>/dev/null
  container builder delete 2>/dev/null
  container builder start --cpus "${1:-6}" --memory "${2:-12g}"
}

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------
cvinto() { container run --rm -it -v "${1:?usage: cvinto <volume>}:/vol" -w /vol "$AC_SHELL_IMAGE" sh; }
cvsize() { container run --rm -v "${1:?usage: cvsize <volume>}:/vol:ro" "$AC_SHELL_IMAGE" du -sh /vol; }

cvbackup() {
  local v="${1:?usage: cvbackup <volume> [outdir]}" out="${2:-$PWD}" stamp
  stamp="$(date +%Y%m%d%H%M%S)"
  mkdir -p "$out"
  container run --rm -v "$v:/vol:ro" -v "$out:/backup" "$AC_SHELL_IMAGE" \
    tar -czf "/backup/$v-$stamp.tar.gz" -C /vol . \
    && echo "wrote $out/$v-$stamp.tar.gz"
}

cvrestore() {
  local v="${1:?usage: cvrestore <volume> <archive.tar.gz>}" f="${2:?}" dir
  [ -f "$f" ] || { echo "no such archive: $f" >&2; return 1; }
  dir="$(cd "$(dirname "$f")" && pwd)"
  container volume inspect "$v" >/dev/null 2>&1 || container volume create "$v"
  container run --rm -v "$v:/vol" -v "$dir:/in:ro" "$AC_SHELL_IMAGE" \
    tar -xzf "/in/$(basename "$f")" -C /vol
}

# ---------------------------------------------------------------------------
# Container machines - persistent general-purpose Linux VMs. Not containers:
# your host user, your home mounted, your cwd carried through, filesystem
# survives a stop. See docs/13-machines.md
# ---------------------------------------------------------------------------
: "${AC_MACHINE_IMAGE:=docker.io/library/alpine:3.22}"
: "${AC_MACHINE_CPUS:=4}"
: "${AC_MACHINE_MEMORY:=8G}"

cmls() { container machine list "$@"; }

# `machine create` returns, and `machine list` says "running", a few seconds
# before `machine run` works - until then it errors with "Operation not
# supported by device". Wait for it to actually accept a command.
cmwait() {
  local m="${1:?usage: cmwait <machine>}" i=0
  while [ "$i" -lt 60 ]; do
    container machine run -n "$m" -- true >/dev/null 2>&1 && return 0
    sleep 1; i=$((i+1))
  done
  echo "cmwait: $m never became ready (try: cmboot $m)" >&2
  return 1
}

# Create with defaults worth having. Memory otherwise defaults to HALF your RAM.
cmnew() {
  local name="${1:?usage: cmnew <name> [image] [cpus] [memory]}"
  container machine create "${2:-$AC_MACHINE_IMAGE}" \
    --name "$name" \
    --cpus "${3:-$AC_MACHINE_CPUS}" \
    --memory "${4:-$AC_MACHINE_MEMORY}" || return 1
  cmwait "$name" && echo "machine '$name' ready"
}

# Interactive login shell. Boots the machine first if it is stopped.
cminto() { container machine run -n "${1:?usage: cminto <machine>}"; }

# Run a command. Pass it as separate words, NOT as a quoted shell string -
# `machine run -- sh -c 'echo hi'` is word-split by the platform and silently
# does nothing. Use cmsh for anything needing a shell.
cmx() {
  local m="${1:?usage: cmx <machine> <command> [args...]}"; shift
  container machine run -n "$m" -- "$@"
}

# Run a shell script in a machine, read from stdin or a heredoc. This is the
# reliable way to run multi-command shell in a machine.
#   cmsh dev <<'EOF'
#   apk add --no-cache git
#   git clone git@github.com:me/repo   # the host SSH agent is already forwarded
#   EOF
cmsh() {
  local m="${1:?usage: cmsh <machine>   (script on stdin)}"
  container machine run -n "$m" -i -- sh
}

cmip() {
  container machine inspect "${1:?usage: cmip <machine>}" | ac_jq -r '.[0].ipAddress // empty'
}

cmstop()  { container machine stop "${1:?usage: cmstop <machine>}"; }
cmrm()    { container machine stop "${1:?usage: cmrm <machine>}" 2>/dev/null; container machine delete "$1"; }
cmlog()   { container machine logs "${1:?usage: cmlog <machine>}" "${@:2}"; }
cmboot()  { container machine logs --boot "${1:?usage: cmboot <machine>}"; }
cmset()   { local m="${1:?usage: cmset <machine> key=value...}"; shift; container machine set -n "$m" "$@"; echo "applies on next boot: cmstop $m"; }

# ---------------------------------------------------------------------------
# Compose
#
# Three front ends can drive a compose file on this platform and they are not
# equivalent - see docs/04-compose.md. Pick one here:
#     AC_COMPOSE=container-compose   (default) Apple-native, smallest feature set
#     AC_COMPOSE=docker              docker compose through socktainer, widest coverage
#     AC_COMPOSE=davit               davit compose, healthchecks + /etc/hosts discovery
# ---------------------------------------------------------------------------
: "${AC_COMPOSE:=container-compose}"

ccompose() {
  case "$AC_COMPOSE" in
    container-compose) command container-compose "$@" ;;
    docker)            command docker compose "$@" ;;
    davit)             command davit compose "$@" ;;
    *) echo "AC_COMPOSE must be container-compose, docker or davit (got '$AC_COMPOSE')" >&2; return 2 ;;
  esac
}
cup()     { ccompose up "$@"; }
cdown()   { ccompose down "$@"; }
cbuildc() { ccompose build "$@"; }
cps()     { ccompose ps "$@"; }

cwhichcompose() {
  echo "AC_COMPOSE=$AC_COMPOSE"
  command -v container-compose >/dev/null 2>&1 && echo "  container-compose  $(container-compose --version 2>&1 | head -1)"
  command -v docker >/dev/null 2>&1 && echo "  docker compose     $(docker compose version 2>&1 | head -1)  [needs socktainer + the socktainer context]"
  command -v davit  >/dev/null 2>&1 && echo "  davit compose      $(davit --version 2>&1 | head -1)"
}

# ---------------------------------------------------------------------------
# socktainer and docker contexts
# ---------------------------------------------------------------------------
sockok() { [ -S "$AC_SOCK" ] && curl -s --unix-socket "$AC_SOCK" http://localhost/_ping >/dev/null 2>&1; }

sockup() {
  if sockok; then echo "socktainer already up"; return 0; fi
  # A socket file left by a crashed process makes every docker call hang.
  if [ -S "$AC_SOCK" ]; then echo "removing stale socket"; rm -f "$AC_SOCK"; fi
  container system status >/dev/null 2>&1 || container system start
  brew services start socktainer
  local i=0
  while [ "$i" -lt 30 ]; do sockok && break; sleep 0.5; i=$((i+1)); done
  if sockok; then
    docker context use socktainer >/dev/null 2>&1 && echo "socktainer up, docker -> socktainer"
  else
    echo "socktainer did not come up. Try: socktainer   (foreground, shows why)" >&2
    return 1
  fi
}

sockdown()   { brew services stop socktainer; rm -f "$AC_SOCK" 2>/dev/null; }
sockstatus() {
  if sockok; then echo "socktainer: up   ($AC_SOCK)"
  elif [ -S "$AC_SOCK" ]; then echo "socktainer: STALE socket - run sockup"
  else echo "socktainer: down"; fi
}

# What is `docker` actually talking to? Check this before blaming a tool for not
# seeing your containers - it is the single most common cause.
dwhich() {
  local ctx ep
  ctx="$(docker context show 2>/dev/null)"
  ep="$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
  printf 'context : %s\nendpoint: %s\n' "${ctx:-none}" "${ep:-unknown}"
  [ -n "${DOCKER_HOST:-}" ] && printf 'DOCKER_HOST=%s   <-- overrides the context\n' "$DOCKER_HOST"
  case "$ep" in
    *socktainer*)             echo "runtime : Apple container" ;;
    *.docker/run/docker.sock) echo "runtime : Docker Desktop" ;;
    *colima*)                 echo "runtime : Colima" ;;
    *orbstack*)               echo "runtime : OrbStack" ;;
    *)                        echo "runtime : unrecognised" ;;
  esac
}

duse() {
  case "${1:-}" in
    apple|container|socktainer) sockup || return 1 ;;
    desktop)
      local ctx
      ctx="$(docker context ls --format '{{.Name}} {{.DockerEndpoint}}' 2>/dev/null | awk '/\.docker\/run\/docker\.sock/{print $1; exit}')"
      [ -n "$ctx" ] || { echo "no Docker Desktop context found" >&2; return 1; }
      open -ga Docker 2>/dev/null
      docker context use "$ctx" >/dev/null || return 1 ;;
    colima)
      colima status >/dev/null 2>&1 || colima start
      docker context use colima >/dev/null || return 1 ;;
    orbstack|orb)
      if command -v orb >/dev/null 2>&1; then
        orb status >/dev/null 2>&1 || orb start
      else
        open -ga OrbStack 2>/dev/null
        local i=0
        while [ "$i" -lt 30 ]; do
          docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx orbstack && break
          sleep 1; i=$((i+1))
        done
      fi
      docker context use orbstack >/dev/null || return 1 ;;
    *) echo "usage: duse apple|desktop|colima|orbstack" >&2; return 2 ;;
  esac
  dwhich
}

# ---------------------------------------------------------------------------
# System
# ---------------------------------------------------------------------------

# Inter-container connections start failing with EHOSTUNREACH after a lot of
# network churn (many networks created and destroyed). Restarting the services
# resets vmnet's state; this is the documented fix, not a superstition.
cnetreset() {
  container system stop && container system start
  sockok && { echo "restarting socktainer..."; brew services restart socktainer; }
  echo "vmnet state reset"
}

# The merged configuration the service is really using, config.toml plus defaults.
cconf() { container system property list "$@"; }

# ---------------------------------------------------------------------------
# zsh completion for the helpers
# ---------------------------------------------------------------------------
# compdef only exists once compinit has run. In a non-interactive zsh, or if the
# user sources this before compinit, skip completion rather than erroring.
if [ -n "${ZSH_VERSION:-}" ] && whence -w compdef >/dev/null 2>&1; then
  _ac_containers() { compadd -- $(container ls -a -q 2>/dev/null); }
  _ac_volumes()    { compadd -- $(container volume ls 2>/dev/null | awk 'NR>1{print $1}'); }
  _ac_images()     { compadd -- $(container image ls 2>/dev/null | awk 'NR>1 && $2!="<none>"{printf "%s:%s\n", $1, $2}'); }
  compdef _ac_containers cinto cx clog cboot cip cports cenv copen
  _ac_machines()   { compadd -- $(container machine list -q 2>/dev/null); }
  compdef _ac_volumes    cvinto cvsize cvbackup cvrestore
  compdef _ac_machines   cminto cmx cmsh cmip cmstop cmrm cmlog cmboot cmset cmwait
  compdef _ac_images     cshell cwork
fi

# ---------------------------------------------------------------------------
# Optional docker shim
#
# This deliberately does NOT translate docker flags into container flags. The
# two CLIs disagree on enough flags (--privileged, --restart, --add-host, -i,
# --network host) that a partial translation silently changes what your command
# means, which is worse than an error. What it does do is make the most common
# failure legible: docker pointed at socktainer while socktainer is down, which
# otherwise hangs and then prints a socket error that names no cause.
# ---------------------------------------------------------------------------
if [ "${AC_DOCKER_SHIM:-0}" = "1" ]; then
  docker() {
    local ep
    ep="$(command docker context inspect "$(command docker context show 2>/dev/null)" \
          --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
    case "$ep" in
      *socktainer*)
        if ! sockok; then
          echo "docker: the active context points at socktainer, but it is not answering." >&2
          echo "        start it:        sockup" >&2
          echo "        or switch:       duse desktop" >&2
          return 1
        fi ;;
    esac
    command docker "$@"
  }
fi

# ---------------------------------------------------------------------------
achelp() {
  cat <<'HELP'
Apple container helpers  (type <name> shows the implementation)

containers  cinto <c> [sh]    interactive shell (tries bash, then sh)
            cx <c> <cmd...>   one-off exec, no TTY
            clog <c> [n]      follow logs
            cboot <c>         guest VM boot log - where "started then died" is explained
            cip [c]           IP of one container, or a table of all
            cports <c>        published port mappings
            cenv <c>          environment
            cres              CPUs/memory reserved per container VM
            copen <c>         open first published port in a browser
            cstopall          stop everything
            crmall            delete every container (asks first)
            cprune            prune containers+images+networks, then show df

images      cshell [img] [sh] throwaway shell in an image
            cwork [img] [sh]  same, with $PWD mounted at /work
            cbigbuilder [cpus] [mem]   recreate the builder VM with real resources

volumes     cvinto <v>        shell into a volume
            cvsize <v>        du -sh
            cvbackup <v> [d]  tar.gz a volume onto your Mac
            cvrestore <v> <f> restore from one

machines    cmls              list machines (persistent Linux VMs, not containers)
            cmnew <n> [img]   create (4 cpus / 8G; default is HALF your RAM)
            cminto <n>        interactive shell (boots it if stopped)
            cmx <n> <cmd...>  run a command - separate words, not a quoted string
            cmsh <n>          run a shell script from stdin/heredoc
            cmip <n>          current IP (changes across restarts)
            cmset <n> k=v     change cpus/memory/home-mount (needs a restart)
            cmwait <n>        block until it accepts commands (create returns early)
            cmstop / cmrm / cmlog / cmboot <n>

compose     cup / cdown / cbuildc / cps    via $AC_COMPOSE
            cwhichcompose     what is installed, and what each needs

docker      dwhich            what is 'docker' talking to right now
            duse apple|desktop|colima|orbstack   switch runtime
            sockup / sockdown / sockstatus

system      csysup / csysdown / csysst     container system start|stop|status
            cconf             merged config.toml + defaults
            cnetreset         fix EHOSTUNREACH after heavy network churn
            cdf               disk usage

aliases     c cr cri crd cls cla cb cim cvl cnl cst cdf ci cpl cph
            csys csysup csysdown csysst cslog
HELP
}
