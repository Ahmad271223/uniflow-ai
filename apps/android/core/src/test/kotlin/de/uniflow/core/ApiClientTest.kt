package de.uniflow.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Nur 2xx (und ausdruecklich erlaubte Status) sind Erfolg: Weiterleitungen folgt der Transport nicht, sie sind ein Fehler. */
class ApiClientTest {
    private class Fixed(val status: Int, val body: String = "", val headers: Map<String, String> = emptyMap()) : HttpTransport {
        var seen: HttpRequest? = null
        override fun send(request: HttpRequest): HttpResponse { seen = request; return HttpResponse(status, headers, body.toByteArray()) }
    }

    @Test
    fun redirectIsAnErrorNotAnEmptyAnswer() {
        val t = Fixed(302, "<html>weiter</html>", mapOf("Location" to "https://login.example/"))
        val e = assertFailsWith<ApiError> { ApiClient("http://pc", t, Auth.Bearer("x")).get("/api/settings") }
        assertEquals(302, e.status)
        assertFalse(e.isNetwork || e.isAuth)
        assertTrue(e.message!!.contains("302") && e.message!!.contains("https://login.example/"), e.message)
        assertEquals("Bearer x", t.seen!!.headers["Authorization"])
        val ohneZiel = assertFailsWith<ApiError> { ApiClient("http://pc", Fixed(301)).post("/api/x", JsonObject(emptyMap())) }
        assertEquals(301, ohneZiel.status); assertEquals("Unerwartete Weiterleitung (301)", ohneZiel.message)
        assertEquals(304, assertFailsWith<ApiError> { ApiClient("http://pc", Fixed(304)).get("/api/x") }.status)
        assertEquals(100, assertFailsWith<ApiError> { ApiClient("http://pc", Fixed(100)).get("/api/x") }.status)
    }

    @Test
    fun successStatusesPass() {
        assertEquals("1", (ApiClient("http://pc", Fixed(200, """{"v":1}""")).get("/api/x") as JsonObject)["v"]!!.jsonPrimitive.content)
        assertEquals("2", (ApiClient("http://pc", Fixed(201, """{"v":2}""")).post("/api/x") as JsonObject)["v"]!!.jsonPrimitive.content)
        assertEquals(JsonNull, ApiClient("http://pc", Fixed(204)).delete("/api/x"))
    }

    @Test
    fun explicitlyAllowedStatusIsReturnedRaw() {
        val r = ApiClient("http://pc", Fixed(302, "", mapOf("location" to "/x"))).raw("GET", "/api/x", allowStatus = setOf(302))
        assertEquals(302, r.status)
        val conflict = ApiClient("http://pc", Fixed(409, """{"detail":"Konflikt","version":3}""")).raw("PUT", "/api/x", allowStatus = setOf(409))
        assertEquals(3, conflict.json().i("version"))
        val e = assertFailsWith<ApiError> { ApiClient("http://pc", Fixed(409, """{"detail":"Konflikt","code":"conflict"}""")).put("/api/x") }
        assertEquals("conflict", e.code)
    }
}
