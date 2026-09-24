# 01 — Install

## Requirements

- Apple silicon. There is no x86-64 Mac support, and there won't be.
- **macOS 26 (Tahoe) or later.** macOS 15 technically runs the runtime but the
  networking and DNS features it relies on aren't there, and `container-compose`
  says so in its own README. Don't.
- Rosetta, if you need amd64 images: `softwareupdate --install-rosetta --agree-to-license`

Check with `./scripts/doctor.sh`.

## Pick one install method and stick to it

This matters more than it sounds. The CLI and the `container-apiserver` daemon
talk over XPC, and that protocol is **not** a stable interface between versions.
If they come from different installs you get failures that look like anything
but a version problem.

### Homebrew (recommended)

```bash
brew install container
container system start
```

One keg holds the CLI, the apiserver and the plugins, so `brew upgrade container`
moves all three together. Upgrades are ordinary Homebrew upgrades.

### The official signed `.pkg`

Download from [the releases page](https://github.com/apple/container/releases),
open it, follow the prompts, then:

```bash
container system start
```

It installs to `/usr/local`, needs an administrator password, and upgrades via
its own script:

```bash
container system stop
sudo /usr/local/bin/update-container.sh
container system start
```

### Which to choose

| | Homebrew | `.pkg` |
|---|---|---|
| Upgrade | `brew upgrade container` | `sudo /usr/local/bin/update-container.sh` |
| Install root | `$(brew --prefix)/Cellar/container/<ver>` | `/usr/local` |
| Needs sudo | no | yes |
| Plugins (e.g. `k8s`) | whatever the formula ships | whatever the release ships |
| Pinning a version | `brew pin container` | download an older `.pkg` |

Homebrew, unless you have a reason. It keeps the whole platform in lockstep and
`doctor.sh` can reason about it.

### If you already have both

That's the single most common broken state. Symptoms: `container system status`
shows a `client.version` and a `server.version` that don't match, plugins report
"not found" even though the binary is on disk, and socktainer logs a
compatibility warning at startup.

```bash
container system stop

# keep Homebrew, drop the .pkg:
sudo /usr/local/bin/uninstall-container.sh

# or the reverse:
brew uninstall container

container system start
./scripts/doctor.sh
```

## The rest of the toolchain

```bash
brew install socktainer          # Docker API compatibility — see docs/05
brew install container-compose   # Apple-native compose front end — see docs/04
brew install docker              # the CLI only; no Desktop, no daemon
brew install wouterdebie/tap/davit   # GUI + headless CLI — see docs/08
brew install jq                  # some shell helpers here need it
```

`./scripts/bootstrap.sh` does all of the above, plus starts the services, installs
zsh completions, and offers to wire up the shell helpers.

### Homebrew 6 and third-party taps

Davit lives in its own tap, and Homebrew 6 asks you to trust a tap before first
use:

```bash
brew tap wouterdebie/tap
brew trust wouterdebie/tap
brew install wouterdebie/tap/davit
```

## Starting and stopping

```bash
container system start     # boots the apiserver + network/runtime plugins
container system status    # versions, paths, counts — read this when confused
container system stop      # really stops; nothing is left resident
container system logs      # the platform's own logs, not your containers'
```

There's no always-on daemon to leave running. `container system stop` releases
everything, which is most of the point of the exercise.

Want it up at login? The launchd services installed by `container system start`
persist across reboots already. socktainer is separate —
`./scripts/socktainer-service.sh start` installs a LaunchAgent for it.

## Shell completions

```bash
mkdir -p ~/.zsh/completion
container --generate-completion-script zsh > ~/.zsh/completion/_container
# and in ~/.zshrc:
#   fpath=(~/.zsh/completion $fpath); autoload -U compinit; compinit
```

With oh-my-zsh, write it to `~/.oh-my-zsh/completions/_container` instead — that
directory is already on the function path. The file must be named `_container`.

bash and fish: `container --generate-completion-script bash|fish`.

The helpers in `shell/apple-container.sh` add completion for container, image and
volume names on their own functions.

## Coexisting with Docker Desktop

Both can be installed simultaneously. They don't share state and they don't
fight, with two exceptions worth knowing:

- **Port conflicts.** If Docker Desktop is publishing `:5432` and you publish
  `:5432` from Apple container, the second one fails. Stop one, or use different
  host ports during the transition.
- **RAM.** Docker Desktop's VM is resident whether you're using it or not. If
  you're testing Apple container's memory story, quit Docker Desktop first or the
  comparison is meaningless.

Switching which one `docker` talks to is a context change:

```bash
./scripts/switch-runtime.sh apple      # starts socktainer, selects its context
./scripts/switch-runtime.sh desktop    # back to Docker Desktop
./scripts/switch-runtime.sh            # what am I pointed at right now?
```

Or with the shell helpers loaded: `duse apple`, `duse desktop`, `dwhich`.

## Rollback

Nothing here is one-way until you run the uninstaller.

```bash
./scripts/switch-runtime.sh desktop    # instant: docker talks to Docker Desktop again
container system stop                  # free the resources
```

Full removal of Apple container:

```bash
container system stop
brew uninstall container socktainer container-compose
sudo /usr/local/bin/uninstall-container.sh    # if you used the .pkg
rm -rf ~/Library/Application\ Support/com.apple.container
rm -rf ~/.config/container ~/.socktainer
rm -f  ~/Library/LaunchAgents/dev.local.socktainer.plist
docker context rm socktainer
```

`~/Library/Application Support/com.apple.container/` is where images, containers
and volumes live — removing it is the destructive step.

## Next

- [02 — Migrate](02-migrate.md): getting your images, volumes and stacks across.
- [12 — Alternatives](12-alternatives.md): if you are still deciding between
  Apple container, Podman, Colima, Rancher Desktop, OrbStack and Finch —
  including which of them are free for commercial use.
