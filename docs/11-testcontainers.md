# 11 — Testcontainers

Testcontainers speaks the Docker Engine API, so it runs on Apple container
through **socktainer**. It works well — Postgres, Redis, Kafka, MySQL,
LocalStack, Elasticsearch all come up — but there is one **mandatory** change and
a handful of caveats that produce confusing failures if you don't know them
upfront.

> **TL;DR**
> ```bash
> ./scripts/socktainer-service.sh start
> export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
> export TESTCONTAINERS_RYUK_DISABLED=true
> ```
> Then run your suite as normal. Both variables are required, not optional.

## Why socktainer, and not the platform directly

Testcontainers has no Apple container backend. It constructs Docker Engine API
calls — `POST /containers/create`, `/containers/{id}/start`, port inspection,
log streaming — and socktainer answers them on Apple container's behalf.
`container` alone cannot serve those calls; there is no Docker API on the XPC
interface.

So the chain is:

```
your test  ->  Testcontainers client  ->  Docker Engine API (v1.51, partial)
           ->  socktainer  ->  XPC  ->  container-apiserver  ->  one VM per container
```

## Setup

### 1. Start socktainer

```bash
./scripts/socktainer-service.sh start
```

This installs a LaunchAgent so it survives logout and reboot. Don't use
`brew services start socktainer` — it sets `HOME` to a Homebrew directory, which
puts the socket somewhere your tools won't find and writes the Docker context
where your CLI never looks. The script header explains it; so does
[05 — Docker compatibility](05-docker-compat.md#dont-use-brew-services-start-socktainer).

Verify:

```bash
./scripts/socktainer-service.sh status
docker --context socktainer ps
```

### 2. Set `DOCKER_HOST`

Most Testcontainers clients read `DOCKER_HOST` and **ignore Docker contexts
entirely**. Selecting the `socktainer` context is not enough on its own.

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
```

There's a ready-made snippet:

```bash
source examples/06-testcontainers/env.sh
```

> Setting `DOCKER_HOST` permanently in your shell profile is a trap for
> everything *else*: it silently overrides whatever Docker context you select, so
> `docker context use desktop-linux` appears to do nothing. Scope it to your test
> command or your build tool, not your profile. `dwhich` warns when it's set.

### 3. Disable Ryuk — mandatory

```bash
export TESTCONTAINERS_RYUK_DISABLED=true
```

**Why.** Ryuk is Testcontainers' reaper sidecar: it starts first, your test
session connects to it, and when the connection drops Ryuk deletes everything
labelled with that session. It works by **bind-mounting the Docker socket into
itself**.

socktainer does relay a `/var/run/docker.sock` bind mount to its own API, but
Ryuk's reaping protocol isn't supported. Leave it enabled and your suite hangs
during container startup or fails with a `Can not connect to Ryuk` style error
before a single test runs.

**The cost.** Nothing cleans up after a crashed or killed test run. Leftover
containers accumulate and hold reserved memory. Add explicit teardown — see
[Cleaning up without Ryuk](#cleaning-up-without-ryuk).

## Per-language configuration

All equivalent; pick whatever fits your build.

### Java / Kotlin

Environment variables work, and are the least surprising in CI:

```bash
DOCKER_HOST="unix://$HOME/.socktainer/container.sock" \
TESTCONTAINERS_RYUK_DISABLED=true \
./gradlew test
```

Or `~/.testcontainers.properties` — note that **`$HOME` is not expanded** in this
file, so write the literal path:

```properties
docker.host=unix:///Users/YOU/.socktainer/container.sock
testcontainers.reuse.enable=false
```

Or JVM system properties, which is the cleanest option for a shared build file:

```groovy
// build.gradle.kts / build.gradle
tasks.test {
    systemProperty("docker.host", "unix://${System.getProperty("user.home")}/.socktainer/container.sock")
    environment("TESTCONTAINERS_RYUK_DISABLED", "true")
}
```

```xml
<!-- maven-surefire-plugin -->
<configuration>
  <environmentVariables>
    <DOCKER_HOST>unix:///Users/YOU/.socktainer/container.sock</DOCKER_HOST>
    <TESTCONTAINERS_RYUK_DISABLED>true</TESTCONTAINERS_RYUK_DISABLED>
  </environmentVariables>
</configuration>
```

Sizing a container's memory (see [the memory caveat](#1-memory-is-a-hard-reservation)):

```java
var postgres = new PostgreSQLContainer<>("postgres:17-alpine")
    .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig()
        .withMemory(2L * 1024 * 1024 * 1024));   // 2 GiB
```

### Node / TypeScript

```bash
DOCKER_HOST="unix://$HOME/.socktainer/container.sock" \
TESTCONTAINERS_RYUK_DISABLED=true \
npm test
```

Or in the test setup, before any container is created:

```ts
process.env.DOCKER_HOST = `unix://${process.env.HOME}/.socktainer/container.sock`;
process.env.TESTCONTAINERS_RYUK_DISABLED = "true";
```

```ts
import { GenericContainer } from "testcontainers";

const redis = await new GenericContainer("redis:alpine")
  .withExposedPorts(6379)
  .withResourcesQuota({ memory: 0.5 })   // GiB — see the CPU caveat below
  .start();

// Always use the mapped port. Never hard-code one.
const url = `redis://${redis.getHost()}:${redis.getMappedPort(6379)}`;
```

### Go

`testcontainers-go` reads `~/.testcontainers.properties` as well as the
environment:

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
go test ./...
```

```go
req := testcontainers.ContainerRequest{
    Image:        "postgres:17-alpine",
    ExposedPorts: []string{"5432/tcp"},
    Env:          map[string]string{
        "POSTGRES_PASSWORD": "devonly",
        // Keep PGDATA off the volume root: ext4 volumes contain /lost+found.
        "PGDATA":            "/var/lib/postgresql/data/pgdata",
    },
    WaitingFor: wait.ForListeningPort("5432/tcp").WithStartupTimeout(2 * time.Minute),
}
```

Note the generous startup timeout — every container boots a kernel here.

### Python

```bash
export DOCKER_HOST="unix://$HOME/.socktainer/container.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
pytest
```

Or in `conftest.py`, before importing `testcontainers`:

```python
import os
from pathlib import Path

os.environ["DOCKER_HOST"] = f"unix://{Path.home()}/.socktainer/container.sock"
os.environ["TESTCONTAINERS_RYUK_DISABLED"] = "true"
```

### .NET

Same two environment variables; `Testcontainers` reads `DOCKER_HOST` and
`TESTCONTAINERS_RYUK_DISABLED`. Or explicitly:

```csharp
var container = new ContainerBuilder()
    .WithImage("postgres:17-alpine")
    .WithDockerEndpoint($"unix://{Environment.GetFolderPath(
        Environment.SpecialFolder.UserProfile)}/.socktainer/container.sock")
    .WithPortBinding(5432, true)
    .Build();
```

## The caveats that actually bite

### 1. Memory is a hard reservation

The most common failure, and the least obvious. `--memory` here is **RAM
allocated to the container's VM at boot**, not an elastic cgroup limit. The
default is **1 GiB**. A Postgres or JVM container that was comfortable on Docker
Desktop gets OOM-killed inside the guest, and the process dies with nothing
useful in the container logs.

```bash
container logs --boot <name>     # the guest-side death is here, not in normal logs
cres                             # what each container VM actually reserved
```

Set it explicitly per container (examples above per language). There is no
"unlimited" — Docker's `--memory 0` maps to the 1 GiB default, not host RAM.

Then budget the whole suite: memory is reserved **per container**, not shared.
Six containers at 1 GiB each reserve 6 GiB the moment they're up. A suite that
starts containers in parallel across test classes can reserve more than your Mac
has, at which point macOS swaps and everything crawls.

### 2. `--cpus` is whole cores

Fractions are floored to the nearest whole core, minimum 1. `withCpuCount(0.5)`
gets 1 vCPU. `cpu_shares`, `cpu_period` and `cpu_quota` have no effect at all.
Tests that assert on CPU throttling behaviour won't reproduce.

### 3. Postgres and `/lost+found`

Every Apple container named volume is ext4, and ext4 always has a `/lost+found`
directory. `initdb` refuses a non-empty data directory.

socktainer **removes it automatically** when a Postgres container is created, so
this usually just works. It only breaks if you opted out with
`SOCKTAINER_CLEAN_VOLUMES=false` or the volume label
`socktainer.clean-volumes=false`. Don't.

For other databases with the same check (MySQL, MongoDB, Elasticsearch), point
the data directory at a subdirectory: `PGDATA=/var/lib/postgresql/data/pgdata`
and equivalents.

### 4. Startup is slower, so raise your timeouts

Every container boots its own microVM. First run per image also fetches the
guest kernel and init image. Expect ~1–3 s per container instead of ~100 ms, and
much more on a cold image.

Warm the images once before the suite:

```bash
container image pull postgres:17-alpine
container image pull redis:alpine
container image pull confluentinc/cp-kafka:latest
```

And raise startup timeouts rather than fighting flaky waits:

```java
.withStartupTimeout(Duration.ofMinutes(2))
```

### 5. No static IPs — use the mapped port

`--ip` and per-container IPAM config can't be honoured; the address allocator
rotates. Always use `getHost()` + `getMappedPort()` (or your language's
equivalent) and never a hard-coded address or fixed host port.

Fixed host ports (`withFixedExposedPort`) do work, but they collide with anything
else already on that port — including Docker Desktop if it's still running.

### 6. `/.dockerenv` doesn't exist

Docker's daemon fabricates that file inside every container. Apple container
doesn't. Code (yours or a library's) that probes `/.dockerenv` to answer "am I
inside a container" will decide it isn't. Detect it another way — an environment
variable you set, or `/proc/1/cgroup`.

This also affects filesystems exported with `docker export`.

### 7. Docker-in-Docker and `--privileged` won't work properly

There is no privileged mode on this platform. socktainer maps `--privileged` to
`--cap-add=ALL`, which unblocks some uses (buildx's `docker-container` driver
rbind-mounting its build context) but grants no device access and doesn't touch
seccomp or AppArmor.

Suites that start a `docker:dind` container, or Testcontainers modules that need
a nested daemon, are the ones to keep on Docker Desktop or Colima.

### 8. Container reuse is unreliable without Ryuk

`testcontainers.reuse.enable=true` depends on bookkeeping that assumes a reaper
is present. Leave reuse off:

```properties
testcontainers.reuse.enable=false
```

## Cleaning up without Ryuk

Add this to your test teardown, a `make` target, or a git hook — whatever you'll
actually run.

```bash
# containers Testcontainers created (it labels them)
docker --context socktainer ps -aq \
  --filter "label=org.testcontainers=true" | xargs -r docker --context socktainer rm -f

# volumes it left behind
docker --context socktainer volume ls -q \
  --filter "label=org.testcontainers=true" | xargs -r docker --context socktainer volume rm
```

Blunter, via the platform CLI — useful when the labels were normalised or you
just want a clean slate:

```bash
container stop --all
container prune
container volume prune     # destroys volume contents, no undo
```

Nuclear, and the fastest way to reclaim reserved memory:

```bash
container system stop && container system start
```

Recommended Gradle wiring:

```kotlin
tasks.register<Exec>("reapTestcontainers") {
    commandLine("bash", "-c",
        "docker --context socktainer ps -aq --filter label=org.testcontainers=true " +
        "| xargs -r docker --context socktainer rm -f")
    isIgnoreExitValue = true
}
tasks.test { finalizedBy("reapTestcontainers") }
```

## Verifying your setup

```bash
# 1. socktainer is answering
./scripts/socktainer-service.sh status

# 2. the Docker API works and sees Apple container
docker --context socktainer ps

# 3. a container starts, publishes a port and is reachable
docker --context socktainer run -d --name tc-probe -p 127.0.0.1:55432:5432 \
  -e POSTGRES_PASSWORD=devonly --memory 1g postgres:17-alpine
sleep 15
docker --context socktainer exec tc-probe pg_isready
docker --context socktainer rm -f tc-probe
```

If all three pass, Testcontainers will work. If step 3 fails, it's the platform,
not Testcontainers — start at [10 — Troubleshooting](10-troubleshooting.md).

## Symptom table

| Symptom | Cause | Fix |
|---|---|---|
| Hangs before any test runs; `Can not connect to Ryuk` | Ryuk enabled | `TESTCONTAINERS_RYUK_DISABLED=true` |
| `Could not find a valid Docker environment` | `DOCKER_HOST` unset, or socktainer down | `source examples/06-testcontainers/env.sh` |
| Every docker call hangs ~30 s then fails | stale socket from a crashed socktainer | `rm -f ~/.socktainer/container.sock && ./scripts/socktainer-service.sh start` |
| Container exits immediately, logs empty | OOM inside the guest VM | raise `--memory`; check `container logs --boot` |
| `initdb: directory exists but is not empty` | ext4 `/lost+found` | don't disable `SOCKTAINER_CLEAN_VOLUMES`; or set `PGDATA` to a subdir |
| Flaky wait strategies / startup timeouts | a kernel boots per container | raise timeouts; pre-pull images |
| Works, then fails after many runs; `EHOSTUNREACH` | `vmnet` state degraded | `container system stop && container system start`, restart socktainer (`cnetreset`) |
| Leftover containers after a crashed run | Ryuk disabled | run the reaper snippet above |
| Assertion on `/.dockerenv` fails | not created here | detect containers differently |
| Mysterious XPC errors | client/daemon version skew | `./scripts/doctor.sh` |

## Should you use it here?

| Your suite | Verdict |
|---|---|
| Postgres / MySQL / Redis / Kafka / LocalStack / Elasticsearch | **Yes.** Works, and you get Docker Desktop's idle RAM back. |
| Many containers started in parallel | **Careful.** Memory is reserved per container; budget it or you'll swap. |
| Depends on Ryuk semantics for cleanup | **Workable**, with your own teardown. |
| Docker-in-Docker, `--privileged` with devices, tight CPU limits | **No.** Keep Docker Desktop or Colima for this project. |

You don't have to decide globally. `duse desktop` before a problematic suite,
`duse apple` afterwards — or scope `DOCKER_HOST` per project so different repos
use different runtimes.

## See also

- [examples/06-testcontainers](../examples/06-testcontainers/README.md) — the
  `env.sh` helper and a condensed version of this page
- [05 — Docker compatibility](05-docker-compat.md) — what socktainer does and
  doesn't implement
- [socktainer's own Testcontainers tutorial](https://socktainer.github.io/tutorial/testcontainers)
