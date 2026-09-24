#!/usr/bin/env bash
# uninstall-docker-desktop.sh - remove Docker Desktop once you are confident in
# the Apple container setup.
#
#   ./scripts/uninstall-docker-desktop.sh            # DRY RUN by default - shows what it would touch
#   ./scripts/uninstall-docker-desktop.sh --execute   # actually do it
#   ./scripts/uninstall-docker-desktop.sh --keep-cli  # leave the docker/compose CLIs in place
#
# This deletes Docker Desktop's VM disk image, which contains every image,
# container and volume it was holding. Migrate first:
#     ./scripts/migrate-images.sh --all
#     ./scripts/migrate-volumes.sh --all
#
# The docker CLI itself is worth keeping - it is what talks to socktainer.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

EXECUTE=0; KEEP_CLI=1
for arg in "$@"; do
  case "$arg" in
    --execute)  EXECUTE=1 ;;
    --keep-cli) KEEP_CLI=1 ;;
    --purge-cli) KEEP_CLI=0 ;;
    -h|--help)  usage "$SELF"; exit 0 ;;
    *)          die "unknown flag: $arg" ;;
  esac
done
# DRY_RUN is consumed by run() in lib/common.sh.
# shellcheck disable=SC2034
(( EXECUTE )) || DRY_RUN=1

PATHS=(
  "/Applications/Docker.app"
  "$HOME/Library/Group Containers/group.com.docker"
  "$HOME/Library/Containers/com.docker.docker"
  "$HOME/Library/Containers/com.docker.helper"
  "$HOME/Library/Application Scripts/group.com.docker"
  "$HOME/Library/Caches/com.docker.docker"
  "$HOME/Library/Caches/KSCrashReports/Docker"
  "$HOME/Library/Preferences/com.docker.docker.plist"
  "$HOME/Library/Preferences/com.electron.docker-frontend.plist"
  "$HOME/Library/Saved Application State/com.electron.docker-frontend.savedState"
  "$HOME/Library/Logs/Docker Desktop"
  "$HOME/.docker/desktop"
)

head1 "Pre-flight"
[[ -d /Applications/Docker.app ]] || { ok "Docker Desktop is not installed - nothing to do"; exit 0; }

VM="$HOME/Library/Containers/com.docker.docker/Data/vms"
if [[ -d "$VM" ]]; then
  warn "Docker Desktop's VM data is $(du -sh "$VM" 2>/dev/null | awk '{print $1}') and will be deleted."
fi

if docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx "$(docker_desktop_context)" \
   && docker --context "$(docker_desktop_context)" info >/dev/null 2>&1; then
  IMG_N="$(docker --context "$(docker_desktop_context)" image ls -q | wc -l | tr -d ' ')"
  VOL_N="$(docker --context "$(docker_desktop_context)" volume ls -q | wc -l | tr -d ' ')"
  warn "Docker Desktop currently holds $IMG_N image(s) and $VOL_N volume(s). These go away."
  note "Migrate them first: ./scripts/migrate-images.sh --all && ./scripts/migrate-volumes.sh --all"
else
  note "Docker Desktop is not running, so its inventory cannot be listed. Start it if you want to check."
fi

if ! socktainer_up; then
  warn "socktainer is not running. Confirm your Apple container setup works BEFORE removing the fallback."
  note "  ./scripts/socktainer-service.sh start && ./scripts/doctor.sh"
fi

head1 "What will be removed"
for p in "${PATHS[@]}"; do
  [[ -e "$p" ]] && printf '       %s  (%s)\n' "$p" "$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
done
if (( ! KEEP_CLI )); then
  note "plus the Homebrew docker CLI formulae (docker, docker-compose, docker-credential-helper)"
fi

if (( ! EXECUTE )); then
  head1 "Dry run"
  note "Nothing was changed. Re-run with --execute to proceed."
  exit 0
fi

head1 "Confirm"
fail "This is irreversible. Docker Desktop's images, containers and volumes will be gone."
confirm "Type y to remove Docker Desktop" || { note "aborted"; exit 1; }

head1 "Removing"
# Docker Desktop ships its own uninstaller, which also unloads its privileged
# helper and vmnetd service. Prefer it over deleting files by hand.
if [[ -x /Applications/Docker.app/Contents/MacOS/uninstall ]]; then
  run "running Docker Desktop's own uninstaller (needs your password)" \
    sudo /Applications/Docker.app/Contents/MacOS/uninstall || warn "the bundled uninstaller failed; falling back to manual removal"
fi
run "quitting Docker Desktop" osascript -e 'quit app "Docker"' || true
pkill -f 'Docker Desktop' 2>/dev/null || true

for p in "${PATHS[@]}"; do
  [[ -e "$p" ]] || continue
  if [[ "$p" == /Applications/* ]]; then
    run "removing $p" sudo rm -rf "$p"
  else
    run "removing $p" rm -rf "$p"
  fi
done

# The privileged helpers survive an app delete and keep re-spawning if left behind.
for svc in com.docker.vmnetd com.docker.socket; do
  [[ -f "/Library/LaunchDaemons/$svc.plist" ]] && {
    run "unloading $svc" sudo launchctl bootout "system/$svc" || true
    run "removing $svc.plist" sudo rm -f "/Library/LaunchDaemons/$svc.plist"
  }
done
[[ -f /Library/PrivilegedHelperTools/com.docker.vmnetd ]] && run "removing vmnetd helper" sudo rm -f /Library/PrivilegedHelperTools/com.docker.vmnetd

if (( ! KEEP_CLI )); then
  have brew && run "removing docker CLI formulae" brew uninstall --ignore-dependencies docker docker-compose 2>/dev/null || true
fi

head1 "Clean up docker contexts"
ctx="$(docker_desktop_context)"
[[ -n "$ctx" ]] && run "removing the $ctx context" docker context rm -f "$ctx" 2>/dev/null || true
have docker && docker context use socktainer 2>/dev/null && ok "docker now points at socktainer"

head1 "Done"
# shellcheck disable=SC2088  # prose, not a path to expand
note "~/.docker/config.json was left alone - it holds your registry logins and credential helpers,"
note "which Apple container and socktainer both read."
note "Verify: ./scripts/doctor.sh"
