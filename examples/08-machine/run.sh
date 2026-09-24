#!/usr/bin/env bash
# Container machines: persistent general-purpose Linux VMs.
#
# Demonstrates the five things that make a machine different from a container,
# then deletes it. Nothing is left behind.
#
#   ./run.sh              # alpine (busybox init, fast)
#   IMAGE=ubuntu:24.04 ./run.sh
set -euo pipefail
NAME=${NAME:-guide-demo}
IMAGE=${IMAGE:-docker.io/library/alpine:3.22}
ME="$(whoami)"

container system status >/dev/null 2>&1 || container system start
container machine delete "$NAME" 2>/dev/null || true

# `machine create` returns, and `machine list` reports "running", several seconds
# before `machine run` actually works - until then it fails with
#   Error: The operation couldn't be completed. Operation not supported by device
# Measured at ~4s for alpine on an M1 Pro. Any script must wait for readiness
# rather than trusting the create call or the reported state.
wait_ready() {
  local m="$1"
  # shellcheck disable=SC2034  # loop counter, body does not reference it
  for _ in $(seq 1 60); do
    container machine run -n "$m" -- true >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "machine $m never became ready; try: container machine logs --boot $m" >&2
  return 1
}

echo "==> create ($IMAGE)"
# Memory would otherwise default to HALF your system RAM, which is a lot to
# reserve for a demo. cpus/memory can be changed later with `machine set`, but
# only take effect on the next boot.
time container machine create "$IMAGE" --name "$NAME" --cpus 2 --memory 2G

echo "==> waiting for it to accept commands (create returns before this)"
time wait_ready "$NAME"

echo
echo "==> 1. you are your host user, not root"
# Containers run as root. A machine maps your macOS uid/gid, so files you create
# on the mounted home have the right owner on both sides.
container machine run -n "$NAME" -- id

echo
echo "==> 2. your Mac home is mounted read-write"
# Note the two different paths: your macOS home is at /Users/<you>, the guest's
# own $HOME is /home/<you>. Both exist.
container machine run -n "$NAME" -- ls -d "/Users/$ME"
container machine run -n "$NAME" -- mount | grep -E 'virtiofs|cgroup2'

echo
echo "==> 3. your working directory comes with you"
# This is the ergonomic argument for machines: `machine run -- make test` acts
# on the tree you are standing in.
( cd "$(dirname "$0")" && container machine run -n "$NAME" -- pwd )

echo
echo "==> 4. the SSH agent is forwarded with no flag"
# Containers need --ssh for this. Machines get it automatically, so
# `git clone git@github.com:...` works with the keys in your Mac's agent.
container machine run -n "$NAME" -i -- sh <<'GUEST'
echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-unset}"
GUEST

echo
echo "==> 5. the filesystem persists across a stop"
# THE difference from a container. Write, stop, boot, read.
container machine run -n "$NAME" -i -- sh <<'GUEST'
echo "written-before-the-stop" > "$HOME/probe.txt"
GUEST
container machine stop "$NAME"
container machine list
echo "--- 'machine run' boots a stopped machine automatically ---"
wait_ready "$NAME"
container machine run -n "$NAME" -- cat "/home/$ME/probe.txt"

echo
echo "==> the sh -c quirk, and the two workarounds"
# A multi-word string passed to `sh -c` is word-split before it reaches the
# guest, so quoting is lost and the command silently does nothing.
printf '  broken   (sh -c multi-word): '
container machine run -n "$NAME" -- sh -c 'echo this-never-prints' 2>/dev/null || true
echo "  ^ empty, as expected"
printf '  works    (single command):   '
container machine run -n "$NAME" -- hostname
printf '  works    (stdin heredoc):    '
container machine run -n "$NAME" -i -- sh <<'GUEST'
echo "one; two; three all run here"
GUEST

echo
echo "==> networking"
container machine inspect "$NAME" | grep -E '"ipAddress"|"status"|"homeMount"'
echo "  the IP changes across restarts - never hardcode it"
container machine run -n "$NAME" -- cat /etc/resolv.conf
echo "  'domain machine' means machine-to-machine names resolve inside."
echo "  To resolve $NAME.machine from your Mac:  sudo container system dns create machine"

echo
echo "==> cleanup"
container machine stop "$NAME" 2>/dev/null || true
container machine delete "$NAME"
container machine list

cat <<'NOTE'

When to reach for a machine instead of a container:
  - you want a Linux shell, not a packaged application
  - you need an init system (systemctl, a process supervisor, a real service)
  - you want the filesystem to survive
  - you want to build against source already on your Mac, as yourself

Alpine gives you busybox init. For systemctl, start from ubuntu:24.04 or another
systemd-capable image:  IMAGE=ubuntu:24.04 ./run.sh

Full detail: ../../docs/13-machines.md
NOTE
