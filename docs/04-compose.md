# 04 — Compose

Three front ends can drive a Compose file on Apple container. They are **not**
equivalent. This page compares them on behaviour measured on the same stack
([examples/03-compose-web-db](../examples/03-compose-web-db)), not on their READMEs.

## Short answer

**Use `docker compose` through socktainer.** It's real Docker Compose, so the
feature coverage is Docker's, and socktainer answers the API on Apple
container's behalf. The other two are worth knowing about for specific reasons.

```bash
./scripts/socktainer-service.sh start
docker context use socktainer
docker compose up -d
```

## Comparison

| | `container-compose` 1.2.0 | `docker compose` + socktainer | `davit compose` |
|---|---|---|---|
| Needs Docker CLI | no | **yes** | no |
| Needs socktainer | no | **yes** | no |
| Talks to | the platform CLI | Docker API → XPC | XPC directly |
| `up` / `down` / `build` | yes | yes | yes |
| `ps` | **no** | yes, with health status | yes |
| `logs` | **no** | yes, `-f` | yes, `-f`, `--tail` |
| `exec` | **no** | yes | yes |
| `stop`/`start`/`restart`/`pull` | **no** | yes | yes |
| `plan` (dry run) | no | no | **yes** |
| Service-name DNS | `/etc/hosts`, short names only | **real DNS**, `db` and `db.myproj` | `/etc/hosts`, managed and re-synced |
| `depends_on` ordering | yes | yes | yes |
| `condition: service_healthy` | **no** (ordering only) | **yes** | **yes** |
| `healthcheck:` | ignored | yes | yes |
| `mem_limit` | **yes** | yes | yes |
| `cpus` | **ignored** (all services got 4) | yes (floored to whole cores) | yes |
| `restart:` | no | yes, while socktainer runs | no |
| `driver_opts` on volumes | **yes**, passed to `--opt` | yes | dropped |
| `profiles` | yes | yes | yes |
| `env_file` / `${VAR}` | yes | yes | yes, with docker-parity interpolation |
| `name:` project isolation | **naming only** (warns about it) | yes | yes |
| `command:` string form | **broken** — see below | yes | yes |
| `down` semantics | **stops only**; containers, volumes and networks remain | removes containers, keeps volumes without `-v` | removes containers; `-v` for volumes |

## The `command:` string-form trap

This is the single most common porting failure, and the error message points
nowhere useful.

```yaml
# breaks under container-compose
command: >
  sh -c 'until pg_isready -h db; do sleep 1; done; exec myapp'
```

```
/usr/local/bin/docker-entrypoint.sh: line 384: /sh -c 'until pg_isready -h db; ...'
: No such file or directory
```

Docker Compose applies shell-style word splitting to a string `command:`.
`container-compose` passes the whole string as a single argv element. Use the
list form, which means the same thing everywhere:

```yaml
command:
  - sh
  - -c
  - |
    until pg_isready -h db; do sleep 1; done
    exec myapp
```

## Always set `name:`

Apple container has **one global hostname namespace**. Two Compose projects that
both define a `db` service share the short DNS alias, and last-started wins.

```yaml
name: myapp     # sets com.docker.compose.project=myapp

services:
  db:
    image: postgres:17-alpine
```

Under socktainer you then get two aliases per service — `db` (short, convenient)
and `db.myapp` (qualified, unambiguous). Use the qualified form in anything that
has to survive a colleague running their own stack.

`container-compose` warns that `name:` only affects container naming for it —
networks and implicit volumes aren't isolated.

## Resource budgeting is different, and it will surprise you

Each service is its own VM, so `mem_limit` is **reserved per service**, not
shared across the stack:

```yaml
services:
  db:    { image: postgres:17-alpine, mem_limit: 1g }
  api:   { image: myapi,              mem_limit: 512m }
  web:   { image: nginx:alpine,       mem_limit: 256m }
  redis: { image: redis:alpine,       mem_limit: 256m }
```

That's 2 GiB reserved the moment the stack is up, regardless of actual use. On
Docker Desktop the same file would share one VM's memory elastically.

Services with no limit get the platform default — 1 GiB, 4 CPUs. A ten-service
stack with no limits reserves 10 GiB. Set limits deliberately; the platform will
happily overcommit past physical RAM and let macOS swap.

```bash
cres    # shell helper: what each container VM actually reserved
```

## When to use which

### `docker compose` + socktainer — the default

Widest coverage, because it *is* Docker Compose. Verified working on the example
stack: healthcheck-gated `depends_on` (`db Waiting` → `db Healthy` → `api
Starting`), `ps` with health status, `logs -f`, `exec`, published ports, named
volumes with `driver_opts`, and DNS for both `db` and `db.myproj` — with no
`[dns]` domain configured on the host, because socktainer runs its own DNS
server.

Costs: two extra moving parts (the Docker CLI and the socktainer daemon), and
you inherit socktainer's approximations — `--privileged` → `--cap-add=ALL`,
`restart:` policies that don't survive a reboot, no static IPs, no
pause/unpause.

```bash
docker compose up -d
docker compose ps
docker compose logs -f api
docker compose exec api sh
docker compose down -v
```

### `container-compose` — when you want no Docker at all

The Apple-native option. Genuinely useful if your stack is simple and you'd
rather not run a Docker CLI or a compatibility daemon.

Verified working: `mem_limit`, published ports, named volumes including
`driver_opts` (so socktainer's `sync=` modes survive), `depends_on` ordering,
`profiles`, `env_file`, `${VAR}` interpolation, and short-name service discovery
via `/etc/hosts` written into each container.

Verified *not* working: string-form `command:`, `cpus:`, healthcheck conditions,
`restart:`, project-level isolation.

It has four subcommands — `up`, `down`, `build`, `version`. Everything else
drops to the platform CLI:

```bash
container-compose -f compose.yaml up -d -b     # -b builds first
container ls -a                                 # instead of ps
container logs -f myproj-api                    # instead of logs
container exec -it myproj-api sh                # instead of exec
container-compose -f compose.yaml down          # stops; does NOT remove
container rm myproj-db myproj-api myproj-web    # actually remove
```

Note that `down` only **stops**. Containers stay in `stopped` state and volumes
are untouched — the reverse of `docker compose down`, which removes containers
but keeps volumes unless you pass `-v`.

Discovery detail: it writes `/etc/hosts` entries at `up` time. A service
recreated outside compose leaves stale IPs behind in the containers that kept
running.

### `davit compose` — when you want to see the plan first

Talks XPC directly, no Docker API involved. Its distinguishing feature is `plan`:

```bash
davit compose plan -f compose.yaml
```

prints the equivalent `container run` for every service in `depends_on` order,
the volumes and networks it will create, and warnings for anything unsupported —
before creating anything. That's genuinely useful when porting a stack you don't
fully trust.

Also has `--down-on-failure`, which rolls back only what the current invocation
created, leaving already-running services it reused alone.

**Argument order is subcommand-first**, unlike the others:

```bash
davit compose plan -f compose.yaml            # correct
davit compose -f compose.yaml plan            # rejected: "unknown subcommand: -f"
```

And `-f` is overloaded — in `compose logs -f` it means `--follow`, so pass the
file last (`logs --tail 20 -f compose.yaml api`) or rely on autodiscovery.

Discovery is `/etc/hosts` based, re-synced on every `up`/`start`/`restart`.
Images without `/bin/sh` can't be patched and get no entries (it warns).

## Before you port a stack

```bash
./scripts/compose-check.sh compose.yaml
```

Flags `privileged`, `network_mode: host`, devices, GPU reservations, static IPs,
`cpu_shares`, `docker.sock` mounts, missing `name:`, and the Postgres
`/lost+found` issue, with a note on which front end handles each.

## Next

- [05 — Docker compatibility](05-docker-compat.md)
