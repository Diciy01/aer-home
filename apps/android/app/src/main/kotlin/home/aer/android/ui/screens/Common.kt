package home.aer.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import home.aer.android.ui.UiContext
import home.aer.android.ui.components.EmptyNote
import home.aer.android.ui.components.ErrorNote
import home.aer.core.CoreApi
import home.aer.core.Link
import home.aer.core.Section
import home.aer.core.describeError

/** Standard scrolling screen body. */
@Composable
fun ScreenList(tag: String, content: LazyListScope.() -> Unit) {
    LazyColumn(
        Modifier.fillMaxSize().testTag(tag),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

/** What a section shows when it has no data: disabled module, its error, or loading. Returns true if it rendered something. */
@Composable
fun sectionProblem(ctx: UiContext, section: Section, hasData: Boolean): Boolean {
    if (section in ctx.snapshot.disabled) {
        EmptyNote("Модуль выключен в конфигурации Core")
        return true
    }
    ctx.snapshot.sectionErrors[section]?.let {
        ErrorNote(it + if (hasData) " — показаны прежние данные" else "", onRetry = { ctx.vm.refreshNow() })
        if (!hasData) return true
    }
    if (!hasData) {
        EmptyNote(
            when (ctx.snapshot.link) {
                Link.Connecting -> "Ждём ответа Core…"
                Link.Online -> "Нет данных"
                Link.NotConfigured -> "Нет данных: Core не настроен"
                else -> "Нет данных: Core недоступен"
            },
        )
        return true
    }
    return false
}

/** One-off read for a detail screen, re-run when [key] changes. */
class Loaded<T>(val value: T?, val error: String?, val loading: Boolean)

@Composable
fun <T> rememberLoad(ctx: UiContext, vararg keys: Any?, block: suspend CoreApi.() -> T): MutableState<Loaded<T>> {
    val state = remember(*keys) { mutableStateOf(Loaded<T>(null, null, true)) }
    LaunchedEffect(*keys) {
        ctx.vm.load(block)
            .onSuccess { state.value = Loaded(it, null, false) }
            .onFailure { state.value = Loaded(state.value.value, describeError(it), false) }
    }
    return state
}
