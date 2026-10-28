package home.aer.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import home.aer.android.ui.Screen
import home.aer.android.ui.UiContext
import home.aer.android.ui.components.EmptyNote
import home.aer.android.ui.components.ErrorNote
import home.aer.android.ui.components.ItemRow
import home.aer.android.ui.components.KeyValue
import home.aer.android.ui.components.SectionCard
import home.aer.android.ui.components.StatusBadge
import home.aer.android.ui.theme.AerColors
import home.aer.core.Incident
import home.aer.core.LogEntry
import home.aer.core.Section
import home.aer.core.agoText
import home.aer.core.describeError
import home.aer.core.incidentStatus
import home.aer.core.localTime
import home.aer.core.logLevel
import home.aer.core.severity
import kotlinx.coroutines.launch

private enum class JournalTab(val label: String) { Incidents("Инциденты"), Logs("Журнал") }

private enum class LevelFilter(val label: String, val level: String?) { All("Все", null), Warn("Предупреждения+", "warning"), Error("Ошибки", "error") }

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
fun JournalScreen(ctx: UiContext) {
    var tab by rememberSaveable { mutableStateOf(JournalTab.Incidents) }
    var showResolved by rememberSaveable { mutableStateOf(false) }
    var level by rememberSaveable { mutableStateOf(LevelFilter.All) }
    val resolved by rememberLoad(ctx, showResolved) { if (showResolved) incidents("resolved", limit = 50).items else emptyList() }

    // Log pages: newest first, «Загрузить ещё» follows Core's cursor.
    val logs = remember(level) { mutableStateListOf<LogEntry>() }
    var cursor by remember(level) { mutableStateOf<Long?>(null) }
    var logError by remember(level) { mutableStateOf<String?>(null) }
    var logsLoading by remember(level) { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    fun loadLogs(before: Long?) = scope.launch {
        logsLoading = true
        ctx.vm.load { logs(level = level.level, before = before, limit = 40) }
            .onSuccess {
                logs += it.items
                cursor = it.nextBefore
                logError = null
            }
            .onFailure { logError = describeError(it) }
        logsLoading = false
    }
    LaunchedEffect(level, tab) { if (tab == JournalTab.Logs && logs.isEmpty()) loadLogs(null) }

    ScreenList("screen_journal") {
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                JournalTab.entries.forEach { t ->
                    FilterChip(selected = tab == t, onClick = { tab = t }, label = { Text(t.label) }, modifier = Modifier.testTag("journal_tab_${t.name}"))
                }
            }
        }
        when (tab) {
            JournalTab.Incidents -> {
                val active = ctx.snapshot.incidents
                if (active == null) {
                    item { sectionProblem(ctx, Section.Incidents, false) }
                } else {
                    if (active.isEmpty()) item { EmptyNote("Активных инцидентов нет") }
                    items(active, key = { it.id }) { IncidentRow(ctx, it) }
                }
                item {
                    FilterChip(selected = showResolved, onClick = { showResolved = !showResolved }, label = { Text("Показать закрытые") })
                }
                if (showResolved) {
                    val r = resolved
                    when {
                        r.loading -> item { EmptyNote("Загружаем…") }
                        r.error != null -> item { ErrorNote(r.error) }
                        r.value.isNullOrEmpty() -> item { EmptyNote("Закрытых инцидентов нет") }
                        else -> items(r.value, key = { "r" + it.id }) { IncidentRow(ctx, it) }
                    }
                }
            }
            JournalTab.Logs -> {
                item {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        LevelFilter.entries.forEach { f -> FilterChip(selected = level == f, onClick = { level = f }, label = { Text(f.label) }) }
                    }
                }
                logError?.let { item { ErrorNote(it, onRetry = { loadLogs(cursor) }) } }
                if (!logsLoading && logs.isEmpty() && logError == null) item { EmptyNote("Записей нет") }
                items(logs, key = { it.id }) { log -> LogRow(ctx, log) }
                item {
                    when {
                        logsLoading -> EmptyNote("Загружаем…")
                        cursor != null -> OutlinedButton(onClick = { loadLogs(cursor) }) { Text("Загрузить ещё") }
                    }
                }
            }
        }
    }
}

@Composable
private fun IncidentRow(ctx: UiContext, inc: Incident) {
    ItemRow(
        title = inc.title,
        subtitle = "${incidentStatus(inc.status).label} · ${agoText(inc.updatedAt, ctx.now)} · повторов: ${inc.occurrences}",
        icon = null,
        badge = { StatusBadge(severity(inc.severity)) },
        onClick = { ctx.vm.open(Screen.Incident(inc.id)) },
        modifier = Modifier.testTag("incident_${inc.id}"),
    )
}

@Composable
private fun LogRow(ctx: UiContext, log: LogEntry) {
    val name = ctx.snapshot.entity(log.entityId)?.name
    ItemRow(
        title = log.message,
        subtitle = listOfNotNull(localTime(log.at), log.source, name).joinToString(" · "),
        icon = null,
        badge = { StatusBadge(logLevel(log.level)) },
        onClick = log.entityId?.let { id -> { ctx.vm.open(Screen.Device(id)) } },
    )
}

@Composable
fun IncidentScreen(ctx: UiContext, id: String) {
    var reload by remember { mutableIntStateOf(0) }
    val loaded by rememberLoad(ctx, id, reload) { incident(id) }
    ScreenList("screen_incident") {
        val inc = loaded.value
        when {
            inc == null && loaded.loading -> item { EmptyNote("Загружаем…") }
            inc == null -> item { ErrorNote(loaded.error ?: "Нет данных", onRetry = { reload++ }) }
            else -> {
                loaded.error?.let { item { ErrorNote("$it — показаны прежние данные") } }
                item {
                    SectionCard(inc.title) {
                        StatusBadge(severity(inc.severity))
                        StatusBadge(incidentStatus(inc.status))
                        KeyValue("Открыт", localTime(inc.openedAt))
                        KeyValue("Обновлён", "${localTime(inc.updatedAt)} (${agoText(inc.updatedAt, ctx.now)})")
                        inc.resolvedAt?.let { KeyValue("Закрыт", localTime(it)) }
                        KeyValue("Повторов", inc.occurrences.toString())
                        KeyValue("Источник", inc.source)
                        Text(
                            if (inc.cause.isNotEmpty()) "Причина: ${inc.cause}" else "Причина неизвестна: Core указывает её только по прямым признакам",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        if (inc.lastMessage.isNotEmpty()) Text(inc.lastMessage, style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                        if (inc.status == "open") {
                            Button(onClick = { ctx.vm.acknowledge(inc.id) { reload++ } }, modifier = Modifier.testTag("incident_ack")) { Text("Подтвердить") }
                            Text("Подтверждённый инцидент всё равно закроется сам, когда проблема исчезнет.", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                        }
                        inc.entityId?.let { eid ->
                            OutlinedButton(onClick = { ctx.vm.open(Screen.Device(eid)) }, modifier = Modifier.testTag("incident_open_device")) {
                                Text("Открыть устройство" + (ctx.snapshot.entity(eid)?.name?.let { " «$it»" } ?: ""))
                            }
                        }
                    }
                }
                if (inc.timeline.isNotEmpty()) {
                    item {
                        SectionCard("Хронология") {
                            inc.timeline.forEach { ev -> ItemRow(ev.message, "${localTime(ev.at)} · ${timelineKind(ev.kind)}", null) }
                        }
                    }
                }
            }
        }
    }
}

private fun timelineKind(k: String) = when (k) {
    "opened" -> "открыт"
    "repeated" -> "повтор"
    "acknowledged" -> "подтверждён"
    "resolved" -> "закрыт"
    "note" -> "заметка"
    else -> k
}
