package de.uniflow.core

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Eine HTTP-Anfrage; die Transportschicht ist austauschbar (JVM: HttpURLConnection, Tests: Attrappe). */
data class HttpRequest(val method: String, val url: String, val headers: Map<String, String>, val body: ByteArray?)

class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    val text: String get() = body.toString(Charsets.UTF_8)
    fun json(): JsonElement? = if (body.isEmpty()) null else runCatching { Json.parseToJsonElement(text) }.getOrNull()
}

interface HttpTransport {
    fun send(request: HttpRequest): HttpResponse
}

/** Fehler des Servers mit stabilem Code (Vertrag G1: {"detail": "...", "code": "..."}) oder Netzfehler (status 0). */
class ApiError(val status: Int, val code: String?, message: String) : Exception(message) {
    val isAuth: Boolean get() = status == 401
    val isNetwork: Boolean get() = status == 0
}

/** Zugang: UniFlow-Konto (Bearer-Token) oder PC im WLAN (PIN als Cookie). */
sealed class Auth {
    data object None : Auth()
    data class Bearer(val token: String) : Auth()
    data class Pin(val pin: String) : Auth()

    fun headers(): Map<String, String> = when (this) {
        None -> emptyMap()
        is Bearer -> mapOf("Authorization" to "Bearer $token")
        is Pin -> mapOf("Cookie" to "lernapp_pin=$pin")
    }
}

/**
 * Zugriff auf den UniFlow-Server (gehosteter Dienst oder PC im WLAN). Pfade wie in packages/shared-contracts/API.md.
 * Alle Aufrufe sind blockierend; die App ruft sie von einem Hintergrund-Dispatcher.
 */
class ApiClient(baseUrl: String, private val transport: HttpTransport, var auth: Auth = Auth.None) {
    val baseUrl: String = baseUrl.trimEnd('/')
    val json: Json = Json { ignoreUnknownKeys = true; encodeDefaults = false }

    fun get(path: String, query: Map<String, String?> = emptyMap()): JsonElement = call("GET", path, query, null).json() ?: JsonNull
    fun getBytes(path: String, query: Map<String, String?> = emptyMap()): ByteArray = call("GET", path, query, null).body
    fun post(path: String, body: JsonElement? = null, query: Map<String, String?> = emptyMap()): JsonElement =
        call("POST", path, query, body).json() ?: JsonNull
    fun put(path: String, body: JsonElement? = null, query: Map<String, String?> = emptyMap()): JsonElement =
        call("PUT", path, query, body).json() ?: JsonNull
    fun patch(path: String, body: JsonElement? = null): JsonElement = call("PATCH", path, emptyMap(), body).json() ?: JsonNull
    fun delete(path: String): JsonElement = call("DELETE", path, emptyMap(), null).json() ?: JsonNull

    fun url(path: String, query: Map<String, String?> = emptyMap()): String {
        val q = query.filterValues { it != null }.map { (k, v) -> enc(k) + "=" + enc(v!!) }.joinToString("&")
        val sep = if (path.contains('?')) "&" else "?"
        return baseUrl + (if (path.startsWith("/")) path else "/$path") + (if (q.isEmpty()) "" else sep + q)
    }

    /** Antwort inklusive Status, z. B. fuer 409 bei Notizen (kein Fehler, sondern ein Konflikt mit Daten). */
    fun raw(method: String, path: String, body: JsonElement? = null, query: Map<String, String?> = emptyMap(),
            allowStatus: Set<Int> = emptySet()): HttpResponse {
        val headers = HashMap<String, String>()
        headers["Accept"] = "application/json"
        headers.putAll(auth.headers())
        var bytes: ByteArray? = null
        if (body != null) {
            headers["Content-Type"] = "application/json"
            bytes = body.toString().toByteArray(Charsets.UTF_8)
        }
        val resp = try {
            transport.send(HttpRequest(method, url(path, query), headers, bytes))
        } catch (e: Exception) {
            throw ApiError(0, "network", e.message ?: "Keine Verbindung")
        }
        if (resp.status >= 400 && resp.status !in allowStatus) throw errorOf(resp)
        return resp
    }

    private fun call(method: String, path: String, query: Map<String, String?>, body: JsonElement?): HttpResponse =
        raw(method, path, body, query)

    private fun errorOf(resp: HttpResponse): ApiError {
        val j = resp.json() as? JsonObject
        val detail = j?.get("detail")
        val code = (j?.get("code") as? JsonPrimitive)?.takeIf { it.isString }?.content
        val message = when (detail) {
            is JsonPrimitive -> detail.content
            is JsonObject -> (detail["detail"] as? JsonPrimitive)?.content ?: detail.toString()
            null -> if (resp.status == 401) "Anmeldung erforderlich." else "Fehler ${resp.status}"
            else -> detail.toString()
        }
        val codeFromDetail = ((detail as? JsonObject)?.get("code") as? JsonPrimitive)?.content
        return ApiError(resp.status, code ?: codeFromDetail, message)
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    companion object {
        fun obj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.filter { it.second != null }.associate { (k, v) ->
            k to when (v) {
                is JsonElement -> v
                is String -> JsonPrimitive(v)
                is Number -> JsonPrimitive(v)
                is Boolean -> JsonPrimitive(v)
                else -> JsonPrimitive(v.toString())
            }
        })

        fun str(o: JsonElement?, key: String): String? = ((o as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
        fun int(o: JsonElement?, key: String): Int? = ((o as? JsonObject)?.get(key) as? JsonPrimitive)?.content?.toDoubleOrNull()?.toInt()
        fun bool(o: JsonElement?, key: String): Boolean = ((o as? JsonObject)?.get(key) as? JsonPrimitive)?.content == "true"
        fun objOf(e: JsonElement?): JsonObject? = e as? JsonObject
        fun arr(o: JsonElement?, key: String): List<JsonElement> = ((o as? JsonObject)?.get(key) as? kotlinx.serialization.json.JsonArray)?.toList() ?: emptyList()
    }
}

/** Transport mit HttpURLConnection (JVM und Android), ohne weitere Abhaengigkeiten. */
class JvmTransport(private val timeoutMillis: Int = 30_000) : HttpTransport {
    override fun send(request: HttpRequest): HttpResponse {
        val conn = URI(request.url).toURL().openConnection() as HttpURLConnection
        conn.requestMethod = request.method
        conn.connectTimeout = timeoutMillis
        conn.readTimeout = timeoutMillis
        conn.instanceFollowRedirects = false
        request.headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
        if (request.body != null) {
            conn.doOutput = true
            conn.outputStream.use { it.write(request.body) }
        }
        val status = conn.responseCode
        val stream = if (status >= 400) conn.errorStream else conn.inputStream
        val body = ByteArrayOutputStream()
        stream?.use { it.copyTo(body) }
        val headers = conn.headerFields.filterKeys { it != null }.mapKeys { it.key.lowercase() }.mapValues { it.value.joinToString(", ") }
        conn.disconnect()
        return HttpResponse(status, headers, body.toByteArray())
    }
}

/** Kleine Helfer fuer JSON-Objekte aus der API. */
fun JsonElement?.s(key: String): String? = ApiClient.str(this, key)
fun JsonElement?.i(key: String): Int? = ApiClient.int(this, key)
fun JsonElement?.b(key: String): Boolean = ApiClient.bool(this, key)
fun JsonElement?.o(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
fun JsonElement?.list(key: String): List<JsonObject> = ApiClient.arr(this, key).mapNotNull { it as? JsonObject }
val JsonElement?.obj: JsonObject? get() = this as? JsonObject
