package home.aer.core

import kotlinx.coroutines.test.runTest
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.ServerSocket

fun fixture(name: String): String = FakeCore::class.java.getResource("/fixtures/$name.json")!!.readText()

/** The `data` member of a captured Core response. */
fun fixtureData(name: String): String = CoreJson.parseToJsonElement(fixture(name)).let { (it as kotlinx.serialization.json.JsonObject)["data"].toString() }

class CoreClientTest {
    private val core = FakeCore()

    @After
    fun tearDown() = core.close()

    @Test
    fun sendsBearerTokenAndApiPrefix() = runTest {
        core.ok("GET /api/v1/system/info", FakeCore.SYSTEM_ALL)
        val info = core.api().systemInfo()
        assertEquals("development", info.mode)
        assertTrue(info.moduleEnabled("network"))
        val r = core.requests.single()
        assertEquals("Bearer ${FakeCore.TOKEN}", r.headers["authorization"])
        assertEquals("application/json", r.headers["accept"])
    }

    @Test
    fun healthIsPublic() = runTest {
        core.ok("GET /api/v1/health", """{"status":"ok","timestamp":"2026-10-28T10:00:00Z","apiVersion":"v1"}""")
        assertEquals("ok", core.api(token = null).health().status)
        assertNull(core.requests.single().headers["authorization"])
    }

    @Test
    fun missingTokenFailsBeforeAnyRequest() = runTest {
        try {
            core.api(token = "").systemInfo()
            fail("expected TokenMissing")
        } catch (_: CoreException.TokenMissing) {
        }
        assertTrue(core.requests.isEmpty())
    }

    @Test
    fun errorEnvelopeBecomesTypedApiError() = runTest {
        core.on("GET /api/v1/system/info", 401) { FakeCore.error("UNAUTHORIZED", "Требуется токен") }
        try {
            core.api().systemInfo()
            fail("expected Api error")
        } catch (e: CoreException.Api) {
            assertTrue(e.isUnauthorized)
            assertEquals(401, e.status)
            assertEquals("r2", e.requestId)
            assertEquals("Core отклонил токен доступа", describeError(e))
        }
    }

    @Test
    fun validationDetailsAreExposed() = runTest {
        core.on("GET /api/v1/monitoring/logs", 422) {
            FakeCore.error("VALIDATION_FAILED", "Данные не прошли проверку", """{"fields":{"limit":"1…500"}}""")
        }
        try {
            core.api().logs(limit = 9999)
            fail()
        } catch (e: CoreException.Api) {
            assertEquals(mapOf("limit" to "1…500"), e.fieldErrors)
        }
    }

    @Test
    fun nonEnvelopeIsInvalidResponse() = runTest {
        core.on("GET /api/v1/system/info") { "<html>router login</html>" }
        try {
            core.api().systemInfo()
            fail()
        } catch (e: CoreException.InvalidResponse) {
            assertTrue(describeError(e).startsWith("По этому адресу отвечает не AER Core"))
        }
    }

    @Test
    fun closedPortIsUnreachable() = runTest {
        val port = ServerSocket(0).use { it.localPort }
        val api = CoreApi(CoreClient("http://127.0.0.1:$port".toHttpUrl(), { "t" }, CoreClient.defaultHttpClient(1)))
        try {
            api.systemInfo()
            fail()
        } catch (e: CoreException.Unreachable) {
            assertEquals("Нет связи с Core: соединение отклонено — Core не запущен или порт закрыт", describeError(e))
        }
    }

    @Test
    fun basePathAndQueryAreEncoded() {
        val c = CoreClient("http://10.0.2.2:8787/aer/".toHttpUrl(), { "t" })
        assertEquals(
            "http://10.0.2.2:8787/aer/api/v1/monitoring/logs?q=%D1%81%D0%B5%D1%82%D1%8C&limit=5",
            c.url("/monitoring/logs", mapOf("q" to "сеть", "limit" to 5, "before" to null)).toString(),
        )
    }

    @Test
    fun decodesRealCoreResponses() = runTest {
        // Captured from an isolated Core with the M09 network lab (127.0.0.1 stubs).
        core.ok("GET /api/v1/network/overview", fixtureData("network_overview"))
        core.ok("GET /api/v1/power/devices", fixtureData("power_devices"))
        core.ok("GET /api/v1/monitoring/overview", fixtureData("monitoring_overview"))
        core.ok("GET /api/v1/monitoring/states", fixtureData("monitoring_states"))
        core.ok("GET /api/v1/registry/entities", fixtureData("registry_entities"))
        core.ok("GET /api/v1/registry/types", fixtureData("registry_types"))
        core.ok("GET /api/v1/monitoring/logs", fixtureData("monitoring_logs"))
        val api = core.api()

        val net = api.networkOverview()
        assertEquals("ok", net.summary.level)
        assertEquals("up", net.internet?.status)
        assertEquals("upnp", net.routers.single().adapter)
        assertEquals("up", net.routers.single().wan?.status)
        val sun = net.sunshine.single()
        assertEquals("unconfigured", sun.tv?.status)
        assertNull("not measured stays null", sun.tv?.latencyMs)
        assertEquals("computer", sun.entity?.type)

        val power = api.powerDevices()
        assertTrue(power.isNotEmpty())
        assertTrue(power.first().actions.any { it.id == "check" && it.available })
        assertTrue(power.first().actions.filter { it.id != "check" }.all { !it.available && it.reason.isNotEmpty() })

        assertEquals(4, api.monitoringOverview().devices)
        val states = api.states()
        assertTrue(states.any { it.latencyMs != null })
        val entities = api.entities()
        assertEquals(4, entities.size)
        assertTrue(api.entityTypes().any { it.id == "router" && it.label.isNotEmpty() })
        val logs = api.logs(limit = 3)
        assertEquals(3, logs.items.size)
        assertFalse(logs.items.any { it.message.isEmpty() })
    }

    @Test
    fun entitiesArePaged() = runTest {
        var call = 0
        core.on("GET /api/v1/registry/entities") {
            call++
            val items = (1..(if (call == 1) 200 else 5)).joinToString(",") { """{"id":"id-$call-$it","name":"n","type":"computer"}""" }
            FakeCore.ok("""{"items":[$items],"total":205,"limit":200,"offset":0}""")
        }
        assertEquals(205, core.api().entities().size)
        assertEquals(listOf("limit=200&offset=0", "limit=200&offset=200"), core.requests.map { it.query })
    }
}
