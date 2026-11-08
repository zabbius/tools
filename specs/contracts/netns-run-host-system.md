# Contract: netns-run <-> Host System

## Boundary Rule

Скрипт `network/netns-run/netns-run.sh` вызывает системные утилиты хоста (`ip`, `iptables`, `sysctl`, `nslookup`, `sudo`) только через `sudo` для привилегированных операций; скрипт не модифицирует свою файловую систему вне `/etc/netns/<name>/` и не имеет права менять маршрутизацию хоста вне объектов, создаваемых им самим (таблица `TABLE_ID`, `ip rule` с его приоритетами, iptables-правила с его критериями).

## Interfaces

| Interface | Package/Binary | Consumed By | Purpose |
| --------- | -------------- | ----------- | ------- |
| `ip netns add/delete <name>` | iproute2 `ip` | сборка/очистка | создать/удалить network namespace |
| `ip link add/del <veth>` + `set <peer> netns <name>` | iproute2 `ip` | сборка/очистка | veth-пара хост↔netns |
| `ip addr add`, `link set up` (хост и внутри netns) | iproute2 `ip` | сборка | адресация и поднятие veth, `lo` |
| `ip route .../table <T>`, `ip rule add/del` | iproute2 `ip` | сборка/очистка | policy routing (таблица `100..199`, pref `20000+`, исключения в `main`) |
| `ip -4 route get <gw>` / `ip -4 route show default dev <if>` / `route show dev <if> scope link` | iproute2 `ip` | автоопределение | определить интерфейс по шлюзу, шлюз по интерфейсу, on-link подсеть |
| `iptables -t nat -A/D POSTROUTING -s <NS_SUBNET> -o <IFACE> -j MASQUERADE` | `iptables` | сборка/очистка | NAT трафика netns наружу |
| `iptables -A/D FORWARD -i/-o <VETH_HOST> ...` | `iptables` | сборка/очистка | разрешить форвардинг netns↔IFACE (out ACCEPT; in ESTABLISHED,RELATED) |
| `sysctl -qw net.ipv4.ip_forward` | `sysctl` / `/proc/sys` | сборка/очистка | включить форвардинг, восстановить исходное значение |
| `ip netns exec <ns> sysctl -qw net.ipv4.ping_group_range=<значение хоста>` | `sysctl` / `/proc/sys` | сборка (шаг 4') | копия host-значения только внутрь netns: ICMP/UDP-сокеты у непривилегированного пользователя (`ping`, `traceroute -I`) — как на хосте; хост не затрагивается, значение умирает вместе с netns |
| `ip netns exec <ns> nslookup <domain>` | `nslookup` | шаги 9–10 | резолв доменов внутри netns (A-записи) |
| `sudo` (`as_root`, `sudo -v`, keepalive `sudo -n true`, `ip netns exec ... sudo -E -u <user>`) | `sudo` | все привилегированные шаги | права root + запуск команды от имени пользователя |
| `mkdir/tee/rm -rf /etc/netns/<name>/resolv.conf` | coreutils | шаг 5 / очистка | per-netns DNS при явном `-d` |

## Initialization

- Проверка наличия `ip`, `sudo`, `iptables` в PATH (`need_cmd`) до любых привилегированных действий; `nslookup` требуется только при доменах в `--route`/`--exclude`.
- `sudo -v` кэширует учётные данные; фоновый keepalive (`sudo -n true` раз в 60с, `KEEPALIVE_PID`) поддерживает их на всё время работы команды.
- Требуется хотя бы один из `-g`/`-i`; второй выводится из первого (см. [environment-lifecycle](../domains/netns-run/environment-lifecycle.md)).

## Data Flow Across Boundary

Внутрь (скрипт → хост): последовательности `ip`/`iptables`/`sysctl` команд с параметрами, выведенными из аргументов CLI и сгенерированных из PID; текстовые файлы (`/etc/netns/<name>/resolv.conf` при `-d`).
Наружу (хост → скрипт): stdout однострочных запросов `ip` (`route get`, `route show`) и `nslookup`, парсится awk'ом; коды выхода команд; `/proc/sys/net/ipv4/ip_forward` (чтение cat'ом); `/proc/sys/net/ipv4/ping_group_range` (чтение host-значения с нормализацией tab→space, шаг 4').
К запускаемой команде: готовое netns-окружение с default-маршрутом на хостовую сторону veth, DNS (хостовый resolv.conf как есть либо заданный `-d`) и policy routing через заданный шлюз.

## Error Propagation

- Отсутствие утилиты, невалидные аргументы, недостижимый шлюз, неудачный резолв домена → `die` (exit 1, сообщение `[netns-run] ОШИБКА: ...`) — всегда до создания окружения, где это возможно.
- Сбой системной команды во время сборки под `set -e` завершает скрипт; трап EXIT выполняет best-effort очистку созданного (ошибки удаления подавляются `2>/dev/null`).
- Возврат кода: скрипт завершается кодом запущенной команды (`APP_EC`), а не кодом очистки.

## Breaking Change Checklist

If you change X, you MUST also update Y:

- Смена формата вывода, на который опирается awk-парсинг (`ip route get/show`, `nslookup`) → проверить `detect_iface`, `detect_gateway`, `detect_host_subnet`, `add_extra_routes`, `add_exclude_rules` и обновить [environment-lifecycle](../domains/netns-run/environment-lifecycle.md).
- Новая системная утилита в скрипте → добавить проверку `need_cmd` и строку в таблицу Interfaces этого контракта.
- Изменение схемы нумерации (`TABLE_ID`, `RULE_PRIO`, `EXCLUDE_RULE_PRIO`, подсеть `10.200.X.0/30`) → обновить генерацию идентификаторов, cleanup (удаление по старым приоритетам) и оба спека домена; убедиться, что диапазоны не конфликтуют с типовой конфигурацией хоста.
- Изменение состава iptables-правил → зеркально изменить блоки добавления (шаг 7) и удаления (cleanup), флаги `ADDED_*`; проверить работу без stateful-правил (conntrack недоступен → правило incoming ESTABLISHED,RELATED не сработает).
- Удаление/переименование CLI-опции → синхронно обновить `usage`, README тула и спеки домена.
- Изменение механизма DNS (`/etc/netns/<name>/resolv.conf`, bind-mount-семантика `ip netns exec`) → обновить шаг 5 в [environment-lifecycle](../domains/netns-run/environment-lifecycle.md) и README тула (поведение по умолчанию "resolv.conf хоста как есть").
