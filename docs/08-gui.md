# 08 — GUI

## Davit — the recommended one

[wouterdebie/davit](https://github.com/wouterdebie/davit) is a native SwiftUI app
(no Electron, no web views) that links Apple's own `ContainerAPIClient` and talks
to `container-apiserver` **directly over XPC** — the same wire path the CLI uses.
It never shells out to the `container` binary.

```bash
brew tap wouterdebie/tap
brew trust wouterdebie/tap      # Homebrew 6 wants this for third-party taps
brew install wouterdebie/tap/davit
```

Or the signed DMG from [releases](https://github.com/wouterdebie/davit/releases/latest)
/ [davit.app](https://davit.app).

Requirements: Apple silicon, macOS 15+ (26 recommended).

### What it gives you that the CLI doesn't

- **Live stats** — CPU/memory/disk-IO charts per container (Swift Charts), plus an
  aggregate CPU chart on the dashboard. CPU% is derived from `cpuUsageUsec`
  deltas normalised to wall clock, so 100% = one full core.
- **File browser** — navigate a container's filesystem, download, upload, delete.
  Also works on **volumes**, by mounting them into a throwaway helper container.
  That's genuinely hard to do by hand.
- **Edit & Recreate** — containers are immutable on this platform, so "editing"
  opens the Run sheet prefilled with the container's ports/env/mounts/resources,
  with the image's own entrypoint/CMD/env subtracted so only *your* changes show,
  and replaces it on confirm.
- **Layers tab** — per-layer size and the command that produced it.
- **Terminal** — one click into an interactive shell in Terminal or iTerm.
- **Local DNS setup** — Settings → Platform creates host DNS domains with a single
  admin prompt, instead of the two-step config edit + `sudo container system dns create`.
- **Platform configuration editor** — a real UI over `~/.config/container/config.toml`:
  default container CPUs/memory, registry, DNS domain, builder resources/Rosetta,
  kernel, init image. Only values that differ from defaults are written,
  `[plugin.*]` sections are preserved, and every save is validated through the
  platform's own config loader before commit.
- **amd64 detection** — an amd64-only image is detected before you run it. With
  Rosetta present it adds `--arch amd64` for you and warns about performance;
  without it, the run is blocked with the exact install command to copy.
- **Credential helpers** — honours `credHelpers`/`credsStore` in
  `~/.docker/config.json`, invoking the helper right before each pull. Hourly-
  expiring GCP Artifact Registry and ECR tokens keep working.
- **Machines** — full lifecycle UI for `container machine` micro-VMs.
- **Menu bar extra**, **auto-start containers on launch**, **open at login**,
  **⌘K global search**, **deep links** (`open davit://container/my-app`),
  **stop notifications** for unexpected exits only.
- **In-app updates** via Sparkle, with an EdDSA signature over the archive — a
  trust root independent of the Developer ID certificate.

### The headless CLI

The app binary doubles as a tool, which is the part most people miss. Link it:

```bash
ln -sf /Applications/Davit.app/Contents/MacOS/Davit "$(brew --prefix)/bin/davit"
```

```bash
davit platform status            # every platform install found, versions, which one it drives
davit platform install|remove    # download + verify Apple's signed pkg into an app-managed root
davit system start|stop          # bootstrap/tear down the launchd services
davit exec <container> [cmd]     # interactive TTY shell
davit run [flags] IMAGE [cmd]    # docker-style single-container run
davit build -t <tag> <dir>
davit compose plan|up|down|ps|logs|stop|start|restart|pull|exec
davit machine list|create|boot|stop|delete|exec|set
davit registry login|list|logout
davit selftest                   # end-to-end test of the XPC layer against the live daemon
```

`davit platform status` is the fastest way to see a mixed-install problem, and
`davit selftest` is a good "is the daemon actually healthy" check.

`davit run` is notable for being honest: it accepts docker-style clustered short
flags (`-it`, `-dit`) and **rejects** docker flags with no platform mapping
(`--restart`, `--privileged`, `--add-host`, `--hostname`, `--gpus`) rather than
silently ignoring them. Without `-d` it attaches to logs; Ctrl-C detaches only —
signals can't be forwarded to the guest process on this platform.

`davit compose` is compared against the alternatives in
[04 — Compose](04-compose.md). Argument order is subcommand-first:
`davit compose plan -f compose.yaml`, not the reverse.

### Install-root resolution

Worth knowing because it's the mixed-install problem again. Davit looks in order:

1. custom root from Settings
2. a Davit-managed install at `~/Library/Application Support/dev.wouter.davit/platform/<version>`
3. `/usr/local` (the official installer)
4. Homebrew kegs
5. vendored inside the app bundle

Then it probes each candidate's `container-apiserver --version`: an exact match
for the client the app links wins outright, and installs whose **major** version
differs are skipped entirely — they can't be driven over XPC at all. If every
install on disk is incompatible, onboarding says so by name and offers the in-app
install rather than starting a daemon it can't talk to.

The in-app install needs **no administrator rights** (it extracts the payload
into an app-managed root), which is a real advantage over the official `.pkg`.
Settings → General can then install a `container` shell wrapper in
`/usr/local/bin` that pins `CONTAINER_INSTALL_ROOT` before exec'ing the real CLI.

App data lives in the standard `~/Library/Application Support/com.apple.container/`,
so Davit and the CLI always see the same containers.

## Other GUIs

Community projects, all newer and narrower than Davit. Worth knowing they exist:

| Project | Stack | Notes |
|---|---|---|
| [PenningLabs/container-desktop](https://github.com/PenningLabs/container-desktop) | native macOS | Docker-Desktop-style, drives the CLI |
| [sembsa/ContainerDesktop](https://github.com/sembsa/ContainerDesktop) | SwiftUI | free and open source |
| [ducheharsh/apple-container-desktop](https://github.com/ducheharsh/apple-container-desktop) | React + Tauri | |
| [Podman Desktop](https://podman-desktop.io/) + [apple-container extension](https://github.com/podman-desktop/extension-apple-container) | Electron | drives **socktainer**, so it also sees anything else on the Docker socket |

The Podman Desktop route is the one to pick if you already use it for Podman and
want one window for both — it goes through socktainer rather than XPC, which
means it inherits socktainer's approximations but also its Docker API breadth.

## Terminal UIs

These speak the Docker API, so they work through socktainer with no extra setup:

```bash
brew install lazydocker ctop dive
docker context use socktainer
lazydocker         # full TUI: containers, logs, stats, exec
ctop               # top-like overview
dive myimage:tag   # layer-by-layer image size explorer
```

`dive` in particular is worth having — it makes the layer bloat that `container
image inspect` only hints at obvious.

The platform's own live view:

```bash
container stats                       # interactive, all running containers
container stats --no-stream --format json | jq
```

## Next

- [09 — Ecosystem](09-ecosystem.md)
