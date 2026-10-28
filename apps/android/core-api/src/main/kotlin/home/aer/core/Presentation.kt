package home.aer.core

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Locale

// Text and tone for Core values, shared by both interface modes. Status is
// never conveyed by colour alone: every tone comes with a label.

enum class Tone { Ok, Warning, Critical, Muted, Info }

data class StatusText(val label: String, val tone: Tone)

fun parseInstant(s: String?): Instant? =
    if (s.isNullOrBlank()) null else try {
        Instant.parse(s)
    } catch (_: DateTimeParseException) {
        null
    }

/** "только что", "5 с назад", "3 мин назад", "2 ч назад", "4 дн назад". */
fun ago(at: Instant?, now: Instant): String {
    if (at == null) return "никогда"
    val s = Duration.between(at, now).seconds
    return when {
        s < 3 -> "только что"
        s < 60 -> "$s с назад"
        s < 3600 -> "${s / 60} мин назад"
        s < 86_400 -> "${s / 3600} ч назад"
        else -> "${s / 86_400} дн назад"
    }
}

fun agoText(at: String?, now: Instant): String = ago(parseInstant(at), now)

private val timeFormat = DateTimeFormatter.ofPattern("dd.MM HH:mm:ss", Locale.forLanguageTag("ru"))

fun localTime(at: String?, zone: ZoneId = ZoneId.systemDefault()): String =
    parseInstant(at)?.atZone(zone)?.format(timeFormat) ?: "—"

/** Latency with a Russian decimal comma; null means "not measured", never zero. */
fun latencyText(ms: Double?): String = when {
    ms == null -> "не измерялась"
    ms < 10 -> String.format(Locale.forLanguageTag("ru"), "%.1f мс", ms)
    else -> "${Math.round(ms)} мс"
}

/** Monitoring status (MonitoringStatus enum). */
fun monitoringStatus(status: String, worstSeverity: String? = null): StatusText = when (status) {
    "online" -> StatusText("В сети", Tone.Ok)
    "degraded" -> if (worstSeverity == "critical") StatusText("Критично", Tone.Critical) else StatusText("Есть проблемы", Tone.Warning)
    "offline" -> StatusText("Не в сети", Tone.Critical)
    "unsupported" -> StatusText("Не проверяется", Tone.Muted)
    else -> StatusText("Нет данных", Tone.Muted)
}

/** Network check / device status (ADR-015: five states). */
fun networkStatus(status: String): StatusText = when (status) {
    "up" -> StatusText("Доступен", Tone.Ok)
    "down" -> StatusText("Недоступен", Tone.Critical)
    "error" -> StatusText("Ошибка проверки", Tone.Warning)
    "unconfigured" -> StatusText("Не настроен", Tone.Muted)
    else -> StatusText("Нет данных", Tone.Muted)
}

fun networkSummaryTone(level: String): Tone = when (level) {
    "ok" -> Tone.Ok
    "warning" -> Tone.Warning
    "critical" -> Tone.Critical
    else -> Tone.Muted
}

fun severity(s: String): StatusText = when (s) {
    "critical" -> StatusText("Критично", Tone.Critical)
    "warning" -> StatusText("Предупреждение", Tone.Warning)
    else -> StatusText("Информация", Tone.Info)
}

fun incidentStatus(s: String): StatusText = when (s) {
    "open" -> StatusText("Открыт", Tone.Critical)
    "acknowledged" -> StatusText("Подтверждён", Tone.Warning)
    "resolved" -> StatusText("Закрыт", Tone.Ok)
    else -> StatusText(s, Tone.Muted)
}

fun logLevel(level: String): StatusText = when (level) {
    "error", "critical", "fatal" -> StatusText("Ошибка", Tone.Critical)
    "warn", "warning" -> StatusText("Предупреждение", Tone.Warning)
    "debug" -> StatusText("Отладка", Tone.Muted)
    else -> StatusText("Инфо", Tone.Info)
}

fun powerState(state: String): StatusText = when (state) {
    "online" -> StatusText("Включён", Tone.Ok)
    "offline" -> StatusText("Не отвечает", Tone.Muted)
    "waking" -> StatusText("Включается", Tone.Info)
    "shutting_down" -> StatusText("Выключается", Tone.Warning)
    "rebooting" -> StatusText("Перезагружается", Tone.Warning)
    "switching" -> StatusText("Переключает ОС", Tone.Warning)
    "suspending" -> StatusText("Засыпает", Tone.Warning)
    else -> StatusText("Неизвестно", Tone.Muted)
}

fun powerJobState(state: String): StatusText = when (state) {
    "queued" -> StatusText("В очереди — ждёт агента", Tone.Info)
    "sent" -> StatusText("Передано агенту", Tone.Info)
    "waiting" -> StatusText("Выполняется — ждём результат", Tone.Info)
    "succeeded" -> StatusText("Выполнено", Tone.Ok)
    "failed" -> StatusText("Ошибка", Tone.Critical)
    "timeout" -> StatusText("Нет подтверждения — состояние неизвестно", Tone.Warning)
    "cancelled" -> StatusText("Отменено", Tone.Muted)
    "simulated" -> StatusText("SIMULATED — ничего не выполнено", Tone.Warning)
    "rejected" -> StatusText("Отклонено", Tone.Critical)
    else -> StatusText(state, Tone.Muted)
}

fun powerJobFinished(state: String) = state in setOf("succeeded", "failed", "timeout", "cancelled", "simulated", "rejected")

fun botActionStatus(status: String): StatusText = when (status) {
    "running" -> StatusText("Выполняется", Tone.Info)
    "succeeded" -> StatusText("Выполнено", Tone.Ok)
    "failed" -> StatusText("Ошибка", Tone.Critical)
    "rejected" -> StatusText("Отклонено", Tone.Critical)
    else -> StatusText(status, Tone.Muted)
}

/** User-facing text for any failure talking to Core. */
fun describeError(e: Throwable): String = when (e) {
    is CoreException.Unreachable -> "Нет связи с Core: ${e.reason}"
    is CoreException.TokenMissing -> "Не задан токен доступа к Core"
    is CoreException.Api -> when {
        e.isUnauthorized -> "Core отклонил токен доступа"
        e.code == "PERMISSION_REQUIRED" -> e.apiMessage.ifEmpty { "Действие сейчас не разрешено" }
        e.code == "NOT_FOUND" -> "Не найдено в Core"
        e.code == "UNSUPPORTED" -> "Не поддерживается этим Core"
        e.code == "INTERNAL" -> "Внутренняя ошибка Core" + (e.requestId?.let { " (запрос $it)" } ?: "")
        else -> e.apiMessage.ifEmpty { e.code }
    }
    is CoreException.InvalidResponse -> "По этому адресу отвечает не AER Core (${e.message})"
    else -> e.message ?: e.javaClass.simpleName
}
