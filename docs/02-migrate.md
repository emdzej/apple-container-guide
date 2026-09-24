# 02 — Migrate

Order matters. Do it in this sequence and you always have a working setup.

```
1. install alongside Docker Desktop        (nothing breaks)
2. audit what you actually have            (compose-check.sh, migrate-*.sh --list)
3. move images                             (cheap, reversible)
4. move volumes                            (the only irreversible-ish part — back up)
5. port one stack, verify it               (pick your least critical project)
6. switch the docker context                (one command, one command back)
7. run for a week
8. remove Docker Desktop                    (last)
```

## 1. Install alongside

See [01 — Install](01-install.md). Don't uninstall anything yet.

```bash
./scripts/bootstrap.sh
./scripts/doctor.sh
```

## 2. Audit

What's in Docker Desktop:

```bash
./scripts/migrate-images.sh --list
./scripts/migrate-volumes.sh --list      # includes apparent size per volume
```

What your Compose files will do here:

```bash
./scripts/compose-check.sh path/to/compose.yaml
```

That flags three tiers: things with no equivalent (`privileged`, `network_mode:
host`, devices, GPU), things that are accepted but approximated (`cpus`,
`restart`, static IPs), and things that work with a caveat. Read the output
before you port anything — it's cheaper than discovering it at 4pm.

## 3. Images

Two transports. `migrate-images.sh` picks per image.

**Registry pull** — for anything that came from a registry. Fastest, and you get
the right platform's blobs:

```bash
container image pull postgres:17-alpine
```

**Tar handoff** — for images you built locally and never pushed:

```bash
docker --context desktop-linux save myapp:dev | docker --context socktainer load
```

This works because socktainer's `/images/load` endpoint accepts real Docker
tarballs (plain, gzip or zstd). Going directly through `container image load`
does *not* work for Docker's output — that wants an OCI archive, and
`docker save` produces a Docker archive.

Both at once:

```bash
./scripts/migrate-images.sh --all
./scripts/migrate-images.sh myapp:dev myapp:staging   # or specific ones
```

### Two image caveats

- **`container image pull` downloads only your local platform's blobs** but keeps
  the full multi-platform index. That's why `docker save` through socktainer
  fails with `ContentStore missing blob data` for registry-pulled images. Save
  works fine for images that were loaded from a tarball.
- **`docker load` drops index entries whose blobs aren't in the tarball.** Real
  `docker save` ships only the pulling platform's blobs while keeping the full
  index, so a multi-arch image comes across single-arch. Rebuild with
  `--arch arm64 --arch amd64` if you need both ([example 05](../examples/05-multiplatform)).

### Registry credentials

`~/.docker/config.json` is shared. Apple container and socktainer both read it,
including `credHelpers` / `credsStore` entries — so ECR, GCP Artifact Registry
and the macOS keychain helper keep working.

```bash
container registry login ghcr.io
container registry list
```

If a login succeeds but private pulls still fail, that's a known upstream rough
edge ([apple/container#816](https://github.com/apple/container/issues/816)) — a
manual credential workaround may be needed.

## 4. Volumes

**Back up first.** The transport is a tar through a scratch directory on your
Mac, which is the only format both runtimes agree on.

```bash
./scripts/migrate-volumes.sh --list
./scripts/migrate-volumes.sh myapp_pgdata --size 20g
./scripts/migrate-volumes.sh --all --keep-tar     # keep the intermediates
```

The script stops short of anything clever: it tars the source out, creates the
destination volume, clears it (preserving `/lost+found`), untars, then compares
file counts and tells you if they differ.

**Stop the containers using a volume first.** Copying a live Postgres data
directory gives you a torn copy that may or may not recover.

### The `/lost+found` trap

Every Apple container named volume is an ext4 filesystem, and ext4 always has a
`/lost+found` directory. Postgres `initdb` refuses to initialise a data directory
that isn't empty, so a fresh named volume fails with:

```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
```

Three ways out:

- Use socktainer — it strips `/lost+found` for Postgres images automatically
  (disable with `SOCKTAINER_CLEAN_VOLUMES=false`, or per-volume with the label
  `socktainer.clean-volumes=false`; you almost certainly don't want to).
- Set `PGDATA` to a subdirectory: `PGDATA=/var/lib/postgresql/data/pgdata`.
- Clear it yourself before first start — see [example 04](../examples/04-postgres-volume/run.sh).

### Check ownership after the copy

Tar preserves uid/gid numerically. If the source image ran as uid 999 and the
destination image uses a different uid, the database won't start. Verify:

```bash
container run --rm -v myapp_pgdata:/v alpine ls -ln /v
```

## 5. Port one stack

Start with your least critical project. Pick a compose front end
([04 — Compose](04-compose.md) compares them on measured behaviour); if you want
the shortest path, it's `docker compose` through socktainer.

```bash
./scripts/socktainer-service.sh start
docker --context socktainer compose up -d
docker --context socktainer compose ps
docker --context socktainer compose logs -f
```

Using `--context` rather than `docker context use` means you haven't changed
anything global yet.

Things to check explicitly, because they're the ones that differ:

- **Service discovery.** Can your app resolve its database by service name?
  `docker compose exec api getent hosts db`
- **Memory.** Did anything get OOM-killed? `container logs --boot <name>` shows
  guest-side deaths that don't appear in normal logs.
- **Ports.** `container ls` shows each container's real IP; you can reach it
  directly from the host without publishing anything.
- **Startup time.** Every service boots a kernel. A 12-service stack is
  noticeably slower to come up than on Docker Desktop.
- **Total RAM.** Memory is reserved per container, not shared. A stack of six
  services at 1 GiB each reserves 6 GiB. Size them down deliberately.

## 6. Switch the context

```bash
./scripts/switch-runtime.sh apple
```

Then check nothing in your shell profile sets `DOCKER_HOST` — it silently
overrides the context and you'll spend an afternoon on it. `dwhich` warns you.

Also update, if you have them:

- IDE Docker integrations → point at `unix://$HOME/.socktainer/container.sock`
- `.testcontainers.properties` → see [11 — Testcontainers](11-testcontainers.md)
- CI runners → they're probably Linux and unaffected; this is a local-dev change
- Makefiles / scripts with hard-coded `/var/run/docker.sock` → these need the
  socktainer path

## 7. Run for a week

Keep Docker Desktop installed. When something doesn't work, `duse desktop`, get
on with your day, and note what broke. Real usage finds things an audit doesn't.

## 8. Remove Docker Desktop

```bash
./scripts/uninstall-docker-desktop.sh            # dry run — shows what it touches
./scripts/uninstall-docker-desktop.sh --execute
```

It runs Docker Desktop's own uninstaller first (which unloads the privileged
`vmnetd` helper — deleting the app alone leaves that behind), then removes the
support directories, then unloads any leftover launch daemons.

It deliberately **keeps** the `docker` CLI and `~/.docker/config.json`: the CLI is
what talks to socktainer, and the config holds your registry logins.

Expect to get 15–20 GB back from the VM disk image alone.

## Next

- [03 — CLI mapping](03-cli-mapping.md): the `docker` → `container` translation table.
