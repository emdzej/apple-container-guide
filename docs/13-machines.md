# 13 — Container machines

`container machine` is the most under-advertised thing the platform ships. It is
not a container feature — it gives you **persistent, general-purpose Linux VMs**
with your Mac's home directory mounted in, your own user, and your working
directory carried across. It is a Lima / Colima / Multipass / UTM replacement
that is already installed.

If you have ever run `colima start` just to get a Linux shell, this is that, with
no extra install.

## Machines vs containers

| | Container | Machine |
|---|---|---|
| Modelled on | one application process | a Linux environment |
| PID 1 | your process | the image's **init system** |
| Filesystem | discarded on delete | **persists across stop/start** |
| Runs as | `root` | **your host user**, same uid/gid |
| Your `$HOME` | not mounted | mounted at `/Users/<you>`, rw by default |
| Working directory | `/` or the image's | **your host cwd, carried through** |
| SSH agent | `--ssh` flag | **mounted automatically** |
| Default memory | 1 GiB | **half of host RAM** |
| System services | no init, so no | `systemctl` works on a systemd image |
| Lifetime | ephemeral | until you `delete` it |

The init system is the substantive difference. A container runs your process as
PID 1; a machine boots the image's init, which is why long-running services,
process supervisors and `systemctl start postgresql` work inside one and not in
a container.

## Quickstart

```bash
container machine create alpine:3.22 --name dev --cpus 4 --memory 8G
container machine run -n dev                 # interactive login shell
container machine list
container machine stop dev
container machine delete dev
```

Creating one took **about 3 seconds** on an M1 Pro with the image already local.
`m` is an alias for `machine`, so `container m ls` works.

### It is not ready when `create` returns

`machine create` exits, and `machine list` reports `running`, **several seconds
before `machine run` actually works.** Until then every command fails with a
message that names nothing useful:

```
Error: The operation couldn't be completed. Operation not supported by device
```

Measured at **~4 seconds** for alpine on an M1 Pro. Interactively you will never
notice; in a script it is a guaranteed flake. Wait for readiness rather than
trusting the exit code or the reported state:

```bash
wait_ready() {
  local m="$1" i
  for i in $(seq 1 60); do
    container machine run -n "$m" -- true >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
```

`cmwait <name>` in the shell helpers does this, and `cmnew` calls it for you.
The same applies after a `stop` — `run` auto-boots the machine, so the first
command after a stop can hit the same window.

## What you get inside

Verified from inside a freshly created alpine machine:

```console
$ container machine run -n dev -- id
uid=1010478632(mjaskols) gid=161333784(mjaskols) groups=161333784(mjaskols)
```

**Your host user, not root.** uid and gid match your macOS account exactly. Files
you create on the mounted home have the right owner on both sides, which is the
single biggest annoyance of doing this with containers.

```console
$ container machine run -n dev -- mount
/dev/vdb on / type ext4 (rw,relatime)
virtiofs on /Users/mjaskols type virtiofs (rw,relatime)
virtiofs on /sbin.machine type virtiofs (ro,relatime)
tmpfs on /var/host-services/ssh-auth.sock type tmpfs (rw,relatime)
none on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)
...
```

Four things worth pulling out of that:

- **`/Users/<you>` is your real Mac home**, read-write over virtiofs. Note the
  path: your macOS home is at `/Users/<you>`, while the guest's own `$HOME` is
  `/home/<you>`. They are different directories and both exist.
- **The SSH agent socket is mounted with no flag.** `SSH_AUTH_SOCK` is already
  set to `/var/host-services/ssh-auth.sock`, so `git clone git@github.com:…`
  works immediately using the keys in your Mac's agent. Containers need `--ssh`
  for this; machines don't.
- **`cgroup2` is mounted**, which is what makes systemd-based images usable.
- `/sbin.machine` is the platform's injected tooling, read-only.

**Your working directory comes with you.** Running a command from a host
directory inside your home puts you in the same place inside the machine:

```console
$ cd ~/Projects/my/apple-container-guide
$ container machine run -n dev -- pwd
/Users/mjaskols/Projects/my/apple-container-guide
```

So `container machine run -n dev -- make test` operates on the tree you are
standing in. That is the whole ergonomic argument for machines.

## Persistence

The filesystem survives a stop. This is the point.

```console
$ container machine run -n dev -- sh /Users/me/write-something.sh
$ container machine stop dev
$ container machine run -n dev -- cat /home/me/probe.txt   # boots it first
persisted-payload
```

`run` boots a stopped machine automatically, so you rarely type a start command.
Deleting is always explicit — nothing reaps machines for you.

Disk is a sparse image and shows in `container machine list`. A bare alpine
machine starts around 75 MB.

## Sizing

```bash
container machine create ubuntu:24.04 --name dev --cpus 8 --memory 16G
container machine create alpine:3.22 --name tiny --no-boot          # create, don't start
container machine create alpine:3.22 --name dev --set-default
```

**Memory defaults to half your system RAM** — much more generous than the 1 GiB a
container gets, and appropriate, since a machine is meant to host several things
at once.

Change settings afterwards; they apply **on the next boot**:

```bash
container machine set -n dev cpus=8 memory=16G home-mount=ro
container machine stop dev
container machine run -n dev -- nproc
```

| Setting | Values | Notes |
|---|---|---|
| `cpus` | number | |
| `memory` | `2G`, `8G`, … | default: half of system memory |
| `home-mount` | `rw` (default), `ro`, `none` | `ro` is a good habit for machines running untrusted code |
| `virtualization` | `true` / `false` | nested virtualisation; needs **Apple silicon M3+**, macOS 15+, and a guest kernel with `CONFIG_KVM=y` |
| `kernel` | path | custom kernel binary; empty value resets to default |

## Running commands: a real quirk

**`sh -c` with a multi-word string does not work.** The command string is
word-split before it reaches the guest, so quoting is lost:

```console
$ container machine run -n dev -- sh -c 'id'          # single token: fine
uid=1010478632(mjaskols) ...

$ container machine run -n dev -- sh -c 'echo hi'     # multi-word: broken
                                                      # (prints an empty line)
```

Simple commands with arguments are fine — it is specifically the shell `-c`
string that breaks:

```bash
container machine run -n dev -- cat /proc/cpuinfo     # fine
container machine run -n dev -- ls -la /Users         # fine
container machine run -n dev -- make -C /Users/me/proj test   # fine
```

Two workarounds, both verified:

**1. Pipe the script in on stdin** (use `-i`):

```console
$ echo 'echo "hello"; id -un; echo "HOME=$HOME"' | container machine run -n dev -i -- sh
hello
mjaskols
HOME=/home/mjaskols
```

**2. Put the script on the mounted home and run it by path:**

```bash
cat > ~/probe.sh <<'SCRIPT'
#!/bin/sh
echo "running as $(id -un) in $(pwd)"
SCRIPT
container machine run -n dev -- sh "/Users/$(whoami)/probe.sh"
```

Option 1 is better for one-offs, option 2 for anything you will run twice.

## Networking

Each machine gets an IP on the same `vmnet` network your containers use, so it is
reachable from the host directly:

```console
$ container machine list
NAME  CREATED              IP            CPUS  MEMORY  DISK  STATE    DEFAULT
dev   2026-09-24 10:41:06  192.168.64.5  4     8G      75M   running  *
```

**The IP changes across restarts.** It was `192.168.64.3` before a stop and
`192.168.64.5` after. Never hardcode it; read it from `list` or `inspect`.

Machines live under a `.machine` DNS domain. Inside one:

```console
$ container machine run -n dev -- cat /etc/resolv.conf
nameserver 192.168.64.1
domain machine
search machine
```

So machine-to-machine and machine-to-container name resolution works out of the
box. Resolving `dev.machine` **from your Mac** needs the host resolver, the same
two-step as for containers ([06 — Networking](06-networking.md)):

```bash
sudo container system dns create machine
ping dev.machine
```

Without that, `dev.machine` does not resolve on the host — use the IP.

## Inspecting

```bash
container machine list
container machine list --format json
container machine inspect dev
container machine logs dev
container machine logs --boot dev      # kernel/init log, when a machine won't come up
container machine set-default dev
```

`inspect` is the useful one for scripting:

```json
{
  "id" : "dev",
  "containerId" : "dev-5d3153",
  "cpus" : 2,
  "memory" : 2147483648,
  "diskSize" : 78675968,
  "homeMount" : "rw",
  "ipAddress" : "192.168.64.5",
  "status" : "running",
  "image" : { "reference" : "docker.io/library/alpine:3.22" },
  "userSetup" : { "uid" : 1010478632, "gid" : 161333784, "username" : "mjaskols" }
}
```

```bash
container machine inspect dev | jq -r '.[0].ipAddress'
```

## What it's actually good for

- **A Linux shell that isn't a container.** Test a distro package, reproduce a
  Linux-only bug, run `strace`, poke at `/proc`, use a tool that has no macOS
  build — without the container mental model getting in the way.
- **Cross-compiling and native builds.** Your source is already mounted at the
  same path, your cwd carries over, and the build artefacts land in your home
  with your own ownership.
- **Linux-only tooling.** `perf`, `bpftrace`, `systemd-analyze`, package-manager
  work, anything that needs an init system.
- **A disposable server.** Boot a systemd image, `systemctl` a real service, and
  delete the whole thing when you're done.
- **Keeping your Mac clean.** A machine with `home-mount=ro` (or `none`) is a
  reasonable place to run a build script you don't fully trust.

Where a container is still the right answer: anything you want to be ephemeral,
reproducible from a Dockerfile, or published as an image.

## Compared to the alternatives

| | `container machine` | Lima | Colima | Multipass | UTM |
|---|---|---|---|---|---|
| Extra install | **none** | brew | brew | brew | app |
| Host home mounted | yes, rw by default | configurable | yes | configurable | manual |
| Runs as your host user | **yes** | yes | yes | no (`ubuntu`) | no |
| Host cwd carried through | **yes** | no | no | no | no |
| SSH agent forwarded | **automatic** | configurable | configurable | manual | manual |
| Image source | **any OCI image** | its own YAML templates | Ubuntu/Alpine images | Ubuntu images | ISO |
| Boots an init system | yes | yes | yes | yes | yes |
| Nested virtualisation | M3+ | limited | limited | no | limited |

The two distinctive columns are **any OCI image** as the machine base — so
`container machine create ubuntu:24.04` or your own internal image just works —
and the host cwd/user/agent integration, which none of the others do all three
of.

## Shell helpers

With [`shell/apple-container.sh`](../shell/apple-container.sh) sourced:

```bash
cmls                  # list machines
cmnew dev             # create with sensible defaults (4 cpus, 8G)
cminto dev            # interactive shell
cmx dev <cmd...>      # run a command
cmsh dev              # pipe a heredoc script in (works around the sh -c quirk)
cmip dev              # current IP
cmstop dev / cmrm dev
```

## Example

[`examples/08-machine/run.sh`](../examples/08-machine/run.sh) creates a machine,
demonstrates the host-user mapping, the home mount, cwd pass-through, the SSH
agent, persistence across a stop, and both `sh -c` workarounds — then deletes it.

## Caveats

- **Experimental-adjacent.** Machines are newer than the container path and the
  `sh -c` quirk above suggests the command plumbing is still settling.
- **The IP is not stable across restarts.**
- **`.machine` names don't resolve from the host** without
  `sudo container system dns create machine`.
- **Nothing cleans up after you.** A forgotten machine holds its disk image and,
  while running, half your RAM by default.
- **`set` needs a restart** to take effect; the command doesn't tell you that.
- **`create` returns before the machine is usable** — see above. `list` saying
  `running` is not a readiness signal.
- **Alpine gives you busybox init**, not systemd. If you want `systemctl`, start
  from a systemd-capable image such as `ubuntu:24.04` or a distro image built for
  it.

## See also

- [09 — Ecosystem](09-ecosystem.md) — the rest of the tooling
- [12 — Alternatives](12-alternatives.md) — Lima, Colima and the other runtimes
- [06 — Networking](06-networking.md) — the DNS two-step in full
