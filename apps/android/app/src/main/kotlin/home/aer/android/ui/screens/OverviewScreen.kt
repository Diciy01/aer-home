package home.aer.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import home.aer.android.ui.Screen
import home.aer.android.ui.UiContext
import home.aer.android.ui.components.EmptyNote
import home.aer.android.ui.components.ItemRow
import home.aer.android.ui.components.SectionCard
import home.aer.android.ui.components.StatusBadge
import home.aer.android.ui.components.typeIcon
import home.aer.android.ui.theme.AerColors
import home.aer.core.Section
import home.aer.core.StatusText
import home.aer.core.Tone
import home.aer.core.ago
import home.aer.core.monitoringStatus
import home.aer.core.networkSummaryTone
import home.aer.core.severity

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OverviewScreen(ctx: UiContext) {
    val s = ctx.snapshot
    val vm = ctx.vm
    ScreenList("screen_overview") {
        item {
            SectionCard("Состояние дома") {
                if (!sectionProblem(ctx, Section.Monitoring, s.overview != null)) {
                    val o = s.overview!!
                    Text("Устройств под наблюдением: ${o.devices}", style = MaterialTheme.typography.bodyLarge)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("online", "degraded", "offline", "unknown").forEach { st ->
                            val n = o.byStatus[st] ?: 0
                            if (n > 0) StatusBadge(monitoringStatus(st).let { it.copy(label = "${it.label}: $n") }, stale = ctx.stale)
                        }
                    }
                    val incidentsTone = if (o.criticalOpen > 0) Tone.Critical else if (o.openIncidents > 0) Tone.Warning else Tone.Ok
                    StatusBadge(StatusText("Открытых инцидентов: ${o.openIncidents}" + if (o.criticalOpen > 0) " (критичных: ${o.criticalOpen})" else "", incidentsTone))
                }
                Text(
                    "Обновлено: ${ago(s.lastSuccessAt, ctx.now)}" + (s.system?.let { if (it.demo) " · Core в демо-режиме" else "" } ?: ""),
                    style = MaterialTheme.typography.bodySmall,
                    color = AerColors.inkMuted,
                )
            }
        }
        val problems = s.states.values.filter { it.status == "offline" || it.status == "degraded" }
        item {
            SectionCard("Требуют внимания") {
                if (!sectionProblem(ctx, Section.Monitoring, s.overview != null)) {
                    if (problems.isEmpty()) EmptyNote("Проблемных устройств нет")
                    problems.forEach { st ->
                        ItemRow(
                            title = st.name,
                            subtitle = st.reason,
                            icon = typeIcon(st.type),
                            badge = { StatusBadge(monitoringStatus(st.status, st.worstSeverity), stale = ctx.stale) },
                            onClick = { vm.open(Screen.Device(st.entityId)) },
                        )
                    }
                }
            }
        }
        item {
            SectionCard("Сеть и ТВ", trailing = { TextButton(onClick = { vm.open(Screen.Network) }) { Text("Открыть") } }) {
                if (!sectionProblem(ctx, Section.Network, s.network != null)) {
                    val n = s.network!!
                    StatusBadge(StatusText(n.summary.title.ifEmpty { "Нет данных" }, networkSummaryTone(n.summary.level)), stale = ctx.stale)
                    n.summary.issues.take(3).forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
                }
            }
        }
        item {
            SectionCard("Активные инциденты", trailing = { TextButton(onClick = { vm.open(Screen.Journal) }) { Text("Журнал") } }) {
                if (!sectionProblem(ctx, Section.Incidents, s.incidents != null)) {
                    val list = s.incidents!!
                    if (list.isEmpty()) EmptyNote("Нет активных инцидентов")
                    list.take(3).forEach { inc ->
                        ItemRow(
                            title = inc.title,
                            subtitle = "${ago(home.aer.core.parseInstant(inc.updatedAt), ctx.now)} · повторов: ${inc.occurrences}",
                            icon = null,
                            badge = { StatusBadge(severity(inc.severity)) },
                            onClick = { vm.open(Screen.Incident(inc.id)) },
                        )
                    }
                }
            }
        }
        item {
            SectionCard("Питание и боты") {
                if (Section.Power !in s.disabled) {
                    val p = s.power
                    ItemRow(
                        title = "Питание",
                        subtitle = when {
                            p == null -> s.sectionErrors[Section.Power] ?: "Нет данных"
                            p.isEmpty() -> "Нет устройств с управлением питанием"
                            else -> "Устройств: ${p.size}" + (p.count { it.activeJob != null }.takeIf { it > 0 }?.let { " · выполняется заданий: $it" } ?: "")
                        },
                        icon = typeIcon("computer"),
                        onClick = { vm.open(Screen.Power) },
                    )
                }
                if (Section.Bots !in s.disabled) {
                    val b = s.bots
                    ItemRow(
                        title = "Боты",
                        subtitle = when {
                            b == null -> s.sectionErrors[Section.Bots] ?: "Нет данных"
                            b.isEmpty() -> "Ботов нет"
                            else -> "Ботов: ${b.size} · с проблемами: ${b.count { it.status == "offline" || it.status == "degraded" }}"
                        },
                        icon = typeIcon("telegram_bot"),
                        onClick = { vm.open(Screen.Bots) },
                    )
                }
            }
        }
        s.overview?.integrations?.takeIf { it.isNotEmpty() }?.let { list ->
            item {
                SectionCard("Источники данных") {
                    list.forEach { i ->
                        val tone = when (i.status) {
                            "ok" -> Tone.Ok
                            "disabled" -> Tone.Muted
                            else -> Tone.Warning
                        }
                        ItemRow(i.label, i.reason, null, badge = { StatusBadge(StatusText(statusWord(i.status), tone)) })
                    }
                }
            }
        }
    }
}

/** Integration status: ok | unavailable | disabled (contracts/openapi.yaml). */
private fun statusWord(s: String) = when (s) {
    "ok" -> "Работает"
    "disabled" -> "Выключено"
    "unavailable" -> "Недоступно"
    else -> s
}
