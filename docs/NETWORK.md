# AER Network + TV (M09)

Один вид домашней сети и ТВ-стриминга: интернет, роутер, сетевые устройства, телевизор, Sunshine, ошибки и журнал проверок. Решения — ADR-015; руководство — `USER_GUIDE_NETWORK.md`; замеры и проверка — `M09_NETWORK_TV_REPORT.md`.

## Кто за что отвечает
| Что | Где |
|---|---|
| Объекты (роутер, сетевые устройства, ТВ, ПК/служба Sunshine) и их адреса | Registry |
| Доступность и задержка объектов (TCP/HTTP-проверки Core, метрика `net.latency`) | Monitoring |
| Интернет, WAN роутера (UPnP IGD), Sunshine — только текущее состояние своих проверок | модуль `network` (`net_checks`) |
| История смен состояния, журнал (`net.*`), инциденты (`network:*`), уведомления | Monitoring (через хуки) |
| Отображение | Flutter: раздел «Сеть и ТВ», панель в доме, карточка в «Обзоре» |

AER не сканирует сеть, не включает UPnP, не меняет настройки роутера/Wi-Fi/DHCP/DNS/firewall, не запускает и не настраивает Sunshine.

## Состояния
`up` Доступен · `down` Недоступен · `error` Ошибка проверки · `unconfigured` Не настроен · `unknown` Нет данных; плюс признак «устарело» (последняя проверка старше трёх интервалов) и устаревание всех данных в клиенте без связи с Core. Сбой подтверждается `failuresBeforeDown` проверками подряд. Для устройств: Monitoring `online/degraded` → Доступен, `offline` → Недоступен, нет адреса/агента → Не настроен, «ни разу не ответило»/DNS → Ошибка проверки (это не доказывает, что устройство выключено).

## Проверки модуля
- **Интернет**: цели `host:port`; `:443` и `tls://…` — TCP + TLS-рукопожатие (защита от локального TUN-прокси, который «отвечает» за любой адрес), иначе TCP (отказ = хост ответил). Задержка — время соединения (с рукопожатием для TLS).
- **Роутер**: доступность и задержка — Monitoring по адресу из Registry. WAN — только если указан URL описания UPnP IGD: `GetStatusInfo` (`NewConnectionStatus`, `NewUptime`) и `GetCommonLinkProperties` (`NewPhysicalLinkStatus`, номинальные скорости). Только IP домашней сети, управляющий URL — тот же хост; внешний IP не запрашивается; переадресации не выполняются.
- **Sunshine**: `GET {serverInfoUrl}/serverinfo` (HTTP-порт GameStream, обычно 47989, без пароля): `state` (`*_BUSY` — идёт стрим), `appversion`, `currentgame`. Остальные поля ответа (имя, MAC, IP, uniqueid) не разбираются и не хранятся. Веб-интерфейс — только TCP-доступность порта; открывается кнопкой в системном браузере (только http/https). ТВ (`tvEntityId`) и ПК/служба (`entityId`) показываются со своими собственными состояниями.

## Журнал и инциденты
- Логи Monitoring, источники `net.internet`, `net.router_wan`, `net.sunshine`: смена состояния (info/warning) и сбой — не чаще раза в 5 минут; перед записью — `Redact`.
- События Monitoring `net_down`, `net_error`, `net_recovered` (у интернета — без объекта).
- Инциденты `network:internet` (critical), `network:router:<id>` (critical), `network:sunshine:<id>` (warning): открываются при переходе в сбой, группируются Monitoring (один на ключ), закрываются при восстановлении. Сроки хранения и ротация — `MONITORING.md`.
- Статус каждой проверки виден в Monitoring → «Источники данных» (`net:*`).

## API (контракт 0.10.0)
| Метод | Путь | |
|---|---|---|
| GET | `/network/overview` | сводка, интернет, роутеры (+WAN), устройства, ТВ, Sunshine (+объект, +ТВ), открытые инциденты, последние строки `net.*` |
| POST | `/network/check` | выполнить проверки сейчас (не чаще раза в 5 с, иначе 409) и вернуть обзор |
Журнал целиком — `GET /monitoring/logs?source=net.`.

## Конфигурация Core (`network`, пример `deploy/core-network.example.json`)
`intervalSec` (30), `timeoutSec` (5), `failuresBeforeDown` (2), `internet.targets` ([] — не настроено), `routers[] = {entityId, upnpUrl}`, `sunshine[] = {id, name, entityId, tvEntityId, serverInfoUrl, webUrl}`. URL с учётными данными отклоняются при запуске. Модуль выключается `"modules": {"network": false}`.
