# Docker Desktop → Apple container

A migration and usage guide for [`apple/container`](https://github.com/apple/container)
on macOS, with working scripts, shell helpers, and runnable examples.

Everything here was verified against **container 1.4.1**, **socktainer 1.2.1**,
**container-compose 1.2.0** and **Davit 0.1.36** on macOS 27 / Apple silicon.
Where a tool behaves differently from its README, the observed behaviour is
what's written down.

---

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

---

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

---

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

---

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

## Sources

- [apple/container](https://github.com/apple/container) — the runtime, and its [docs/](https://github.com/apple/container/tree/main/docs)
- [socktainer/socktainer](https://github.com/socktainer/socktainer) — Docker API compatibility ([docs site](https://socktainer.github.io/))
- [Mcrich23/Container-Compose](https://github.com/Mcrich23/Container-Compose) — `container-compose`
- [wouterdebie/davit](https://github.com/wouterdebie/davit) — native GUI + headless CLI
