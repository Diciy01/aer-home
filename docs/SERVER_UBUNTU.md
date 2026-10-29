# Домашний сервер Ubuntu: AER Core + AER Remote Gateway

Для AER Connect Anywhere (ADR-017, ADR-018). Один физический Ubuntu Server с
белым статическим IPv4; без VPS и сторонних серверов. Файлы — `deploy/ubuntu/`.

**Статус: подготовлено, на реальном Ubuntu Server НЕ ПРОВЕРЕНО (UNVERIFIED).**
Проверены: Linux cross-build и `go vet` (GOOS=linux), строгий разбор
конфигураций тестом, синтаксис скриптов (`bash -n`) и функционально
`aer-admin` (учётка Gateway, код регистрации, списки, отказ на неизвестное
устройство) против локального Core на Windows. systemd, права пользователей,
TLS на сервере и публикация в интернет не проверялись.

## Схема

```
Интернет ── TCP 443 (проброс владельцем) ──► сервер:8443  aer-remote-gateway  (пользователь aer-gateway)
                                                   │ http://127.0.0.1:8787 (только loopback)
                                                   ▼
                                              aer-core  (пользователь aer-core, /var/lib/aer-home/core)
```

- **Один публичный порт**: Gateway обслуживает на одном TLS-порту API
  клиентов (`/gw/v1/*`), туннели `aer-tunnel/1`, регистрацию устройств и
  прокси агентов Host. Core слушает только `127.0.0.1:8787`.
- Разные системные пользователи: Gateway не может прочитать БД и токен
  владельца Core; у него только своя учётка агента вида `gateway`
  (systemd credential, файл `/etc/aer-home/gateway.token` 0600 root).
- Устройства AER Connect открывают к Gateway только исходящие TLS-соединения
  (NAT, CG-NAT, мобильный интернет). На клиентах порты не открываются.

## Первичная установка

На машине разработчика (или CI) соберите Linux-бинарники:

```bash
cd core
GOOS=linux GOARCH=amd64 go build -trimpath -o dist/aer-core ./cmd/aer-core
GOOS=linux GOARCH=amd64 go build -trimpath -o dist/aer-remote-gateway ./cmd/aer-remote-gateway
```

Либо используйте готовый архив `aer-server-ubuntu-*.tar.gz` (бинарники +
`deploy/ubuntu`). На сервере (нужны `curl`, `python3`; `openssl` — для
проверки отпечатка в `health`):

```bash
tar -xzf aer-server-ubuntu-20261029.tar.gz && cd aer-server-ubuntu
sudo bash deploy/install-server.sh bin
sudo systemctl enable --now aer-core
sudo aer-admin gateway-credential
sudo systemctl enable --now aer-remote-gateway
sudo aer-admin fingerprint        # SHA-256 сертификата Gateway: его сверяют/закрепляют клиенты
sudo aer-admin health
```

`install-server.sh` создаёт пользователей `aer-core`/`aer-gateway`, кладёт
бинарники в `/usr/local/bin` (предыдущие сохраняет как `.prev-<время>`),
конфиги в `/etc/aer-home` (существующие не перезаписывает), юниты в
`/etc/systemd/system` и `aer-admin` в `/usr/local/sbin`. Ничего не включает,
не запускает, не трогает firewall, SSH и роутер.

## TLS и первоначальное доверие

Gateway при первом запуске создаёт самоподписанный ECDSA-сертификат в
`/var/lib/aer-remote-gateway`. Клиенты **закрепляют** его SHA-256 (pin), CA не
используется. Первичное доверие — одно из двух:

1. Пользователь вводит адрес и сверяет показанный отпечаток с `aer-admin
   fingerprint` (по телефону/лично), затем ставит галочку «Отпечаток совпадает».
2. Владелец собирает пакет AER Connect с `connect.json`
   (`package-connect.ps1 -GatewayAddress … -GatewayFingerprint …`): тогда
   приложение само сверяет отпечаток и отказывает при несовпадении.

Ключ Gateway — его идентичность: **включайте его в резервные копии**. Новый
ключ означает новый отпечаток и повторную регистрацию всех устройств.
Свой сертификат (`tlsCert`/`tlsKey`) тоже поддерживается; pin всё равно нужен.

## Регистрация устройств AER Connect

```bash
sudo aer-admin enroll-code "Семья" 5 48     # код на 5 устройств, 48 часов; показывается один раз
sudo aer-admin enrollments                 # без самих кодов
sudo aer-admin devices                     # ID, статус online/offline/revoked/conflict
sudo aer-admin revoke-device <id>          # обе учётки устройства и его сеансы; ID не переиспользуется
```

Код регистрации — одноразовый ключ на N установок; Gateway пропускает не
более 5 попыток регистрации с адреса за 10 минут. Пароли подключения сервер
не видит (их проверяет компьютер-хост, ADR-018).

## Логи и наблюдение

- `journalctl -u aer-core -u aer-remote-gateway` (Core — JSON, Gateway — текст).
  Пароли, токены, билеты, коды и учётки в журналы не пишутся (проверено
  тестами; см. `AER_CONNECT_ANYWHERE_REPORT.md`).
- Аудит сеансов — в Core (`GET /api/v1/remote/sessions`), события устройств
  (регистрация, отзыв, блокировка после неверных паролей, клон) — в журнале
  Monitoring.
- `aer-admin health`: состояние служб, `/health` Core, `/gw/v1/health`
  Gateway, совпадение сертификата с отпечатком. Удобно запускать из cron/
  внешнего мониторинга; код возврата ≠0 при проблеме.

## Резервное копирование и восстановление

```bash
sudo aer-admin backup /var/backups/aer            # службы останавливаются на секунды
sudo aer-admin restore /var/backups/aer/aer-backup-….tar.gz --yes
```

Архив (0600) содержит БД Core, токен владельца, учётку Gateway и TLS-ключ
Gateway — храните его как секрет. При восстановлении текущее состояние не
удаляется, а переименовывается с суффиксом `-before-restore-<время>`;
удалите его сами после проверки. Рядом пишется `.sha256`, восстановление
проверяет его и отвергает архив с посторонними путями.

## Обновление

```bash
sudo aer-admin backup /var/backups/aer
sudo bash deploy/install-server.sh bin            # новые бинарники; старые — .prev-<время>
sudo systemctl restart aer-core aer-remote-gateway
sudo aer-admin health
```

Миграции БД Core аддитивны и применяются при старте. Откат: вернуть
`/usr/local/bin/*.prev-*` и восстановить резервную копию, сделанную до
обновления (новая схема БД старым бинарником не читается гарантированно).

## Публикация в интернет — отдельное решение владельца

Не выполняется ни одним скриптом. Перед публикацией нужен отдельный аудит
развёрнутой конфигурации на самом сервере. После него владелец сам:

1. На роутере пробрасывает **один** порт: WAN 443/TCP → сервер:8443.
   Core 8787, SSH, RDP, файлы и БД не пробрасываются.
2. В firewall сервера разрешает входящий 8443/TCP (например,
   `ufw allow 8443/tcp`) — только если firewall включён и это его решение.
3. Клиенты используют `IP:443` или DNS-имя, указывающее на этот IP.

Без публикации система уже работает внутри домашней сети по адресу
`сервер:8443` — удобно для первичной проверки.
