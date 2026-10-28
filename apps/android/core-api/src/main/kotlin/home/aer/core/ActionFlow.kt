package home.aer.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A power or bot action the user asked for. */
data class ActionTarget(
    val kind: Kind,
    val entityId: String,
    val entityName: String,
    val action: String,
    val label: String,
    /** Core requires a confirmation token (every power action except check; bot actions with confirm=true). */
    val needsConfirmation: Boolean,
    val targetOs: String? = null,
) {
    enum class Kind { Power, Bot }
}

/** What Core said before the user confirms. The token stays inside [ActionFlow]. */
data class ActionPreview(
    val summary: String,
    val risks: List<String>,
    val checks: List<PowerCheck>,
    val expiresAt: String,
)

data class ActionOutcome(
    val ok: Boolean,
    val title: String,
    val message: String,
    /** The power agent ran in check mode: nothing was really done. */
    val simulated: Boolean = false,
    val powerJobId: String? = null,
    val replayed: Boolean = false,
)

sealed interface ActionStep {
    data object Idle : ActionStep
    data class Preparing(val target: ActionTarget) : ActionStep
    data class AwaitingUser(val target: ActionTarget, val preview: ActionPreview) : ActionStep
    data class Running(val target: ActionTarget) : ActionStep
    data class Finished(val target: ActionTarget, val outcome: ActionOutcome) : ActionStep

    /** [retryable] when the request may not have reached Core; a retry reuses the same idempotency key. */
    data class Failed(val target: ActionTarget, val message: String, val retryable: Boolean) : ActionStep
}

/**
 * Core's confirm → execute protocol (ADR-012, ADR-014) for one action at a
 * time. The client only relays: Core decides availability, issues the
 * single-use token and runs the action; nothing is reported as done unless
 * Core's answer says so.
 */
class ActionFlow(private val api: () -> CoreApi?) {
    private val _step = MutableStateFlow<ActionStep>(ActionStep.Idle)
    val step: StateFlow<ActionStep> = _step.asStateFlow()

    private var token: String? = null
    private var idempotencyKey: String? = null

    /** Asks Core for the confirmation (or runs a no-confirmation action right away). */
    suspend fun start(target: ActionTarget) {
        token = null
        idempotencyKey = CoreApi.newIdempotencyKey()
        if (!target.needsConfirmation) return execute(target)
        _step.value = ActionStep.Preparing(target)
        val core = api() ?: return fail(target, "Core не настроен", false)
        try {
            val preview = when (target.kind) {
                ActionTarget.Kind.Power -> core.confirmPower(target.entityId, target.action, target.targetOs).let {
                    token = it.token
                    ActionPreview(it.summary, it.risks, it.checks, it.expiresAt)
                }
                ActionTarget.Kind.Bot -> core.confirmBot(target.entityId, target.action).let {
                    token = it.token
                    ActionPreview(it.summary, it.risks, emptyList(), it.expiresAt)
                }
            }
            _step.value = ActionStep.AwaitingUser(target, preview)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            fail(target, describeError(e), false)
        }
    }

    /** The user confirmed the preview. */
    suspend fun approve() {
        val s = _step.value as? ActionStep.AwaitingUser ?: return
        execute(s.target)
    }

    /** Repeats a request whose answer was lost; Core replays the first result for the same key. */
    suspend fun retry() {
        val s = _step.value as? ActionStep.Failed ?: return
        if (s.retryable) execute(s.target)
    }

    fun dismiss() {
        token = null
        idempotencyKey = null
        _step.value = ActionStep.Idle
    }

    private suspend fun execute(target: ActionTarget) {
        val key = idempotencyKey ?: CoreApi.newIdempotencyKey().also { idempotencyKey = it }
        _step.value = ActionStep.Running(target)
        val core = api() ?: return fail(target, "Core не настроен", false)
        try {
            val outcome = when (target.kind) {
                ActionTarget.Kind.Power -> core.runPower(target.entityId, target.action, token, key, target.targetOs).let { job ->
                    val st = powerJobState(job.state)
                    ActionOutcome(
                        ok = job.state !in setOf("failed", "rejected", "timeout"),
                        title = st.label,
                        message = job.message,
                        simulated = job.simulated || job.state == "simulated",
                        powerJobId = job.id,
                        replayed = job.replayed,
                    )
                }
                ActionTarget.Kind.Bot -> core.runBot(target.entityId, target.action, token, key).let { rec ->
                    ActionOutcome(
                        ok = rec.status == "succeeded" || rec.status == "running",
                        title = botActionStatus(rec.status).label,
                        message = rec.message,
                        replayed = rec.replayed,
                    )
                }
            }
            token = null
            _step.value = ActionStep.Finished(target, outcome)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // Lost answer: the action may have started; only a retry with the same key is safe.
            fail(target, describeError(e), retryable = e is CoreException.Unreachable)
        }
    }

    /** Applies a later power job state (polling after a 202). */
    fun updatePowerJob(job: PowerJob) {
        val s = _step.value as? ActionStep.Finished ?: return
        if (s.outcome.powerJobId != job.id) return
        _step.value = s.copy(
            outcome = s.outcome.copy(
                ok = job.state !in setOf("failed", "rejected", "timeout"),
                title = powerJobState(job.state).label,
                message = job.message,
                simulated = job.simulated || job.state == "simulated",
            ),
        )
    }

    private fun fail(target: ActionTarget, message: String, retryable: Boolean) {
        _step.value = ActionStep.Failed(target, message, retryable)
    }
}
