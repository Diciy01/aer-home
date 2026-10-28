package home.aer.android.data

import android.content.Context
import home.aer.core.CoreApi
import home.aer.core.CoreJson
import home.aer.core.describeError
import home.aer.scene.SceneCodec
import home.aer.scene.SceneDocument
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Where the scene on screen came from; the house tells the user. */
enum class SceneOrigin { Core, Cache, Demo }

data class LoadedScene(val document: SceneDocument, val origin: SceneOrigin, val note: String)

/**
 * The house uses Core's stored scene (the same document the desktop editor
 * saves). Offline it shows the last one received; with no scene in Core at
 * all it shows the bundled demo layout, clearly labelled as such.
 */
class SceneSource(private val context: Context) {
    private val cache = File(context.filesDir, "scene-cache.json")

    suspend fun load(api: CoreApi?): LoadedScene = withContext(Dispatchers.IO) {
        var problem: String? = null
        if (api != null) {
            try {
                val summary = api.scenes().firstOrNull()
                if (summary == null) return@withContext demo("В Core нет сохранённой сцены — показана демо-планировка")
                val record = api.scene(summary.id)
                val doc = SceneCodec.decode(record.document)
                writeCache(record.document.toString())
                return@withContext LoadedScene(doc, SceneOrigin.Core, "Сцена из Core: «${record.name}»")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                problem = if (e is home.aer.scene.SceneFormatException) e.message else describeError(e)
            }
        }
        readCache()?.let { return@withContext LoadedScene(it, SceneOrigin.Cache, "Последняя полученная сцена (${problem ?: "Core не настроен"})") }
        demo("Демо-планировка: сцена из Core недоступна (${problem ?: "Core не настроен"})")
    }

    private fun demo(note: String): LoadedScene {
        val text = context.assets.open("scenes/demo_home.scene.json").use { it.readBytes().decodeToString() }
        return LoadedScene(SceneCodec.decode(text), SceneOrigin.Demo, note)
    }

    private fun readCache(): SceneDocument? = try {
        if (cache.exists()) SceneCodec.decode(cache.readText()) else null
    } catch (_: Exception) {
        // A damaged cache is set aside, never trusted.
        cache.renameTo(File(cache.parentFile, "scene-cache.corrupt-${System.currentTimeMillis()}.json"))
        null
    }

    private fun writeCache(json: String) {
        // Validate before replacing the previous copy; atomic rename.
        CoreJson.parseToJsonElement(json)
        val tmp = File(cache.parentFile, "scene-cache.json.tmp")
        tmp.writeText(json)
        tmp.renameTo(cache)
    }
}
