# Готовые open-source решения: adopt / evaluate / reject

**Статус проверки:** публичные репозитории/документация просмотрены 26.10.2026. Версии SDK и лицензии перепроверять непосредственно перед добавлением зависимостей. Наличие фичи в README не доказывает совместимость с текущими Ubuntu Wayland / iPhone.

| Инструмент | Ссылка | Роль | Решение |
|---|---|---|---|
| Flame | https://github.com/flame-engine/flame | графика Flutter, components, gestures, sprites | ADOPT, MIT |
| Tiled | https://github.com/mapeditor/tiled | создание изометрических карт/слоёв/метаданных | TOOL ONLY, не встраивать редактор без проверки GPL |
| flame_tiled | https://pub.dev/packages/flame_tiled | загрузка карт Tiled через Flame | EVALUATE version fit |
| Beszel | https://github.com/henrygd/beszel | метрики Linux/Docker/история/alert | EVALUATE adapter + RAM, MIT |
| MeshCentral | https://github.com/Ylianst/MeshCentral | desktop/files/terminal agents | SPIKE FIRST; Ubuntu Wayland issue |
| RustDesk | https://github.com/rustdesk/rustdesk | desktop remoting alternative | SPIKE FIRST, license/embedding review |
| Apache Guacamole | https://github.com/apache/guacamole-client | browser RDP/VNC/SSH gateway | OPTIONAL; may add dependencies |
| Uptime Kuma | https://github.com/louislam/uptime-kuma | availability checks/heartbeat | OPTIONAL, do not depend on undocumented API |
| Healthchecks | https://github.com/healthchecks/healthchecks | scheduled job heartbeat | REFERENCE; too heavy for few bots |
| Sunshine/Moonlight | https://github.com/LizardByte/Sunshine ; https://github.com/moonlight-stream/moonlight-android | уже выбранный TV-streaming | INTEGRATE STATUS only first; not clipboard/files solution |
| Tailscale | https://tailscale.com/ | private remote access | EVALUATE setup; no public inbound |

## Важные оговорки
1. MeshCentral: https://github.com/Ylianst/MeshCentral/issues/7875 — issue от июня 2026 о неполной поддержке Wayland; на 2026-10-26 issue **закрыт**, но фактическая поддержка Ubuntu 24.04 Wayland не проверена — прототип обязателен.
2. Flame даёт primitives, **не** готовый Sims-редактор.
3. Tiled редактор распространяется по GPL; редактор использовать как отдельную dev tool, данные/ассеты и лицензирование отдельно проверить. Не копировать чужие игровые ассеты без права.
4. Beszel внешний hub+agent; выбран только если реально легче поддержки собственного сборщика и API удовлетворяет требованиям.
5. RustDesk лицензия AGPL (проверить конкретные компоненты, условия интеграции). Не копировать код напрямую по умолчанию.
6. Remote window-only на телефоне — **не подтверждено** ни одним кандидатом, возможна отдельная интеграция/ограничение.
7. Любая интеграция должна иметь timeout, circuit breaker, health и `UNSUPPORTED` capability.

## Порядок экспериментов
- Flame desktop scene: 1-room camera 5 hit zones FPS/memory.
- Beszel: agent на одном тестовом узле, прочитать метрики через документированный API и измерить overhead.
- MeshCentral/RustDesk: матрица Wayland/Windows/clipboard/file/window isolation, протестировать без публичных портов.
- WoL и dual-boot: инвентаризация BIOS/EFI прежде команды.
