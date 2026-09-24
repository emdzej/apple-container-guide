#!/usr/bin/env bash
# Path 1: container-compose - the Apple-native front end.
# No Docker dependency at all. Smallest feature set of the three.
set -euo pipefail
cd "$(dirname "$0")"
container system status >/dev/null 2>&1 || container system start

echo "==> container-compose up"
# -b/--build builds local images first, --no-cache forces a rebuild,
# --profile gates services, --env-file points at a non-default .env.
# Without -d it stays attached, but killing it does NOT stop the containers.
container-compose -f compose.yaml up -d

sleep 8
echo
echo "==> containers (there is no 'container-compose ps')"
container ls -a

echo
echo "==> did api reach db by name?"
container logs -n 20 acdemo-api | tail -8

echo
echo "==> how discovery actually works here"
container exec acdemo-api cat /etc/hosts

cat <<'NOTE'

Verified behaviour of container-compose 1.2.0:

  works
    - mem_limit per service (the VM gets that much, reserved at boot)
    - ports: published to the host
    - named volumes, including driver_opts (passed through to
      `container volume create --opt`, so socktainer's sync= modes survive)
    - depends_on ordering
    - service discovery, via /etc/hosts entries written into each container -
      short names only (`db`), NOT the qualified `db.acdemo` form
    - profiles, env_file, ${VAR} interpolation

  does not work
    - `command:` in STRING form. Docker Compose word-splits
      `command: sh -c '...'`; container-compose passes the whole string as one
      argv element and the container dies with "No such file or directory".
      Always use the list form. This is the single most common porting failure.
    - `cpus:` is ignored - every service got 4 vCPUs regardless
    - healthcheck-gated depends_on conditions (service_healthy): ordering only
    - restart: policies
    - project-level isolation: `name:` only affects container naming. It warns
      about this itself. Two projects with a `db` service collide.

  subcommands
    up, down, build, version. That is all. For the rest, drop to the CLI:
      ps       -> container ls -a
      logs     -> container logs -f acdemo-api
      exec     -> container exec -it acdemo-api sh
      restart  -> container stop <name> && container start <name>

  `down` STOPS containers; it does not remove them, and it leaves volumes and
  networks alone. They stay in the `stopped` state until you `container rm` them.
  That is the opposite of `docker compose down`, which removes containers but
  keeps volumes unless you pass -v.

Down:    container-compose -f compose.yaml down
Remove:  container rm acdemo-db acdemo-api acdemo-web
NOTE
