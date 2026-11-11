#!/usr/bin/env bash
#
# netns-run.sh
#
# Wrapper for running an arbitrary command in an isolated network
# namespace (netns). The netns itself has no connectivity: its traffic
# leaves through a veth pair onto the host, where policy routing
# (a separate routes table + ip rule) decides where it goes:
#
#   - without --route: ALL traffic from the netns follows the host's
#     system routing (the main table), as if the netns did not exist
#     (a catch-all 0.0.0.0/0 exception is added automatically);
#   - each --route directs traffic to the given destination through the
#     specified gateway and/or host interface, overriding the host's
#     system routing for that destination; destinations not covered by
#     any --route keep following the host's system routing;
#   - --exclude entries direct traffic to the given addresses/domains
#     into the host's main table.
#
# The link between the netns and the host is provided by a veth pair;
# outbound traffic is NAT'ed on the host (iptables MASQUERADE). DNS for
# the netns: by default processes inside see the host's current
# /etc/resolv.conf as is (no /etc/netns/... entries are created); each
# --dns server is written into a per-netns
# /etc/netns/<name>/resolv.conf instead (bind-mounted over /etc inside
# the netns by `ip netns exec`) and removed at teardown.
#
# Domains given via --route / --exclude are pre-resolved on the host
# (an unprivileged nslookup before sudo): routes/rules are created for
# the resolved IPv4 (A) addresses, and a domain without any is fatal.
#
# After the command finishes (successfully or not), everything that
# was created is automatically torn down.
#
# Usage:
#   netns-run.sh [--route R] [--route-file F] [--exclude A] \
#                [--exclude-file F] [--dns IP] -- COMMAND [ARGS...]
#
# Options and examples: run `netns-run.sh --help`.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  netns-run.sh [--route R] [--route-file F] [--exclude A] \
               [--exclude-file F] [--dns IP] -- COMMAND [ARGS...]

  --route R    route for the netns traffic to the given destination:
                 [<addr>] (via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>)
               addr is an IPv4 address, a CIDR subnet (e.g. 10.1.0.0/16),
               a domain (all of the domain's addresses are used) or the
               keyword "default"; an omitted addr and "0.0.0.0"/"0.0.0.0/0"
               mean the default route. gw is the gateway's IPv4 address,
               if is a host interface name. May be specified multiple times.
  --route-file F  routes file (each non-empty line = one --route argument).
               May be specified multiple times.
  --exclude A  address/CIDR subnet or domain whose traffic from the netns
               goes via the host's system routing (main table), as if
               there were no netns. May be specified multiple times.
  --exclude-file F  exclude file (each non-empty line = one --exclude
               argument). May be specified multiple times.
  --dns IP     DNS server (IPv4 address) for processes inside the netns:
               all --dns servers are written to /etc/netns/<name>/resolv.conf,
               which `ip netns exec` bind-mounts over /etc/resolv.conf in
               the netns. Without --dns the netns sees the host's current
               /etc/resolv.conf. May be specified multiple times.
  --help       this help

With no --route given, ALL traffic from the netns follows the host's system
routing (a catch-all exception 0.0.0.0/0 is added). Each --route entry
overrides the host's system routing for its destination; destinations not
covered by any entry keep following the host's system routing.
Without --dns, DNS servers are taken from the host's current
/etc/resolv.conf; --dns entries override them for the netns only
(domain resolution for --route/--exclude always uses the host's
resolver, regardless of --dns).

Examples:
  netns-run.sh --route "via 192.168.1.5" -- firefox
  netns-run.sh --route "via 192.168.1.5 dev eth1" -- firefox
  netns-run.sh --route "10.40.0.0/16 via 192.168.1.254" -- firefox
  netns-run.sh --route "10.1.0.0/16 dev eth1" -- curl https://example.com
  netns-run.sh --route "example.com via 192.168.1.254" -- curl https://example.com
  netns-run.sh --route "via 192.168.1.5" --exclude 192.168.23.0/24 -- curl https://example.com
  netns-run.sh --dns 9.9.9.9 --dns 149.112.112.112 -- curl https://example.com
EOF
}

log()  { echo "[netns-run] $*" >&2; }
die()  { echo "[netns-run] ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required utility '$1' not found in PATH"
}

as_root() {
  sudo "$@"
}

# ---------------------------------------------------------------------------
# defaults / global variables
# ---------------------------------------------------------------------------
RUN_AS_USER="${SUDO_USER:-$(id -un)}"

EXTRA_ROUTES=()    # raw "<addr> via|dev ..." lines from --route / --route-file
ROUTE_ADDR=()      # addr part of each parsed route: "default" | IPv4 | CIDR | domain
ROUTE_TAIL=()      # normalized remainder: "via <gw> dev <if>" | "via <gw>" | "dev <if>"
ROUTE_IPS=()       # space-separated A addresses of each route's domain,
                   # pre-resolved on the host ("" for default/IPv4/CIDR)
EXCLUDED_ADDRS=()  # lines "<addr|domain>" from --exclude / --exclude-file
EXCLUDED_IPS=()    # space-separated A addresses of each exclude's domain,
                   # pre-resolved on the host ("" for IPv4/CIDR entries)
DNS_SERVERS=()     # DNS server IPv4 addresses from --dns (repeatable;
                   # exact duplicates are dropped, the order is preserved
                   # — it becomes the order of the "nameserver" lines);
                   # empty = no override, the netns sees the host's
                   # current /etc/resolv.conf as is

# ip rule priority for exceptions: must be LESS than RULE_PRIO (i.e. higher),
# so that the exceptions match earlier than the rule sending all traffic
# from the netns into the TABLE_ID table
EXCLUDE_RULE_PRIO=""

VETH_HOST=""
VETH_NS=""
TABLE_ID=""
RULE_PRIO=""

HOST_VETH_IP=""
NS_VETH_IP=""
NS_SUBNET=""

IP_FORWARD_ORIG=""
KEEPALIVE_PID=""

CREATED_NETNS=0
CREATED_VETH=0
CREATED_NETNS_DNS=0
ADDED_NAT_RULE=0
ADDED_FWD_RULE1=0
ADDED_FWD_RULE2=0
ADDED_RULE=0
ADDED_EXCLUDE_RULE=0
ADDED_ROUTE=0
CHANGED_FORWARD=0

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0 ;;
    --route)
      [[ -n "${2:-}" ]] || die "no route given after --route (see --help)"
      EXTRA_ROUTES+=("$2")
      shift 2 ;;
    --route-file)
      [[ -n "${2:-}" && -r "$2" ]] || die "routes file is not readable: '${2:-}'"
      mapfile -t _rl < <(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$2")
      [[ ${#_rl[@]} -gt 0 ]] || die "routes file is empty: '$2'"
      EXTRA_ROUTES+=("${_rl[@]}")
      shift 2 ;;
    --exclude)
      [[ -n "${2:-}" ]] || die "no address given after --exclude (see --help)"
      EXCLUDED_ADDRS+=("$2")
      shift 2 ;;
    --exclude-file)
      [[ -n "${2:-}" && -r "$2" ]] || die "exclude file is not readable: '${2:-}'"
      mapfile -t _el < <(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$2")
      [[ ${#_el[@]} -gt 0 ]] || die "exclude file is empty: '$2'"
      EXCLUDED_ADDRS+=("${_el[@]}")
      shift 2 ;;
    --dns)
      [[ -n "${2:-}" ]] || die "no DNS server given after --dns (see --help)"
      DNS_SERVERS+=("$2")
      shift 2 ;;
    --)
      shift
      break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)  break ;;
  esac
done

[[ $# -ge 1 ]] || die "no command specified to run (after --)"

need_cmd ip
need_cmd sudo
need_cmd iptables

# ---------------------------------------------------------------------------
# parsing / normalization / validation of --route / --route-file
# (rewritten validate_routes; the "gw" synonym of "via" is NOT supported)
# Grammar of one route:
#   [<addr>] (via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>)
# addr is an IPv4 address, a CIDR subnet (/0..32), a domain or the keyword
# "default"; 0.0.0.0 and 0.0.0.0/0 are normalized to "default"; an omitted
# addr means "default". gw is an IPv4 address, if is a host interface name.
# Each parsed route is stored in two parallel arrays:
#   ROUTE_ADDR[i] — addr part: "default" | IPv4 | CIDR | domain;
#   ROUTE_TAIL[i] — normalized remainder: "via <gw> dev <if>", "via <gw>"
#                   or "dev <if>".
# Domains are resolved later, on the host (pre-sudo resolve_domains),
# so a name-format check is sufficient here.
# ---------------------------------------------------------------------------
parse_route() {
  local r="$1"
  local -a tok=()
  local n=0 addr="" gw="" dev="" kw=""
  local -i have_via=0 have_dev=0 i=0 start=1

  read -r -a tok <<<"$r"
  n=${#tok[@]}
  [[ $n -gt 0 ]] \
    || die "route '$r': empty route string (expected: \"[<addr>] via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>\")"

  case "${tok[0]}" in
    via|dev)
      addr="default"   # addr omitted — the default route
      start=0
      ;;
    default|0.0.0.0|0.0.0.0/0)
      addr="default"
      ;;
    *)
      addr="${tok[0]}"
      if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
        || [[ "$addr" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\.?$ ]]; then
        : # IPv4 address, CIDR subnet or domain
      else
        die "route '$r': '$addr' is not an IPv4 address, not a CIDR subnet (prefix 0-32) and not a domain"
      fi
      ;;
  esac

  # keyword arguments via <gw> / dev <if> — each at most once, in any order
  for (( i = start; i < n; i++ )); do
    kw="${tok[i]}"
    case "$kw" in
      via)
        [[ $have_via -eq 0 ]] || die "route '$r': duplicate 'via'"
        have_via=1
        [[ $((i + 1)) -lt $n ]] || die "route '$r': no gateway given after 'via'"
        gw="${tok[i + 1]}"
        if [[ "$gw" == via || "$gw" == dev ]]; then
          die "route '$r': no gateway given after 'via'"
        fi
        [[ "$gw" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
          || die "route '$r': gateway '$gw' must be an IPv4 address"
        i=$((i + 1))
        ;;
      dev)
        [[ $have_dev -eq 0 ]] || die "route '$r': duplicate 'dev'"
        have_dev=1
        [[ $((i + 1)) -lt $n ]] || die "route '$r': no interface given after 'dev'"
        dev="${tok[i + 1]}"
        if [[ "$dev" == via || "$dev" == dev ]]; then
          die "route '$r': no interface given after 'dev'"
        fi
        i=$((i + 1))
        ;;
      *)
        die "route '$r': unexpected token '$kw' (expected: \"[<addr>] via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>\")"
        ;;
    esac
  done

  [[ $have_via -eq 1 || $have_dev -eq 1 ]] \
    || die "route '$r': missing 'via <gw>' or 'dev <if>' (expected: \"[<addr>] via <gw> | dev <if> | via <gw> dev <if> | dev <if> via <gw>\")"

  if [[ $have_via -eq 1 && $have_dev -eq 1 ]]; then
    ROUTE_TAIL+=("via $gw dev $dev")
  elif [[ $have_via -eq 1 ]]; then
    ROUTE_TAIL+=("via $gw")
  else
    ROUTE_TAIL+=("dev $dev")
  fi
  ROUTE_ADDR+=("$addr")
}

for _r in "${EXTRA_ROUTES[@]}"; do
  parse_route "$_r"
done
log "extra routes: ${#ROUTE_ADDR[@]}"

# without any --route the whole netns traffic must follow the host's system
# routing — register a catch-all exception via the regular excludes mechanism
if [[ ${#ROUTE_ADDR[@]} -eq 0 ]]; then
  log "no --route given: all traffic from the netns will follow the host's system routing (catch-all exception 0.0.0.0/0 added)"
  EXCLUDED_ADDRS+=("0.0.0.0/0")
fi

# ---------------------------------------------------------------------------
# pre-sudo route resolution (replaces the old gateway/interface autodetect):
#   - a route with via but no dev — the interface is determined via
#     `ip -4 route get <gw>`; the gateway must be reachable through one of
#     the host's interfaces, otherwise the script dies;
#   - a route with an explicit dev — the interface must exist on the host.
# After this stage every via-route carries an explicit dev.
# ---------------------------------------------------------------------------
resolve_routes() {
  local -i i
  local gw dev
  for i in "${!ROUTE_TAIL[@]}"; do
    gw=$(awk '{for(j=1;j<=NF;j++) if ($j=="via") {print $(j+1); exit}}' <<<"${ROUTE_TAIL[i]}")
    dev=$(awk '{for(j=1;j<=NF;j++) if ($j=="dev") {print $(j+1); exit}}' <<<"${ROUTE_TAIL[i]}")
    if [[ -n "$gw" && -z "$dev" ]]; then
      if ! dev=$(ip -4 route get "$gw" 2>/dev/null \
           | awk '{for(j=1;j<=NF;j++) if ($j=="dev") {print $(j+1); exit}}'); then
        die "route '${ROUTE_ADDR[i]}': gateway $gw is unreachable from any host interface (specify the interface explicitly: 'dev <if>')"
      fi
      [[ -n "$dev" ]] || die "route '${ROUTE_ADDR[i]}': failed to determine the interface for gateway $gw (no 'dev' in the output of 'ip route get')"
      ROUTE_TAIL[i]="via $gw dev $dev"
      log "route '${ROUTE_ADDR[i]}': interface for gateway $gw determined automatically: $dev"
    elif [[ -n "$dev" ]]; then
      ip link show "$dev" >/dev/null 2>&1 \
        || die "route '${ROUTE_ADDR[i]}': interface '$dev' not found on the host"
    fi
  done
}
resolve_routes

# ---------------------------------------------------------------------------
# validation of --exclude / --exclude-file
# Format: "<addr|domain>" — an IPv4 address, a CIDR subnet or a domain.
# No via/dev — traffic to the exceptions is directed into the host's
# main table.
# Domains are resolved later, on the host (pre-sudo resolve_domains),
# so a name-format check is sufficient here.
# ---------------------------------------------------------------------------
validate_excludes() {
  local e addr
  for e in "${EXCLUDED_ADDRS[@]}"; do
    # the entry must consist of exactly one token
    read -r -a _et <<<"$e"
    [[ ${#_et[@]} -eq 1 ]] || die "exception '$e': only '<addr|domain>' is allowed (a single token)"

    addr="${_et[0]}"
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
      || [[ "$addr" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\.?$ ]]; then
      : # IPv4 address or CIDR subnet
    else
      die "exception '$e': '$addr' is not an IPv4 address, not a CIDR subnet (prefix 0-32) and not a domain"
    fi
  done
}
validate_excludes
log "exceptions: ${#EXCLUDED_ADDRS[@]}"

# dedupe --dns entries preserving the given order (the first occurrence
# wins: the order of the "nameserver" lines in resolv.conf is meaningful
# — the first server is the primary one)
if [[ ${#DNS_SERVERS[@]} -gt 1 ]]; then
  mapfile -t DNS_SERVERS < <(printf '%s\n' "${DNS_SERVERS[@]}" | awk '!seen[$0]++')
fi

# ---------------------------------------------------------------------------
# validation of --dns
# Format: "<addr>" — an IPv4 address only. The entries are written verbatim
# as "nameserver <addr>" lines into /etc/netns/<name>/resolv.conf (step 5);
# exact duplicates are dropped before that, the order is preserved.
# Domains and CIDR subnets are not accepted: a nameserver entry must be
# usable without prior DNS resolution (a chicken-and-egg problem otherwise).
# Servers given here do NOT participate in resolving --route/--exclude
# domains — that resolution always happens on the host, with the host's
# resolver configuration (resolve_domains, before sudo).
# ---------------------------------------------------------------------------
validate_dns_servers() {
  local s
  for s in "${DNS_SERVERS[@]}"; do
    [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
      || die "--dns '$s': not an IPv4 address (domains and CIDR subnets are not accepted)"
  done
}
validate_dns_servers
if [[ ${#DNS_SERVERS[@]} -gt 0 ]]; then
  log "dns servers: ${DNS_SERVERS[*]}"
  # mkdir/tee/rm are required only with --dns (the same pattern as
  # nslookup in resolve_domains: checked only when actually needed)
  need_cmd mkdir
  need_cmd tee
  need_cmd rm
fi

# ---------------------------------------------------------------------------
# pre-sudo resolution of domains (--route / --exclude), before `sudo -v`:
#   every domain from ROUTE_ADDR / EXCLUDED_ADDRS is resolved on the host
#   with an unprivileged `nslookup` (the host's resolv.conf — the netns
#   does not exist yet); all of the domain's unique IPv4 (A) addresses
#   are stored, space-separated, in the parallel arrays ROUTE_IPS[i] /
#   EXCLUDED_IPS[i] ("" for default/IPv4/CIDR entries). ROUTE_ADDR /
#   EXCLUDED_ADDRS stay untouched and serve only as labels in log
#   messages. A domain without IPv4 (A) records is fatal: the script
#   dies here — before the sudo password prompt and before any netns
#   object is created.
# ---------------------------------------------------------------------------
resolve_domain() {
  # resolve one domain into a space-separated list of its unique IPv4 (A)
  # addresses (kept in the global $_resolved); dies if there are none
  local addr="$1"
  local -a ips=()
  mapfile -t ips < <(nslookup "$addr" 2>/dev/null \
    | awk '/^Address[0-9 ]*:/ {print $NF}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -u)
  [[ ${#ips[@]} -gt 0 ]] || die "failed to resolve domain '$addr' (no IPv4 (A) records)"
  _resolved="${ips[*]}"
}

resolve_domains() {
  local -i i
  local addr

  # nslookup is required only when at least one entry is a domain
  for addr in "${ROUTE_ADDR[@]}" "${EXCLUDED_ADDRS[@]}"; do
    if [[ "$addr" != "default" \
          && ! "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      need_cmd nslookup
      break
    fi
  done

  # fill the parallel arrays: "" for default/IPv4/CIDR entries,
  # space-separated A addresses for domains
  for i in "${!ROUTE_ADDR[@]}"; do
    addr="${ROUTE_ADDR[i]}"
    if [[ "$addr" == "default" \
          || "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      ROUTE_IPS+=("")
    else
      log "resolving domain '$addr' on the host..."
      resolve_domain "$addr"
      ROUTE_IPS+=("$_resolved")
      log "domain '$addr' resolved: ${ROUTE_IPS[i]}"
    fi
  done
  for i in "${!EXCLUDED_ADDRS[@]}"; do
    addr="${EXCLUDED_ADDRS[i]}"
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      EXCLUDED_IPS+=("")
    else
      log "resolving domain '$addr' on the host..."
      resolve_domain "$addr"
      EXCLUDED_IPS+=("$_resolved")
      log "domain '$addr' resolved: ${EXCLUDED_IPS[i]}"
    fi
  done
}
resolve_domains

# ---------------------------------------------------------------------------
# unique names/subnets/identifiers for this run
# ---------------------------------------------------------------------------
PID_SUFFIX=$(( $$ % 65536 ))
OCTET=$(( ($$ % 250) + 1 ))   # 1..250 — third octet of the veth-pair subnet

NETNS_NAME="netns-${PID_SUFFIX}"
VETH_HOST="vh-${PID_SUFFIX}"
VETH_NS="vn-${PID_SUFFIX}"
TABLE_ID=$(( 100 + (PID_SUFFIX % 100) ))
RULE_PRIO=$(( 20000 + (PID_SUFFIX % 1000) ))
# exception rule priority: strictly less than RULE_PRIO (numerically higher
# in processing order) — so that the exceptions into the main table work
# earlier than the rule sending all netns traffic to TABLE_ID
EXCLUDE_RULE_PRIO=$(( RULE_PRIO - 10 ))

HOST_VETH_IP="10.200.${OCTET}.1"
NS_VETH_IP="10.200.${OCTET}.2"
NS_SUBNET="10.200.${OCTET}.0/30"

log "netns=$NETNS_NAME subnet=$NS_SUBNET user=$RUN_AS_USER"
if [[ ${#EXCLUDED_ADDRS[@]} -gt 0 ]]; then
  log "exceptions: ${#EXCLUDED_ADDRS[@]} (rule pref $EXCLUDE_RULE_PRIO, table main)"
fi

# ---------------------------------------------------------------------------
# environment teardown (called on EXIT/INT/TERM)
# ---------------------------------------------------------------------------
cleanup() {
  local ec=$?
  set +e
  log "tearing down the environment..."

  [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null

  if [[ $ADDED_RULE -eq 1 ]]; then
    as_root ip rule del pref "$RULE_PRIO" 2>/dev/null
  fi
  # delete all exception rules of this run (by priority)
  if [[ $ADDED_EXCLUDE_RULE -eq 1 ]]; then
    while as_root ip rule del pref "$EXCLUDE_RULE_PRIO" 2>/dev/null; do
      :
    done
  fi
  if [[ $ADDED_ROUTE -eq 1 ]]; then
    as_root ip route flush table "$TABLE_ID" 2>/dev/null
  fi
  if [[ $ADDED_FWD_RULE1 -eq 1 ]]; then
    as_root iptables -D FORWARD -i "$VETH_HOST" -j ACCEPT 2>/dev/null
  fi
  if [[ $ADDED_FWD_RULE2 -eq 1 ]]; then
    as_root iptables -D FORWARD -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
  fi
  if [[ $ADDED_NAT_RULE -eq 1 ]]; then
    as_root iptables -t nat -D POSTROUTING -s "$NS_SUBNET" -j MASQUERADE 2>/dev/null
  fi

  # deleting the netns automatically deletes the whole veth pair (both ends)
  if [[ $CREATED_NETNS -eq 1 ]]; then
    as_root ip netns delete "$NETNS_NAME" 2>/dev/null
  elif [[ $CREATED_VETH -eq 1 ]]; then
    as_root ip link delete "$VETH_HOST" 2>/dev/null
  fi

  # remove the per-netns DNS override — the only host-filesystem entry
  # this script ever creates (best-effort, like everything above)
  if [[ $CREATED_NETNS_DNS -eq 1 ]]; then
    as_root rm -rf "/etc/netns/$NETNS_NAME" 2>/dev/null
  fi

  if [[ $CHANGED_FORWARD -eq 1 && -n "$IP_FORWARD_ORIG" ]]; then
    as_root sysctl -qw net.ipv4.ip_forward="$IP_FORWARD_ORIG" 2>/dev/null
  fi

  log "teardown complete"
  exit "$ec"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# environment setup
# ---------------------------------------------------------------------------

# cache the sudo credentials once and keep them fresh for as long as the
# command runs, so the password is not requested again
sudo -v || die "failed to obtain sudo privileges"
( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
KEEPALIVE_PID=$!

# 1. netns
as_root ip netns add "$NETNS_NAME"
CREATED_NETNS=1

# 2. veth pair: one end stays on the host, the other goes into the netns
as_root ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
CREATED_VETH=1
as_root ip link set "$VETH_NS" netns "$NETNS_NAME"

# 3. addresses and bringing the interfaces up
as_root ip addr add "${HOST_VETH_IP}/30" dev "$VETH_HOST"
as_root ip link set "$VETH_HOST" up

as_root ip netns exec "$NETNS_NAME" ip addr add "${NS_VETH_IP}/30" dev "$VETH_NS"
as_root ip netns exec "$NETNS_NAME" ip link set "$VETH_NS" up
as_root ip netns exec "$NETNS_NAME" ip link set lo up

# 4. default route inside the netns — via the host side of the veth
as_root ip netns exec "$NETNS_NAME" ip route add default via "$HOST_VETH_IP" dev "$VETH_NS"

# 4'. ping_group_range: a per-netns sysctl enabling unprivileged ICMP
#     sockets (SOCK_DGRAM, IPPROTO_ICMP) — used by ping and
#     traceroute -I. Host systemd sets this value only in the initial
#     netns (/usr/lib/sysctl.d/50-default.conf); it does not get into
#     a new netns automatically, so we copy the host's current value:
#     read it from the host's /proc/sys (tab -> space) into a variable,
#     then write it only inside our own netns (the host is not touched);
#     the value dies with the netns — no cleanup needed.
#     Failure is not fatal: the script's purpose is to run a command;
#     ping is just diagnostics.
PING_GROUP_RANGE=""
if [[ -r /proc/sys/net/ipv4/ping_group_range ]]; then
  PING_GROUP_RANGE=$(tr '\t' ' ' < /proc/sys/net/ipv4/ping_group_range)
else
  log "WARNING: failed to read the host value of net.ipv4.ping_group_range — ping and traceroute -I inside the netns may not work"
fi
if [[ -n "$PING_GROUP_RANGE" ]]; then
  if ! as_root ip netns exec "$NETNS_NAME" \
       sysctl -qw "net.ipv4.ping_group_range=$PING_GROUP_RANGE"; then
    log "WARNING: failed to set net.ipv4.ping_group_range in the netns — ping and traceroute -I may not work for the unprivileged user"
  else
    log "ping_group_range in the netns: $PING_GROUP_RANGE (copy of the host value)"
  fi
fi

# 5. DNS:
#    - without --dns: nothing to configure — there is no
#      /etc/netns/<name>/resolv.conf, so `ip netns exec` does not replace
#      /etc/resolv.conf and processes inside the netns see the host's
#      current resolv.conf as is;
#    - with --dns: a per-netns resolv.conf is written from the validated
#      DNS_SERVERS array. `ip netns exec` bind-mounts every file from
#      /etc/netns/<name>/ over the same-named path in /etc inside the
#      netns's own mount namespace — the host's /etc is not affected;
#      this directory is the only host-filesystem entry the script ever
#      creates, and cleanup removes it.
if [[ ${#DNS_SERVERS[@]} -gt 0 ]]; then
  if [[ ${#DNS_SERVERS[@]} -gt 3 ]]; then
    log "WARNING: more than 3 DNS servers given — glibc-based resolvers use only the first 3 (MAXNS)"
  fi
  [[ ! -e "/etc/netns/$NETNS_NAME" ]] \
    || die "/etc/netns/$NETNS_NAME already exists (stale leftover of a previous run with the same PID?)"
  as_root mkdir -p "/etc/netns/$NETNS_NAME" \
    || die "failed to create /etc/netns/$NETNS_NAME"
  CREATED_NETNS_DNS=1
  printf 'nameserver %s\n' "${DNS_SERVERS[@]}" \
    | as_root tee "/etc/netns/$NETNS_NAME/resolv.conf" >/dev/null \
    || die "failed to write /etc/netns/$NETNS_NAME/resolv.conf"
  log "dns servers for the netns: ${DNS_SERVERS[*]} (/etc/netns/$NETNS_NAME/resolv.conf)"
else
  log "using the host's current /etc/resolv.conf unchanged"
fi

# 6'. definition of the extra-routes function (--route / --route-file)
#    Applied from the parsed ROUTE_ADDR/ROUTE_TAIL/ROUTE_IPS arrays:
#    - an IPv4 address, a CIDR subnet or "default" — `ip route replace`
#      into the TABLE_ID table (replace, rather than add, so it does not
#      fail on a re-run or on overlapping entries);
#    - a domain — a /32 route is added for each of its A addresses
#      pre-resolved on the host (resolve_domains, before sudo).
#    The tail carries the normalized "via <gw>" / "dev <if>" / both.
#    The call is made later (step 9), after the netns default route
#    through the veth (step 4) is up.
add_extra_routes() {
  local -i i
  local addr tail ip
  for i in "${!ROUTE_ADDR[@]}"; do
    addr="${ROUTE_ADDR[i]}"
    tail="${ROUTE_TAIL[i]}"
    if [[ "$addr" == "default" \
          || "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      as_root ip route replace "$addr" $tail table "$TABLE_ID" \
        || die "failed to add route '$addr $tail' to table $TABLE_ID"
      log "route added: $addr $tail (table $TABLE_ID)"
    else
      # domain: loop over the A addresses pre-resolved on the host
      for ip in ${ROUTE_IPS[i]}; do
        as_root ip route add "$ip/32" $tail table "$TABLE_ID" \
          || log "WARNING: route to $ip not added (it may already exist)"
        log "route added: $ip/32 $tail (table $TABLE_ID, domain $addr)"
      done
    fi
  done
}

# 6''. definition of the exceptions function (--exclude / --exclude-file)
#    For the listed addresses/subnets/domains, traffic from the netns
#    must follow the host's system routing. Achieved with an ip rule
#    with a HIGHER priority (lower number) than the main netns rule:
#      ip rule add pref <EXCLUDE_RULE_PRIO> from <NS_SUBNET> to <addr> table main
#    For domains a rule is added for each of the domain's A addresses
#    (/32), pre-resolved on the host (resolve_domains, before sudo).
add_exclude_rules() {
  local -i i
  local addr ip
  for i in "${!EXCLUDED_ADDRS[@]}"; do
    addr="${EXCLUDED_ADDRS[i]}"

    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      as_root ip rule add pref "$EXCLUDE_RULE_PRIO" from "$NS_SUBNET" to "$addr" table main \
        || die "failed to add the exception rule for '$addr'"
      ADDED_EXCLUDE_RULE=1
      log "exception: traffic to $addr directed into the main table (rule pref $EXCLUDE_RULE_PRIO)"
    else
      # domain: loop over the A addresses pre-resolved on the host
      for ip in ${EXCLUDED_IPS[i]}; do
        as_root ip rule add pref "$EXCLUDE_RULE_PRIO" from "$NS_SUBNET" to "$ip/32" table main \
          || log "WARNING: exception rule for $ip not added (it may already exist)"
        ADDED_EXCLUDE_RULE=1
        log "exception: traffic to $ip/32 directed into the main table (rule pref $EXCLUDE_RULE_PRIO, domain $addr)"
      done
    fi
  done
}

# 6. packet forwarding on the host (the original value is restored during cleanup)
IP_FORWARD_ORIG=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "$IP_FORWARD_ORIG" != "1" ]]; then
  as_root sysctl -qw net.ipv4.ip_forward=1
  CHANGED_FORWARD=1
fi

# 7. outbound NAT + allowing forwarding to/from the veth (interface-agnostic:
#    NAT masquerades regardless of the outgoing interface; forwarding is
#    allowed in both directions for the veth regardless of the peer interface)
as_root iptables -t nat -A POSTROUTING -s "$NS_SUBNET" -j MASQUERADE
ADDED_NAT_RULE=1
as_root iptables -A FORWARD -i "$VETH_HOST" -j ACCEPT
ADDED_FWD_RULE1=1
as_root iptables -A FORWARD -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT
ADDED_FWD_RULE2=1

# 8. policy routing — only when --route entries are given: traffic from
#    the netns subnet is looked up in the TABLE_ID table (populated in
#    step 9 from the --route entries), which overrides the host's system
#    routing for the covered destinations. Without --route neither the
#    rule nor the table is created: the catch-all exception (step 10)
#    already directs all netns traffic into the host's main table.
#    The routes themselves — including "default", when given via
#    `--route "via <gw>"` — are added in step 9 only.
if [[ ${#ROUTE_ADDR[@]} -gt 0 ]]; then
  ADDED_ROUTE=1   # step 9 populates TABLE_ID; cleanup flushes the table
  as_root ip rule add pref "$RULE_PRIO" from "$NS_SUBNET" table "$TABLE_ID"
  ADDED_RULE=1
fi

# 9. extra routes (--route / --route-file) — added to the TABLE_ID table,
#    so they apply only to traffic from the netns (a no-op loop when no
#    --route entries were given). Domains were resolved on the host
#    before sudo (resolve_domains) — all of the domain's addresses
#    (all A records) are covered.
add_extra_routes

# 10. exceptions (--exclude / --exclude-file): an ip rule with a higher
#     priority (lower pref) than the main netns rule directs traffic to
#     the listed addresses/domains into the host's main table. Domains
#     were resolved on the host before sudo (resolve_domains).
add_exclude_rules

log "environment ready. Running the command as '$RUN_AS_USER': $*"

# ---------------------------------------------------------------------------
# running the command inside the netns on behalf of the original user
# ---------------------------------------------------------------------------
set +e
as_root ip netns exec "$NETNS_NAME" sudo -E -u "$RUN_AS_USER" -- "$@"
APP_EC=$?
set -e

log "command exited with exit code $APP_EC"
exit "$APP_EC"
