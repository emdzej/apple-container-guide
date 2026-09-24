#!/usr/bin/env bash
# socktainer-service.sh - run the Docker-compatible socket daemon as a login agent.
#
#   start      install + load a LaunchAgent (survives logout and reboot)
#   stop       unload it
#   restart
#   status     is it alive, where is the socket, is the docker context right
#   fg         run in the foreground (logs on your terminal - best for debugging)
#   logs       tail the log
#   uninstall  remove the LaunchAgent entirely
#
# Env:
#   SOCKTAINER_VOLUME_SYNC=nosync|fsync|full   default nosync, see docs/07-storage.md
#
# Why not `brew services start socktainer`?
# Because Homebrew's generated plist sets HOME=$(brew --prefix)/var/run/socktainer.
# socktainer derives both its socket path and the Docker context file from HOME, so
# with brew services you get:
#     socket   -> $(brew --prefix)/var/run/socktainer/.socktainer/container.sock
#     context  -> $(brew --prefix)/var/run/socktainer/.docker/contexts/...
# The socket works, but the context is written somewhere your docker CLI never
# looks, so `docker context use socktainer` fails with "context not found".
# This script installs its own agent with HOME set to your real home instead.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

have socktainer || die "socktainer not installed: brew install socktainer"

LABEL="dev.local.socktainer"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/socktainer.log"
ERRLOG="$HOME/Library/Logs/socktainer.error.log"
DOMAIN="gui/$(id -u)"
BIN="$(command -v socktainer)"
SYNC="${SOCKTAINER_VOLUME_SYNC:-nosync}"

write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--volume-sync=$SYNC</string>
  </array>
  <!-- HOME is the whole point: socktainer puts its socket in \$HOME/.socktainer
       and its docker context in \$HOME/.docker. Both must be your real home. -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$(dirname "$BIN"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$ERRLOG</string>
</dict>
</plist>
PLIST_EOF
}

case "${1:-status}" in
  start)
    require_container_cli
    ensure_container_running
    if socktainer_up; then ok "already running on $SOCKTAINER_SOCK"; exit 0; fi

    # brew's own agent would race ours for the same binary and confuse the socket path.
    if have brew && brew services list 2>/dev/null | awk '$1=="socktainer" && $2!="none"{exit 0} END{exit 1}'; then
      warn "Homebrew's socktainer service is running - stopping it (see the note at the top of this script)"
      brew services stop socktainer >/dev/null 2>&1
    fi
    # A socket file left behind by a crashed process makes every docker call hang.
    [[ -S "$SOCKTAINER_SOCK" ]] && { warn "removing stale socket"; rm -f "$SOCKTAINER_SOCK"; }

    write_plist
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
    run "loading $LABEL" launchctl bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed"

    for _ in $(seq 1 40); do socktainer_up && break; sleep 0.5; done
    if ! socktainer_up; then
      fail "socktainer did not come up"
      note "last lines of $ERRLOG:"; tail -15 "$ERRLOG" 2>/dev/null | sed 's/^/       /'
      note "try running it in the foreground: $0 fg"
      exit 1
    fi
    ok "socktainer up on $SOCKTAINER_SOCK"

    EP="$(docker context inspect socktainer --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
    if [[ "$EP" == "unix://$SOCKTAINER_SOCK" ]]; then
      ok "docker context 'socktainer' points at it"
      note "select it with: docker context use socktainer"
    else
      warn "the docker context is missing or points elsewhere (${EP:-none}); creating it"
      docker context create socktainer --docker "host=unix://$SOCKTAINER_SOCK" >/dev/null 2>&1 \
        || docker context update socktainer --docker "host=unix://$SOCKTAINER_SOCK" >/dev/null 2>&1
      ok "context set to unix://$SOCKTAINER_SOCK"
    fi
    grep -q 'compatibility warning' "$LOG" 2>/dev/null && {
      warn "socktainer logged an Apple Container version-compatibility warning:"
      grep -A2 'compatibility warning' "$LOG" | tail -3 | sed 's/^/       /'
      note "Fix the version skew (./doctor.sh) - XPC errors downstream usually trace back to this."
    }
    ;;

  stop)
    run "unloading $LABEL" launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    have brew && brew services stop socktainer >/dev/null 2>&1
    rm -f "$SOCKTAINER_SOCK" 2>/dev/null
    ok "stopped"
    ;;

  restart) "$SELF" stop; "$SELF" start ;;

  fg)
    require_container_cli
    ensure_container_running
    info "foreground mode, Ctrl-C to stop (socket: $SOCKTAINER_SOCK)"
    exec socktainer --volume-sync="$SYNC"
    ;;

  status)
    if socktainer_up; then
      ok "answering on $SOCKTAINER_SOCK"
      curl -s --unix-socket "$SOCKTAINER_SOCK" http://localhost/version 2>/dev/null | \
        { have jq && jq -r '"       Docker API \(.ApiVersion), socktainer \(.Components[0].Version)"' || cat; }
    elif [[ -S "$SOCKTAINER_SOCK" ]]; then
      fail "socket exists but is dead (stale) -> $0 restart"
    else
      warn "not running -> $0 start"
    fi
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && ok "LaunchAgent $LABEL is loaded" || note "LaunchAgent not loaded"
    if have brew && brew services list 2>/dev/null | awk '$1=="socktainer" && $2!="none"{exit 0} END{exit 1}'; then
      warn "Homebrew's socktainer service is ALSO running - its socket path differs; stop it: brew services stop socktainer"
    fi
    EP="$(docker context inspect socktainer --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
    [[ -n "$EP" ]] && info "docker context 'socktainer' -> $EP" || warn "no 'socktainer' docker context"
    ;;

  logs) tail -f "$LOG" "$ERRLOG" ;;

  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    ok "removed $PLIST"
    ;;

  -h|--help) usage "$SELF" ;;
  *) die "unknown command: $1 (start|stop|restart|status|fg|logs|uninstall)" ;;
esac
