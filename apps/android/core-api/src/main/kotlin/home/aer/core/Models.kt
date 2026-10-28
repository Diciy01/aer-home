package home.aer.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

// DTOs for the parts of contracts/openapi.yaml (0.10.0) the mobile client reads.
// Fields the client does not use are omitted; unknown fields are ignored, so a
// newer Core stays readable. Timestamps stay RFC 3339 strings (see Time.kt).

@Serializable
data class Health(val status: String = "", val timestamp: String = "", val apiVersion: String = "")

@Serializable
data class ModuleInfo(val name: String, val enabled: Boolean = false)

@Serializable
data class SystemInfo(
    val coreVersion: String = "",
    val apiVersion: String = "",
    val mode: String = "",
    val demo: Boolean = false,
    val uptimeSeconds: Long = 0,
    val modules: List<ModuleInfo> = emptyList(),
) {
    fun moduleEnabled(name: String) = modules.any { it.name == name && it.enabled }
}

// --- Registry ---

@Serializable
data class EntityType(
    val id: String,
    val label: String = "",
    val description: String = "",
    val group: String = "",
    val icon: String = "",
)

@Serializable
data class Entity(
    val id: String,
    val name: String,
    val type: String,
    val description: String = "",
    val icon: String = "",
    val tags: List<String> = emptyList(),
    val parentId: String? = null,
    val address: String = "",
    val capabilities: List<String> = emptyList(),
    val archived: Boolean = false,
    val createdAt: String = "",
    val updatedAt: String = "",
)

@Serializable
data class EntityPage(val items: List<Entity> = emptyList(), val total: Int = 0)

// --- Monitoring ---

@Serializable
data class Integration(
    val id: String,
    val label: String = "",
    val status: String = "",
    val reason: String = "",
    val checkedAt: String? = null,
)

@Serializable
data class MonitoringEvent(
    val id: Long,
    val at: String = "",
    val entityId: String? = null,
    val kind: String = "",
    val severity: String = "",
    val message: String = "",
    val incidentId: String? = null,
)

@Serializable
data class MonitoringOverview(
    val generatedAt: String = "",
    val devices: Int = 0,
    val byStatus: Map<String, Int> = emptyMap(),
    val openIncidents: Int = 0,
    val criticalOpen: Int = 0,
    val unreadNotifications: Int = 0,
    val integrations: List<Integration> = emptyList(),
    val recentEvents: List<MonitoringEvent> = emptyList(),
)

@Serializable
data class Metric(
    val metric: String,
    val label: String = "",
    val value: Double? = null,
    val unit: String = "",
    val at: String? = null,
    val quality: String = "",
)

@Serializable
data class EntityState(
    val entityId: String,
    val name: String = "",
    val type: String = "",
    val status: String = "unknown",
    val reason: String = "",
    val checkKind: String = "",
    val lastContactAt: String? = null,
    val lastCheckAt: String? = null,
    val changedAt: String? = null,
    val keyMetrics: List<Metric> = emptyList(),
    val openIncidents: Int = 0,
    val worstSeverity: String? = null,
) {
    val latencyMs: Double? get() = keyMetrics.firstOrNull { it.metric == "net.latency" }?.value
}

@Serializable
data class LogEntry(
    val id: Long,
    val at: String = "",
    val entityId: String? = null,
    val source: String = "",
    val level: String = "info",
    val message: String = "",
    val incidentId: String? = null,
)

@Serializable
data class LogPage(val items: List<LogEntry> = emptyList(), val nextBefore: Long? = null)

@Serializable
data class IncidentEvent(val at: String = "", val kind: String = "", val message: String = "")

@Serializable
data class Incident(
    val id: String,
    val key: String = "",
    val title: String = "",
    val source: String = "",
    val entityId: String? = null,
    val severity: String = "info",
    val status: String = "open",
    val openedAt: String = "",
    val updatedAt: String = "",
    val acknowledgedAt: String? = null,
    val resolvedAt: String? = null,
    val cause: String = "",
    val occurrences: Int = 0,
    val lastMessage: String = "",
    val timeline: List<IncidentEvent> = emptyList(),
) {
    val active get() = status != "resolved"
}

@Serializable
data class IncidentPage(val items: List<Incident> = emptyList(), val total: Int = 0)

// --- Network + TV (M09, ADR-015) ---

@Serializable
data class NetworkSummary(val level: String = "unconfigured", val title: String = "", val issues: List<String> = emptyList())

@Serializable
data class NetworkCheck(
    val key: String = "",
    val kind: String = "",
    val name: String = "",
    val entityId: String = "",
    val status: String = "unknown",
    val reason: String = "",
    val latencyMs: Double? = null,
    val lastCheckAt: String? = null,
    val lastOkAt: String? = null,
    val changedAt: String? = null,
    val failures: Int = 0,
    val stale: Boolean = false,
    val details: JsonObject? = null,
)

@Serializable
data class NetworkDevice(
    val entityId: String,
    val name: String = "",
    val type: String = "",
    val address: String = "",
    val status: String = "unknown",
    val reason: String = "",
    val monitoringStatus: String = "unknown",
    val latencyMs: Double? = null,
    val latencyAt: String? = null,
    val lastContactAt: String? = null,
    val lastCheckAt: String? = null,
    val changedAt: String? = null,
    val stale: Boolean = false,
    val openIncidents: Int = 0,
)

@Serializable
data class NetworkRouter(
    val device: NetworkDevice,
    val adapter: String = "none",
    val adapterNote: String = "",
    val wan: NetworkCheck? = null,
)

@Serializable
data class NetworkSunshine(
    val id: String,
    val name: String = "",
    val webUrl: String = "",
    val check: NetworkCheck = NetworkCheck(),
    val entity: NetworkDevice? = null,
    val tv: NetworkDevice? = null,
)

@Serializable
data class NetworkOverview(
    val summary: NetworkSummary = NetworkSummary(),
    val internet: NetworkCheck? = null,
    val routers: List<NetworkRouter> = emptyList(),
    val devices: List<NetworkDevice> = emptyList(),
    val tvs: List<NetworkDevice> = emptyList(),
    val sunshine: List<NetworkSunshine> = emptyList(),
    val incidents: List<Incident> = emptyList(),
    val recent: List<LogEntry> = emptyList(),
    val intervalSec: Int = 0,
    val generatedAt: String = "",
)

// --- Power (M08, ADR-014) ---

@Serializable
data class PowerAction(
    val id: String,
    val label: String = "",
    val available: Boolean = false,
    val reason: String = "",
    val dangerous: Boolean = false,
)

@Serializable
data class PowerJob(
    val id: String,
    val entityId: String = "",
    val deviceName: String = "",
    val action: String = "",
    val targetOs: String = "",
    val state: String = "",
    val message: String = "",
    val replayed: Boolean = false,
    val simulated: Boolean = false,
    val requestedAt: String = "",
    val finishedAt: String? = null,
    val deadline: String = "",
)

@Serializable
data class PowerDevice(
    val entityId: String,
    val name: String = "",
    val type: String = "",
    val state: String = "unknown",
    val stateReason: String = "",
    val currentOs: String = "",
    val lastContactAt: String? = null,
    val monitoringStatus: String = "unknown",
    val sameMachineAsCore: Boolean = false,
    val sameMachineNote: String = "",
    val actions: List<PowerAction> = emptyList(),
    val activeJob: PowerJob? = null,
    val lastJob: PowerJob? = null,
)

@Serializable
data class PowerCheck(val name: String = "", val ok: Boolean = false, val message: String = "")

/** Contains a single-use [token]: never log or persist it. */
@Serializable
data class PowerConfirmation(
    val token: String,
    val entityId: String = "",
    val action: String = "",
    val targetOs: String = "",
    val summary: String = "",
    val risks: List<String> = emptyList(),
    val checks: List<PowerCheck> = emptyList(),
    val expiresAt: String = "",
) {
    override fun toString() = "PowerConfirmation(action=$action, entityId=$entityId)"
}

// --- Bots (M06, ADR-012) ---

@Serializable
data class Bot(
    val entityId: String,
    val name: String = "",
    val type: String = "",
    val description: String = "",
    val runtime: String = "",
    val category: String = "",
    val controllerId: String = "",
    val archived: Boolean = false,
    val status: String = "unknown",
    val statusReason: String = "",
    val lastContactAt: String? = null,
    val openIncidents: Int = 0,
    val version: String = "",
    val uptimeSec: Long? = null,
    val lastError: String = "",
    val lastErrorAt: String? = null,
    val lastSuccessAt: String? = null,
    val cpuPercent: Double? = null,
    val memBytes: Double? = null,
)

@Serializable
data class BotAction(
    val id: String,
    val label: String = "",
    val available: Boolean = false,
    val reason: String = "",
    val confirm: Boolean = true,
    val risk: String = "",
)

/** Contains a single-use [token]: never log or persist it. */
@Serializable
data class BotConfirmation(
    val token: String,
    val entityId: String = "",
    val action: String = "",
    val summary: String = "",
    val risks: List<String> = emptyList(),
    val expiresAt: String = "",
) {
    override fun toString() = "BotConfirmation(action=$action, entityId=$entityId)"
}

@Serializable
data class BotActionRecord(
    val id: String,
    val entityId: String = "",
    val action: String = "",
    val status: String = "",
    val message: String = "",
    val replayed: Boolean = false,
    val requestedAt: String = "",
    val finishedAt: String? = null,
)

// --- Scenes (format: :scene module) ---

@Serializable
data class SceneSummary(
    val id: String,
    val name: String = "",
    val schemaVersion: Int = 1,
    val demo: Boolean = false,
    val revision: Int = 1,
    val updatedAt: String = "",
)
