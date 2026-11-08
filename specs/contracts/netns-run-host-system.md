# Contract: netns-run <-> Host System

## Boundary Rule

The script `network/netns-run/netns-run.sh` invokes host system utilities (`ip`, `iptables`, `sysctl`, `nslookup`, `sudo`) only via `sudo` for privileged operations; the script does not modify its filesystem outside `/etc/netns/<name>/` and is not allowed to change host routing outside the objects it creates itself (table `TABLE_ID`, `ip rule` with its priorities, iptables rules with its match criteria).

## Interfaces

| Interface | Package/Binary | Consumed By | Purpose |
| --------- | -------------- | ----------- | ------- |
| `ip netns add/delete <name>` | iproute2 `ip` | setup/teardown | create/delete the network namespace |
| `ip link add/del <veth>` + `set <peer> netns <name>` | iproute2 `ip` | setup/teardown | host↔netns veth pair |
| `ip addr add`, `link set up` (host and inside netns) | iproute2 `ip` | setup | veth addressing and bringing up, `lo` |
| `ip route .../table <T>`, `ip rule add/del` | iproute2 `ip` | setup/teardown | policy routing (table `100..199`, pref `20000+`, exceptions into `main`) |
| `ip -4 route get <gw>` / `ip -4 route show default dev <if>` / `route show dev <if> scope link` | iproute2 `ip` | autodetection | determine the interface from the gateway, the gateway from the interface, the on-link subnet |
| `iptables -t nat -A/D POSTROUTING -s <NS_SUBNET> -o <IFACE> -j MASQUERADE` | `iptables` | setup/teardown | NAT netns traffic outbound |
| `iptables -A/D FORWARD -i/-o <VETH_HOST> ...` | `iptables` | setup/teardown | allow netns↔IFACE forwarding (out ACCEPT; in ESTABLISHED,RELATED) |
| `sysctl -qw net.ipv4.ip_forward` | `sysctl` / `/proc/sys` | setup/teardown | enable forwarding, restore the original value |
| `ip netns exec <ns> sysctl -qw net.ipv4.ping_group_range=<host value>` | `sysctl` / `/proc/sys` | setup (step 4') | copy of the host value into the netns only: ICMP/UDP sockets for the unprivileged user (`ping`, `traceroute -I`) — as on the host; the host is not touched, the value dies with the netns |
| `ip netns exec <ns> nslookup <domain>` | `nslookup` | steps 9–10 | domain resolution inside the netns (A records) |
| `sudo` (`as_root`, `sudo -v`, keepalive `sudo -n true`, `ip netns exec ... sudo -E -u <user>`) | `sudo` | all privileged steps | root privileges + running the command on behalf of the user |
| `mkdir/tee/rm -rf /etc/netns/<name>/resolv.conf` | coreutils | step 5 / teardown | per-netns DNS with explicit `-d` |

## Initialization

- Check that `ip`, `sudo`, `iptables` are present in PATH (`need_cmd`) before any privileged actions; `nslookup` is required only when domains appear in `--route`/`--exclude`.
- `sudo -v` caches the credentials; a background keepalive (`sudo -n true` every 60s, `KEEPALIVE_PID`) keeps them fresh for as long as the command runs.
- At least one of `-g`/`-i` is required; the other is derived from the first (see [environment-lifecycle](../domains/netns-run/environment-lifecycle.md)).

## Data Flow Across Boundary

Inward (script → host): sequences of `ip`/`iptables`/`sysctl` commands with parameters derived from CLI arguments and generated from the PID; text files (`/etc/netns/<name>/resolv.conf` with `-d`).
Outward (host → script): stdout of one-line `ip` queries (`route get`, `route show`) and `nslookup`, parsed with awk; command exit codes; `/proc/sys/net/ipv4/ip_forward` (read with cat); `/proc/sys/net/ipv4/ping_group_range` (reading the host value with tab→space normalization, step 4').
To the command being run: a ready netns environment with a default route via the host side of the veth, DNS (the host's resolv.conf as is, or as given by `-d`) and policy routing through the specified gateway.

## Error Propagation

- Missing utility, invalid arguments, unreachable gateway, failed domain resolution → `die` (exit 1, message `[netns-run] ERROR: ...`) — always before the environment is created, where possible.
- A system command failing during setup under `set -e` terminates the script; the EXIT trap performs a best-effort teardown of what was created (deletion errors are suppressed with `2>/dev/null`).
- Return code: the script exits with the exit code of the command it ran (`APP_EC`), not with the teardown code.

## Breaking Change Checklist

If you change X, you MUST also update Y:

- Changing an output format that awk parsing relies on (`ip route get/show`, `nslookup`) → check `detect_iface`, `detect_gateway`, `detect_host_subnet`, `add_extra_routes`, `add_exclude_rules` and update [environment-lifecycle](../domains/netns-run/environment-lifecycle.md).
- A new system utility in the script → add a `need_cmd` check and a row to the Interfaces table of this contract.
- Changing the numbering scheme (`TABLE_ID`, `RULE_PRIO`, `EXCLUDE_RULE_PRIO`, the `10.200.X.0/30` subnet) → update identifier generation, teardown (deletion by the old priorities) and both domain specs; make sure the ranges do not conflict with typical host configuration.
- Changing the set of iptables rules → mirror the change in the add (step 7) and delete (teardown) blocks and the `ADDED_*` flags; verify operation without stateful rules (conntrack unavailable → the incoming ESTABLISHED,RELATED rule will not work).
- Removing/renaming a CLI option → synchronously update the `usage`, the tool's README and the domain specs.
- Changing the DNS mechanism (`/etc/netns/<name>/resolv.conf`, the bind-mount semantics of `ip netns exec`) → update step 5 in [environment-lifecycle](../domains/netns-run/environment-lifecycle.md) and the tool's README (default behavior "the host's resolv.conf as is").
