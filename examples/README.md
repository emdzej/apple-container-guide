# Examples

Every script is runnable and self-cleaning where it can be. They assume
`container system start` has been run — most do it themselves.

Run `../scripts/doctor.sh` first if anything misbehaves.

| Example | What it demonstrates | Run |
|---|---|---|
| [01-hello](01-hello) | build + run, the end-to-end smoke test | `./01-hello/run.sh` |
| [02-node-web](02-node-web) | published ports, live bind mount, per-container CPU/memory | `./02-node-web/run.sh` |
| [03-compose-web-db](03-compose-web-db) | the same 3-service stack through all three compose front ends | `./03-compose-web-db/up-docker-compose.sh` |
| [04-postgres-volume](04-postgres-volume) | named volumes, the `/lost+found` trap, database memory sizing | `./04-postgres-volume/run.sh` |
| [05-multiplatform](05-multiplatform) | arm64 + amd64 in one image, Rosetta | `./05-multiplatform/build.sh` |
| [06-testcontainers](06-testcontainers) | Java/Node/Go/Python/.NET config, and the Ryuk requirement ([full doc](../docs/11-testcontainers.md)) | `source ./06-testcontainers/env.sh` |
| [07-k8s](07-k8s) | local Kubernetes via `container k8s`, loading a local image | `./07-k8s/run.sh` |
| [08-machine](08-machine) | container machines: host user, home mount, cwd pass-through, SSH agent, persistence | `./08-machine/run.sh` |

## Suggested order

1. **01-hello** — if this works, your install is sound.
2. **02-node-web** — the mental model shift: the container has a real IP you can
   curl directly, *and* a published port.
3. **03-compose-web-db** — run all three `up-*.sh` scripts on the same file. The
   differences in their output are the whole argument of
   [docs/04-compose.md](../docs/04-compose.md).
4. **04-postgres-volume** — the storage trap you will otherwise hit at a bad moment.
5. **08-machine** — the part of the platform that isn't containers at all, and
   the one most people never find.

## Cleanup

Each script prints its own teardown commands. To reset everything the examples
created:

```bash
container rm -f node-web pg-demo acdemo-db acdemo-api acdemo-web 2>/dev/null
container volume delete pg-demo-data acdemo_pgdata 2>/dev/null
container image rm hello-apple:latest node-web:dev multiarch-demo:latest k8s-demo:local 2>/dev/null
container k8s delete --name k8s-dev 2>/dev/null
../scripts/cleanup.sh
```
