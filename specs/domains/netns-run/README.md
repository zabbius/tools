# netns-run

## Purpose

`netns-run` runs an arbitrary command in an isolated network namespace (netns) and forces all of its network traffic through a given gateway, reachable via one of the host's interfaces. The host's own routing is not changed. Typical use case — running an application through a different channel (a second provider, a VPN gateway, a separate network card). After the command finishes, the entire created environment is removed automatically.

## Key Files

- `network/netns-run/netns-run.sh` — the single implementation file: argument parsing, validation, environment setup and cleanup, running the command
- `network/netns-run/README.md` — user documentation (usage, options, examples, limitations)

## Core Types

The script is procedural bash; its "types" are global arrays and state scalars (from `network/netns-run/netns-run.sh`):

```bash
EXTRA_ROUTES=()    # "<addr> via <gw> [dev <iface>]" lines from --route / --route-file
EXCLUDED_ADDRS=()  # "<addr|domain>" lines from --exclude / --exclude-file

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
# ADDED_NAT_RULE, ADDED_FWD_RULE1/2, ADDED_RULE, ADDED_EXCLUDE_RULE,
# ADDED_ROUTE, ADDED_LOCAL_ROUTE, CHANGED_FORWARD, CREATED_RESOLV_DIR)
# + IP_FORWARD_ORIG (original value of net.ipv4.ip_forward), KEEPALIVE_PID
```

Route line format (`--route`): `<addr> via <gw> [dev <iface>]`, where `addr` is an IPv4 address, a CIDR subnet (`/0`–`/32`) or a domain; `gw` is an IPv4 address; `gw` is a synonym for `via`; after the gateway only `dev <iface>` is allowed. Exclude format (`--exclude`): exactly one token `<addr|domain>`.

## Flow

```
arguments + validation (--route/--exclude before sudo; an invalid line -> die)
        │
        ▼
gateway/interface pair determination (-g <-> -i automatically via ip route)
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
5. DNS: the host resolv.conf as is (or /etc/netns/<name>/resolv.conf with -d)
6. sysctl ip_forward=1 (+remember the original value)
7. iptables: NAT MASQUERADE from NS_SUBNET to HOST_IFACE + 2 FORWARD rules
8. policy routing: ip route (on-link HOST_SUBNET + default via GATEWAY)
   into TABLE_ID + ip rule pref RULE_PRIO from NS_SUBNET table TABLE_ID
9. add_extra_routes: --route into TABLE_ID (domains resolved INSIDE the netns, a /32 per A address)
10. add_exclude_rules: ip rule pref EXCLUDE_RULE_PRIO from NS_SUBNET to <addr> table main
        │
        ▼
ip netns exec <netns> sudo -E -u <user> -- COMMAND
        │
        ▼ (EXIT/INT/TERM at any moment)
cleanup(): ip rule del (main + excludes), flush table, iptables -D,
           ip netns delete (removes the veth pair), rm -rf /etc/netns/<name>,
           restore ip_forward; exit with the command's code
```

## Invariants

- Host routing is never modified: all changes (`ip rule`, `TABLE_ID`, iptables) affect only traffic with a source in `NS_SUBNET`, or are added as forwarding rules for it.
- The specified host interface is never moved into the netns; host↔netns connectivity is provided by the veth pair.
- Inside the netns the host value of `net.ipv4.ping_group_range` is in effect (a copy, step 4'): the set of ICMP/UDP socket capabilities of an unprivileged user (`ping`, `traceroute -I`) matches the host. The host value is never modified; a copy failure is a non-fatal warning, and the value dies together with the netns.
- Validation of all `--route`/`--route-file`/`--exclude`/`--exclude-file` is performed before sudo is called and the environment is created; an invalid line terminates the script with diagnostics and exit code 1.
- Domains in `--route`/`--exclude` are resolved inside the netns (after DNS and the default route are up), using the DNS servers from `-d`; all A records are taken, IPv6 is ignored.
- For addresses/subnets in `--route`, `ip route replace` is used (robust against an overlapping default route and repeated runs), for domains — `ip route add <ip>/32`.
- The script runs with `set -euo pipefail` and a cleanup trap on EXIT/INT/TERM; cleanup is idempotent (best-effort, deletion errors are suppressed) and uses the created-object flags.
- Parallel runs are safe: netns/veth/table/priorities are generated from the PID; runs with matching `PID % 100` may share a table — in that case the table is shared, but routes added via `replace` do not conflict.
- The tool is limited to IPv4: gateway, DNS, routes, exceptions — IPv4 only.

## Configuration

Parameters are set only via CLI options (there are no configuration files):

| Option | Default | Allowed values |
|---|---|---|
| `-g GATEWAY` | auto from `-i` (`ip route show default dev IFACE`) | IPv4 address |
| `-i IFACE` | auto from `-g` (`ip route get GATEWAY`) | an existing host interface |
| `-n NETNS` | `netns-<PID % 65536>` | namespace name |
| `-d DNS` | the host resolv.conf as is (no bind mount of `/etc/netns/...`) | comma-separated IPv4 addresses |
| `-u USER` | `$SUDO_USER` or the current user | user name |
| `--route` / `--route-file` | — | `<addr> via <gw> [dev <iface>]` (multiple times; files: a line = a route, `#` — a comment) |
| `--exclude` / `--exclude-file` | — | `<addr\|domain>` (multiple times; files: a line = an exception) |

Required utilities (checked via `need_cmd`): `ip` (iproute2), `iptables`, `sudo`; `nslookup` — only with domains in `--route`/`--exclude`.

## Extension Points

- A new target type in `--route`/`--exclude` (e.g. IPv6) — extended in parallel in `validate_routes`/`validate_excludes` (syntax before sudo) and `add_extra_routes`/`add_exclude_rules` (application after DNS is up).
- A new routing rule — added in the step 8–10 block into `TABLE_ID` with a corresponding `ADDED_*` flag and a mirrored deletion in `cleanup()`.
- A detailed description of the environment lifecycle — [environment-lifecycle.md](environment-lifecycle.md).

## Related Specs

- [environment-lifecycle.md](environment-lifecycle.md) — the step-by-step lifecycle: creation, policy routing, cleanup
- [../../contracts/netns-run-host-system.md](../../contracts/netns-run-host-system.md) — the contract with the host's system utilities (ip/iptables/sysctl/sudo)
- [../../architecture/repo-layout.md](../../architecture/repo-layout.md) — the rules for adding tools to the collection
