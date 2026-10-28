package home.aer.android.ui.house

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CenterFocusStrong
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ViewAgenda
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import home.aer.android.data.SceneOrigin
import home.aer.android.ui.Screen
import home.aer.android.ui.UiContext
import home.aer.android.ui.components.ConnectionBanner
import home.aer.android.ui.components.EmptyNote
import home.aer.android.ui.components.ItemRow
import home.aer.android.ui.components.StatusBadge
import home.aer.android.ui.theme.AerColors
import home.aer.core.HomeSnapshot
import home.aer.core.Link
import home.aer.core.StatusText
import home.aer.core.Tone
import home.aer.core.ago
import home.aer.core.parseInstant
import home.aer.scene.EntityFacts
import home.aer.scene.LiveStatus
import home.aer.scene.ObjectPresentation
import home.aer.scene.RegistryLink
import home.aer.scene.SceneCamera
import home.aer.scene.SceneCatalog
import home.aer.scene.SceneDocument
import home.aer.scene.SceneLayout
import home.aer.scene.SceneStatus
import home.aer.scene.Vec2
import home.aer.scene.presentObject

private fun sceneTone(s: SceneStatus) = when (s) {
    SceneStatus.Online -> Tone.Ok
    SceneStatus.Warning -> Tone.Warning
    SceneStatus.Critical -> Tone.Critical
    SceneStatus.Loading -> Tone.Info
    else -> Tone.Muted
}

/** Registry + Monitoring → per-object presentation (the binding rules live in :scene). */
fun presentations(doc: SceneDocument, s: HomeSnapshot, stale: Boolean): Map<String, ObjectPresentation> {
    val link = when {
        s.entities == null && (s.link == Link.Connecting || s.link == Link.NotConfigured && !s.hasData) -> RegistryLink.Loading
        s.entities == null -> RegistryLink.Unavailable
        s.link == Link.Online -> RegistryLink.Live
        else -> RegistryLink.Stale
    }
    val facts = s.entities.orEmpty().associate { it.id to EntityFacts(it.name, s.typeLabel(it.type), it.archived) }
    return doc.objects.associate { o ->
        val live = o.entityBinding?.let { b ->
            s.states[b.entityId]?.let { st ->
                LiveStatus(SceneStatus.fromMonitoring(st.status, st.worstSeverity), st.reason.ifEmpty { "Состояние из мониторинга" }, stale, st.openIncidents)
            }
        }
        o.id to presentObject(o, doc.asset(o.assetId), facts, link, live)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HouseScreen(ctx: UiContext, modifier: Modifier = Modifier, canGoBack: Boolean) {
    val vm = ctx.vm
    val loaded by vm.scene.collectAsStateWithLifecycle()
    val focus by vm.houseFocus.collectAsStateWithLifecycle()
    val online = ctx.snapshot.link == Link.Online
    // Load once, and again when Core comes back while a cached/demo scene is shown.
    LaunchedEffect(online) {
        if (loaded == null || (online && loaded?.origin != SceneOrigin.Core)) vm.loadScene()
    }
    val scene = loaded
    Column(modifier.fillMaxSize().background(AerColors.background)) {
        HouseTopBar(ctx, canGoBack)
        ConnectionBanner(ctx.snapshot, ctx.now, ctx.stale, onOpenSettings = { vm.open(Screen.Settings) })
        if (scene == null) {
            EmptyNote("Загружаем сцену…", Modifier.padding(16.dp))
            return@Column
        }
        val layout = remember(scene.document) { SceneLayout.build(scene.document) }
        val pres = presentations(scene.document, ctx.snapshot, ctx.stale)
        var selectedObject by rememberSaveable(scene.document.sceneId) { mutableStateOf<String?>(null) }
        var selectedRoom by rememberSaveable(scene.document.sceneId) { mutableStateOf<String?>(null) }
        var viewSize by remember { mutableStateOf(IntSize.Zero) }
        var cam by remember(layout) { mutableStateOf<SceneCamera?>(null) }

        fun focusRoom(roomId: String?) {
            val w = viewSize.width.toDouble()
            val h = viewSize.height.toDouble()
            if (w <= 0) return
            cam = if (roomId == null) {
                SceneCamera.fit(layout.bounds, w, h)
            } else {
                layout.roomGeometry(roomId)?.let { SceneCamera.fit(it.focusBounds, w, h) } ?: cam
            }
        }

        LaunchedEffect(focus, layout, viewSize) {
            val id = focus ?: return@LaunchedEffect
            if (viewSize.width == 0) return@LaunchedEffect
            val g = layout.objects.values.firstOrNull { it.obj.entityBinding?.entityId == id }
            if (g != null) {
                selectedObject = g.obj.id
                selectedRoom = g.room.id
                focusRoom(g.room.id)
            } else {
                selectedObject = null
            }
            vm.houseFocusConsumed()
        }

        // Scene origin: Core, last cached copy, or the demo layout — always said explicitly.
        Text(
            scene.note,
            style = MaterialTheme.typography.labelMedium,
            color = if (scene.origin == SceneOrigin.Core) AerColors.inkMuted else AerColors.amber,
            modifier = Modifier.padding(horizontal = 16.dp).testTag("scene_origin"),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        RoomChips(layout, selectedRoom) { id ->
            selectedRoom = id
            selectedObject = null
            focusRoom(id)
        }
        val textMeasurer = rememberTextMeasurer()
        val renderer = remember(layout, pres, textMeasurer) { HouseRenderer(layout, pres, textMeasurer) }
        val boundCount = layout.objects.values.count { it.obj.entityBinding != null }
        Box(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .onSizeChanged {
                    viewSize = it
                    if (cam == null && it.width > 0) cam = SceneCamera.fit(layout.bounds, it.width.toDouble(), it.height.toDouble())
                },
        ) {
            Canvas(
                Modifier
                    .fillMaxSize()
                    .testTag("house_canvas")
                    .semantics {
                        contentDescription = "Изометрический дом «${scene.document.name}»: комнат ${layout.rooms.size}, привязанных предметов $boundCount"
                    }
                    .pointerInput(layout) {
                        detectTransformGestures { centroid, pan, zoom, _ ->
                            val c = cam ?: return@detectTransformGestures
                            cam = c.transformed(
                                layout.bounds,
                                size.width.toDouble(),
                                size.height.toDouble(),
                                Vec2(pan.x.toDouble(), pan.y.toDouble()),
                                zoom.toDouble(),
                                Vec2(centroid.x.toDouble(), centroid.y.toDouble()),
                            )
                        }
                    }
                    .pointerInput(layout) {
                        detectTapGestures { at ->
                            val c = cam ?: return@detectTapGestures
                            val world = c.worldAt(at.x, at.y, size.width.toFloat(), size.height.toFloat())
                            val hit = layout.hitTest(world)
                            if (hit != null) {
                                selectedObject = hit.obj.id
                                selectedRoom = hit.room.id
                            } else {
                                val room = layout.roomAt(world)
                                selectedObject = null
                                selectedRoom = room?.room?.id
                                if (room != null) focusRoom(room.room.id)
                            }
                        }
                    },
            ) {
                val c = cam ?: return@Canvas
                with(renderer) { draw(c, selectedObject, selectedRoom) }
            }
            IconButton(
                onClick = { selectedRoom = null; selectedObject = null; focusRoom(null) },
                modifier = Modifier.align(Alignment.TopEnd).padding(4.dp),
            ) { Icon(Icons.Filled.CenterFocusStrong, "Показать весь дом", tint = AerColors.inkMuted) }
        }
        DetailsPanel(ctx, layout, pres, selectedObject, selectedRoom) { selectedObject = it }
        HouseNavigation(ctx)
    }
}

@Composable
private fun HouseTopBar(ctx: UiContext, canGoBack: Boolean) {
    val vm = ctx.vm
    val s = ctx.snapshot
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (canGoBack) IconButton(onClick = { vm.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Назад") }
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text("Дом", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            val problems = s.states.values.count { it.status == "offline" || it.status == "degraded" }
            Text(
                when {
                    !s.hasData -> "Нет данных Core"
                    problems > 0 -> "Проблем: $problems · обновлено ${ago(s.lastSuccessAt, ctx.now)}"
                    else -> "Всё спокойно · обновлено ${ago(s.lastSuccessAt, ctx.now)}"
                },
                style = MaterialTheme.typography.bodySmall,
                color = if (problems > 0) AerColors.terracotta else AerColors.inkMuted,
            )
        }
        IconButton(onClick = { vm.refreshNow(); vm.loadScene() }) { Icon(Icons.Filled.Refresh, "Обновить") }
        IconButton(onClick = { vm.toggleMode() }, modifier = Modifier.testTag("toggle_mode")) { Icon(Icons.Filled.ViewAgenda, "Переключить на «Классика»") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RoomChips(layout: SceneLayout, selected: String?, onSelect: (String?) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FilterChip(selected = selected == null, onClick = { onSelect(null) }, label = { Text("Весь дом") }, modifier = Modifier.testTag("room_all"))
        layout.rooms.forEach { r ->
            FilterChip(
                selected = selected == r.room.id,
                onClick = { onSelect(r.room.id) },
                label = { Text(r.room.name.ifEmpty { SceneCatalog.roomKinds[r.room.kind] ?: r.room.kind }) },
                modifier = Modifier.testTag("room_${r.room.name}"),
            )
        }
    }
}

/** Below the picture: the selected object, the objects of the selected room, or a hint. */
@Composable
private fun DetailsPanel(
    ctx: UiContext,
    layout: SceneLayout,
    pres: Map<String, ObjectPresentation>,
    selectedObject: String?,
    selectedRoom: String?,
    onSelect: (String?) -> Unit,
) {
    Surface(
        color = AerColors.surface,
        shape = MaterialTheme.shapes.large,
        border = androidx.compose.foundation.BorderStroke(1.dp, AerColors.border),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp).heightIn(max = 260.dp),
    ) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val g = selectedObject?.let { layout.objects[it] }
            val p = selectedObject?.let { pres[it] }
            when {
                g != null && p != null -> {
                    Text(p.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("house_selected_title"))
                    Text("${p.subtitle} · ${g.room.name}", style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted)
                    p.status?.let { StatusBadge(StatusText(it.label + if (p.isDemo) " (тест)" else "", sceneTone(it)), stale = p.stale) }
                    Text(p.note, style = MaterialTheme.typography.bodyMedium)
                    p.live?.takeIf { it.openIncidents > 0 }?.let { Text("Открытых инцидентов: ${it.openIncidents}", color = AerColors.terracotta) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        val eid = p.entityId
                        if (eid != null && ctx.snapshot.entity(eid) != null) {
                            Button(onClick = { ctx.vm.open(Screen.Device(eid)) }, modifier = Modifier.testTag("house_open_device")) { Text("Подробнее") }
                        }
                        TextButton(onClick = { onSelect(null) }) { Text("Закрыть") }
                    }
                }
                selectedRoom != null -> {
                    val room = layout.roomGeometry(selectedRoom)?.room
                    Text(room?.name ?: "Комната", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    val objs = layout.objectsIn(selectedRoom)
                    if (objs.isEmpty()) EmptyNote("В комнате нет предметов")
                    objs.forEach { o ->
                        val op = pres[o.obj.id]
                        ItemRow(
                            title = op?.title ?: o.obj.label,
                            subtitle = op?.subtitle,
                            icon = null,
                            badge = op?.status?.let { st -> { StatusBadge(StatusText(st.label, sceneTone(st)), stale = op.stale) } },
                            onClick = { onSelect(o.obj.id) },
                            modifier = Modifier.testTag("house_object_${o.obj.label}"),
                        )
                    }
                }
                else -> {
                    Text("Нажмите на комнату или предмет", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "Значки над предметами — состояние привязанных устройств из Monitoring. Двумя пальцами — масштаб, одним — сдвиг.",
                        style = MaterialTheme.typography.bodySmall,
                        color = AerColors.inkMuted,
                    )
                    val bound = pres.values.filter { it.isBound }
                    if (bound.isNotEmpty()) {
                        val newest = ctx.snapshot.states.values.mapNotNull { parseInstant(it.lastCheckAt) }.maxOrNull()
                        Text(
                            "Привязано устройств: ${bound.size}; в сети: ${bound.count { it.status == SceneStatus.Online }}" +
                                (newest?.let { " · проверка ${ago(it, ctx.now)}" } ?: ""),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun HouseNavigation(ctx: UiContext) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        listOf(
            Triple("Обзор", Icons.Outlined.Dashboard, Screen.Overview),
            Triple("Журнал", Icons.Outlined.NotificationsNone, Screen.Journal),
            Triple("Сеть", Icons.Outlined.Wifi, Screen.Network),
            Triple("Ещё", Icons.Outlined.MoreHoriz, Screen.More),
        ).forEach { (label, icon, screen) ->
            Column(
                Modifier
                    .weight(1f)
                    .clip(MaterialTheme.shapes.medium)
                    .clickable { ctx.vm.open(screen) }
                    .padding(vertical = 6.dp)
                    .testTag("house_nav_$label"),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(icon, null, tint = AerColors.accent)
                Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 1)
            }
        }
    }
}
