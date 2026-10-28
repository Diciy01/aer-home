package home.aer.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import home.aer.android.data.LoadedScene
import home.aer.android.data.UiMode
import home.aer.core.ActionFlow
import home.aer.core.ActionStep
import home.aer.core.ActionTarget
import home.aer.core.CoreApi
import home.aer.core.CoreClient
import home.aer.core.CoreException
import home.aer.core.EndpointCheck
import home.aer.core.HomeRepository
import home.aer.core.Link
import home.aer.core.checkEndpoint
import home.aer.core.describeError
import home.aer.core.powerJobFinished
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.time.Duration

/** Settings the view model needs; Android storage in the app, in-memory in tests. */
interface AppSettings {
    var coreUrl: String?
    var mode: UiMode?
    val hasToken: Boolean
    fun token(): String?
    fun saveToken(token: String)
    fun clearToken()
}

fun interface SceneLoader {
    suspend fun load(api: CoreApi?): LoadedScene
}

/** Screens of both modes. Classic tabs and the house are roots; the rest are pushed on top. */
sealed interface Screen {
    data object Overview : Screen
    data object Devices : Screen
    data object Journal : Screen
    data object Network : Screen
    data object More : Screen
    data object Power : Screen
    data object Bots : Screen
    data object Settings : Screen
    data object House : Screen
    data class Device(val id: String) : Screen
    data class Incident(val id: String) : Screen
    data class Bot(val id: String) : Screen
}

val classicTabs = listOf(Screen.Overview, Screen.Devices, Screen.Journal, Screen.Network, Screen.More)

/** Result of «Проверить подключение» in the settings. */
sealed interface ConnectionTest {
    data object Idle : ConnectionTest
    data object Running : ConnectionTest
    data class Ok(val text: String) : ConnectionTest
    data class Failed(val text: String) : ConnectionTest
}

class AppViewModel(
    private val settings: AppSettings,
    private val sceneLoader: SceneLoader,
    private val httpTimeoutSeconds: Long = 8,
) : ViewModel() {
    val repository = HomeRepository(::api)
    val actions = ActionFlow(::api)

    private val _mode = MutableStateFlow(settings.mode)
    val mode: StateFlow<UiMode?> = _mode.asStateFlow()

    private val _stack = MutableStateFlow(listOf(rootFor(settings.mode)))
    val stack: StateFlow<List<Screen>> = _stack.asStateFlow()

    private val _scene = MutableStateFlow<LoadedScene?>(null)
    val scene: StateFlow<LoadedScene?> = _scene.asStateFlow()

    /** Entity the house should select when it opens (from «Показать в доме»). */
    private val _houseFocus = MutableStateFlow<String?>(null)
    val houseFocus: StateFlow<String?> = _houseFocus.asStateFlow()

    private val _connectionTest = MutableStateFlow<ConnectionTest>(ConnectionTest.Idle)
    val connectionTest: StateFlow<ConnectionTest> = _connectionTest.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)

    /** One-off notice for a snackbar. */
    val message: StateFlow<String?> = _message.asStateFlow()

    private var cachedApi: Pair<String, CoreApi>? = null
    private var jobPoll: Job? = null

    val coreUrl get() = settings.coreUrl
    val hasToken get() = settings.hasToken
    val isConfigured get() = settings.coreUrl != null && settings.hasToken

    /** Api for the current settings; null when not configured. The token is read per request. */
    fun api(): CoreApi? {
        val url = settings.coreUrl?.toHttpUrlOrNull() ?: return null
        if (!settings.hasToken) return null
        cachedApi?.let { (u, a) -> if (u == url.toString()) return a }
        return CoreApi(CoreClient(url, settings::token, CoreClient.defaultHttpClient(httpTimeoutSeconds))).also { cachedApi = url.toString() to it }
    }

    // --- modes and navigation ---

    fun chooseMode(mode: UiMode) {
        settings.mode = mode
        _mode.value = mode
        _stack.value = listOf(rootFor(mode))
    }

    /** Switches «Дом» ↔ «Классика». Data and settings stay; only the screen stack is reset. */
    fun toggleMode() = chooseMode(if (_mode.value == UiMode.House) UiMode.Classic else UiMode.House)

    fun selectTab(tab: Screen) {
        _stack.value = listOf(tab)
    }

    fun open(screen: Screen) {
        if (_stack.value.lastOrNull() != screen) _stack.value = _stack.value + screen
    }

    /** Returns false at a root (the system then closes the app). */
    fun back(): Boolean {
        if (_stack.value.size <= 1) return false
        _stack.value = _stack.value.dropLast(1)
        return true
    }

    fun showInHouse(entityId: String) {
        _houseFocus.value = entityId
        if (_mode.value == UiMode.House) _stack.value = listOf(Screen.House) else open(Screen.House)
    }

    fun houseFocusConsumed() {
        _houseFocus.value = null
    }

    private fun rootFor(mode: UiMode?): Screen = if (mode == UiMode.House) Screen.House else Screen.Overview

    // --- data ---

    suspend fun pollForever(interval: Duration = POLL_INTERVAL) {
        while (true) {
            repository.refresh()
            delay(interval.toMillis())
        }
    }

    fun refreshNow() = viewModelScope.launch { repository.refresh() }

    fun loadScene() = viewModelScope.launch { _scene.value = sceneLoader.load(api()) }

    /** Runs a one-off read for a detail screen. */
    suspend fun <T> load(block: suspend CoreApi.() -> T): Result<T> {
        val a = api() ?: return Result.failure(CoreException.TokenMissing())
        return try {
            Result.success(a.block())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Result.failure(e)
        }
    }

    fun networkCheckNow() = viewModelScope.launch {
        load { networkCheckNow() }
            .onSuccess { repository.applyNetwork(it); _message.value = "Проверки сети выполнены" }
            .onFailure { e ->
                _message.value = if (e is CoreException.Api && e.isConflict) {
                    "Проверка уже запускалась только что — подождите несколько секунд"
                } else {
                    describeError(e)
                }
            }
    }

    fun acknowledge(incidentId: String, onDone: () -> Unit = {}) = viewModelScope.launch {
        load { acknowledge(incidentId) }
            .onSuccess { repository.applyIncident(it); _message.value = "Инцидент подтверждён"; onDone() }
            .onFailure { _message.value = describeError(it) }
    }

    fun messageShown() {
        _message.value = null
    }

    // --- power and bot actions (Core's confirm → execute) ---

    fun startAction(target: ActionTarget) = viewModelScope.launch {
        actions.start(target)
        afterAction()
    }

    fun approveAction() = viewModelScope.launch {
        actions.approve()
        afterAction()
    }

    fun retryAction() = viewModelScope.launch {
        actions.retry()
        afterAction()
    }

    fun dismissAction() {
        jobPoll?.cancel()
        actions.dismiss()
        refreshNow()
    }

    private fun afterAction() {
        val done = actions.step.value as? ActionStep.Finished ?: return
        val jobId = done.outcome.powerJobId
        if (jobId == null) {
            refreshNow()
            return
        }
        jobPoll?.cancel()
        jobPoll = viewModelScope.launch {
            // Power jobs are asynchronous (202): follow the job until Core reports a final state.
            repeat(JOB_POLLS) {
                delay(JOB_POLL_INTERVAL_MS)
                val job = load { powerJob(jobId) }.getOrNull() ?: return@repeat
                actions.updatePowerJob(job)
                if (powerJobFinished(job.state)) {
                    repository.refresh()
                    return@launch
                }
            }
        }
    }

    // --- connection settings ---

    /** Validates and stores the address and (if given) a new token. Returns an error text or null. */
    fun saveConnection(url: String, token: String?): String? {
        val check = checkEndpoint(url)
        if (check is EndpointCheck.Invalid) return check.message
        val ok = check as EndpointCheck.Ok
        val newToken = token?.trim()?.takeIf { it.isNotEmpty() }
        if (newToken == null && !settings.hasToken) return "Введите токен доступа Core"
        if (newToken != null) {
            if (newToken.any { it.isWhitespace() }) return "Токен не должен содержать пробелов"
            try {
                settings.saveToken(newToken)
            } catch (e: Exception) {
                return "Не удалось надёжно сохранить токен: ${e.message}"
            }
        }
        val changed = settings.coreUrl != ok.url.toString()
        settings.coreUrl = ok.url.toString()
        cachedApi = null
        if (changed) {
            repository.reset()
            _scene.value = null
        }
        _connectionTest.value = ConnectionTest.Idle
        refreshNow()
        return null
    }

    fun forgetToken() {
        settings.clearToken()
        cachedApi = null
        repository.reset()
        refreshNow()
    }

    /** Health (public) first, then an authenticated call: tells «Core off» from «token rejected». */
    fun testConnection() = viewModelScope.launch {
        _connectionTest.value = ConnectionTest.Running
        val a = api()
        if (a == null) {
            _connectionTest.value = ConnectionTest.Failed("Сначала сохраните адрес и токен")
            return@launch
        }
        _connectionTest.value = try {
            a.health()
            val info = a.systemInfo()
            ConnectionTest.Ok(
                "Core ${info.coreVersion} (${info.mode}${if (info.demo) ", демо-данные" else ""}) отвечает, токен принят",
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: CoreException.Api) {
            ConnectionTest.Failed(if (e.isUnauthorized) "Core доступен, но отклонил токен" else describeError(e))
        } catch (e: Throwable) {
            ConnectionTest.Failed(describeError(e))
        }
        repository.refresh()
    }

    companion object {
        val POLL_INTERVAL: Duration = Duration.ofSeconds(10)

        /** Data older than three missed polls is shown as outdated. */
        val STALE_AFTER: Duration = Duration.ofSeconds(30)
        private const val JOB_POLLS = 45
        private const val JOB_POLL_INTERVAL_MS = 2000L
    }
}

fun Link.isProblem() = this == Link.Unreachable || this == Link.Unauthorized || this == Link.Incompatible
