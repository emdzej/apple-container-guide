#!/usr/bin/env bash
# The smallest useful end-to-end check: build an image, run it, clean up.
# If this works, your install is sound.
set -euo pipefail
cd "$(dirname "$0")"

container system status >/dev/null 2>&1 || container system start

echo "==> build"
# --arch defaults to arm64. Rosetta handles amd64 when you ask for it.
container build --tag hello-apple:latest --file Dockerfile .

echo
echo "==> run"
container run --rm hello-apple:latest

echo
echo "==> what just happened"
echo "The build ran inside a BuildKit builder VM (container builder status)."
echo "The run booted a second, separate VM for this one container, then tore it down."
echo
echo "==> cleanup"
container image rm hello-apple:latest
