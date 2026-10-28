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

## Мониторинг (M05): агент, живая проверка, нагрузка
```bash
cd core && go build -o bin/aer-core ./cmd/aer-core && go build -o bin/aer-agent ./cmd/aer-agent
bin/aer-agent -once                       # что агент соберёт на этой машине (ничего не отправляет)
D=$(mktemp -d)
echo '{"monitoring":{"checkIntervalSec":5,"heartbeatTimeoutSec":20}}' > $D/core.json
AER_CONFIG=$D/core.json AER_DATA_DIR=$D AER_LISTEN=127.0.0.1:18787 bin/aer-core &
# объект + учётные данные агента: «Мониторинг → Агенты и интеграции → Добавить» или
#   POST /api/v1/registry/entities, затем POST /api/v1/monitoring/agents {entityId,name,kind}
# токен — в файл с правами 600, конфиг — по образцу deploy/agent/agent.example.json
bin/aer-agent -config agent.json &
cd ../apps/desktop
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token \
  AER_DESKTOP_DATA_DIR=$D/desktop AER_SCREENSHOT_DIR=$D/shots \
  flutter test integration_test/monitoring_live_test.dart -d linux   # + AER_EXPECT_OFFLINE=1 при остановленном Core
# синтетическая нагрузка (тестовые данные): хранилище и Core по HTTP
cd ../../core && bin/aer-monbench -mode store
bin/aer-monbench -mode http -core http://127.0.0.1:18787 -token-file $D/core.token -devices 100 -duration 120s
```
Docker-интеграция читает только локальный сокет; без запущенного Docker интерфейс показывает причину. Telegram — только при `monitoring.telegram.enabled` в конфиге Core.

## Боты (M06): тестовый бот, живая проверка, нагрузка
```bash
cd core && go build -o bin/aer-core ./cmd/aer-core && go build -o bin/aer-botbench ./cmd/aer-botbench
D=$(mktemp -d); R=$(cd .. && pwd)
# конфиг с ОДНИМ изолированным процессом-адаптером: тестовый бот без Telegram
python3 - "$D" "$R" <<'PY'
import json, sys
d, r = sys.argv[1], sys.argv[2]
json.dump({"mode": "development", "listenAddr": "127.0.0.1:18797", "dataDir": d + "/data",
           "bots": {"controllers": [{"id": "example-bot", "kind": "process", "stopTimeoutSec": 5,
                                     "allow": ["start", "stop", "restart"],
                                     "command": ["/usr/bin/python3", "-u", r + "/tools/bot-heartbeat/example_bot.py",
                                                 "--core", "http://127.0.0.1:18797", "--token-file", d + "/bot.token"]}]}},
          open(d + "/core.json", "w"))
PY
bin/aer-core -config $D/core.json &
# «Боты → Добавить бота»: тип «Процесс», адаптер example-bot, токен heartbeat → $D/bot.token (chmod 600) → «Запустить»
cd ../apps/desktop
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18797 AER_CORE_TOKEN_FILE=$D/data/core.token \
  AER_DESKTOP_DATA_DIR=$D/desktop AER_SCREENSHOT_DIR=$D/shots \
  flutter test integration_test/bots_live_test.dart -d linux   # ждёт «Тестовый бот (пример)» и бота n8n
# синтетическая нагрузка (тестовые данные)
cd ../../core && bin/aer-botbench -mode store
bin/aer-botbench -mode http -core http://127.0.0.1:18797 -token-file $D/data/core.token -core-pid "$(pgrep -n -x aer-core)" -bots 50 -duration 60s
```
Go-тесты управляют только своими процессами `/bin/sh` во временном каталоге; Docker, systemd и n8n в тестах — подделки API. Реальные боты, контейнеры и службы не затрагиваются. Живая проверка n8n в отчёте M06 шла против заглушки API (`/healthz`, workflows, executions, retry).

## Изолированный запуск (не трогая реальные данные)
```bash
D=$(mktemp -d)
AER_DATA_DIR=$D AER_LISTEN=127.0.0.1:18787 core/bin/aer-core &
AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token apps/desktop/build/linux/x64/release/bundle/aer_home_desktop
```

## Удалённый доступ (M07): стенд и живая проверка
```bash
LAB=$(mktemp -d); tools/remote-lab/lab-host.sh $LAB 33891     # изолированный headless GNOME + grdctl (RDP выключен)
# Core на 127.0.0.1:18797, компьютер в Registry, учётка агента kind=remote → $D/agent.token, политика с files=true
# агент внутри стенда (его D-Bus и XDG-каталоги):
bash -c ". $LAB/env.sh; export DBUS_SESSION_BUS_ADDRESS=\$(cat $LAB/bus); exec core/bin/aer-remote-host -config agent.json" &
#   agent.json: grdctl ["grdctl","--headless"], daemon ["/usr/libexec/gnome-remote-desktop-daemon","--headless"], address 127.0.0.1, port 33891
cd apps/desktop
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18797 AER_CORE_TOKEN_FILE=$D/data/core.token \
  AER_DESKTOP_DATA_DIR=$D/desktop AER_SCREENSHOT_DIR=$D/shots AER_REMOTE_CLIENT_SHOTS=$D/shots \
  AER_REMOTE_CLIENT="$PWD/../../tools/remote-lab/lab-client.sh $LAB :77" AER_REMOTE_FREERDP_DIR=$LAB/client/config/freerdp \
  AER_REMOTE_LAB_TOOLS=$PWD/../../tools/remote-lab flutter test integration_test/remote_live_test.dart -d linux
```
Клиент Remmina запускается приложением в изолированном Xvfb `:77`; сеанс и буфер обмена пользователя не затрагиваются.

## Питание (M08): стенд и живая проверка
```bash
L=$(mktemp -d); python3 -I tools/power-lab/lab.py up $L 18797 &   # Core (WoL разрешён), aer-power-host в режиме проверки, приёмник WoL 127.0.0.1
python3 -I tools/power-lab/lab.py bench $L                          # задержки API, параллельные задания, CPU/RSS
cd apps/desktop
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18797 AER_CORE_TOKEN_FILE=$L/data/core.token \
  AER_DESKTOP_DATA_DIR=$L/desktop AER_SCREENSHOT_DIR=$L/shots AER_POWER_LAB=$L AER_POWER_LAB_TOOLS=$PWD/../../tools/power-lab \
  flutter test integration_test/power_live_test.dart -d linux
```
Стенд отказывается запускать агента с `"execute": true`; Magic Packet уходит только на 127.0.0.1. Остановка — `kill` PID из `$L/lab.json` (не `pkill`).

## Сеть и ТВ (M09): стенд, живая проверка, реальные устройства
```bash
L=$(mktemp -d); python3 -I tools/network-lab/lab.py up $L 18798 &      # заглушки Sunshine/UPnP/TCP + изолированный Core
python3 -I tools/network-lab/lab.py set $L sunshine=busy               # free|busy|down|401, wan=up|down
python3 -I tools/network-lab/lab.py bench $L
cd apps/desktop
AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18798 AER_CORE_TOKEN_FILE=$L/data/core.token \
  AER_DESKTOP_DATA_DIR=$L/desktop AER_SCREENSHOT_DIR=$L/shots AER_NET_LAB=$L AER_NET_LAB_TOOLS=$PWD/../../tools/network-lab \
  flutter test integration_test/network_live_test.dart -d linux
# реальные устройства, только чтение, отдельный Core на :18799, адреса в выводе маскируются:
python3 -I tools/network-lab/real_check.py $(mktemp -d) --router <IP роутера> --tv <IP ТВ> --internet 1.1.1.1:443 --internet 9.9.9.9:443
```
Остановка стенда — `kill` PID Core из `$L/lab.json`.

## Android (M12): сборка, тесты, эмулятор
Подробно — `ANDROID.md` («Сборка и проверки»). Кратко:
```bash
cd apps/android && echo "sdk.dir=$ANDROID_HOME" > local.properties
./gradlew :core-api:test :scene:test :app:testDebugUnitTest :app:lintDebug :app:assembleRelease
# сквозные тесты против изолированного стенда (tools/network-lab + tools/mobile-lab), эмулятор видит хост как 10.0.2.2
./gradlew connectedAndroidTest -Pandroid.testInstrumentationRunnerArguments.aerToken="$(cat $LAB/data/core.token)"
```
