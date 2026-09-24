#!/usr/bin/env bash
# setup-dns.sh - make containers reachable from your Mac by name (<name>.<domain>).
#
#   ./scripts/setup-dns.sh              # uses the domain 'test'
#   ./scripts/setup-dns.sh internal     # uses .internal
#   ./scripts/setup-dns.sh --host-access   # also create host.container.internal
#
# Two things have to happen and people usually only do the first:
#   1. the container service has to append a domain to container hostnames  ([dns] in config.toml)
#   2. macOS has to be told to resolve that domain via 127.0.0.1            (/etc/resolver/<domain>, needs sudo)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=lib/common.sh
source ./lib/common.sh

DOMAIN="test"; HOST_ACCESS=0; HOST_IP="203.0.113.113"
for arg in "$@"; do
  case "$arg" in
    --host-access) HOST_ACCESS=1 ;;
    --host-ip=*)   HOST_IP="${arg#*=}" ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    -*)            die "unknown flag: $arg" ;;
    *)             DOMAIN="$arg" ;;
  esac
done

require_container_cli
CONFIG="$HOME/.config/container/config.toml"

head1 "1. Set [dns].domain = \"$DOMAIN\" in $CONFIG"
CURRENT="$(container system property list 2>/dev/null | awk '/^\[dns\]/{f=1;next} /^\[/{f=0} f && $1=="domain"{gsub(/"/,"",$3); print $3}')"
if [[ "$CURRENT" == "$DOMAIN" ]]; then
  ok "already set to '$DOMAIN'"
else
  [[ -n "$CURRENT" ]] && warn "currently '$CURRENT' - changing it to '$DOMAIN'"
  mkdir -p "$(dirname "$CONFIG")"
  if [[ -f "$CONFIG" ]]; then
    cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    note "backed up existing config"
    if grep -q '^\[dns\]' "$CONFIG"; then
      # Replace the domain line inside the existing [dns] table.
      awk -v d="$DOMAIN" '
        /^\[dns\]/      { print; indns=1; done=0; next }
        /^\[/           { if (indns && !done) { print "domain = \"" d "\"" ; done=1 } indns=0; print; next }
        indns && /^[[:space:]]*domain[[:space:]]*=/ { print "domain = \"" d "\""; done=1; next }
        { print }
        END             { if (indns && !done) print "domain = \"" d "\"" }
      ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    else
      printf '\n[dns]\ndomain = "%s"\n' "$DOMAIN" >> "$CONFIG"
    fi
  else
    printf '[dns]\ndomain = "%s"\n' "$DOMAIN" > "$CONFIG"
  fi
  ok "wrote $CONFIG"
  run "restarting services so the change takes effect" bash -c 'container system stop && container system start'
fi

head1 "2. Tell macOS to resolve *.$DOMAIN via the container DNS service"
if [[ -f "/etc/resolver/$DOMAIN" ]]; then
  ok "/etc/resolver/$DOMAIN already exists"
else
  warn "this step needs your administrator password"
  run "creating the resolver entry" sudo container system dns create "$DOMAIN" \
    || die "failed - run it yourself: sudo container system dns create $DOMAIN"
fi
container system dns list 2>/dev/null | sed 's/^/       /'

if (( HOST_ACCESS )); then
  head1 "3. host.container.internal -> your Mac ($HOST_IP)"
  warn "Heads up: creating a localhost domain disables iCloud Private Relay, and macOS"
  warn "drops the packet-filter rule on reboot, so you may need to re-run this."
  if confirm "Create host.container.internal pointing at $HOST_IP?"; then
    run "creating host domain" sudo container system dns create host.container.internal --localhost "$HOST_IP"
  fi
fi

head1 "Verify"
note "container run -d --rm --name dnscheck python:alpine python3 -m http.server 8000"
note "curl http://dnscheck.$DOMAIN:8000"
note "container stop dnscheck"
warn "Bare hostnames on custom networks still do not resolve (apple/container#1809)."
warn "Compose-style discovery needs socktainer's DNS or Davit's /etc/hosts management - see docs/06-networking.md"
