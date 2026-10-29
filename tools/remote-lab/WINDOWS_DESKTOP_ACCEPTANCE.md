# Ограниченная живая Windows-приёмка

**Только после отдельного согласия владельца на захват текущего desktop и
ввод в безопасное тестовое окно.** Это не обычный synthetic regression.
Не подтверждайте запрос согласия автоматически.

`start-windows-desktop-acceptance.ps1` запускает fixture через существующий
Explorer, без повышения прав. Fixture отвергает elevated token до запуска
Core/Gateway/агента, проверяет токены native children и создаёт собственное
тестовое окно. Свежий приватный каталог содержит только тестовые данные;
`lab.json` содержит временную owner-учётку стенда — не публиковать и не логировать.

```powershell
$run = ./tools/remote-lab/start-windows-desktop-acceptance.ps1 -LabExe C:/aer/core/bin/aer-remotelab.exe -ShadowExe C:/aer/host/aer-shadow.exe -TempRoot C:/aer/test-temp -OwnerConsented
$env:AER_DESKTOP_ACCEPTANCE = '1'
$env:AER_DESKTOP_ACCEPTANCE_DIR = $run
$env:AER_DESKTOP_ACCEPTANCE_END = 'revoke' # второй независимый прогон: stop
cd apps/connect
flutter test integration_test/windows_desktop_acceptance_test.dart -d windows
```

Нужны заранее собранные native библиотеки/viewer и рабочий Flutter Windows SDK
(см. `docs/WINDOWS.md`). `AER_RDP_LIB` при необходимости указывает на проверяемую
DLL; production-пакет использует app-local DLL.

Каждому прогону нужен новый fixture/каталог и ручное «Да» в штатном локальном
диалоге AER. Default отказ сохранён. Режим `revoke` проверяет DXGI-маркеры в
настоящем Flutter viewer, Gateway relay, мышь и клавишу A только в проверенном
окне, затем отзыв. `stop` независимо проверяет изображение и видимую кнопку
Stop, без повторной отправки ввода. Тест нажимает production-кнопку через
`BM_CLICK` только у своего native child и проверяет выход процесса.

Clipboard/files принудительно отключены. Все listener проверяются на
127.0.0.1; владелец Core не используется в Connect и хранится только в
контроллере тестового стенда для отзыва. Desktop pixels обрабатываются в памяти,
снимки рабочего стола не сохраняются. Перед вводом проверяются границы экрана,
свежесть статуса, отсутствие перекрытия тестовой точки и foreground для клавиш.
Не взаимодействуйте с другими окнами во время короткой проверки ввода.

Закрытие тестового окна, ошибка, тайм-аут или команда завершения закрывают
только принадлежащий fixture стенд. Максимальное время fixture — 12 минут.
После каждого прогона сверяйте `result.json`, `closed.json`, процессы и порты;
FAIL/отменённый прогон не является приёмкой. Временные данные автоматически
не удаляются. Отдельные неизменяемые status/command JSON исключают конфликт
Windows file sharing между PowerShell и Dart.

Без обоих условий `-desktop-acceptance` и `AER_DESKTOP_ACCEPTANCE=1`
`aer-remotelab -shadow` остаётся строго SYNTHETIC и не захватывает desktop.
Проверки elevation/secure desktop и видимого Stop в production Host не обходятся.
