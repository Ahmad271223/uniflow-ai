package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/**
 * Vertrag G1: jeder aufgezeichnete Ablauf aus fixtures/account/contract.json wird mit dem Client nachgespielt.
 * Die Attrappe prueft, dass der Client genau die aufgezeichnete Anfrage schickt, und antwortet mit der
 * aufgezeichneten Antwort; danach muss der Client dieselben Werte bzw. denselben Fehlercode liefern.
 */
class AccountContractTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")
    private val contract = Json.parseToJsonElement(File(fixtures, "account/contract.json").readText()) as JsonObject

    private class Replay(val expectMethod: String, val expectPath: String, val expectBody: JsonElement?, val status: Int, val body: JsonElement?) : HttpTransport {
        var seen: HttpRequest? = null
        override fun send(request: HttpRequest): HttpResponse {
            seen = request
            assertEquals(expectMethod, request.method)
            assertEquals(expectPath, request.url.removePrefix("https://dienst.test"))
            val sent = request.body?.let { Json.parseToJsonElement(it.toString(Charsets.UTF_8)) }
            if (expectBody != null && expectBody !is kotlinx.serialization.json.JsonNull) {
                assertEquals(AnnotationMerge.canonical(expectBody), AnnotationMerge.canonical(sent), "Anfrage an $expectPath")
            }
            val bytes = body?.toString()?.toByteArray() ?: ByteArray(0)
            return HttpResponse(status, mapOf("content-type" to "application/json"), bytes)
        }
    }

    private fun s(o: JsonObject, k: String) = (o[k] as? JsonPrimitive)?.content

    @Test
    fun everyRecordedFlowReplaysWithTheClient() {
        val flows = contract["flows"] as JsonArray
        assertTrue(flows.size >= 30)
        var token = "<token>"
        for (f in flows) {
            f as JsonObject
            val method = s(f, "method")!!
            val path = s(f, "path")!!
            val request = f["request"] as? JsonObject
            val status = (f["status"] as JsonPrimitive).content.toInt()
            val response = f["response"]
            val transport = Replay(method, path, request, status, response)
            val client = ApiClient("https://dienst.test", transport, if (f["auth"]?.jsonPrimitive?.content == "true") Auth.Bearer(token) else Auth.None)
            val api = AccountApi(client)
            val step = s(f, "step")!!
            val run: () -> Any? = when {
                path == "/api/account/register" -> ({ api.register(s(request!!, "email")!!, s(request, "password")!!, s(request, "university")!!, s(request, "device_id"), s(request, "device_name")) })
                path == "/api/account/login" -> ({ api.login(s(request!!, "email")!!, s(request, "password")!!, s(request, "device_id"), s(request, "device_name")) })
                path.startsWith("/api/account/login/") -> ({ api.loginWithIdentity(path.substringAfterLast('/'), s(request!!, "identity_token")!!, s(request, "university"), s(request, "device_id"), s(request, "device_name")) })
                path.startsWith("/api/account/link/") -> ({ api.linkIdentity(path.substringAfterLast('/'), s(request!!, "identity_token")!!) })
                path == "/api/account/info" -> ({ api.info() })
                path == "/api/account/me" -> ({ api.me() })
                path == "/api/account/logout" -> ({ api.logout() })
                path == "/api/account/logout-all" -> ({ api.logoutAll() })
                path == "/api/account/password" -> ({ api.changePassword(s(request!!, "old_password")!!, s(request, "new_password")!!) })
                path == "/api/account/password/reset-request" -> ({ api.requestPasswordReset(s(request!!, "email")!!) })
                path == "/api/account/password/reset" -> ({ api.resetPassword(s(request!!, "token")!!, s(request, "new_password")!!) })
                path == "/api/account/university" -> ({ api.setUniversity(s(request!!, "university")!!) })
                path == "/api/account/delete" -> ({ api.delete(request?.let { s(it, "password") }) })
                method == "GET" -> ({ client.get(path) })
                method == "PUT" -> ({ client.put(path, request) })
                else -> ({ client.post(path, request) })
            }
            if (status >= 400) {
                val e = assertFailsWith<ApiError>(step) { run() }
                assertEquals(status, e.status, step)
                assertEquals((response as? JsonObject)?.let { s(it, "code") }, e.code, step)
                assertEquals((response as? JsonObject)?.let { s(it, "detail") }, e.message, step)
            } else {
                val out = run()
                when (out) {
                    is LoginResult -> {
                        assertEquals(s((response as JsonObject)["user"] as JsonObject, "email"), out.user.email, step)
                        assertEquals("<token>", out.token, step)
                        token = out.token
                    }
                    is Pair<*, *> -> {
                        val u = out.first as User
                        assertEquals(s((response as JsonObject)["user"] as JsonObject, "id"), u.id, step)
                        assertEquals(((response["sessions"] as JsonArray).size), (out.second as List<*>).size, step)
                    }
                    is AccountInfo -> assertEquals(s(response as JsonObject, "mode"), out.mode, step)
                    is User -> assertEquals(s((response as JsonObject)["user"] as JsonObject, "university"), out.university, step)
                }
            }
            assertTrue(transport.seen != null, step)
        }
    }

    @Test
    fun rulesMatchTheClientsExpectations() {
        val rules = contract["rules"] as JsonObject
        assertEquals(10, (rules["password_min"] as JsonPrimitive).content.toInt())
        assertEquals(30, (rules["session_days"] as JsonPrimitive).content.toInt())
        val errors = contract["errors"] as JsonObject
        for (code in listOf("credentials_invalid", "unauthenticated", "email_taken", "locked", "provider_not_configured", "credentials_missing")) {
            assertTrue(errors.containsKey(code), code)
        }
        val endpoints = (contract["endpoints"] as JsonArray).map { (it as JsonObject)["path"]!!.jsonPrimitive.content }.toSet()
        assertTrue(endpoints.containsAll(listOf("/api/account/register", "/api/account/login", "/api/account/me", "/api/account/delete")))
    }

    @Test
    fun authHeadersAndErrorShapes() {
        assertEquals(mapOf("Authorization" to "Bearer abc"), Auth.Bearer("abc").headers())
        assertEquals(mapOf("Cookie" to "lernapp_pin=123456"), Auth.Pin("123456").headers())
        val t = object : HttpTransport {
            override fun send(request: HttpRequest) = HttpResponse(401, emptyMap(), """{"detail":"PIN erforderlich"}""".toByteArray())
        }
        val e = assertFailsWith<ApiError> { ApiClient("http://192.168.1.2:8765", t, Auth.Pin("1")).get("/api/settings") }
        assertTrue(e.isAuth && e.code == null && e.message == "PIN erforderlich")
        val net = object : HttpTransport { override fun send(request: HttpRequest): HttpResponse = throw java.net.ConnectException("refused") }
        val n = assertFailsWith<ApiError> { ApiClient("http://x", net).get("/api/settings") }
        assertTrue(n.isNetwork)
    }
}
