package home.aer.core

import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Duration
import java.time.Instant

class HomeRepositoryTest {
    private val core = FakeCore()
    private var now = Instant.parse("2026-10-28T12:00:00Z")
    private var configured = true
    private val repo = HomeRepository({ if (configured) core.api() else null }, { now })

    @After
    fun tearDown() = core.close()

    private fun serveAll() {
        core.ok("GET /api/v1/system/info", FakeCore.SYSTEM_ALL)
        core.ok("GET /api/v1/monitoring/overview", fixtureData("monitoring_overview"))
        core.ok("GET /api/v1/monitoring/states", fixtureData("monitoring_states"))
        core.ok("GET /api/v1/registry/entities", fixtureData("registry_entities"))
        core.ok("GET /api/v1/registry/types", fixtureData("registry_types"))
        core.ok("GET /api/v1/network/overview", fixtureData("network_overview"))
        core.ok("GET /api/v1/power/devices", fixtureData("power_devices"))
        core.ok("GET /api/v1/bots", "[]")
        core.ok("GET /api/v1/monitoring/incidents", """{"items":[],"total":0}""")
    }

    @Test
    fun notConfiguredDoesNotTouchNetwork() = runTest {
        configured = false
        repo.refresh()
        assertEquals(Link.NotConfigured, repo.snapshot.value.link)
        assertTrue(core.requests.isEmpty())
    }

    @Test
    fun fullRefreshFillsEverySection() = runTest {
        serveAll()
        repo.refresh()
        val s = repo.snapshot.value
        assertEquals(Link.Online, s.link)
        assertEquals(now, s.lastSuccessAt)
        assertEquals(4, s.entities?.size)
        assertEquals(4, s.states.size)
        assertNotNull(s.network)
        assertNotNull(s.power)
        assertEquals(emptyList<Bot>(), s.bots)
        assertTrue(s.sectionErrors.isEmpty())
        assertFalse(s.isStale(now, Duration.ofSeconds(30)))
        assertEquals("Роутер", s.typeLabel("router"))
    }

    @Test
    fun coreGoingAwayKeepsDataButMarksItStale() = runTest {
        serveAll()
        repo.refresh()
        core.close() // Core process stops
        now = now.plusSeconds(15)
        repo.refresh()
        val s = repo.snapshot.value
        assertEquals(Link.Unreachable, s.link)
        assertTrue(s.linkMessage.startsWith("Нет связи с Core"))
        assertEquals("last known data is kept", 4, s.entities?.size)
        assertTrue(s.isStale(now, Duration.ofSeconds(30)))
    }

    @Test
    fun oldDataIsStaleEvenWhenOnline() = runTest {
        serveAll()
        repo.refresh()
        assertTrue(repo.snapshot.value.isStale(now.plusSeconds(61), Duration.ofSeconds(60)))
    }

    @Test
    fun rejectedTokenIsReportedAsAuthProblem() = runTest {
        core.on("GET /api/v1/system/info", 401) { FakeCore.error("UNAUTHORIZED", "Требуется токен") }
        repo.refresh()
        assertEquals(Link.Unauthorized, repo.snapshot.value.link)
        assertEquals("only system/info was asked", 1, core.requests.size)
    }

    @Test
    fun foreignServiceIsIncompatible() = runTest {
        core.on("GET /api/v1/system/info") { "not json" }
        repo.refresh()
        assertEquals(Link.Incompatible, repo.snapshot.value.link)
    }

    @Test
    fun oneFailingSectionDoesNotHideOthers() = runTest {
        serveAll()
        core.on("GET /api/v1/power/devices", 500) { FakeCore.error("INTERNAL", "internal error") }
        repo.refresh()
        val s = repo.snapshot.value
        assertEquals(Link.Online, s.link)
        assertNull(s.power)
        assertTrue(s.sectionErrors[Section.Power]!!.startsWith("Внутренняя ошибка Core"))
        assertNotNull(s.network)
    }

    @Test
    fun disabledModulesAreNotQueried() = runTest {
        serveAll()
        core.ok(
            "GET /api/v1/system/info",
            """{"mode":"local","modules":[{"name":"registry","enabled":true},{"name":"monitoring","enabled":true},{"name":"network","enabled":false}]}""",
        )
        repo.refresh()
        val s = repo.snapshot.value
        assertEquals(setOf(Section.Network, Section.Power, Section.Bots), s.disabled)
        assertFalse(core.requests.any { it.path.startsWith("/api/v1/network") || it.path.startsWith("/api/v1/power") })
        assertNull(s.network)
    }

    @Test
    fun typesAreFetchedOnce() = runTest {
        serveAll()
        repo.refresh()
        repo.refresh()
        assertEquals(1, core.requests.count { it.path == "/api/v1/registry/types" })
    }
}
