package home.aer.android.ui

import home.aer.android.data.LoadedScene
import home.aer.android.data.SceneOrigin
import home.aer.android.data.UiMode
import home.aer.core.Link
import home.aer.scene.SceneDocument
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** In-memory settings: what the Android store would hold. */
private class MemorySettings : AppSettings {
    override var coreUrl: String? = null
    override var mode: UiMode? = null
    var stored: String? = null
    override val hasToken get() = stored != null
    override fun token() = stored
    override fun saveToken(token: String) {
        stored = token
    }
    override fun clearToken() {
        stored = null
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModelTest {
    private val settings = MemorySettings()
    private val demo = LoadedScene(SceneDocument(schemaVersion = 1, sceneId = "s"), SceneOrigin.Demo, "демо")
    private lateinit var vm: AppViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        vm = AppViewModel(settings, { demo }, httpTimeoutSeconds = 1)
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun firstStartHasNoModeAndNoApi() {
        assertNull(vm.mode.value)
        assertNull(vm.api())
        assertFalse(vm.isConfigured)
    }

    @Test
    fun modeChoiceIsPersistedAndSetsTheRoot() {
        vm.chooseMode(UiMode.House)
        assertEquals(UiMode.House, settings.mode)
        assertEquals(listOf(Screen.House), vm.stack.value)
        vm.chooseMode(UiMode.Classic)
        assertEquals(listOf(Screen.Overview), vm.stack.value)
    }

    @Test
    fun switchingModesKeepsSettingsAndData() {
        vm.chooseMode(UiMode.Classic)
        assertNull(vm.saveConnection("http://10.0.2.2:1", "tok-123"))
        val repo = vm.repository
        vm.toggleMode()
        assertEquals(UiMode.House, vm.mode.value)
        assertEquals("http://10.0.2.2:1/", settings.coreUrl)
        assertEquals("tok-123", settings.stored)
        assertTrue("same repository: no data is dropped", repo === vm.repository)
        vm.toggleMode()
        assertEquals(listOf(Screen.Overview), vm.stack.value)
    }

    @Test
    fun navigationStackAndBack() {
        vm.chooseMode(UiMode.Classic)
        vm.selectTab(Screen.Devices)
        vm.open(Screen.Device("a"))
        vm.open(Screen.Device("a")) // double tap does not stack twice
        assertEquals(listOf(Screen.Devices, Screen.Device("a")), vm.stack.value)
        assertTrue(vm.back())
        assertFalse("root: the system handles back", vm.back())
    }

    @Test
    fun showInHouseFromClassicPushesHouseWithFocus() {
        vm.chooseMode(UiMode.Classic)
        vm.open(Screen.Device("e1"))
        vm.showInHouse("e1")
        assertEquals(Screen.House, vm.stack.value.last())
        assertEquals("e1", vm.houseFocus.value)
        vm.houseFocusConsumed()
        assertNull(vm.houseFocus.value)
    }

    @Test
    fun connectionValidation() {
        assertNotNull(vm.saveConnection("http://198.51.100.7:8787", "t"))
        assertNull("nothing stored on refusal", settings.coreUrl)
        assertEquals("Введите токен доступа Core", vm.saveConnection("http://192.168.1.2:8787", ""))
        assertEquals("Токен не должен содержать пробелов", vm.saveConnection("http://192.168.1.2:8787", "a b"))
        assertNull(vm.saveConnection("192.168.1.2:8787", "  abc  "))
        assertEquals("abc", settings.stored)
        assertNull("token kept when the field is left empty", vm.saveConnection("http://192.168.1.3:8787", ""))
        assertEquals("abc", settings.stored)
    }

    @Test
    fun unreachableCoreShowsAsUnreachable() = runTest {
        vm.saveConnection("http://127.0.0.1:1", "abc")
        vm.repository.refresh()
        assertEquals(Link.Unreachable, vm.repository.snapshot.value.link)
    }

    @Test
    fun forgettingTheTokenUnconfigures() = runTest {
        vm.saveConnection("http://127.0.0.1:1", "abc")
        vm.forgetToken()
        assertNull(vm.api())
        vm.repository.refresh()
        assertEquals(Link.NotConfigured, vm.repository.snapshot.value.link)
    }
}
