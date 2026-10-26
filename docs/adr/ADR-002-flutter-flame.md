# ADR-002: Flutter desktop + Flame

**Статус:** Flutter — ACCEPTED (M01); Flame — PROPOSED до бенчмарка во входе M03.

## Решение
- Desktop-клиент: Flutter 3.47.7 / Dart 3.13.5, платформы linux + windows, пакет `apps/desktop`.
- Состояние без DI-фреймворков: `ChangeNotifier`/`ValueNotifier`; HTTP — `package:http` (BSD-3).
- Режимы «Дом»/«Классика» живут одновременно (`IndexedStack`) → переключение без потери состояния.
- Сцена (M03): Flame 1.38.2 (MIT) совместим (Flutter ≥ 3.41). Сцена — отдельный пакет/модуль, получает только данные Registry/Scene через интерфейс, без логики устройств.

## Условие перехода Flame в ACCEPTED
Прототип: 1 комната, 5 hit zones, pan/zoom; замер FPS и памяти на этом ПК (дискретная GPU, Wayland) и на 1366×768.

## Последствия
- Windows-сборка возможна только на Windows-хосте (M10).
- Tray/уведомления потребуют плагинов (оценить в M10).
