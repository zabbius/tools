# Environment Lifecycle (netns-run)

## Role

Полный жизненный цикл временного сетевого окружения, которое `netns-run.sh` создаёт вокруг запускаемой команды: генерация идентификаторов, поднятие netns/veth/DNS/policy routing/NAT, запуск команды и гарантированная очистка по любому способу завершения.

## Key Files

- `network/netns-run/netns-run.sh` — вся логика жизненного цикла: генерация идентификаторов, функции `cleanup`, `add_extra_routes`, `add_exclude_rules`, основной блок настройки (шаги 1–10)

## Behavior

### Генерация идентификаторов (из PID скрипта `$$`)

```
PID_SUFFIX  = $$ % 65536
OCTET       = ($$ % 250) + 1                # третий октет подсети veth, 1..250
NETNS_NAME  = netns-<PID_SUFFIX>            # либо -n
VETH_HOST   = vh-<PID_SUFFIX>;  VETH_NS = vn-<PID_SUFFIX>
TABLE_ID    = 100 + (PID_SUFFIX % 100)      # 100..199
RULE_PRIO   = 20000 + (PID_SUFFIX % 1000)
EXCLUDE_RULE_PRIO = RULE_PRIO - 10          # строго выше приоритетом основного правила
HOST_VETH_IP = 10.200.<OCTET>.1;  NS_VETH_IP = 10.200.<OCTET>.2
NS_SUBNET   = 10.200.<OCTET>.0/30
```

### Автоопределение пары шлюз/интерфейс

Требуется хотя бы один из `-g`/`-i`:

- задан `-g` → `HOST_IFACE` = `ip -4 route get GATEWAY` (awk-парсинг поля после `dev`);
- задан `-i` → `GATEWAY` = шлюз из `ip -4 route show default dev IFACE`.

Дополнительно определяется `HOST_SUBNET` (on-link подсеть интерфейса, `scope link`); если не определена — warning, и весь трафик netns идёт через шлюз, включая локальную подсеть.

### Состояние окружения

```
[аргументы/валидация] -> [sudo + keepalive] -> [сборка окружения: шаги 1..10]
        -> [запуск команды] -> [cleanup] -> [exit с кодом команды]
```

Cleanup-трап установлен на EXIT/INT/TERM с момента сборки; любой сбой шага сборки под `set -e` приводит к очистке уже созданных объектов (флаги `CREATED_*`/`ADDED_*`/`CHANGED_*` помечают, что именно было создано).

### Шаги сборки (в порядке выполнения)

| Шаг | Действие | Флаг для очистки |
|---|---|---|
| 1 | `ip netns add NETNS_NAME` | `CREATED_NETNS` |
| 2 | `ip link add VETH_HOST type veth peer name VETH_NS`; `ip link set VETH_NS netns` | `CREATED_VETH` |
| 3 | адреса `HOST_VETH_IP`/`NS_VETH_IP`, `link up`, `lo up` (внутри netns) | (покрывается veth/netns) |
| 4 | `ip netns exec ... ip route add default via HOST_VETH_IP dev VETH_NS` | (внутри netns) |
| 4' | копия `net.ipv4.ping_group_range`: чтение `/proc/sys/net/ipv4/ping_group_range` хоста (tab→space) в `PING_GROUP_RANGE` под `[[ -r ]]`; запись внутрь netns — `ip netns exec ... sysctl -qw net.ipv4.ping_group_range=...` | — |
| 5 | DNS: без `-d` ничего (хостовый resolv.conf виден как есть); с `-d` — `/etc/netns/<name>/resolv.conf` с `nameserver`-ами | `CREATED_RESOLV_DIR` |
| 6 | чтение `/proc/sys/net/ipv4/ip_forward`; если не 1 — `sysctl -qw ...=1` | `CHANGED_FORWARD` + `IP_FORWARD_ORIG` |
| 7 | `iptables -t nat -A POSTROUTING -s NS_SUBNET -o HOST_IFACE -j MASQUERADE`; два правила FORWARD (outgoing ACCEPT; incoming ESTABLISHED,RELATED) | `ADDED_NAT_RULE`, `ADDED_FWD_RULE1/2` |
| 8 | policy routing: `ip route add HOST_SUBNET dev HOST_IFACE table TABLE_ID` (если определена); `ip route add default via GATEWAY dev HOST_IFACE table TABLE_ID`; `ip rule add pref RULE_PRIO from NS_SUBNET table TABLE_ID` | `ADDED_LOCAL_ROUTE`, `ADDED_ROUTE`, `ADDED_RULE` |
| 9 | `add_extra_routes`: `--route` в TABLE_ID; для адресов/подсетей `ip route replace`, для доменов резолв внутри netns (`nslookup`, все A-записи, IPv6 игнорируется) + `ip route add <ip>/32` | `ADDED_ROUTE` |
| 10 | `add_exclude_rules`: для каждого исключения `ip rule add pref EXCLUDE_RULE_PRIO from NS_SUBNET to <addr> table main`; домены — правило на каждый резолвленный A-адрес | `ADDED_EXCLUDE_RULE` |

### Запуск команды

```
as_root ip netns exec "$NETNS_NAME" sudo -E -u "$RUN_AS_USER" -- "$@"
```

`set +e` вокруг запуска: код выхода команды сохраняется и возвращается как exit-код скрипта (после cleanup). `sudo -E` сохраняет окружение пользователя.

### Очистка (cleanup, по EXIT/INT/TERM)

Порядок (каждый шаг — только если соответствующий флаг установлен; все удаления best-effort `2>/dev/null`):

1. kill keepalive-процесса sudo (`KEEPALIVE_PID`).
2. `ip rule del pref RULE_PRIO` (основное правило); правила-исключения удаляются в цикле `while ip rule del pref EXCLUDE_RULE_PRIO` (могут быть дубликаты от нескольких адресов одного домена).
3. `ip route flush table TABLE_ID`.
4. `iptables -D` обоих правил FORWARD и правила NAT.
5. `ip netns delete` (удаляет и veth-пару) либо, если netns не создан, `ip link delete VETH_HOST`.
6. `rm -rf /etc/netns/<name>` (если создавался resolv.conf).
7. восстановление `net.ipv4.ip_forward` = `IP_FORWARD_ORIG`, если менялся.
8. `exit` с сохранённым кодом.

## Error Handling

- Все проверки до создания окружения (`die`): отсутствие утилит (`ip`, `sudo`, `iptables`), некорректный IPv4 шлюза, невалидные строки `--route`/`--exclude` (формат `<addr>`, CIDR-префикс 0–32, домен, обязательный шлюз, `dev`-хвост), нечитаемые/пустые `--route-file`/`--exclude-file` — скрипт завершается с кодом 1 и сообщением в `[netns-run] ОШИБКА: ...`, окружение не создаётся.
- Сбои внутри сборки под `set -e` прерывают скрипт; трап EXIT запускает cleanup созданных объектов.
- Недостижимый шлюз / отсутствие default-маршрута на интерфейсе / неопределённая on-link подсеть — `die` или предупреждение (см. шаг автоопределения).
- Неудачный резолв домена в `--route`/`--exclude` — `die` (после поднятия DNS внутри netns).
- Шаг 4' — best-effort: нечитаемый `/proc/sys/net/ipv4/ping_group_range` на хосте или неудачная запись значения в netns не прерывают скрипт — `[netns-run] ПРЕДУПРЕЖДЕНИЕ`, сборка продолжается (ping и `traceroute -I` у непривилегированного пользователя внутри netns могут не работать).
- Ошибки при очистке подавляются: очистка идемпотентна и не должна маскировать код выхода команды.
- Возврат кода: скрипт завершается кодом запущенной команды (`APP_EC`), а не кодом очистки.

## Invariants

- Очистка выполняется при любом способе завершения (EXIT/INT/TERM) и удаляет ровно те объекты, которые были созданы этим запуском (флаги `CREATED_*`/`ADDED_*`/`CHANGED_*`).
- Правила-исключения (`EXCLUDE_RULE_PRIO`) всегда имеют приоритет выше (меньший pref), чем основное правило netns (`RULE_PRIO`).
- Резолвинг доменов выполняется только после поднятия DNS и default-маршрута внутри netns (шаги 9–10 после шагов 4–5).
- Cleanup не маскирует код выхода команды.
- Идентификаторы (`NETNS_NAME`, `VETH_*`, `TABLE_ID`, `RULE_PRIO`, подсеть `10.200.X.0/30`) детерминированы PID запуска; параллельные запуски с разными PID не конфликтуют по veth-именам и подсетям.

## Related Specs

- [README.md](README.md) — обзор домена: цели, опции, инварианты
- [../../contracts/netns-run-host-system.md](../../contracts/netns-run-host-system.md) — системные вызовы, через которые реализованы шаги жизненного цикла
