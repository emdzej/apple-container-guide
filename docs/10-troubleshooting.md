# 10 — Troubleshooting

Start here:

```bash
./scripts/doctor.sh
```

It checks, in one pass: macOS version and architecture, mixed installs,
client/daemon version skew, service state, DNS configuration, socktainer health
and socket staleness, which runtime `docker` is pointed at, whether `DOCKER_HOST`
is overriding your context, competing runtimes, and disk usage.

## Multiple installs

**The single most common broken state, and the symptoms never point at it.**

The official `.pkg` installs to `/usr/local`. Homebrew installs to its own keg.
If you've used both, your CLI and your running `container-apiserver` are
different builds — and the XPC protocol between them is explicitly **not** a
stable interface across versions.

### Symptoms

- `container system status` shows `client.version` ≠ `server.version`
- plugins report `Plugin 'container-k8s' not found` even though the binary is on
  disk — because the daemon is running from the install root that *doesn't* have it
- socktainer logs `Apple Container version mismatch: detected X but this
  socktainer binary requires Y`
- assorted XPC connection errors that look like anything else

### Diagnose

```bash
container system status | grep -E 'client.version|server.version|installRoot'
command -v container
ls -d /usr/local/bin/container $(brew --prefix)/Cellar/container/* 2>/dev/null
davit platform status        # if you have Davit — best summary of all installs found
```

Note the two independent facts: which binary `PATH` resolves (`command -v
container`) and which install root the **daemon** came from (`paths.installRoot`).
They can differ, and that's the bug.

### Fix

```bash
container system stop

# keep Homebrew (recommended), drop the .pkg. -k keeps your images and volumes:
sudo /usr/local/bin/uninstall-container.sh -k

# or the reverse:
brew uninstall container

container system start
./scripts/doctor.sh
```

`-k` vs `-d` on the uninstaller matters: `-d` deletes
`~/Library/Application Support/com.apple.container` — every image, container and
volume you have. Use `-k` unless you mean it.

The uninstaller refuses to run while the services are up, so `container system
stop` first.

## `docker` doesn't see my containers

Nine times in ten it's the context.

```bash
dwhich                          # shell helper
./scripts/switch-runtime.sh     # same thing, no helpers needed
```

Check in this order:

1. **`DOCKER_HOST` is set.** It silently overrides whatever context you selected,
   so `docker context use` appears to do nothing. `echo $DOCKER_HOST` — and grep
   your shell profile, because something put it there.
2. **Wrong context.** `docker context ls`, then `docker context use socktainer`.
3. **socktainer isn't running.** `./scripts/socktainer-service.sh status`.
4. **Stale socket.** The socket file exists but nothing answers, so every docker
   call hangs for 30 seconds and then fails cryptically. `rm -f
   ~/.socktainer/container.sock && ./scripts/socktainer-service.sh start`.

## `docker context use socktainer` → "context not found"

You started socktainer with `brew services`. Homebrew's plist sets
`HOME=$(brew --prefix)/var/run/socktainer`, and socktainer derives **both** its
socket path and its Docker context file from `HOME`:

```
socket   -> /opt/homebrew/var/run/socktainer/.socktainer/container.sock
context  -> /opt/homebrew/var/run/socktainer/.docker/contexts/...
```

The socket works. The context is written where your `docker` CLI never looks.

```bash
brew services stop socktainer
./scripts/socktainer-service.sh start     # installs a LaunchAgent with the right HOME
```

Or keep brew services and point the context at the brew socket yourself:

```bash
docker context create socktainer \
  --docker host=unix://$(brew --prefix)/var/run/socktainer/.socktainer/container.sock
```

## A container "started" then died, and the logs are empty

Check the **boot log**. This is the diagnostic with no Docker equivalent — if the
guest VM failed to boot, or the process was killed before it wrote anything,
normal logs are empty and the answer is here.

```bash
container logs --boot <name>
cboot <name>                   # shell helper
```

Most common cause: **memory**. `--memory` is a hard VM reservation, default
1 GiB, not an elastic cgroup limit. A Postgres or JVM that was fine on Docker
Desktop gets OOM-killed inside the guest with no useful output.

```bash
container run --memory 2g ...
cres                           # what each container VM actually reserved
```

There is no "unlimited": Docker's `--memory 0` maps to the 1 GiB default, not
host RAM. Always pass an explicit value if you need more.

## Everything is slow / my Mac is swapping

Memory is **reserved per container**, not shared. Ten services with no limits
reserve 10 GiB whether they use it or not, and the platform will happily
overcommit past physical RAM and let macOS swap.

```bash
container stats
cres
container system status | grep -E 'containers|host.cpus'
```

Fix: set `mem_limit` per service in Compose, deliberately and small. Also check
Docker Desktop isn't still resident holding its own VM:

```bash
pgrep -fl 'Docker Desktop'
```

## `initdb: directory exists but is not empty`

ext4 named volumes always contain `/lost+found`, and Postgres refuses a
non-empty data directory.

- Use socktainer — it strips it automatically for Postgres images
- or `--env PGDATA=/var/lib/postgresql/data/pgdata`
- or clear it first: `container run --rm -v vol:/v alpine rm -rf /v/lost+found`

Same class of problem with MySQL, MongoDB and Elasticsearch. See
[07 — Storage](07-storage.md#the-lostfound-trap).

## `EHOSTUNREACH` / "no route to host" between containers

`vmnet` state degrades after a lot of network churn (many networks created and
destroyed). The documented fix:

```bash
container system stop && container system start
./scripts/socktainer-service.sh restart    # if you use socktainer
```

`cnetreset` does both.

## Containers can't resolve each other by name

Expected, in several cases. See [06 — Networking](06-networking.md).

- **Bare hostnames don't resolve.** With `[dns] domain = "test"` set, use
  `db.test`, not `db`.
- **On custom networks, neither form resolves.** This is the Compose-style
  zero-config discovery gap — [apple/container#1809](https://github.com/apple/container/issues/1809).
- **For Compose stacks, use socktainer.** It runs its own DNS and registers
  `<service>` and `<service>.<project>`, with no host DNS setup at all. This is
  the reason `docker compose` is the recommended compose path.
- **Two stacks with the same service name collide.** One global hostname
  namespace, last started wins. Always set `name:` in your Compose file and use
  the qualified form.

## `<name>.test` doesn't resolve from my Mac

You did step 1 (config) and not step 2 (the macOS resolver), or vice versa.

```bash
container system property list | grep -A2 '\[dns\]'   # step 1
ls /etc/resolver/                                      # step 2
./scripts/setup-dns.sh test                            # does both
```

## Compose service dies with "No such file or directory" naming your command

String-form `command:` under `container-compose`. It passes the whole string as
one argv element instead of word-splitting it. Use the list form:

```yaml
command: ["sh", "-c", "until pg_isready -h db; do sleep 1; done; exec myapp"]
```

Details in [04 — Compose](04-compose.md#the-command-string-form-trap).

## `container-compose down` didn't remove anything

Correct — it **stops** containers. They stay in `stopped` state, and volumes and
networks are untouched. That's the opposite of `docker compose down`, which
removes containers but keeps volumes unless you pass `-v`.

```bash
container-compose -f compose.yaml down
container rm myproj-db myproj-api myproj-web
```

## `container k8s` → "Plugin 'container-k8s' not found"

Two possible causes:

1. **Install-root mismatch.** The plugin exists under one install root but the
   daemon is running from the other. This is the mixed-install problem above —
   fix that and `container k8s` starts working with no other change.
2. **Your version genuinely doesn't ship it.** It's experimental and plugin-based.

```bash
container system status | grep installRoot
ls "$(container system status | awk '$1=="paths.installRoot"{print $2}')libexec/container-plugins" 2>/dev/null
ls "$(brew --prefix container)/libexec/container-plugins" 2>/dev/null
```

## Builds are slow or run out of memory

The builder is a VM with **2 CPUs and 2 GiB** by default, and its resources are
fixed at start. Recreate it bigger:

```bash
container builder stop && container builder delete
container builder start --cpus 8 --memory 32g
cbigbuilder 8 32g              # shell helper, same thing
```

Also keep `.dockerignore` tight — the whole build context crosses virtiofs into
the builder VM.

To reclaim the BuildKit layer cache (it lives inside the builder's VM, so there's
no other way):

```bash
container builder stop && container builder delete
```

## Disk keeps growing

Freed blocks inside a container's disk image are never returned to the host
filesystem, so usage only ever goes up until you prune.

```bash
container system df
./scripts/cleanup.sh              # safe set, asks before touching volumes
./scripts/cleanup.sh --aggressive # + all unused images + the builder cache
```

Watch for **anonymous volumes**: `-v /path` with no source creates one, and
unlike Docker it is **not** deleted with `--rm`. They accumulate invisibly.

```bash
container volume ls               # TYPE column says "anonymous"
container volume prune
```

## `docker save` fails with `ContentStore missing blob data`

The image was pulled from a registry. `container image pull` downloads only your
local platform's blobs but keeps the full multi-platform index, and `save`
exports the whole index. Save works fine for images that were *loaded* from a
tarball.

Workarounds: re-pull on the target instead of moving a tarball, or go through
`skopeo copy docker-daemon:img:tag oci-archive:/tmp/img.tar`.

## Private registry pulls fail after a successful login

Known upstream rough edge —
[apple/container#816](https://github.com/apple/container/issues/816) has the
current workarounds. `~/.docker/config.json` credential helpers
(`credHelpers`/`credsStore`) are honoured by both the platform and Davit, so ECR
and GCP Artifact Registry tokens generally work; static logins are the flakier
path.

```bash
container registry list
container registry login ghcr.io
```

## Testcontainers hangs on startup

Ryuk. It's mandatory to disable it:

```bash
export TESTCONTAINERS_RYUK_DISABLED=true
```

Then nothing reaps leftovers, so add a teardown. Full per-language setup, memory
budgeting and the symptom table: [11 — Testcontainers](11-testcontainers.md).

## amd64 image won't run

```bash
softwareupdate --install-rosetta --agree-to-license
container run --arch amd64 myimage
```

Rosetta is correct but slower, and some JITs and AVX-using binaries still fail
under it. Test rather than assume. `container system property list` shows
`build.rosetta` for the builder.

## It needs a feature this platform does not have

`--privileged` with device access, `--network host`, `--pid host`,
Docker-in-Docker, GPU passthrough: these are structural, not unimplemented.
There is no shared kernel for them to refer to, so no release will add them.

Use a fallback runtime for that project rather than fighting it:

```bash
./scripts/switch-runtime.sh colima     # or desktop
```

[12 — Alternatives](12-alternatives.md) covers which runtime to keep alongside,
and the licensing position of each.

## Collecting information for a bug report

```bash
container --version
container system status
container system property list
container system logs
container logs --boot <name>
sw_vers && uname -m
```

Apple's own guidance: [docs/bug-report-how-to.md](https://github.com/apple/container/blob/main/docs/bug-report-how-to.md).
For socktainer: run it in the foreground (`./scripts/socktainer-service.sh fg`)
and include the startup banner, which reports the detected runtime version.
