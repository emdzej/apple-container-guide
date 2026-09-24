#!/usr/bin/env bash
# Named volumes, the ext4 /lost+found gotcha, and why databases need explicit memory.
set -euo pipefail
NAME=pg-demo
VOL=pg-demo-data
PORT=${PORT:-55432}

container system status >/dev/null 2>&1 || container system start
container rm -f "$NAME" 2>/dev/null || true

if ! container volume inspect "$VOL" >/dev/null 2>&1; then
  # Volume images are sparse: the size is a ceiling, not an allocation.
  # journal=writeback trades a little crash safety for noticeably faster WAL writes.
  container volume create --opt journal=writeback:64m -s 20g "$VOL"
fi

# THE GOTCHA: every Apple container ext4 volume contains a /lost+found directory,
# and postgres initdb refuses to initialise a data directory that is not empty.
# socktainer strips it automatically for postgres images; the container CLI does not.
container run --rm -v "$VOL:/v" docker.io/library/alpine:3.22 \
  sh -c 'rm -rf /v/lost+found; ls -A /v | head'

# --memory matters here. The default 1 GiB is a hard VM reservation; postgres with
# a real working set will be OOM-killed inside the guest, and the only sign is an
# abrupt exit. Check `container logs --boot` if that happens.
container run --detach --name "$NAME" \
  --publish "127.0.0.1:${PORT}:5432" \
  --volume "$VOL:/var/lib/postgresql/data" \
  --cpus 2 --memory 2g \
  --env POSTGRES_PASSWORD=devonly \
  --env PGDATA=/var/lib/postgresql/data/pgdata \
  docker.io/library/postgres:17-alpine

echo "waiting for postgres..."
for _ in $(seq 1 60); do
  container exec "$NAME" pg_isready -q && break
  sleep 1
done

container exec "$NAME" psql -U postgres -c "select version();"
echo
echo "connect   psql 'postgresql://postgres:devonly@127.0.0.1:${PORT}/postgres'"
echo "backup    container run --rm -v $VOL:/vol:ro -v \$PWD:/out alpine tar czf /out/$VOL.tar.gz -C /vol ."
echo "stop      container rm -f $NAME       (the volume survives)"
echo "destroy   container volume delete $VOL   (permanent, no undo)"
