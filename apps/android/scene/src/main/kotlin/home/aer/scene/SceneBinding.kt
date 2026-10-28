package home.aer.scene

// Port of apps/desktop/lib/src/scene/binding/scene_binding.dart (viewer part):
// a scene object + Registry facts + Monitoring state → what the house shows.
// A healthy state is never invented: without Monitoring data it is `unknown`.

enum class SceneStatus(val wire: String, val label: String) {
    Online("online", "В сети"),
    Offline("offline", "Не в сети"),
    Warning("warning", "Предупреждение"),
    Critical("critical", "Критично"),
    Unknown("unknown", "Неизвестно"),
    Loading("loading", "Загрузка"),
    Archived("archived", "В архиве"),
    ;

    companion object {
        fun fromWire(s: String) = entries.firstOrNull { it.wire == s }

        /** Monitoring status (+ worst open incident severity) → scene status. */
        fun fromMonitoring(status: String, worstSeverity: String?): SceneStatus = when (status) {
            "online" -> Online
            "degraded" -> if (worstSeverity == "critical") Critical else Warning
            "offline" -> Offline
            else -> Unknown
        }
    }
}

/** Registry facts about a bound entity. */
data class EntityFacts(val name: String, val typeLabel: String, val archived: Boolean)

/** Monitoring state of a bound entity, as the scene needs it. */
data class LiveStatus(val status: SceneStatus, val note: String, val stale: Boolean, val openIncidents: Int = 0)

enum class RegistryLink { Loading, Live, Stale, Unavailable }

enum class BindingState { Unbound, Resolved, Missing, Archived, Pending, Unavailable }

data class ObjectPresentation(
    val title: String,
    val subtitle: String,
    val binding: BindingState,
    /** Null for decor: no badge at all. */
    val status: SceneStatus?,
    val isDemo: Boolean = false,
    val stale: Boolean = false,
    val note: String,
    val entityId: String? = null,
    val live: LiveStatus? = null,
) {
    val isBound get() = binding != BindingState.Unbound
}

/**
 * [facts] maps entity id → Registry facts for every entity Core returned; an
 * id missing from it while [link] is live means the binding is dangling.
 */
fun presentObject(
    o: SceneObject,
    asset: SceneAsset?,
    facts: Map<String, EntityFacts>,
    link: RegistryLink,
    live: LiveStatus?,
): ObjectPresentation {
    val assetLabel = asset?.label ?: o.assetId
    val fallbackTitle = o.label.ifEmpty { assetLabel }
    val b = o.entityBinding
    if (b == null) {
        val demo = o.demoState
        return ObjectPresentation(
            title = fallbackTitle,
            subtitle = if (fallbackTitle == assetLabel) "Объект сцены" else assetLabel,
            binding = BindingState.Unbound,
            status = demo,
            isDemo = demo != null,
            note = if (demo != null) "Тестовое состояние демо-сцены — не данные устройства" else "Декор: не привязан к Registry",
        )
    }
    val f = facts[b.entityId]
    val stale = link != RegistryLink.Live
    if (f == null) {
        return when (link) {
            RegistryLink.Loading -> ObjectPresentation(
                fallbackTitle, assetLabel, BindingState.Pending, SceneStatus.Loading,
                note = "Загружаем сведения из Registry…", entityId = b.entityId,
            )
            RegistryLink.Live -> ObjectPresentation(
                fallbackTitle, assetLabel, BindingState.Missing, SceneStatus.Unknown,
                note = "Объект Registry не найден (привязка указывает на удалённый UUID)", entityId = b.entityId,
            )
            else -> ObjectPresentation(
                fallbackTitle, assetLabel, BindingState.Unavailable, SceneStatus.Unknown, stale = true,
                note = "Registry недоступен, сведений об объекте нет", entityId = b.entityId,
            )
        }
    }
    if (f.archived) {
        return ObjectPresentation(
            f.name, f.typeLabel, BindingState.Archived, SceneStatus.Archived, stale = stale,
            note = "Объект в архиве Registry", entityId = b.entityId,
        )
    }
    return ObjectPresentation(
        title = f.name,
        subtitle = f.typeLabel,
        binding = BindingState.Resolved,
        status = live?.status ?: SceneStatus.Unknown,
        stale = stale || (live?.stale ?: false),
        note = live?.note ?: "Нет данных мониторинга для этого объекта",
        entityId = b.entityId,
        live = live,
    )
}
