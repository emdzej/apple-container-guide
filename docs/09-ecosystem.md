# 09 — Ecosystem

The four tools in this guide's title are the core. This page is everything else
worth knowing about — what works as-is, what needs a nudge, and what to reach for
when Apple container isn't the right answer.

## The core four

| Tool | Role |
|---|---|
| [apple/container](https://github.com/apple/container) | the runtime |
| [socktainer](https://github.com/socktainer/socktainer) | Docker API compatibility — the keystone for everything below |
| [container-compose](https://github.com/Mcrich23/Container-Compose) | Apple-native compose front end |
| [davit](https://github.com/wouterdebie/davit) | native GUI + a genuinely useful headless CLI |

**Install socktainer even if you never type `docker`.** Most of the tooling in
this page reaches the runtime through it.

## Works as-is through socktainer

Anything that speaks the Docker API and honours `DOCKER_HOST` or Docker contexts:

| Tool | What it's for | Notes |
|---|---|---|
| `docker` CLI | the commands you already know | `brew install docker` — CLI only, no Desktop |
| `docker compose` | stacks | the recommended compose path ([04](04-compose.md)) |
| [lazydocker](https://github.com/jesseduffield/lazydocker) | TUI: containers, logs, stats, exec | |
| [ctop](https://github.com/bcicen/ctop) | top-like container overview | |
| [dive](https://github.com/wagoodman/dive) | layer-by-layer image size explorer | makes image bloat obvious |
| [Testcontainers](https://testcontainers.com/) | integration tests | needs `TESTCONTAINERS_RYUK_DISABLED=true` — [full setup](11-testcontainers.md) |
| [Podman Desktop](https://podman-desktop.io/) | GUI | via the [apple-container extension](https://github.com/podman-desktop/extension-apple-container) |
| JetBrains / VS Code Docker plugins | IDE integration | point at `unix://$HOME/.socktainer/container.sock` |

## Works, but goes around the Docker API

These talk to registries or build images without needing a daemon at all, which
makes them *more* reliable here than daemon-dependent tools:

| Tool | Why you want it |
|---|---|
| [skopeo](https://github.com/containers/skopeo) | Copy images between registries, daemons and archive formats without pulling. **The fix for the `docker save`/`container image load` format mismatch:** `skopeo copy docker-daemon:img:tag oci-archive:/tmp/img.tar` |
| [crane](https://github.com/google/go-containerregistry) | Registry surgery: copy, retag, inspect, delete, mutate — all server-side, no local pull. `crane cp`, `crane digest`, `crane config`. |
| [regclient](https://github.com/regclient/regclient) (`regctl`) | Same niche as crane, better multi-arch index handling. Useful for assembling arm64+amd64 manifests by hand. |
| [ORAS](https://oras.land/) | Push/pull arbitrary artifacts (Helm charts, SBOMs, WASM) to OCI registries. |
| [syft](https://github.com/anchore/syft) | SBOM generation. Reads images directly from a registry or archive. |
| [grype](https://github.com/anchore/grype) / [trivy](https://github.com/aquasecurity/trivy) | Vulnerability scanning. Both can scan a registry reference with no daemon. |
| [hadolint](https://github.com/hadolint/hadolint) | Dockerfile linting. Static, no runtime involved. |
| [ko](https://ko.build/) | Build Go container images with no Dockerfile and no daemon. Extremely fast on this platform because it skips the builder VM entirely. |
| [Jib](https://github.com/GoogleContainerTools/jib) | Same idea for Java/Maven/Gradle. Daemonless by default. |
| [pack](https://buildpacks.io/) (Cloud Native Buildpacks) | Needs a Docker daemon → works via socktainer, but is slow here; `ko`/`jib` are better if they fit. |

`skopeo`, `crane` and `ko` are the three I'd add first. They sidestep the
platform's rough edges rather than working around them.

## Local Kubernetes

| Option | How |
|---|---|
| **`container k8s`** | Built in (experimental, plugin). Fastest path. Needs the CLI and daemon to share an install root — see [example 07](../examples/07-k8s/run.sh). |
| [kind](https://kind.sigs.k8s.io/) | Needs a Docker daemon → works via socktainer. Privileged-ish node containers make this hit-and-miss; try it before relying on it. |
| [k3d](https://k3d.io/) | Same shape as kind, lighter nodes. |
| [minikube](https://minikube.sigs.k8s.io/) | `--driver=docker` via socktainer. |
| [Colima](https://github.com/abiosoft/colima) | `colima start --kubernetes` — a separate VM, but reliable. The pragmatic fallback. |

If Kubernetes is central to your work, Colima or Rancher Desktop is still the
lower-friction choice. `container k8s` is excellent for "spin up a cluster, load
an image, test a manifest, delete it".

## Dev environments

| Tool | Status here |
|---|---|
| [devcontainer CLI](https://github.com/devcontainers/cli) | Honours `DOCKER_HOST`. Straightforward configs work. Features needing `--privileged` or docker-in-docker are the failure cases. |
| [DevPod](https://devpod.sh/) | Docker provider via socktainer. |
| [Tilt](https://tilt.dev/) / [Skaffold](https://skaffold.dev/) | Both work against socktainer, and against `container k8s`. |
| [mirrord](https://mirrord.dev/) / [Telepresence](https://www.telepresence.io/) | Cluster-side; unaffected by your local runtime. |
| [act](https://github.com/nektos/act) | Run GitHub Actions locally. Needs `--container-daemon-socket unix://$HOME/.socktainer/container.sock`. Privileged steps are the weak point. |

## `container machine` — the one people miss

Not a container tool. `container machine` gives you **persistent, general-purpose
Linux VMs** with your home directory mounted and a stable `.machine` DNS name.
It's a Lima/Colima/Multipass replacement that's already installed.

```bash
container machine create alpine:3.22 --name dev
container machine run -n dev                     # interactive shell
container machine run -n dev -- cat /proc/cpuinfo
container machine set -n dev cpus=4 memory=8G home-mount=ro
container machine stop dev
container machine delete dev
container machine list
container machine set-default dev
```

Defaults are 4 CPUs / 16 GiB with `home-mount=rw`. Unlike a container, the
filesystem survives stop/start. Good for cross-compiling, running Linux-only
tooling, or anything where you want a machine rather than a process.

## Fallback runtimes — keep one

You will hit something that needs `--privileged` with real device access,
`--network host`, a GPU, or Docker-in-Docker. Keep an escape hatch installed:

| Runtime | When it's the better answer |
|---|---|
| [Colima](https://github.com/abiosoft/colima) | Best fallback. CLI-only, lightweight, `colima start --kubernetes`, and it's the closest to plain Docker semantics. `brew install colima` |
| [Lima](https://lima-vm.org/) | Colima's substrate. Reach for it if you want to hand-write the VM config. |
| [OrbStack](https://orbstack.dev/) | Fastest and most polished commercial option, with the same per-container-lightweight feel. Paid for commercial use. |
| [Rancher Desktop](https://rancherdesktop.io/) | Free, Kubernetes-first, ships `nerdctl` and `docker`. |
| [Podman](https://podman.io/) | Rootless, daemonless, good systemd story. `podman machine`. |
| [Finch](https://github.com/runfinch/finch) | AWS's Lima+nerdctl bundle. |
| Docker Desktop | The thing you're leaving. Licensing applies above a company-size threshold; check before you keep it "just in case" at work. |

Switching is one command with the helpers loaded: `duse colima`, `duse desktop`,
`duse apple`. Or `./scripts/switch-runtime.sh <target>`.

## Things that don't work, and why

| Tool / pattern | Problem |
|---|---|
| Docker-in-Docker (`docker:dind`) | Needs real `--privileged`. socktainer's `--cap-add=ALL` covers some uses, not nested daemons reliably. |
| `docker buildx` with the `docker-container` driver | Needs privileged + a builder container. Reported to work via socktainer's cap-add approximation; test it. The `container build --arch a --arch b` route is simpler. |
| Watchtower and similar auto-updaters | Rely on restart semantics that only survive while socktainer runs. |
| cAdvisor / node-exporter style agents | Want host cgroup and `/proc` access across all containers. There's no shared kernel to observe — use `container stats` / `docker stats`. |
| Anything asserting on `/.dockerenv` | Not created here. Docker's daemon fabricates it. Detect containers another way. |
| GPU workloads (CUDA, ROCm, Metal passthrough) | No device passthrough. Run these natively on macOS or remotely. |
| `--network host` service meshes, VPN sidecars | No host netns. |

## Suggested starting set

Beyond the core four:

```bash
brew install docker jq skopeo dive lazydocker
brew install crane          # or: brew install regclient
brew install hadolint       # Dockerfile linting
brew install colima         # the escape hatch
```

And optionally, if the languages match: `ko` (Go), `trivy`/`grype` (scanning),
`kubectl` + `k9s` (if you use `container k8s`).

## Next

- [10 — Troubleshooting](10-troubleshooting.md)
