package home.aer.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/** JSON settings shared by every Core response: unknown fields are ignored. */
val CoreJson: Json = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
}

/** Everything that can go wrong talking to Core; clients branch on the subtype and [Api.code]. */
sealed class CoreException(message: String) : Exception(message) {
    /** Core could not be reached at all (process down, wrong address, no network, timeout). */
    class Unreachable(val reason: String) : CoreException("Core unreachable: $reason")

    /** No token is stored on this device. */
    class TokenMissing : CoreException("API token is not set")

    /** Core answered with an error envelope (docs/adr/ADR-007). */
    class Api(
        val status: Int,
        val code: String,
        val apiMessage: String,
        val requestId: String?,
        val details: JsonObject?,
    ) : CoreException("$status $code: $apiMessage") {
        val isUnauthorized get() = code == "UNAUTHORIZED"
        val isConflict get() = code == "CONFLICT"
        val isPermissionRequired get() = code == "PERMISSION_REQUIRED"

        /** VALIDATION_FAILED: field → message. */
        val fieldErrors: Map<String, String>
            get() = (details?.get("fields") as? JsonObject)
                ?.mapValues { (it.value as? JsonPrimitive)?.contentOrNull ?: it.value.toString() }
                ?: emptyMap()
    }

    /** The answer is not a Core envelope (wrong service on that port, proxy page…). */
    class InvalidResponse(val status: Int, reason: String) : CoreException(reason)
}

/** Typed access to the AER Core REST API `/api/v1` (contracts/openapi.yaml). */
class CoreClient(
    val baseUrl: HttpUrl,
    private val tokenProvider: () -> String?,
    private val http: OkHttpClient = defaultHttpClient(),
) {
    suspend fun get(path: String, query: Map<String, Any?> = emptyMap()): JsonElement =
        request("GET", path, query)

    suspend fun post(
        path: String,
        body: JsonElement = JsonObject(emptyMap()),
        headers: Map<String, String> = emptyMap(),
    ): JsonElement = request("POST", path, body = body, headers = headers)

    suspend fun <T> decode(strategy: DeserializationStrategy<T>, element: JsonElement): T =
        try {
            CoreJson.decodeFromJsonElement(strategy, element)
        } catch (e: SerializationException) {
            throw CoreException.InvalidResponse(200, "unexpected data shape: ${e.message}")
        } catch (e: IllegalArgumentException) {
            throw CoreException.InvalidResponse(200, "unexpected data shape: ${e.message}")
        }

    /** Sends a request and returns the envelope's `data`. */
    suspend fun request(
        method: String,
        path: String,
        query: Map<String, Any?> = emptyMap(),
        body: JsonElement? = null,
        authenticated: Boolean = true,
        headers: Map<String, String> = emptyMap(),
    ): JsonElement = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url(path, query)).header("Accept", "application/json")
        if (authenticated) {
            val token = tokenProvider()
            if (token.isNullOrBlank()) throw CoreException.TokenMissing()
            builder.header("Authorization", "Bearer $token")
        }
        headers.forEach { (k, v) -> builder.header(k, v) }
        val requestBody = body?.toString()?.toRequestBody(JSON_MEDIA)
        builder.method(method, requestBody ?: if (method == "POST" || method == "PUT") ByteArray(0).toRequestBody(JSON_MEDIA) else null)
        val (status, text) = try {
            http.newCall(builder.build()).execute().use { it.code to it.body.string() }
        } catch (e: IOException) {
            throw CoreException.Unreachable(unreachableReason(e))
        }
        decodeEnvelope(status, text)
    }

    internal fun url(path: String, query: Map<String, Any?>): HttpUrl {
        val b = baseUrl.newBuilder()
        // Keep a base path (reverse proxy prefix), then append api/v1 and the path segments.
        b.encodedPath("/")
        baseUrl.pathSegments.filter { it.isNotEmpty() }.forEach(b::addPathSegment)
        b.addPathSegment("api").addPathSegment("v1")
        path.split('/').filter { it.isNotEmpty() }.forEach(b::addPathSegment)
        query.forEach { (k, v) -> if (v != null) b.addQueryParameter(k, v.toString()) }
        return b.build()
    }

    companion object {
        private val JSON_MEDIA = "application/json".toMediaType()

        fun defaultHttpClient(timeoutSeconds: Long = 8): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .callTimeout(timeoutSeconds + 2, TimeUnit.SECONDS)
            .followRedirects(false)
            .build()

        /** Short Russian reason for a transport failure (the raw text stays in the exception chain). */
        internal fun unreachableReason(e: IOException): String = when (e) {
            is java.net.ConnectException -> "соединение отклонено — Core не запущен или порт закрыт"
            is java.net.SocketTimeoutException, is java.io.InterruptedIOException -> "нет ответа за отведённое время"
            is java.net.UnknownHostException -> "адрес не найден (имя не разрешилось)"
            is java.net.NoRouteToHostException -> "нет маршрута до адреса — проверьте сеть"
            is javax.net.ssl.SSLException -> "ошибка TLS: ${e.message ?: "сертификат не принят"}"
            else -> e.message ?: e.javaClass.simpleName
        }

        internal fun decodeEnvelope(status: Int, text: String): JsonElement {
            val root = try {
                CoreJson.parseToJsonElement(text)
            } catch (_: SerializationException) {
                throw CoreException.InvalidResponse(status, "response is not JSON")
            }
            val obj = root as? JsonObject
                ?: throw CoreException.InvalidResponse(status, "response is not an envelope")
            val requestId = (obj["meta"] as? JsonObject)?.get("requestId")?.let { (it as? JsonPrimitive)?.contentOrNull }
            val error = obj["error"] as? JsonObject
            if (error != null) {
                throw CoreException.Api(
                    status = status,
                    code = (error["code"] as? JsonPrimitive)?.contentOrNull ?: "INVALID_RESPONSE",
                    apiMessage = (error["message"] as? JsonPrimitive)?.contentOrNull ?: "",
                    requestId = requestId,
                    details = error["details"] as? JsonObject,
                )
            }
            if (status >= 300 || !obj.containsKey("data")) {
                throw CoreException.InvalidResponse(status, "unexpected response shape")
            }
            return obj["data"] ?: JsonNull
        }
    }
}
