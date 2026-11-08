# Contract: netns-run <-> Host System

## Boundary Rule

The script `network/netns-run/netns-run.sh` invokes host system utilities (`ip`, `iptables`, `sysctl`, `nslookup`, `sudo`) only via `sudo` for privileged operations; the script does not modify the host filesystem at all (read-only access to `/proc/sys`) and is not allowed to change host routing outside the objects it creates itself (table `TABLE_ID`, `ip rule` with its priorities, iptables rules with its match criteria).

## Interfaces

| Interface | Package/Binary | Consumed By | Purpose |
| --------- | -------------- | ----------- | ------- |
| `ip netns add/delete <name>` | iproute2 `ip` | setup/teardown | create/delete the network namespace |
| `ip link add/del <veth>` + `set <peer> netns <name>` | iproute2 `ip` | setup/teardown | host↔netns veth pair |
| `ip addr add`, `link set up` (host and inside netns) | iproute2 `ip` | setup | veth addressing and bringing up, `lo` |
| `ip route .../table <T>`, `ip rule add/del` | iproute2 `ip` | setup/teardown | policy routing (table `100..199`, pref `20000+`, exceptions into `main`) |
| `ip -4 route get <gw>` | iproute2 `ip` | route resolution (before sudo) | determine the egress interface for a via-only route (`--route "... via <gw>"`), one query per route |
| `ip link show <if>` | iproute2 `ip` | route resolution (before sudo) | existence check of an interface given explicitly (`dev <if>`) |
| `ip route replace <dst> <via/dev tail> table <T>` / `ip route add <ip>/32 <via/dev tail> table <T>` | iproute2 `ip` | setup (step 9) | populate `TABLE_ID` from `--route` entries (`replace` — an address/CIDR/`default`; `add /32` — each resolved domain address) |
| `iptables -t nat -A/D POSTROUTING -s <NS_SUBNET> -j MASQUERADE` | `iptables` | setup/teardown | NAT netns traffic outbound, regardless of the outgoing interface |
| `iptables -A/D FORWARD -i <VETH_HOST> -j ACCEPT` and `-o <VETH_HOST> -m state --state ESTABLISHED,RELATED -j ACCEPT` | `iptables` | setup/teardown | forwarding to/from the netns veth in both directions, regardless of the peer interface |
| `sysctl -qw net.ipv4.ip_forward` | `sysctl` / `/proc/sys` | setup/teardown | enable forwarding, restore the original value |
| `ip netns exec <ns> sysctl -qw net.ipv4.ping_group_range=<host value>` | `sysctl` / `/proc/sys` | setup (step 4') | copy of the host value into the netns only: ICMP/UDP sockets for the unprivileged user (`ping`, `traceroute -I`) — as on the host; the host is not touched, the value dies with the netns |
| `ip netns exec <ns> nslookup <domain>` | `nslookup` | steps 9–10 | domain resolution inside the netns (A records) |
| `sudo` (`as_root`, `sudo -v`, keepalive `sudo -n true`, `ip netns exec ... sudo -E -u <user>`) | `sudo` | all privileged steps | root privileges + running the command on behalf of the user |

## Initialization

- Check that `ip`, `sudo`, `iptables` are present in PATH (`need_cmd`) before any privileged actions; `nslookup` is required only when domains appear in `--route`/`--exclude`.
- `sudo -v` caches the credentials; a background keepalive (`sudo -n true` every 60s, `KEEPALIVE_PID`) keeps them fresh for as long as the command runs.
- Before the first privileged action every `--route` line is parsed and resolved: the egress interface for a via-only route comes from `ip -4 route get <gw>`, an explicitly given `dev` is existence-checked; after this stage every via-route carries an explicit dev (see [Route Resolution](../domains/netns-run/environment-lifecycle.md#route-resolution)).

## Data Flow Across Boundary

Inward (script → host): sequences of `ip`/`iptables`/`sysctl` commands with parameters derived from the normalized `--route` fragments (`ROUTE_ADDR`/`ROUTE_TAIL`) and generated from the PID.
Outward (host → script): stdout of one-line `ip` queries (`ip -4 route get <gw>` — the `dev` field) and `nslookup`, parsed with awk; command exit codes; `/proc/sys/net/ipv4/ip_forward` (read with cat); `/proc/sys/net/ipv4/ping_group_range` (reading the host value with tab→space normalization, step 4').
To the command being run: a ready netns environment with a default route via the host side of the veth, the host's DNS resolver configuration unchanged, and policy routing that overrides the host's system routing exactly for the destinations given in `--route` (the remaining destinations follow the host's main table).

## Error Propagation

- Missing utility, invalid arguments, a route gateway unreachable from any host interface, a nonexistent interface, failed domain resolution → `die` (exit 1, message `[netns-run] ERROR: ...`) — always before the environment is created, where possible.
- A system command failing during setup under `set -e` terminates the script; the EXIT trap performs a best-effort teardown of what was created (deletion errors are suppressed with `2>/dev/null`).
- Return code: the script exits with the exit code of the command it ran (`APP_EC`), not with the teardown code.

## Breaking Change Checklist

If you change X, you MUST also update Y:

- Changing an output format that awk parsing relies on (`ip -4 route get`, `nslookup`) → check `resolve_routes`, `add_extra_routes`, `add_exclude_rules` and update [environment-lifecycle](../domains/netns-run/environment-lifecycle.md).
- A new system utility in the script → add a `need_cmd` check and a row to the Interfaces table of this contract.
- Changing the numbering scheme (`TABLE_ID`, `RULE_PRIO`, `EXCLUDE_RULE_PRIO`, the `10.200.X.0/30` subnet) → update identifier generation, teardown (deletion by the old priorities) and both domain specs; make sure the ranges do not conflict with typical host configuration.
- Changing the set of iptables rules → mirror the change in the add (step 7) and delete (teardown) blocks and the `ADDED_*` flags; verify operation without stateful rules (conntrack unavailable → the incoming ESTABLISHED,RELATED rule will not work).
- Removing/renaming a CLI option → synchronously update the `usage`, the tool's README and the domain specs.
- Changing per-route interface resolution (`ip -4 route get <gw>`, the `dev` existence check, the before-sudo ordering) → update `resolve_routes` and Route Resolution in [environment-lifecycle](../domains/netns-run/environment-lifecycle.md).
