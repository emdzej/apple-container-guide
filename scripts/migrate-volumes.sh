#!/usr/bin/env bash
# migrate-volumes.sh - copy the contents of Docker Desktop named volumes into
# Apple container named volumes.
#
#   ./scripts/migrate-volumes.sh --list                  # what is there, and how big
#   ./scripts/migrate-volumes.sh myapp_pgdata            # one volume
#   ./scripts/migrate-volumes.sh --all                   # every non-anonymous volume
#   ./scripts/migrate-volumes.sh pgdata --rename newname # copy under a different name
#   ./scripts/migrate-volumes.sh pgdata --size 20g       # size the destination volume
#   ./scripts/migrate-volumes.sh pgdata --keep-tar       # leave the intermediate tar on disk
#
# How: tar the source volume out through a scratch bind mount on your Mac, then
# untar it into the destination volume. Slower than a block copy, but it is the
# only transport both runtimes agree on, and it survives the ext4-vs-overlay
# difference between them.
#
# Stop the containers that use these volumes first. Copying a live database
# directory gives you a torn copy.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

HELPER_IMAGE="${HELPER_IMAGE:-docker.io/library/alpine:3.22}"
MODE=""; RENAME=""; SIZE=""; KEEP_TAR=0; VOLS=()
while (( $# )); do
  case "$1" in
    --list)      MODE=list ;;
    --all)       MODE=all ;;
    --rename)    RENAME="${2:?--rename needs a name}"; shift ;;
    --size)      SIZE="${2:?--size needs a value, e.g. 20g}"; shift ;;
    --keep-tar)  KEEP_TAR=1 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    -*)          die "unknown flag: $1" ;;
    *)           VOLS+=("$1"); MODE="${MODE:-some}" ;;
  esac
  shift
done
[[ -n "$MODE" ]] || { sed -n '2,20p' "$0"; exit 1; }
[[ -n "$RENAME" && ${#VOLS[@]} -gt 1 ]] && die "--rename only makes sense with a single volume"

have docker || die "docker CLI not installed"
require_container_cli
SRC_CTX="$(docker_desktop_context)"
[[ -n "$SRC_CTX" ]] || die "no Docker Desktop context found"
docker --context "$SRC_CTX" info >/dev/null 2>&1 || die "Docker Desktop is not running (context: $SRC_CTX)"

if [[ "$MODE" == "list" ]]; then
  head1 "Docker Desktop volumes"
  printf '       %-40s %s\n' "NAME" "APPARENT SIZE"
  while read -r v; do
    [[ -z "$v" ]] && continue
    sz="$(docker --context "$SRC_CTX" run --rm -v "$v:/v:ro" "$HELPER_IMAGE" du -sh /v 2>/dev/null | awk '{print $1}')"
    printf '       %-40s %s\n' "$v" "${sz:-?}"
  done < <(docker --context "$SRC_CTX" volume ls -q)
  head1 "Apple container volumes"
  ensure_container_running; container volume ls
  exit 0
fi

ensure_container_running
[[ "$MODE" == "all" ]] && mapfile -t VOLS < <(docker --context "$SRC_CTX" volume ls -q | grep -Ev '^[0-9a-f]{64}$')
(( ${#VOLS[@]} )) || die "nothing to migrate"

XFER="${XFER_DIR:-$HOME/.cache/apple-container-migrate}"
mkdir -p "$XFER"
OK=(); BAD=()

for vol in "${VOLS[@]}"; do
  dest="${RENAME:-$vol}"
  head1 "$vol -> $dest"

  docker --context "$SRC_CTX" volume inspect "$vol" >/dev/null 2>&1 \
    || { fail "source volume does not exist"; BAD+=("$vol"); continue; }

  if container volume inspect "$dest" >/dev/null 2>&1; then
    warn "destination volume '$dest' already exists"
    confirm "Overwrite its contents?" || { note "skipped"; continue; }
  else
    if [[ -n "$SIZE" ]]; then
      run "creating volume $dest ($SIZE)" container volume create -s "$SIZE" "$dest" || { BAD+=("$vol"); continue; }
    else
      # Volume images are sparse: the default 512 GiB ceiling costs nothing up front.
      run "creating volume $dest" container volume create "$dest" || { BAD+=("$vol"); continue; }
    fi
  fi

  tar_path="$XFER/$vol.tar"
  info "exporting from Docker Desktop"
  # -C /src . keeps paths relative so dotfiles at the root come across too.
  if ! docker --context "$SRC_CTX" run --rm \
        -v "$vol:/src:ro" -v "$XFER:/xfer" "$HELPER_IMAGE" \
        tar -cf "/xfer/$vol.tar" -C /src . ; then
    fail "export failed"; BAD+=("$vol"); continue
  fi
  note "$(du -h "$tar_path" | awk '{print $1}') written to $tar_path"

  info "importing into Apple container"
  # ext4 volumes always carry a /lost+found. Postgres initdb refuses a non-empty
  # data dir, so clear the destination but put lost+found back where it belongs.
  if ! container run --rm \
        -v "$dest:/dst" -v "$XFER:/xfer:ro" "$HELPER_IMAGE" \
        sh -c 'set -e; find /dst -mindepth 1 -maxdepth 1 ! -name "lost+found" -exec rm -rf {} +; tar -xf "/xfer/'"$vol"'.tar" -C /dst'; then
    fail "import failed"; BAD+=("$vol"); continue
  fi

  src_count="$(docker --context "$SRC_CTX" run --rm -v "$vol:/v:ro" "$HELPER_IMAGE" sh -c 'find /v -type f | wc -l' 2>/dev/null | tr -d ' ')"
  dst_count="$(container run --rm -v "$dest:/v" "$HELPER_IMAGE" sh -c 'find /v -type f -not -path "/v/lost+found/*" | wc -l' 2>/dev/null | tr -d ' ')"
  if [[ "$src_count" == "$dst_count" ]]; then
    ok "$src_count files copied"
  else
    warn "file count differs: source $src_count, destination $dst_count (check permissions / sockets / device nodes)"
  fi
  OK+=("$dest")
  (( KEEP_TAR )) || rm -f "$tar_path"
done

head1 "Result"
(( ${#OK[@]} ))  && { ok "migrated: ${OK[*]}"; }
(( ${#BAD[@]} )) && { fail "failed: ${BAD[*]}"; }
note "Mount one with: container run --rm -it -v <name>:/data $HELPER_IMAGE sh"
note "Postgres/MySQL: check file ownership inside the volume matches the uid the image runs as."
(( KEEP_TAR )) && note "intermediate tars kept in $XFER"
exit $(( ${#BAD[@]} > 0 ? 1 : 0 ))
