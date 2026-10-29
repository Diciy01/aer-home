# M14.4 — AER Connect и управляемый Windows Host

Статус: **IN_PROGRESS; ограниченная живая приёмка Windows 11 Pro — PASS; AER Connect Anywhere (ID + пароль) реализован, synthetic/integration PASS**.
Владелец отдельно разрешил текущий desktop и ввод только в безопасное окно.
2026-10-29 подтверждены настоящие DXGI/SendInput, AER Connect через Gateway,
отзыв и видимая кнопка Stop. Полная матрица Windows Home/clipboard/files/
secure desktop/реальной сети остаётся UNVERIFIED; synthetic не заменяет её.

## Правила интерфейса до реализации

Источник истины — `apps/desktop/lib/src/theme/{tokens,theme}.dart`,
`features/remote/gateway_views.dart`, `remote/remote_desktop_view.dart` и
`docs/DESIGN_TOKENS.md`. Направление: Cozy Beige Tech Home.

- Фон #F4EFE7, поверхность #FFFCF7, границы #D8CCBE, текст #40352E,
  акцент #A77E5F; состояния sage/amber/terracotta плюс текст и иконка.
- Радиусы 12/16/20, интервалы 4/8/16/24/32; шрифт существующей темы
  `Typography.blackMountainView`, переходы 150/220 мс.
- Карточки без elevation, тонкая граница, заполненные поля, существующие
  FilledButton/OutlinedButton с формой из темы, округлённые Material icons.
- Адаптация через ListView/Wrap/ограничение ширины; просмотр рабочего стола
  использует тот же Flutter-виджет и чёрные поля вокруг изображения.
- Сцена и остальные модули AER HOME в AER Connect не переносятся.

Общие токены/тема/поверхность просмотра извлекаются без изменения содержимого, старые пути
AER HOME остаются экспортами. Это позволяет продолжать визуальный стиль
без изменения существующих экранов.

## Предшествующее исправление безопасности

`e248126`: обязательный pin-only TLS файлового канала через общий движок,
запрет HTTP и redirects. Восемь локальных TLS/transfer тестов, включая
воспроизведение прежнего обхода на доверенном сертификате; analyze PASS,
вся регрессия AER HOME 223/223 PASS.

## Исправление CRT до продолжения M14.4

`bf44ef9`: изолированно воспроизведён `_CrtIsValidHeapPointer(block)`:
WinPR выделял clipboard-буферы через Release CRT, Flutter Debug viewer
освобождал их через Debug CRT. Это ошибка аллокатора на первом освобождении,
а не установленный double free. Исправлены владение буферами, CMP0091 до
`project()`, контроль CRT imports и идемпотентное асинхронное освобождение
FFI-соединения. Проверки CRT остаются включёнными.

Подробности, минимальный тест до/после, проверка конкурентных dispose и
жизненного цикла viewer: [CRT_FFI_REPORT.md](CRT_FFI_REPORT.md).

## Реализовано в рабочем срезе 2026-10-29

- `apps/connect`: отдельное Windows Flutter-приложение, собственные identity,
  DPAPI-профиль и учётка клиента `aerc1`; owner token Core не используется.
  IP/DDNS/домен, явная сверка pin, одноразовое сопряжение, разрешённые хосты,
  embedded viewer, мышь/клавиши, текстовый clipboard, ограниченные файлы,
  переподключение, завершение и отзыв. Инструкция: [AER_CONNECT.md](AER_CONNECT.md).
- `packages/aer_widgets`: общие исходные тема/токены/desktop surface;
  старые импорты AER HOME сохранены через exports. Сцена и разделы HOME
  не переносились и не переделывались.
- Файловый клиент перенесён в `aer_remote` с pin-only TLS; дополнительно
  отвергаются Windows reserved names, ADS и выход из каталога. На сервере
  `os.Root` для чтения, атомарная публикация без перезаписи через hard link,
  лимит скачивания; нужны NTFS/ext4 или другой том с hard links.
- `native/aer_shadow` и Windows `Backend`: собственные DXGI/SendInput поверх
  FreeRDP server/shadow, loopback bind, исходящий Gateway relay, локальное
  согласие на каждый сеанс и видимая кнопка Stop, права ввода/clipboard,
  сертификат и пароль на сеанс, защищённый DACL, независимый native deadline,
  завершение при lock/UAC/DXGI access-lost. Контракт 0.11.1 — добавление backend,
  существующие Linux/backend API сохранены. [WINDOWS_HOST.md](WINDOWS_HOST.md).
- Пакеты содержат app-local DLL/CRT и лицензии. Connect устанавливается
  пользовательскими PowerShell-скриптами с отдельным ярлыком и удалением по
  манифесту/хэшам. Host — переносимый пакет для ручного запуска без службы.

## Результаты проверок на этой Windows

| Проверка | Статус и свидетельство |
|---|---|
| `go test ./...` | PASS, все пакеты; `codex-m144-go-test-final.log` |
| `go vet ./...` | PASS, `codex-m144-go-vet-final.log` |
| `GOOS=linux GOARCH=amd64 go build ./...` | PASS, только cross-build; `codex-m144-linux-cross-build.log` |
| Native allocator CTest Debug | PASS 1/1, 1000 циклов; ошибочный старый вариант воспроизведён как FAIL exit 86, проверки не выключались |
| Dart analyze | PASS, без замечаний; `codex-m144-dart-analyze-final.log` |
| Dart полная suite с native DLL и synthetic Host | PASS 11, SKIPPED 7; `codex-m144-dart-test-final.log`. Пропущены 2 Linux relay и 5 прежних sample-server тестов, их повтор здесь UNVERIFIED |
| Flutter AER HOME analyze / tests | PASS, 224/224; `codex-crt-home-analyze.log`, `codex-crt-home-test.log` |
| Flutter AER Connect analyze / tests | PASS, 4 теста, включая 4 golden-состояния; `codex-m144-connect-analyze.log`, `codex-m144-connect-test.log` |
| Windows Release AER HOME / AER Connect | PASS; `codex-m144-home-release.log`, `codex-m144-connect-release-final.log` |
| Реальное Flutter-окно Connect | PASS на SYNTHETIC Host через настоящий Core/Gateway/agent/RDP: pin, pairing, кадры, input, clipboard echo, reconnect, revoke, teardown, отдельный тестовый DPAPI-ключ; `codex-crt-connect-live-after.log` |
| Native Host lifecycle | PASS 4 теста: конфигурация, два сеанса с разными сертификатами/DACL/удалением ключей, отсутствие bootstrap private key, истечение native TTL при открытом stdin без команды агента; `codex-m144-shadow-lifecycle-final.log` |
| Отрицательные права / неверный pin и пароль | PASS на настоящем RDP-протоколе с SYNTHETIC источником, включая отказ input/clipboard/files; `test/windows_shadow_test.dart` |
| Files pin trusted/untrusted CA | PASS: правильный и неправильный pin для обоих вариантов, HTTP/redirect refusal, SHA/transfer/имена; `apps/desktop/test/remote/files_client_tls_test.dart` |
| Connect установка / запуск без SDK в PATH / удаление | PASS: новый каталог, PATH=System32, package-local DLL, `--no-profile`, exit 0; сохранены добавленный файл и изменённая лицензия, удалён неизменённый EXE; `codex-m144-connect-package-smoke.log`, `codex-m144-connect-uninstall.log` |
| Start Menu shortcut | PASS: отдельная установка создала собственный ярлык, uninstaller удалил его по целевому пути; чужой ярлык не перезаписывался |
| Настоящие DXGI и SendInput | PASS в ограниченной живой приёмке Windows 11 Pro: ordinary-user Host через Explorer, первичный монитор 1920×1080, проверенное тестовое окно; подробности ниже. Elevated Host по-прежнему отвергается |
| Windows Home физически / чистая VM / второй ПК / интернет | UNVERIFIED |
| Linux native runtime после этих изменений | UNVERIFIED: Linux/WSL недоступны; cross-build не заменяет runtime |

Журналы перечислены относительно локального `E:/dev/logs/`; это результаты
сохранённых запусков, а не обещание прохождения в другом окружении.
Тестовые серверы слушали только loopback, настоящий Core 8787 и существующий
Monitoring Agent не затрагивались. Синтетический режим не вызывает DXGI,
SendInput и системный clipboard. Тестовые clipboard handlers в UI не читают
и не изменяют буфер пользователя.

## Визуальная проверка

Сопоставлены снимок AER HOME `02-device-cards.png` из M10 и живые Connect
`03-hosts.png`, `05-revoked.png`: те же фон, тонкая рамка, радиусы, кнопки,
текст и цветовые состояния. Снимки Connect находятся в
`E:/dev/temp/codex-m144-connect-shots/`; они содержат только тестовое окно.
`apps/connect/test/goldens` закрепляет pairing/fingerprint/hosts/revoked при
компактном размере. Goldens используют Ahem для воспроизводимости layout;
реальная типографика проверена на живом Flutter-окне. Отдельная палитра и
редизайн HOME не вводились. Сравнение с `e248126` подтвердило идентичность
содержимого трёх извлечённых файлов после нормализации CRLF/LF:
`tokens.dart`, `theme.dart`, `remote_desktop_view.dart`.

## Локальные артефакты

Локальные коммиты этой работы (без push):

- `e248126` — обязательный pin файлового канала независимо от доверия CA.
- `bf44ef9` — устранение CRT allocator defect, FFI ownership/disposal и регрессия.
- `1ee7f6b` — самостоятельный AER Connect, общие визуальные компоненты,
  файлы/жизненный цикл клиента и пользовательская упаковка.
- `b04f0d4` — защита файлового сервера от выхода из каталога и перезаписи.
- `10a3c1b` — Windows Host, контракт, native helper и синтетическая приёмка.
- `bd12743` — обязательные видимые consent/Stop, отказ при невозможности
  показать Stop, безопасный opt-in стенд и регрессия живой приёмки.

| Пакет | Размер / SHA-256 |
|---|---|
| `E:/dev/temp/aer-connect-m144-20261029.zip` | 16 355 160 байт; `55F9272D0F1CED77D4ABA202DB101FCB5103E6BC91F7CBE2726CEB1EEF0B3EC2` |
| `E:/dev/temp/aer-windows-host-m144-20261029.zip` | **SUPERSEDED — не использовать**: версия до исправления видимости Stop; сохранена для трассировки, новый пакет указан в живой приёмке ниже |
| **Актуальный Host** `E:/dev/temp/aer-windows-host-m144-live-20261029.zip` | 11 249 846 байт; SHA-256 `78A8D4F0784155DEFD42BE700D72E12E8D3758F61625618E48AE65046E3AF396` |

Инструменты разработчика: Go 1.27.3, Flutter 3.47.7 / Dart 3.13.5,
MSVC 14.44.35207, Windows SDK 10.0.26100, FreeRDP 3.32.2 (vcpkg x64-windows).
SDK/vcpkg используются при сборке, но не требуются пользователю пакета.
Изолированный запуск с очищенным PATH не доказывает запуск в чистой VM.
Проверка 38 собственных test/CRT-журналов и обоих ZIP не обнаружила шаблонов
полных agent/client credentials или private keys. В пакетах нет test fixtures,
token/key-файлов или каталогов тестов. Это ограниченная проверка артефактов,
не замена полного аудита безопасности.

## Ограниченная живая приёмка (2026-10-29)

Windows 11 Pro, build 26300. Host — Release, AER Connect — настоящее Flutter
Debug-приложение с FreeRDP DLL. Core/Gateway/агент работают в отдельном временном
каталоге; пользовательский Core не используется. Fixture и Host запущены
через существующий Explorer с обычным токеном; elevation проверяется до запуска
стенда и у native child. Права ОС не менялись и elevated guard не обходился.
Каждый захват начинался после ручного подтверждения production-диалога.

`apps/connect/integration_test/windows_desktop_acceptance_test.dart` проверяет
два цветных маркера собственного окна в настоящем DXGI/RDP кадре и факт
отрисовки Flutter viewer. Full desktop pixels нигде не сохраняются.
Clipboard/files принудительно отключены, тестовый профиль только в памяти.
Перед вводом сверяются свежесть status, границы первичного монитора,
`WindowFromPoint` и foreground тестового окна для клавиатуры.

| Сценарий | Подтверждённый результат |
|---|---|
| Изображение, SendInput, отзыв | **PASS**, `codex-m144-desktop-revoke-5.log`: настоящие DXGI-маркеры в Connect, один remote click и клавиша A (scan 0x1e, VK 65) получены тестовым окном. Не подтверждает кириллицу/Unicode. Route=relay, 4 980 756 байт вниз / 4 865 вверх через локальный forwarder/Gateway. Viewer и native helper отсутствуют через 486 мс после запроса отзыва по опросу теста |
| Видимый Stop | **PASS**, `codex-m144-desktop-stop-3.log`: на финальной сборке подтверждены реальный кадр и видимый/enabled production Stop; `BM_CLICK` своей кнопке завершил сеанс и native helper за 1347 мс по опросу. Повторный remote input в этом сценарии не отправлялся |
| Loopback | **PASS**: `Get-NetTCPConnection` для собственного Core/Gateway/Host показал только 127.0.0.1; локальный клиентский forwarder также loopback. Snapshot listener сохраняется в `network.json` |
| Обычные права | **PASS**: fixture/агент и все session children без elevation. Системный RDP/NLA не используется |
| Завершение | **PASS**: оба `closed.json` содержат labExited=true, exitCode=0; после завершения нет fixture/Host/Connect/стендовых Core/Gateway и принадлежащих им listener. Посторонние процессы не останавливались |
| Стиль | **PASS**: frontend продукта не изменён этим исправлением; повторно совпало содержимое извлечённых theme/tokens/desktop surface с `e248126`, 4 Connect widget/model tests с 4 goldens и 224 HOME tests прошли без обновления эталонов |

Приватные каталоги результатов (содержат временные test credentials в
`lab.json`, **не публиковать**):

- revoke: `E:/dev/temp/codex-m144-desktop-ec9204a3cfd342d28ef8d895db87c8ce`;
- Stop: `E:/dev/temp/codex-m144-desktop-4f2440299c534ef2942ac9163c9fefb3`.

В них `result.json`, `network.json` и `closed.json` содержат только метаданные
проверки, без изображений. Воспроизведение с отдельным согласием:
`tools/remote-lab/WINDOWS_DESKTOP_ACCEPTANCE.md`. Обычный `-shadow` остаётся
SYNTHETIC: для живого режима нужны одновременно дополнительный флаг и env opt-in;
production local consent сохраняется. Отсутствие второго opt-in проверено
как отказ до запуска стенда (`codex-m144-desktop-opt-in-guard.log`).

### Обнаруженный дефект и неуспешные промежуточные прогоны

Проверка видимости обнаружила **настоящий дефект Host**: скрытый запуск console
helper через STARTUPINFO/SW_HIDE также скрывал первоначальное окно Stop,
несмотря на WS_VISIBLE. Этот прогон **FAIL**, немедленно завершён до ввода.
Это соответствует [поведению первого ShowWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow).
Исправление `bd12743`: явный показ/позиционирование topmost notice, проверка
видимого enabled Stop **до запуска RDP**, прекращение сеанса при скрытии окна.
Диалог согласия также topmost (по умолчанию No), подтверждение не автоматизировано.

Другие промежуточные прогоны не считаются PASS: отменён прогон с тестовой
точкой за пределами первичного монитора; исправлены file-sharing гонки fixture
через immutable status/command snapshots; один прогон ввода остановлен при
дополнительном Space в тестовом окне, перезаписавшем LastKey (источник этого
дополнительного события не установлен); один Stop-сеанс истёк без согласия,
владелец сообщил, что диалог не виден. Управление личными окнами не выполнялось.
Успешный revoke-прогон отдельно подтверждает A и мышь; Stop принят отдельным
прогоном без повторного ввода. Старые FAIL-журналы сохранены, не подменены PASS.

### Регрессии после исправления

- Go `test ./...`, `vet ./...` — **PASS**; Windows native synthetic lifecycle,
  TLS/права/файлы включены. Linux Go cross-build — **PASS**, не runtime.
- Dart analyze — **PASS**, tests — **PASS 11 / SKIPPED 7** (Linux relay и
  прежний sample-server отдельно в этот запуск не включались).
- Connect analyze — **PASS**, tests — **PASS 4**, HOME tests — **PASS 224**.
- Native Host Windows Release build/install — **PASS**. Новый пакет указан
  в таблице артефактов; старый ZIP до исправления Stop больше не является актуальным.
- Журналы: `codex-m144-desktop-go-test.log`, `codex-m144-desktop-go-vet.log`,
  `codex-m144-desktop-linux-cross.log`, `codex-m144-desktop-dart-analyze.log`,
  `codex-m144-desktop-dart-test.log`, `codex-m144-desktop-analyze.log`,
  `codex-m144-desktop-widget.log`, `codex-m144-desktop-home-test.log`,
  `codex-m144-shadow-visible-stop-build.log`, `codex-m144-desktop-cleanup.log`
  в `E:/dev/logs`. Новый Host ZIP совпадает с проверенным native helper;
  сканирование 18 собственных desktop-журналов и пакета не выявило шаблонов
  полных credentials/private keys или вложенных тестовых token/key-файлов.

## Оставшаяся приёмка M14.4 — UNVERIFIED

1. Реальный Windows desktop: Unicode/кириллица, view-only, двусторонний OS
   clipboard, файлы и reconnect. В текущем согласованном сценарии clipboard/files
   отключены; synthetic проверки этих функций остаются PASS, не real desktop.
2. С отдельно согласованным безопасным сценарием — lock/UAC/DXGI access-lost
   и отсутствие продолжения после смены desktop. Настройки UAC не менять.
3. Windows Home, чистая Windows без SDK, длительная работа/производительность,
   масштабирование, второй физический ПК и реальная сеть/интернет.
4. Linux native runtime новых изменений — отдельная среда (WSL отсутствует).

Ограниченная живая приёмка выполнена, но полная матрица ещё не пройдена:
M14.4 остаётся **IN_PROGRESS**, не DONE. M11 CANCELLED; M13/Android/editor
не начинались. Firewall, UAC, Windows RDP, службы, драйверы и системные права
не менялись. Push не выполнялся.

## AER Connect Anywhere (2026-10-29, ADR-018)

Реализована модель «ID + пароль»: самостоятельная регистрация установки по коду
владельца, постоянный 9-значный ID, временный и постоянный пароль с проверкой
на самом хосте (сервер видит только шифротекст), автоматическое исходящее
подключение Host к Gateway с backoff/jitter, единое приложение Host + Viewer,
пакет Windows с Host-компонентами, установка с `-Upgrade`, развёртывание
Ubuntu Server (`deploy/ubuntu`, `SERVER_UBUNTU.md`). Контракт 0.12.0.

Проверено: Go (21 пакет, включая сквозной тест с перезапуском Gateway и Core),
Dart ↔ Go, synthetic RDP по ID через FreeRDP FFI, настоящее окно Flutter
(регистрация → ID/пароль → кадры → ввод → буфер → завершение → отзыв), golden,
AER HOME 224/224, CMake/CRT, установка/запуск без SDK/удаление пакета, отказ
elevated Host. Полная матрица, аудит безопасности и UNVERIFIED —
[AER_CONNECT_ANYWHERE_REPORT.md](AER_CONNECT_ANYWHERE_REPORT.md).

Не выполнялись: живой захват/ввод через новый Host-рантайм (сессия этого прогона
elevated, отдельное согласие не запрашивалось), Windows Home, реальный WAN/CG-NAT,
реальный Ubuntu Server, публикация Gateway. M14.4 остаётся IN_PROGRESS.
Firewall, UAC, RDP, службы и роутер не менялись. Push не выполнялся.
