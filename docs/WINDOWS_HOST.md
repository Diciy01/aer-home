# Управляемый AER Windows Host (M14.4)

**Ограниченная живая DXGI/SendInput-приёмка на Windows 11 Pro пройдена с
отдельного согласия владельца.** Изображение в AER Connect через loopback
Gateway, мышь/клавиша только в тестовом окне, отзыв и видимый Stop — PASS.
Полная матрица (Home, OS clipboard, secure desktop, сеть) ещё UNVERIFIED.
Результаты и актуальный пакет — `M14_4_REPORT.md`.

## Внутри AER Connect (ADR-018)

С 2026-10-29 тот же Host запускается приложением AER Connect автоматически:
`aer-connect-host.exe` (дочерний процесс, секреты через stdin) управляет
`aer-shadow.exe` только для сеансов, прошедших проверку пароля хостом и
локальное согласие. Ручной `aer-remote-host` + JSON остаются для прежней схемы.
Под повышенными правами Host отказывается запускаться. Живая приёмка нового пути
запуска — UNVERIFIED (`AER_CONNECT_ANYWHERE_REPORT.md`).

## Архитектура

`aer-remote-host.exe` — существующий Go-агент. Backend `windows-shadow`
запускает `aer-shadow.exe` ровно на один разрешённый сеанс.
Серверные библиотеки FreeRDP 3 (`freerdp-server3`, `freerdp-shadow3`)
обслуживают RDP/TLS/кодеки; собственная подсистема обеспечивает DXGI Desktop
Duplication и SendInput. Upstream shadow CLI/Windows WDS не используются и
не патчатся. Системный RDP Windows не включается.

Одинаковый механизм применяется на Home и Pro. Наличие встроенного Windows
RDP не требуется; старый `windows-rdp` по-прежнему отказывает в управляемых
сеансах. Поддержка именно Windows Home на физической машине — UNVERIFIED.

Только **текущий интерактивный пользователь**, обычные права, без UIAccess.
Session 0, служба, elevated Host, закрытый/защищённый desktop отвергаются.
Readiness probe читает только доступность пользовательского desktop и DLL,
не запускает захват. Каждый сеанс требует отдельного локального подтверждения
с перечнем эффективных прав. Окно активного доступа видно на хосте;
его закрытие/Stop немедленно запрещает ввод и сигнализирует агенту.
RDP не запускается без фактически видимой enabled кнопки Stop. После
скрытого запуска console helper окно явно показывается; скрытие/сворачивание
notice во время сеанса также прекращает доступ. Диалог согласия topmost,
по умолчанию No; согласие не автоматизируется.
Агент закрывает relay/files при ближайшей проверке (обычно ≤1 с), затем
завершает принадлежащий ему процесс с ограниченным ожиданием.

Блокировка, UAC/secure desktop, потеря DXGI duplication и истечение срока
завершают доступ; автоматического продолжения захвата после такого события
нет. Повторное подключение к desktop требует нового сеанса и согласия.
SendInput не обходит UIPI и не повышает привилегии. SAS/Ctrl+Alt+Del,
управление экраном входа/UAC и повышенными приложениями не предоставляются.

## Сеть, сертификат и права

- RDP helper всегда слушает **127.0.0.1**, адрес bind не настраивается.
  На хосте не появляется LAN/WAN RDP-порт.
- Агент открывает исходящие TLS relay-ноги к собственному Gateway; файлы
  также loopback HTTPS. Direct route для `windows-shadow` отвергается.
- Для управления из-за NAT включите `agentProxy` в Gateway; `coreUrl`
  агента указывает на `https://SERVER:PORT/gw/v1/agent`. Это allow-list
  агентских API, не прокси токена владельца Core.
- Pin Gateway/Core обязателен. Подставьте реальный отпечаток, независимо
  сверенный в AER HOME, вместо `ab:ab:...` из примера.
- Пароль случаен для каждого сеанса; передаётся helper через анонимный stdin,
  не через argv/environment/SAM-файл. Пароль не относится к учётной записи Windows.
- Сертификат/ключ создаются для каждого сеанса в каталоге с защищённым DACL
  (owner/SYSTEM), NotAfter ограничен expiresAt. После закрытия ключ удаляется.
  До первого сеанса Hello содержит только публичный presence-сертификат:
  его неиспользуемый приватный ключ сразу удаляется.
- Срок ограничен Core/агентом, дополнительно монотонным таймером helper;
  максимум backend — 24 часа. Потеря Core не оставляет бессрочный доступ.
- Input и clipboard проверяет хост, даже если клиент игнорирует grant.
  Clipboard только текст, до 1 MiB. Аудио, принтеры, диски, clipboard-файлы
  и произвольные каналы перенаправления не предоставляются.
- HTTPS-файлы: только явно выбранная папка обмена, сеансовый токен,
  лимит обеих направлений, SHA-256, запрет путей/Windows devices/ADS,
  защита чтения через `os.Root`, атомарная публикация без перезаписи.
  Папка должна быть на томе с hard links (например NTFS); иначе upload
  безопасно завершается ошибкой, не подменяя существующий файл.

## Сборка и ручной запуск

Нужны инструменты разработчика из `WINDOWS.md`, FreeRDP 3.32 с server/shadow
библиотеками и cJSON. Конечному пользователю SDK/компиляторы/vcpkg не нужны.

```powershell
cmake -S native/aer_shadow -B E:/build/aer-shadow -A x64 -DCMAKE_PREFIX_PATH=$prefix -DCMAKE_INSTALL_PREFIX=E:/packages/aer-host-native
cmake --build E:/build/aer-shadow --config Release
cmake --install E:/build/aer-shadow --config Release
cd core
go build -o bin/aer-remote-host.exe ./cmd/aer-remote-host
cd ..
./tools/windows/package-host.ps1 -OutputDir E:/packages/aer-windows-host -NativeBundle E:/packages/aer-host-native -AgentExe core/bin/aer-remote-host.exe -FreeRdpPrefix $prefix
```

Распакуйте в новый пользовательский каталог. Не запускайте Host от
администратора. Скопируйте `remote-host.windows-shadow.example.json` в
собственный конфиг, задайте пути и адреса. Учётные данные агента получите в
AER HOME, храните в отдельном tokenFile с доступом только своему пользователю.
Пример безопасно начинает с view-only, clipboard/files выключены. Для управления
явно разрешите input (`shadowViewOnly:false`) и нужные права в Core/клиенте;
локальный пользователь всё равно подтверждает сеанс.

```powershell
./aer-remote-host.exe -config C:/Users/USER/AppData/Local/aer-home/remote-host.json
```

Это ручной процесс: пакет не устанавливает службу/драйвер/автозапуск, не меняет
Firewall, Windows RDP, роутер или системные сертификаты. Не запускайте пример
с placeholders и не публикуйте Core или порт helper в интернет.

## Ограничения захвата

Первая реализация захватывает первичный монитор с координатами (0,0) на
доступном DXGI adapter. Поворот монитора и размер более 8192 по стороне
отвергаются. Изменение topology, lock/UAC или access-lost заканчивает сеанс.
Multi-monitor, special/HDR/DRM surfaces, длительная производительность и
кириллица в реальном приложении — UNVERIFIED. Первичный 1920×1080, мышь,
клавиша A и видимый Stop подтверждены живой приёмкой, остальная матрица
не подменяется этими результатами.
Защищённое содержимое Windows не обходится.

`shadowSource:"synthetic"` — исключительно тестовый источник: известная
картинка, счётчики ввода и clipboard в памяти. Он не вызывает DXGI,
SendInput или системный clipboard и не доказывает готовность desktop backend.
