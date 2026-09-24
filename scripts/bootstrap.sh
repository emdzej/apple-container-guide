#!/usr/bin/env bash
# bootstrap.sh - install the Apple container toolchain and bring it up.
#
#   ./scripts/bootstrap.sh              # runtime + socktainer + compose + Davit
#   ./scripts/bootstrap.sh --minimal    # runtime only
#   ./scripts/bootstrap.sh --no-gui     # skip Davit
#   DRY_RUN=1 ./scripts/bootstrap.sh    # print what it would do
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

WANT_SOCKTAINER=1; WANT_COMPOSE=1; WANT_GUI=1; WANT_COMPLETIONS=1
for arg in "$@"; do
  case "$arg" in
    --minimal)        WANT_SOCKTAINER=0; WANT_COMPOSE=0; WANT_GUI=0 ;;
    --no-gui)         WANT_GUI=0 ;;
    --no-socktainer)  WANT_SOCKTAINER=0 ;;
    --no-compose)     WANT_COMPOSE=0 ;;
    --no-completions) WANT_COMPLETIONS=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown flag: $arg" ;;
  esac
done

require_apple_silicon
require_macos 26

# Everything in the Apple container ecosystem is in Homebrew core except the GUI
# (its own tap), so brew is the path of least resistance: one `brew upgrade`
# keeps the CLI, the apiserver and the plugins in the same keg and therefore the
# same version. The official .pkg is the only other option, and mixing the two
# is what produces the client/daemon skew this script warns about below.
if ! have brew; then
  fail "Homebrew not found, and every install step here goes through brew."
  note "Either install Homebrew (https://brew.sh) and re-run this script, or install"
  note "the runtime manually from the signed installer:"
  note "  1. download the .pkg from https://github.com/apple/container/releases"
  note "  2. open it, follow the prompts"
  note "  3. container system start"
  note "  4. upgrade later with: sudo /usr/local/bin/update-container.sh"
  note "The other tools (socktainer, container-compose, Davit) ship prebuilt binaries"
  note "on their GitHub release pages if you go that route."
  exit 1
fi
ok "using Homebrew at $(brew --prefix)"

head1 "1. Runtime"
if have container; then
  ok "container already installed ($(container --version 2>&1 | head -1))"
else
  # Homebrew keeps the CLI, the apiserver and the plugins in one keg, so
  # `brew upgrade` moves all of them together. The official .pkg installs into
  # /usr/local and updates via /usr/local/bin/update-container.sh instead.
  run "installing apple/container via Homebrew" brew install container || die "install failed"
fi
if [[ -x /usr/local/bin/container ]] && [[ "$(command -v container)" != "/usr/local/bin/container" ]]; then
  warn "An official .pkg install also exists at /usr/local."
  note "Two installs means the CLI and daemon can be different builds. Remove one:"
  note "  sudo /usr/local/bin/uninstall-container.sh      # drop the .pkg install"
  note "  brew uninstall container                        # or drop the Homebrew one"
fi
run "starting system services" container system start || warn "container system start reported an error"

head1 "2. Docker API compatibility"
if (( WANT_SOCKTAINER )); then
  have socktainer && ok "socktainer already installed" || run "installing socktainer" brew install socktainer
  have docker || { warn "docker CLI missing - socktainer is only useful with a Docker client"; run "installing docker CLI" brew install docker; }
  note "Start it with: ./scripts/socktainer-service.sh start"
else
  note "skipped (--no-socktainer)"
fi

head1 "3. Compose"
if (( WANT_COMPOSE )); then
  have container-compose && ok "container-compose already installed" || run "installing container-compose" brew install container-compose
  note "You will also have 'docker compose' via socktainer and 'davit compose'. See docs/04-compose.md"
else
  note "skipped (--no-compose)"
fi

head1 "4. GUI"
if (( WANT_GUI )); then
  if [[ -d /Applications/Davit.app ]]; then
    ok "Davit already installed"
  else
    run "tapping wouterdebie/tap" brew tap wouterdebie/tap
    run "installing Davit" brew install wouterdebie/tap/davit \
      || warn "install failed - Homebrew 6 may want: brew trust wouterdebie/tap"
  fi
  if [[ -x /Applications/Davit.app/Contents/MacOS/Davit ]] && ! have davit; then
    LINK="$(brew --prefix)/bin/davit"
    if confirm "Link Davit's headless CLI to $LINK?"; then
      run "linking davit CLI" ln -sf /Applications/Davit.app/Contents/MacOS/Davit "$LINK"
    fi
  fi
else
  note "skipped (--no-gui)"
fi

head1 "5. Shell completions"
if (( WANT_COMPLETIONS )); then
  ZDIR="${ZSH_COMPLETION_DIR:-$HOME/.zsh/completion}"
  if [[ -d "$HOME/.oh-my-zsh" ]]; then ZDIR="$HOME/.oh-my-zsh/completions"; fi
  run "writing zsh completion to $ZDIR/_container" mkdir -p "$ZDIR"
  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    container --generate-completion-script zsh > "$ZDIR/_container" && ok "wrote $ZDIR/_container"
    if [[ "$ZDIR" != "$HOME/.oh-my-zsh/completions" ]]; then
      note "Add to ~/.zshrc if not already there:  fpath=($ZDIR \$fpath); autoload -U compinit; compinit"
    fi
  fi
else
  note "skipped (--no-completions)"
fi

head1 "6. Shell aliases"
SNIPPET="source $(cd .. && pwd)/shell/apple-container.sh"
if grep -qsF "apple-container.sh" "$HOME/.zshrc"; then
  ok "aliases already sourced from ~/.zshrc"
else
  note "Add this to ~/.zshrc (or ~/.bashrc) to get the helper aliases:"
  printf '\n    %s\n\n' "$SNIPPET"
  if confirm "Append it to ~/.zshrc now?"; then
    run "appending to ~/.zshrc" bash -c "printf '\n# Apple container helpers\n%s\n' '$SNIPPET' >> '$HOME/.zshrc'"
  fi
fi

head1 "Done"
note "Next: ./scripts/doctor.sh          - verify the setup"
note "      ./scripts/setup-dns.sh       - reach containers by name from the host"
note "      ./scripts/switch-runtime.sh  - point 'docker' at Apple container"
note "      container run --rm alpine echo hello"
