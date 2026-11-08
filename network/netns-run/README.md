# netns-run.sh

A wrapper for running an arbitrary command in an isolated network namespace
(netns). The netns itself has no connectivity of its own: its traffic leaves
through a veth pair onto the host, where policy routing decides where it goes.
The routing is described by the user with `--route` entries; destinations not
covered by any entry follow the host's system routing, and with no entries at
all all of the netns's traffic follows the host's routing as if the netns did
not exist. Typical use case — running an application whose traffic to
selected destinations goes through a different channel (a second provider, a
VPN gateway, a separate network card) without changing the host's own
routing.

When the command finishes (successfully or not), the entire created environment
is automatically removed — including the netns, the veth pair, routes, policy
routing rules, iptables rules and modified sysctls.

## How It Works

1. A temporary network namespace is created (fixed name `netns-<PID>`).
2. A veth pair is brought up between the host and the netns
   (`10.200.X.1` ↔ `10.200.X.2/30`, X is chosen from the PID). No host
   interface is moved into the netns — the veth is its only link to the
   host. Inside the netns a default route via the host side of the veth is
   set, so every packet of the netns leaves onto the host through the veth.
3. The current value of the host sysctl `net.ipv4.ping_group_range` is copied
   into the netns — it permits unprivileged ICMP sockets (SOCK_DGRAM), which
   `ping` and `traceroute -I` rely on. Host systemd sets this value only in
   the initial netns; it does not get into a new netns on its own. The write
   goes only into the netns and dies together with it; a failure is not fatal
   (a warning).
4. DNS: nothing is configured — there is no per-netns `resolv.conf`, so
   processes inside the netns see the host's current `/etc/resolv.conf`
   as is.
5. On the host, forwarding is enabled (if it was disabled, the original value
   is restored during cleanup).
6. NAT and FORWARD rules are added on the host without binding to any
   particular outgoing interface: MASQUERADE for all traffic from the netns
   subnet (regardless of which interface it leaves through) and FORWARD
   accept rules for traffic to and from the host end of the veth.
7. Policy routing — only when `--route` entries are given: a rule
   `ip rule add pref <P> from <netns subnet> table <T>` directs traffic from
   the netns into a separate routing table (number derived from the PID)
   populated from the `--route` entries. A destination covered by an entry
   follows it, overriding the host's system routing; destinations not covered
   by any entry keep following the host's system routing. With no `--route`
   entries neither the rule nor the table is created, and a catch-all
   exception `0.0.0.0/0` directs all netns traffic into the host's `main`
   table.
8. Exceptions (`--exclude`): a rule with a higher priority (a lower number)
   than the main netns rule — `ip rule add pref <P-10> from <netns subnet>
   to <addr> table main` — directs traffic to the listed addresses/domains
   into the host's system routing.
9. The command is launched: `ip netns exec <netns> sudo -E -u <user> -- <command>`.

## Requirements

- Linux, `root` privileges via `sudo` (the script invokes sudo itself; the
  password is asked once, afterwards it is maintained by a background
  keepalive process).
- Utilities: `ip` (iproute2), `iptables`, `nslookup` (needed only if domains
  are used in `--route`/`--route-file`/`--exclude`/`--exclude-file`).

## Usage

```
netns-run.sh [--route R] [--route-file F] [--exclude A] \
             [--exclude-file F] -- COMMAND [ARGS...]
```

Options may be given in any order and interleaved. Some things are **not
configurable**:

- the netns is always named `netns-<PID>`;
- the command runs as the user who launched the script (`$SUDO_USER`, or the
  current user);
- the netns uses the host's current `/etc/resolv.conf` as is.

## Options

| Option | Description |
|---|---|
| `--route R` | Route for the netns traffic to the given destination: `[<addr>] (via <gw> \| dev <if> \| via <gw> dev <if> \| dev <if> via <gw>)`. See "Routes and Exceptions" below. May be specified multiple times. |
| `--route-file F` | Routes file; every non-empty line is one `--route` argument (lines starting with `#` are ignored). May be specified multiple times. |
| `--exclude A` | Address/CIDR subnet or domain whose traffic from the netns goes via the host's system routing (the `main` table), as if the netns did not exist. May be specified multiple times. |
| `--exclude-file F` | Exclude file; every non-empty line is one `--exclude` argument (lines starting with `#` are ignored). May be specified multiple times. |
| `--help` | Help. |

## Routes and Exceptions

### `--route "[<addr>] via <gw> | dev <if> | ..."`

Grammar of one route (quoted as a single argument):

```
[<addr>] (via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>)
```

`via` and `dev` may be given in either order, each at most once; no other
keywords are allowed after them (no `metric`, `mtu`, etc.).

- `<addr>` — an IPv4 address (`8.8.8.8`), a CIDR subnet (`10.1.0.0/16`, valid
  prefixes `/0`–`/32`), a domain (`example.com`) or the keyword `default`.
  An omitted `<addr>`, as well as `0.0.0.0` or `0.0.0.0/0`, mean the default
  route.
- `<gw>` — an IPv4 gateway address.
- `<if>` — a host interface name. A `dev`-only route (`10.1.0.0/16 dev eth1`,
  `dev eth1`) sends the traffic out through that interface, taking the
  gateway from the interface's own routes.

Interface determination: for a `via <gw>` route without `dev` the interface is
found automatically via `ip route get <gw>` — the gateway must be reachable
through one of the host's interfaces, otherwise the script fails immediately
(specify `dev <if>` explicitly). An explicit `dev <if>` must exist on the host.

Routes are added to a separate policy table which applies **only to traffic
from the netns** — the host is not affected. For addresses/subnets (including
`default`) `ip route replace` is used, so repeated or overlapping entries do
not fail: the last entry for a destination wins (several default routes —
the last one given replaces the previous). For domains all IPv4 addresses
(A records) are resolved **inside the netns** and a `/32` route is added for
each of them.

**With no `--route` given at all, all traffic from the netns follows the
host's system routing** — a catch-all exception `0.0.0.0/0` is added
automatically (the same as `--exclude 0.0.0.0/0`).

### `--route-file <file>`

A routes file in which every non-empty line is a route in the `--route` format
(lines starting with `#` are ignored). Equivalent to several `--route` options.
May be specified multiple times.

### `--exclude <addr|domain>`

An address/CIDR subnet or a domain whose traffic from the netns is routed by
the **host's system routing** (the `main` table) — as if the netns did not
exist. Implemented by the rule `ip rule add pref <P-10> from <netns subnet>
to <addr> table main`, whose priority is higher (a lower number) than that of
the main netns rule. May be specified multiple times.

- for an IP/subnet — a single rule (`to 8.8.8.8`, `to 192.168.23.0/24`);
- for a domain — a `/32` rule for every IPv4 address of the domain (resolved
  inside the netns).

### `--exclude-file <file>`

An exclude file with one exception per line (format same as `--exclude`; empty
lines and `#` comments are ignored). Equivalent to several `--exclude` options.
May be specified multiple times.

### Validation and Domains

All `--route`/`--route-file`/`--exclude`/`--exclude-file` lines are validated
**before** sudo and environment creation — an invalid line fails the script
immediately, with a clear message. The domain name format is checked
syntactically; the domain's addresses are resolved later, **inside the netns**
(after the default route through the veth is up), using the host's current
`/etc/resolv.conf`; all A records are resolved (IPv6 answers are ignored).

## Examples

```bash
# all firefox traffic via gateway 192.168.1.5 (default route)
./netns-run.sh --route "via 192.168.1.5" -- firefox

# default route via gateway 192.168.1.5, reachable through eth1
./netns-run.sh --route "via 192.168.1.5 dev eth1" -- firefox

# the same route, dev first — both orders are equivalent
./netns-run.sh --route "dev eth1 via 192.168.1.5" -- firefox

# default route via the interface eth1 (gateway taken from its routes)
./netns-run.sh --route "dev eth1" -- firefox

# the same, with the explicit keyword default
./netns-run.sh --route "default via 192.168.1.5" -- firefox

# subnet 10.40.0.0/16 — via a separate gateway 192.168.1.254
./netns-run.sh --route "10.40.0.0/16 via 192.168.1.254" -- firefox

# subnet 10.1.0.0/16 — out through the interface eth1
./netns-run.sh --route "10.1.0.0/16 dev eth1" -- curl https://example.com

# domain: /32 routes to all of its addresses
./netns-run.sh --route "example.com via 192.168.1.254" -- curl https://example.com

# 192.168.23.0/24 — via the host's system routing (bypassing the netns routes)
./netns-run.sh --route "via 192.168.1.5" --exclude 192.168.23.0/24 -- curl https://example.com

# routes and exceptions from files
./netns-run.sh --route-file routes.txt --exclude-file exclude.txt -- firefox
```

Example `routes.txt`:

```
# default route through another provider
via 192.168.1.5 dev eth1
# corporate subnet via its own gateway
10.40.0.0/16 via 192.168.1.254
# database host
10.40.1.10 via 192.168.1.254
# domain — all of its A records
gitlab.corp.example via 192.168.1.254
```

Example `exclude.txt`:

```
# the printer's local network
192.168.23.0/24
# domains following the host's system routing
internal.corp.example
```

## Cleanup

Cleanup runs on `EXIT`/`INT`/`TERM` and removes everything that was created:
the `ip rule` rules (the main one and the exceptions), the policy table's
routes (flush), the iptables rules (FORWARD, NAT), the netns (together with
the veth pair), and restores the original value of `net.ipv4.ip_forward` if
it was changed.

## Limitations

- IPv4 only (routes and exceptions are IPv4; AAAA answers are ignored when
  resolving domains).
- The IP addresses of domains in `--route`/`--exclude` are fixed at launch
  time — if the domain's DNS records change while the command runs, the
  routes/rules are not updated.
- Several `--route` entries with the same destination (including several
  default routes) do not add up: the last one given replaces the previous
  (`ip route replace` semantics; domain routes expand to `/32` entries and
  skip already-existing ones).
- A `via <gw>` route without an explicit `dev` requires the gateway to be
  reachable through one of the host's interfaces at launch time (checked
  before the environment is created; the script fails otherwise).
- Parallel runs are safe: veth names, the table number and the `ip rule`
  priorities are generated from the script PID (runs with matching
  `PID % 100` may get the same table number — in that case the table is
  shared).
- Diagnostic network utilities inside the netns run with the same privileges
  as on the host. `ping` and `traceroute -I` work "as on the host" — the host
  sysctl `net.ipv4.ping_group_range` is copied into the netns (see step 3 of
  the "How It Works" section); `tracepath` and `traceroute` (UDP mode) need no
  privileges at all; tools that require real `CAP_NET_RAW` require root —
  both inside the netns and on the host. Matrix:

| Utility | Inside the netns | On the host |
|---|---|---|
| `ping`, `traceroute -I` | work for a regular user ("as on the host", via a copy of `net.ipv4.ping_group_range`) | the same (the sysctl is set by host systemd) |
| `tracepath`, `traceroute` (UDP) | work without privileges | work without privileges |
| `traceroute -T`, `tcpdump` | require root | also require root |
