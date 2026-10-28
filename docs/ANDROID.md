# Android-клиент (M12)

Нативное приложение AER HOME на Kotlin и Jetpack Compose: `apps/android`. Решения — ADR-016. Клиент работает только через существующий API Core (контракт 0.10.0) и не хранит своих данных об устройствах.

## Модули
| Модуль | Что внутри | Зависит от Android |
|---|---|---|
| `:core-api` | `CoreClient` (конверт ADR-007, ошибки по `code`), `CoreApi` (Registry, Monitoring, Network, Power, Bots, Scenes), `HomeRepository` (снимок, частичные ошибки, устаревание), `ActionFlow` (подтвердить → выполнить, ключ идемпотентности), `Endpoint` (проверка адреса), `Presentation` (тексты и тона состояний) | нет |
| `:scene` | Формат сцены v1, проекция 2:1, стены, порядок отрисовки, выбор касанием, камера, привязки к Registry/Monitoring, каталог материалов | нет |
| `:app` | Compose: `ui/AppRoot` (режимы, навигация), `ui/screens/*` (Обзор, Устройства, Устройство, Журнал, Инцидент, Сеть и ТВ, Питание, Боты, Ещё, Подключение), `ui/house/*` (изометрический дом), `ui/actions` (диалог подтверждения), `data/*` (настройки, Keystore, источник сцены) | да |

## Режимы
- **«Дом»** — изометрический дом из сцены Core: комнаты, предметы, значки состояний привязанных устройств (из Monitoring), выбор касанием или списком предметов комнаты, «Подробнее» → карточка устройства, масштаб двумя пальцами, сдвиг, «Весь дом». Внизу — переход к Обзору, Журналу, Сети и «Ещё».
- **«Классика»** — нижняя навигация: Обзор, Устройства, Журнал, Сеть, Ещё (Питание, Боты, Дом, Подключение).
- Выбор при первом запуске; переключение — кнопкой в верхней панели или в «Ещё»/«Подключении». Данные, адрес и токен при переключении не теряются (один `HomeRepository`).

## Данные и обновление
- Опрос Core каждые 10 с, только пока приложение на экране. Данные старше 30 с (или после неудачного опроса) помечаются «устарело», баннер объясняет причину: Core не настроен, нет связи (с временем последних данных), токен отклонён, по адресу отвечает не AER Core.
- Каждый раздел грузится отдельно: ошибка одного не скрывает остальные; выключенный в Core модуль показан как выключенный.
- Ничего не выдумывается: нет данных Monitoring → «Нет данных»/«Неизвестно», задержка без замера → «не измерялась», SIMULATED-задание питания → «SIMULATED — ничего не выполнено».

## Подключение
1. Core в режиме `local` или `server`, `listenAddr` — адрес домашней сети или Tailscale (development слушает только loopback; эмулятор видит компьютер как `10.0.2.2`).
2. В приложении: «Подключение к Core» → адрес и токен (содержимое `core.token`) → «Сохранить» → «Проверить» (сначала публичный `/health`, затем `/system/info` — так различаются «Core выключен» и «токен отклонён»).

## Безопасность
- Токен — AES-256-GCM, ключ в AndroidKeyStore (неэкспортируемый); в настройках только шифротекст; `allowBackup=false`, правила извлечения данных исключают всё. Токен не логируется; одноразовые токены подтверждения не попадают в `toString`.
- http разрешён (`network_security_config`, cleartext — сознательно: у Core нет TLS), но на публичный адрес по http приложение токен **не отправит**; для адресов LAN — предупреждение. Только системные CA.
- Действия питания и ботов — только протокол Core: условия, риски, одноразовый токен, `Idempotency-Key`; повтор после потери ответа — с тем же ключом.
- Ограничение: телефон держит токен владельца (полные права). Device-scoped учётки — ADR-007 «Отложено».

## Сборка и проверки
```bash
cd apps/android
echo "sdk.dir=$ANDROID_HOME" > local.properties               # не коммитится
./gradlew :core-api:test :scene:test :app:testDebugUnitTest  # JVM: клиент, сцена, состояние интерфейса
./gradlew :app:lintDebug                                      # Android Lint, предупреждения = ошибки
./gradlew :app:assembleDebug :app:assembleRelease             # APK (release — R8, подписан debug-ключом: только для проверки)

# сквозные тесты на эмуляторе/устройстве против ИЗОЛИРОВАННОГО тестового Core
python3 -I tools/network-lab/lab.py up /tmp/aer-lab 18798 &   # заглушки + Core
python3 -I tools/mobile-lab/seed_scene.py /tmp/aer-lab       # сцена, привязанная к объектам стенда
./gradlew connectedAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.aerCoreUrl=http://10.0.2.2:18798 \
  -Pandroid.testInstrumentationRunnerArguments.aerToken="$(cat /tmp/aer-lab/data/core.token)"
# + сбой и восстановление Core: -P...aerOutage=1 и параллельно
python3 -I tools/mobile-lab/outage.py /tmp/aer-lab emulator-5580 "$(command -v adb)"
# те же тесты на минифицированной сборке: -PaerTestBuildType=release
# скриншоты шагов: adb pull /data/local/tmp/aer-shots
```
Без `aerToken` живые тесты помечаются пропущенными, а не пройденными.

## Эмулятор
Пакеты SDK: `emulator` (проверено 37.2.12) и `system-images;android-35;google_apis;x86_64`; AVD на профиле Pixel 6, 3 ГБ ОЗУ; на Linux нужен доступ к `/dev/kvm`. Где лежат SDK и AVD на машине разработки — в `docs/private/LOCAL_NOTES.md`.
```bash
sdkmanager "emulator" "system-images;android-35;google_apis;x86_64"
avdmanager create avd -n aer_pixel_api35 -k "system-images;android-35;google_apis;x86_64" -d pixel_6
$ANDROID_HOME/emulator/emulator -avd aer_pixel_api35 -no-window -no-audio -gpu swiftshader_indirect -port 5580
```

## Не реализовано / UNVERIFIED
- Редактирование сцены на телефоне (только просмотр и навигация); рисунки предметов упрощены относительно desktop.
- Remote Desktop/Remote Apps с телефона — UNSUPPORTED (см. `REMOTE_APPS_MOBILE.md`).
- Изменение политики питания, WoL-цели, добавление ботов и объектов Registry — в настольном клиенте.
- Физическое устройство, реальный Core в LAN/Tailscale — UNVERIFIED.
