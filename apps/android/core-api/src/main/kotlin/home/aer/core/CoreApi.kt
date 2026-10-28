package home.aer.core

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/** A stored scene: metadata plus the raw document, parsed by the :scene module. */
data class SceneRecord(val id: String, val name: String, val revision: Int, val document: JsonElement)

/**
 * The Core operations the mobile client uses. Read-mostly; the only writes are
 * the ones Core already exposes to the desktop client with its own safety
 * rules: acknowledge an incident, run network checks, and power/bot actions
 * through Core's confirm → execute protocol.
 */
class CoreApi(val client: CoreClient) {
    suspend fun health(): Health = client.decode(Health.serializer(), client.request("GET", "/health", authenticated = false))
    suspend fun systemInfo(): SystemInfo = client.decode(SystemInfo.serializer(), client.get("/system/info"))

    // Registry
    suspend fun entityTypes(): List<EntityType> = client.decode(ListSerializer(EntityType.serializer()), client.get("/registry/types"))
    /** All non-archived entities; pages through Core's limit of 200. */
    suspend fun entities(): List<Entity> {
        val out = mutableListOf<Entity>()
        while (true) {
            val page = client.decode(EntityPage.serializer(), client.get("/registry/entities", mapOf("limit" to 200, "offset" to out.size)))
            out += page.items
            if (page.items.isEmpty() || out.size >= page.total) return out
        }
    }
    suspend fun entity(id: String): Entity = client.decode(Entity.serializer(), client.get("/registry/entities/$id"))

    // Monitoring
    suspend fun monitoringOverview(): MonitoringOverview = client.decode(MonitoringOverview.serializer(), client.get("/monitoring/overview"))
    suspend fun states(): List<EntityState> = client.decode(ListSerializer(EntityState.serializer()), client.get("/monitoring/states"))
    suspend fun state(entityId: String): EntityState = client.decode(EntityState.serializer(), client.get("/monitoring/states/$entityId"))
    suspend fun logs(entityId: String? = null, source: String? = null, level: String? = null, before: Long? = null, limit: Int = 50): LogPage =
        client.decode(
            LogPage.serializer(),
            client.get("/monitoring/logs", mapOf("entityId" to entityId, "source" to source, "level" to level, "before" to before, "limit" to limit)),
        )
    suspend fun incidents(status: String = "active", entityId: String? = null, limit: Int = 100): IncidentPage =
        client.decode(IncidentPage.serializer(), client.get("/monitoring/incidents", mapOf("status" to status, "entityId" to entityId, "limit" to limit)))
    suspend fun incident(id: String): Incident = client.decode(Incident.serializer(), client.get("/monitoring/incidents/$id"))
    suspend fun acknowledge(id: String): Incident =
        client.decode(Incident.serializer(), client.post("/monitoring/incidents/$id/acknowledge", buildJsonObject { put("note", "Подтверждено с телефона") }))

    // Network + TV
    suspend fun networkOverview(): NetworkOverview = client.decode(NetworkOverview.serializer(), client.get("/network/overview"))
    suspend fun networkCheckNow(): NetworkOverview = client.decode(NetworkOverview.serializer(), client.post("/network/check"))

    // Power
    suspend fun powerDevices(): List<PowerDevice> = client.decode(ListSerializer(PowerDevice.serializer()), client.get("/power/devices"))
    suspend fun powerJob(id: String): PowerJob = client.decode(PowerJob.serializer(), client.get("/power/jobs/$id"))
    suspend fun confirmPower(entityId: String, action: String, targetOs: String? = null): PowerConfirmation =
        client.decode(
            PowerConfirmation.serializer(),
            client.post("/power/devices/$entityId/actions/$action/confirm", buildJsonObject { if (targetOs != null) put("targetOs", targetOs) }),
        )
    suspend fun runPower(entityId: String, action: String, confirmationToken: String?, idempotencyKey: String, targetOs: String? = null): PowerJob =
        client.decode(
            PowerJob.serializer(),
            client.post(
                "/power/devices/$entityId/actions/$action",
                body = tokenBody(confirmationToken, targetOs),
                headers = mapOf("Idempotency-Key" to idempotencyKey),
            ),
        )

    // Bots
    suspend fun bots(): List<Bot> = client.decode(ListSerializer(Bot.serializer()), client.get("/bots"))
    suspend fun botActions(entityId: String): List<BotAction> =
        client.decode(ListSerializer(BotAction.serializer()), client.get("/bots/$entityId/actions"))
    suspend fun confirmBot(entityId: String, action: String): BotConfirmation =
        client.decode(BotConfirmation.serializer(), client.post("/bots/$entityId/actions/$action/confirm"))
    suspend fun runBot(entityId: String, action: String, confirmationToken: String?, idempotencyKey: String): BotActionRecord =
        client.decode(
            BotActionRecord.serializer(),
            client.post("/bots/$entityId/actions/$action", body = tokenBody(confirmationToken), headers = mapOf("Idempotency-Key" to idempotencyKey)),
        )

    // Scenes
    suspend fun scenes(): List<SceneSummary> = client.decode(ListSerializer(SceneSummary.serializer()), client.get("/scenes"))
    suspend fun scene(id: String): SceneRecord {
        val data = client.get("/scenes/$id") as? JsonObject ?: throw CoreException.InvalidResponse(200, "scene is not an object")
        val document = data["document"] ?: throw CoreException.InvalidResponse(200, "scene has no document")
        return SceneRecord(
            id = (data["id"] as? JsonPrimitive)?.content ?: id,
            name = (data["name"] as? JsonPrimitive)?.content ?: "",
            revision = (data["revision"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0,
            document = document,
        )
    }

    private fun tokenBody(token: String?, targetOs: String? = null): JsonObject = buildJsonObject {
        if (token != null) put("confirmationToken", token)
        if (targetOs != null) put("targetOs", targetOs)
    }

    companion object {
        /** One key per user intent (Core replays the first result for a repeated key). */
        fun newIdempotencyKey(): String = "mobile-" + UUID.randomUUID().toString()
    }
}
