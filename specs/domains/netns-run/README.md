# netns-run

## Purpose

`netns-run` запускает произвольную команду в изолированном network namespace (netns) и принудительно направляет весь её сетевой трафик через заданный шлюз, доступный с одного из интерфейсов хоста. Маршрутизация самого хоста не меняется. Типичное применение — запуск приложения через другой канал (второй провайдер, VPN-шлюз, отдельная сетевая карта). После завершения команды всё созданное окружение автоматически удаляется.

## Key Files

- `network/netns-run/netns-run.sh` — единственный файл реализации: разбор аргументов, валидация, поднятие и очистка окружения, запуск команды
- `network/netns-run/README.md` — пользовательская документация (использование, опции, примеры, ограничения)

## Core Types

Скрипт — процедурный bash; "типами" служат глобальные массивы и скаляры состояния (из `network/netns-run/netns-run.sh`):

```bash
EXTRA_ROUTES=()    # строки "<addr> via <gw> [dev <iface>]" из --route / --route-file
EXCLUDED_ADDRS=()  # строки "<addr|domain>" из --exclude / --exclude-file

# идентификаторы окружения, генерируемые из PID скрипта
NETNS_NAME="netns-<PID_SUFFIX>"   # PID_SUFFIX = $$ % 65536
VETH_HOST="vh-<PID_SUFFIX>"; VETH_NS="vn-<PID_SUFFIX>"
TABLE_ID=$((100 + PID_SUFFIX % 100))          # номер policy-таблицы
RULE_PRIO=$((20000 + PID_SUFFIX % 1000))      # pref основного ip rule
EXCLUDE_RULE_PRIO=$((RULE_PRIO - 10))         # pref правил-исключений (выше приоритетом)
HOST_VETH_IP="10.200.<OCTET>.1"; NS_VETH_IP="10.200.<OCTET>.2"; NS_SUBNET="10.200.<OCTET>.0/30"

PING_GROUP_RANGE=""  # host-значение net.ipv4.ping_group_range для шага 4'
                     # (копируется только в netns; умирает вместе с netns — флаг очистки не нужен)

# флаги созданных объектов для очистки (CREATED_NETNS, CREATED_VETH,
# ADDED_NAT_RULE, ADDED_FWD_RULE1/2, ADDED_RULE, ADDED_EXCLUDE_RULE,
# ADDED_ROUTE, ADDED_LOCAL_ROUTE, CHANGED_FORWARD, CREATED_RESOLV_DIR)
# + IP_FORWARD_ORIG (исходное значение net.ipv4.ip_forward), KEEPALIVE_PID
```

Формат строки маршрута (`--route`): `<addr> via <gw> [dev <iface>]`, где `addr` — IPv4-адрес, подсеть CIDR (`/0`–`/32`) или домен; `gw` — IPv4-адрес; синоним `gw` вместо `via`; после шлюза допускается только `dev <iface>`. Формат исключения (`--exclude`): ровно один токен `<addr|domain>`.

## Flow

```
аргументы + валидация (--route/--exclude до sudo; некорректная строка -> die)
        │
        ▼
определение пары шлюз/интерфейс (-g <-> -i автоматически через ip route)
        │
        ▼
sudo -v + keepalive-процесс (поддержание sudo-прав на всё время работы)
        │
        ▼
1. ip netns add          2. veth-пара (host <-> netns)
3. адреса 10.200.X.1/2, link up, lo up
4. default-маршрут в netns -> хостовая сторона veth
4'. копия host-значения net.ipv4.ping_group_range в netns
    (ping/traceroute -I у непривилегированного пользователя — как на хосте;
    сбой не фатален, хост не затрагивается)
5. DNS: resolv.conf хоста как есть (или /etc/netns/<name>/resolv.conf при -d)
6. sysctl ip_forward=1 (+запомнить исходное)
7. iptables: NAT MASQUERADE из NS_SUBNET в HOST_IFACE + 2 правила FORWARD
8. policy routing: ip route (on-link HOST_SUBNET + default via GATEWAY)
   в TABLE_ID + ip rule pref RULE_PRIO from NS_SUBNET table TABLE_ID
9. add_extra_routes: --route в TABLE_ID (домены резолвятся ВНУТРИ netns, /32 на каждый A-адрес)
10. add_exclude_rules: ip rule pref EXCLUDE_RULE_PRIO from NS_SUBNET to <addr> table main
        │
        ▼
ip netns exec <netns> sudo -E -u <user> -- COMMAND
        │
        ▼ (EXIT/INT/TERM в любой момент)
cleanup(): ip rule del (осн. + исключения), flush table, iptables -D,
           ip netns delete (удаляет veth-пару), rm -rf /etc/netns/<name>,
           восстановить ip_forward; exit с кодом команды
```

## Invariants

- Хостовая маршрутизация не изменяется: все изменения (`ip rule`, `TABLE_ID`, iptables) действуют только на трафик с source из `NS_SUBNET` либо добавлены как правила форвардинга для него.
- Указанный интерфейс хоста никогда не перемещается в netns; связь хост↔netns обеспечивает veth-пара.
- Внутри netns действует host-значение `net.ipv4.ping_group_range` (копия, шаг 4'): набор ICMP/UDP-сокетных возможностей у непривилегированного пользователя (`ping`, `traceroute -I`) соответствует хосту. Host-значение никогда не изменяется; сбой копирования — non-fatal предупреждение, значение умирает вместе с netns.
- Валидация всех `--route`/`--route-file`/`--exclude`/`--exclude-file` выполняется до вызова sudo и создания окружения; некорректная строка завершает скрипт с диагностикой и кодом 1.
- Домены в `--route`/`--exclude` резолвятся внутри netns (после поднятия DNS и default-маршрута), учитывая DNS из `-d`; берутся все A-записи, IPv6 игнорируется.
- Для адресов/подсетей в `--route` используется `ip route replace` (устойчивость к перекрытию default и повторным запускам), для доменов — `ip route add <ip>/32`.
- Скрипт поддерживает `set -euo pipefail` и cleanup-трап по EXIT/INT/TERM; очистка идемпотентна (лучшие усилия, ошибки удаления подавляются) и использует флаги созданных объектов.
- Параллельные запуски безопасны: netns/veth/таблица/приоритеты генерируются из PID; возможна общая таблица у запусков с совпадающим `PID % 100` — тогда таблица общая, но маршруты через `replace` не конфликтуют.
- Инструмент ограничен IPv4: шлюз, DNS, маршруты, исключения — только IPv4.

## Configuration

Параметры задаются только CLI-опциями (конфигурационных файлов нет):

| Опция | Значение по умолчанию | Допустимые значения |
|---|---|---|
| `-g GATEWAY` | авто из `-i` (`ip route show default dev IFACE`) | IPv4-адрес |
| `-i IFACE` | авто из `-g` (`ip route get GATEWAY`) | существующий интерфейс хоста |
| `-n NETNS` | `netns-<PID % 65536>` | имя namespace |
| `-d DNS` | resolv.conf хоста как есть (без bind-mount `/etc/netns/...`) | IPv4-адреса через запятую |
| `-u USER` | `$SUDO_USER` либо текущий пользователь | имя пользователя |
| `--route` / `--route-file` | — | `<addr> via <gw> [dev <iface>]` (неск. раз, файлы: строка = маршрут, `#` — комментарий) |
| `--exclude` / `--exclude-file` | — | `<addr\|domain>` (неск. раз, файлы: строка = исключение) |

Требуемые утилиты (проверяются `need_cmd`): `ip` (iproute2), `iptables`, `sudo`; `nslookup` — только при доменах в `--route`/`--exclude`.

## Extension Points

- Новый тип цели в `--route`/`--exclude` (например, IPv6) — расширяется параллельно в `validate_routes`/`validate_excludes` (синтаксис до sudo) и `add_extra_routes`/`add_exclude_rules` (применение после поднятия DNS).
- Новое правило роутинга — добавляется в блок шагов 8–10 в `TABLE_ID` с соответствующим флагом `ADDED_*` и зеркальным удалением в `cleanup()`.
- Детальное описание жизненного цикла окружения — [environment-lifecycle.md](environment-lifecycle.md).

## Related Specs

- [environment-lifecycle.md](environment-lifecycle.md) — пошаговый жизненный цикл: создание, политика роутинга, очистка
- [../../contracts/netns-run-host-system.md](../../contracts/netns-run-host-system.md) — контракт с системными утилитами хоста (ip/iptables/sysctl/sudo)
- [../../architecture/repo-layout.md](../../architecture/repo-layout.md) — правила добавления тулзов в коллекцию
