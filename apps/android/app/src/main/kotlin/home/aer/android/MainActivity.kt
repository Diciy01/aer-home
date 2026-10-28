package home.aer.android

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import home.aer.android.data.SceneSource
import home.aer.android.data.SettingsStore
import home.aer.android.data.UiMode
import home.aer.android.ui.AppRoot
import home.aer.android.ui.AppSettings
import home.aer.android.ui.AppViewModel
import home.aer.android.ui.SceneLoader
import home.aer.android.ui.theme.AerTheme
import kotlinx.coroutines.launch

class AerApplication : Application() {
    val settings: AppSettings by lazy { StoreSettings(SettingsStore(this)) }
    val sceneLoader: SceneLoader by lazy { SceneSource(this).let { src -> SceneLoader { src.load(it) } } }
}

/** Adapts the Android store to the view model's settings interface. */
private class StoreSettings(private val store: SettingsStore) : AppSettings {
    override var coreUrl: String?
        get() = store.coreUrl
        set(v) {
            store.coreUrl = v
        }
    override var mode: UiMode?
        get() = store.mode
        set(v) {
            store.mode = v
        }
    override val hasToken get() = store.hasToken
    override fun token() = store.token()
    override fun saveToken(token: String) = store.saveToken(token)
    override fun clearToken() = store.clearToken()
}

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels {
        val app = application as AerApplication
        object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = AppViewModel(app.settings, app.sceneLoader) as T
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Poll Core only while the app is visible.
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { vm.pollForever() } }
        setContent { AerTheme { AppRoot(vm) } }
    }
}
