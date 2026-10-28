package home.aer.android.ui.screens

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import android.net.Uri
import home.aer.android.ui.Screen
import home.aer.android.ui.UiContext
import home.aer.android.ui.components.EmptyNote
import home.aer.android.ui.components.ItemRow
import home.aer.android.ui.components.KeyValue
import home.aer.android.ui.components.SectionCard
import home.aer.android.ui.components.StatusBadge
import home.aer.android.ui.components.typeIcon
import home.aer.android.ui.theme.AerColors
import home.aer.core.NetworkCheck
import home.aer.core.NetworkDevice
import home.aer.core.Section
import home.aer.core.StatusText
import home.aer.core.agoText
import home.aer.core.latencyText
import home.aer.core.localTime
import home.aer.core.logLevel
import home.aer.core.networkStatus
import home.aer.core.networkSummaryTone
import home.aer.core.severity
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/** M09 «Сеть и ТВ»: router, internet, TV and Sunshine as separate objects; read-only checks. */
@Composable
fun NetworkScreen(ctx: UiContext) {
    val s = ctx.snapshot
    val vm = ctx.vm
    ScreenList("screen_network") {
        val n = s.network
        if (n == null) {
            item { SectionCard("Сеть и ТВ") { sectionProblem(ctx, Section.Network, false) } }
            return@ScreenList
        }
        item {
            SectionCard("Сводка") {
                StatusBadge(StatusText(n.summary.title.ifEmpty { "Нет данных" }, networkSummaryTone(n.summary.level)), stale = ctx.stale)
                n.summary.issues.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) }
                Text(
                    "Проверки каждые ${n.intervalSec} с · сводка от ${agoText(n.generatedAt, ctx.now)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = AerColors.inkMuted,
                )
                sectionProblem(ctx, Section.Network, true)
                Button(onClick = { vm.networkCheckNow() }, modifier = Modifier.testTag("network_check_now")) { Text("Проверить сейчас") }
                Text("Только чтение: настройки роутера и сети не меняются, сеть не сканируется.", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
            }
        }
        item {
            SectionCard("Интернет") {
                val inet = n.internet
                if (inet == null || inet.status == "unconfigured") {
                    StatusBadge(networkStatus("unconfigured"))
                    EmptyNote(inet?.reason?.ifEmpty { null } ?: "Цели проверки интернета не заданы в конфигурации Core")
                } else {
                    CheckFacts(ctx, inet)
                }
            }
        }
        item {
            SectionCard("Роутеры") {
                if (n.routers.isEmpty()) EmptyNote("Роутер не указан в конфигурации сети Core")
                n.routers.forEach { r ->
                    DeviceLine(ctx, r.device)
                    val wan = r.wan
                    if (wan != null) {
                        Text("WAN (${r.adapterNote.ifEmpty { r.adapter }})", style = MaterialTheme.typography.labelLarge)
                        CheckFacts(ctx, wan)
                    } else {
                        Text(r.adapterNote.ifEmpty { "Состояние WAN роутером не сообщается: проверяется только доступность" }, style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                    }
                }
            }
        }
        item {
            SectionCard("Телевизоры") {
                if (n.tvs.isEmpty()) EmptyNote("Телевизоров в Registry нет")
                n.tvs.forEach { DeviceLine(ctx, it) }
            }
        }
        item {
            SectionCard("Sunshine") {
                if (n.sunshine.isEmpty()) EmptyNote("Sunshine не указан в конфигурации сети Core")
                n.sunshine.forEach { sun ->
                    Text(sun.name, style = MaterialTheme.typography.titleSmall)
                    CheckFacts(ctx, sun.check)
                    val d = sun.check.details
                    val streaming = (d?.get("streaming") as? JsonPrimitive)?.booleanOrNull
                    val version = (d?.get("version") as? JsonPrimitive)?.contentOrNull
                    if (sun.check.status == "up") {
                        KeyValue("Стрим", if (streaming == true) "идёт" else "нет")
                        version?.let { KeyValue("Версия", it) }
                    }
                    Text("Состояние ПК и телевизора — отдельно:", style = MaterialTheme.typography.labelLarge)
                    sun.entity?.let { DeviceLine(ctx, it) }
                    sun.tv?.let { DeviceLine(ctx, it) }
                    SunshineLink(sun.webUrl)
                }
            }
        }
        item {
            SectionCard("Другие сетевые устройства") {
                if (n.devices.isEmpty()) EmptyNote("Других сетевых устройств в Registry нет")
                n.devices.forEach { DeviceLine(ctx, it) }
            }
        }
        if (n.incidents.isNotEmpty()) {
            item {
                SectionCard("Инциденты сети") {
                    n.incidents.forEach { inc ->
                        ItemRow(inc.title, inc.lastMessage, null, badge = { StatusBadge(severity(inc.severity)) }, onClick = { vm.open(Screen.Incident(inc.id)) })
                    }
                }
            }
        }
        item {
            SectionCard("Журнал проверок") {
                if (n.recent.isEmpty()) EmptyNote("Записей нет")
                n.recent.take(15).forEach { log ->
                    ItemRow(
                        log.message,
                        localTime(log.at),
                        null,
                        badge = { StatusBadge(logLevel(log.level)) },
                        onClick = log.entityId?.let { id -> { vm.open(Screen.Device(id)) } },
                    )
                }
            }
        }
    }
}

@Composable
private fun CheckFacts(ctx: UiContext, c: NetworkCheck) {
    StatusBadge(networkStatus(c.status), stale = c.stale || ctx.stale)
    if (c.reason.isNotEmpty()) Text(c.reason, style = MaterialTheme.typography.bodyMedium)
    KeyValue("Задержка", latencyText(c.latencyMs))
    KeyValue("Последняя проверка", agoText(c.lastCheckAt, ctx.now))
    KeyValue("Последний успех", agoText(c.lastOkAt, ctx.now))
    if (c.failures > 0) KeyValue("Сбоев подряд", c.failures.toString())
}

@Composable
private fun DeviceLine(ctx: UiContext, d: NetworkDevice) {
    ItemRow(
        title = d.name,
        subtitle = listOfNotNull(
            d.reason.ifEmpty { null },
            "задержка ${latencyText(d.latencyMs)}",
            "проверено ${agoText(d.lastCheckAt, ctx.now)}",
        ).joinToString(" · "),
        icon = typeIcon(d.type),
        badge = { StatusBadge(networkStatus(d.status), stale = d.stale || ctx.stale) },
        onClick = { ctx.vm.open(Screen.Device(d.entityId)) },
        modifier = Modifier.testTag("net_${d.entityId}"),
    )
}

/** Opens Sunshine's own web UI in the browser; only http(s) URLs from Core's config. */
@Composable
private fun SunshineLink(url: String) {
    if (!(url.startsWith("https://") || url.startsWith("http://"))) return
    val context = LocalContext.current
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
        }) { Text("Открыть Sunshine") }
    }
}
