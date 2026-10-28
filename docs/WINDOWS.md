# AER HOME на Windows (M10)

Клиент — Flutter Windows x64; Core и агенты — отдельные Go EXE. M14.4 (лёгкий AER Connect и управляемый Windows Host) в M10 не реализуется. Результаты приёмки в репозитории: `docs/M10_WINDOWS_REPORT.md`.

## Сборка разработчиком

Проверенное окружение: Windows 11 build 26300.9711 (ru-RU), Go 1.27.3, Flutter 3.47.7 / Dart 3.13.5, Visual Studio Build Tools 2022 17.14.42, Windows SDK 10.0.26100.0. Установки из этой инструкции не выполняются автоматически.

Нужны Desktop development with C++, CMake >= 3.21 и FreeRDP 3 с клиентскими библиотеками (проверено 3.32.2, vcpkg `freerdp[client]:x64-windows`). Пути SDK произвольные; ниже `$prefix` — выбранный разработчиком каталог `vcpkg/installed/x64-windows`.

```powershell
$env:AER_FREERDP_PREFIX = $prefix
cd apps/desktop
flutter analyze
flutter test
flutter build windows --release
```

Либо задайте `VCPKG_ROOT`: CMake ищет `$env:VCPKG_ROOT/installed/x64-windows`. Без FreeRDP встроенный просмотр отключён, остаётся внешний mstsc; это допустимый fallback, но не полный пакет M10. Скрипт упаковки требует DLL встроенного просмотра и release CRT, не позволяя незаметно выпустить урезанный пакет. Linux-сборка и внешний Remmina сохранены.

`aer_rdp` использует release CRT и release FreeRDP также в Debug/Profile. Flutter install копирует `aer_rdp.dll`, FreeRDP/WinPR, OpenSSL, zlib/cJSON, плагины и app-local Microsoft Visual C++ runtime рядом с EXE. CMake разрешает транзитивные runtime-зависимости. SDK, .lib, заголовки и vcpkg нужны только разработчику.

## Пакет и установка

Из корня репозитория после Release:

```powershell
./tools/windows/package.ps1 -OutputDir C:/temp/aer-home-package -FreeRdpPrefix $prefix
```

Получается ZIP с `app/`, лицензиями, `install.ps1`, `uninstall.ps1`, README. Каталог результата должен быть новым. Внутри ZIP весь runtime; не переносите один EXE. Flutter/Dart notices поставляются в `data/flutter_assets/NOTICES.Z` внутри app; лицензии нативных зависимостей — `app/licenses`. Пакет не подписан; корпоративная политика исполнения PowerShell/SmartScreen может требовать подписи владельцем. MSI/MSIX и подпись не заявлены.

После распаковки запускайте `./install.ps1`: копирование в `%LOCALAPPDATA%/Programs/AER HOME`, ярлык в меню «Пуск» текущего пользователя. Администратор не нужен. Существующий каталог и ярлык не перезаписываются: для обновления используйте новый каталог либо сначала удалите прежнюю установку. Для переносимого запуска можно открыть `app/aer_home_desktop.exe` без установки.

Удаление: `./uninstall.ps1` из каталога установки. Скрипт сверяет SHA-256 и удаляет только неизменённые файлы пакета и созданный ярлык. Добавленные/изменённые файлы, Core, токены и кэши сохраняются. Пустые каталоги могут остаться. Установщик не регистрирует службы, драйверы, автозапуск, firewall или входящий RDP.

## Core и конфигурация

Core не запускается скрытно вместе с клиентом. Для отдельного локального Core:

```powershell
cd core
go build -o bin/aer-core.exe ./cmd/aer-core
# Для стенда: отдельный каталог и свободный loopback-порт. 8787 не трогать.
$env:AER_DATA_DIR = 'C:/temp/aer-test/core'
$env:AER_LISTEN = '127.0.0.1:18887'
./bin/aer-core.exe
```

В отдельном терминале перед запуском клиента:

```powershell
$env:AER_CORE_URL = 'http://127.0.0.1:18887'
$env:AER_CORE_TOKEN_FILE = 'C:/temp/aer-test/core/core.token'
$env:AER_DESKTOP_DATA_DIR = 'C:/temp/aer-test/desktop'
./app/aer_home_desktop.exe
```

Без переопределений клиент подключается к `http://127.0.0.1:8787`, токен ищет в `%LOCALAPPDATA%/aer-home/core/core.token`. Отсутствие Core/токена отображается как ошибка связи/авторизации; кэш помечается устаревшим. Не копируйте действующий токен в конфиг/командную строку. JSON-конфиги Go сохраняйте в UTF-8 без BOM (Windows PowerShell 5 `Set-Content -Encoding UTF8` добавляет BOM; используйте редактор с UTF-8 без BOM).

Учётка Gateway хранится через `flutter_secure_storage` (Windows DPAPI). Открытый профиль не содержит секрета. `AER_REMOTE_SECRET_STORE=file` допустим только для изолированного стенда с явным `AER_DESKTOP_DATA_DIR`; реальная эксплуатация использует хранилище ОС.

## Трей и уведомления

Значок AER HOME: Open AER HOME, Hide to tray, Notifications, Exit. Обычный крестик завершает приложение; скрытие в трей выполняется явно. После перезапуска Explorer значок восстанавливается. Если оболочка не приняла значок, скрытие отключено, чтобы окно оставалось доступным.

При увеличении числа непрочитанных уведомлений Monitoring отправляется системное уведомление с числом, без текста инцидентов, имён устройств и журналов. Начальная загрузка и восстановление связи задают базовый уровень без повторного показа старых уведомлений. Щелчок по уведомлению открывает Monitoring. Переключатель действует до выхода. Windows может подавить показ (фокусировка, тихое время, политика пользователя); принятие Shell API не гарантирует визуальную доставку.

## Windows Remote Host: фактические ограничения

`deploy/remote-host.windows.example.json` — только пример диагностики `windows-rdp`. Схема принимается, но `ready=false`, desktop/input/clipboard/files не рекламируются. `Open` отказывает даже при доступном TCP-порте. Старый код отвечал `ready=true` по одному порту, генерировал сертификат, не связанный с системным RDP, и имел пустой `Close`; это не обеспечивало закрепление и отзыв. В M10 этот небезопасный путь закрыт. Пример не включает RDP и не меняет настройки ОС.

Windows Pro/Enterprise/Education могут быть системным RDP-хостом; Home — только клиентом ([Microsoft](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access)). В AER ещё нет безопасного сопоставления AER-сеанса с Windows WTS-сеансом, его настоящего сертификата, NLA-учётки и разрешений. `WTSDisconnectSession` требует права Disconnect и допускает последующее подключение — одного вызова недостаточно для отзыва AER-доступа ([WTS API](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsdisconnectsession)). Отключать текущий рабочий стол для проверки нельзя.

`windows-shadow` отсутствует в `Config.Validate` и реализации `Backend`; это **TODO M14.4**, не работающий Home Host. Сборка FreeRDP shadow CLI 3.32.2 с текущим MSVC/SDK ранее упала в `server/shadow/Win/win_wds.c`: `tagVARIANT` не содержит прямых `vt`/`pdispVal`. Локально имеются `freerdp-server3.dll/.lib`, серверные заголовки, кодеки и API peer/listener, cliprdr, drdynvc, rdpgfx, disp, ainput. Наличие библиотеки и sample-сервера доказывает только транспорт/кодеки, не захват Windows-сеанса, аутентификацию и безопасный ввод.

Запасной путь ADR-017 — собственный адаптер над libfreerdp-server3. Для него DXGI требует обработки смены desktop/режима и потери duplication, отдельного вывода/адаптера на монитор, курсора и поворота; защищённый desktop и защищённое видео ограничены ОС ([DXGI](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutput1-duplicateoutput), [Desktop Duplication](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)). `SendInput` ограничен UIPI: доступен ввод в процессы равного или меньшего integrity level; защищённый UAC/экран входа не обходится ([SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)). В M10 такой захват/ввод не запускался и адаптер не создавался.

## Воспроизводимые безопасные проверки

`go test ./...`, `go vet ./...` — из `core`; на Windows тест `TestWindowsLiveCollectorsAgainstCore` запускает настоящие сборщики против in-process Core на случайном loopback-порту, проверяет heartbeat/метрики, остановку и отзыв. `TestEstablishedCountsRealConnections` проверяет IPv4/IPv6 TCP API без системного RDP.

`dart analyze`, `dart test` — из `packages/aer_remote`; стендовые тесты без переменных окружения пропускаются, а не считаются пройденными. Для live Engine задайте `AER_REMOTELAB_BIN` (сборка `go build -o bin/aer-remotelab.exe ./cmd/aer-remotelab`).

Для настоящего RDP нужен FreeRDP **sample**, не доступ к пользовательскому desktop. Upstream sample по умолчанию может слушать все интерфейсы! До сборки примените `tools/remote-lab/sample-loopback.patch`, проверьте в исходнике `instance->Open(instance, "127.0.0.1", ...)`, затем проверьте адрес listener через `Get-NetTCPConnection`/`netstat`. Наш проверенный бинарник собран именно с таким ограничением. Не используйте произвольный sample EXE.

Переменные для `dart test test/viewer_sample_server_test.dart test/engine_test.dart`: `AER_RDP_LIB` (DLL из Release), `AER_RDP_SAMPLE_SERVER`, `AER_RDP_SAMPLE_CERT`, `AER_RDP_SAMPLE_KEY`, `AER_REMOTELAB_BIN`, `AER_RDP_SAMPLE_LOOPBACK_ONLY=1` (только после проверки ограничения сервера). В каталоге сертификата нужен `test_icon.bmp` из `server/Sample`. Ключ/сертификат только тестовые. Тесты проверяют закрепление, изображение, изменение кадра от мыши, отправку scancode/Unicode, отказ clipboard, очистку private FreeRDP config и Gateway/отзыв. Они не подтверждают кириллицу в настоящем пользовательском Windows-сеансе.

Flutter live-тесты запускаются последовательно с `-d windows`:

- `integration_test/windows_shell_live_test.dart`: трей, скрытие/возврат, отправка системного уведомления.
- `integration_test/monitoring_live_test.dart`: отдельные `AER_CORE_URL` (127.0.0.1, не 8787), `AER_CORE_TOKEN_FILE`, `AER_DESKTOP_DATA_DIR`, `AER_SCREENSHOT_DIR`, `AER_WINDOW_SIZE=1920x1080`; `AER_TEST_AGENT_BIN` создаёт тестовое устройство/учётку через клиент API, запускает только своего агента и добавляет явно синтетическую запись журнала. Метрики настоящие; запись Event Log не подделывается.
- `integration_test/windows_desktop_live_test.dart`: тот же отдельный Core и тестовый каталог; дополнительно sample/remotelab переменные выше и `AER_RDP_SAMPLE_LOOPBACK_ONLY=1` только после проверки сборки сервера. Все разделы, настоящее изображение через Gateway внутри Flutter, ввод, отключённые права, переподключение, отзыв.
- `integration_test/secure_store_live_test.dart`: только с `AER_SECURE_STORE_LIVE=1`; отдельный тестовый DPAPI-ключ удаляется в конце. Действующая учётка Gateway не затрагивается.

Без чистой VM/отдельного ПК запуск без установленного SDK/vcpkg проверяется лишь частично: копия пакета и PATH только System32, без `AER_RDP_LIB`, `AER_FREERDP_PREFIX`, `VCPKG_ROOT`. Полная чистая Windows, другая машина, интернет, NLA, clipboard в обе стороны и реальный Windows Host остаются **UNVERIFIED**.

Воспроизведение проверки пакета: `tools/windows/smoke-package.ps1 -AppDir <установка>/app -CoreUrl http://127.0.0.1:<тестовый-порт> -CoreTokenFile <тестовый-core>/core.token -DataDir <новый-каталог>`. Скрипт не читает токен: передаёт путь самому приложению, ограничивает PATH, проверяет своё скрытое окно, снимок Monitoring и фактические пути загруженных DLL, закрывает только своё окно через WM_CLOSE. Запускайте из отдельного PowerShell: окружение этого процесса меняется. Реальный Core 8787 запрещён.
