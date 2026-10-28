package home.aer.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import home.aer.android.ui.components.typeIcon
import home.aer.android.ui.theme.AerColors
import home.aer.core.Entity
import home.aer.core.EntityState
import home.aer.core.HomeSnapshot
import home.aer.core.Section
import home.aer.core.agoText
import home.aer.core.latencyText
import home.aer.core.localTime
import home.aer.core.logLevel
import home.aer.core.monitoringStatus
import home.aer.core.networkStatus
import home.aer.core.powerState
import home.aer.core.severity

private enum class DeviceFilter(val label: String) { All("Все"), Problems("Проблемы"), Online("В сети"), NoData("Нет данных") }

private fun rank(st: EntityState?) = when (st?.status) {
    "offline" -> 0
    "degraded" -> 1
    "online" -> 3
    else -> 2
}

/** Registry entities with their Monitoring state; problems first. */
fun deviceList(s: HomeSnapshot, query: String, problemsOnly: Boolean = false): List<Entity> {
    val q = query.trim().lowercase()
    return (s.entities ?: emptyList())
        .filter { !it.archived }
        .filter { q.isEmpty() || it.name.lowercase().contains(q) || it.address.lowercase().contains(q) || s.typeLabel(it.type).lowercase().contains(q) }
        .filter { !problemsOnly || rank(s.states[it.id]) < 2 }
        .sortedWith(compareBy({ rank(s.states[it.id]) }, { it.name.lowercase() }))
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(ctx: UiContext) {
    val s = ctx.snapshot
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf(DeviceFilter.All) }
    val list = deviceList(s, query).filter {
        when (filter) {
            DeviceFilter.All -> true
            DeviceFilter.Problems -> rank(s.states[it.id]) < 2
            DeviceFilter.Online -> s.states[it.id]?.status == "online"
            DeviceFilter.NoData -> rank(s.states[it.id]) == 2
        }
    }
    ScreenList("screen_devices") {
        item {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth().testTag("device_search"),
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                placeholder = { Text("Имя, тип или адрес") },
                singleLine = true,
            )
        }
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                DeviceFilter.entries.forEach { f ->
                    FilterChip(selected = filter == f, onClick = { filter = f }, label = { Text(f.label) })
                }
            }
        }
        if (s.entities == null) {
            item { sectionProblem(ctx, Section.Registry, false) }
        } else {
            s.sectionErrors[Section.Registry]?.let { item { ErrorNote("$it — показаны прежние данные") } }
            if (list.isEmpty()) item { EmptyNote(if (s.entities.isNullOrEmpty()) "В Registry пока нет устройств" else "Ничего не найдено") }
            items(list, key = { it.id }) { e ->
                val st = s.states[e.id]
                ItemRow(
                    title = e.name,
                    subtitle = listOfNotNull(
                        s.typeLabel(e.type),
                        e.address.ifEmpty { null },
                        st?.latencyMs?.let { latencyText(it) },
                    ).joinToString(" · "),
                    icon = typeIcon(e.type),
                    badge = { StatusBadge(monitoringStatus(st?.status ?: "unknown", st?.worstSeverity), stale = ctx.stale) },
                    onClick = { ctx.vm.open(Screen.Device(e.id)) },
                    modifier = Modifier.testTag("device_${e.id}"),
                )
            }
        }
    }
}

@Composable
fun DeviceScreen(ctx: UiContext, id: String) {
    val s = ctx.snapshot
    val vm = ctx.vm
    val e = s.entity(id)
    val st = s.states[id]
    val logs by rememberLoad(ctx, id) { logs(entityId = id, limit = 30) }
    ScreenList("screen_device") {
        if (e == null) {
            item {
                if (s.entities == null) sectionProblem(ctx, Section.Registry, false) else ErrorNote("Объект не найден в Registry (возможно, удалён)")
            }
            return@ScreenList
        }
        item {
            SectionCard(e.name) {
                StatusBadge(monitoringStatus(st?.status ?: "unknown", st?.worstSeverity), stale = ctx.stale)
                KeyValue("Тип", s.typeLabel(e.type))
                if (e.address.isNotEmpty()) KeyValue("Адрес", e.address)
                if (e.description.isNotEmpty()) KeyValue("Описание", e.description)
                if (e.tags.isNotEmpty()) KeyValue("Метки", e.tags.joinToString())
                OutlinedButton(onClick = { vm.showInHouse(id) }, modifier = Modifier.testTag("show_in_house")) { Text("Показать в доме") }
            }
        }
        item {
            SectionCard("Мониторинг") {
                if (!sectionProblem(ctx, Section.Monitoring, st != null || s.overview != null)) {
                    if (st == null) {
                        EmptyNote("Monitoring не прислал состояния этого объекта")
                    } else {
                        if (st.reason.isNotEmpty()) Text(st.reason, style = MaterialTheme.typography.bodyMedium)
                        KeyValue("Задержка", latencyText(st.latencyMs))
                        KeyValue("Последний ответ", agoText(st.lastContactAt, ctx.now))
                        KeyValue("Последняя проверка", agoText(st.lastCheckAt, ctx.now))
                        KeyValue("Состояние с", localTime(st.changedAt))
                        if (st.checkKind.isNotEmpty()) KeyValue("Способ проверки", st.checkKind)
                    }
                }
            }
        }
        networkFacts(s, id)?.let { (label, status, reason) ->
            item {
                SectionCard("Сеть") {
                    StatusBadge(networkStatus(status), stale = ctx.stale)
                    Text("$label: $reason", style = MaterialTheme.typography.bodyMedium)
                    OutlinedButton(onClick = { vm.open(Screen.Network) }) { Text("Раздел «Сеть и ТВ»") }
                }
            }
        }
        s.power?.firstOrNull { it.entityId == id }?.let { p ->
            item {
                SectionCard("Питание") {
                    StatusBadge(powerState(p.state), stale = ctx.stale)
                    if (p.stateReason.isNotEmpty()) Text(p.stateReason, style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                    PowerActions(ctx, p)
                }
            }
        }
        s.bots?.firstOrNull { it.entityId == id }?.let {
            item {
                SectionCard("Бот") {
                    Button(onClick = { vm.open(Screen.Bot(id)) }) { Text("Открыть бота") }
                }
            }
        }
        val incidents = s.incidents?.filter { it.entityId == id }.orEmpty()
        item {
            SectionCard("Инциденты") {
                if (incidents.isEmpty()) EmptyNote("Активных инцидентов нет")
                incidents.forEach { inc ->
                    ItemRow(inc.title, inc.lastMessage, null, badge = { StatusBadge(severity(inc.severity)) }, onClick = { vm.open(Screen.Incident(inc.id)) })
                }
            }
        }
        item {
            SectionCard("Журнал устройства") {
                val l = logs
                when {
                    l.loading -> EmptyNote("Загружаем…")
                    l.error != null -> ErrorNote(l.error)
                    l.value?.items.isNullOrEmpty() -> EmptyNote("Записей нет")
                    else -> l.value.items.forEach { log ->
                        ItemRow(log.message, "${localTime(log.at)} · ${log.source}", null, badge = { StatusBadge(logLevel(log.level)) })
                    }
                }
            }
        }
    }
}

/** The entity's line in the network overview, if any: (label, status, reason). */
private fun networkFacts(s: HomeSnapshot, id: String): Triple<String, String, String>? {
    val n = s.network ?: return null
    n.routers.firstOrNull { it.device.entityId == id }?.let { r ->
        return Triple("Роутер", r.wan?.status ?: r.device.status, r.wan?.reason ?: r.device.reason)
    }
    (n.devices + n.tvs).firstOrNull { it.entityId == id }?.let { return Triple(if (it.type == "television") "Телевизор" else "Устройство", it.status, it.reason) }
    n.sunshine.firstOrNull { it.entity?.entityId == id }?.let { return Triple("Sunshine", it.check.status, it.check.reason) }
    return null
}
