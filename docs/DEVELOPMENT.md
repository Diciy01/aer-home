# Разработка и запуск (M01 Foundation)

## Инструменты
- Go 1.27.3: `<tools>/go-1.27.3/go/bin` (не в PATH профиля). В сессии:
  `export PATH=<tools>/go-1.27.3/go/bin:$PATH`
- Flutter 3.47.7 (уже в PATH).

## AER Core
```bash
cd core
go test ./...            # unit + integration + contract
go vet ./...
gofmt -l .               # должно быть пусто
go build -o bin/aer-core ./cmd/aer-core
./bin/aer-core           # http://127.0.0.1:8787, режим development
```
Первый запуск создаёт `~/.local/share/aer-home/core/aer-core.db` и `core.token` (0600). Сам токен не печатается.

Конфигурация (приоритет: defaults < JSON-файл < env):

| Env | JSON | По умолчанию |
|---|---|---|
| `AER_CONFIG` / `-config` | — | нет |
| `AER_MODE` | `mode` | `development` (только loopback) |
| `AER_LISTEN` | `listenAddr` | `127.0.0.1:8787` |
| `AER_DATA_DIR` | `dataDir` | `$XDG_DATA_HOME` или `~/.local/share/aer-home/core` (Windows: `%LOCALAPPDATA%\aer-home\core`) |
| `AER_LOG_LEVEL` | `logLevel` | `info` |
| `AER_LOG_FORMAT` | `logFormat` | `text` (`json`) |
| — | `modules: {"name": false}` | все модули включены |

Секреты в конфиг не кладутся (неизвестные поля отклоняются).

Проверка вручную:
```bash
curl -s localhost:8787/api/v1/health
curl -s -H "Authorization: Bearer $(cat ~/.local/share/aer-home/core/core.token)" localhost:8787/api/v1/system/info
```

## Desktop
```bash
cd apps/desktop
flutter analyze
flutter test
flutter run -d linux                    # или
flutter build linux --release && build/linux/x64/release/bundle/aer_home_desktop
```
Переопределения: `AER_CORE_URL` (по умолчанию `http://127.0.0.1:8787`), `AER_CORE_TOKEN_FILE`.
Без запущенного Core клиент стартует и показывает «Core недоступен».

## Живая проверка Registry (integration_test)
Сквозной тест реального приложения на Linux против запущенного Core (мастер, связи, правка, поиск, архив) с PNG-скриншотами. Запускать **только** с изолированным каталогом данных:
```bash
D=$(mktemp -d); mkdir $D/shots
AER_DATA_DIR=$D AER_LISTEN=127.0.0.1:18787 core/bin/aer-core &
cd apps/desktop
AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token AER_SCREENSHOT_DIR=$D/shots \
  flutter test integration_test -d linux
```
Без `AER_CORE_URL` тест пропускается. Все создаваемые объекты помечены «(тест)».

## Сцена (M03): живая проверка и замеры
```bash
D=$(mktemp -d); mkdir -p $D/shots $D/desktop
AER_DATA_DIR=$D AER_LISTEN=127.0.0.1:18787 core/bin/aer-core &
cd apps/desktop
# скриншоты всех экранов против реального Core (объекты Registry «(тест)»)
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token \
  AER_DESKTOP_DATA_DIR=$D/desktop AER_SCREENSHOT_DIR=$D/shots \
  flutter test integration_test/scene_live_test.dart -d linux
# то же после остановки Core: AER_EXPECT_OFFLINE=1 (проверка офлайн-кэша)
# FPS/кадры (profile):
AER_WINDOW_SIZE=1920x1080 flutter drive --profile --driver=test_driver/integration_test.dart \
  --target=integration_test/scene_perf_test.dart -d linux   # → build/integration_response_data.json
```
Переменные клиента: `AER_DESKTOP_DATA_DIR` — каталог офлайн-кэша сцены; `AER_WINDOW_SIZE=WxH` — начальный размер окна (Linux); `AER_SCENE_FPS_LOG=1` — печать кадров сцены в секунду.

## Редактор (M04): тесты, живая проверка, замеры
Юнит- и виджет-тесты редактора — `apps/desktop/test/scene/editor/` (команды и история, проверка размещения и каталог, контроллер с фейковыми Core/Registry, черновик на реальных файлах во временном каталоге, интерфейс при 1366×768 и 1920×1080, горячие клавиши, drag-and-drop). Входят в обычный `flutter test`.
```bash
D=$(mktemp -d); mkdir -p $D/shots $D/desktop
AER_DATA_DIR=$D AER_LISTEN=127.0.0.1:18787 core/bin/aer-core &
cd apps/desktop
# весь путь пользователя мышью против реального Core: строительство, каталог, размещение,
# перетаскивание, привязка, новая комната, размер, Undo/Redo, сохранение, конфликт, перезапуск, черновик
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token \
  AER_DESKTOP_DATA_DIR=$D/desktop AER_SCREENSHOT_DIR=$D/shots \
  flutter test integration_test/editor_live_test.dart -d linux
# замеры 35/100/200 объектов (profile); с AER_CORE_URL — ещё и сохранение большой сцены
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token \
  flutter drive --profile --driver=test_driver/integration_test.dart \
  --target=integration_test/editor_perf_test.dart -d linux   # → build/integration_response_data.json
```
`registry_live_test` рассчитывает на пустой Core — запускать на отдельном каталоге данных.

Где что лежит: каталог предметов и материалов — `lib/src/scene/catalog/scene_catalog_data.dart` (добавить предмет = запись + отрисовщик в `art/`), команды — `scene/editor/editor_commands.dart`, правила размещения — `scene/editor/placement.dart`. Новая команда редактора = класс `EditCommand` с чистым `apply` поверх `SceneEdits` + тест в `editor_commands_test.dart`.

## Изолированный запуск (не трогая реальные данные)
```bash
D=$(mktemp -d)
AER_DATA_DIR=$D AER_LISTEN=127.0.0.1:18787 core/bin/aer-core &
AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token apps/desktop/build/linux/x64/release/bundle/aer_home_desktop
```
