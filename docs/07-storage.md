# 07 — Storage

Three kinds of mount, same as Docker, with different performance and different
traps.

| | Backing | Speed | Use for |
|---|---|---|---|
| Bind mount (`-v /host/path:/c/path`) | virtiofs to your Mac's filesystem | slowest | source code you edit |
| Named volume (`-v name:/c/path`) | sparse ext4 disk image | fast | databases, caches, anything write-heavy |
| tmpfs (`--tmpfs /path`) | guest VM RAM | fastest | scratch, test fixtures |

The rule of thumb is the same as on Docker Desktop but the gap is wider: **never
put a database data directory on a bind mount.** Use a named volume.

## Bind mounts

```bash
container run -v "$PWD:/work" -w /work node:22-alpine npm test
container run --mount source="$PWD",target=/work node:22-alpine ls /work
container run -v "$PWD:/work:ro" alpine ls /work         # read-only
```

`--volume` uses `[source:]destination[:options]`. The **only** option is `ro`.
Docker's `:z`, `:Z`, `:cached`, `:delegated`, `:consistent` don't exist — drop
them from ported commands rather than hoping they're ignored.

`--mount` is the `key=value` form:

| Key | Values | Notes |
|---|---|---|
| `type` | `bind` (alias `virtiofs`), `volume`, `tmpfs` | defaults to `bind` |
| `source`, `src` | host path, or volume name | omit for tmpfs, or for an anonymous volume |
| `destination`, `dst`, `target` | absolute container path | |
| `readonly`, `ro` | key only | |
| `size` | `512M`, `1G` | tmpfs only |
| `mode` | octal, e.g. `1777` | tmpfs only |

An unrecognised key is an error, not a warning — which is better than Docker.

## Named volumes

```bash
container volume create foo
container volume create -s 20g foo                       # size ceiling
container volume create --opt journal=writeback:64m foo   # faster journalling
container volume ls
container volume inspect foo
container volume delete foo
container volume prune        # everything with no container referencing it
```

Mount by name:

```bash
container run -it --rm -v foo:/mnt/foo alpine sh
container run -it --rm --mount type=volume,source=foo,target=/mnt/foo alpine sh
```

### Sizing

A volume is a **sparse** disk image, so `sizeInBytes` is a ceiling, not an
allocation. The default is 512 GiB and costs nothing up front. Setting `-s 20g`
caps it; you can't grow it afterwards.

### Journal modes

```bash
container volume create --opt journal=ordered myvol              # default
container volume create --opt journal=writeback:64m myvol        # faster, less safe
container volume create --opt journal=journal --opt size=10g myvol   # full data journal
```

`writeback` is a reasonable trade for a dev database: noticeably faster WAL
writes, and the data you'd lose in a crash is data you don't care about.

### The `/lost+found` trap

Every named volume is ext4, and ext4 **always** has a `/lost+found` directory.
Postgres `initdb` refuses a non-empty data directory:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
```

MySQL, MongoDB and Elasticsearch have variations of the same check.

Fixes, best first:

1. **Use socktainer.** It removes `/lost+found` automatically when a Postgres
   container is created, before `initdb` runs. (Opt out with
   `SOCKTAINER_CLEAN_VOLUMES=false` or the volume label
   `socktainer.clean-volumes=false`. Don't.)
2. **Point the data dir at a subdirectory:**
   `--env PGDATA=/var/lib/postgresql/data/pgdata`
3. **Clear it yourself before first start:**
   ```bash
   container run --rm -v mydata:/v alpine rm -rf /v/lost+found
   ```

[Example 04](../examples/04-postgres-volume/run.sh) shows all three in context.

### Anonymous volumes

`-v /path` with no source creates one — named with a bare UUID and labelled
`com.apple.container.resource.anonymous`.

**They are not deleted when the container is removed with `--rm`.** Unlike
Docker. They accumulate silently until you notice `container system df` climbing.

```bash
# find them
container volume ls                 # TYPE column says "anonymous"
container volume list --format json | jq -r '.[] | select(.configuration.labels["com.apple.container.resource.anonymous"] != null) | .id'
container volume prune              # removes the unreferenced ones
```

Prefer explicit named volumes so they're identifiable six months later.

## tmpfs

```bash
container run --rm --tmpfs /scratch alpine mount -t tmpfs
container run --rm --tmpfs /scratch:size=64M,mode=1777 alpine sh
container run --rm --mount type=tmpfs,target=/scratch,size=512M alpine stat -f /scratch
```

It's guest VM **memory**, and the VM's memory is a hard reservation. A 512 MiB
tmpfs inside a 1 GiB container leaves 512 MiB for your process. Size `--memory`
to cover both.

Every container already has a `/dev/shm` tmpfs at 64 MiB; raise it with
`--shm-size 1g` (Chrome/Puppeteer and Postgres parallel query both want this).

## socktainer volume sync modes

This one is unique to socktainer and worth understanding, because the default
trades durability for speed.

Named volumes default to **`nosync`**: guest `fsync()` calls are not flushed to
the host disk on demand. Roughly 1.5× faster for write-heavy workloads —
Postgres WAL, Kafka, Redis AOF — and it matches Colima's behaviour.

**The trade:** data written since the last OS page-cache flush can be lost if
**your Mac** crashes or loses power. Data is safe across a normal `docker stop`
and across host restarts. For a dev database that is the right default. For
anything you'd be upset to lose, it isn't.

```bash
socktainer --volume-sync=fsync    # honour guest fsyncs (durable)
socktainer --volume-sync=full     # fully synchronous (slowest)
socktainer --volume-sync=nosync   # default
```

Per volume, which overrides the global flag and persists:

```bash
docker volume create -o sync=fsync my-pgdata
```

```yaml
volumes:
  pgdata:
    driver: local
    driver_opts:
      sync: fsync
```

`container-compose` passes `driver_opts` through to `container volume create
--opt`, so this survives there too. `davit compose` drops them.

Set it for the service via the helper script:

```bash
SOCKTAINER_VOLUME_SYNC=fsync ./scripts/socktainer-service.sh restart
```

## Performance

Measured shape, not exact numbers — benchmark your own workload:

- **tmpfs** ≫ **named volume** > **bind mount**, with the bind-mount gap larger
  than on Docker Desktop.
- `node_modules` on a bind mount is the classic killer. Put the project on a bind
  mount and `node_modules` on a named volume:
  ```bash
  container run -v "$PWD:/app" -v app-node-modules:/app/node_modules -w /app node:22-alpine npm run dev
  ```
  Same trick as Docker Desktop, bigger payoff.
- Build caches, Gradle/Maven/Cargo/pip caches: named volumes.
- Large `COPY` in a Dockerfile: keep a tight `.dockerignore`. The whole context
  crosses virtiofs into the builder VM.

## Disk usage and reclaiming

Every container gets its own sparse disk image for its writable layer; every
volume gets another. **Deleting files inside a container does not shrink its
image** — freed blocks aren't returned to the host filesystem. Disk use only
goes up until you prune.

```bash
container system df
# TYPE            TOTAL  ACTIVE  SIZE     RECLAIMABLE
# Images          12     4       3.2GB    1.1GB (34%)
# Containers      4      2       890MB    210MB (24%)
# Local Volumes   6      3       4.5GB    2.1GB (47%)
```

```bash
container prune                  # stopped containers
container image prune            # dangling images
container image prune --all      # everything unused, not just dangling
container volume prune           # unreferenced volumes — DESTROYS DATA
container network prune

# the builder's BuildKit layer cache lives inside its VM; replacing it is the
# only way to reclaim that space
container builder stop && container builder delete
```

`./scripts/cleanup.sh` runs the safe set and shows before/after. `--aggressive`
adds all-unused images and the builder. It asks before touching volumes.

## Backup and restore

No native `volume export`. Tar through a throwaway container:

```bash
# backup
container run --rm -v mydata:/vol:ro -v "$PWD:/backup" alpine \
  tar czf /backup/mydata.tar.gz -C /vol .

# restore
container volume create mydata
container run --rm -v mydata:/vol -v "$PWD:/in:ro" alpine \
  tar xzf /in/mydata.tar.gz -C /vol
```

Shell helpers: `cvbackup mydata ~/backups` and `cvrestore mydata ~/backups/mydata-*.tar.gz`.
`./scripts/migrate-volumes.sh` uses the same transport to move volumes from
Docker Desktop, and verifies file counts afterwards.

Tar preserves uid/gid numerically. If the source image ran as a different uid
than the destination, fix ownership before starting the service:

```bash
container run --rm -v mydata:/v alpine ls -ln /v
container run --rm -v mydata:/v alpine chown -R 999:999 /v
```

## Next

- [08 — GUI](08-gui.md)
