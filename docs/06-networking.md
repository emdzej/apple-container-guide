# 06 — Networking & DNS

The model is genuinely different, and mostly in your favour: every container is
a VM on a `vmnet` network with a **real, routable IP address, reachable from your
Mac without publishing anything**.

```bash
container ls
# ID        IMAGE                  STATE    IP
# my-app    myapp:dev              running  192.168.64.7/24

curl http://192.168.64.7:8000      # works, no --publish needed
```

That's the part people don't expect. On Docker you must publish a port to reach
a container from the host. Here you don't — publishing is only for binding to
`localhost`.

## The default network

`container system start` creates a `vmnet` network named `default`. Containers
attach to it unless told otherwise.

```bash
container network ls
# NETWORK  SUBNET
# default  192.168.64.0/24
```

## Reaching containers by name from your Mac

This takes **two** steps and almost everyone does only the first, then concludes
it's broken.

### Step 1 — tell the service which domain to use

`~/.config/container/config.toml`:

```toml
[dns]
domain = "test"
```

```bash
container system stop && container system start
```

Now every container is registered as `<name>.test` inside the platform's DNS,
and each container's own resolver knows to look `.test` names up there.

### Step 2 — tell macOS about the domain

Step 1 only configures the platform. Your Mac's resolver still knows nothing:

```bash
sudo container system dns create test
```

This writes `/etc/resolver/test`, telling macOS to send `*.test` queries to
`127.0.0.1`. It needs an administrator password.

```bash
container system dns list
ls /etc/resolver/
```

Both steps, or nothing works. `./scripts/setup-dns.sh` does both and verifies.

### Verify

```bash
container run -d --rm --name my-web-server python:alpine python3 -m http.server 8000
curl http://my-web-server.test:8000
container stop my-web-server
```

### Choosing a domain

`test` is reserved by RFC 6761 for exactly this and will never resolve publicly —
a good default. Avoid `.local` (mDNS/Bonjour owns it) and avoid `.dev` (a real
gTLD with enforced HSTS; browsers will force HTTPS).

## Container-to-container

With the DNS setup above, containers on the `default` network reach each other by
**domain-qualified** name:

```bash
container run --rm -d --name http-server python:alpine python3 -m http.server
container run -it --rm alpine/curl curl -v http://http-server.test:8000
```

### The gap that matters

**Bare hostnames do not resolve**, and on custom networks created with
`container network create` neither form does. That is, this doesn't work:

```bash
container network create mynet
container run -d --name db --network mynet postgres:17-alpine
container run --rm --network mynet alpine/curl curl http://db:5432   # fails
```

This is the zero-config, Compose-style service discovery people expect, and it
isn't implemented — tracked as
[apple/container#1809](https://github.com/apple/container/issues/1809) and
[#856](https://github.com/apple/container/issues/856).

Until it lands, your options:

| Approach | How |
|---|---|
| **socktainer's DNS** | Runs its own DNS server on port 2054 and registers `<service>` and `<service>.<project>` for Compose stacks. Works with no host DNS setup at all. Verified. |
| `container-compose` / `davit compose` | Both write `/etc/hosts` entries into each container. Short names only; stale after an out-of-band recreate. |
| Qualified names on `default` | Skip custom networks, use `<name>.test` everywhere. |
| IP addresses | `container inspect <name> \| jq -r '.[0].status.networks[0].ipv4Address'`. Stable for a container's lifetime, not across recreates. |

In practice: **if you need service discovery, use socktainer.** It's the reason
`docker compose` is the recommended compose path.

## Publishing ports

```bash
# [host-ip:]host-port:container-port[/protocol]
container run -d -p 8080:8000 myapp                 # all interfaces
container run -d -p 127.0.0.1:8080:8000 myapp       # loopback only
container run -d -p '[::1]:8080:8000' myapp         # IPv6 loopback (quote it)
container run -d -p 5353:5353/udp myapp             # UDP
```

If a container is on multiple networks, published ports forward to the interface
on the **first** network.

You can also publish a unix socket, which Docker can't do:

```bash
container run --publish-socket /tmp/app.sock:/var/run/app.sock myapp
```

## Reaching your Mac from inside a container

There's no `host.docker.internal`. You create the equivalent yourself:

```bash
sudo container system dns create host.container.internal --localhost 203.0.113.113
```

Then from a container:

```bash
container run -it --rm alpine/curl curl http://host.container.internal:8000
```

Pick an address unlikely to collide — the documentation ranges
(`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) or something inside
`172.16.0.0/12`.

**Two caveats Apple documents explicitly:**

- Creating a localhost domain **disables iCloud Private Relay**.
- The packet-filter rule is **removed on restart**, so you re-run the command
  after a reboot.

`./scripts/setup-dns.sh --host-access` sets this up and warns about both.

## Custom networks

```bash
container network create mynet
container network create mynet --subnet 192.168.100.0/24 --subnet-v6 fd00:1234::/64
container network create isolated --internal          # host-only
container network ls
container network delete mynet                         # must be empty first
```

Networks are **mutually isolated** — a container on one has no connectivity to
containers on another. IPv4 and IPv6 both supported; subnets are validated
against overlap.

Defaults for new networks:

```toml
[network]
subnet = "192.168.100.0/24"
subnetv6 = "fd00:abcd::/64"
```

### No hot-plug

There is no `network connect` / `disconnect`. Network membership is fixed at
container create — Virtualization.framework offers no NIC hotplug. socktainer
accepts the Docker calls as no-ops so Compose doesn't break, but nothing happens.

Under socktainer, networks get a **pinned** subnet so inter-container DNS keeps
working across a `container system` restart. Networks created before that
behaviour shipped aren't pinned retroactively — recreate them
(`docker compose down && docker compose up`).

## Custom MAC addresses

```bash
container run --network default,mac=02:42:ac:11:00:02 ubuntu:latest
container run --rm --network default,mac=02:42:ac:11:00:02 ubuntu cat /sys/class/net/eth0/address
```

Set the two least significant bits of the first octet to `10` (locally
administered, unicast). Auto-generated addresses start with nibble `f`, so
picking anything else avoids collisions.

## What's impossible

| Docker | Why not here |
|---|---|
| `--network host` | Each container has its own kernel and network stack. There is no host netns to join. Use `--publish`, or a `--localhost` DNS domain to reach host services. |
| `--network none` | Closest is `container network create --internal`. |
| `--network container:<id>` | No shared netns across VMs. |
| `--ip` / static IPs | The allocator rotates; no way to request an address. Stable per container lifetime. |
| `--add-host` | No flag. Compose front ends write `/etc/hosts`; the CLI doesn't. |
| IPAM gateway / ip-range | Gateway is always the subnet's `.1`; addresses come from `vmnet`. Ignored with a warning. |

## Troubleshooting

**`EHOSTUNREACH` / "no route to host" between containers.** After a lot of
network churn (many networks created and destroyed), `vmnet` state degrades.
The documented fix:

```bash
container system stop && container system start
# then restart socktainer if you use it
```

`cnetreset` in the shell helpers does both.

**A published port doesn't answer.** The VM has to boot first — a second or so,
not instant. Scripts that `curl` immediately after `run -d` need a retry loop;
see [example 02](../examples/02-node-web/run.sh).

**Name resolution works from a container but not from your Mac.** You did step 1
and not step 2. `ls /etc/resolver/`.

**Name resolution works from your Mac but not inside a container.** Usually the
reverse — `[dns] domain` isn't set, so the container's own resolver was never
configured. `container system property list`.

## Next

- [07 — Storage](07-storage.md)
