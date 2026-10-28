package home.aer.scene

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** The canonical example scene shared with Core and the desktop client. */
fun exampleScene(): SceneDocument =
    SceneCodec.decode(File(System.getProperty("aer.repoRoot"), "examples/home.scene.json").readText())

// Mirrors apps/desktop/test/scene/geometry_test.dart: same inputs, same expectations.
class GeometryTest {
    @Test
    fun projectionMatchesTheDocumentedFormula() {
        assertEquals(Vec2(0.0, 0.0), Iso.project(0.0, 0.0, 0.0))
        assertEquals(Vec2(32.0, 16.0), Iso.project(1.0, 0.0, 0.0))
        assertEquals(Vec2(-32.0, 16.0), Iso.project(0.0, 1.0, 0.0))
        assertEquals(Vec2(0.0, -36.0), Iso.project(0.0, 0.0, 1.0))
    }

    @Test
    fun unprojectInvertsProjectOnAnyPlane() {
        for ((x, y, z) in listOf(Triple(3.5, 7.25, 0.0), Triple(-2.0, 4.0, 1.5), Triple(12.0, 0.5, 3.0))) {
            val (ux, uy) = Iso.unproject(Iso.project(x, y, z), z)
            assertEquals(x, ux, 1e-9)
            assertEquals(y, uy, 1e-9)
        }
    }

    @Test
    fun boxSilhouetteIsAConvexHexagon() {
        val hull = Iso.silhouette(Box3(0.0, 0.0, 0.0, 2.0, 1.0, 1.0))
        assertEquals(6, hull.size)
        assertTrue(pointInConvex(hull, Iso.project(1.0, 0.5, 0.5)))
        assertFalse(pointInConvex(hull, Vec2(500.0, 500.0)))
    }

    @Test
    fun separatingAxisAndContainers() {
        val desk = Box3(0.0, 0.0, 0.0, 3.0, 1.5, 1.5)
        val monitor = Box3(1.0, 0.2, 1.5, 2.0, 0.6, 2.5)
        assertTrue(isBehind(desk, monitor))
        val back = Box3(0.0, 0.0, 0.0, 1.0, 1.0, 1.0)
        val front = Box3(0.0, 2.0, 0.0, 1.0, 3.0, 1.0)
        assertTrue(isBehind(back, front))
        assertFalse(isBehind(front, back))
        val shelf = Box3(0.0, 0.0, 0.0, 2.0, 1.0, 3.0)
        val item = Box3(0.5, 0.2, 1.0, 1.0, 0.8, 1.5)
        assertTrue("container before its contents", isBehind(shelf, item))
        val order = depthOrder(listOf(front, shelf, item, back))
        assertTrue(order.indexOf(1) < order.indexOf(2))
        assertTrue(order.indexOf(3) < order.indexOf(0))
    }
}

class DemoLayoutTest {
    private val layout = SceneLayout.build(exampleScene())
    private fun obj(label: String) = layout.objects.values.first { it.obj.label == label }
    private fun pos(g: ObjectGeometry) = layout.drawOrder.indexOfFirst { it is DrawItem.Obj && it.geometry === g }

    @Test
    fun everyObjectHasGeometryAndWallsExist() {
        assertEquals(layout.document.objects.size, layout.objects.size)
        assertTrue(layout.drawOrder.any { it is DrawItem.Wall && it.wall.tall })
        assertTrue(layout.floorObjects.all { it.obj.layer == SceneLayer.Floor })
        assertEquals(5, layout.rooms.size)
    }

    @Test
    fun monitorAfterDeskItemsAfterShelf() {
        assertTrue(pos(obj("Рабочий стол")) < pos(obj("Монитор")))
        assertTrue(pos(obj("Стеллаж")) < pos(obj("Домашний сервер")))
        assertTrue(pos(obj("Тумба")) < pos(obj("Телевизор")))
    }

    @Test
    fun hitTestReturnsTheFrontMostObject() {
        val monitor = obj("Монитор")
        val desk = obj("Рабочий стол")
        val onMonitor = Iso.project((monitor.box.minX + monitor.box.maxX) / 2, monitor.box.maxY, monitor.box.minZ + 0.5)
        assertEquals(monitor.obj.id, layout.hitTest(onMonitor)?.obj?.id)
        assertTrue("desk silhouette overlaps there too", pointInConvex(desk.silhouette, onMonitor))
        val onDeskTop = Iso.project(desk.box.maxX - 0.3, desk.box.maxY - 0.2, desk.box.maxZ)
        assertEquals(desk.obj.id, layout.hitTest(onDeskTop)?.obj?.id)
    }

    @Test
    fun rugsAreNotHitTestableFloorMapsToRoom() {
        val rug = layout.floorObjects.first()
        val c = Iso.project((rug.box.minX + rug.box.maxX) / 2, (rug.box.minY + rug.box.maxY) / 2, 0.0)
        assertNotEquals(SceneLayer.Floor, layout.hitTest(c)?.obj?.layer)
        assertEquals(rug.room.id, layout.roomAt(c)?.room?.id)
        assertNull(layout.roomAt(Vec2(99999.0, 99999.0)))
    }

    @Test
    fun boundsCoverEveryRoom() {
        for (r in layout.rooms) {
            assertTrue(layout.bounds.contains(Iso.project(r.x0 + 0.1, r.y0 + 0.1)))
            assertTrue(layout.bounds.contains(Iso.project(r.x1 - 0.1, r.y1 - 0.1)))
        }
    }

    @Test
    fun objectsInRoomAreInteractiveOnly() {
        val office = layout.rooms.first { it.room.kind == "office" }
        val list = layout.objectsIn(office.room.id)
        assertTrue(list.isNotEmpty())
        assertTrue(list.all { it.interactive && it.room.id == office.room.id })
    }
}

class CodecTest {
    @Test
    fun demoSceneIsMarkedDemo() {
        val doc = exampleScene()
        assertTrue(doc.demo)
        assertEquals(27, doc.assets.size)
        assertTrue(doc.objects.any { it.demoState == SceneStatus.Warning })
    }

    @Test
    fun otherSchemaVersionIsRefused() {
        try {
            SceneCodec.decode("""{"schemaVersion":2,"sceneId":"x","rooms":[],"assets":[],"objects":[]}""")
            fail()
        } catch (e: SceneFormatException) {
            assertTrue(e.message!!.contains("не поддерживается"))
        }
    }

    @Test
    fun brokenJsonIsAFormatError() {
        try {
            SceneCodec.decode("{")
            fail()
        } catch (_: SceneFormatException) {
        }
    }
}

// Mirrors the viewer part of apps/desktop/test/scene/binding_test.dart.
class BindingTest {
    private val doc = exampleScene()
    private val asset = doc.assets.first()
    private val bound = doc.objects.first().copy(entityBinding = EntityBinding("11111111-1111-1111-1111-111111111111"), visualState = null)

    @Test
    fun decorHasNoBadgeDemoIsMarked() {
        val decor = doc.objects.first { it.entityBinding == null && it.visualState == null }
        assertNull(presentObject(decor, doc.asset(decor.assetId), emptyMap(), RegistryLink.Live, null).status)
        val demo = doc.objects.first { it.visualState != null }
        val p = presentObject(demo, doc.asset(demo.assetId), emptyMap(), RegistryLink.Live, null)
        assertTrue(p.isDemo)
        assertTrue(p.note.contains("Тестовое"))
    }

    @Test
    fun boundWithoutMonitoringIsUnknownNeverOnline() {
        val facts = mapOf(bound.entityBinding!!.entityId to EntityFacts("ПК", "Компьютер", false))
        val p = presentObject(bound, asset, facts, RegistryLink.Live, null)
        assertEquals(SceneStatus.Unknown, p.status)
        assertEquals("ПК", p.title)
    }

    @Test
    fun liveStateAndStaleness() {
        val facts = mapOf(bound.entityBinding!!.entityId to EntityFacts("ПК", "Компьютер", false))
        val live = LiveStatus(SceneStatus.Online, "Отвечает", stale = true)
        val p = presentObject(bound, asset, facts, RegistryLink.Live, live)
        assertEquals(SceneStatus.Online, p.status)
        assertTrue(p.stale)
    }

    @Test
    fun danglingArchivedAndUnavailable() {
        assertEquals(BindingState.Missing, presentObject(bound, asset, emptyMap(), RegistryLink.Live, null).binding)
        assertEquals(BindingState.Unavailable, presentObject(bound, asset, emptyMap(), RegistryLink.Unavailable, null).binding)
        assertEquals(BindingState.Pending, presentObject(bound, asset, emptyMap(), RegistryLink.Loading, null).binding)
        val archived = mapOf(bound.entityBinding!!.entityId to EntityFacts("ПК", "Компьютер", true))
        assertEquals(SceneStatus.Archived, presentObject(bound, asset, archived, RegistryLink.Live, null).status)
    }

    @Test
    fun monitoringMapping() {
        assertEquals(SceneStatus.Online, SceneStatus.fromMonitoring("online", null))
        assertEquals(SceneStatus.Warning, SceneStatus.fromMonitoring("degraded", "warning"))
        assertEquals(SceneStatus.Critical, SceneStatus.fromMonitoring("degraded", "critical"))
        assertEquals(SceneStatus.Offline, SceneStatus.fromMonitoring("offline", null))
        assertEquals(SceneStatus.Unknown, SceneStatus.fromMonitoring("unsupported", null))
    }
}

class CameraTest {
    private val house = SceneLayout.build(exampleScene()).bounds

    @Test
    fun fitShowsTheWholeHouse() {
        val cam = SceneCamera.fit(house, 400.0, 700.0)
        val tl = cam.toScreen(Vec2(house.left, house.top), 400.0, 700.0)
        val br = cam.toScreen(Vec2(house.right, house.bottom), 400.0, 700.0)
        assertTrue(tl.x >= 0 && tl.y >= 0 && br.x <= 400 && br.y <= 700)
    }

    @Test
    fun zoomAndPanAreClamped() {
        val cam = SceneCamera.fit(house, 400.0, 700.0)
        val zoomedIn = cam.transformed(house, 400.0, 700.0, Vec2(0.0, 0.0), 100.0)
        assertEquals(SceneCamera.MAX_ZOOM, zoomedIn.zoom, 1e-9)
        val zoomedOut = cam.transformed(house, 400.0, 700.0, Vec2(0.0, 0.0), 0.001)
        assertEquals(SceneCamera.fitZoom(house, 400.0, 700.0) * 0.6, zoomedOut.zoom, 1e-9)
        val flung = cam.transformed(house, 400.0, 700.0, Vec2(1e7, -1e7), 1.0)
        assertTrue("center stays inside the house", flung.center.x >= house.left && flung.center.y <= house.bottom)
    }

    @Test
    fun screenWorldRoundTrip() {
        val cam = SceneCamera(Vec2(10.0, 20.0), 1.7)
        val w = cam.toWorld(cam.toScreen(Vec2(123.0, -45.0), 400.0, 700.0), 400.0, 700.0)
        assertEquals(123.0, w.x, 1e-9)
        assertEquals(-45.0, w.y, 1e-9)
    }
}
