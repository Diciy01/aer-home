# AER Remote (M07)

Удалённый рабочий стол между компьютерами дома (и извне — через VPN). Исследование — `S_REMOTE_FEASIBILITY.md`; решения — ADR-013; безопасность — `REMOTE_SECURITY.md`; подключение — `REMOTE_CONNECT.md`; руководство — `USER_GUIDE_REMOTE.md`; Windows — `REMOTE_WINDOWS_VALIDATION.md`; мобильные Remote Apps — `REMOTE_APPS_MOBILE.md`; замеры — `M07_REMOTE_REPORT.md`. Исходные требования (политика клиентов, ошибки, запреты) — раздел «Требования» ниже.

## Архитектура
```text
 AER HOME (клиент) ──owner token──► Core: модуль remote (плоскость управления)
   │  «Подключиться»                 хосты · политика · сеансы · одноразовая выдача · аудит
   │                                      ▲ hello / long-poll / события (учётка агента kind=remote)
   │                                      │
   │  RDP/TLS (закреплённый сертификат) ┌─┴──────────────── компьютер-хост ─────────────────┐
   └──────────────────────────────────► │ aer-remote-host → grdctl + gnome-remote-desktop    │
   └── HTTPS файлы (тот же сертификат) ► │   (демон на время сеанса, пароль на сеанс)         │
       окно Remmina / mstsc             │ HTTPS-канал файлов (папка обмена)                  │
                                        └────────────────────────────────────────────────────┘
```
Видео, ввод, буфер обмена и файлы идут **напрямую** клиент ↔ хост; Core их не видит и не хранит.

| Компонент | Где | Что делает |
|---|---|---|
| Remote Session Service | `core/internal/modules/remote/sessions.go` | создание, состояния, сроки, одноразовая выдача, отзыв |
| Remote Host Registry | `remote/service.go` (`remote_hosts`) | сведения агента поверх объекта Registry, реальная готовность |
| Remote Permissions | `remote/service.go` (`remote_policies`) | политика владельца ∩ возможности хоста; лимиты |
| Remote Audit | `remote_events` + события Monitoring | история подключений без содержимого |
| Transport Adapter | `core/internal/remotehost/backend.go` | `gnome-rdp` (VERIFIED на стенде), `windows-rdp` (UNVERIFIED) |
| Remote Host Agent | `core/cmd/aer-remote-host` | открывает RDP только на одобренный сеанс, канал файлов |
| Remote Client UI | `apps/desktop/lib/src/features/remote`, `state/remote_controller.dart`, `remote/` | раздел «Удалённый доступ», запуск внешнего клиента, файлы |

## Состояния сеанса
`pending` (запрошен) → `awaiting_approval` (ждём подтверждения на компьютере, если `approval=prompt`) → `connecting` (RDP включён, данные можно забрать один раз) → `connected` (агент видит установленное соединение) ⇄ `reconnecting` (соединение прервано, окно 120 с) → `disconnected` | `failed` | `expired` | `revoked`.

Сроки (конфиг `remote` Core): ответ хоста 30 с, подтверждение 120 с, выдача данных 60 с после готовности, переподключение 120 с, сеанс — по умолчанию 60 мин, максимум 8 ч (и не больше политики хоста); агент закрывает сеанс по сроку сам, даже без Core.

## Готовность хоста (перед «Подключиться»)
Возможность Registry `remote.desktop` — только заявка. Подключение предлагается, когда: объект не в архиве; есть агент и он на связи (hello ≤ 90 с, учётка не отозвана); агент сообщает `ready`; Monitoring не считает компьютер `offline`; политика включена и разрешает рабочий стол; нет активного сеанса. Иначе — причина текстом. Выключенный компьютер не предлагается (Wake-on-LAN — M08).

## API (`/api/v1`, контракт 0.8.0)
Токен владельца:
| Метод | Путь | Назначение |
|---|---|---|
| GET | `/remote/hosts`, `/remote/hosts/{id}` | хосты, готовность, политика, активный/последний сеанс |
| PUT | `/remote/hosts/{id}/policy` | `{enabled, desktop, clipboard, files, maxMinutes, revision}`; выключение отзывает сеансы |
| POST | `/remote/hosts/{id}/revoke-sessions` | отозвать все сеансы хоста |
| GET | `/remote/hosts/{id}/apps` | Remote Apps: `unsupported` + причина (честно) |
| GET/POST | `/remote/sessions` | история / запрос сеанса (`Idempotency-Key`; 503 «не готов», 409 «занят»/«лимит», 422 `apps`) |
| GET | `/remote/sessions/{id}` | сеанс + аудит |
| POST | `/remote/sessions/{id}/grant` | **одноразово**: адрес, порт, пользователь, пароль сеанса, сертификат, токен файлов; повтор — 410 |
| POST | `/remote/sessions/{id}/end`, `/revoke` | завершить / отозвать |

Учётка агента (`kind=remote`): `POST /remote/agent/hello`, `GET /remote/agent/commands?wait=25`, `POST /remote/agent/sessions/{id}/events` (`awaiting_approval|approved|denied|ready|connected|disconnected|closed|failed`).

Канал файлов агента (не Core): `GET /v1/files`, `PUT /v1/files/{name}` (заголовок `X-AER-SHA256`), `GET /v1/files/{name}` (ответ с `X-AER-SHA256`), `Authorization: Bearer <токен сеанса>`; только имена без путей, без перезаписи, лимит размера.

## Что поддерживается
| Функция | Статус |
|---|---|
| Рабочий стол Ubuntu GNOME Wayland (изображение, мышь, клавиатура-латиница) через AER | **VERIFIED** (изолированный стенд, клиент Linux) |
| Буфер обмена (текст, в обе стороны) | **VERIFIED** (стенд, канал RDP); выключение — на стороне клиента |
| Передача файлов (загрузка, скачивание, SHA-256, отмена, лимит) | **VERIFIED** (стенд, канал агента) |
| Масштаб, полноэкранный режим, изменение размера | в окне Remmina (внешний клиент) — не функция AER |
| Несколько мониторов | UNVERIFIED (headless-стенд с одним виртуальным монитором) |
| Хост Windows, клиент Windows (mstsc) | UNVERIFIED |
| Кириллица с реальной клавиатуры | UNVERIFIED |
| Remote Apps (одно приложение), мобильные клиенты | UNSUPPORTED на текущем транспорте; спецификация — `REMOTE_APPS_MOBILE.md` |
| Встроенное окно рабочего стола внутри AER | не реализовано (внешний клиент, ADR-013) |

## Требования (исходные, сохранены)
- Desktop-клиенты: полный рабочий стол, мышь/клавиатура (включая русскую раскладку), двусторонний текстовый буфер, файлы туда-обратно; drag-and-drop — только при безопасной поддержке.
- Mobile: только список авторизованных приложений/окон; **никогда** не переключать на полный рабочий стол автоматически; если ОС не изолирует окно — `UNSUPPORTED` и рекомендация desktop-клиента.
- Ошибки: DISPLAY_PERMISSION_REQUIRED, WAYLAND_UNSUPPORTED, NO_ACTIVE_SESSION, WINDOW_NOT_CAPTURABLE, AUTH_FAILED, HOST_ASLEEP, INPUT_DENIED, PROVIDER_UNAVAILABLE, CONNECTION_TIMEOUT.
- Запреты: не обходить экран блокировки, не запускать привилегированный скрытый рабочий стол, не публиковать порт в WAN, не записывать сеансы без согласия.
