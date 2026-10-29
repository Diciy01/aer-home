# M14.4 — AER Connect и управляемый Windows Host

Статус: **IN_PROGRESS**. Реальный захват и ввод требуют отдельного согласия владельца. Ни стенд, ни сборка не заменяют эту приёмку.

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
| Настоящие DXGI и SendInput | BLOCKED до отдельного согласия и запуска Host обычным пользователем. `--probe` текущего elevated-контекста возвращает 3, как предусмотрено защитой |
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

| Пакет | Размер / SHA-256 |
|---|---|
| `E:/dev/temp/aer-connect-m144-20261029.zip` | 16 355 160 байт; `55F9272D0F1CED77D4ABA202DB101FCB5103E6BC91F7CBE2726CEB1EEF0B3EC2` |
| `E:/dev/temp/aer-windows-host-m144-20261029.zip` | 11 249 374 байт; `90669E358722541E3687CC4A73BF77E28C4401078C604FA9FC45883C022B3FE1` |

Инструменты разработчика: Go 1.27.3, Flutter 3.47.7 / Dart 3.13.5,
MSVC 14.44.35207, Windows SDK 10.0.26100, FreeRDP 3.32.2 (vcpkg x64-windows).
SDK/vcpkg используются при сборке, но не требуются пользователю пакета.
Изолированный запуск с очищенным PATH не доказывает запуск в чистой VM.
Проверка 38 собственных test/CRT-журналов и обоих ZIP не обнаружила шаблонов
полных agent/client credentials или private keys. В пакетах нет test fixtures,
token/key-файлов или каталогов тестов. Это ограниченная проверка артефактов,
не замена полного аудита безопасности.

## Обязательная оставшаяся приёмка M14.4

1. Отдельное согласие владельца на реальный захват и ввод; Host запустить
   обычным пользователем, без повышения прав. Не ослаблять token/desktop guards.
2. На localhost проверить реальные DXGI-кадры, мышь/клавиши/Unicode только в
   отдельном тестовом окне, view-only, clipboard в обе стороны, файлы,
   видимое согласие и Stop, отзыв и повторное соединение.
3. С отдельно согласованным безопасным сценарием проверить lock/UAC/access-lost,
   отсутствие продолжения после смены desktop и освобождение ресурсов.
4. Windows Home и чистая Windows без SDK, производительность/масштабирование;
   второй физический ПК и реальная сеть — отдельно от текущего loopback.

Пока эти проверки не пройдены, Windows Host не объявляется готовым, M14.4
остаётся **IN_PROGRESS**, а не DONE. M11 остаётся CANCELLED; M13/Android/editor
не начинались. Системные службы, драйверы, Firewall и RDP не менялись.
Push не выполнялся.
