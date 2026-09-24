# 12 — Alternatives compared

Apple container is one of seven credible ways to run Linux containers on a Mac.
This page is the comparison, including the part that is often the actual reason
for the migration: **who owes money for commercial use.**

Licence terms change. Everything below has a source; check it yourself before
making a purchasing or compliance decision, and treat this as a starting point
rather than legal advice.

## Licensing and commercial use

| | Licence | Free for commercial use? | Notes |
|---|---|---|---|
| **apple/container** | Apache-2.0 | **Yes, unconditionally** | No subscription, no seat count, no revenue threshold. |
| **socktainer** | Apache-2.0 | Yes | |
| **container-compose** | Apache-2.0 | Yes | Its README says MIT; the `LICENSE` file is Apache-2.0. The file wins. |
| **Davit** | MIT | Yes | |
| **Colima** | MIT | Yes | |
| **Lima** | Apache-2.0 | Yes | |
| **Podman** / **Podman Desktop** | Apache-2.0 | Yes | Red Hat sells support, not the software. |
| **Rancher Desktop** | Apache-2.0 | Yes | SUSE, same model. |
| **Finch** | Apache-2.0 | Yes | AWS. |
| **Docker Desktop** | proprietary | **No, above a threshold** | A paid subscription is required for commercial use at companies with **≥250 employees or ≥$10M annual revenue** — either threshold alone triggers it. Government entities need a subscription regardless of size. Plans run roughly $9 / $15 / $24 per user per month. |
| **OrbStack** | proprietary | **No** | Free tier is *personal, non-commercial use* only. Business and commercial use needs Pro, about $8/month per user. |

Two clarifications that come up constantly:

- **Docker Engine is not Docker Desktop.** The engine and the Moby project are
  Apache-2.0 with no restriction. The subscription covers Docker Desktop
  specifically — the GUI, its helper VM, the bundled Compose binary and the
  settings panel. Running the engine on a Linux box, or in CI, has never needed a
  licence.
- **The `docker` CLI is free.** `brew install docker` installs only the client.
  That's what talks to socktainer, and it's what this guide assumes you keep.

So if your migration is licence-driven, the shortlist is Apple container,
Colima, Podman, Rancher Desktop or Finch. OrbStack solves the technical problem
elegantly but not the commercial one.

Sources: [Docker Subscription Service Agreement](https://www.docker.com/legal/docker-subscription-service-agreement/) ·
[Docker plans FAQ](https://www.docker.com/pricing/faq/) ·
[OrbStack pricing](https://orbstack.dev/pricing)

## Architecture

This is what actually drives the behavioural differences.

| | Isolation model | Idle cost | Cold start |
|---|---|---|---|
| **Apple container** | **one lightweight VM per container**, own kernel each | nothing resident once stopped | ~1 s — a kernel boots |
| Docker Desktop | one shared Linux VM, namespaces inside | one VM always resident (~2 GB+) | ~100 ms |
| OrbStack | one tuned shared VM | low, aggressively optimised | ~100 ms, fastest of the shared-VM options |
| Colima / Lima | one shared Lima VM | one VM while running | ~100 ms |
| Podman | one shared Lima VM (`podman machine`), rootless, **daemonless** | VM while running; no daemon process | ~100 ms |
| Rancher Desktop | one shared VM, containerd or dockerd | VM while running | ~100 ms |
| Finch | one shared Lima VM + nerdctl | VM while running | ~100 ms |

Apple container is the only one that isn't a shared-VM design, and that is the
whole trade:

**What the per-container VM buys you.** A separate kernel per container, so a
container escape is a VM escape. Nothing resident when you're not using it —
`container system stop` really releases everything, where a shared VM sits on
its RAM whether you have containers running or not. And each container gets a
real routable IP you can reach from the host with no `--publish` at all.

**What it costs.** A kernel boot per container, so cold start is roughly 10×
slower and a twelve-service Compose stack is noticeably slower to come up.
Memory is a **hard reservation per container** rather than an elastic shared
pool — six services at 1 GiB each reserve 6 GiB, where the same stack on Docker
Desktop shares one VM's memory. And several Docker features become structurally
impossible rather than merely unimplemented: `--network host`, `--privileged`,
`--pid`/`--ipc` sharing, `pause`/`unpause`.

That last point is worth sitting with. Those aren't gaps someone will close in a
release — there is no shared kernel for them to refer to.

## Capability matrix

| | Apple container | Docker Desktop | Colima | Podman | Rancher Desktop | OrbStack |
|---|---|---|---|---|---|---|
| Intel Mac support | **no** | yes | yes | yes | yes | yes |
| Minimum macOS | **26** | 13+ | 13+ | 13+ | 13+ | 13+ |
| `docker` CLI works | via socktainer | native | native | via alias/socket | native | native |
| `docker compose` | via socktainer | native | native | `podman compose` | native | native |
| `--network host` | **no** | yes | yes | yes | yes | yes |
| `--privileged` | **no** (approximated) | yes | yes | yes | yes | yes |
| `pause` / `unpause` | **no** | yes | yes | yes | yes | yes |
| Docker-in-Docker | unreliable | yes | yes | yes | yes | yes |
| Rootless | n/a (VM per container) | no | no | **yes** | no | no |
| Daemonless | apiserver, but nothing when stopped | no | no | **yes** | no | no |
| Built-in Kubernetes | `container k8s` (experimental) | yes | `--kubernetes` | via kind/k3d | **yes, first-class** | yes |
| x86-64 emulation | Rosetta | Rosetta / QEMU | Rosetta / QEMU | Rosetta / QEMU | QEMU | Rosetta |
| Native GUI | Davit (3rd party) | yes | no | Podman Desktop | yes | yes |
| GPU passthrough | no | no | no | no | no | no |

Nobody does GPU passthrough on macOS. If that's what you need, the answer is a
Linux box.

## Podman specifically

Podman deserves more than a table row, because it's the closest thing to a
philosophical sibling and people assume the two are interchangeable.

**Where they agree:** both reject the always-on privileged daemon. Both are
Apache-2.0 with no commercial restriction. Both have an OCI-standard,
Docker-compatible image story.

**Where they differ, and it matters:**

- **Isolation.** Podman is rootless *namespaces* inside one shared Linux VM.
  Apple container is a *separate kernel* per container. Podman's rootless model
  is a genuinely strong answer to "the daemon runs as root"; Apple container
  answers a different question — "containers share a kernel" — and the answers
  aren't substitutes.
- **What runs when you're idle.** Podman has no daemon, but `podman machine` is
  a VM that stays up. Apple container's services can be stopped outright and
  reclaim everything. Neither is free; Apple's zero point is lower.
- **Compose.** `podman compose` shells out to Docker Compose or `podman-compose`
  and is well-trodden. Apple container's three front ends are all young and
  differ from each other in ways that matter ([04](04-compose.md)).
- **systemd.** Podman generates systemd units (Quadlet) and runs systemd inside
  containers. If your production target is RHEL, that's a real workflow
  advantage with no Apple-container equivalent.
- **Maturity.** Podman is years old with a large install base. Apple container
  hit 1.0 in 2026 and the surrounding ecosystem moves weekly.
- **Portability.** Podman runs on Linux, macOS and Windows. Apple container runs
  on Apple silicon Macs on macOS 26+, and that will not change.

**Pick Podman over Apple container if:** you need rootless specifically, you
deploy to RHEL/systemd, you have Intel Macs or Linux/Windows developers to keep
in step, or you want a mature Compose path today.

**Pick Apple container over Podman if:** you want per-container kernel
isolation, you want genuinely nothing resident when idle, your fleet is
all-Apple-silicon on macOS 26+, and your stacks don't need `--privileged` or
`--network host`.

They also coexist fine. Podman Desktop has an
[apple-container extension](https://github.com/podman-desktop/extension-apple-container)
that drives socktainer, so one window shows both.

## Decision guide

| If this is your constraint | Pick |
|---|---|
| Docker Desktop licence cost, all-Apple-silicon fleet | **Apple container** |
| Docker Desktop licence cost, mixed or Intel fleet | **Colima** or **Rancher Desktop** |
| Strongest isolation per container | **Apple container** |
| Rootless is a hard requirement | **Podman** |
| Kubernetes is central to your day | **Rancher Desktop**, or Colima `--kubernetes` |
| Deploying to RHEL / systemd | **Podman** |
| Fastest and most polished, budget for it | **OrbStack** |
| You need `--privileged`, `--network host`, or DinD | anything **except** Apple container |
| Intel Mac | anything **except** Apple container |
| AWS shop wanting an AWS-supported tool | **Finch** |
| Minimum change from what you have today | stay on **Docker Desktop** if you're under the threshold |

## Keep a fallback

Whatever you choose, keep a second runtime installed. You will hit something
that needs a feature the per-container-VM model can't provide, and the cost of
being stuck is much higher than the cost of a second install.

```bash
brew install colima          # MIT, no commercial restriction, closest to plain Docker
```

Switching is one command:

```bash
./scripts/switch-runtime.sh apple
./scripts/switch-runtime.sh colima
./scripts/switch-runtime.sh desktop
```

Or `duse apple` / `duse colima` / `duse desktop` with the shell helpers loaded.
Only the active Docker context decides which runtime `docker` talks to, so this
is genuinely a per-command choice rather than a commitment.

## See also

- [09 — Ecosystem](09-ecosystem.md) — the tools that work *with* whichever
  runtime you pick
- [01 — Install](01-install.md#coexisting-with-docker-desktop) — running two
  runtimes side by side
