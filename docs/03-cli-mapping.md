# 03 — CLI mapping

Two ways to run Docker commands here:

1. **Use `container` directly.** Different CLI, mostly-familiar shape. This page
   is the translation table.
2. **Use the real `docker` CLI through socktainer.** Same commands you already
   type. See [05 — Docker compatibility](05-docker-compat.md).

Most people end up doing both: `docker compose` for stacks, `container` for
one-offs and for the things only it exposes (boot logs, machines, `system df`).

> There is deliberately **no `docker` → `container` alias shim** in this repo.
> The two CLIs disagree on enough flags that a partial translation silently
> changes what your command means, which is worse than an error. Use socktainer
> when you want `docker` to work.

## Commands

| Docker | Apple container | Notes |
|---|---|---|
| `docker run` | `container run` | |
| `docker create` | `container create` | |
| `docker start/stop/kill` | `container start/stop/kill` | `stop --all` exists |
| `docker restart` | — | `container stop X && container start X` |
| `docker pause/unpause` | — | **no equivalent.** No freezer for VMs. |
| `docker rm` | `container rm` / `container delete` | |
| `docker ps` | `container ls` | `-a`, `-q`, `--format json\|yaml\|toml` |
| `docker exec` | `container exec` | `-i`, `-t`, `-d`, `-e`, `-u`, `-w`, `--ulimit` |
| `docker logs` | `container logs` | `-f`, `-n`, and **`--boot`** |
| `docker top` | — | not implemented |
| `docker stats` | `container stats` | `--no-stream`, `--format json` |
| `docker inspect` | `container inspect` | JSON; `.status.networks[0].ipv4Address` for the IP |
| `docker cp` | `container cp` | `container cp <src> <dst>`, either side `container:path` |
| `docker export` | `container export` | no `/.dockerenv` in the tar — Docker fabricates that file, this doesn't |
| `docker commit` | — | not implemented |
| `docker diff` | — | not implemented |
| `docker container prune` | `container prune` | |
| `docker update` | — | resources are fixed at VM boot; recreate instead |
| `docker build` | `container build` | BuildKit, same Dockerfiles |
| `docker images` | `container image ls` | |
| `docker pull/push` | `container image pull/push` | |
| `docker tag` | `container image tag` | |
| `docker rmi` | `container image rm` | |
| `docker save` | `container image save` | writes an **OCI** archive, not a Docker archive |
| `docker load` | `container image load` | wants an **OCI** archive; see below |
| `docker image prune` | `container image prune` | `--all` for all unused, not just dangling |
| `docker search` | — | not implemented |
| `docker login/logout` | `container registry login/logout` | shares `~/.docker/config.json`, incl. credential helpers |
| `docker volume *` | `container volume *` | `create`, `ls`, `inspect`, `rm`, `prune` |
| `docker network *` | `container network *` | `create`, `ls`, `inspect`, `rm`, `prune` — but **no `connect`/`disconnect`** |
| `docker system df` | `container system df` | |
| `docker system prune` | — | `container prune && container image prune && container network prune` |
| `docker info` / `version` | `container system status` / `container system version` | status also prints install paths — read it when debugging |
| `docker compose` | see [04 — Compose](04-compose.md) | three options |
| `docker buildx` | `container build --arch a --arch b` | multi-platform in one pass |
| — | `container system logs` | the platform's own logs |
| — | `container builder start/stop/status/delete` | the BuildKit builder VM |
| — | `container machine *` | **persistent general-purpose Linux VMs** — see [13](13-machines.md) |
| — | `container k8s *` | local Kubernetes clusters (plugin; may not be in your install) |
| — | `container system dns create` | host-side DNS resolution for container names |
| — | `container system property list` | merged `config.toml` + defaults |

### `docker save` / `load` across runtimes

They are not interchangeable, and the error messages don't say why:

| From → To | Works? | How |
|---|---|---|
| Docker → Apple container | yes | `docker --context desktop-linux save X \| docker --context socktainer load` |
| Docker → Apple container, directly | **no** | `container image load` wants OCI; `docker save` emits a Docker archive |
| Apple container → Apple container | yes | `container image save -o x.tar X && container image load -i x.tar` |
| Apple container → Docker, for a registry-pulled image | **no** | fails with `ContentStore missing blob data` — only the local platform's blobs were downloaded, but save exports the whole index |

`skopeo` bridges the rest: `skopeo copy docker-daemon:img:tag oci-archive:/tmp/img.tar`.

## Flags on `run` / `create`

### Same meaning, same spelling

`-d/--detach` · `-e/--env` · `--env-file` · `-i/--interactive` · `-t/--tty` ·
`-u/--user` · `-w/--workdir` · `--name` · `-p/--publish` · `-v/--volume` ·
`--mount` · `--tmpfs` · `--entrypoint` · `-l/--label` · `--rm` · `--read-only` ·
`--init` · `--cap-add` · `--cap-drop` · `--shm-size` · `--ulimit` ·
`--dns` · `--dns-search` · `--dns-option` · `--platform` · `--cidfile` · `--network`

### Same spelling, different behaviour — read these

| Flag | What's different |
|---|---|
| `-m/--memory` | A **hard VM allocation made at boot**, not an elastic cgroup limit. Default 1 GiB. Too low and the process is OOM-killed inside the guest, often with nothing in `container logs` — check `container logs --boot`. There is no "unlimited". |
| `-c/--cpus` | Whole vCPUs. `--cpus 1.5` gets 1. Default 4. No CFS throttling, no `--cpu-shares`/`--cpu-period`/`--cpu-quota` equivalent. |
| `--network` | `--network <name>[,mac=…][,mtu=…]`. Accepts a network name, **never** `host`, `none` or `container:<id>`. |
| `-v` | virtiofs bind mount, or a named volume by name. Options are `ro` only — no `:z`, `:Z`, `:cached`, `:delegated`. |
| `--platform` | `linux/arm64` native, `linux/amd64` via Rosetta. Nothing else. |
| `-a/--arch` | Apple-specific: selects a variant from a multi-arch image. Defaults to `arm64`. |

### Docker flags with no counterpart

| Flag | Situation |
|---|---|
| `--privileged` | Doesn't exist. Via socktainer it maps to `--cap-add=ALL` — enough for buildx's `docker-container` driver, not enough for device access, seccomp or AppArmor. Use explicit `--cap-add` instead. |
| `--network host` | Impossible. Each container is a separate VM with its own kernel. Use `--publish`, or reach the host via a `--localhost` DNS domain ([06](06-networking.md)). |
| `--network none` | No equivalent. Closest is `container network create --internal`. |
| `--pid`, `--ipc`, `--uts`, `--userns` | Namespace sharing across VMs isn't possible. |
| `--restart` | No equivalent in the CLI. socktainer implements the policies, but only while socktainer itself is running — they don't survive a reboot. |
| `--add-host` | No equivalent. Davit's compose writes `/etc/hosts` entries; the CLI doesn't. |
| `--hostname` | Set via `--network <name>` options, not a top-level flag. |
| `--gpus`, `--device` | No passthrough. |
| `--health-*` | No healthchecks in the runtime. socktainer and `davit compose` honour Compose-level healthchecks. |
| `--ip` | Static IPs aren't assignable — the allocator rotates. Addresses are stable for a container's lifetime; use names. |
| `--log-driver`, `--log-opt` | Logs go to files the platform manages. `container logs`, `container system logs`. |
| `--sysctl` | Present in `inspect` output but not a documented `run` flag. |

### Apple-only flags worth knowing

| Flag | Why |
|---|---|
| `--ssh` | Forwards `SSH_AUTH_SOCK` in, and **re-points it after logout/login** — better than doing the bind mount yourself. Private git clones inside containers just work. |
| `--rosetta` | Enables Rosetta inside the container. |
| `--virtualization` | Nested virtualisation, if host and guest support it. |
| `--kernel`, `--kernel-arg` | Custom guest kernel. No Docker analogue at all. |
| `--publish-socket` | Publishes a **unix socket** from container to host. |
| `--masked-path`, `--read-only-path` | Experimental per-path hardening. |
| `--no-dns` | Skip DNS configuration in the guest. |

## Build flags

| Docker | Apple container |
|---|---|
| `-t`, `-f`, `--build-arg`, `--no-cache`, `--target`, `--secret`, `--ssh`, `--pull` | identical |
| `--platform linux/amd64,linux/arm64` | `--arch amd64 --arch arm64`, or `--platform` once |
| `--output type=…` | `-o type=oci\|tar\|local[,dest=]` |
| `--progress` | `--progress auto\|plain\|tty` |
| builder resources | `container builder start --cpus 8 --memory 32g` — default is **2 CPUs / 2 GiB**, which is not enough for most real builds |

The builder is a VM whose resources are fixed at start. To change them:

```bash
container builder stop && container builder delete
container builder start --cpus 8 --memory 32g
```

`cbigbuilder 8 32g` in the shell helpers does exactly that.

## Things you'll reach for that have no Docker equivalent

```bash
container logs --boot <name>     # guest kernel/init log — why a container "started then died"
container system df              # per-type disk usage with reclaimable amounts
container system property list   # the merged config the daemon is really using
container inspect <name> | jq '.[0].status.networks[0].ipv4Address'   # routable IP
container machine create alpine:3.22 --name dev    # a persistent Linux VM with $HOME mounted, running as you
```

`container logs --boot` is the one to internalise. On Docker, a container that
exits immediately tells you why in its logs. Here, if the *VM* failed to boot —
bad kernel arg, out of memory before the process started, a broken init image —
normal logs are empty and the boot log has the answer.

## Next

- [04 — Compose](04-compose.md)
- [13 — Container machines](13-machines.md) — the `container machine` subcommand in full
