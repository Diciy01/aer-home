package home.aer.core

import com.sun.net.httpserver.HttpServer
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList

/** A recorded request to the fake Core. */
data class Recorded(val method: String, val path: String, val query: String?, val headers: Map<String, String>, val body: String)

/**
 * Minimal stand-in for AER Core on 127.0.0.1 (JDK HttpServer): routes by
 * "METHOD /path" to a status and a raw body, records every request.
 */
class FakeCore : AutoCloseable {
    private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    private val routes = mutableMapOf<String, () -> Pair<Int, String>>()
    val requests = CopyOnWriteArrayList<Recorded>()

    init {
        server.createContext("/") { ex ->
            val body = ex.requestBody.readBytes().decodeToString()
            val headers = ex.requestHeaders.entries.associate { it.key.lowercase() to it.value.joinToString(",") }
            requests += Recorded(ex.requestMethod, ex.requestURI.path, ex.requestURI.rawQuery, headers, body)
            val handler = routes["${ex.requestMethod} ${ex.requestURI.path}"]
            val (status, text) = handler?.invoke() ?: (404 to error("NOT_FOUND", "no route"))
            if (status == DROP) {
                ex.close() // connection cut before any answer: the client sees an I/O error
                return@createContext
            }
            val bytes = text.encodeToByteArray()
            ex.responseHeaders.add("Content-Type", "application/json")
            ex.sendResponseHeaders(status, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            if (bytes.isNotEmpty()) ex.responseBody.use { it.write(bytes) } else ex.close()
        }
        server.start()
    }

    val url get() = "http://127.0.0.1:${server.address.port}".toHttpUrl()

    fun on(route: String, status: Int = 200, body: () -> String) {
        routes[route] = { status to body() }
    }

    /** A handler that picks the status per call (e.g. [DROP] first, then an answer). */
    fun onCall(route: String, handler: () -> Pair<Int, String>) {
        routes[route] = handler
    }

    fun ok(route: String, data: String) = on(route) { ok(data) }

    fun api(token: String? = TOKEN) = CoreApi(CoreClient(url, { token }, CoreClient.defaultHttpClient(timeoutSeconds = 2)))

    override fun close() = server.stop(0)

    companion object {
        const val TOKEN = "test-token-not-a-secret"

        /** Status meaning "drop the connection without answering". */
        const val DROP = -1
        fun ok(data: String) = """{"data":$data,"meta":{"requestId":"r1","apiVersion":"v1"}}"""
        fun error(code: String, message: String, details: String = "null") =
            """{"error":{"code":"$code","message":"$message","details":$details},"meta":{"requestId":"r2","apiVersion":"v1"}}"""

        val SYSTEM_ALL = """{"coreVersion":"0.1.0-dev","apiVersion":"v1","mode":"development","demo":true,"uptimeSeconds":5,
            "modules":[{"name":"registry","enabled":true},{"name":"monitoring","enabled":true},{"name":"network","enabled":true},
            {"name":"power","enabled":true},{"name":"bots","enabled":true},{"name":"scene","enabled":true}]}"""
    }
}
