#!/usr/bin/env bash
#
# netns-run.sh
#
# Wrapper for running an arbitrary command in an isolated network
# namespace (netns). All of the command's network traffic is forced
# through a specified gateway reachable from one of the host's
# interfaces. That interface itself is NOT moved into the netns:
# the link between the netns and the host is provided by a veth pair,
# and the required route is provided via policy routing (a separate
# routes table + ip rule) and NAT (iptables MASQUERADE).
#
# After the command finishes (successfully or not), everything that
# was created is automatically torn down.
#
# Usage:
#   netns-run.sh -g GATEWAY [-i IFACE] [-n NETNS] [-d DNS1,DNS2] \
#                [-u USER] -- COMMAND [ARGS...]
#
# DNS: by default the netns uses the host's current resolv.conf as
# is (no /etc/netns/... bind mounts are created). If different DNS
# servers are needed — specify them via -d.
#
# Options:
#   -g GATEWAY   IPv4 address of the gateway through which all of the
#                application's traffic must go. If not set but -i is
#                set — the current default gateway for that interface
#                is used (ip route show default dev IFACE).
#   -i IFACE     Host interface through which the gateway is
#                reachable. If not set but -g is set — determined
#                automatically via `ip route get GATEWAY`.
#                At least one of -g / -i must be given.
#   -n NETNS     Network namespace name. Defaults to netns-<PID>.
#   -d DNS       Comma-separated DNS servers for the netns (e.g.
#                1.1.1.1,9.9.9.9). If not specified — the host's
#                current /etc/resolv.conf is used unchanged.
#   -u USER      User on whose behalf to run the command inside the
#                netns. Defaults to the user who ran the script
#                ($SUDO_USER or the current one).
#   --route R    An additional route for the given address/subnet or
#                domain (all of the domain's addresses are used).
#                Syntax is standard for ip route: "<addr> via <gw> [dev <if>]"
#                ("gw" is also allowed instead of "via"). May be specified
#                multiple times.
#   --route-file F  A file where each non-empty line is a route in the
#                same format as --route. Equivalent to several --route
#                options. May be specified multiple times.
#   --exclude A  Address/subnet or domain whose traffic from the netns
#                is routed using the host's system routing
#                (the main table), as if the netns did not exist.
#                May be specified multiple times.
#   --exclude-file F  A file with one exception per line (same format
#                as --exclude). Equivalent to several --exclude
#                options. May be specified multiple times.
#   -h           Show this help.
#
# Examples:
#   ./netns-run.sh -g 192.168.1.5 -- firefox
#   ./netns-run.sh -i eth1 -- firefox
#   ./netns-run.sh -g 10.0.0.1 -i eth1 -n vpntest -- curl -4 ifconfig.me
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  netns-run.sh [-g GATEWAY] [-i IFACE] [-n NETNS] [-d DNS1,DNS2] [-u USER] -- COMMAND [ARGS...]

  -g GATEWAY   IPv4 address of the gateway (if not set — the current default gateway for -i is used)
  -i IFACE     host interface (if not set — determined from the -g gateway)
               at least one of -g / -i must be given
  -n NETNS     network namespace name (defaults to netns-<PID>)
  -d DNS       comma-separated DNS servers for the netns (by default — the host's resolv.conf as is)
  -u USER      user on whose behalf to run the command in the netns
  --route R    extra route: "<addr> via <gw> [dev <if>]"; addr is an IP,
               a CIDR subnet (e.g. 10.1.0.0/16) or a domain (all of the
               domain's addresses); "gw" may be written instead of "via".
               May be specified multiple times.
  --route-file F  routes file (line = same format as --route). May be specified multiple times.
  --exclude A  address/CIDR subnet or domain whose traffic goes via the
               host's system routing (main table), as if there were no netns.
               May be specified multiple times.
  --exclude-file F  exclude file (line = same format as --exclude). May be specified multiple times.
  -h           this help

Examples:
  netns-run.sh -g 192.168.1.5 -- firefox
  netns-run.sh -i eth1 -- firefox
  netns-run.sh -g 192.168.1.5 --route "10.40.0.0/16 via 192.168.1.254" -- firefox
  netns-run.sh -g 192.168.1.5 --route "10.1.0.0/16 gw 192.168.23.100" -- curl https://example.com
  netns-run.sh -g 192.168.1.5 --exclude 192.168.23.0/24 -- curl https://example.com
  netns-run.sh -g 192.168.1.5 --route "example.com via 192.168.1.254" -- curl https://example.com
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
GATEWAY=""
HOST_IFACE=""
NETNS_NAME=""
DNS_SERVERS=""     # empty = use the host's resolv.conf as is
RUN_AS_USER="${SUDO_USER:-$(id -un)}"

EXTRA_ROUTES=()    # lines "<addr> via <gw> [dev <iface>]" from --route / --route-file
EXCLUDED_ADDRS=()  # lines "<addr|domain>" from --exclude / --exclude-file

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
HOST_SUBNET=""

IP_FORWARD_ORIG=""
KEEPALIVE_PID=""

CREATED_NETNS=0
CREATED_VETH=0
ADDED_NAT_RULE=0
ADDED_FWD_RULE1=0
ADDED_FWD_RULE2=0
ADDED_RULE=0
ADDED_EXCLUDE_RULE=0
ADDED_ROUTE=0
ADDED_LOCAL_ROUTE=0
CHANGED_FORWARD=0
CREATED_RESOLV_DIR=0

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g) GATEWAY="${2:-}"; shift 2 ;;
    -i) HOST_IFACE="${2:-}"; shift 2 ;;
    -n) NETNS_NAME="${2:-}"; shift 2 ;;
    -d) DNS_SERVERS="${2:-}"; shift 2 ;;
    -u) RUN_AS_USER="${2:-}"; shift 2 ;;
    --route) EXTRA_ROUTES+=("${2:-}"); shift 2 ;;
    --route-file)
      [[ -n "${2:-}" && -r "$2" ]] || die "routes file is not readable: '${2:-}'"
      mapfile -t _rl < <(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$2")
      [[ ${#_rl[@]} -gt 0 ]] || die "routes file is empty: '$2'"
      EXTRA_ROUTES+=("${_rl[@]}")
      shift 2 ;;
    --exclude) EXCLUDED_ADDRS+=("${2:-}"); shift 2 ;;
    --exclude-file)
      [[ -n "${2:-}" && -r "$2" ]] || die "exclude file is not readable: '${2:-}'"
      mapfile -t _el < <(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$2")
      [[ ${#_el[@]} -gt 0 ]] || die "exclude file is empty: '$2'"
      EXCLUDED_ADDRS+=("${_el[@]}")
      shift 2 ;;
    -h) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (see -h)" ;;
    *)  break ;;
  esac
done

if [[ -z "$GATEWAY" && -z "$HOST_IFACE" ]]; then
  usage
  exit 1
fi
[[ $# -ge 1 ]] || die "no command specified to run (after --)"

need_cmd ip
need_cmd sudo
need_cmd iptables

if [[ -n "$GATEWAY" ]] && ! [[ "$GATEWAY" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
  die "gateway must be specified as an IPv4 address, e.g. 192.168.1.1"
fi

# ---------------------------------------------------------------------------
# validation of --route / --route-file
# Format (standard ip route syntax): "<addr> via <gw> [dev <iface>]".
# The word "gw" is allowed as a synonym of "via": "<addr> gw <gw> [dev <iface>]".
# addr is an IPv4 address, a CIDR subnet (/0..32) or a domain; gw is the
# gateway's IPv4 address.
# Domains are resolved later, inside the netns (after DNS is configured),
# so a name-format check is sufficient here.
# ---------------------------------------------------------------------------
validate_routes() {
  local r addr gw
  for r in "${EXTRA_ROUTES[@]}"; do
    # extract the first token (address/subnet/domain)
    addr="${r%%[[:space:]]*}"

    case "$r" in
      *" via "*|*" gw "*) : ;;
      *) die "route '$r': missing ' via <gw>' or 'gw <gw>' (format: \"<addr> via|gw <gw> [dev <iface>]\")" ;;
    esac

    gw=$(awk '{for(i=1;i<=NF;i++) if ($i=="via" || $i=="gw") {print $(i+1); exit}}' <<<"$r")
    [[ -n "$gw" ]] || die "route '$r': no gateway given after 'via'/'gw'"
    [[ "$gw" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
      || die "route '$r': gateway '$gw' must be an IPv4 address"

    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
      || [[ "$addr" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\.?$ ]]; then
      : # IPv4 address or CIDR subnet
    else
      die "route '$r': '$addr' is not an IPv4 address, not a CIDR subnet (prefix 0-32) and not a domain"
    fi

    # rest of the line: only "dev <iface>" is allowed after via <gw>
    local tail
    tail=$(awk '{
      for (i=1;i<=NF;i++) if ($i=="via" || $i=="gw") { for (j=i+2;j<=NF;j++) printf "%s ", $j; exit }
    }' <<<"$r")
    tail="${tail% }"
    if [[ -n "$tail" && "$tail" != "dev "* ]]; then
      die "route '$r': only 'dev <iface>' is allowed after 'via <gw>' (got: '$tail')"
    fi
    if [[ "$tail" == dev\ * ]]; then
      local ifn="${tail#dev }"
      [[ -n "$ifn" && "$ifn" != *' '* ]] || die "route '$r': no interface given after 'dev'"
    fi
  done
}
validate_routes
log "extra routes: ${#EXTRA_ROUTES[@]}"

# ---------------------------------------------------------------------------
# validation of --exclude / --exclude-file
# Format: "<addr|domain>" — an IPv4 address, a CIDR subnet or a domain.
# No via/dev — traffic to the exceptions is directed into the host's
# main table.
# Domains are resolved later, inside the netns (after DNS is configured),
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

# ---------------------------------------------------------------------------
# unique names/subnets/identifiers for this run
# ---------------------------------------------------------------------------
PID_SUFFIX=$(( $$ % 65536 ))
OCTET=$(( ($$ % 250) + 1 ))   # 1..250 — third octet of the veth-pair subnet

NETNS_NAME="${NETNS_NAME:-netns-${PID_SUFFIX}}"
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

# ---------------------------------------------------------------------------
# autodetect the interface from the gateway and vice versa — the gateway from the interface
# ---------------------------------------------------------------------------
detect_iface() {
  local out dev
  out=$(ip -4 route get "$GATEWAY" 2>/dev/null) \
    || die "gateway $GATEWAY is unreachable from any host interface"
  dev=$(awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$out")
  [[ -n "$dev" ]] || die "failed to determine the interface for gateway $GATEWAY (output: $out)"
  echo "$dev"
}

detect_gateway() {
  local iface="$1" gw
  gw=$(ip -4 route show default dev "$iface" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
  [[ -n "$gw" ]] || die "failed to determine the default gateway for interface '$iface' (no 'default via ...' route for this interface; specify the gateway explicitly via -g)"
  echo "$gw"
}

if [[ -n "$HOST_IFACE" ]]; then
  ip link show "$HOST_IFACE" >/dev/null 2>&1 || die "interface '$HOST_IFACE' not found on the host"
fi

if [[ -z "$HOST_IFACE" ]]; then
  HOST_IFACE=$(detect_iface)
  log "host interface for gateway $GATEWAY determined automatically: $HOST_IFACE"
elif [[ -z "$GATEWAY" ]]; then
  GATEWAY=$(detect_gateway "$HOST_IFACE")
  log "default gateway for interface $HOST_IFACE determined automatically: $GATEWAY"
fi

# The interface's local (directly-connected) subnet — the same subnet
# the specified gateway resides in. Needed so that the local network
# is reachable from the netns directly rather than through GATEWAY.
detect_host_subnet() {
  ip -4 route show dev "$HOST_IFACE" scope link 2>/dev/null | awk '{print $1}' | head -n1
}
HOST_SUBNET=$(detect_host_subnet)
if [[ -z "$HOST_SUBNET" ]]; then
  log "WARNING: failed to determine the local (on-link) subnet of interface $HOST_IFACE — no direct route to the local network will be added, all traffic will go through $GATEWAY"
else
  log "local subnet of interface $HOST_IFACE: $HOST_SUBNET"
fi

log "netns=$NETNS_NAME gateway=$GATEWAY iface=$HOST_IFACE table=$TABLE_ID subnet=$NS_SUBNET user=$RUN_AS_USER"
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
    as_root iptables -D FORWARD -i "$VETH_HOST" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null
  fi
  if [[ $ADDED_FWD_RULE2 -eq 1 ]]; then
    as_root iptables -D FORWARD -i "$HOST_IFACE" -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
  fi
  if [[ $ADDED_NAT_RULE -eq 1 ]]; then
    as_root iptables -t nat -D POSTROUTING -s "$NS_SUBNET" -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null
  fi

  # deleting the netns automatically deletes the whole veth pair (both ends)
  if [[ $CREATED_NETNS -eq 1 ]]; then
    as_root ip netns delete "$NETNS_NAME" 2>/dev/null
  elif [[ $CREATED_VETH -eq 1 ]]; then
    as_root ip link delete "$VETH_HOST" 2>/dev/null
  fi

  if [[ $CREATED_RESOLV_DIR -eq 1 ]]; then
    as_root rm -rf "/etc/netns/${NETNS_NAME}" 2>/dev/null
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

# 5. DNS: by default we do nothing — without /etc/netns/<name>/resolv.conf
#    `ip netns exec` does not replace /etc/resolv.conf, and processes
#    inside the netns see the host's current resolv.conf as is. If DNS
#    is given explicitly via -d, we create a separate resolv.conf for
#    this netns.
if [[ -n "$DNS_SERVERS" ]]; then
  as_root mkdir -p "/etc/netns/${NETNS_NAME}"
  CREATED_RESOLV_DIR=1
  {
    IFS=',' read -ra _dns <<<"$DNS_SERVERS"
    for _s in "${_dns[@]}"; do echo "nameserver $_s"; done
  } | as_root tee "/etc/netns/${NETNS_NAME}/resolv.conf" >/dev/null
  log "using the specified DNS servers: $DNS_SERVERS"
else
  log "using the host's current /etc/resolv.conf unchanged"
fi

# 6'. definition of the extra-routes function (--route / --route-file)
#    For addresses/subnets — simply add them to the TABLE_ID table.
#    For domains — resolve them inside the netns (using the DNS from -d /
#    the host's resolv.conf) and add a /32 route for each address of the
#    domain.
#    The word "gw" is normalized to "via" (for ip route).
#    The call is made later (step 9), when DNS and the default route
#    already work inside the netns — then domain resolution is
#    guaranteed to succeed.
add_extra_routes() {
  local r addr gw rest dev dst ip
  for r in "${EXTRA_ROUTES[@]}"; do
    addr="${r%%[[:space:]]*}"
    # normalize "gw" -> "via" for ip route
    r=$(awk '{
      for (i=1;i<=NF;i++) if ($i=="gw") $i="via";
      print
    }' <<<"$r")
    gw=$(awk '{for(i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"$r")
    rest=$(awk '{for(i=1;i<=NF;i++) if ($i=="via") { for (j=i+2;j<=NF;j++) printf "%s ", $j; exit }}' <<<"$r")
    rest="${rest% }"
    dev=""
    if [[ "$rest" == dev\ * ]]; then
      dev="${rest#dev }"
      rest="dev ${dev}"
    fi

    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      # replace (rather than add) so the route does not fail on a re-run
      # or on a subnet overlapping the already added default (0.0.0.0/0)
      as_root ip route replace "$addr" via "$gw" $rest table "$TABLE_ID" \
        || die "failed to add route '$r' to table $TABLE_ID"
      log "route added: $addr via $gw $rest (table $TABLE_ID)"
    else
      # domain: resolve all A records inside the netns
      log "resolving domain '$addr' inside the netns..."
      mapfile -t _ips < <(as_root ip netns exec "$NETNS_NAME" \
        nslookup "$addr" 2>/dev/null \
        | awk '/^Address[0-9 ]*:/ {print $NF}' | sort -u)
      [[ ${#_ips[@]} -gt 0 ]] || die "failed to resolve domain '$addr'"
      for ip in "${_ips[@]}"; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        as_root ip route add "$ip/32" via "$gw" $rest table "$TABLE_ID" \
          || log "WARNING: route to $ip not added (it may already exist)"
        log "route added: $ip/32 via $gw $rest (table $TABLE_ID, domain $addr)"
      done
    fi
  done
}

# 6''. definition of the exceptions function (--exclude / --exclude-file)
#    For the listed addresses/subnets/domains, traffic from the netns
#    must follow the host's system routing. Achieved with an ip rule
#    with a HIGHER priority (lower number) than the main netns rule:
#      ip rule add pref <EXCLUDE_RULE_PRIO> from <NS_SUBNET> to <addr> table main
#    For domains we resolve all A records inside the netns and add a
#    rule for each address (/32). The call is made later (step 10),
#    when DNS and the default route already work inside the netns.
add_exclude_rules() {
  local e addr ip
  for e in "${EXCLUDED_ADDRS[@]}"; do
    addr="${e%%[[:space:]]*}"

    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      as_root ip rule add pref "$EXCLUDE_RULE_PRIO" from "$NS_SUBNET" to "$addr" table main \
        || die "failed to add the exception rule for '$addr'"
      ADDED_EXCLUDE_RULE=1
      log "exception: traffic to $addr directed into the main table (rule pref $EXCLUDE_RULE_PRIO)"
    else
      # domain: resolve all A records inside the netns
      log "resolving domain '$addr' inside the netns (exception)..."
      mapfile -t _ips < <(as_root ip netns exec "$NETNS_NAME" \
        nslookup "$addr" 2>/dev/null \
        | awk '/^Address[0-9 ]*:/ {print $NF}' | sort -u)
      [[ ${#_ips[@]} -gt 0 ]] || die "failed to resolve domain '$addr' (exception)"
      for ip in "${_ips[@]}"; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
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

# 7. outbound NAT + allowing forwarding between the veth and the external interface
as_root iptables -t nat -A POSTROUTING -s "$NS_SUBNET" -o "$HOST_IFACE" -j MASQUERADE
ADDED_NAT_RULE=1
as_root iptables -A FORWARD -i "$VETH_HOST" -o "$HOST_IFACE" -j ACCEPT
ADDED_FWD_RULE1=1
as_root iptables -A FORWARD -i "$HOST_IFACE" -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT
ADDED_FWD_RULE2=1

# 8. policy routing: all traffic from the netns subnet is forced out
#    through the specified gateway GATEWAY, regardless of the host's
#    main routing table (i.e. regardless of the host's default gateway).
#    The host's local subnet (the one GATEWAY itself resides in) is
#    added as a separate on-link route — it is more specific (a longer
#    prefix) than default, so it takes precedence in route selection,
#    and traffic to the local-network neighbors goes directly rather
#    than through GATEWAY.
if [[ -n "$HOST_SUBNET" ]]; then
  as_root ip route add "$HOST_SUBNET" dev "$HOST_IFACE" table "$TABLE_ID"
  ADDED_LOCAL_ROUTE=1
fi
as_root ip route add default via "$GATEWAY" dev "$HOST_IFACE" table "$TABLE_ID"
ADDED_ROUTE=1
as_root ip rule add pref "$RULE_PRIO" from "$NS_SUBNET" table "$TABLE_ID"
ADDED_RULE=1

# 9. extra routes (--route / --route-file) — added to the same TABLE_ID
#    table, so they apply only to traffic from the netns.
#    The default route and DNS are brought up first (above), so that for
#    domain routes the addresses are resolved inside the netns — this way
#    the DNS servers given via -d are used (and all of the domain's
#    addresses: all A records are returned).
add_extra_routes

# 10. exceptions (--exclude / --exclude-file): an ip rule with a higher
#     priority (lower pref) than the main netns rule directs traffic to
#     the listed addresses/domains into the host's main table.
#     The call is also made after DNS/default is up — domains are
#     resolved inside the netns.
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
