package home.aer.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Duration
import java.time.Instant

/** Connection to Core as the user sees it. */
enum class Link { NotConfigured, Connecting, Online, Unauthorized, Unreachable, Incompatible }

/** Parts of the snapshot that are fetched independently; one failing does not hide the others. */
enum class Section { Monitoring, Registry, Network, Power, Bots, Incidents }

/**
 * Everything the mobile client shows, as last received from Core. Data is
 * never invented: a section that has not loaded is null, and after a failed
 * refresh the previous values stay but [isStale] turns true.
 */
data class HomeSnapshot(
    val link: Link = Link.NotConfigured,
    val linkMessage: String = "",
    val system: SystemInfo? = null,
    val lastSuccessAt: Instant? = null,
    val overview: MonitoringOverview? = null,
    val states: Map<String, EntityState> = emptyMap(),
    val entities: List<Entity>? = null,
    val types: Map<String, EntityType> = emptyMap(),
    val network: NetworkOverview? = null,
    val power: List<PowerDevice>? = null,
    val bots: List<Bot>? = null,
    val incidents: List<Incident>? = null,
    val sectionErrors: Map<Section, String> = emptyMap(),
    /** Module disabled in Core (system/info): the section shows that instead of an error. */
    val disabled: Set<Section> = emptySet(),
) {
    fun isStale(now: Instant, maxAge: Duration): Boolean =
        link != Link.Online || lastSuccessAt == null || Duration.between(lastSuccessAt, now) > maxAge

    fun entity(id: String?): Entity? = if (id == null) null else entities?.firstOrNull { it.id == id }

    fun typeLabel(type: String): String = types[type]?.label?.ifEmpty { null } ?: type

    val hasData get() = lastSuccessAt != null
}

/**
 * Polls Core and keeps one [HomeSnapshot]. The api is created from the
 * current settings each time ([apiProvider] returns null when no address or
 * token is configured), so changing settings needs no restart.
 */
class HomeRepository(
    private val apiProvider: () -> CoreApi?,
    private val clock: () -> Instant = Instant::now,
) {
    private val _snapshot = MutableStateFlow(HomeSnapshot())
    val snapshot: StateFlow<HomeSnapshot> = _snapshot.asStateFlow()
    private val mutex = Mutex()

    /** Forgets everything (another Core was configured). */
    fun reset() {
        _snapshot.value = HomeSnapshot()
    }

    suspend fun refresh() = mutex.withLock { refreshLocked() }

    private suspend fun refreshLocked() {
        val api = apiProvider()
        if (api == null) {
            _snapshot.update { it.copy(link = Link.NotConfigured, linkMessage = "Укажите адрес Core и токен в настройках") }
            return
        }
        if (_snapshot.value.lastSuccessAt == null) _snapshot.update { it.copy(link = Link.Connecting, linkMessage = "") }

        val system = try {
            api.systemInfo()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            val link = when {
                e is CoreException.Unreachable -> Link.Unreachable
                e is CoreException.TokenMissing -> Link.Unauthorized
                e is CoreException.Api && e.isUnauthorized -> Link.Unauthorized
                e is CoreException.InvalidResponse -> Link.Incompatible
                else -> Link.Unreachable
            }
            _snapshot.update { it.copy(link = link, linkMessage = describeError(e)) }
            return
        }

        val disabled = buildSet {
            if (!system.moduleEnabled("monitoring")) { add(Section.Monitoring); add(Section.Incidents) }
            if (!system.moduleEnabled("network")) add(Section.Network)
            if (!system.moduleEnabled("power")) add(Section.Power)
            if (!system.moduleEnabled("bots")) add(Section.Bots)
        }
        val errors = mutableMapOf<Section, String>()
        val prev = _snapshot.value

        suspend fun <T> section(s: Section, block: suspend () -> T): T? {
            if (s in disabled) return null
            return try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                errors[s] = describeError(e)
                null
            }
        }

        coroutineScope {
            val overview = async { section(Section.Monitoring) { api.monitoringOverview() } }
            val states = async { section(Section.Monitoring) { api.states() } }
            val entities = async { section(Section.Registry) { api.entities() } }
            val types = async { if (prev.types.isEmpty()) section(Section.Registry) { api.entityTypes() } else null }
            val network = async { section(Section.Network) { api.networkOverview() } }
            val power = async { section(Section.Power) { api.powerDevices() } }
            val bots = async { section(Section.Bots) { api.bots() } }
            val incidents = async { section(Section.Incidents) { api.incidents("active").items } }

            val st = states.await()
            val ty = types.await()
            _snapshot.update { s ->
                s.copy(
                    link = Link.Online,
                    linkMessage = "",
                    system = system,
                    lastSuccessAt = clock(),
                    overview = overview.await() ?: s.overview.takeUnless { Section.Monitoring in disabled },
                    states = st?.associateBy { it.entityId } ?: s.states,
                    entities = entities.await() ?: s.entities,
                    types = ty?.associateBy { it.id } ?: s.types,
                    network = network.await() ?: s.network.takeUnless { Section.Network in disabled },
                    power = power.await() ?: s.power.takeUnless { Section.Power in disabled },
                    bots = bots.await() ?: s.bots.takeUnless { Section.Bots in disabled },
                    incidents = incidents.await() ?: s.incidents.takeUnless { Section.Incidents in disabled },
                    sectionErrors = errors.toMap(),
                    disabled = disabled,
                )
            }
        }
    }

    /** Applies a fresher network overview (from «Проверить сейчас») without a full refresh. */
    fun applyNetwork(overview: NetworkOverview) = _snapshot.update { it.copy(network = overview) }

    fun applyIncident(incident: Incident) = _snapshot.update { s ->
        s.copy(incidents = s.incidents?.map { if (it.id == incident.id) incident else it })
    }
}
