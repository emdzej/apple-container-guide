#!/usr/bin/env bash
# compose-check.sh - lint a Compose file for things Apple container cannot honour.
#
#   ./scripts/compose-check.sh                      # autodiscovers compose.yaml / docker-compose.yml
#   ./scripts/compose-check.sh path/to/compose.yaml
#
# Run this before you migrate a stack. It flags keys that will be silently
# ignored, quietly approximated, or outright rejected, and says which compose
# front end (container-compose / docker compose via socktainer / davit compose)
# handles each one.
set -uo pipefail
# Resolve the argument against the CALLER's directory before we cd anywhere,
# otherwise a relative path like examples/x/compose.yaml breaks.
FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  for c in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    [[ -f "$c" ]] && { FILE="$(pwd)/$c"; break; }
  done
elif [[ "$FILE" != /* ]]; then
  FILE="$(pwd)/$FILE"
fi

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh
[[ -n "$FILE" && -f "$FILE" ]] || die "no compose file found (pass one as an argument)"
info "checking $FILE"

FINDINGS=0
# hit <severity> <key-regex> <message>
hit() {
  local sev="$1" pat="$2" msg="$3" lines
  lines="$(grep -nE "$pat" "$FILE" | cut -d: -f1 | paste -sd, -)"
  [[ -z "$lines" ]] && return 0
  FINDINGS=$((FINDINGS + 1))
  case "$sev" in
    block) fail "line(s) $lines: $msg" ;;
    warn)  warn "line(s) $lines: $msg" ;;
    info)  info "line(s) $lines: $msg" ;;
  esac
}

head1 "No equivalent on this platform"
hit block '^[[:space:]]*privileged:[[:space:]]*true'    "privileged: true - Apple container has no privileged mode. socktainer approximates it as --cap-add=ALL (no device access, seccomp or AppArmor). container-compose will ignore it."
hit block '^[[:space:]]*(devices|device_cgroup_rules):' "devices: - no device passthrough into the guest VM."
hit block '^[[:space:]]*(gpus|deploy:[[:space:]]*$)?[[:space:]]*(driver:[[:space:]]*nvidia|capabilities:.*gpu)' "GPU reservations - not available."
hit block '^[[:space:]]*network_mode:[[:space:]]*(host|container:)' "network_mode: host/container: - each container is its own VM, so there is no shared host netns."
hit block '^[[:space:]]*pid:[[:space:]]*(host|container:)'  "pid namespace sharing - not possible across VMs."
hit block '^[[:space:]]*(userns_mode|cgroup_parent|cgroup:)' "cgroup/userns controls - not exposed."
hit block '^[[:space:]]*platform:[[:space:]]*linux/(386|arm/v[67]|ppc64le|s390x)' "only linux/arm64 natively and linux/amd64 under Rosetta are supported."

head1 "Accepted but approximated"
hit warn '^[[:space:]]*cpus?:|cpu_count:|^[[:space:]]*cpus:' "cpus: - the VM gets a whole number of vCPUs. Fractions are floored to 1; there is no CFS throttling."
hit warn 'cpu_shares:|cpu_quota:|cpu_period:'            "cpu_shares/quota/period - no equivalent, silently not applied."
hit warn '^[[:space:]]*(mem_limit|memory):'              "memory - allocated to the VM at boot, not a soft cgroup limit. Too low means the process is OOM-killed inside the guest."
hit warn '^[[:space:]]*restart:'                         "restart: - socktainer enforces it only while socktainer itself runs; it does not survive a reboot. container-compose does not implement it."
hit warn '^[[:space:]]*(ipv4_address|ipv6_address):'      "static IPs - addresses come from a rotating allocator. Use service names via DNS instead."
hit warn '(gateway|ip_range|aux_addresses):'             "IPAM gateway/ip_range/aux_addresses - ignored; only subnet is honoured."
hit warn '/var/run/docker\.sock'                          "docker.sock bind mount - socktainer relays it to its own API, which gives that container full control of every other container. Drop it if you can."
hit warn '^[[:space:]]*(sysctls|ulimits):'                "sysctls/ulimits - container run has --ulimit, but compose front ends may not pass these through."
hit warn '^[[:space:]]*extra_hosts:'                      "extra_hosts - no --add-host equivalent; Davit writes /etc/hosts entries, others do not."

head1 "Portability across compose front ends"
# `command: sh -c '...'` (or a >/| block) is word-split by Docker Compose but
# passed as a single argv element by container-compose, which fails at runtime
# with "No such file or directory". The list form is unambiguous everywhere.
CMD_LINES="$(grep -nE '^[[:space:]]*(command|entrypoint):[[:space:]]*([>|]|[^[:space:]#[]|$)' "$FILE" \
             | grep -vE ':[[:space:]]*(command|entrypoint):[[:space:]]*$' | cut -d: -f1 | paste -sd, -)"
if [[ -n "$CMD_LINES" ]]; then
  FINDINGS=$((FINDINGS + 1))
  fail "line(s) $CMD_LINES: string-form 'command:'/'entrypoint:'. Docker Compose word-splits these; container-compose passes the whole string as one argv element and the container dies with \"No such file or directory\". Use the list form: command: [\"sh\", \"-c\", \"...\"]"
fi

hit warn '^[[:space:]]*driver_opts:'                     "driver_opts - honoured by 'docker compose' (socktainer sync= modes) and container-compose; silently dropped by davit compose."

head1 "Works, but read the notes"
hit info '^[[:space:]]*depends_on:'                      "depends_on - ordering works in all three front ends."
hit warn '^[[:space:]]*condition:[[:space:]]*service_'   "depends_on conditions (service_healthy / service_completed_successfully) - honoured by 'docker compose' via socktainer and by davit compose; container-compose treats depends_on as ordering only and starts the dependant immediately."
hit warn '^[[:space:]]*healthcheck:'                     "healthcheck - honoured by 'docker compose' via socktainer and davit compose; ignored by container-compose."
hit info '^[[:space:]]*profiles:'                        "profiles - supported by container-compose (--profile) and davit compose."
hit info '^[[:space:]]*build:'                           "build: - goes through the BuildKit builder VM; give it resources with 'container builder start --cpus N --memory Ng'."
hit info '^[[:space:]]*secrets:'                          "secrets - container build has --secret, but compose-level secrets are not uniformly supported."
hit info 'image:[[:space:]]*(postgres|.*\/postgres)'      "postgres on a named volume: ext4 volumes contain /lost+found and initdb refuses a non-empty dir. socktainer clears it automatically; with container-compose you must do it yourself."

head1 "Service discovery"
if grep -qE '^[[:space:]]*name:' "$FILE"; then
  ok "a project 'name:' is set - socktainer's qualified aliases (<service>.<project>) will be unambiguous"
else
  warn "no project 'name:' - two stacks with a service called the same thing will fight over the short DNS alias. Add 'name: myproject' at the top."
fi

head1 "Summary"
if (( FINDINGS == 0 )); then
  ok "nothing flagged - this stack should port cleanly"
else
  info "$FINDINGS item(s) flagged. See docs/04-compose.md and docs/05-docker-compat.md"
fi
