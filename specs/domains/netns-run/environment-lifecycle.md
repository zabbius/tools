# Environment Lifecycle (netns-run)

## Role

The full lifecycle of the temporary network environment that `netns-run.sh` creates around the command being run: identifier generation, bringing up the netns/veth/DNS/policy routing/NAT, running the command, and guaranteed cleanup on any way of termination.

## Key Files

- `network/netns-run/netns-run.sh` — all lifecycle logic: identifier generation, the `cleanup`, `add_extra_routes`, `add_exclude_rules` functions, the main setup block (steps 1–10)

## Behavior

### Identifier Generation (from the script PID `$$`)

```
PID_SUFFIX  = $$ % 65536
OCTET       = ($$ % 250) + 1                # third octet of the veth subnet, 1..250
NETNS_NAME  = netns-<PID_SUFFIX>            # or -n
VETH_HOST   = vh-<PID_SUFFIX>;  VETH_NS = vn-<PID_SUFFIX>
TABLE_ID    = 100 + (PID_SUFFIX % 100)      # 100..199
RULE_PRIO   = 20000 + (PID_SUFFIX % 1000)
EXCLUDE_RULE_PRIO = RULE_PRIO - 10          # strictly higher priority than the main rule
HOST_VETH_IP = 10.200.<OCTET>.1;  NS_VETH_IP = 10.200.<OCTET>.2
NS_SUBNET   = 10.200.<OCTET>.0/30
```

### Gateway/Interface Pair Auto-Detection

At least one of `-g`/`-i` is required:

- `-g` given → `HOST_IFACE` = `ip -4 route get GATEWAY` (awk parsing of the field after `dev`);
- `-i` given → `GATEWAY` = the gateway from `ip -4 route show default dev IFACE`.

Additionally `HOST_SUBNET` is determined (the interface's on-link subnet, `scope link`); if it cannot be determined — a warning, and all netns traffic goes through the gateway, including the local subnet.

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
| 5 | DNS: without `-d` nothing (the host resolv.conf is visible as is); with `-d` — `/etc/netns/<name>/resolv.conf` with `nameserver` entries | `CREATED_RESOLV_DIR` |
| 6 | reading `/proc/sys/net/ipv4/ip_forward`; if it is not 1 — `sysctl -qw ...=1` | `CHANGED_FORWARD` + `IP_FORWARD_ORIG` |
| 7 | `iptables -t nat -A POSTROUTING -s NS_SUBNET -o HOST_IFACE -j MASQUERADE`; two FORWARD rules (outgoing ACCEPT; incoming ESTABLISHED,RELATED) | `ADDED_NAT_RULE`, `ADDED_FWD_RULE1/2` |
| 8 | policy routing: `ip route add HOST_SUBNET dev HOST_IFACE table TABLE_ID` (if determined); `ip route add default via GATEWAY dev HOST_IFACE table TABLE_ID`; `ip rule add pref RULE_PRIO from NS_SUBNET table TABLE_ID` | `ADDED_LOCAL_ROUTE`, `ADDED_ROUTE`, `ADDED_RULE` |
| 9 | `add_extra_routes`: `--route` into TABLE_ID; for addresses/subnets `ip route replace`, for domains resolution inside the netns (`nslookup`, all A records, IPv6 ignored) + `ip route add <ip>/32` | `ADDED_ROUTE` |
| 10 | `add_exclude_rules`: for each exception `ip rule add pref EXCLUDE_RULE_PRIO from NS_SUBNET to <addr> table main`; domains — one rule per resolved A address | `ADDED_EXCLUDE_RULE` |

### Running the Command

```
as_root ip netns exec "$NETNS_NAME" sudo -E -u "$RUN_AS_USER" -- "$@"
```

`set +e` around the launch: the command's exit code is preserved and returned as the script's exit code (after the cleanup). `sudo -E` preserves the user's environment.

### Cleanup (cleanup, on EXIT/INT/TERM)

Order (each step — only if the corresponding flag is set; all deletions are best-effort `2>/dev/null`):

1. Kill the sudo keepalive process (`KEEPALIVE_PID`).
2. `ip rule del pref RULE_PRIO` (the main rule); the exclude rules are deleted in a `while ip rule del pref EXCLUDE_RULE_PRIO` loop (duplicates may exist from several addresses of one domain).
3. `ip route flush table TABLE_ID`.
4. `iptables -D` of both FORWARD rules and the NAT rule.
5. `ip netns delete` (which also removes the veth pair) or, if the netns was not created, `ip link delete VETH_HOST`.
6. `rm -rf /etc/netns/<name>` (if a resolv.conf was created).
7. Restoring `net.ipv4.ip_forward` = `IP_FORWARD_ORIG`, if it was changed.
8. `exit` with the preserved code.

## Error Handling

- All checks before the environment is created (`die`): missing utilities (`ip`, `sudo`, `iptables`), an invalid gateway IPv4, invalid `--route`/`--exclude` lines (the `<addr>` format, a CIDR prefix 0–32, a domain, a required gateway, a `dev` tail), unreadable/empty `--route-file`/`--exclude-file` — the script terminates with code 1 and a message of the form `[netns-run] ERROR: ...`; the environment is not created.
- Failures inside the build under `set -e` interrupt the script; the EXIT trap runs cleanup of the created objects.
- An unreachable gateway / no default route on the interface / an undetermined on-link subnet — `die` or a warning (see the auto-detection step).
- A failed domain resolution in `--route`/`--exclude` — `die` (after DNS is up inside the netns).
- Step 4' is best-effort: an unreadable host `/proc/sys/net/ipv4/ping_group_range` or a failed write of the value into the netns do not interrupt the script — `[netns-run] WARNING`, the build continues (ping and `traceroute -I` may not work for an unprivileged user inside the netns).
- Errors during cleanup are suppressed: cleanup is idempotent and must not mask the command's exit code.
- Code return: the script terminates with the exit code of the launched command (`APP_EC`), not with the cleanup code.

## Invariants

- Cleanup runs on any way of termination (EXIT/INT/TERM) and removes exactly the objects created by this run (the `CREATED_*`/`ADDED_*`/`CHANGED_*` flags).
- The exclude rules (`EXCLUDE_RULE_PRIO`) always have a higher priority (a lower pref) than the main netns rule (`RULE_PRIO`).
- Domain resolution is performed only after DNS and the default route are up inside the netns (steps 9–10 after steps 4–5).
- Cleanup does not mask the command's exit code.
- The identifiers (`NETNS_NAME`, `VETH_*`, `TABLE_ID`, `RULE_PRIO`, the subnet `10.200.X.0/30`) are deterministic from the run's PID; parallel runs with different PIDs do not conflict over veth names or subnets.

## Related Specs

- [README.md](README.md) — the domain overview: purpose, options, invariants
- [../../contracts/netns-run-host-system.md](../../contracts/netns-run-host-system.md) — the system calls through which the lifecycle steps are implemented
