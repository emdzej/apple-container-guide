# Testcontainers on Apple container

> Condensed. The full treatment — per-language code, memory budgeting, cleanup
> wiring, and a symptom table — is in [docs/11-testcontainers.md](../../docs/11-testcontainers.md).

Testcontainers speaks the Docker API, so it works through **socktainer** — with
one mandatory change and a few caveats.

## Setup

```bash
../../scripts/socktainer-service.sh start
docker context use socktainer
```

Then tell Testcontainers where the socket is, and turn Ryuk off:

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
```

`TESTCONTAINERS_RYUK_DISABLED=true` is **not optional**. Ryuk is the sidecar that
reaps leftover containers, and it works by bind-mounting the Docker socket into
itself. socktainer does relay that bind mount, but Ryuk's reaping protocol is not
supported, so tests hang or fail on startup if you leave it on.

The trade-off: nothing cleans up after a crashed test run. Add a teardown step:

```bash
container ls -a --format json | jq -r '.[].configuration.id' | grep -E '^testcontainers' | xargs -r container rm -f
```

## Per-language configuration

Pick whichever fits your build; they are equivalent.

**Java / Kotlin** — `~/.testcontainers.properties` (no `$HOME` expansion, write the real path):

```properties
docker.host=unix:///Users/YOU/.socktainer/container.sock
testcontainers.reuse.enable=false
```

or as JVM args:

```
-Ddocker.host=unix:///Users/YOU/.socktainer/container.sock
-Dtestcontainers.ryuk.disabled=true
```

Maven / Gradle:

```bash
TESTCONTAINERS_RYUK_DISABLED=true mvn test
TESTCONTAINERS_RYUK_DISABLED=true ./gradlew test
```

**Node (testcontainers-node)**

```bash
DOCKER_HOST="unix://$HOME/.socktainer/container.sock" \
TESTCONTAINERS_RYUK_DISABLED=true \
npm test
```

**Go (testcontainers-go)** — `~/.testcontainers.properties` is read too, or:

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
go test ./...
```

**Python (testcontainers-python)**

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
pytest
```

**.NET** — set the same two environment variables; `Testcontainers` reads
`DOCKER_HOST` and `TESTCONTAINERS_RYUK_DISABLED`.

## Caveats that bite in practice

| Symptom | Cause | Fix |
|---|---|---|
| Container OOM-killed with no log | Each container is a VM with a **hard** 1 GiB default. Not a soft cgroup limit. | Set `withCreateContainerCmdModifier(c -> c.getHostConfig().withMemory(2L*1024*1024*1024))` or the equivalent memory option. |
| `initdb: directory exists but is not empty` | ext4 volumes always contain `/lost+found`. | socktainer removes it for Postgres automatically. If you opted out via `SOCKTAINER_CLEAN_VOLUMES=false`, don't. |
| A `withFixedExposedPort` test cannot reach the container | Fine — but static container IPs are not supported. | Use the mapped port / hostname the API returns, never a hard-coded IP. |
| Tests that assert on `/.dockerenv` | Apple container does not create that file; Docker's daemon fabricates it. | Detect the container differently (e.g. `/proc/1/cgroup`, or an env var you set). |
| `--privileged` containers (DinD, buildx driver) | No privileged mode exists. socktainer approximates it with `--cap-add=ALL`. | Works for many cases; real device access does not. |
| Very slow first run | Every container boots its own microVM and pulls its own kernel/init image the first time. | Warm the images once: `container image pull` the ones your suite uses. |
| Tests leak containers between runs | Ryuk is disabled. | Run the teardown snippet above, or `container prune` in CI. |

## Is it worth it?

If your suite is small and mostly Postgres/Redis/Kafka, yes — it works and you
get Docker Desktop's RAM back. If your suite depends on Ryuk semantics,
`--privileged`, Docker-in-Docker, or tight CPU limits, keep Docker Desktop or
Colima for tests and use Apple container for everything else. Switching is one
command: `duse desktop` / `duse apple`.
