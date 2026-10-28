package home.aer.scene

import kotlin.math.max
import kotlin.math.min

// Port of apps/desktop/lib/src/scene/geometry/iso.dart: the same projection,
// silhouettes and painter's order, so both clients draw a scene identically.

data class Vec2(val x: Double, val y: Double) {
    operator fun plus(o: Vec2) = Vec2(x + o.x, y + o.y)
    operator fun minus(o: Vec2) = Vec2(x - o.x, y - o.y)
    operator fun times(k: Double) = Vec2(x * k, y * k)
}

data class Rect2(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    val width get() = right - left
    val height get() = bottom - top
    val center get() = Vec2((left + right) / 2, (top + bottom) / 2)

    fun contains(p: Vec2) = p.x >= left && p.x < right && p.y >= top && p.y < bottom
    fun overlaps(o: Rect2) = right > o.left && o.right > left && bottom > o.top && o.bottom > top
    fun deflate(d: Double) = Rect2(left + d, top + d, right - d, bottom - d)
    fun union(o: Rect2) = Rect2(min(left, o.left), min(top, o.top), max(right, o.right), max(bottom, o.bottom))

    companion object {
        val Zero = Rect2(0.0, 0.0, 0.0, 0.0)
        fun bounding(points: List<Vec2>): Rect2 = Rect2(
            points.minOf { it.x },
            points.minOf { it.y },
            points.maxOf { it.x },
            points.maxOf { it.y },
        )
    }
}

/** Axis-aligned box in scene space (tiles): +x screen down-right, +y down-left, +z up. */
data class Box3(val minX: Double, val minY: Double, val minZ: Double, val maxX: Double, val maxY: Double, val maxZ: Double) {
    /** Sort key for ties: centre depth towards the viewer. */
    val depthKey get() = (minX + maxX) / 2 + (minY + maxY) / 2 + (minZ + maxZ) / 4

    val corners: List<Triple<Double, Double, Double>>
        get() = buildList {
            for (x in listOf(minX, maxX)) for (y in listOf(minY, maxY)) for (z in listOf(minZ, maxZ)) add(Triple(x, y, z))
        }
}

/** 2:1 dimetric projection (docs/SCENE_FORMAT.md). */
object Iso {
    const val TILE_WIDTH = 64.0
    const val TILE_HEIGHT = 32.0
    const val Z_STEP = 36.0

    fun project(x: Double, y: Double, z: Double = 0.0) = Vec2((x - y) * TILE_WIDTH / 2, (x + y) * TILE_HEIGHT / 2 - z * Z_STEP)

    /** Inverse of [project] on the horizontal plane at height [z]. */
    fun unproject(p: Vec2, z: Double = 0.0): Pair<Double, Double> {
        val a = p.x / (TILE_WIDTH / 2)
        val b = (p.y + z * Z_STEP) / (TILE_HEIGHT / 2)
        return (a + b) / 2 to (b - a) / 2
    }

    fun silhouette(b: Box3): List<Vec2> = convexHull(b.corners.map { (x, y, z) -> project(x, y, z) })

    fun screenBounds(b: Box3): Rect2 = Rect2.bounding(b.corners.map { (x, y, z) -> project(x, y, z) })
}

/** Andrew's monotone chain; counter-clockwise hull without repeats. */
fun convexHull(points: List<Vec2>): List<Vec2> {
    val pts = points.distinct().sortedWith(compareBy<Vec2> { it.x }.thenBy { it.y })
    if (pts.size < 3) return pts
    fun cross(o: Vec2, a: Vec2, b: Vec2) = (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    val lower = mutableListOf<Vec2>()
    for (p in pts) {
        while (lower.size >= 2 && cross(lower[lower.size - 2], lower.last(), p) <= 0) lower.removeAt(lower.lastIndex)
        lower += p
    }
    val upper = mutableListOf<Vec2>()
    for (p in pts.asReversed()) {
        while (upper.size >= 2 && cross(upper[upper.size - 2], upper.last(), p) <= 0) upper.removeAt(upper.lastIndex)
        upper += p
    }
    return lower.dropLast(1) + upper.dropLast(1)
}

/** Point-in-convex-polygon test (either winding); edges count as inside. */
fun pointInConvex(poly: List<Vec2>, p: Vec2): Boolean {
    if (poly.size < 3) return false
    var sign = 0
    for (i in poly.indices) {
        val a = poly[i]
        val b = poly[(i + 1) % poly.size]
        val c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        if (kotlin.math.abs(c) < 1e-9) continue
        val s = if (c > 0) 1 else -1
        if (sign == 0) sign = s else if (s != sign) return false
    }
    return true
}

/** True when [a] must be painted before [b]; the first separating axis decides. */
fun isBehind(a: Box3, b: Box3, eps: Double = 1e-6): Boolean {
    if (a.maxX <= b.minX + eps) return true
    if (b.maxX <= a.minX + eps) return false
    if (a.maxY <= b.minY + eps) return true
    if (b.maxY <= a.minY + eps) return false
    if (a.maxZ <= b.minZ + eps) return true
    if (b.maxZ <= a.minZ + eps) return false
    // Volumes intersect: a container (shelf, rack) is painted before its contents.
    fun containsXY(o: Box3, i: Box3) =
        o.minX <= i.minX + eps && o.maxX >= i.maxX - eps && o.minY <= i.minY + eps && o.maxY >= i.maxY - eps
    if (containsXY(a, b)) return true
    if (containsXY(b, a)) return false
    return a.depthKey < b.depthKey
}

/** Topological painter's order; only pairs with overlapping screen bounds get an edge. */
fun depthOrder(boxes: List<Box3>): List<Int> {
    val n = boxes.size
    val bounds = boxes.map { Iso.screenBounds(it).deflate(0.01) }
    val after = List(n) { mutableListOf<Int>() }
    val indegree = IntArray(n)
    for (i in 0 until n) {
        for (j in i + 1 until n) {
            if (!bounds[i].overlaps(bounds[j])) continue
            if (isBehind(boxes[i], boxes[j])) {
                after[i] += j
                indegree[j]++
            } else {
                after[j] += i
                indegree[i]++
            }
        }
    }
    val ready = (0 until n).filter { indegree[it] == 0 }.toMutableList()
    val done = BooleanArray(n)
    val order = mutableListOf<Int>()
    while (order.size < n) {
        if (ready.isEmpty()) {
            // Cycle: release the shallowest remaining node.
            var best = -1
            for (i in 0 until n) if (!done[i] && (best < 0 || boxes[i].depthKey < boxes[best].depthKey)) best = i
            ready += best
            indegree[best] = 0
        }
        ready.sortByDescending { boxes[it].depthKey }
        val next = ready.removeAt(ready.lastIndex)
        if (done[next]) continue
        done[next] = true
        order += next
        for (m in after[next]) if (!done[m] && --indegree[m] == 0) ready += m
    }
    return order
}
