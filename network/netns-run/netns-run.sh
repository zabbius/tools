#!/usr/bin/env bash
#
# netns-run.sh
#
# Обёртка для запуска произвольной команды в изолированном network
# namespace (netns). Весь сетевой трафик команды принудительно
# направляется через заданный шлюз (gateway), доступный с одного из
# интерфейсов хоста. Сам этот интерфейс в netns НЕ перемещается:
# связь между netns и хостом обеспечивает пара veth, а нужный маршрут
# обеспечивается через policy routing (отдельная таблица маршрутов +
# ip rule) и NAT (iptables MASQUERADE).
#
# После завершения команды (успешного или нет) всё созданное
# окружение автоматически удаляется.
#
# Использование:
#   netns-run.sh -g GATEWAY [-i IFACE] [-n NETNS] [-d DNS1,DNS2] \
#                [-u USER] -- COMMAND [ARGS...]
#
# DNS: по умолчанию netns использует текущий resolv.conf хоста как
# есть (никаких bind-mount'ов /etc/netns/... не создаётся). Если
# нужны другие DNS-серверы — задайте их через -d.
#
# Опции:
#   -g GATEWAY   IPv4-адрес шлюза, через который должен идти весь
#                трафик приложения. Если не задан, но задан -i —
#                берётся текущий шлюз по умолчанию для этого
#                интерфейса (ip route show default dev IFACE).
#   -i IFACE     Интерфейс хоста, с которого доступен шлюз. Если не
#                задан, но задан -g — определяется автоматически
#                через `ip route get GATEWAY`.
#                Нужно задать хотя бы один из -g / -i.
#   -n NETNS     Имя network namespace. По умолчанию netns-<PID>.
#   -d DNS       DNS-серверы через запятую для netns (например
#                1.1.1.1,9.9.9.9). Если не указано — используется
#                текущий /etc/resolv.conf хоста без изменений.
#   -u USER      От чьего имени внутри netns запускать команду.
#                По умолчанию — пользователь, запустивший скрипт
#                ($SUDO_USER либо текущий).
#   --route R    Дополнительный маршрут для указанного адреса/подсети
#                или домена (используются все адреса домена). Синтаксис
#                стандартный для ip route: "<addr> via <gw> [dev <if>]"
#                (допускается также "gw" вместо "via"). Может указываться
#                несколько раз.
#   --route-file F  Файл, в каждой непустой строке которого — маршрут
#                в том же формате, что и у --route. Эквивалентно
#                нескольким --route. Может указываться несколько раз.
#   --exclude A  Адрес/подсеть или домен, трафик к которым из netns
#                направляется по системной маршрутизации хоста
#                (основная таблица, main), как если бы netns не было.
#                Может указываться несколько раз.
#   --exclude-file F  Файл, по строке на исключение (формат как у
#                --exclude). Эквивалентно нескольким --exclude.
#                Может указываться несколько раз.
#   -h           Показать эту справку.
#
# Примеры:
#   ./netns-run.sh -g 192.168.1.5 -- firefox
#   ./netns-run.sh -i eth1 -- firefox
#   ./netns-run.sh -g 10.0.0.1 -i eth1 -n vpntest -- curl -4 ifconfig.me
#
set -euo pipefail

usage() {
  cat <<'EOF'
Использование:
  netns-run.sh [-g GATEWAY] [-i IFACE] [-n NETNS] [-d DNS1,DNS2] [-u USER] -- COMMAND [ARGS...]

  -g GATEWAY   IPv4-адрес шлюза (если не задан — берётся текущий шлюз по умолчанию для -i)
  -i IFACE     интерфейс хоста (если не задан — определяется по шлюзу -g)
               нужно задать хотя бы один из -g / -i
  -n NETNS     имя network namespace (по умолчанию netns-<PID>)
  -d DNS       DNS-серверы через запятую для netns (по умолчанию — resolv.conf хоста как есть)
  -u USER      пользователь, от имени которого запускать команду в netns
  --route R    доп. маршрут: "<addr> via <gw> [dev <if>]"; addr — IP,
               подсеть CIDR (например 10.1.0.0/16) или домен (все адреса
               домена); вместо via можно писать gw. Можно несколько раз.
  --route-file F  файл с маршрутами (строка = как у --route). Можно несколько раз.
  --exclude A  адрес/подсеть CIDR или домен, трафик к которым идёт по
               системной маршрутизации хоста (main-таблица), как без netns.
               Можно указывать несколько раз.
  --exclude-file F  файл с исключениями (строка = как у --exclude). Можно несколько раз.
  -h           эта справка

Примеры:
  netns-run.sh -g 192.168.1.5 -- firefox
  netns-run.sh -i eth1 -- firefox
  netns-run.sh -g 192.168.1.5 --route "10.40.0.0/16 via 192.168.1.254" -- firefox
  netns-run.sh -g 192.168.1.5 --route "10.1.0.0/16 gw 192.168.23.100" -- curl https://example.com
  netns-run.sh -g 192.168.1.5 --exclude 192.168.23.0/24 -- curl https://example.com
  netns-run.sh -g 192.168.1.5 --route "example.com via 192.168.1.254" -- curl https://example.com
EOF
}

log()  { echo "[netns-run] $*" >&2; }
die()  { echo "[netns-run] ОШИБКА: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "требуется утилита '$1', но она не найдена в PATH"
}

as_root() {
  sudo "$@"
}

# ---------------------------------------------------------------------------
# значения по умолчанию / глобальные переменные
# ---------------------------------------------------------------------------
GATEWAY=""
HOST_IFACE=""
NETNS_NAME=""
DNS_SERVERS=""     # пусто = использовать resolv.conf хоста как есть
RUN_AS_USER="${SUDO_USER:-$(id -un)}"

EXTRA_ROUTES=()    # строки "<addr> via <gw> [dev <iface>]" из --route / --route-file
EXCLUDED_ADDRS=()  # строки "<addr|domain>" из --exclude / --exclude-file

# приоритет ip rule для исключений: должен быть МЕНЬШЕ (выше) RULE_PRIO,
# чтобы исключения срабатывали раньше правила, направляющего весь трафик
# из netns в таблицу TABLE_ID
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
# разбор аргументов
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
      [[ -n "${2:-}" && -r "$2" ]] || die "файл маршрутов не читается: '${2:-}'"
      mapfile -t _rl < <(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$2")
      [[ ${#_rl[@]} -gt 0 ]] || die "файл маршрутов пуст: '$2'"
      EXTRA_ROUTES+=("${_rl[@]}")
      shift 2 ;;
    --exclude) EXCLUDED_ADDRS+=("${2:-}"); shift 2 ;;
    --exclude-file)
      [[ -n "${2:-}" && -r "$2" ]] || die "файл исключений не читается: '${2:-}'"
      mapfile -t _el < <(sed '/^[[:space:]]*$/d;/^[[:space:]]*#/d' "$2")
      [[ ${#_el[@]} -gt 0 ]] || die "файл исключений пуст: '$2'"
      EXCLUDED_ADDRS+=("${_el[@]}")
      shift 2 ;;
    -h) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "неизвестная опция: $1 (см. -h)" ;;
    *)  break ;;
  esac
done

if [[ -z "$GATEWAY" && -z "$HOST_IFACE" ]]; then
  usage
  exit 1
fi
[[ $# -ge 1 ]] || die "не указана команда для запуска (после --)"

need_cmd ip
need_cmd sudo
need_cmd iptables

if [[ -n "$GATEWAY" ]] && ! [[ "$GATEWAY" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
  die "шлюз должен быть указан как IPv4-адрес, например 192.168.1.1"
fi

# ---------------------------------------------------------------------------
# валидация --route / --route-file
# Формат (стандартный синтаксис ip route): "<addr> via <gw> [dev <iface>]".
# Слово "gw" допускается как синоним "via": "<addr> gw <gw> [dev <iface>]".
# addr — IPv4-адрес, подсеть CIDR (/0..32) или домен; gw — IPv4-адрес шлюза.
# Домены резолвятся позже, внутри netns (после настройки DNS), поэтому
# здесь для них достаточно проверки формата имени.
# ---------------------------------------------------------------------------
validate_routes() {
  local r addr gw
  for r in "${EXTRA_ROUTES[@]}"; do
    # выдёргиваем первый токен (адрес/подсеть/домен)
    addr="${r%%[[:space:]]*}"

    case "$r" in
      *" via "*|*" gw "*) : ;;
      *) die "маршрут '$r': отсутствует ' via <gw>' или 'gw <gw>' (формат: \"<addr> via|gw <gw> [dev <iface>]\")" ;;
    esac

    gw=$(awk '{for(i=1;i<=NF;i++) if ($i=="via" || $i=="gw") {print $(i+1); exit}}' <<<"$r")
    [[ -n "$gw" ]] || die "маршрут '$r': после 'via'/'gw' не указан шлюз"
    [[ "$gw" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
      || die "маршрут '$r': шлюз '$gw' должен быть IPv4-адресом"

    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
      || [[ "$addr" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\.?$ ]]; then
      : # IPv4-адрес или подсеть CIDR
    else
      die "маршрут '$r': '$addr' — не IPv4-адрес, не CIDR-подсеть (префикс 0-32) и не домен"
    fi

    # остальная часть строки: допускается только "dev <iface>" после via <gw>
    local tail
    tail=$(awk '{
      for (i=1;i<=NF;i++) if ($i=="via" || $i=="gw") { for (j=i+2;j<=NF;j++) printf "%s ", $j; exit }
    }' <<<"$r")
    tail="${tail% }"
    if [[ -n "$tail" && "$tail" != "dev "* ]]; then
      die "маршрут '$r': после 'via <gw>' допускается только 'dev <iface>' (получено: '$tail')"
    fi
    if [[ "$tail" == dev\ * ]]; then
      local ifn="${tail#dev }"
      [[ -n "$ifn" && "$ifn" != *' '* ]] || die "маршрут '$r': после 'dev' не указан интерфейс"
    fi
  done
}
validate_routes
log "доп. маршрутов: ${#EXTRA_ROUTES[@]}"

# ---------------------------------------------------------------------------
# валидация --exclude / --exclude-file
# Формат: "<addr|domain>" — IPv4-адрес, подсеть CIDR или домен. Никаких
# via/dev — трафик к исключениям направляется в основную таблицу хоста.
# Домены резолвятся позже, внутри netns (после настройки DNS), поэтому
# здесь для них достаточно проверки формата имени.
# ---------------------------------------------------------------------------
validate_excludes() {
  local e addr
  for e in "${EXCLUDED_ADDRS[@]}"; do
    # строка должна состоять ровно из одного токена
    read -r -a _et <<<"$e"
    [[ ${#_et[@]} -eq 1 ]] || die "исключение '$e': допускается только '<addr|domain>' (один токен)"

    addr="${_et[0]}"
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
      || [[ "$addr" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\.?$ ]]; then
      : # IPv4-адрес или подсеть CIDR
    else
      die "исключение '$e': '$addr' — не IPv4-адрес, не CIDR-подсеть (префикс 0-32) и не домен"
    fi
  done
}
validate_excludes
log "исключений: ${#EXCLUDED_ADDRS[@]}"

# ---------------------------------------------------------------------------
# уникальные имена/подсети/идентификаторы для этого запуска
# ---------------------------------------------------------------------------
PID_SUFFIX=$(( $$ % 65536 ))
OCTET=$(( ($$ % 250) + 1 ))   # 1..250 — третий октет подсети veth-пары

NETNS_NAME="${NETNS_NAME:-netns-${PID_SUFFIX}}"
VETH_HOST="vh-${PID_SUFFIX}"
VETH_NS="vn-${PID_SUFFIX}"
TABLE_ID=$(( 100 + (PID_SUFFIX % 100) ))
RULE_PRIO=$(( 20000 + (PID_SUFFIX % 1000) ))
# приоритет правила-исключения: строго меньше RULE_PRIO (численно выше по
# порядку обработки) — чтобы исключения в main-таблицу работали раньше,
# чем правило, отправляющее весь трафик netns в TABLE_ID
EXCLUDE_RULE_PRIO=$(( RULE_PRIO - 10 ))

HOST_VETH_IP="10.200.${OCTET}.1"
NS_VETH_IP="10.200.${OCTET}.2"
NS_SUBNET="10.200.${OCTET}.0/30"

# ---------------------------------------------------------------------------
# автоопределение интерфейса по шлюзу и наоборот — шлюза по интерфейсу
# ---------------------------------------------------------------------------
detect_iface() {
  local out dev
  out=$(ip -4 route get "$GATEWAY" 2>/dev/null) \
    || die "шлюз $GATEWAY недостижим ни с одного интерфейса хоста"
  dev=$(awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$out")
  [[ -n "$dev" ]] || die "не удалось определить интерфейс для шлюза $GATEWAY (вывод: $out)"
  echo "$dev"
}

detect_gateway() {
  local iface="$1" gw
  gw=$(ip -4 route show default dev "$iface" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
  [[ -n "$gw" ]] || die "не удалось определить шлюз по умолчанию для интерфейса '$iface' (для этого интерфейса нет маршрута default via ...; задайте шлюз явно через -g)"
  echo "$gw"
}

if [[ -n "$HOST_IFACE" ]]; then
  ip link show "$HOST_IFACE" >/dev/null 2>&1 || die "интерфейс '$HOST_IFACE' не найден на хосте"
fi

if [[ -z "$HOST_IFACE" ]]; then
  HOST_IFACE=$(detect_iface)
  log "автоматически определён интерфейс хоста для шлюза $GATEWAY: $HOST_IFACE"
elif [[ -z "$GATEWAY" ]]; then
  GATEWAY=$(detect_gateway "$HOST_IFACE")
  log "автоматически определён шлюз по умолчанию для интерфейса $HOST_IFACE: $GATEWAY"
fi

# локальная (directly-connected) подсеть интерфейса — та же подсеть,
# в которой находится указанный шлюз. Нужна, чтобы из netns локальная
# сеть была доступна напрямую, а не через GATEWAY.
detect_host_subnet() {
  ip -4 route show dev "$HOST_IFACE" scope link 2>/dev/null | awk '{print $1}' | head -n1
}
HOST_SUBNET=$(detect_host_subnet)
if [[ -z "$HOST_SUBNET" ]]; then
  log "ПРЕДУПРЕЖДЕНИЕ: не удалось определить локальную (on-link) подсеть интерфейса $HOST_IFACE — прямой маршрут в локальную сеть добавлен не будет, весь трафик пойдёт через $GATEWAY"
else
  log "локальная подсеть интерфейса $HOST_IFACE: $HOST_SUBNET"
fi

log "netns=$NETNS_NAME gateway=$GATEWAY iface=$HOST_IFACE table=$TABLE_ID subnet=$NS_SUBNET user=$RUN_AS_USER"
if [[ ${#EXCLUDED_ADDRS[@]} -gt 0 ]]; then
  log "исключений: ${#EXCLUDED_ADDRS[@]} (rule pref $EXCLUDE_RULE_PRIO, table main)"
fi

# ---------------------------------------------------------------------------
# очистка окружения (вызывается по EXIT/INT/TERM)
# ---------------------------------------------------------------------------
cleanup() {
  local ec=$?
  set +e
  log "выполняется очистка окружения..."

  [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null

  if [[ $ADDED_RULE -eq 1 ]]; then
    as_root ip rule del pref "$RULE_PRIO" 2>/dev/null
  fi
  # удаление всех правил-исключений данного запуска (по приоритету)
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

  # удаление netns автоматически удаляет всю veth-пару (обе стороны)
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

  log "очистка завершена"
  exit "$ec"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# настройка окружения
# ---------------------------------------------------------------------------

# кэшируем sudo-права один раз и поддерживаем их на всё время работы
# команды, чтобы не запрашивать пароль повторно
sudo -v || die "не удалось получить права sudo"
( while true; do sudo -n true 2>/dev/null; sleep 60; done ) &
KEEPALIVE_PID=$!

# 1. netns
as_root ip netns add "$NETNS_NAME"
CREATED_NETNS=1

# 2. veth-пара: один конец остаётся на хосте, второй уходит в netns
as_root ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
CREATED_VETH=1
as_root ip link set "$VETH_NS" netns "$NETNS_NAME"

# 3. адреса и поднятие интерфейсов
as_root ip addr add "${HOST_VETH_IP}/30" dev "$VETH_HOST"
as_root ip link set "$VETH_HOST" up

as_root ip netns exec "$NETNS_NAME" ip addr add "${NS_VETH_IP}/30" dev "$VETH_NS"
as_root ip netns exec "$NETNS_NAME" ip link set "$VETH_NS" up
as_root ip netns exec "$NETNS_NAME" ip link set lo up

# 4. маршрут по умолчанию внутри netns — через хостовую сторону veth
as_root ip netns exec "$NETNS_NAME" ip route add default via "$HOST_VETH_IP" dev "$VETH_NS"

# 4'. ping_group_range: per-netns sysctl, включающий непривилегированные
#     ICMP-сокеты (SOCK_DGRAM, IPPROTO_ICMP) — их используют ping и
#     traceroute -I. Host-systemd задаёт это значение только в initial
#     netns (/usr/lib/sysctl.d/50-default.conf); в новый netns оно
#     автоматически не попадает, поэтому копируем текущее значение хоста:
#     читаем его из /proc/sys хоста (tab -> space) в переменную, затем
#     записываем только внутрь собственного netns (хост не затрагивается),
#     значение умирает вместе с netns — cleanup не нужен.
#     Сбой не фатален: назначение скрипта — запуск команды, ping — лишь
#     диагностика.
PING_GROUP_RANGE=""
if [[ -r /proc/sys/net/ipv4/ping_group_range ]]; then
  PING_GROUP_RANGE=$(tr '\t' ' ' < /proc/sys/net/ipv4/ping_group_range)
else
  log "ПРЕДУПРЕЖДЕНИЕ: не удалось прочитать host-значение net.ipv4.ping_group_range — ping и traceroute -I внутри netns могут не работать"
fi
if [[ -n "$PING_GROUP_RANGE" ]]; then
  if ! as_root ip netns exec "$NETNS_NAME" \
       sysctl -qw "net.ipv4.ping_group_range=$PING_GROUP_RANGE"; then
    log "ПРЕДУПРЕЖДЕНИЕ: не удалось задать net.ipv4.ping_group_range в netns — ping и traceroute -I у непривилегированного пользователя могут не работать"
  else
    log "ping_group_range в netns: $PING_GROUP_RANGE (копия значения хоста)"
  fi
fi

# 5. DNS: по умолчанию ничего не делаем — без /etc/netns/<name>/resolv.conf
#    `ip netns exec` не подменяет /etc/resolv.conf, и процессы внутри
#    netns видят текущий resolv.conf хоста как есть. Если DNS задан
#    явно через -d, создаём отдельный resolv.conf для этого netns.
if [[ -n "$DNS_SERVERS" ]]; then
  as_root mkdir -p "/etc/netns/${NETNS_NAME}"
  CREATED_RESOLV_DIR=1
  {
    IFS=',' read -ra _dns <<<"$DNS_SERVERS"
    for _s in "${_dns[@]}"; do echo "nameserver $_s"; done
  } | as_root tee "/etc/netns/${NETNS_NAME}/resolv.conf" >/dev/null
  log "используются заданные DNS-серверы: $DNS_SERVERS"
else
  log "используется текущий /etc/resolv.conf хоста без изменений"
fi

# 6'. определение функции доп. маршрутов (--route / --route-file)
#    Для адресов/подсетей — просто добавляем в таблицу TABLE_ID.
#    Для доменов — резолвим внутри netns (с учётом DNS из -d / resolv.conf
#    хоста) и добавляем по маршруту /32 на каждый адрес домена.
#    Слово "gw" нормализуется к "via" (для ip route).
#    Вызов делается позже (шаг 9), когда в netns уже работают DNS и
#    default-маршрут — тогда резолв домена гарантированно проходит.
add_extra_routes() {
  local r addr gw rest dev dst ip
  for r in "${EXTRA_ROUTES[@]}"; do
    addr="${r%%[[:space:]]*}"
    # нормализуем "gw" -> "via" для ip route
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
      # replace (а не add), чтобы маршрут не падал на повторном запуске
      # и на подсети, перекрывающей уже добавленный default (0.0.0.0/0)
      as_root ip route replace "$addr" via "$gw" $rest table "$TABLE_ID" \
        || die "не удалось добавить маршрут '$r' в таблицу $TABLE_ID"
      log "добавлен маршрут: $addr via $gw $rest (table $TABLE_ID)"
    else
      # домен: резолвим все A-записи внутри netns
      log "резолв домена '$addr' внутри netns..."
      mapfile -t _ips < <(as_root ip netns exec "$NETNS_NAME" \
        nslookup "$addr" 2>/dev/null \
        | awk '/^Address[0-9 ]*:/ {print $NF}' | sort -u)
      [[ ${#_ips[@]} -gt 0 ]] || die "не удалось разрешить домен '$addr'"
      for ip in "${_ips[@]}"; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        as_root ip route add "$ip/32" via "$gw" $rest table "$TABLE_ID" \
          || log "ПРЕДУПРЕЖДЕНИЕ: маршрут на $ip не добавлен (возможно, уже существует)"
        log "добавлен маршрут: $ip/32 via $gw $rest (table $TABLE_ID, домен $addr)"
      done
    fi
  done
}

# 6''. определение функции исключений (--exclude / --exclude-file)
#    Для перечисленных адресов/подсетей/доменов трафик из netns должен
#    идти по системной маршрутизации хоста. Достигается ip rule с
#    приоритетом ВЫШЕ (меньше номер), чем у основного правила netns:
#      ip rule add pref <EXCLUDE_RULE_PRIO> from <NS_SUBNET> to <addr> table main
#    Для доменов резолвим все A-записи внутри netns и добавляем правило
#    на каждый адрес (/32). Вызов делается позже (шаг 10), когда в netns
#    уже работают DNS и default-маршрут.
add_exclude_rules() {
  local e addr ip
  for e in "${EXCLUDED_ADDRS[@]}"; do
    addr="${e%%[[:space:]]*}"

    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
      as_root ip rule add pref "$EXCLUDE_RULE_PRIO" from "$NS_SUBNET" to "$addr" table main \
        || die "не удалось добавить правило-исключение для '$addr'"
      ADDED_EXCLUDE_RULE=1
      log "исключение: трафик к $addr направлен в main-таблицу (rule pref $EXCLUDE_RULE_PRIO)"
    else
      # домен: резолвим все A-записи внутри netns
      log "резолв домена '$addr' внутри netns (исключение)..."
      mapfile -t _ips < <(as_root ip netns exec "$NETNS_NAME" \
        nslookup "$addr" 2>/dev/null \
        | awk '/^Address[0-9 ]*:/ {print $NF}' | sort -u)
      [[ ${#_ips[@]} -gt 0 ]] || die "не удалось разрешить домен '$addr' (исключение)"
      for ip in "${_ips[@]}"; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        as_root ip rule add pref "$EXCLUDE_RULE_PRIO" from "$NS_SUBNET" to "$ip/32" table main \
          || log "ПРЕДУПРЕЖДЕНИЕ: правило-исключение на $ip не добавлено (возможно, уже существует)"
        ADDED_EXCLUDE_RULE=1
        log "исключение: трафик к $ip/32 направлен в main-таблицу (rule pref $EXCLUDE_RULE_PRIO, домен $addr)"
      done
    fi
  done
}

# 6. форвардинг пакетов на хосте (восстанавливаем исходное значение при очистке)
IP_FORWARD_ORIG=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "$IP_FORWARD_ORIG" != "1" ]]; then
  as_root sysctl -qw net.ipv4.ip_forward=1
  CHANGED_FORWARD=1
fi

# 7. NAT наружу + разрешение форвардинга между veth и внешним интерфейсом
as_root iptables -t nat -A POSTROUTING -s "$NS_SUBNET" -o "$HOST_IFACE" -j MASQUERADE
ADDED_NAT_RULE=1
as_root iptables -A FORWARD -i "$VETH_HOST" -o "$HOST_IFACE" -j ACCEPT
ADDED_FWD_RULE1=1
as_root iptables -A FORWARD -i "$HOST_IFACE" -o "$VETH_HOST" -m state --state ESTABLISHED,RELATED -j ACCEPT
ADDED_FWD_RULE2=1

# 8. policy routing: весь трафик из подсети netns принудительно уходит
#    через указанный шлюз GATEWAY, независимо от основной таблицы
#    маршрутизации хоста (т.е. независимо от дефолтного шлюза хоста).
#    Локальная подсеть хоста (в которой находится сам GATEWAY)
#    добавляется отдельным on-link маршрутом — она более специфична
#    (длиннее префикс), чем default, поэтому имеет приоритет при
#    выборе маршрута, и трафик к соседям по локальной сети идёт
#    напрямую, а не через GATEWAY.
if [[ -n "$HOST_SUBNET" ]]; then
  as_root ip route add "$HOST_SUBNET" dev "$HOST_IFACE" table "$TABLE_ID"
  ADDED_LOCAL_ROUTE=1
fi
as_root ip route add default via "$GATEWAY" dev "$HOST_IFACE" table "$TABLE_ID"
ADDED_ROUTE=1
as_root ip rule add pref "$RULE_PRIO" from "$NS_SUBNET" table "$TABLE_ID"
ADDED_RULE=1

# 9. дополнительные маршруты (--route / --route-file) — добавляются в ту же
#    таблицу TABLE_ID, поэтому действуют только для трафика из netns.
#    Сначала поднимаем default-маршрут и DNS (выше), чтобы для доменных
#    маршрутов резолвить адреса уже внутри netns — так учитываются DNS-серверы,
#    заданные через -d (и все адреса домена: A-записи возвращаются все).
add_extra_routes

# 10. исключения (--exclude / --exclude-file): ip rule с более высоким
#     приоритетом (меньший pref), чем основное правило netns, направляет
#     трафик к перечисленным адресам/доменам в main-таблицу хоста.
#     Вызов тоже после поднятия DNS/default — резолв доменов внутри netns.
add_exclude_rules

log "окружение готово. Запуск команды от имени '$RUN_AS_USER': $*"

# ---------------------------------------------------------------------------
# запуск команды внутри netns от имени исходного пользователя
# ---------------------------------------------------------------------------
set +e
as_root ip netns exec "$NETNS_NAME" sudo -E -u "$RUN_AS_USER" -- "$@"
APP_EC=$?
set -e

log "команда завершилась с кодом выхода $APP_EC"
exit "$APP_EC"
