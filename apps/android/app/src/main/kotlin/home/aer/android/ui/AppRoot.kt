package home.aer.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.outlined.Cottage
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import home.aer.android.data.UiMode
import home.aer.android.ui.actions.ActionDialog
import home.aer.android.ui.components.ConnectionBanner
import home.aer.android.ui.house.HouseScreen
import home.aer.android.ui.screens.BotDetailScreen
import home.aer.android.ui.screens.BotsScreen
import home.aer.android.ui.screens.DeviceScreen
import home.aer.android.ui.screens.DevicesScreen
import home.aer.android.ui.screens.IncidentScreen
import home.aer.android.ui.screens.JournalScreen
import home.aer.android.ui.screens.MoreScreen
import home.aer.android.ui.screens.NetworkScreen
import home.aer.android.ui.screens.OverviewScreen
import home.aer.android.ui.screens.PowerScreen
import home.aer.android.ui.screens.SettingsScreen
import home.aer.android.ui.theme.AerColors
import home.aer.core.HomeSnapshot
import kotlinx.coroutines.delay
import java.time.Instant

/** Shared state every screen gets. */
class UiContext(val vm: AppViewModel, val snapshot: HomeSnapshot, val now: Instant) {
    val stale get() = snapshot.isStale(now, AppViewModel.STALE_AFTER)
}

@Composable
fun AppRoot(vm: AppViewModel) {
    val mode by vm.mode.collectAsStateWithLifecycle()
    val stack by vm.stack.collectAsStateWithLifecycle()
    val snapshot by vm.repository.snapshot.collectAsStateWithLifecycle()
    val message by vm.message.collectAsStateWithLifecycle()
    val now by produceState(Instant.now()) {
        while (true) {
            value = Instant.now()
            delay(1000)
        }
    }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(message) {
        message?.let {
            snackbar.showSnackbar(it)
            vm.messageShown()
        }
    }
    BackHandler(enabled = stack.size > 1) { vm.back() }

    val m = mode
    if (m == null) {
        ModeChoiceScreen(onChoose = vm::chooseMode)
        return
    }
    val ctx = UiContext(vm, snapshot, now)
    val screen = stack.last()
    if (screen == Screen.House) {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }, containerColor = AerColors.background) { pad ->
            HouseScreen(ctx, Modifier.padding(pad), canGoBack = stack.size > 1)
        }
    } else {
        AppScaffold(ctx, m, screen, isRoot = stack.size == 1, snackbar = snackbar)
    }
    ActionDialog(vm)
    var settingsOffered by rememberSaveable { mutableStateOf(false) }
    if (!vm.isConfigured && !settingsOffered) {
        // First start: offer the connection settings once; the user may leave them and look around.
        LaunchedEffect(Unit) {
            settingsOffered = true
            vm.open(Screen.Settings)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppScaffold(ctx: UiContext, mode: UiMode, screen: Screen, isRoot: Boolean, snackbar: SnackbarHostState) {
    val vm = ctx.vm
    Scaffold(
        containerColor = AerColors.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = AerColors.background),
                title = { Text(titleOf(screen, ctx.snapshot), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    if (!isRoot) {
                        IconButton(onClick = { vm.back() }, modifier = Modifier.testTag("nav_back")) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Назад")
                        }
                    }
                },
                actions = {
                    IconButton(onClick = { vm.refreshNow() }) { Icon(Icons.Filled.Refresh, "Обновить") }
                    IconButton(onClick = { vm.toggleMode() }, modifier = Modifier.testTag("toggle_mode")) {
                        if (mode == UiMode.House) {
                            Icon(Icons.Filled.ViewAgenda, "Переключить на «Классика»")
                        } else {
                            Icon(Icons.Filled.Home, "Переключить на «Дом»")
                        }
                    }
                },
            )
        },
        bottomBar = {
            if (mode == UiMode.Classic && isRoot) ClassicNavigation(screen, vm::selectTab)
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            if (screen != Screen.Settings) ConnectionBanner(ctx.snapshot, ctx.now, ctx.stale, onOpenSettings = { vm.open(Screen.Settings) })
            ScreenContent(ctx, screen)
        }
    }
}

@Composable
private fun ClassicNavigation(current: Screen, onSelect: (Screen) -> Unit) {
    NavigationBar(containerColor = AerColors.surface) {
        classicTabs.forEach { tab ->
            val (label, icon) = when (tab) {
                Screen.Overview -> "Обзор" to Icons.Outlined.Dashboard
                Screen.Devices -> "Устройства" to Icons.Outlined.Devices
                Screen.Journal -> "Журнал" to Icons.Outlined.NotificationsNone
                Screen.Network -> "Сеть" to Icons.Outlined.Wifi
                else -> "Ещё" to Icons.Outlined.MoreHoriz
            }
            NavigationBarItem(
                selected = current == tab,
                onClick = { onSelect(tab) },
                icon = { Icon(icon, null) },
                label = { Text(label, maxLines = 1) },
                modifier = Modifier.testTag("tab_$label"),
            )
        }
    }
}

@Composable
fun ScreenContent(ctx: UiContext, screen: Screen) {
    when (screen) {
        Screen.Overview -> OverviewScreen(ctx)
        Screen.Devices -> DevicesScreen(ctx)
        Screen.Journal -> JournalScreen(ctx)
        Screen.Network -> NetworkScreen(ctx)
        Screen.More -> MoreScreen(ctx)
        Screen.Power -> PowerScreen(ctx)
        Screen.Bots -> BotsScreen(ctx)
        Screen.Settings -> SettingsScreen(ctx)
        Screen.House -> Unit
        is Screen.Device -> DeviceScreen(ctx, screen.id)
        is Screen.Incident -> IncidentScreen(ctx, screen.id)
        is Screen.Bot -> BotDetailScreen(ctx, screen.id)
    }
}

private fun titleOf(s: Screen, snap: HomeSnapshot): String = when (s) {
    Screen.Overview -> "AER HOME"
    Screen.Devices -> "Устройства"
    Screen.Journal -> "Журнал и инциденты"
    Screen.Network -> "Сеть и ТВ"
    Screen.More -> "Ещё"
    Screen.Power -> "Питание"
    Screen.Bots -> "Боты"
    Screen.Settings -> "Подключение к Core"
    Screen.House -> "Дом"
    is Screen.Device -> snap.entity(s.id)?.name ?: "Устройство"
    is Screen.Incident -> "Инцидент"
    is Screen.Bot -> snap.bots?.firstOrNull { it.entityId == s.id }?.name ?: "Бот"
}

/** First launch: «Дом» or «Классика». Either can be switched later without losing anything. */
@Composable
fun ModeChoiceScreen(onChoose: (UiMode) -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Spacer(Modifier.height(12.dp))
        Text("AER HOME", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, color = AerColors.ink)
        Text("Как вам удобнее смотреть на дом?", style = MaterialTheme.typography.titleMedium, color = AerColors.inkMuted)
        ModeCard(
            title = "Дом",
            text = "Уютный изометрический дом: комнаты, предметы и привязанные к ним устройства. Нажмите на предмет — увидите его состояние.",
            icon = Icons.Outlined.Cottage,
            tag = "mode_house",
        ) { onChoose(UiMode.House) }
        ModeCard(
            title = "Классика",
            text = "Привычные разделы: обзор, устройства, журнал и инциденты, сеть, питание и боты — списками и карточками.",
            icon = Icons.Outlined.Dashboard,
            tag = "mode_classic",
        ) { onChoose(UiMode.Classic) }
        Text(
            "Режим можно сменить в любой момент кнопкой в верхней панели — данные и настройки сохранятся.",
            style = MaterialTheme.typography.bodySmall,
            color = AerColors.inkMuted,
        )
    }
}

@Composable
private fun ModeCard(title: String, text: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tag: String, onClick: () -> Unit) {
    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().testTag(tag),
        colors = CardDefaults.cardColors(containerColor = AerColors.surface),
        border = androidx.compose.foundation.BorderStroke(1.dp, AerColors.border),
        shape = MaterialTheme.shapes.large,
    ) {
        Row(Modifier.padding(PaddingValues(18.dp)), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = AerColors.accent, modifier = Modifier.size(40.dp))
            Spacer(Modifier.width(16.dp))
            Column {
                Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(4.dp))
                Text(text, style = MaterialTheme.typography.bodyMedium, color = AerColors.inkMuted)
            }
        }
    }
}
