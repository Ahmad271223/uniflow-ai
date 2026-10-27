package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/**
 * Hochschul-Anmeldung auf dem Geraet: dieselben Faelle wie Python (app/learnweb.py, app/filestream.py) und das iPad aus
 * fixtures/learnweb/launch.json - Profile, Startadresse der Moodle-App-Anmeldung, Rueckleitung mit Signatur, Download mit
 * Schluessel, Cookie-Kopfzeile und Anmeldeseite statt Datei.
 */
class LearnwebContractTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")
    private val root = Json.parseToJsonElement(File(fixtures, "learnweb/launch.json").readText()) as JsonObject
    private val launch = root["launch"] as JsonObject

    private fun s(o: JsonObject, k: String): String? = (o[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    @Test
    fun builtInProfilesMatchTheFixture() {
        val profiles = root["profiles"] as JsonObject
        assertEquals(setOf("luh", "hildesheim"), profiles.keys)
        for ((key, p) in profiles) {
            // die Fixture traegt den Schluessel nur als Name des Eintrags
            val fromFixture = UniversityProfile.from(JsonObject((p as JsonObject) + ("key" to JsonPrimitive(key))))
            assertEquals(fromFixture, UniversityProfile.builtIn(key), key)
            assertEquals("uniflow", fromFixture.launchScheme, key)
            assertTrue(fromFixture.isLoginPage(fromFixture.loginUrl), "$key: login_url ist eine Anmeldeseite")
            assertTrue(fromFixture.allows(fromFixture.loginUrl) && fromFixture.allows(fromFixture.loggedInCheckUrl), key)
            assertFalse(fromFixture.isLoginPage(fromFixture.loggedInCheckUrl), key)
            assertTrue(fromFixture.fileHost in fromFixture.hosts, key)
        }
        assertNull(UniversityProfile.builtIn("tuebingen"))
        assertNull(UniversityProfile.builtIn("LUH"), "kein Raten aus Schreibweisen")
        assertEquals("hildesheim", UniversityProfile.builtIn("hildesheim")!!.key)
    }

    @Test
    fun launchUrlLikePython() {
        val base = s(launch, "base")!!
        val passport = s(launch, "passport")!!
        assertEquals(s(launch, "url"), Learnweb.launchUrl(base, passport, s(launch, "scheme")!!))
        assertEquals(s(launch, "url_default_scheme"), Learnweb.launchUrl(base, passport))
        assertEquals(s(launch, "url"), Learnweb.launchUrl("$base/", passport, "uniflow"), "Schraegstrich am Ende egal")
        // Passport und Schema werden kodiert wie urllib.parse.quote(safe='')
        assertTrue(Learnweb.launchUrl(base, "a b/c", "x+y").endsWith("passport=a%20b%2Fc&urlscheme=x%2By"))
        assertTrue(UniversityProfile.builtIn("hildesheim")!!.allows(s(launch, "url")!!), "die WebView darf die Startadresse laden")
    }

    @Test
    fun everyTokenCaseParsesLikePython() {
        val base = s(launch, "base")!!
        val passport = s(launch, "passport")!!
        val cases = root["token_cases"] as JsonArray
        assertTrue(cases.size >= 8)
        for (c in cases) {
            c as JsonObject
            val name = s(c, "name")!!
            val got = Learnweb.parseLaunchToken(s(c, "redirect")!!, base, passport)
            val expect = c["expect"] as? JsonObject
            if (expect == null) {
                assertNull(got, name)
            } else {
                assertNotNull(got, name)
                assertEquals(s(expect, "token"), got.token, name)
                assertEquals(s(expect, "private_token"), got.privateToken, name)
            }
        }
        // dieselbe Rueckleitung mit anderem Passport oder anderer Adresse gilt nicht
        val valid = s(cases[0] as JsonObject, "redirect")!!
        assertNotNull(Learnweb.parseLaunchToken(valid, "$base/", passport), "Schraegstrich am Ende egal")
        assertNull(Learnweb.parseLaunchToken(valid, base, "anderer"))
        assertNull(Learnweb.parseLaunchToken(valid, "https://fremd.example/moodle", passport))
    }

    @Test
    fun downloadWithTokenKeepsTheKeyOutOfTheAddress() {
        val d = root["download_with_token"] as JsonObject
        val expect = d["request"] as JsonObject
        val url = s(d, "url")!!
        val token = s(d, "token")!!
        val r = Learnweb.tokenRequest(url, token)
        assertEquals(s(expect, "method"), r.method)
        assertEquals(s(expect, "url"), r.url)
        assertEquals("token=" + s(expect["form"] as JsonObject, "token"), r.body!!.toString(Charsets.UTF_8))
        assertEquals("application/x-www-form-urlencoded", r.headers["Content-Type"])
        assertEquals("UniFlow-Android", r.headers["User-Agent"])
        assertEquals("*/*", r.headers["Accept"])
        assertFalse(r.url.contains(token), "Schluessel nie in der Adresse")
        assertTrue(Learnweb.isPluginfile(url))
        // ueber die Sitzung des Geraets: dieselbe Anfrage
        val via = DirectDownload.request(url, "learnweb", UniversitySession("hildesheim", emptyList(), learnwebToken = token))
        assertEquals(r.method, via.method); assertEquals(r.url, via.url); assertEquals(r.headers, via.headers)
        assertTrue(r.body!!.contentEquals(via.body!!))
    }

    @Test
    fun cookieHeaderCasesLikePython() {
        val ch = root["cookie_header"] as JsonObject
        val now = ch["now"]!!.jsonPrimitive.long
        val cookies = (ch["cookies"] as JsonArray).map { UniCookie.from(it as JsonObject)!! }
        assertEquals(4, cookies.size)
        assertEquals(-1L, cookies[0].expires); assertNull(cookies[3].expires)
        val session = UniversitySession("luh", cookies)
        val cases = ch["cases"] as JsonArray
        assertEquals(3, cases.size)
        for (c in cases) {
            c as JsonObject
            val url = s(c, "url")!!
            assertEquals(s(c, "header"), session.cookieHeader(url, now), url)
            // der GET fuer Stud.IP traegt genau die Kopfzeile der Sitzung (oder keine); request() nimmt die echte Uhr,
            // deshalb hier nur mit den Cookies ohne Ablauf verglichen
            val sessionCookies = UniversitySession("luh", cookies.filter { it.expires == null || it.expires <= 0 })
            val req = DirectDownload.request(url, "studip", sessionCookies)
            assertEquals(sessionCookies.cookieHeader(url, now).ifEmpty { null }, req.headers["Cookie"], url)
        }
        assertEquals("Seminar_Session=abc", DirectDownload.request(s(cases[0] as JsonObject, "url")!!, "studip",
            UniversitySession("luh", cookies.filter { it.expires == null || it.expires <= 0 })).headers["Cookie"])
        // Rundreise durch die Ablage aendert nichts
        assertEquals(session, UniversitySession.fromJson(session.toJson()))
    }

    @Test
    fun htmlInsteadOfFileCases() {
        val cases = (root["html_instead_of_file"] as JsonObject)["cases"] as JsonArray
        assertEquals(4, cases.size)
        for (c in cases) {
            c as JsonObject
            val expect = c["html"]!!.jsonPrimitive.content == "true"
            val body = s(c, "body_start")!!.toByteArray()
            assertEquals(expect, DirectDownload.looksLikeHtml(s(c, "content_type"), body), s(c, "body_start"))
            val transport = object : HttpTransport {
                override fun send(request: HttpRequest) = HttpResponse(200, mapOf("Content-Type" to s(c, "content_type")!!), body)
            }
            val req = DirectDownload.request("https://studip.uni-hannover.de/sendfile.php?file_id=1", "studip", UniversitySession("luh", emptyList()))
            if (expect) {
                assertFailsWith<DirectDownload.SessionExpired>(s(c, "body_start")) { DirectDownload.fetch(transport, req) }
            } else {
                assertTrue(DirectDownload.fetch(transport, req).contentEquals(body))
            }
        }
    }
}
