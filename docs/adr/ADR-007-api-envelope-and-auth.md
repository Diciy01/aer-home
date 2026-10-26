# ADR-007: REST-конверт, модель ошибок и локальная аутентификация

**Статус:** ACCEPTED (2026-10-26, M01). Контракт `contracts/openapi.yaml` 0.1.0 → **0.2.0**.

## Решение
1. Все ответы `/api/v1`:
   - успех: `{"data": …, "meta": {"requestId", "apiVersion"}}`
   - ошибка: `{"error": {"code", "message", "details?"}, "meta": {…}}`
   Заголовок `X-Request-ID` совпадает с `meta.requestId`. Клиенты ветвятся по `code`, не по тексту.
2. Коды: BAD_REQUEST, VALIDATION_FAILED, UNAUTHORIZED, FORBIDDEN, NOT_FOUND, METHOD_NOT_ALLOWED, CONFLICT, PAYLOAD_TOO_LARGE, UNSUPPORTED, PERMISSION_REQUIRED, UNAVAILABLE, INTERNAL. Внутренние ошибки наружу не раскрываются (только INTERNAL + requestId), оригинал — в логе.
3. `GET /health` — **публичный** (отступление от черновика 0.1): клиенту нужно отличать «Core выключен» от «токен отклонён». Отдаёт только `status/timestamp/apiVersion`.
4. MVP-аутентификация: один случайный 256-битный bearer-токен в файле `core.token` (0600) в каталоге данных Core; сравнение constant-time; токен не логируется. Локальный клиент читает файл (`AER_CORE_TOKEN_FILE`).
5. Development-режим отказывается слушать не-loopback адрес.
6. Контрактный тест (`core/internal/core/contract_test.go`) сверяет маршруты роутера с операциями `x-aer-status: implemented` и их требованием авторизации.

## Отложено (обязательно до Remote/mobile)
Device-scoped credentials с capabilities и отзывом, TLS/приватная overlay-сеть, rate limiting.

## Миграция
Клиентов 0.1 не существовало — миграция не требуется.
