package home.aer.core

import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionFlowTest {
    private val core = FakeCore()
    private val flow = ActionFlow { core.api() }
    private val id = "e868be9e-7758-45ab-b7da-b23344772aad"
    private val reboot = ActionTarget(ActionTarget.Kind.Power, id, "ПК", "reboot", "Перезагрузить", needsConfirmation = true)

    @After
    fun tearDown() = core.close()

    private val confirmation = """{"token":"one-time-secret","entityId":"$id","action":"reboot","targetOs":"",
        "summary":"Перезагрузить ПК","risks":["Несохранённые данные будут потеряны"],
        "checks":[{"name":"Агент на связи","ok":true,"message":""}],"expiresAt":"2026-10-28T12:01:00Z"}"""

    private fun job(state: String, simulated: Boolean = false) =
        """{"id":"job-1","entityId":"$id","deviceName":"ПК","action":"reboot","targetOs":"","state":"$state","message":"m",
           "replayed":false,"simulated":$simulated,"requestedAt":"2026-10-28T12:00:00Z","deadline":"2026-10-28T12:05:00Z"}"""

    @Test
    fun confirmThenExecuteSendsTokenAndKey() = runTest {
        core.ok("POST /api/v1/power/devices/$id/actions/reboot/confirm", confirmation)
        core.on("POST /api/v1/power/devices/$id/actions/reboot", 202) { FakeCore.ok(job("queued")) }

        flow.start(reboot)
        val waiting = flow.step.value as ActionStep.AwaitingUser
        assertEquals("Перезагрузить ПК", waiting.preview.summary)
        assertEquals(1, waiting.preview.risks.size)
        assertFalse("token is not exposed to the UI", waiting.toString().contains("one-time-secret"))
        assertEquals("nothing runs before the user confirms", 1, core.requests.size)

        flow.approve()
        val done = flow.step.value as ActionStep.Finished
        assertEquals("В очереди — ждёт агента", done.outcome.title)
        val exec = core.requests.last()
        assertTrue(exec.body.contains("\"confirmationToken\":\"one-time-secret\""))
        assertTrue(exec.headers["idempotency-key"]!!.startsWith("mobile-"))
    }

    @Test
    fun simulatedJobIsNeverShownAsDone() = runTest {
        core.ok("POST /api/v1/power/devices/$id/actions/reboot/confirm", confirmation)
        core.on("POST /api/v1/power/devices/$id/actions/reboot", 202) { FakeCore.ok(job("queued")) }
        flow.start(reboot)
        flow.approve()
        flow.updatePowerJob(CoreJson.decodeFromString(PowerJob.serializer(), job("simulated", simulated = true)))
        val o = (flow.step.value as ActionStep.Finished).outcome
        assertTrue(o.simulated)
        assertEquals("SIMULATED — ничего не выполнено", o.title)
    }

    @Test
    fun checkRunsWithoutConfirmation() = runTest {
        core.on("POST /api/v1/power/devices/$id/actions/check", 202) { FakeCore.ok(job("succeeded")) }
        flow.start(reboot.copy(action = "check", label = "Проверить", needsConfirmation = false))
        assertTrue(flow.step.value is ActionStep.Finished)
        assertEquals(1, core.requests.size)
        assertFalse(core.requests.single().body.contains("confirmationToken"))
    }

    @Test
    fun refusedConfirmationShowsCoreReason() = runTest {
        core.on("POST /api/v1/power/devices/$id/actions/reboot/confirm", 403) {
            FakeCore.error("PERMISSION_REQUIRED", "Агент питания (aer-power-host) не на связи")
        }
        flow.start(reboot)
        val f = flow.step.value as ActionStep.Failed
        assertEquals("Агент питания (aer-power-host) не на связи", f.message)
        assertFalse(f.retryable)
    }

    @Test
    fun lostAnswerIsRetriedWithTheSameKey() = runTest {
        core.ok("POST /api/v1/bots/$id/actions/restart/confirm", """{"token":"t2","entityId":"$id","action":"restart","summary":"s","risks":[],"expiresAt":""}""")
        var calls = 0
        core.onCall("POST /api/v1/bots/$id/actions/restart") {
            calls++
            if (calls == 1) {
                FakeCore.DROP to ""
            } else {
                200 to FakeCore.ok("""{"id":"a1","entityId":"$id","action":"restart","status":"succeeded","message":"ok","replayed":true,"requestedAt":""}""")
            }
        }
        val target = ActionTarget(ActionTarget.Kind.Bot, id, "Бот", "restart", "Перезапустить", needsConfirmation = true)
        flow.start(target)
        flow.approve()
        val failed = flow.step.value as ActionStep.Failed
        assertTrue("the answer was lost, so a retry is offered", failed.retryable)

        flow.retry()
        val done = flow.step.value as ActionStep.Finished
        assertTrue(done.outcome.replayed)
        val keys = core.requests.filter { it.path.endsWith("/restart") }.map { it.headers["idempotency-key"] }
        assertEquals(2, keys.size)
        assertEquals("both attempts carry one key: Core runs the action once", keys[0], keys[1])
    }

    @Test
    fun unreachableExecutionIsRetryableWithSameKey() = runTest {
        core.ok("POST /api/v1/power/devices/$id/actions/reboot/confirm", confirmation)
        flow.start(reboot)
        val key0 = core.requests.size
        core.close() // answer lost: Core down
        flow.approve()
        val f = flow.step.value as ActionStep.Failed
        assertTrue(f.retryable)
        assertEquals(key0, core.requests.size)
    }
}
