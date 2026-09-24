# Docker Desktop → Apple container

A migration and usage guide for [`apple/container`](https://github.com/apple/container)
on macOS, with working scripts, shell helpers, and runnable examples.

Everything here was verified against **container 1.4.1**, **socktainer 1.2.1**,
**container-compose 1.2.0** and **Davit 0.1.36** on macOS 27 / Apple silicon.
Where a tool behaves differently from its README, the observed behaviour is
what's written down.

## The 60-second version

```bash
./scripts/bootstrap.sh              # install the toolchain via Homebrew
./scripts/doctor.sh                 # verify it, and catch the classic misconfigurations
./scripts/socktainer-service.sh start   # expose a Docker-compatible socket
docker context use socktainer       # now `docker` and `docker compose` drive Apple container
./examples/01-hello/run.sh          # end-to-end smoke test
```

Add the shell helpers:

```bash
echo "source $PWD/shell/apple-container.sh" >> ~/.zshrc && exec zsh
achelp
```

Docker Desktop stays installed and one command away (`./scripts/switch-runtime.sh desktop`)
until you're confident. Remove it last, not first.

## What you're actually switching to

Docker on macOS runs **one** Linux VM and puts all your containers inside it.
Apple container boots **one lightweight VM per container**.

That single architectural difference explains nearly every behavioural
difference you'll hit:

| | Docker Desktop | Apple container |
|---|---|---|
| Isolation | shared kernel, namespaces | separate kernel per container |
| Idle cost | one VM always resident (~2 GB+) | nothing running when stopped |
| `--memory` | soft cgroup limit, elastic | **hard VM reservation at boot** |
| `--cpus` | CFS quota, fractional | whole vCPUs, fractions floored to 1 |
| Container IP | inside a NAT'd bridge | real routable address, reachable from the host |
| `--network host` | works | impossible — no shared netns |
| `--privileged` | works | doesn't exist |
| `pause` / `unpause` | works | no freezer |
| Startup | ~100 ms | ~1 s (a kernel boots) |
| Filesystem | overlayfs | ext4 disk image per container, sparse |

The wins are real: no idle daemon, no 15 GB monolithic VM disk, per-container
kernel isolation, and no licensing question. The costs are real too, and they're
concentrated in a handful of Docker features that simply have no counterpart.

## Should you migrate?

| Your situation | Verdict |
|---|---|
| Web app + Postgres/Redis/Kafka, compose-based | **Yes.** This is the sweet spot. |
| You mostly `docker build` and push | **Yes.** BuildKit is the same builder. |
| Testcontainers suites | **Probably.** Ryuk must be disabled — see [11 — Testcontainers](docs/11-testcontainers.md). |
| Docker-in-Docker, buildx `docker-container` driver | **Partly.** Approximated via `--cap-add=ALL`; test it. |
| `--network host`, `--privileged` with device access, GPU | **No.** Keep Docker Desktop or Colima for those projects. |
| You need x86-64 containers routinely | **Careful.** Rosetta works but is slower, and some binaries fail. |
| Still on macOS 15 | **No.** Networking and DNS need macOS 26+. |

You don't have to choose globally. Both can be installed at once; the active
Docker context decides which one `docker` talks to.

Apple container isn't the only alternative either. If the driver is Docker
Desktop's licence — a paid subscription is required at companies with **≥250
employees or ≥$10M annual revenue**, either threshold alone — then Colima,
Podman, Rancher Desktop and Finch are all Apache-2.0 or MIT with no commercial
restriction, and OrbStack is *not* (its free tier is personal, non-commercial
only). [12 — Alternatives](docs/12-alternatives.md) compares all seven on
architecture, capabilities and licensing.

## Contents

**Guide**

| | |
|---|---|
| [01 Install](docs/01-install.md) | installing, which install method to pick, coexisting with Docker Desktop, rollback |
| [02 Migrate](docs/02-migrate.md) | moving images, volumes and stacks; cutover checklist |
| [03 CLI mapping](docs/03-cli-mapping.md) | every `docker` command and flag → the `container` equivalent, or what to do instead |
| [04 Compose](docs/04-compose.md) | three front ends compared on measured behaviour |
| [05 Docker compatibility](docs/05-docker-compat.md) | socktainer, contexts, Testcontainers, buildx, IDEs, CI |
| [06 Networking & DNS](docs/06-networking.md) | reaching containers by name, publishing ports, host access |
| [07 Storage](docs/07-storage.md) | volumes, bind mounts, sync modes, performance, disk reclaim |
| [08 GUI](docs/08-gui.md) | Davit and the other UIs |
| [09 Ecosystem](docs/09-ecosystem.md) | tools that work, tools that don't, tools worth adding |
| [10 Troubleshooting](docs/10-troubleshooting.md) | the failures you will actually hit |
| [11 Testcontainers](docs/11-testcontainers.md) | per-language setup, the Ryuk requirement, memory budgeting, cleanup |
| [12 Alternatives](docs/12-alternatives.md) | Podman, Colima, Rancher, OrbStack, Finch compared — architecture, capabilities, and commercial-use licensing |
| [13 Container machines](docs/13-machines.md) | persistent Linux VMs with your home, your user and your cwd — a Lima/Colima replacement that's already installed |

**Scripts** — all safe to re-run; the destructive one is dry-run by default.

| | |
|---|---|
| [`bootstrap.sh`](scripts/bootstrap.sh) | install the toolchain via Homebrew, start services, wire up completions |
| [`doctor.sh`](scripts/doctor.sh) | read-only health check: version skew, mixed installs, DNS, contexts, competing runtimes |
| [`socktainer-service.sh`](scripts/socktainer-service.sh) | run socktainer as a LaunchAgent (works around a real `brew services` bug — see the script header) |
| [`switch-runtime.sh`](scripts/switch-runtime.sh) | point `docker` at Apple container / Docker Desktop / Colima |
| [`setup-dns.sh`](scripts/setup-dns.sh) | make `<name>.test` resolve from your Mac |
| [`migrate-images.sh`](scripts/migrate-images.sh) | move images across, registry-pull or tar handoff |
| [`migrate-volumes.sh`](scripts/migrate-volumes.sh) | copy volume contents across, with verification |
| [`compose-check.sh`](scripts/compose-check.sh) | lint a Compose file for things this platform can't honour |
| [`cleanup.sh`](scripts/cleanup.sh) | reclaim disk |
| [`uninstall-docker-desktop.sh`](scripts/uninstall-docker-desktop.sh) | the last step, when you're sure (dry-run unless `--execute`) |

**Shell** — [`shell/apple-container.sh`](shell/apple-container.sh), aliases and
helpers for zsh and bash. Nothing shadows a real command. `achelp` lists everything.

**[`AGENTS.md`](AGENTS.md)** — operational rules for AI coding agents, so an
agent doesn't reach for `docker run --privileged` and burn a turn on an error it
could have avoided. Detection first, the command translation, the flags that are
structurally impossible, the `--memory` rule, and when to stop and switch
runtime. Copy it into a project root or merge it into an existing `AGENTS.md` /
`CLAUDE.md`.

**Makefile** — `make help` for the short list: `make install doctor up apple desktop
audit migrate clean smoke lint`.

**Examples**

| | |
|---|---|
| [01-hello](examples/01-hello) | build + run, the smoke test |
| [02-node-web](examples/02-node-web) | published ports, bind mounts, resource sizing |
| [03-compose-web-db](examples/03-compose-web-db) | the same stack through all three compose front ends |
| [04-postgres-volume](examples/04-postgres-volume) | named volumes, the `/lost+found` trap, database memory |
| [05-multiplatform](examples/05-multiplatform) | arm64 + amd64 in one image |
| [06-testcontainers](examples/06-testcontainers) | config for Java/Node/Go/Python/.NET |
| [07-k8s](examples/07-k8s) | local Kubernetes via `container k8s` |
| [08-machine](examples/08-machine) | container machines: host user, home mount, cwd pass-through, SSH agent, persistence |

## Don't miss `container machine`

The platform ships a second thing that has nothing to do with containers, and
almost nobody mentions it: **persistent, general-purpose Linux VMs**.

```bash
container machine create ubuntu:24.04 --name dev --cpus 4 --memory 8G
container machine run -n dev                    # a Linux shell, as you
```

Unlike a container, a machine boots the image's **init system** (so `systemctl`
works), its filesystem **survives a stop**, and it runs as **your host user**
with your Mac's home mounted at `/Users/<you>`, your working directory carried
through, and your SSH agent already forwarded — no flags. It is a Lima / Colima
/ Multipass replacement you have already installed, and it takes any OCI image
as its base.

[13 — Container machines](docs/13-machines.md) covers it, including the two
gotchas that will bite a script: `create` returns ~4 s **before** the machine
accepts commands, and `sh -c 'multi word string'` is silently word-split.

## The three things that will confuse you first

1. **`--memory` is a reservation, not a limit.** The default is 1 GiB per
   container, allocated at boot. A Postgres that was happy on Docker Desktop
   gets OOM-killed here with nothing useful in the logs. Set `--memory`
   explicitly, and check `container logs --boot <name>` when a container dies
   silently.

2. **Two installs is the default failure mode.** The official `.pkg` installs to
   `/usr/local`; Homebrew installs to its own keg. If you've used both, your CLI
   and your running daemon are different builds, and the symptoms are bizarre
   and unrelated-looking. `./scripts/doctor.sh` detects this specifically.

3. **`docker` not seeing your containers is a context problem, 90% of the time.**
   `dwhich` (or `./scripts/switch-runtime.sh`) tells you what it's pointed at.
   `DOCKER_HOST`, if set anywhere in your shell profile, silently overrides the
   context you selected.

## Keep a fallback runtime

Some things here are structurally impossible, not merely unimplemented:
`--network host`, `--privileged` with device access, `--pid host`,
Docker-in-Docker, GPU passthrough. There is no shared kernel for them to refer
to, so no release will add them.

Keep a second runtime installed and switch per project:

```bash
brew install colima
./scripts/switch-runtime.sh colima     # or: orbstack, desktop, apple
```

Colima is the usual choice — MIT, no commercial restriction, closest to plain
Docker semantics. OrbStack is faster and more polished but its free tier is
personal, non-commercial use only. [12 — Alternatives](docs/12-alternatives.md)
compares Podman, Colima, Rancher Desktop, OrbStack and Finch on architecture,
capabilities and licensing.

## Sources

- [apple/container](https://github.com/apple/container) — the runtime, and its [docs/](https://github.com/apple/container/tree/main/docs)
- [socktainer/socktainer](https://github.com/socktainer/socktainer) — Docker API compatibility ([docs site](https://socktainer.github.io/))
- [Mcrich23/Container-Compose](https://github.com/Mcrich23/Container-Compose) — `container-compose`
- [wouterdebie/davit](https://github.com/wouterdebie/davit) — native GUI + headless CLI
