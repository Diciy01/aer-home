package home.aer.scene

import kotlin.math.ceil

// Port of apps/desktop/lib/src/scene/geometry/scene_layout.dart.

/** Wall thickness, low interior partitions and the floor slab (tiles). */
const val WALL_THICKNESS = 0.25
const val PARTITION_HEIGHT = 0.7
const val FLOOR_THICKNESS = 0.6

class RoomGeometry(val room: SceneRoom) {
    val x0 = room.origin.x
    val y0 = room.origin.y
    val x1 = room.origin.x + room.size.w
    val y1 = room.origin.y + room.size.d

    val floorBox get() = Box3(x0, y0, -FLOOR_THICKNESS, x1, y1, 0.0)
    fun contains(x: Double, y: Double) = x >= x0 && x < x1 && y >= y0 && y < y1

    /** Screen rect covering the floor plus a typical wall height (camera focus). */
    val focusBounds get() = Iso.screenBounds(Box3(x0, y0, 0.0, x1, y1, room.wallHeight * 0.6))
}

enum class WallSide { North, West }

/** Outer walls are tall; partitions between rooms stay low (cutaway view). */
data class WallSegment(val roomId: String, val side: WallSide, val box: Box3, val tall: Boolean, val window: Boolean)

class ObjectGeometry(val obj: SceneObject, val asset: SceneAsset, val room: SceneRoom, val box: Box3) {
    val silhouette = Iso.silhouette(box)
    val screenBounds = Iso.screenBounds(box)
    val interactive get() = obj.layer != SceneLayer.Floor

    /** Anchor for labels and status badges: top centre of the box. */
    val topAnchor get() = Iso.project((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2, box.maxZ)
}

sealed interface DrawItem {
    data class Wall(val wall: WallSegment) : DrawItem
    data class Obj(val geometry: ObjectGeometry) : DrawItem
}

/** Everything the renderer and touch handling need, computed once per document. */
class SceneLayout private constructor(
    val document: SceneDocument,
    val rooms: List<RoomGeometry>,
    val floorObjects: List<ObjectGeometry>,
    val drawOrder: List<DrawItem>,
    val objects: Map<String, ObjectGeometry>,
    /** Screen-space bounds of the whole house at zoom 1. */
    val bounds: Rect2,
) {
    fun roomGeometry(id: String) = rooms.firstOrNull { it.room.id == id }

    /** Topmost interactive object under a world point; hidden objects are never picked through others. */
    fun hitTest(world: Vec2): ObjectGeometry? {
        for (item in drawOrder.asReversed()) {
            when (item) {
                is DrawItem.Wall -> if (item.wall.tall && pointInConvex(Iso.silhouette(item.wall.box), world)) return null
                is DrawItem.Obj -> {
                    val g = item.geometry
                    if (g.interactive && g.screenBounds.contains(world) && pointInConvex(g.silhouette, world)) return g
                }
            }
        }
        return null
    }

    /** Room whose floor is under a world point. */
    fun roomAt(world: Vec2): RoomGeometry? {
        val (x, y) = Iso.unproject(world)
        return rooms.firstOrNull { it.contains(x, y) }
    }

    /** Interactive objects of a room in a stable reading order (for lists next to the picture). */
    fun objectsIn(roomId: String): List<ObjectGeometry> =
        objects.values.filter { it.room.id == roomId && it.interactive }.sortedWith(compareBy({ it.box.minY }, { it.box.minX }))

    companion object {
        fun build(doc: SceneDocument): SceneLayout {
            val rooms = doc.rooms.map { RoomGeometry(it) }.sortedBy { it.x0 + it.y0 }
            val objects = LinkedHashMap<String, ObjectGeometry>()
            for (o in doc.objects) {
                val asset = doc.asset(o.assetId) ?: continue
                val room = doc.room(o.roomId) ?: continue
                objects[o.id] = ObjectGeometry(o, asset, room, boxOf(o, asset, room))
            }
            val walls = walls(rooms)
            val floorObjects = objects.values.filter { it.obj.layer == SceneLayer.Floor }.sortedBy { it.box.depthKey }
            val items: List<DrawItem> = walls.map { DrawItem.Wall(it) } +
                objects.values.filter { it.obj.layer != SceneLayer.Floor }.map { DrawItem.Obj(it) }
            val boxes = items.map {
                when (it) {
                    is DrawItem.Wall -> it.wall.box
                    is DrawItem.Obj -> it.geometry.box
                }
            }
            val order = depthOrder(boxes).map { items[it] }
            var bounds: Rect2? = null
            fun include(r: Rect2) {
                bounds = bounds?.union(r) ?: r
            }
            rooms.forEach { include(Iso.screenBounds(it.floorBox)) }
            walls.forEach { include(Iso.screenBounds(it.box)) }
            objects.values.forEach { include(it.screenBounds) }
            return SceneLayout(doc, rooms, floorObjects, order, objects, bounds ?: Rect2.Zero)
        }

        /** World box of an object: room origin + local position, rotated and scaled footprint. */
        fun boxOf(o: SceneObject, asset: SceneAsset, room: SceneRoom): Box3 {
            val fp = o.footprint(asset)
            val x = room.origin.x + o.position.x
            val y = room.origin.y + o.position.y
            return Box3(x, y, o.position.z, x + fp.w, y + fp.d, o.position.z + asset.height * o.scale)
        }

        private fun walls(rooms: List<RoomGeometry>): List<WallSegment> {
            fun occupied(x: Double, y: Double) = rooms.any { it.contains(x, y) }
            val out = mutableListOf<WallSegment>()
            for (r in rooms) {
                val h = r.room.wallHeight
                for (side in WallSide.entries) {
                    val length = if (side == WallSide.North) r.x1 - r.x0 else r.y1 - r.y0
                    val n = ceil(length).toInt()
                    // Classify unit segments, then merge runs with equal flags.
                    data class Seg(val a: Double, val b: Double, val outside: Boolean, val window: Boolean)
                    val segs = mutableListOf<Seg>()
                    for (i in 0 until n) {
                        val a = i.toDouble()
                        val b = (i + 1.0).coerceIn(0.0, length)
                        val mid = (a + b) / 2
                        val outside = if (side == WallSide.North) !occupied(r.x0 + mid, r.y0 - 0.05) else !occupied(r.x0 - 0.05, r.y0 + mid)
                        val door = !outside && n >= 4 && (i == n / 2 || i == n / 2 - 1)
                        if (door) continue
                        val window = outside && n >= 6 && (i == n / 2 || i == n / 2 - 1)
                        segs += Seg(a, b, outside, window)
                    }
                    var k = 0
                    while (k < segs.size) {
                        val (a, b0, tall, window) = segs[k]
                        var b = b0
                        while (k + 1 < segs.size && segs[k + 1].a == b && segs[k + 1].outside == tall && segs[k + 1].window == window) {
                            b = segs[++k].b
                        }
                        k++
                        val height = if (tall) h else PARTITION_HEIGHT
                        if (height <= 0) continue
                        val box = if (side == WallSide.North) {
                            Box3(r.x0 + a - (if (a == 0.0) WALL_THICKNESS else 0.0), r.y0 - WALL_THICKNESS, 0.0, r.x0 + b, r.y0, height)
                        } else {
                            Box3(r.x0 - WALL_THICKNESS, r.y0 + a, 0.0, r.x0, r.y0 + b, height)
                        }
                        out += WallSegment(r.room.id, side, box, tall, window)
                    }
                }
            }
            return out
        }
    }
}
