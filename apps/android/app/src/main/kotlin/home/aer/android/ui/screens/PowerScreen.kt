package home.aer.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
import home.aer.core.ActionTarget
import home.aer.core.Bot
import home.aer.core.PowerDevice
import home.aer.core.Section
import home.aer.core.agoText
import home.aer.core.localTime
import home.aer.core.logLevel
import home.aer.core.monitoringStatus
import home.aer.core.powerJobState
import home.aer.core.powerState

@Composable
fun PowerScreen(ctx: UiContext) {
    val s = ctx.snapshot
    ScreenList("screen_power") {
        item {
            Text(
                "Каждое действие Core проверяет и просит подтвердить; выполняет его агент на устройстве. Недоступные действия показаны с причиной.",
                style = MaterialTheme.typography.bodySmall,
                color = AerColors.inkMuted,
            )
        }
        val list = s.power
        if (list == null) {
            item { sectionProblem(ctx, Section.Power, false) }
            return@ScreenList
        }
        s.sectionErrors[Section.Power]?.let { item { ErrorNote("$it — показаны прежние данные") } }
        if (list.isEmpty()) item { EmptyNote("Нет устройств с управлением питанием (возможности power.* в Registry)") }
        items(list, key = { it.entityId }) { p ->
            SectionCard(p.name) {
                StatusBadge(powerState(p.state), stale = ctx.stale)
                if (p.stateReason.isNotEmpty()) Text(p.stateReason, style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                if (p.currentOs.isNotEmpty()) KeyValue("Текущая ОС", p.currentOs)
                KeyValue("На связи", agoText(p.lastContactAt, ctx.now))
                if (p.sameMachineAsCore) Text(p.sameMachineNote.ifEmpty { "Это компьютер, на котором работает Core" }, style = MaterialTheme.typography.bodySmall, color = AerColors.amber)
                PowerActions(ctx, p)
                OutlinedButton(onClick = { ctx.vm.open(Screen.Device(p.entityId)) }) { Text("Карточка устройства") }
            }
        }
    }
}

/** Power actions exactly as Core lists them; the client never decides availability itself. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PowerActions(ctx: UiContext, p: PowerDevice) {
    p.activeJob?.let { KeyValue("Задание", "${it.action}: ${powerJobState(it.state).label}") }
    p.lastJob?.takeIf { p.activeJob == null }?.let { j ->
        KeyValue("Последнее задание", "${j.action}: ${powerJobState(j.state).label}" + if (j.simulated) " (SIMULATED)" else "")
    }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        p.actions.filter { it.available }.forEach { a ->
            val targets: List<String?> = if (a.id == "switch_os") listOf("linux", "windows").filter { it != p.currentOs } else listOf(null)
            targets.forEach { os ->
                val label = if (os != null) "${a.label}: ${if (os == "linux") "Linux" else "Windows"}" else a.label
                val target = ActionTarget(ActionTarget.Kind.Power, p.entityId, p.name, a.id, label, needsConfirmation = a.id != "check", targetOs = os)
                if (a.dangerous) {
                    Button(
                        onClick = { ctx.vm.startAction(target) },
                        colors = ButtonDefaults.buttonColors(containerColor = AerColors.terracotta),
                        modifier = Modifier.testTag("power_${p.entityId}_${a.id}"),
                    ) { Text(label) }
                } else {
                    OutlinedButton(onClick = { ctx.vm.startAction(target) }, modifier = Modifier.testTag("power_${p.entityId}_${a.id}")) { Text(label) }
                }
            }
        }
    }
    val unavailable = p.actions.filter { !it.available }
    if (unavailable.isNotEmpty()) {
        Column {
            unavailable.forEach { a ->
                Text("${a.label}: ${a.reason.ifEmpty { "недоступно" }}", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
            }
        }
    }
}

@Composable
fun BotsScreen(ctx: UiContext) {
    val s = ctx.snapshot
    ScreenList("screen_bots") {
        val list = s.bots
        if (list == null) {
            item { sectionProblem(ctx, Section.Bots, false) }
            return@ScreenList
        }
        s.sectionErrors[Section.Bots]?.let { item { ErrorNote("$it — показаны прежние данные") } }
        if (list.isEmpty()) item { EmptyNote("Ботов нет. Добавляются в настольном клиенте («Боты» → «Добавить»).") }
        items(list.filter { !it.archived }, key = { it.entityId }) { b ->
            ItemRow(
                title = b.name,
                subtitle = listOf(b.runtime, b.statusReason).filter { it.isNotEmpty() }.joinToString(" · "),
                icon = typeIcon("telegram_bot"),
                badge = { StatusBadge(monitoringStatus(b.status), stale = ctx.stale) },
                onClick = { ctx.vm.open(Screen.Bot(b.entityId)) },
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BotDetailScreen(ctx: UiContext, id: String) {
    val bot: Bot? = ctx.snapshot.bots?.firstOrNull { it.entityId == id }
    val actions by rememberLoad(ctx, id, ctx.snapshot.lastSuccessAt) { botActions(id) }
    val logs by rememberLoad(ctx, id) { logs(entityId = id, limit = 30) }
    ScreenList("screen_bot") {
        if (bot == null) {
            item { if (ctx.snapshot.bots == null) sectionProblem(ctx, Section.Bots, false) else ErrorNote("Бот не найден") }
            return@ScreenList
        }
        item {
            SectionCard(bot.name) {
                StatusBadge(monitoringStatus(bot.status), stale = ctx.stale)
                if (bot.statusReason.isNotEmpty()) Text(bot.statusReason, style = MaterialTheme.typography.bodyMedium)
                if (bot.runtime.isNotEmpty()) KeyValue("Среда", bot.runtime)
                if (bot.version.isNotEmpty()) KeyValue("Версия", bot.version)
                KeyValue("На связи", agoText(bot.lastContactAt, ctx.now))
                bot.uptimeSec?.let { KeyValue("Работает", "${it / 3600} ч ${it % 3600 / 60} мин") }
                if (bot.lastError.isNotEmpty()) KeyValue("Последняя ошибка", "${bot.lastError} (${agoText(bot.lastErrorAt, ctx.now)})")
                if (bot.controllerId.isEmpty()) Text("Только мониторинг: управляющий адаптер не настроен в Core", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                OutlinedButton(onClick = { ctx.vm.open(Screen.Device(id)) }) { Text("Карточка в Registry") }
            }
        }
        item {
            SectionCard("Управление") {
                val a = actions
                when {
                    a.value == null && a.loading -> EmptyNote("Загружаем…")
                    a.value == null -> ErrorNote(a.error ?: "Нет данных")
                    else -> {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            a.value.filter { it.available }.forEach { act ->
                                OutlinedButton(
                                    onClick = {
                                        ctx.vm.startAction(ActionTarget(ActionTarget.Kind.Bot, id, bot.name, act.id, act.label, needsConfirmation = act.confirm))
                                    },
                                    modifier = Modifier.testTag("bot_action_${act.id}"),
                                ) { Text(act.label) }
                            }
                        }
                        a.value.filter { !it.available }.forEach { act ->
                            Text("${act.label}: ${act.reason.ifEmpty { "недоступно" }}", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                        }
                    }
                }
            }
        }
        item {
            SectionCard("Журнал бота") {
                val l = logs
                when {
                    l.loading -> EmptyNote("Загружаем…")
                    l.error != null -> ErrorNote(l.error)
                    l.value?.items.isNullOrEmpty() -> EmptyNote("Записей нет")
                    else -> l.value.items.forEach { log -> ItemRow(log.message, "${localTime(log.at)} · ${log.source}", null, badge = { StatusBadge(logLevel(log.level)) }) }
                }
            }
        }
    }
}
