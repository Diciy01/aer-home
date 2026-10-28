# M10 Windows Desktop — приёмка 2026-10-28

Продолжение работы Claude Code на этой же Windows, без сброса Git и без push. Инструкции сборки, пакета, конфигурации и ограничения Host — [WINDOWS.md](WINDOWS.md).

## Принятая работа

Входной HEAD `b464b2e276171bf9e2393f2e65fdff42fce242a2`, ветка `main`, 28 локальных коммитов поверх `origin/main`. Изменённых отслеживаемых файлов не было; два untracked примера `deploy/remote-host.windows.example.json` и `deploy/power-host.windows.example.json` сохранены и проверены.

Коммиты Claude: `fe99701` (Core/netx/переносимость Go), `09a2d33` (Windows scene cache/remotelab), `6bd1ed2` (Windows FreeRDP, DLL, TCP IPv4/IPv6, настоящая RDP-ретрансляция), `b464b2e` (MultiSZ дисков, SCM вместо локализованного sc, декодирование Event Log). Они не дублировались и не переписывались.

Сборок и активного Claude при передаче не обнаружено; оставался `aer-agent.exe` PID 7144 с конфигом `E:/dev/temp/aer-m10-live`. Его не прерывали. Исходный стенд Core на 18787 уже не слушал. Системные listener'ы не затрагивались. Тесты Codex использовали новый каталог `E:/dev/temp/codex-m10-1b2c33bb6cf241cb88e68357ea54aa97`, случайные loopback-порты, свои процессы. Существующие тестовые каталоги сохранены.

Результат последней проверки Claude восстановлен точно: в коммите `b464b2e` и кэше Monitoring есть настоящий online/CPU/RAM/C:/D:/E:, но `E:/dev/logs/live-monitoring.log` содержит **FAIL** UI-теста на строке 192: не было ни одной записи журнала. Прежний сквозной UI-прогон не засчитан как PASS. Новый тест создаёт явно синтетический UTF-8 warning через агентский API; реальные метрики поступают от настоящего Windows-агента. Event Log ОС не изменяется.

## Исправления и завершение

- Windows Bots: убийство родительского shell оставляло потомков с открытыми stdout/stderr и срывало restart. Теперь отдельный unnamed Job Object с `KILL_ON_JOB_CLOSE`; запуск приостановлен до назначения в Job, остановка по handle, без охоты за чужими PID. Сохранились POSIX-группы процессов Linux. Проверка пересечения действий синхронизируется на поддельном адаптере, а не зависит от скорости остановки Windows. CPU/RAM отдельного процесса Bots по-прежнему только Linux; системные CPU/RAM Windows собирает Monitoring Agent.
- Dart FFI: полное имя DLL само по себе не обеспечивало поиск её зависимостей из процесса SDK Dart. `LoadLibraryExW` загружает зависимости из каталога DLL и безопасных стандартных каталогов, без правки PATH/глобального DLL search path. Windows больше не ищет `aer_rdp.dll` по произвольному относительному имени.
- Просмотр: первый статичный кадр мог уйти до подписки страницы Flutter. Новый подписчик сразу получает последний кадр. Начальная ошибка TLS pin теперь сохраняет `failed` после освобождения native handle. При закрытии освобождаются кэш кадра и ссылка на credentials.
- `windows-rdp` больше не выдаёт небезопасный сеанс по факту доступности порта: `ready=false`, capabilities выключены, `Open` отказывает. Генерируемый агентом сертификат не является сертификатом системного Windows RDP, а пустой `Close` не отзывал доступ; это нельзя считать готовым Host. `windows-shadow` не реализован, остаётся M14.4.
- Пример Windows Power Host работает в `execute=false`; проверка Linux `bootNextHelper` больше не мешает загрузке Windows-конфига. Никакие power/BCD/EFI команды при проверке примера не запускаются.
- Desktop: нативный трей, скрытие/возврат/выход, счётчик новых уведомлений Monitoring через Shell API с подавлением повтора при старте/восстановлении связи. В оболочку не передаются тексты журналов и имена устройств.
- Поставка: app-local release CRT, все DLL FreeRDP/OpenSSL и плагины, упаковка с лицензиями, пользовательский PowerShell-установщик, безопасное удаление по SHA-256 без удаления данных/изменённых файлов. Нет служб/автозапуска/firewall/RDP-настроек.

## Матрица проверки

Все команды ниже запускались на настоящей Windows 11 build 26300.9711, ru-RU. Стендовые результаты не означают проверку настоящего Windows-сеанса или интернета.

| Проверка | Статус | Артефакт / предел |
|---|---|---|
| `go test ./...` | PASS | `E:/dev/logs/codex-m10-go-test-final.log`; первоначальные сбои Bots исправлены |
| `go vet ./...` | PASS | `codex-m10-go-vet-final.log` |
| Windows Bots, 3 повтора | PASS | `codex-m10-bots-repeat.log`; настоящий изолированный дочерний процесс, фальшивые данные/адаптер concurrency |
| TCP IPv4/IPv6, 20 повторов | PASS | `go test ./internal/remotehost -run TestEstablishedCountsRealConnections -count=20`; реальные loopback-соединения |
| Windows Agent → изолированный Core | PASS | `codex-m10-monitoring-live.log`; настоящий heartbeat, CPU, RAM, C:/D:/E:, cancellation и отказ отозванному токену, без токенов в логах |
| Go Linux `GOOS=linux go build ./...` | PASS | `codex-m10-linux-cross-build.log`; исполнение Linux и native FreeRDP Linux в этой сессии UNVERIFIED |
| Dart analyze | PASS | `codex-m10-dart-analyze-final.log` |
| Dart test с sample/remotelab | PASS | `codex-m10-dart-test-final.log`: 11 passed, 2 Linux/GNOME live tests skipped |
| Flutter analyze / widget tests | PASS | `codex-m10-flutter-analyze-final.log`, `codex-m10-flutter-test-final.log`; 215 тестов |
| Flutter Windows Release | PASS | `codex-m10-release-final.log`; FreeRDP включён |
| Настоящий UI: все 8 разделов + Gateway viewer | PASS | `codex-m10-desktop-live.log`; навигация кликами, настоящий кадр во Flutter, мышь/скан-коды, запрет clipboard/files, переподключение, отзыв убирает viewer |
| Настоящий UI Monitoring | PASS | `codex-m10-monitoring-ui.log`, 13 PNG в `.../shots`; настоящий агент + явно синтетический журнал |
| Настоящий UI при недоступном Core | PASS | `codex-m10-offline-ui.log`, 3 PNG в `.../shots-offline`; stale-кэш Monitoring и дом после остановки только своего стенда |
| Трей / Shell notification | PASS | `codex-m10-shell-live.log`; скрытие, восстановление, принятие Shell API; визуальная доставка по политике Windows UNVERIFIED |
| DPAPI в настоящем плагине | PASS | `codex-m10-secure-store-live.log`; уникальный тестовый ключ, encrypted round trip, удаление |
| Пакет / установка / переносимый запуск | PASS | ZIP `.../aer-home-windows-x64.zip`, `codex-m10-package-smoke.log`; новый каталог, NoShortcut, скрытое тестовое окно, закрытие WM_CLOSE, авторизованный снимок Core, DLL/CRT из пакета при PATH=System32 без SDK/vcpkg overrides |
| Удаление установки | PASS | Неизменённый EXE удалён, добавленный тестовый файл и изменённая лицензия сохранены; настоящий каталог пользователя/ярлык не затронут |

Прямой native-тест против sample RDP и путь Dart → Gateway → агент → sample проверяют TLS SHA-256/pin refusal, изображение, изменение кадра от мыши, отправку клавиш и Unicode `Привет`, запрет clipboard без права, учёт connect/drop, отзыв, завершение, сохранность общего `%APPDATA%/FreeRDP` и очистку временного private config. Sample не умеет NLA/clipboard; ввод кириллицы проверяет отправку и сохранение соединения, не появление текста в настоящем Windows-приложении.

В Flutter-тесте Gateway, Core и агент настоящие, но backend управления daemon поддельный: RDP — настоящий sample. Это не Windows Host. Никакой захват или SendInput в текущий desktop владельца не выполнялся.

## Что не проверено

**UNVERIFIED:** чистая Windows/VM без SDK и vcpkg; второй ПК; интернет и публикация Gateway; настоящий Windows Pro RDP/NLA; clipboard в обе стороны на Windows; Windows-host file channel; RU-раскладка/Unicode в пользовательском Windows-сеансе; multi-monitor/UAC/lock; реальный Linux runtime после изменений этой сессии; визуальная доставка системного уведомления/перезапуск Explorer; создание ярлыка в настоящем меню пользователя (изолированная установка использует NoShortcut).

**BLOCKED в пределах M10:** безопасный управляемый `windows-rdp` и `windows-shadow` отсутствуют; это отдельная реализация/приёмка M14.4. Ошибка сборки upstream shadow, имеющиеся библиотеки и ограничения DXGI/SendInput описаны в WINDOWS.md. Отсутствие Host не маскируется зелёной готовностью.

M14.1–M14.3/M14.5 и Linux M07 сохранены; M14 в целом не DONE без AER Connect и Host. M14.4 и iOS не начинались. Живая power-приёмка по-прежнему требует отдельного согласия.

## Поставка и продолжение

Пакет: `E:/dev/temp/codex-m10-1b2c33bb6cf241cb88e68357ea54aa97/aer-home-windows-x64.zip` (SHA-256 `5EE66B7150A5641D680A26C882009F6CAA7A15A16625F20E7C353A8C34D42F70`). Проверенный Release также в `apps/desktop/build/windows/x64/runner/Release`. В ZIP нет исходников SDK, vcpkg, ключей/токенов стенда и баз Core. Это пользовательский PowerShell-установщик/переносимый пакет, не MSI/MSIX; подписи нет.

M10 завершает Windows Desktop по ROADMAP: native build/tests, установка, запуск и подключение к Core, трей и уведомления. Границы проверки выше обязательны: DONE не означает готовый Windows Host или проверку интернета. Следующая отдельная задача — M14.4 по команде владельца, начиная с зафиксированных ограничений Host; до публикации желательно проверить ZIP в чистой Windows VM и решить подпись пакета.

Локальные коммиты продолжения: `3005e85` (Job Object/Bots), `3fb6e52` (DLL/кадры/ошибка pin), `2f9dde4` (безопасность Host, конфиги, Agent), `6fbfe1e` (трей/уведомления/live UI), `e5d7fc3` (пакет/установщик/smoke), затем финальный `docs(m10): record Windows desktop acceptance and host boundaries`. Финальный HEAD — `git rev-parse HEAD`; ветка `main`. Push не выполнялся. Свои Core/агенты/sample-серверы и сборки остановлены; оставшийся при передаче агент Claude PID 7144 сохранён. Порт 8787 и системные службы не затронуты.
