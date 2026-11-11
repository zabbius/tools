# netns-run

## Purpose

`netns-run` runs an arbitrary command in an isolated network namespace (netns). Routing of the netns traffic is set explicitly via `--route` entries: each entry directs traffic to its destination (an address, a subnet, a domain or the default route) through the given gateway and/or host interface, overriding the host's system routing for that destination; destinations not covered by any entry — as well as all traffic when no `--route` is given — follow the host's system routing. The host's own routing is not changed. Typical use case — directing traffic to specific destinations through a different channel (a second provider, a VPN gateway, a separate network card) without touching the rest of the routing. After the command finishes, the entire created environment is removed automatically.

## Key Files

- `network/netns-run/netns-run.sh` — the single implementation file: argument parsing, validation, environment setup and cleanup, running the command
- `network/netns-run/README.md` — user documentation (usage, options, examples, limitations)

## Core Types

The script is procedural bash; its "types" are global arrays and state scalars (from `network/netns-run/netns-run.sh`):

```bash
EXTRA_ROUTES=()    # raw "[<addr>] via|dev ..." lines from --route / --route-file
ROUTE_ADDR=()      # addr part of each parsed route: "default" | IPv4 | CIDR | domain
ROUTE_TAIL=()      # normalized remainder: "via <gw> dev <if>" | "via <gw>" | "dev <if>"
ROUTE_IPS=()       # A addresses of ROUTE_ADDR[i]'s domain, pre-resolved on the
                   # host before sudo ("" for default/IPv4/CIDR entries)
EXCLUDED_ADDRS=()  # "<addr|domain>" lines from --exclude / --exclude-file
                   # (+ the automatic catch-all "0.0.0.0/0" when no --route is given)
EXCLUDED_IPS=()    # same as ROUTE_IPS, for EXCLUDED_ADDRS[i]
DNS_SERVERS=()     # DNS server IPv4 addresses from --dns (repeatable;
                   # exact duplicates are dropped, the order is preserved
                   # — it becomes the order of the "nameserver" lines);
                   # empty = no override, the netns sees the host's
                   # current /etc/resolv.conf as is

# environment identifiers generated from the script PID
NETNS_NAME="netns-<PID_SUFFIX>"   # PID_SUFFIX = $$ % 65536
VETH_HOST="vh-<PID_SUFFIX>"; VETH_NS="vn-<PID_SUFFIX>"
TABLE_ID=$((100 + PID_SUFFIX % 100))          # policy table number
RULE_PRIO=$((20000 + PID_SUFFIX % 1000))      # pref of the main ip rule
EXCLUDE_RULE_PRIO=$((RULE_PRIO - 10))         # pref of the exclude rules (higher priority)
HOST_VETH_IP="10.200.<OCTET>.1"; NS_VETH_IP="10.200.<OCTET>.2"; NS_SUBNET="10.200.<OCTET>.0/30"

PING_GROUP_RANGE=""  # host value of net.ipv4.ping_group_range for step 4'
                     # (copied only into the netns; dies together with the netns — no cleanup flag needed)

# created-object flags for cleanup (CREATED_NETNS, CREATED_VETH,
# CREATED_NETNS_DNS, ADDED_NAT_RULE, ADDED_FWD_RULE1/2, ADDED_RULE,
# ADDED_EXCLUDE_RULE, ADDED_ROUTE, CHANGED_FORWARD)
# + IP_FORWARD_ORIG (original value of net.ipv4.ip_forward), KEEPALIVE_PID
```

Route line format (`--route`): `[<addr>] (via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>)`, where `addr` is an IPv4 address, a CIDR subnet (`/0`–`/32`), a domain or the keyword `default`; an omitted `addr`, `0.0.0.0` and `0.0.0.0/0` mean the default route; `gw` is an IPv4 address; `if` is a host interface name; at least one of `via`/`dev` is required (the missing interface for a via-only route is determined before sudo via `ip -4 route get <gw>`); the `gw` synonym of `via` is not supported. Exclude format (`--exclude`): exactly one token `<addr|domain>`.

## Flow

```
arguments + validation + resolution (--route parsed into ROUTE_ADDR/ROUTE_TAIL,
per-route resolution: `ip -4 route get <gw>` for a via-only route,
`ip link show` for an explicit dev; --exclude validated; --dns deduplicated
and validated (IPv4 only); domains of
--route/--exclude resolved on the host (unprivileged `nslookup`, pre-sudo) —
an invalid line or an unresolvable domain -> die, nothing is created)
        │
        ▼
no --route given? -> automatic catch-all exception 0.0.0.0/0
(all netns traffic follows the host's system routing)
        │
        ▼
sudo -v + keepalive process (keeps sudo rights for the whole run)
        │
        ▼
1. ip netns add          2. veth pair (host <-> netns)
3. addresses 10.200.X.1/2, link up, lo up
4. default route in the netns -> host side of the veth
4'. copy of the host value net.ipv4.ping_group_range into the netns
    (ping/traceroute -I for an unprivileged user — as on the host;
    a failure is non-fatal, the host is not affected)
5. DNS: with --dns — a per-netns /etc/netns/<name>/resolv.conf is written
   (bind-mounted over /etc inside the netns by `ip netns exec`); without —
   the host's resolver configuration as is (nothing is configured)
6. sysctl ip_forward=1 (+remember the original value)
7. iptables: NAT MASQUERADE from NS_SUBNET (no -o) + 2 FORWARD rules (veth only)
8. policy routing (only with --route): ip rule pref RULE_PRIO
   from NS_SUBNET table TABLE_ID (the table is populated in step 9)
9. add_extra_routes: --route entries into TABLE_ID
   (a /32 per A address of a domain pre-resolved on the host)
10. add_exclude_rules: ip rule pref EXCLUDE_RULE_PRIO from NS_SUBNET to <addr> table main
        │
        ▼
ip netns exec <netns> sudo -E -u <user> -- COMMAND
        │
        ▼ (EXIT/INT/TERM at any moment)
cleanup(): ip rule del (main + excludes), flush TABLE_ID, iptables -D,
           ip netns delete (removes the veth pair),
           rm -rf /etc/netns/<name> (only with --dns),
           restore ip_forward; exit with the command's code
```

## Invariants

- Host routing is never modified: all changes (`ip rule`, `TABLE_ID`, iptables) affect only traffic with a source in `NS_SUBNET`, or are added as forwarding rules for it.
- Netns traffic not covered by any `--route` entry — and all traffic when no `--route` is given — follows the host's system routing (the main table).
- Every route with `via` carries an explicit host interface after the pre-sudo resolution (`ip -4 route get <gw>`).
- The specified host interface is never moved into the netns; host↔netns connectivity is provided by the veth pair.
- Inside the netns the host value of `net.ipv4.ping_group_range` is in effect (a copy, step 4'): the set of ICMP/UDP socket capabilities of an unprivileged user (`ping`, `traceroute -I`) matches the host. The host value is never modified; a copy failure is a non-fatal warning, and the value dies together with the netns.
- Validation of all `--route`/`--route-file`/`--exclude`/`--exclude-file` is performed before sudo is called and the environment is created; an invalid line terminates the script with diagnostics and exit code 1.
- Domains in `--route`/`--exclude` are resolved on the host, before sudo (before the netns and any privileged action), using the host's DNS resolver configuration; all A records are taken, IPv6 is ignored; a domain without A records terminates the script before anything is created.
- Without `--dns` the netns uses the host's DNS resolver configuration (step 5 creates no per-netns override); with `--dns` the only override is the per-netns `/etc/netns/<name>/resolv.conf` (a `nameserver` line per entry after duplicate removal, IPv4 addresses only), bind-mounted over `/etc` inside the netns by `ip netns exec` — the host's `/etc` is never touched.
- Servers given via `--dns` never participate in resolving `--route`/`--exclude` domains: that resolution always happens on the host, with the host's resolver configuration, before sudo.
- `/etc/netns/<name>/` is the only host-filesystem entry the script ever creates (only when `--dns` is given); its name is derived from the script PID, and cleanup removes the directory on any way of termination.
- For addresses/subnets in `--route`, `ip route replace` is used (robust against an overlapping default route and repeated runs), for domains — `ip route add <ip>/32`.
- The script runs with `set -euo pipefail` and a cleanup trap on EXIT/INT/TERM; cleanup is idempotent (best-effort, deletion errors are suppressed) and uses the created-object flags.
- Parallel runs are safe: netns/veth/table/priorities are generated from the PID; runs with matching `PID % 100` may share a table — in that case the table is shared, but routes added via `replace` do not conflict.
- The tool is limited to IPv4: gateway, DNS, routes, exceptions — IPv4 only.

## Configuration

Parameters are set only via CLI options (there are no configuration files):

| Option | Default | Allowed values |
|---|---|---|
| `--route` / `--route-file` | — (no entries: all netns traffic follows the host's system routing) | `[<addr>] (via <gw> \| dev <if> \| via <gw> dev <if> \| dev <if> via <gw>)` (multiple times; files: a line = a route, `#` — a comment) |
| `--exclude` / `--exclude-file` | — | `<addr\|domain>` (multiple times; files: a line = an exception) |
| `--dns` | — (no entries: the netns sees the host's current `/etc/resolv.conf`) | an IPv4 address of a DNS server (multiple times; exact duplicates are dropped, the order is preserved — the first server is the primary one; more than 3 entries — a WARNING, glibc-based resolvers use only the first 3; written as `nameserver` lines into `/etc/netns/<name>/resolv.conf`) |

There are no other options: the namespace name and all identifiers are generated from the script PID; the command runs as `$SUDO_USER` (or the current user, if the script was not invoked via sudo).

Required utilities (checked via `need_cmd`): `ip` (iproute2), `iptables`, `sudo`; `nslookup` — only with domains in `--route`/`--exclude`; `mkdir`/`tee`/`rm` — only with `--dns`.

## Extension Points

- A new target type in `--route`/`--exclude` (e.g. IPv6) — extended in parallel in `parse_route`/`validate_excludes` (syntax before sudo), `resolve_domains` (resolution on the host, before sudo) and `add_extra_routes`/`add_exclude_rules` (application during the build).
- A richer per-netns `resolv.conf` (`search`/`options` directives, IPv6 DNS servers) or new `--dns` entry formats — extended in `validate_dns_servers` (syntax before sudo) and the step-5 writer; `/etc/netns/<name>/` must remain the only host-filesystem entry and must be removed by cleanup.
- A new routing rule — added in the step 8–10 block into `TABLE_ID` with a corresponding `ADDED_*` flag and a mirrored deletion in `cleanup()`.
- A detailed description of the environment lifecycle — [environment-lifecycle.md](environment-lifecycle.md).

## Related Specs

- [environment-lifecycle.md](environment-lifecycle.md) — the step-by-step lifecycle: creation, policy routing, cleanup
- [../../contracts/netns-run-host-system.md](../../contracts/netns-run-host-system.md) — the contract with the host's system utilities (ip/iptables/sysctl/sudo)
- [../../architecture/repo-layout.md](../../architecture/repo-layout.md) — the rules for adding tools to the collection
