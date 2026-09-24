#!/usr/bin/env bash
# One image, both architectures. arm64 runs natively; amd64 runs under Rosetta.
set -euo pipefail
cd "$(dirname "$0")"
TAG=${TAG:-multiarch-demo:latest}

container system status >/dev/null 2>&1 || container system start

# Repeating --arch produces a multi-platform image in one pass. The builder VM
# uses Rosetta for the amd64 leg, which is why `container system property list`
# shows build.rosetta = true by default.
echo "==> build arm64 + amd64"
container build --arch arm64 --arch amd64 --tag "$TAG" --file Dockerfile .

echo
echo "==> run the native variant"
container run --rm --arch arm64 "$TAG"

echo
echo "==> run the x86-64 variant under Rosetta"
container run --rm --arch amd64 "$TAG" || {
  echo "amd64 run failed - Rosetta may not be installed:"
  echo "  softwareupdate --install-rosetta --agree-to-license"
}

echo
echo "==> what the store holds"
container image inspect "$TAG" | grep -E 'architecture|os' | sort -u

cat <<'NOTE'

Caveats worth knowing before you rely on this:
  - amd64 under Rosetta is correct but slower, and some JITs and AVX-using
    binaries still fail. Test, do not assume.
  - `container image pull` downloads only your local platform's blobs, but keeps
    the full multi-platform index. That is why `docker save` through socktainer
    fails with "ContentStore missing blob data" for registry-pulled images.
  - Push is platform-agnostic: container image push <tag> ships both variants.
NOTE
