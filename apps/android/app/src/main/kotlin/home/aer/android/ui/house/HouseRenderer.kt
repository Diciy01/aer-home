package home.aer.android.ui.house

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.drawText
import androidx.compose.ui.unit.sp
import home.aer.android.ui.theme.AerColors
import home.aer.scene.Box3
import home.aer.scene.DrawItem
import home.aer.scene.FLOOR_THICKNESS
import home.aer.scene.Iso
import home.aer.scene.ObjectPresentation
import home.aer.scene.SceneCamera
import home.aer.scene.SceneCatalog
import home.aer.scene.SceneLayout
import home.aer.scene.SceneStatus
import home.aer.scene.Vec2
import home.aer.scene.WallSide
import home.aer.scene.WallSegment

/** Status colours of the house view (desktop scene palette: offline is muted, not alarming). */
fun sceneStatusColor(s: SceneStatus): Color = when (s) {
    SceneStatus.Online -> Color(0xFF5F7E64)
    SceneStatus.Offline -> Color(0xFF8F8279)
    SceneStatus.Warning -> Color(0xFFC98E3E)
    SceneStatus.Critical -> Color(0xFFB8604B)
    SceneStatus.Unknown -> Color(0xFFA89C92)
    SceneStatus.Loading -> AerColors.blue
    SceneStatus.Archived -> AerColors.lavender
}

private fun argb(v: Long) = Color(v.toInt())

private fun lighten(c: Color, f: Float) = lerp(c, Color.White, f)
private fun darken(c: Color, f: Float) = lerp(c, Color(0xFF2E2621), f)

/**
 * Simplified painter for scene format v1: the same geometry, order and hit
 * areas as the desktop renderer (via :scene), drawn as shaded boxes instead of
 * the desktop's procedural art. Status badges and labels are screen-sized.
 */
class HouseRenderer(
    private val layout: SceneLayout,
    private val presentations: Map<String, ObjectPresentation>,
    private val textMeasurer: TextMeasurer,
) {
    fun DrawScope.draw(cam: SceneCamera, selectedObject: String?, selectedRoom: String?) {
        val w = size.width.toDouble()
        val h = size.height.toDouble()
        fun p(x: Double, y: Double, z: Double): Offset {
            val s = cam.toScreen(Iso.project(x, y, z), w, h)
            return Offset(s.x.toFloat(), s.y.toFloat())
        }
        fun poly(pts: List<Offset>): Path = Path().apply {
            moveTo(pts[0].x, pts[0].y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            close()
        }
        val edge = Stroke(width = 1f)

        // 1. Floors (slab sides first, then the walkable top), tinted by the room light preset.
        for (r in layout.rooms) {
            val floor = argb(SceneCatalog.floorColor(r.room.style.floor))
            val tint = r.room.style.light?.let { SceneCatalog.lights[it] }?.let(::argb)
            val top = if (tint != null) lerp(floor, tint.copy(alpha = 1f), tint.alpha) else floor
            val ft = FLOOR_THICKNESS
            drawPath(poly(listOf(p(r.x0, r.y1, 0.0), p(r.x1, r.y1, 0.0), p(r.x1, r.y1, -ft), p(r.x0, r.y1, -ft))), darken(floor, 0.18f))
            drawPath(poly(listOf(p(r.x1, r.y0, 0.0), p(r.x1, r.y1, 0.0), p(r.x1, r.y1, -ft), p(r.x1, r.y0, -ft))), darken(floor, 0.30f))
            val topPath = poly(listOf(p(r.x0, r.y0, 0.0), p(r.x1, r.y0, 0.0), p(r.x1, r.y1, 0.0), p(r.x0, r.y1, 0.0)))
            drawPath(topPath, top)
            drawPath(topPath, darken(floor, 0.25f).copy(alpha = 0.35f), style = edge)
            if (r.room.id == selectedRoom) drawPath(topPath, AerColors.accent, style = Stroke(width = 4f))
        }
        // 2. Floor decor (rugs).
        for (g in layout.floorObjects) {
            val b = g.box
            val c = objectColor(g.asset.id, g.obj.metadata["finish"])
            drawPath(poly(listOf(p(b.minX, b.minY, b.maxZ), p(b.maxX, b.minY, b.maxZ), p(b.maxX, b.maxY, b.maxZ), p(b.minX, b.maxY, b.maxZ))), c)
        }
        // 3. Walls and objects in the painter's order.
        for (item in layout.drawOrder) {
            when (item) {
                is DrawItem.Wall -> drawWall(item.wall, ::p, ::poly)
                is DrawItem.Obj -> {
                    val g = item.geometry
                    val pres = presentations[g.obj.id]
                    drawBox(g.box, objectColor(g.asset.id, g.obj.metadata["finish"]), ::p, ::poly)
                    if (SceneCatalog.hasScreen(g.asset.id)) drawScreenFace(g.box, g.obj.rotation, pres?.status == SceneStatus.Online, ::p, ::poly)
                }
            }
        }
        // 4. Selection, status badges and room names on top, at screen size.
        selectedObject?.let { id ->
            layout.objects[id]?.let { g ->
                val path = Path().apply {
                    g.silhouette.forEachIndexed { i, v ->
                        val s = cam.toScreen(v, w, h)
                        if (i == 0) moveTo(s.x.toFloat(), s.y.toFloat()) else lineTo(s.x.toFloat(), s.y.toFloat())
                    }
                    close()
                }
                drawPath(path, AerColors.accent.copy(alpha = 0.18f))
                drawPath(path, AerColors.accent, style = Stroke(width = 5f))
            }
        }
        val badgeR = 9.5f * density
        for (g in layout.objects.values) {
            val pres = presentations[g.obj.id] ?: continue
            val st = pres.status ?: continue
            val a = cam.toScreen(g.topAnchor, w, h)
            val c = Offset(a.x.toFloat(), a.y.toFloat() - badgeR - 2 * density)
            val alpha = if (pres.stale) 0.5f else 1f
            drawCircle(Color.White.copy(alpha = alpha), badgeR + 2.5f * density, c)
            drawCircle(sceneStatusColor(st).copy(alpha = alpha), badgeR, c)
            if (pres.isDemo) drawCircle(AerColors.lavender, badgeR + 2.5f * density, c, style = Stroke(width = 2f * density))
        }
        val labelStyle = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = AerColors.ink)
        for (r in layout.rooms) {
            val c = cam.toScreen(Iso.project((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2, 0.0), w, h)
            val text = textMeasurer.measure(r.room.name, labelStyle)
            val pad = 6f * density
            val tl = Offset(c.x.toFloat() - text.size.width / 2f - pad, c.y.toFloat() - text.size.height / 2f - pad / 2)
            drawRoundRect(
                AerColors.surface.copy(alpha = 0.88f),
                topLeft = tl,
                size = Size(text.size.width + 2 * pad, text.size.height + pad),
                cornerRadius = CornerRadius(10f * density),
            )
            drawText(text, topLeft = Offset(tl.x + pad, tl.y + pad / 2))
        }
    }

    private fun objectColor(assetId: String, finish: String?): Color {
        val base = argb(SceneCatalog.assetColor(assetId))
        val tint = finish?.let { SceneCatalog.finishes[it] }?.let(::argb) ?: return base
        return lerp(base, tint.copy(alpha = 1f), tint.alpha)
    }

    private fun DrawScope.drawBox(b: Box3, base: Color, p: (Double, Double, Double) -> Offset, poly: (List<Offset>) -> Path) {
        val top = poly(listOf(p(b.minX, b.minY, b.maxZ), p(b.maxX, b.minY, b.maxZ), p(b.maxX, b.maxY, b.maxZ), p(b.minX, b.maxY, b.maxZ)))
        val left = poly(listOf(p(b.minX, b.maxY, b.maxZ), p(b.maxX, b.maxY, b.maxZ), p(b.maxX, b.maxY, b.minZ), p(b.minX, b.maxY, b.minZ)))
        val right = poly(listOf(p(b.maxX, b.minY, b.maxZ), p(b.maxX, b.maxY, b.maxZ), p(b.maxX, b.maxY, b.minZ), p(b.maxX, b.minY, b.minZ)))
        drawPath(left, base)
        drawPath(right, darken(base, 0.16f))
        drawPath(top, lighten(base, 0.14f))
        val line = darken(base, 0.35f).copy(alpha = 0.45f)
        val s = Stroke(width = 1f)
        drawPath(left, line, style = s)
        drawPath(right, line, style = s)
        drawPath(top, line, style = s)
    }

    private fun DrawScope.drawWall(wall: WallSegment, p: (Double, Double, Double) -> Offset, poly: (List<Offset>) -> Path) {
        val room = layout.roomGeometry(wall.roomId)?.room
        val base = argb(SceneCatalog.wallColor(room?.style?.wall ?: ""))
        drawBox(wall.box, base, p, poly)
        if (!wall.window) return
        // Window: a light pane on the inner face, in the middle third of the wall height.
        val b = wall.box
        val z0 = b.maxZ * 0.38
        val z1 = b.maxZ * 0.78
        val pane = Color(0xFFDCE8EC)
        if (wall.side == WallSide.North) {
            val y = b.maxY
            drawPath(poly(listOf(p(b.minX + 0.2, y, z1), p(b.maxX - 0.2, y, z1), p(b.maxX - 0.2, y, z0), p(b.minX + 0.2, y, z0))), pane)
        } else {
            val x = b.maxX
            drawPath(poly(listOf(p(x, b.minY + 0.2, z1), p(x, b.maxY - 0.2, z1), p(x, b.maxY - 0.2, z0), p(x, b.minY + 0.2, z0))), pane)
        }
    }

    /** Screen panel on the front face (rotation 0 → +y, 90 → +x); lit only for a device Monitoring reports online. */
    private fun DrawScope.drawScreenFace(b: Box3, rotation: Int, lit: Boolean, p: (Double, Double, Double) -> Offset, poly: (List<Offset>) -> Path) {
        val color = if (lit) Color(0xFF9CC3D2) else Color(0xFF2F2925)
        val z0 = b.minZ + (b.maxZ - b.minZ) * 0.18
        val z1 = b.maxZ - (b.maxZ - b.minZ) * 0.1
        when (rotation) {
            0 -> {
                val inset = (b.maxX - b.minX) * 0.08
                drawPath(poly(listOf(p(b.minX + inset, b.maxY, z1), p(b.maxX - inset, b.maxY, z1), p(b.maxX - inset, b.maxY, z0), p(b.minX + inset, b.maxY, z0))), color)
            }
            90 -> {
                val inset = (b.maxY - b.minY) * 0.08
                drawPath(poly(listOf(p(b.maxX, b.minY + inset, z1), p(b.maxX, b.maxY - inset, z1), p(b.maxX, b.maxY - inset, z0), p(b.maxX, b.minY + inset, z0))), color)
            }
            else -> Unit // faces away from the viewer
        }
    }
}

/** Screen point → world point for touch handling. */
fun SceneCamera.worldAt(x: Float, y: Float, w: Float, h: Float): Vec2 = toWorld(Vec2(x.toDouble(), y.toDouble()), w.toDouble(), h.toDouble())
