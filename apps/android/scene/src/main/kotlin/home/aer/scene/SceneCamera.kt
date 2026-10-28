package home.aer.scene

import kotlin.math.max
import kotlin.math.min

/**
 * Camera over the house: screen = (world − center) · zoom + viewport/2.
 * Same limits as the desktop (SCENE_FORMAT.md): zoom in [0.6 × fit, 3.5] and
 * the center never leaves the house bounds, so the scene cannot be lost.
 */
data class SceneCamera(val center: Vec2, val zoom: Double) {
    fun toScreen(world: Vec2, viewW: Double, viewH: Double) =
        Vec2((world.x - center.x) * zoom + viewW / 2, (world.y - center.y) * zoom + viewH / 2)

    fun toWorld(screen: Vec2, viewW: Double, viewH: Double) =
        Vec2((screen.x - viewW / 2) / zoom + center.x, (screen.y - viewH / 2) / zoom + center.y)

    companion object {
        const val MAX_ZOOM = 3.5
        private const val MARGIN = 0.92

        /** Zoom that shows [r] whole inside the viewport. */
        fun fitZoom(r: Rect2, viewW: Double, viewH: Double): Double {
            if (r.width <= 0 || r.height <= 0 || viewW <= 0 || viewH <= 0) return 1.0
            return min(viewW / r.width, viewH / r.height) * MARGIN
        }

        fun fit(r: Rect2, viewW: Double, viewH: Double) = SceneCamera(r.center, min(fitZoom(r, viewW, viewH), MAX_ZOOM))
    }

    /** Applies pan (screen pixels) and pinch, then clamps to [house] bounds. */
    fun transformed(house: Rect2, viewW: Double, viewH: Double, pan: Vec2, zoomFactor: Double, focus: Vec2? = null): SceneCamera {
        val minZoom = fitZoom(house, viewW, viewH) * 0.6
        val newZoom = (zoom * zoomFactor).coerceIn(min(minZoom, MAX_ZOOM), MAX_ZOOM)
        // Keep the world point under the pinch focus in place.
        var c = center
        if (focus != null && newZoom != zoom) {
            val w = toWorld(focus, viewW, viewH)
            c = Vec2(w.x - (focus.x - viewW / 2) / newZoom, w.y - (focus.y - viewH / 2) / newZoom)
        }
        c = Vec2(c.x - pan.x / newZoom, c.y - pan.y / newZoom)
        return SceneCamera(clampCenter(c, house), newZoom)
    }

    private fun clampCenter(c: Vec2, r: Rect2) = Vec2(max(r.left, min(r.right, c.x)), max(r.top, min(r.bottom, c.y)))
}
