# Агент AER HOME (`aer-agent`)

Лёгкий фоновый агент: каждые 15 с собирает системные показатели, состояние выбранных служб и системные журналы уровня warning и выше и отправляет их в Core. Работает независимо от приложения AER HOME. **В систему автоматически не устанавливается** — только вручную по инструкции ниже.

## Что собирается

| Показатель | Ubuntu | Windows |
|---|---|---|
| CPU | `/proc/stat` | `GetSystemTimes` |
| RAM, swap | `/proc/meminfo` | `GlobalMemoryStatusEx` (файл подкачки) |
| Диски (заполнение, свободно) | `/proc/self/mounts` + `statfs` (ext4, xfs, btrfs, ntfs, vfat…; без snap/tmpfs) | `GetLogicalDriveStrings`, `GetDiskFreeSpaceEx` (только фиксированные диски) |
| Сеть (приём, передача, ошибки) | `/proc/net/dev` (без lo/veth/docker/br-) | `GetIfTable2Ex` (физические подключённые интерфейсы) |
| Температура CPU | hwmon: k10temp/zenpower (Tctl/Tdie), coretemp (Package id 0) | **не поддерживается**: нужен драйвер производителя или права администратора (WMI) — так и сообщается |
| GPU (загрузка, температура) | amdgpu sysfs; иначе `nvidia-smi` | `nvidia-smi`; иначе не поддерживается |
| Число процессов, память агента | `/proc` | Toolhelp32 |
| Службы | `systemctl is-active` | `sc query` |
| Системный журнал | `journalctl -p warning -o json` с курсором | `wevtutil` (System, Application; уровни 1–3) |
| Время работы, версия ОС | `/proc/uptime`, `/etc/os-release` | `GetTickCount64`, `RtlGetVersion` |

Не собирается: содержимое файлов, документы, история браузера, пароли, список пользователей, сетевой трафик по содержимому. Если значение получить нельзя, агент отправляет `unsupported` или `unavailable` с причиной — без выдуманных чисел.

## Безопасность
- Отдельные учётные данные на каждого агента: «Мониторинг → Агенты и интеграции → Добавить» (или `POST /api/v1/monitoring/agents`). Токен показывается **один раз**; Core хранит только хэш.
- Токен — в файле с правами `600` (на Windows — доступ только SYSTEM и администраторам); в конфиге только путь к файлу. Агент предупреждает, если файл читают другие пользователи.
- Токен передаётся в заголовке `Authorization`, никогда в URL и в логах. Учётные данные привязаны к одному устройству Registry: агент не может прислать данные за другое устройство. Отзыв — «Отозвать» (агент сразу получает 401 и прекращает отправку).
- Для Core на другом компьютере используйте HTTPS или доверенную сеть: при `http://` на не-loopback адрес агент пишет предупреждение. AER не открывает портов и не меняет брандмауэр.

## Конфигурация
Пример — `deploy/agent/agent.example.json`. Поля: `coreUrl`, `tokenFile`, `intervalSec` (5…3600, по умолчанию 15), `logIntervalSec` (30), `queueSamples` (5000), `queueLogs` (1000), `collectors` (каждый сборщик выключается; `services` — список служб). При недоступности Core данные копятся в ограниченной очереди (старые вытесняются, число потерянных сообщается Core), повтор с удвоением паузы до 5 минут.

Проверка без отправки: `aer-agent -once -config agent.json` печатает отчёт в JSON.

## Ubuntu (вручную)
```bash
cd core && go build -o bin/aer-agent ./cmd/aer-agent
sudo install -m 0755 bin/aer-agent /usr/local/bin/aer-agent
sudo install -d -m 0750 /etc/aer-agent
sudo install -m 0600 agent.token /etc/aer-agent/agent.token        # токен из «Агенты»
sudo install -m 0644 deploy/agent/agent.example.json /etc/aer-agent/agent.json
# в agent.json: "tokenFile": "/run/credentials/aer-agent.service/agent.token"
sudo install -m 0644 deploy/agent/aer-agent.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now aer-agent
```
Юнит запускается с `DynamicUser`, `ProtectSystem=strict`, `MemoryMax=64M`, `CPUQuota=10%`; для чтения системного журнала — группа `systemd-journal`.

## Windows (вручную)
```powershell
# сборка на любой ОС:
GOOS=windows GOARCH=amd64 go build -o aer-agent.exe ./cmd/aer-agent
```
Затем — шаги из `deploy/agent/install-windows.ps1.txt` в PowerShell от администратора (копирование в `C:\ProgramData\AER\agent`, права на токен, `sc.exe create aer-agent …`). Агент сам определяет запуск как служба Windows.

## Боты (heartbeat)
Учётные данные с видом «Heartbeat бота» + `tools/bot-heartbeat/aer_heartbeat.py` (только стандартная библиотека Python):
```python
from aer_heartbeat import Heartbeat
hb = Heartbeat("http://127.0.0.1:8787", token_file="/etc/aer/pico.token", name="pico").start()
hb.success()              # после настоящего успешного действия
hb.error("timeout")       # после сбоя (секреты вырезаются Core)
hb.api_ok(check_api())    # собственная проверка зависимости
```

## Протокол v1
`POST /api/v1/monitoring/agent/report`, `Authorization: Bearer aer1.<agentId>.<secret>`; тело — `{agent, bot?, samples[], logs[], dropped}` (схема `AgentReport` в `contracts/openapi.yaml`). Ответ — `{acceptedSamples, acceptedLogs, droppedLogs, serverTime, intervalSec}`. Время значений — в окне −24 ч…+5 мин от часов Core.

## Статус проверки
Ubuntu-агент проверен вживую против Core на этой машине (реальные CPU, RAM, диски, сеть, температуры CPU/GPU, journald, службы). Windows-агент собирается (`GOOS=windows go vet/build`), разборщики `sc query`, `wevtutil`, `nvidia-smi` покрыты тестами; **на реальной Windows не запускался (UNVERIFIED)**.
