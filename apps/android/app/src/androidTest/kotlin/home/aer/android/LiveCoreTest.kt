package home.aer.android

import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * End-to-end on a device/emulator against an isolated TEST Core
 * (tools/network-lab + tools/mobile-lab), never a real home Core.
 *
 *   -e aerCoreUrl http://10.0.2.2:18798 -e aerToken <lab token>
 *
 * Without aerToken the live tests are skipped (reported as skipped, not passed).
 * Screenshots: /data/local/tmp/aer-shots/ (survives the uninstall after the run).
 */
@RunWith(AndroidJUnit4::class)
class LiveCoreTest {
    @get:Rule
    val rule = createEmptyComposeRule()

    private val args = InstrumentationRegistry.getArguments()
    private val coreUrl = args.getString("aerCoreUrl") ?: "http://10.0.2.2:18798"
    private val token: String? = args.getString("aerToken")
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private var scenario: ActivityScenario<MainActivity>? = null

    @Before
    fun freshApp() {
        ctx.getSharedPreferences("aer_settings", 0).edit().clear().commit()
        File(ctx.filesDir, "scene-cache.json").delete()
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun close() {
        scenario?.close()
    }

    @Test
    fun classicModeAgainstLabCore() {
        assumeTrue("aerToken not given: live test skipped", token != null)
        rule.onNodeWithTag("mode_classic").performClick()
        shot("c01-settings-first-start")
        configure(coreUrl, token!!)
        rule.waitForTag("settings_test_ok")
        shot("c02-settings-connected")
        rule.onNodeWithTag("nav_back").performClick()

        rule.waitForText("Устройств под наблюдением", substring = true)
        rule.waitForText("Сеть в порядке", substring = true)
        shot("c03-overview")

        rule.onNodeWithTag("tab_Устройства").performClick()
        rule.waitForText("Роутер (стенд)")
        shot("c04-devices")
        rule.onNodeWithText("Роутер (стенд)").performClick()
        rule.waitForText("Мониторинг")
        rule.onNodeWithText("Задержка").assertExistsCompat()
        shot("c05-device-card")
        rule.onNodeWithTag("nav_back").performClick()

        rule.onNodeWithTag("tab_Журнал").performClick()
        rule.waitForText("Активных инцидентов нет")
        rule.onNodeWithTag("journal_tab_Logs").performClick()
        rule.waitForText("Интернет", substring = true)
        shot("c06-journal-logs")

        rule.onNodeWithTag("tab_Сеть").performClick()
        rule.waitForText("Сеть в порядке", substring = true)
        shot("c07-network")
        rule.onNodeWithTag("screen_network").performScrollToNode(hasText("Sunshine (стенд)"))
        shot("c07b-network-sunshine-tv")
        rule.onNodeWithTag("screen_network").performScrollToNode(hasTestTag("network_check_now"))
        rule.onNodeWithTag("network_check_now").performClick()
        rule.waitUntilAny(10_000, "Проверки сети выполнены", "Проверка уже запускалась")
        shot("c08-network-checked")

        rule.onNodeWithTag("tab_Ещё").performClick()
        rule.onNodeWithTag("more_power").performClick()
        rule.waitForText("ПК со Sunshine (стенд)")
        shot("c09-power")
        // «Проверить состояние» needs no confirmation; Core answers with a job (agent absent in the lab).
        rule.onAllNodesWithText("Проверить состояние")[0].performScrollTo().performClick()
        rule.waitUntil(15_000) {
            rule.onAllNodesWithTag("action_result_dialog").fetchSemanticsNodes().isNotEmpty() ||
                rule.onAllNodesWithTag("action_failed_dialog").fetchSemanticsNodes().isNotEmpty()
        }
        shot("c10-power-check-result")
    }

    @Test
    fun houseModeShowsBoundDevicesAndSwitchesModes() {
        assumeTrue("aerToken not given: live test skipped", token != null)
        rule.onNodeWithTag("mode_house").performClick()
        configure(coreUrl, token!!)
        rule.waitForTag("settings_test_ok")
        rule.onNodeWithTag("nav_back").performClick()

        rule.waitForText("Сцена из Core", substring = true)
        rule.waitForText("Всё спокойно", substring = true)
        shot("h01-house")
        rule.onNodeWithTag("room_Сетевая").performClick()
        rule.onNodeWithTag("house_object_Роутер").performScrollTo().performClick()
        rule.waitForTag("house_selected_title")
        rule.onNodeWithTag("house_selected_title").assertTextContains("Роутер (стенд)")
        rule.onNodeWithText("В сети", substring = true).assertExistsCompat()
        shot("h02-house-router-selected")
        rule.onNodeWithTag("house_open_device").performClick()
        rule.waitForText("Мониторинг")
        shot("h03-house-device-card")
        rule.onNodeWithTag("nav_back").performClick()

        // House → Classic → House: data and settings are kept.
        rule.onNodeWithTag("toggle_mode").performClick()
        rule.waitForText("Устройств под наблюдением", substring = true)
        shot("h04-switched-to-classic")
        rule.onNodeWithTag("toggle_mode").performClick()
        rule.waitForTag("house_canvas")
        rule.waitForText("Всё спокойно", substring = true)
        rule.onNodeWithTag("room_Кабинет").performClick()
        rule.onNodeWithTag("house_object_Основной ПК").performScrollTo().performClick()
        rule.onNodeWithTag("house_selected_title").assertTextContains("ПК со Sunshine (стенд)")
        shot("h05-house-again-pc")
    }

    @Test
    fun unreachableCoreIsReportedNotFaked() {
        rule.onNodeWithTag("mode_classic").performClick()
        configure("http://10.0.2.2:1", "x".repeat(43))
        rule.waitForTag("settings_test_failed", 20_000)
        rule.onNodeWithText("Нет связи с Core", substring = true).assertExistsCompat()
        shot("e01-settings-unreachable")
        rule.onNodeWithTag("nav_back").performClick()
        rule.waitForText("Нет связи с Core", substring = true)
        rule.onAllNodesWithText("Устройств под наблюдением", substring = true).assertCountCompat(0)
        rule.waitForText("Нет данных: Core недоступен", substring = true)
        rule.onAllNodesWithText("Ждём ответа Core", substring = true).assertCountCompat(0)
        shot("e02-overview-unreachable")
    }

    /**
     * Outage and recovery, driven together with tools/mobile-lab/outage.py on the
     * host: the test signals «online» with a marker file, the host freezes the
     * lab Core (SIGSTOP), the test waits for the outage banner, the host resumes it.
     */
    @Test
    fun coreOutageAndRecovery() {
        assumeTrue("needs -e aerOutage 1 and tools/mobile-lab/outage.py", token != null && args.getString("aerOutage") == "1")
        shell("rm -f /data/local/tmp/aer-outage-ready /data/local/tmp/aer-outage-seen")
        rule.onNodeWithTag("mode_classic").performClick()
        configure(coreUrl, token!!)
        rule.waitForTag("settings_test_ok")
        rule.onNodeWithTag("nav_back").performClick()
        rule.waitForText("Устройств под наблюдением", substring = true)
        shell("touch /data/local/tmp/aer-outage-ready")
        rule.waitForText("Нет связи с Core", substring = true, timeout = 90_000)
        rule.onNodeWithText("Показаны данные, полученные", substring = true).assertExistsCompat()
        rule.onNodeWithText("Устройств под наблюдением", substring = true).assertExistsCompat() // last known data kept
        shot("r01-outage-last-known-data")
        shell("touch /data/local/tmp/aer-outage-seen")
        rule.waitUntil(90_000) { rule.onAllNodes(hasText("Нет связи с Core", substring = true)).fetchSemanticsNodes().isEmpty() }
        rule.waitForText("Обновлено: только что", substring = true, timeout = 30_000)
        shot("r02-recovered")
    }

    @Test
    fun rejectedTokenIsAnAuthError() {
        assumeTrue("aerToken not given: live test skipped", token != null)
        rule.onNodeWithTag("mode_classic").performClick()
        configure(coreUrl, "wrong-" + "0".repeat(40))
        rule.waitForTag("settings_test_failed")
        rule.onNodeWithText("отклонил токен", substring = true).assertExistsCompat()
        shot("e03-token-rejected")
    }

    @Test
    fun publicCleartextAddressIsRefused() {
        rule.onNodeWithTag("mode_classic").performClick()
        rule.onNodeWithTag("settings_url").performTextInput("http://198.51.100.7:8787")
        rule.onNodeWithTag("settings_token").performTextInput("t".repeat(43))
        rule.onNodeWithTag("settings_save").performClick()
        rule.waitForText("публичный", substring = true)
        rule.onAllNodesWithTag("settings_test_ok").assertCountCompat(0)
        shot("e04-public-address-refused")
    }

    private fun configure(url: String, tok: String) {
        rule.waitForTag("settings_url")
        rule.onNodeWithTag("settings_url").performTextClearance()
        rule.onNodeWithTag("settings_url").performTextInput(url)
        rule.onNodeWithTag("settings_token").performTextInput(tok)
        rule.onNodeWithTag("settings_save").performClick()
    }

    private fun shot(name: String) {
        rule.waitForIdle()
        shell("mkdir -p /data/local/tmp/aer-shots")
        shell("screencap -p /data/local/tmp/aer-shots/$name.png")
    }

    private fun shell(cmd: String) {
        val pfd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(cmd)
        ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes() } // wait until done
    }
}

private fun ComposeTestRule.waitForTag(tag: String, timeout: Long = 15_000) =
    waitUntil(timeout) { onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }

private fun ComposeTestRule.waitForText(text: String, substring: Boolean = false, timeout: Long = 15_000) =
    waitUntil(timeout) { onAllNodes(hasText(text, substring = substring)).fetchSemanticsNodes().isNotEmpty() }

private fun ComposeTestRule.waitUntilAny(timeout: Long, vararg texts: String) =
    waitUntil(timeout) { texts.any { onAllNodes(hasText(it, substring = true)).fetchSemanticsNodes().isNotEmpty() } }

private fun SemanticsNodeInteraction.assertExistsCompat() = assertExists()

private fun SemanticsNodeInteraction.assertTextContains(s: String) =
    this.assert(hasText(s, substring = true) or hasAnyDescendant(hasText(s, substring = true)))

private fun androidx.compose.ui.test.SemanticsNodeInteractionCollection.assertCountCompat(n: Int) =
    check(fetchSemanticsNodes().size == n) { "expected $n nodes, got ${fetchSemanticsNodes().size}" }
