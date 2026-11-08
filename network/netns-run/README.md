# netns-run.sh

A wrapper for running an arbitrary command in an isolated network namespace
(netns), forcing all of its network traffic through a given gateway,
reachable via one of the host's interfaces. Typical use case —
running an application through a different channel (a second provider, a VPN
gateway, a separate network card) without changing the host's own routing.

When the command finishes (successfully or not), the entire created environment
is automatically removed — including the netns, the veth pair, routes, policy
routing rules, iptables rules and modified sysctls.

## How It Works

1. A temporary network namespace is created (default name `netns-<PID>`).
2. A veth pair is brought up between the host and the netns
   (`10.200.X.1` ↔ `10.200.X.2/30`, X is chosen from the PID).
   **The specified host interface is not moved into the netns** — it stays on
   the host; connectivity goes through the veth.
3. Inside the netns a default route is set to the host side of the veth.
4. The current value of the host sysctl `net.ipv4.ping_group_range` is copied
   into the netns — it permits unprivileged ICMP sockets (SOCK_DGRAM), which
   `ping` and `traceroute -I` rely on. Host systemd sets this value only in
   the initial netns; it does not get into a new netns on its own. The write
   goes only into the netns and dies together with it; a failure is not fatal
   (a warning).
5. On the host, forwarding is enabled (if it was disabled, the original value
   is restored during cleanup), and NAT is added (MASQUERADE from the netns
   subnet to the outgoing interface) along with FORWARD rules.
6. Policy routing: a separate routing table (number derived from the PID) is
   added with a default route via the specified gateway, plus the rule
   `ip rule add pref <P> from <netns subnet> table <T>` — all traffic from the
   netns goes through the given gateway, regardless of the host's default
   route. The interface's local (on-link) subnet is added to the table as a
   separate, more specific route — LAN neighbors are reachable directly, not
   through the gateway.
7. The command is launched: `ip netns exec <netns> sudo -E -u <user> -- <command>`.

## Requirements

- Linux, `root` privileges via `sudo` (the script invokes sudo itself; the
  password is asked once, afterwards it is maintained by a background
  keepalive process).
- Utilities: `ip` (iproute2), `iptables`, `nslookup` (needed only if domains
  are used in `--route`/`--exclude`).

## Usage

```
netns-run.sh [-g GATEWAY] [-i IFACE] [-n NETNS] [-d DNS1,DNS2] [-u USER] \
             [--route R]... [--route-file F]... [--exclude A]... \
             [--exclude-file F]... -- COMMAND [ARGS...]
```

At least one of `-g` / `-i` must be given — the other is determined
automatically:

- `-g` given → the interface is found via `ip route get GATEWAY`;
- `-i` given → the gateway is taken from `ip route show default dev IFACE`.

## Options

| Option | Description |
|---|---|
| `-g GATEWAY` | IPv4 address of the gateway through which all of the command's traffic must go. |
| `-i IFACE` | Host interface via which the gateway is reachable. |
| `-n NETNS` | Network namespace name (default `netns-<PID>`). |
| `-d DNS` | Comma-separated DNS servers for the netns (e.g. `1.1.1.1,9.9.9.9`). By default the host's current `/etc/resolv.conf` is used as is (no `/etc/netns/...` bind mounts are created; with an explicit `-d` a separate resolv.conf is created for this netns). |
| `-u USER` | User to run the command inside the netns as (default — the user who launched the script: `$SUDO_USER` or the current one). |
| `-h` | Help. |

## Routes and Exceptions

### `--route "<addr> via <gw> [dev <iface>]"`

An additional route for the given address/subnet or domain. The syntax is the
standard one for `ip route`; the word `gw` is allowed instead of `via`. Both
options (`--route` and `--route-file`) may be given multiple times and
interleaved.

- `<addr>` — an IPv4 address (`8.8.8.8`), a CIDR subnet (`10.1.0.0/16`, valid
  prefixes `/0`–`/32`) or a domain (`example.com`).
- `<gw>` — an IPv4 gateway address (required).
- `[dev <iface>]` — an optional host interface via which `<gw>` is reachable
  (same as the main gateway `-g`). After `via <gw>` **only** `dev <iface>` is
  allowed — no `metric`, `mtu`, etc.

Routes are added to the same policy table as the default route, so they apply
**only to traffic from the netns** — the host is not affected. For
addresses/subnets `ip route replace` is used (robust against an overlapping
default route and repeated runs), for domains — `ip route add <ip>/32` for
every IPv4 address of the domain.

### `--route-file <file>`

A routes file in which every non-empty line is a route in the `--route` format
(lines starting with `#` are ignored). Equivalent to several `--route` options.
May be specified multiple times.

### `--exclude <addr|domain>`

An address/CIDR subnet or a domain whose traffic from the netns is routed by
the **host's system routing** (the main `main` table) — as if the netns did
not exist. Implemented by the rule `ip rule add pref <P-10> from <netns subnet>
to <addr> table main`, whose priority is higher (a lower number) than that of
the main netns rule. May be specified multiple times.

- for an IP/subnet — a single rule (`to 8.8.8.8`, `to 192.168.23.0/24`);
- for a domain — a `/32` rule for every IPv4 address of the domain.

### `--exclude-file <file>`

An exclude file with one exception per line (format same as `--exclude`; empty
lines and `#` comments are ignored). Equivalent to several `--exclude` options.
May be specified multiple times.

### Validation and Domains

All `--route`/`--route-file`/`--exclude`/`--exclude-file` lines are validated
**before** sudo and environment creation — an invalid line fails the script
immediately, with a clear message. The domain name format is checked
syntactically; the domain's addresses are resolved later, **inside the netns**
(after DNS and the default route are up), so the DNS servers from `-d` are
used and all A records are resolved (IPv6 answers are ignored).

## Examples

```bash
# all firefox traffic via gateway 192.168.1.5
./netns-run.sh -g 192.168.1.5 -- firefox

# interface given, gateway taken from its default route
./netns-run.sh -i eth1 -- firefox

# subnet 10.40.0.0/16 — via a separate gateway 192.168.1.254
./netns-run.sh -g 192.168.1.5 --route "10.40.0.0/16 via 192.168.1.254" -- firefox

# gw synonym; subnet 10.1.0.0/16 via 192.168.23.100
./netns-run.sh -g 192.168.1.5 --route "10.1.0.0/16 gw 192.168.23.100" -- curl https://example.com

# domain: /32 routes to all of its addresses
./netns-run.sh -g 192.168.1.5 --route "example.com via 192.168.1.254" -- curl https://example.com

# 192.168.23.0/24 — via the host's system routing (bypassing the netns gateway)
./netns-run.sh -g 192.168.1.5 --exclude 192.168.23.0/24 -- curl https://example.com

# routes and exceptions from files
./netns-run.sh -g 192.168.1.5 --route-file routes.txt --exclude-file exclude.txt -- firefox
```

Example `routes.txt`:

```
# gateway for the corporate subnet
10.40.0.0/16 via 192.168.1.254
# database host
10.40.1.10 via 192.168.1.254 dev eth1
# domain — all of its A records
gitlab.corp.example via 192.168.1.254
```

Example `exclude.txt`:

```
# the printer's local network
192.168.23.0/24
# domains bypassing the tunnel
internal.corp.example
```

## Cleanup

Cleanup runs on `EXIT`/`INT`/`TERM` and removes everything that was created:
the `ip rule` rules (the main one and the exceptions), the table's routes
(flush), the iptables rules (FORWARD, NAT), the netns (together with the veth
pair), `/etc/netns/<name>/resolv.conf` (if it was created), and restores the
original value of `net.ipv4.ip_forward` if it was changed.

## Limitations

- IPv4 only (gateway, DNS servers, routes and exceptions are IPv4; AAAA
  answers are ignored when resolving domains).
- The IP addresses of domains in `--route`/`--exclude` are fixed at launch
  time — if the domain's DNS records change while the command runs, the
  routes/rules are not updated.
- Parallel runs are safe: veth names, the table number and the `ip rule`
  priorities are generated from the script PID (runs with matching
  `PID % 100` may get the same table number — in that case the table is
  shared).
- The script assumes the specified gateway is reachable via the specified (or
  automatically determined) host interface.
- Diagnostic network utilities inside the netns run with the same privileges
  as on the host. `ping` and `traceroute -I` work "as on the host" — the host
  sysctl `net.ipv4.ping_group_range` is copied into the netns (see step 4 of
  the "How It Works" section); `tracepath` and `traceroute` (UDP mode) need no
  privileges at all; tools that require real `CAP_NET_RAW` require root
  (`-u root`) — both inside the netns and on the host. Matrix:

| Utility | Inside the netns | On the host |
|---|---|---|
| `ping`, `traceroute -I` | work for a regular user ("as on the host", via a copy of `net.ipv4.ping_group_range`) | the same (the sysctl is set by host systemd) |
| `tracepath`, `traceroute` (UDP) | work without privileges | work without privileges |
| `traceroute -T`, `tcpdump` | require root: run via `-u root` | also require root |
