package home.aer.scene

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

// Scene format v1 (contracts/scene.schema.json, docs/SCENE_FORMAT.md) — the
// same documents Core stores and the desktop client renders. This module only
// reads them; Core remains the validator and the source of truth.

@Serializable
data class Point2(val x: Double = 0.0, val y: Double = 0.0)

@Serializable
data class Point3(val x: Double = 0.0, val y: Double = 0.0, val z: Double = 0.0)

@Serializable
data class RoomSize(val w: Double, val d: Double)

@Serializable
data class RoomStyle(val floor: String = "", val wall: String = "", val light: String? = null)

@Serializable
data class SceneRoom(
    val id: String,
    val name: String = "",
    val kind: String = "custom",
    val origin: Point2 = Point2(),
    val size: RoomSize,
    val wallHeight: Double = 5.0,
    val style: RoomStyle = RoomStyle(),
)

@Serializable
data class Footprint(val w: Double, val d: Double)

@Serializable
data class SceneAsset(
    val id: String,
    val label: String = "",
    val footprint: Footprint,
    val height: Double,
)

@Serializable
data class EntityBinding(val entityId: String, val role: String = "primary")

@Serializable
data class VisualState(val demo: String)

@Serializable
enum class SceneLayer {
    @SerialName("floor") Floor,
    @SerialName("object") Object,
    @SerialName("wall") Wall,
}

@Serializable
data class SceneObject(
    val id: String,
    val roomId: String,
    val assetId: String,
    val label: String = "",
    val position: Point3 = Point3(),
    val rotation: Int = 0,
    val scale: Double = 1.0,
    val layer: SceneLayer = SceneLayer.Object,
    val entityBinding: EntityBinding? = null,
    val visualState: VisualState? = null,
    val metadata: Map<String, String> = emptyMap(),
) {
    /** Footprint after scale and rotation (90/270 swap width and depth). */
    fun footprint(asset: SceneAsset): Footprint {
        val w = asset.footprint.w * scale
        val d = asset.footprint.d * scale
        return if (rotation == 90 || rotation == 270) Footprint(d, w) else Footprint(w, d)
    }

    /** Explicit test state from a demo scene, null otherwise. */
    val demoState: SceneStatus? get() = visualState?.demo?.let { SceneStatus.fromWire(it) }
}

@Serializable
data class SceneDocument(
    val schemaVersion: Int,
    val sceneId: String,
    val name: String = "",
    val demo: Boolean = false,
    val projection: String = "isometric-2:1",
    val assets: List<SceneAsset> = emptyList(),
    val rooms: List<SceneRoom> = emptyList(),
    val objects: List<SceneObject> = emptyList(),
    val metadata: Map<String, String> = emptyMap(),
) {
    private val assetsById by lazy { assets.associateBy { it.id } }
    private val roomsById by lazy { rooms.associateBy { it.id } }

    fun asset(id: String): SceneAsset? = assetsById[id]
    fun room(id: String): SceneRoom? = roomsById[id]

    /** Entity ids bound in this scene (for fetching their state). */
    val boundEntityIds: Set<String> get() = objects.mapNotNullTo(mutableSetOf()) { it.entityBinding?.entityId }
}

class SceneFormatException(message: String) : Exception(message)

object SceneCodec {
    const val SUPPORTED_VERSION = 1

    // Unknown fields are tolerated so a newer Core does not break the viewer;
    // the version check below still refuses documents of another major format.
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    fun decode(text: String): SceneDocument = check(
        try {
            json.decodeFromString(SceneDocument.serializer(), text)
        } catch (e: SerializationException) {
            throw SceneFormatException("Сцена повреждена: ${e.message}")
        } catch (e: IllegalArgumentException) {
            throw SceneFormatException("Сцена повреждена: ${e.message}")
        },
    )

    fun decode(element: JsonElement): SceneDocument = check(
        try {
            json.decodeFromJsonElement(SceneDocument.serializer(), element)
        } catch (e: SerializationException) {
            throw SceneFormatException("Сцена повреждена: ${e.message}")
        } catch (e: IllegalArgumentException) {
            throw SceneFormatException("Сцена повреждена: ${e.message}")
        },
    )

    private fun check(doc: SceneDocument): SceneDocument {
        if (doc.schemaVersion != SUPPORTED_VERSION) {
            throw SceneFormatException("Версия сцены ${doc.schemaVersion} не поддерживается (нужна $SUPPORTED_VERSION): обновите приложение")
        }
        return doc
    }
}
