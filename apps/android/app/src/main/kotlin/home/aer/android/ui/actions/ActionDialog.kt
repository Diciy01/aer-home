package home.aer.android.ui.actions

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import home.aer.android.ui.AppViewModel
import home.aer.android.ui.theme.AerColors
import home.aer.core.ActionStep
import home.aer.core.ActionTarget

/** Core's confirm → execute protocol on screen. Nothing runs until «Подтвердить». */
@Composable
fun ActionDialog(vm: AppViewModel) {
    val step by vm.actions.step.collectAsStateWithLifecycle()
    when (val s = step) {
        ActionStep.Idle -> Unit
        is ActionStep.Preparing -> AlertDialog(
            onDismissRequest = vm::dismissAction,
            title = { Text(s.target.label) },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Core проверяет условия для «${s.target.entityName}»…")
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = vm::dismissAction) { Text("Отмена") } },
        )
        is ActionStep.AwaitingUser -> AlertDialog(
            modifier = Modifier.testTag("action_confirm_dialog"),
            onDismissRequest = vm::dismissAction,
            title = { Text("${s.target.label}: ${s.target.entityName}") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(s.preview.summary, style = MaterialTheme.typography.bodyLarge)
                    if (s.preview.checks.isNotEmpty()) {
                        Text("Проверки Core", fontWeight = FontWeight.SemiBold)
                        s.preview.checks.forEach { c ->
                            Row(verticalAlignment = Alignment.Top) {
                                Icon(
                                    if (c.ok) Icons.Outlined.CheckCircle else Icons.Outlined.ErrorOutline,
                                    if (c.ok) "Пройдена" else "Не пройдена",
                                    tint = if (c.ok) AerColors.sage else AerColors.terracotta,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(c.name + if (c.message.isNotEmpty()) " — ${c.message}" else "", style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                    if (s.preview.risks.isNotEmpty()) {
                        Text("Риски", fontWeight = FontWeight.SemiBold)
                        s.preview.risks.forEach { r ->
                            Row {
                                Icon(Icons.Outlined.WarningAmber, null, tint = AerColors.amber, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(r, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                    Text("Подтверждение действует ограниченное время и только для этого действия.", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                }
            },
            confirmButton = {
                Button(
                    onClick = vm::approveAction,
                    modifier = Modifier.testTag("action_approve"),
                    colors = if (s.target.kind == ActionTarget.Kind.Power && s.target.action != "wake") {
                        ButtonDefaults.buttonColors(containerColor = AerColors.terracotta)
                    } else {
                        ButtonDefaults.buttonColors()
                    },
                ) { Text("Подтвердить") }
            },
            dismissButton = { TextButton(onClick = vm::dismissAction) { Text("Отмена") } },
        )
        is ActionStep.Running -> AlertDialog(
            onDismissRequest = {},
            title = { Text(s.target.label) },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Запрос отправлен в Core…")
                }
            },
            confirmButton = {},
        )
        is ActionStep.Finished -> AlertDialog(
            modifier = Modifier.testTag("action_result_dialog"),
            onDismissRequest = vm::dismissAction,
            icon = {
                Icon(
                    if (s.outcome.simulated || !s.outcome.ok) Icons.Outlined.WarningAmber else Icons.Outlined.CheckCircle,
                    null,
                    tint = if (s.outcome.simulated) AerColors.amber else if (s.outcome.ok) AerColors.sage else AerColors.terracotta,
                )
            },
            title = { Text(s.outcome.title) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("${s.target.label}: ${s.target.entityName}", fontWeight = FontWeight.SemiBold)
                    if (s.outcome.message.isNotEmpty()) Text(s.outcome.message)
                    if (s.outcome.simulated) {
                        Text("Агент работает в режиме проверки: реальное действие не выполнялось.", color = AerColors.amber)
                    }
                    if (s.outcome.replayed) Text("Core вернул результат уже выполненного запроса (повтор того же намерения).", style = MaterialTheme.typography.bodySmall)
                    if (s.outcome.powerJobId != null) {
                        Text("Состояние задания обновляется, пока Core не сообщит итог.", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                    }
                }
            },
            confirmButton = { TextButton(onClick = vm::dismissAction, modifier = Modifier.testTag("action_close")) { Text("Закрыть") } },
        )
        is ActionStep.Failed -> AlertDialog(
            modifier = Modifier.testTag("action_failed_dialog"),
            onDismissRequest = vm::dismissAction,
            icon = { Icon(Icons.Outlined.ErrorOutline, null, tint = AerColors.terracotta) },
            title = { Text("${s.target.label}: не выполнено") },
            text = {
                Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(s.message)
                    if (s.retryable) {
                        Text(
                            "Ответ Core не получен — действие могло начаться. Повтор безопасен: Core выполнит его не более одного раза.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            },
            confirmButton = {
                if (s.retryable) TextButton(onClick = vm::retryAction) { Text("Повторить") }
            },
            dismissButton = { TextButton(onClick = vm::dismissAction) { Text("Закрыть") } },
        )
    }
}
