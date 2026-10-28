package home.aer.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Cottage
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.Power
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SmartToy
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import home.aer.android.data.UiMode
import home.aer.android.ui.ConnectionTest
import home.aer.android.ui.Screen
import home.aer.android.ui.UiContext
import home.aer.android.ui.components.ErrorNote
import home.aer.android.ui.components.ItemRow
import home.aer.android.ui.components.KeyValue
import home.aer.android.ui.components.SectionCard
import home.aer.android.ui.components.StatusBadge
import home.aer.android.ui.theme.AerColors
import home.aer.core.EndpointCheck
import home.aer.core.StatusText
import home.aer.core.Tone
import home.aer.core.checkEndpoint

@Composable
fun MoreScreen(ctx: UiContext) {
    val vm = ctx.vm
    val mode by vm.mode.collectAsStateWithLifecycle()
    ScreenList("screen_more") {
        item {
            SectionCard("Разделы") {
                ItemRow("Питание", "Включение, выключение, перезагрузка по политике Core", Icons.Outlined.Power, onClick = { vm.open(Screen.Power) }, modifier = Modifier.testTag("more_power"))
                ItemRow("Боты", "Состояние, журнал и разрешённые действия", Icons.Outlined.SmartToy, onClick = { vm.open(Screen.Bots) }, modifier = Modifier.testTag("more_bots"))
                ItemRow("Дом", "Изометрический вид с комнатами и устройствами", Icons.Outlined.Cottage, onClick = { vm.open(Screen.House) }, modifier = Modifier.testTag("more_house"))
                ItemRow("Подключение к Core", vm.coreUrl ?: "не настроено", Icons.Outlined.Settings, onClick = { vm.open(Screen.Settings) }, modifier = Modifier.testTag("more_settings"))
            }
        }
        item {
            SectionCard("Режим интерфейса") {
                Text("Сейчас: ${if (mode == UiMode.House) "«Дом»" else "«Классика»"}", style = MaterialTheme.typography.bodyMedium)
                OutlinedButton(onClick = { vm.toggleMode() }) {
                    Text(if (mode == UiMode.House) "Переключить на «Классика»" else "Переключить на «Дом»")
                }
            }
        }
        ctx.snapshot.system?.let { sys ->
            item {
                SectionCard("Core") {
                    KeyValue("Версия", sys.coreVersion)
                    KeyValue("Режим", sys.mode + if (sys.demo) " (демо-данные)" else "")
                    KeyValue("API", sys.apiVersion)
                    KeyValue("Модули", sys.modules.filter { it.enabled }.joinToString { it.name })
                }
            }
        }
    }
}

@Composable
fun SettingsScreen(ctx: UiContext) {
    val vm = ctx.vm
    var url by rememberSaveable { mutableStateOf(vm.coreUrl ?: "") }
    var token by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    var saved by rememberSaveable { mutableStateOf(false) }
    val test by vm.connectionTest.collectAsStateWithLifecycle()
    val mode by vm.mode.collectAsStateWithLifecycle()
    val check = if (url.isBlank()) null else checkEndpoint(url)

    ScreenList("screen_settings") {
        item {
            SectionCard("Адрес Core") {
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it; error = null; saved = false },
                    modifier = Modifier.fillMaxWidth().testTag("settings_url"),
                    label = { Text("Адрес, например http://192.168.1.10:8787") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    isError = check is EndpointCheck.Invalid,
                    supportingText = {
                        when (check) {
                            is EndpointCheck.Invalid -> Text(check.message)
                            is EndpointCheck.Ok -> check.warning?.let { Text(it, color = AerColors.amber) }
                            null -> Unit
                        }
                    },
                )
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it; error = null; saved = false },
                    modifier = Modifier.fillMaxWidth().testTag("settings_token"),
                    label = { Text(if (vm.hasToken) "Новый токен (пусто — оставить сохранённый)" else "Токен доступа") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                )
                Text(
                    if (vm.hasToken) "Токен сохранён в зашифрованном виде (ключ Android Keystore)." else "Токен не сохранён.",
                    style = MaterialTheme.typography.bodySmall,
                    color = AerColors.inkMuted,
                )
                error?.let { ErrorNote(it) }
                if (saved) StatusBadge(StatusText("Сохранено", Tone.Ok))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = {
                            error = vm.saveConnection(url, token)
                            if (error == null) {
                                token = ""
                                saved = true
                                vm.testConnection()
                            }
                        },
                        modifier = Modifier.testTag("settings_save"),
                    ) { Text("Сохранить") }
                    OutlinedButton(onClick = { vm.testConnection() }, modifier = Modifier.testTag("settings_test")) { Text("Проверить") }
                }
                when (val t = test) {
                    ConnectionTest.Idle -> Unit
                    ConnectionTest.Running -> Text("Проверяем…", style = MaterialTheme.typography.bodySmall)
                    is ConnectionTest.Ok -> StatusBadge(StatusText(t.text, Tone.Ok), Modifier.testTag("settings_test_ok"))
                    is ConnectionTest.Failed -> ErrorNote(t.text, Modifier.testTag("settings_test_failed"))
                }
                if (vm.hasToken) TextButton(onClick = { vm.forgetToken() }) { Text("Удалить сохранённый токен") }
            }
        }
        item {
            SectionCard("Где взять адрес и токен") {
                Text(
                    "• Токен — содержимое файла core.token в каталоге данных Core (права 0600). Скопируйте его на телефон безопасным способом.\n" +
                        "• Чтобы телефон видел Core, Core должен работать в режиме local или server и слушать адрес домашней сети или Tailscale " +
                        "(в режиме development он доступен только на самом компьютере).\n" +
                        "• Не открывайте Core в интернет: используйте домашнюю сеть или Tailscale.\n" +
                        "• В эмуляторе Android компьютер с Core доступен по адресу 10.0.2.2.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        item {
            SectionCard("Режим интерфейса") {
                ItemRow(
                    if (mode == UiMode.House) "Сейчас «Дом»" else "Сейчас «Классика»",
                    "Переключение не трогает данные и настройки",
                    if (mode == UiMode.House) Icons.Outlined.Cottage else Icons.Outlined.Dashboard,
                    onClick = { vm.toggleMode() },
                )
            }
        }
    }
}
