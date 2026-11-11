# Environment Lifecycle (netns-run)

## Role

The full lifecycle of the temporary network environment that `netns-run.sh` creates around the command being run: identifier generation, per-route resolution, bringing up the netns/veth/policy routing/NAT, running the command, and guaranteed cleanup on any way of termination.

## Key Files

- `network/netns-run/netns-run.sh` — all lifecycle logic: identifier generation, the `cleanup`, `resolve_routes`, `resolve_domains`, `validate_dns_servers`, `add_extra_routes`, `add_exclude_rules` functions, the main setup block (steps 1–10)

## Behavior

### Identifier Generation (from the script PID `$$`)

```
PID_SUFFIX  = $$ % 65536
OCTET       = ($$ % 250) + 1                # third octet of the veth subnet, 1..250
NETNS_NAME  = netns-<PID_SUFFIX>
VETH_HOST   = vh-<PID_SUFFIX>;  VETH_NS = vn-<PID_SUFFIX>
TABLE_ID    = 100 + (PID_SUFFIX % 100)      # 100..199
RULE_PRIO   = 20000 + (PID_SUFFIX % 1000)
EXCLUDE_RULE_PRIO = RULE_PRIO - 10          # strictly higher priority than the main rule
HOST_VETH_IP = 10.200.<OCTET>.1;  NS_VETH_IP = 10.200.<OCTET>.2
NS_SUBNET   = 10.200.<OCTET>.0/30
```

### Route Resolution

Before sudo, each `--route` line is parsed into the parallel arrays `ROUTE_ADDR`/`ROUTE_TAIL` (the grammar `[<addr>] (via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>)`; `addr` is an IPv4 address, a CIDR subnet `/0`–`/32`, a domain or the keyword `default`; `0.0.0.0`, `0.0.0.0/0` and an omitted `addr` are normalized to `default`; the `gw` synonym of `via` is not supported). Then `resolve_routes` runs per route:

- a route with `via` but no `dev` — the interface is determined via `ip -4 route get <gw>` (the field after `dev`); an unreachable gateway or no `dev` in the output → `die`;
- a route with an explicit `dev` — an existence check `ip link show <dev>`; a missing interface → `die`.

After this stage every via-route carries an explicit dev. With no `--route` given at all, a catch-all exception `0.0.0.0/0` is registered through the regular excludes mechanism: all netns traffic follows the host's main routing table.

Then `resolve_domains` runs (still before sudo): every domain in `ROUTE_ADDR`/`EXCLUDED_ADDRS` is resolved on the host with an unprivileged `nslookup` (all unique A records, IPv6 answers ignored; `need_cmd nslookup` fires only when at least one domain is present). The resolved addresses are stored space-separated in the parallel arrays `ROUTE_IPS[i]`/`EXCLUDED_IPS[i]` ("" for default/IPv4/CIDR entries); the original entries stay in `ROUTE_ADDR`/`EXCLUDED_ADDRS` and serve as labels in log messages. A domain without A records → `die` — before the sudo password prompt and before any netns object is created.

Servers given via `--dns` do not participate in this resolution: domains of `--route`/`--exclude` are always resolved with the host's resolver configuration (the host's `/etc/resolv.conf`), never with the `--dns` servers — the netns and its DNS override do not exist yet at this stage. The `--dns` entries themselves are handled pre-sudo too (`validate_dns_servers`): exact duplicates are dropped with the order preserved, every entry must be an IPv4 address (domains and CIDR subnets are rejected), and `mkdir`/`tee`/`rm` are checked via `need_cmd` only when entries exist.

### Environment State

```
[arguments/validation] -> [sudo + keepalive] -> [environment build: steps 1..10]
        -> [run command] -> [cleanup] -> [exit with the command's code]
```

The cleanup trap is installed on EXIT/INT/TERM from the moment the build starts; any build step failure under `set -e` leads to cleanup of the objects already created (the `CREATED_*`/`ADDED_*`/`CHANGED_*` flags mark what exactly was created).

### Build Steps (in execution order)

| Step | Action | Cleanup flag |
|---|---|---|
| 1 | `ip netns add NETNS_NAME` | `CREATED_NETNS` |
| 2 | `ip link add VETH_HOST type veth peer name VETH_NS`; `ip link set VETH_NS netns` | `CREATED_VETH` |
| 3 | the addresses `HOST_VETH_IP`/`NS_VETH_IP`, `link up`, `lo up` (inside the netns) | (covered by veth/netns) |
| 4 | `ip netns exec ... ip route add default via HOST_VETH_IP dev VETH_NS` | (inside the netns) |
| 4' | a copy of `net.ipv4.ping_group_range`: reading the host's `/proc/sys/net/ipv4/ping_group_range` (tab→space) into `PING_GROUP_RANGE` under `[[ -r ]]`; writing into the netns — `ip netns exec ... sysctl -qw net.ipv4.ping_group_range=...` | — |
| 5 | DNS: with `--dns` — `mkdir -p /etc/netns/NETNS_NAME` and writing `resolv.conf` (a `nameserver <addr>` line per `DNS_SERVERS` entry — pre-deduplicated, order preserved; more than 3 entries — a `WARNING`: glibc-based resolvers use only the first 3; via `as_root tee`; a pre-existing directory or a write failure → `die`); without `--dns` — nothing is configured (no per-netns override is created), processes inside the netns see the host's current DNS resolver configuration as is. `ip netns exec` bind-mounts every file from `/etc/netns/<name>/` over the same-named path in `/etc` inside the netns's own mount namespace — the host's `/etc` is not affected | `CREATED_NETNS_DNS` |
| 6 | reading `/proc/sys/net/ipv4/ip_forward`; if it is not 1 — `sysctl -qw ...=1` | `CHANGED_FORWARD` + `IP_FORWARD_ORIG` |
| 7 | `iptables -t nat -A POSTROUTING -s NS_SUBNET -j MASQUERADE` (regardless of the outgoing interface); two FORWARD rules (`-i VETH_HOST -j ACCEPT`; `-o VETH_HOST -m state --state ESTABLISHED,RELATED -j ACCEPT`) | `ADDED_NAT_RULE`, `ADDED_FWD_RULE1/2` |
| 8 | policy routing — only when `--route` entries exist: `ip rule add pref RULE_PRIO from NS_SUBNET table TABLE_ID`; the table itself is populated in step 9 (no routes are added here) | `ADDED_ROUTE`, `ADDED_RULE` |
| 9 | `add_extra_routes` from `ROUTE_ADDR`/`ROUTE_TAIL`/`ROUTE_IPS`: for an address/subnet/`default` — `ip route replace <addr> <tail> table TABLE_ID`; for a domain — `ip route add <ip>/32 <tail>` per A address pre-resolved on the host (before sudo) | `ADDED_ROUTE` |
| 10 | `add_exclude_rules`: for each exception `ip rule add pref EXCLUDE_RULE_PRIO from NS_SUBNET to <addr> table main`; with no `--route` a catch-all `0.0.0.0/0` is added automatically; domains — one rule per A address pre-resolved on the host (before sudo) | `ADDED_EXCLUDE_RULE` |

### Running the Command

```
as_root ip netns exec "$NETNS_NAME" sudo -E -u "$RUN_AS_USER" -- "$@"
```

`set +e` around the launch: the command's exit code is preserved and returned as the script's exit code (after the cleanup). `sudo -E` preserves the user's environment.

### Cleanup (cleanup, on EXIT/INT/TERM)

Order (each step — only if the corresponding flag is set; all deletions are best-effort `2>/dev/null`):

1. Kill the sudo keepalive process (`KEEPALIVE_PID`).
2. `ip rule del pref RULE_PRIO` (the main rule); the exception rules are deleted in a `while ip rule del pref EXCLUDE_RULE_PRIO` loop (several rules may exist — one per address of a domain plus the catch-all `0.0.0.0/0`).
3. `ip route flush table TABLE_ID` (only when `--route` entries were given).
4. `iptables -D` of both FORWARD rules and the NAT rule.
5. `ip netns delete` (which also removes the veth pair) or, if the netns was not created, `ip link delete VETH_HOST`.
6. `rm -rf /etc/netns/NETNS_NAME` (only with `--dns`, `CREATED_NETNS_DNS`) — removal of the per-netns DNS override, the only host-filesystem entry the script ever creates.
7. Restoring `net.ipv4.ip_forward` = `IP_FORWARD_ORIG`, if it was changed.
8. `exit` with the preserved code.

## Error Handling

- All checks before the environment is created (`die`): missing utilities (`ip`, `sudo`, `iptables`), an invalid `--route` line (the `[<addr>] via|dev ...` grammar: the `addr` format — an IPv4 address, a CIDR prefix 0–32 or a domain —, duplicate or missing `via`/`dev`), an invalid `--exclude` line (exactly one token, the `addr` format), an invalid `--dns` entry (only an IPv4 address is accepted — domains and CIDR subnets are rejected), unreadable/empty `--route-file`/`--exclude-file` — the script terminates with code 1 and a message of the form `[netns-run] ERROR: ...`; the environment is not created.
- Failures inside the build under `set -e` interrupt the script; the EXIT trap runs cleanup of the created objects.
- Route resolution failures (before sudo, the environment is not created): a gateway unreachable from any host interface, no `dev` in the `ip route get` output, a nonexistent interface given via `dev` — `die`.
- A failed `ip route replace` into `TABLE_ID` or an exception-rule add for an address — `die`; a failed `/32` route or exception-rule add for a single address of a domain — a warning (the entry may already exist), the build continues.
- A failed domain resolution in `--route`/`--exclude` (no IPv4 (A) records, or `nslookup` unavailable) — `die` on the host, before sudo and before anything is created.
- Step 4' is best-effort: an unreadable host `/proc/sys/net/ipv4/ping_group_range` or a failed write of the value into the netns do not interrupt the script — `[netns-run] WARNING`, the build continues (ping and `traceroute -I` may not work for an unprivileged user inside the netns).
- Step 5 with `--dns` is strict: a pre-existing `/etc/netns/NETNS_NAME` (a stale leftover of a previous run with the same PID), a failed `mkdir` or a failed `resolv.conf` write → `die`; the EXIT trap removes the directory via `CREATED_NETNS_DNS` (the flag is set only after a successful `mkdir`, so a directory that existed before the run is never deleted).
- Errors during cleanup are suppressed: cleanup is idempotent and must not mask the command's exit code.
- Code return: the script terminates with the exit code of the launched command (`APP_EC`), not with the cleanup code.

## Invariants

- Cleanup runs on any way of termination (EXIT/INT/TERM) and removes exactly the objects created by this run (the `CREATED_*`/`ADDED_*`/`CHANGED_*` flags).
- The exclude rules (`EXCLUDE_RULE_PRIO`) always have a higher priority (a lower pref) than the main netns rule (`RULE_PRIO`).
- Domain resolution is performed on the host, before any privileged action (before `sudo -v` and before the netns is created); build steps 9–10 only apply the already resolved addresses.
- Without `--dns` the netns uses the host's DNS resolver configuration (step 5 creates no per-netns override); with `--dns` the only override is the per-netns `/etc/netns/<name>/resolv.conf` written in step 5 and bind-mounted over `/etc` inside the netns by `ip netns exec`.
- Servers given via `--dns` never participate in resolving `--route`/`--exclude` domains: that resolution always happens on the host, with the host's resolver configuration, before any privileged action.
- `/etc/netns/<name>/` is the only host-filesystem entry the script ever creates (only with `--dns`); it is named from the run's PID and removed by cleanup (`CREATED_NETNS_DNS`) on any way of termination.
- Netns traffic that matches no route in `TABLE_ID` — including all traffic when no `--route` was given (neither the table nor the rule is created) — follows the host's main routing table.
- After route resolution every via-route carries an explicit host interface; the resolution completes before the first privileged action.
- Cleanup does not mask the command's exit code.
- The identifiers (`NETNS_NAME`, `VETH_*`, `TABLE_ID`, `RULE_PRIO`, the subnet `10.200.X.0/30`) are deterministic from the run's PID; parallel runs with different PIDs do not conflict over veth names or subnets.

## Related Specs

- [README.md](README.md) — the domain overview: purpose, options, invariants
- [../../contracts/netns-run-host-system.md](../../contracts/netns-run-host-system.md) — the system calls through which the lifecycle steps are implemented
