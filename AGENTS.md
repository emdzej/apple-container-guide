# AGENTS.md

Instructions for AI coding agents working on a machine where **Apple's
`container` runtime** is the container platform, instead of Docker Desktop,
Podman, Colima or Rancher Desktop.

Copy this file into a project's root (or merge it into an existing `AGENTS.md` /
`CLAUDE.md`) so an agent doesn't reach for `docker run --privileged` and burn a
turn on an error it could have avoided.

Human-facing detail is in [`docs/`](docs/); this file is the operational subset.

## 1. Detect the runtime before assuming one

Never assume `docker` reaches the runtime you expect. Run this first:

```bash
docker context show
docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}'
echo "DOCKER_HOST=${DOCKER_HOST:-unset}"
container system status 2>/dev/null | head -3
```

Interpret the endpoint:

| Endpoint contains | Runtime |
|---|---|
| `socktainer` | Apple container (via the Docker API shim) |
| `.docker/run/docker.sock` | Docker Desktop |
| `colima` | Colima |
| `orbstack` | OrbStack |
| `podman` or `podman-machine` | Podman |

`DOCKER_HOST`, if set, **overrides the context**. Check it before concluding the
context is wrong.

If `container` is on `PATH` and `container system status` succeeds, Apple
container is available regardless of what `docker` is pointed at.

## 2. Choose a path deliberately

Two ways to drive Apple container. Pick one per task and say which you used.

**Path A — the `container` CLI.** No extra daemon. Use for one-off containers,
builds, and anything needing platform-only features (`logs --boot`,
`system df`, `machine`, `k8s`).

**Path B — `docker` via socktainer.** Use when the project already has
`docker`/`docker compose` commands, a Makefile, or a test suite that speaks the
Docker API. Needs socktainer running:

```bash
./scripts/socktainer-service.sh start   # from this repo
docker context use socktainer
```

**Default to Path B for Compose and for Testcontainers**, Path A otherwise.

Do **not** write a `docker` → `container` translation wrapper. The CLIs disagree
on enough flags that partial translation silently changes meaning. Use
socktainer when you want `docker` semantics.

## 3. Command translation

| Instead of | Use |
|---|---|
| `docker run` | `container run` |
| `docker ps` | `container ls` (`-a`, `-q`, `--format json`) |
| `docker exec -it X sh` | `container exec -it X sh` |
| `docker logs -f X` | `container logs -f X` |
| `docker images` | `container image ls` |
| `docker pull/push` | `container image pull/push` |
| `docker rmi` | `container image rm` |
| `docker build` | `container build` |
| `docker login` | `container registry login` |
| `docker volume ls` | `container volume ls` |
| `docker network ls` | `container network ls` |
| `docker system df` | `container system df` |
| `docker info` | `container system status` |
| `docker system prune` | `container prune && container image prune && container network prune` |
| `docker restart X` | `container stop X && container start X` |
| `docker buildx build --platform a,b` | `container build --arch arm64 --arch amd64` |

No equivalent — **do not emit these**, and don't retry them with variations:

`docker pause` · `docker unpause` · `docker commit` · `docker diff` ·
`docker top` · `docker search` · `docker update` (resources)

## 4. Flags that will fail or mislead

**Never emit these against Apple container.** They are structurally impossible —
each container is a separate VM with its own kernel, so there is no shared
kernel or netns to refer to. No release will add them.

| Flag | Why | Do this instead |
|---|---|---|
| `--network host` | no shared netns | `--publish`, or reach the host via a `--localhost` DNS domain |
| `--privileged` | no privileged mode | explicit `--cap-add`; via socktainer it silently becomes `--cap-add=ALL`, which is **not** equivalent |
| `--pid`, `--ipc`, `--uts`, `--userns` | no cross-VM namespace sharing | redesign, or use a fallback runtime |
| `--device`, `--gpus` | no passthrough | run natively or remotely |
| `--ip` / static IPs | rotating allocator | service names via DNS |
| `--add-host` | no flag | compose front ends write `/etc/hosts` |
| `--restart` | no CLI support | socktainer honours it, but only while socktainer runs — never across reboot |
| `--network none` | no equivalent | `container network create --internal` |
| `-v ...:cached` / `:delegated` / `:z` / `:Z` | not supported | plain `-v src:dst[:ro]` |

**Same spelling, different behaviour — the three that cause silent bugs:**

| Flag | Difference |
|---|---|
| `--memory` | A **hard VM reservation at boot**, default **1 GiB**, not an elastic cgroup limit. Too low → the process is OOM-killed inside the guest with **nothing in `container logs`**. There is no unlimited: `--memory 0` maps to 1 GiB. |
| `--cpus` | Whole vCPUs only. `--cpus 1.5` gets 1. `--cpu-shares`/`--cpu-period`/`--cpu-quota` are silently ignored. |
| `--platform` | `linux/arm64` native, `linux/amd64` under Rosetta. Nothing else exists. |

### Always set `--memory` for databases and JVMs

This is the single highest-value rule in this file. `postgres`, `mysql`,
`mongo`, `elasticsearch`, `kafka` and any JVM service need an explicit value or
they die silently:

```bash
container run -d --name db --memory 2g --cpus 2 \
  -e POSTGRES_PASSWORD=devonly \
  -e PGDATA=/var/lib/postgresql/data/pgdata \
  -v pgdata:/var/lib/postgresql/data \
  -p 127.0.0.1:5432:5432 \
  docker.io/library/postgres:17-alpine
```

Budget the whole stack: memory is reserved **per container**, not shared. Six
services at 1 GiB each reserve 6 GiB before any work happens.

## 5. Diagnose failures in this order

When a container starts and then dies, **check the boot log before anything
else**. It has no Docker equivalent and it is where guest-side deaths appear:

```bash
container logs --boot <name>     # kernel/init failures, OOM before the process wrote anything
container logs -n 100 <name>     # normal stdio
container inspect <name>         # .status.state, .status.networks[0].ipv4Address
container stats --no-stream      # actual vs reserved memory
```

Do not conclude "the image is broken" until `logs --boot` has been read. The
most common answer is insufficient `--memory`.

## 6. Networking facts that change how you write code

- **Every container has a real routable IP, reachable from the host with no
  `--publish`.** Get it from
  `container inspect X | jq -r '.[0].status.networks[0].ipv4Address'`. Useful for
  health checks in scripts.
- **A published port needs the VM to boot first** — around a second, not
  instant. Any script that curls straight after `run -d` must retry in a loop.
  Do not use a bare `sleep 1`.
- **Bare hostnames do not resolve.** With a `[dns] domain` set, use
  `<name>.<domain>`. On custom networks, neither form resolves.
- **For Compose service discovery, use socktainer.** It runs its own DNS and
  registers `<service>` and `<service>.<project>`. This is the reason Path B is
  the default for Compose.
- **There is no `host.docker.internal`.** The equivalent must be created:
  `sudo container system dns create host.container.internal --localhost 203.0.113.113`.

## 7. Compose rules

Prefer `docker compose` via socktainer. If you must use `container-compose`,
these are hard constraints, not preferences:

1. **Use list-form `command:` and `entrypoint:`, always.** String form is
   word-split by Docker Compose but passed as a single argv element by
   `container-compose`, so the container exits with `No such file or directory`
   quoting the whole command.
   ```yaml
   command: ["sh", "-c", "until pg_isready -h db; do sleep 1; done; exec myapp"]
   ```
2. **Always set a project `name:`.** One global hostname namespace — two stacks
   with a `db` service collide, last started wins.
3. **Set `mem_limit` on every service.** Unset means 1 GiB reserved.
4. `container-compose down` **only stops** — containers remain, volumes remain.
   Follow with `container rm` if removal was the intent.
5. `container-compose` ignores `cpus:`, `restart:` and healthcheck-gated
   `depends_on` conditions. It has only `up`, `down`, `build`, `version` — use
   `container ls` / `logs` / `exec` for the rest.

Before porting a Compose file, run the linter in this repo:

```bash
./scripts/compose-check.sh path/to/compose.yaml
```

## 8. Storage rules

- **Never put a database data directory on a bind mount.** Use a named volume.
  The bind-mount penalty is larger here than on Docker Desktop.
- **ext4 volumes always contain `/lost+found`, and `initdb` refuses a non-empty
  directory.** Either set `PGDATA` to a subdirectory (preferred, works
  everywhere), or clear it first:
  ```bash
  container run --rm -v vol:/v alpine rm -rf /v/lost+found
  ```
  socktainer strips it automatically for Postgres images; the `container` CLI
  does not.
- **Anonymous volumes (`-v /path`) are NOT removed by `--rm`**, unlike Docker.
  Always name volumes explicitly so they can be found and cleaned up.
- Put `node_modules`, build caches and package caches on named volumes, with the
  source on a bind mount.

## 9. Images

- `container image load` wants an **OCI** archive; `docker save` emits a
  **Docker** archive. They are not interchangeable.
- To move an image from Docker to Apple container:
  ```bash
  docker --context desktop-linux save X | docker --context socktainer load
  ```
- `docker save` of a **registry-pulled** image fails with
  `ContentStore missing blob data` — the pull fetched only the local platform's
  blobs but save exports the whole index. Re-pull on the target instead.
- Prefer `container image pull` over moving tarballs whenever the image exists in
  a registry.

## 10. Testcontainers

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
```

Both are **required**. Most Testcontainers clients read `DOCKER_HOST` and ignore
Docker contexts. Ryuk reaps by bind-mounting the Docker socket into itself,
which socktainer relays but cannot honour — leave it enabled and the suite hangs
before any test runs.

Because Ryuk is off, nothing cleans up after a crashed run. Add teardown:

```bash
docker --context socktainer ps -aq --filter label=org.testcontainers=true \
  | xargs -r docker --context socktainer rm -f
```

Also: raise startup timeouts (a kernel boots per container), and set container
memory explicitly. Full detail: [docs/11-testcontainers.md](docs/11-testcontainers.md).

## 11. Consider a machine instead of a container

If the task is "get a Linux shell", "run a Linux-only tool", "build this against
source already on disk", or "run a real service with systemd", a **container
machine** is the right primitive and a container is the wrong one.

```bash
container machine create ubuntu:24.04 --name dev --cpus 4 --memory 8G
container machine run -n dev -- <command> <args...>
container machine stop dev && container machine delete dev
```

A machine boots the image's init system, persists its filesystem across stops,
runs as the **host user** (not root), mounts the host home at `/Users/<user>`,
carries the host working directory through, and forwards `SSH_AUTH_SOCK`
automatically. Memory defaults to **half of host RAM**, so set `--memory`.

Three rules when scripting one:

1. **Wait for readiness after `create`.** The command returns, and
   `machine list` reports `running`, roughly 4 seconds before `machine run`
   works. Until then it fails with
   `Operation not supported by device`. Poll instead of sleeping blindly:
   ```bash
   until container machine run -n dev -- true >/dev/null 2>&1; do sleep 1; done
   ```
   The same window applies to the first command after a `stop`, since `run`
   auto-boots.
2. **Do not pass a multi-word string to `sh -c`.** It is word-split before it
   reaches the guest and silently does nothing. Pass separate words, or pipe the
   script in:
   ```bash
   container machine run -n dev -- make -C /Users/me/proj test   # fine
   printf 'apk add git\ngit clone ...\n' | container machine run -n dev -i -- sh
   ```
3. **Never hardcode a machine's IP** — it changes across restarts. Read it:
   `container machine inspect dev | jq -r '.[0].ipAddress'`.

Note the two home paths: the host home is mounted at `/Users/<user>`, while the
guest's own `$HOME` is `/home/<user>`. Both exist and they are different.

Alpine gives busybox init. For `systemctl`, use a systemd-capable image such as
`ubuntu:24.04`.

Full detail: [docs/13-machines.md](docs/13-machines.md).

## 12. When to stop and use a different runtime

If the task genuinely requires `--privileged` with device access,
`--network host`, `--pid host`, Docker-in-Docker, or a GPU, **say so and switch**
rather than attempting workarounds:

```bash
./scripts/switch-runtime.sh colima     # or: desktop, orbstack
```

All of these support `--privileged` and `--network host`, because they run
containers as namespaced processes inside one shared Linux VM. Colima is the
usual choice: MIT, no commercial restriction, closest to plain Docker semantics.
OrbStack is the fastest but its free tier is personal, non-commercial use only.

Report which runtime you used and why. Do not silently fall back, and do not
spend turns trying to approximate a feature that does not exist.
[docs/12-alternatives.md](docs/12-alternatives.md) has the comparison.

## 13. Verify before reporting success

```bash
container ls -a                       # is it actually running, or exited?
container logs --boot <name>          # did the VM boot cleanly?
curl -sf http://127.0.0.1:<port>/     # does the published port answer?
container stats --no-stream <name>    # is it near its memory reservation?
```

A container in `stopped` state is not a working deployment. Check state, don't
infer it from the absence of an error.

## Quick reference

```bash
# services
container system start | stop | status
container system df
container system property list                 # merged config + defaults

# containers
container run -d --name X --memory 2g --cpus 2 -p 127.0.0.1:8080:80 -v vol:/data IMAGE
container ls -a
container exec -it X sh
container logs -f X
container logs --boot X                        # READ THIS WHEN A CONTAINER DIES
container inspect X | jq -r '.[0].status.networks[0].ipv4Address'
container stop X && container rm X

# images
container build -t tag -f Dockerfile .
container build --arch arm64 --arch amd64 -t tag .
container image ls | pull | push | rm | prune

# builder (default 2 CPUs / 2 GiB is too small for real builds)
container builder stop && container builder delete
container builder start --cpus 8 --memory 32g

# machines (persistent Linux VMs, not containers - see section 11)
container machine create ubuntu:24.04 --name dev --cpus 4 --memory 8G
until container machine run -n dev -- true >/dev/null 2>&1; do sleep 1; done
container machine run -n dev -- <cmd> <args...>       # separate words, not 'sh -c "..."'
container machine list | inspect | stop | delete

# docker compatibility
./scripts/socktainer-service.sh start
docker context use socktainer

# cleanup
container prune && container image prune && container network prune
```

## Common mistakes, ranked

1. Emitting `--privileged` or `--network host`, then retrying variations.
2. Not setting `--memory`, then misdiagnosing the silent OOM as a broken image.
3. Reading `container logs` but not `container logs --boot`.
4. Assuming `docker` reaches Apple container without checking the context.
5. String-form `command:` in a Compose file used with `container-compose`.
6. Forgetting `TESTCONTAINERS_RYUK_DISABLED=true`.
7. `curl`ing a published port immediately after `run -d` with no retry loop.
8. Expecting `container-compose down` to remove containers.
9. Using anonymous volumes and expecting `--rm` to clean them up.
10. Putting a database data directory on a bind mount.
11. Running `container machine run` immediately after `create` without waiting
    for readiness, then reporting the machine as broken.
12. Reaching for a container when the task wanted a machine — a Linux shell, an
    init system, or a persistent filesystem.
