# 05 — Docker compatibility (socktainer)

[socktainer](https://github.com/socktainer/socktainer) exposes a Docker Engine
API on top of Apple container. Point any Docker client at it and it works — the
CLI, Compose, Testcontainers, IDE integrations, Podman Desktop.

It targets **partial Docker Engine API v1.51** compatibility. "Partial" is doing
real work in that sentence; the gaps are listed below and most of them are
platform limits, not socktainer's.

## Setup

```bash
brew install socktainer
./scripts/socktainer-service.sh start
docker context use socktainer
docker ps
```

That's it. socktainer starts Apple container's services itself if they aren't
running (like Colima does), and writes a `socktainer` Docker context on startup.

### Don't use `brew services start socktainer`

Homebrew's generated plist sets `HOME=$(brew --prefix)/var/run/socktainer`.
socktainer derives **both** its socket path and its Docker context file from
`HOME`, so you get:

```
socket   -> /opt/homebrew/var/run/socktainer/.socktainer/container.sock
context  -> /opt/homebrew/var/run/socktainer/.docker/contexts/...
```

The socket works. The context is written somewhere your `docker` CLI never
looks, so `docker context use socktainer` fails with `context not found` and the
path in the error is a hash you can't interpret.

`./scripts/socktainer-service.sh start` installs a LaunchAgent with `HOME` set to
your real home instead. It also stops Homebrew's service if it's running, since
both would fight over the same binary.

If you'd rather keep `brew services`, point the context at the brew socket
yourself:

```bash
brew services start socktainer
docker context create socktainer \
  --docker host=unix://$(brew --prefix)/var/run/socktainer/.socktainer/container.sock
```

### Manual, for debugging

```bash
socktainer                      # foreground, logs to your terminal
socktainer --no-auto-start      # don't start Apple container's services for me
socktainer --no-docker-context  # don't write the context file
socktainer --check-compatibility   # verify version match and exit
```

Run it in the foreground the first time something is wrong. The startup banner
tells you the socket path, the DNS port, and whether it detected a version
mismatch with the runtime.

### Bypassing the context

Some tools ignore Docker contexts entirely and read `DOCKER_HOST`:

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
```

Useful for Testcontainers. Dangerous in a shell profile — it silently overrides
whatever context you select, and then `docker context use desktop-linux`
appears to do nothing. `dwhich` warns when it's set.

## What works

Verified on this setup:

- `docker ps`, `ps -a`, `images`, `pull`, `rmi`, `logs`, `inspect`, `stats`,
  `events`, `exec` (non-interactive), `export`, `load`, `volume *`, `network *`
- `docker compose` — the full lifecycle, including healthcheck-gated
  `depends_on`, `ps` with health status, `logs -f`, `exec`
- inter-service DNS with two aliases per service (`db` and `db.<project>`),
  served by socktainer's own DNS on port 2054 — no host `[dns]` setup needed
- `docker volume create -o sync=fsync`, and `driver_opts: {sync: fsync}` in Compose
- `~/.docker/config.json` registry logins and credential helpers
- Podman Desktop, via its [apple-container extension](https://github.com/podman-desktop/extension-apple-container)

## What doesn't, and why

### Returns an explicit error (doesn't pretend)

`docker commit` · `docker diff` · `docker search` · `docker top` ·
`GET /distribution/{name}/json`

### Not supported by the platform

| Docker feature | What happens |
|---|---|
| `pause` / `unpause` | unsupported — no freezer/checkpoint for VMs |
| `--privileged` | mapped to `--cap-add=ALL`. Enough for buildx's `docker-container` driver rbind-mounting its context; **not** enough for device access, seccomp or AppArmor. Prefer explicit `--cap-add`/`--cap-drop`. |
| `network connect` / `disconnect` | accepted as **no-ops**. Virtualization.framework has no NIC hotplug, so network membership is fixed at create. Name-based discovery covers the Compose case. |
| static IPs (`--ip`, IPAM per-container) | can't be honoured — the allocator rotates. Addresses are stable for a container's lifetime; use names. |
| IPAM `Gateway`, `IPRange`, `AuxiliaryAddresses` | ignored, with a `WARNING` logged. Only `Subnet` is honoured. |
| `--cpus` fractions | floored to whole cores, minimum 1. `--cpu-shares`, `--cpu-period`, `--cpu-quota` have no effect. |
| `--memory 0` (unlimited) | maps to the platform default of **1 GiB**, not host RAM. Always pass an explicit value if you need more. |
| `docker update` with resource flags | only `--restart` can change. Resources are fixed at VM boot; a resource-only update errors, a mixed one applies the policy and warns. |
| `/.dockerenv` | not created. Code that probes for it to detect "am I in a container" won't find it. |

### Behaves, with a caveat

| Feature | Caveat |
|---|---|
| `--restart` policies | Fully implemented, including moby's backoff quirks (100 ms doubling to 1 min, reset after 10 s up). But enforced **only by the running socktainer process** — not restored after a socktainer restart or a host reboot. |
| `docker save` | Works for tarball-loaded images and for `save \| load` round-trips. Fails with `ContentStore missing blob data` for **registry-pulled** images: the pull fetched only your platform's blobs but save exports the whole multi-platform index. |
| `docker load` | Accepts real Docker tarballs (plain/gzip/zstd). Index entries whose blobs aren't in the tarball are dropped, so a multi-arch image saved by real Docker arrives single-arch. |
| Label keys | Apple container only accepts `[a-z0-9][a-z0-9\-./]*`. socktainer normalises (uppercase → lowercase, `_` → `-`, invalid chars dropped) and keeps an internal mapping so `docker inspect`, `--filter label=` and Go templates all return your **original** key. Two keys that normalise identically collide — last wins, with a `WARNING`. |
| `-v /var/run/docker.sock:/var/run/docker.sock` | **Transparently relayed** to socktainer's own API rather than dropped. Matches Docker's behaviour — and carries the same well-known risk: any container with that mount gets full control of every container socktainer manages. |
| Postgres named volumes | `/lost+found` is removed automatically before `initdb`. Opt out with `SOCKTAINER_CLEAN_VOLUMES=false` or the label `socktainer.clean-volumes=false` (don't). |

## Version skew

socktainer pins an expected Apple container version and warns loudly if it
doesn't match:

```
⚠️  Apple Container compatibility warning:
   Apple Container version mismatch: detected 1.0.0 but this socktainer binary
   requires 1.2.0. This version incompatibility will cause XPC connection errors.
```

Take it seriously. Downstream XPC errors that look like anything else usually
trace back to this. Run `./scripts/doctor.sh` — it checks client/daemon versions
and detects mixed installs, which is the usual root cause.

## Memory reporting

`docker stats` reports memory against the **container's VM limit**, not host RAM.
A container with `--memory 512m` shows `x / 512 MiB`. That's correct and more
useful than Docker's view, but it means percentages aren't comparable to what you
saw on Docker Desktop.

## Testcontainers

Works, with `TESTCONTAINERS_RYUK_DISABLED=true` as a hard requirement. It has its
own page, because the caveats are specific and the failure modes are confusing:
**[11 — Testcontainers](11-testcontainers.md)**.

## IDEs and other clients

| Client | Setup |
|---|---|
| IntelliJ / JetBrains Docker plugin | Settings → Docker → Add → *Unix socket*, `$HOME/.socktainer/container.sock` |
| VS Code Docker / Container Tools | `"docker.host": "unix:///Users/YOU/.socktainer/container.sock"` in settings |
| Podman Desktop | install the [apple-container extension](https://github.com/podman-desktop/extension-apple-container) — it drives socktainer |
| `lazydocker`, `ctop`, `dive` | honour `DOCKER_HOST` / contexts; work as-is |
| Dev Containers (`devcontainer` CLI) | honours `DOCKER_HOST`. Works for straightforward configs; features that need `--privileged` or docker-in-docker are the ones that fail. |
| `act` (GitHub Actions locally) | needs `--container-daemon-socket unix://$HOME/.socktainer/container.sock`; mixed results with privileged steps |
| Skaffold / Tilt | point at the socket; both also work against `container k8s` |

## CI

Almost nothing here matters for CI. Your runners are Linux and use Docker
natively. This is a local-development change.

The exception is a self-hosted macOS runner, where Apple container is a genuine
improvement over nested Docker Desktop — no licence question, no idle VM. Bring
the services up in the job:

```yaml
- run: container system start
- run: socktainer --no-docker-context &
- run: export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
```

## Next

- [06 — Networking & DNS](06-networking.md)
- [11 — Testcontainers](11-testcontainers.md)
