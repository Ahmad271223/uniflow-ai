package de.uniflow.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Hochschul-Anmeldung in der WebView, Sitzung des Geraets und direkter Download (University.kt), ohne Netz. */
class UniversityTest {
    private val luh = UniversityProfile.builtIn("luh")!!
    private val hildesheim = UniversityProfile.builtIn("hildesheim")!!
    private val studipSession = UniversitySession("luh", listOf(UniCookie("Seminar_Session", "abc", "studip.uni-hannover.de")))
    private val studipUrl = "https://studip.uni-hannover.de/sendfile.php?type=0&file_id=abc"
    private val learnwebUrl = "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/21/mod_resource/content/1/Blatt%201.pdf"

    private class Fixed(val status: Int, val body: ByteArray, val headers: Map<String, String> = emptyMap()) : HttpTransport {
        var seen: HttpRequest? = null
        override fun send(request: HttpRequest): HttpResponse { seen = request; return HttpResponse(status, headers, body) }
    }

    private class Recorder(val body: String, val status: Int = 200) : HttpTransport {
        val seen = ArrayList<HttpRequest>()
        override fun send(request: HttpRequest): HttpResponse {
            seen += request
            return HttpResponse(status, mapOf("content-type" to "application/json"), body.toByteArray())
        }
    }

    // ---------------------------------------------------------------- Profil

    @Test
    fun allowsOnlyHttpsOnKnownHostsAndTheOwnScheme() {
        assertTrue(luh.allows("https://studip.uni-hannover.de/dispatch.php/my_courses"))
        assertTrue(luh.allows("https://STUDIP.Uni-Hannover.DE/"), "Host ohne Gross-/Kleinschreibung")
        assertTrue(luh.allows("https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1"))
        assertTrue(luh.allows("https://login.uni-hannover.de/"))
        assertTrue(luh.allows("https://sub.studip.uni-hannover.de/x"), "Unter-Domain eines Hosts")
        assertTrue(luh.allows("uniflow://token=abc"), "Rueckleitung im eigenen Schema")
        assertTrue(luh.allows("UNIFLOW://token=abc"))
        assertFalse(luh.allows("http://studip.uni-hannover.de/"), "nur https")
        assertFalse(luh.allows("https://www.uni-hildesheim.de/learnweb2026/my/"), "andere Hochschule")
        assertFalse(luh.allows("https://studip.uni-hannover.de.example.org/"), "Host nur als Praefix")
        assertFalse(luh.allows("https://xstudip.uni-hannover.de/"), "Suffix ohne Punkt")
        assertFalse(luh.allows("https://uni-hannover.de/"), "Eltern-Domain ist kein Host")
        assertFalse(luh.allows("https://studip.uni-hannover.de@evil.example/"), "Benutzerteil taeuscht den Host vor")
        assertFalse(luh.allows("https://evil.example/?studip.uni-hannover.de"))
        assertFalse(luh.allows("https://evil.example/studip.uni-hannover.de"))
        assertFalse(luh.allows("moodlemobile://token=abc"), "fremdes Schema")
        assertFalse(luh.allows("javascript:alert(1)"))
        assertFalse(luh.allows("about:blank"))
        assertFalse(luh.allows(""))
        assertFalse(luh.allows("nicht mal eine adresse"))
        assertFalse(luh.allows("https://studip.uni-hannover.de/mit leerzeichen"), "unlesbare Adresse bleibt draussen")
        assertTrue(hildesheim.allows("https://www.uni-hildesheim.de/sso/login?service=x"))
        assertTrue(hildesheim.allows("https://lsf.uni-hildesheim.de/qisserver/rds"))
        assertFalse(hildesheim.allows("https://uni-hildesheim.de/sso/login"), "nur die eingetragenen Hosts")
        assertFalse(hildesheim.allows("https://studip.uni-hannover.de/"))
        // eigenes Schema aus dem Profil
        val dev = luh.copy(launchScheme = "uniflowdev")
        assertTrue(dev.allows("uniflowdev://token=x"))
        assertFalse(dev.allows("uniflow://token=x"))
    }

    @Test
    fun loginPagesByPathOnly() {
        assertTrue(luh.isLoginPage("https://studip.uni-hannover.de/dispatch.php/login"))
        assertTrue(luh.isLoginPage("https://studip.uni-hannover.de/dispatch.php/login?again=yes"))
        assertTrue(luh.isLoginPage("https://studip.uni-hannover.de/Shibboleth.sso/SAML2/POST"))
        assertTrue(luh.isLoginPage("https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1"))
        assertTrue(hildesheim.isLoginPage("https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Fx"))
        assertTrue(hildesheim.isLoginPage("https://www.uni-hildesheim.de/learnweb2026/login/index.php?authCAS=CAS"))
        assertTrue(luh.isLoginPage(luh.loginUrl) && hildesheim.isLoginPage(hildesheim.loginUrl))
        assertTrue(luh.isLoginPage("/login/index.php"), "auch ein relativer Pfad (Location-Kopfzeile)")
        assertFalse(luh.isLoginPage("https://studip.uni-hannover.de/dispatch.php/my_courses"))
        assertFalse(luh.isLoginPage("https://studip.uni-hannover.de/jsonapi.php/v1/users/me"))
        assertFalse(hildesheim.isLoginPage("https://www.uni-hildesheim.de/learnweb2026/my/"))
        assertFalse(luh.isLoginPage("https://studip.uni-hannover.de/x?next=/dispatch.php/login"), "nur der Pfad zaehlt, nicht die Abfrage")
        assertFalse(luh.isLoginPage("https://studip.uni-hannover.de/x#/sso/login"))
        assertFalse(luh.isLoginPage("uniflow://token=abc"))
        assertFalse(luh.isLoginPage(""))
    }

    @Test
    fun loggedInNeedsSessionCookieAllowedPageAndNoLoginPage() {
        val c = listOf(UniCookie("Seminar_Session", "abc", "studip.uni-hannover.de"))
        assertTrue(luh.loggedIn(c, "https://studip.uni-hannover.de/dispatch.php/my_courses"))
        assertTrue(luh.loggedIn(c, luh.loggedInCheckUrl))
        assertTrue(luh.loggedIn(listOf(UniCookie("Seminar_Session", "abc", ".uni-hannover.de")), "https://studip.uni-hannover.de/"), "Cookie der Eltern-Domain")
        assertFalse(luh.loggedIn(c, "https://studip.uni-hannover.de/dispatch.php/login"), "noch auf der Anmeldeseite")
        assertFalse(luh.loggedIn(c, "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO"), "noch beim IdP")
        assertFalse(luh.loggedIn(c, "https://evil.example/"), "fremde Seite")
        assertFalse(luh.loggedIn(c, "http://studip.uni-hannover.de/"), "nur https")
        assertFalse(luh.loggedIn(emptyList(), "https://studip.uni-hannover.de/"))
        assertFalse(luh.loggedIn(listOf(UniCookie("Seminar_Session", "", "studip.uni-hannover.de")), "https://studip.uni-hannover.de/"), "leerer Wert")
        assertFalse(luh.loggedIn(listOf(UniCookie("Seminar_Session", "abc", "studip.example.org")), "https://studip.uni-hannover.de/"), "Cookie fremder Domain")
        assertFalse(luh.loggedIn(listOf(UniCookie("MoodleSession", "abc", "studip.uni-hannover.de")), "https://studip.uni-hannover.de/"), "falscher Name")
        assertFalse(hildesheim.loggedIn(c, "https://www.uni-hildesheim.de/learnweb2026/my/"), "Cookie der anderen Hochschule")
        assertTrue(hildesheim.loggedIn(listOf(UniCookie("MoodleSession", "m1", "www.uni-hildesheim.de")), hildesheim.loggedInCheckUrl))
        assertFalse(hildesheim.loggedIn(listOf(UniCookie("MoodleSession", "m1", "www.uni-hildesheim.de")), hildesheim.loginUrl))
    }

    @Test
    fun profileFromJsonToleratesGaps() {
        val p = UniversityProfile.from(Json.parseToJsonElement("""{"key":"x","name":"X","hosts":["a.example",5,null],"learnweb_base":null}""") as JsonObject)
        assertEquals(listOf("a.example"), p.hosts)
        assertEquals("", p.loginUrl); assertEquals("", p.sessionCookie); assertNull(p.learnwebBase); assertNull(p.casBase)
        assertEquals("uniflow", p.launchScheme)
        assertEquals("eigen", UniversityProfile.from(Json.parseToJsonElement("""{"launch_scheme":"eigen"}""") as JsonObject).launchScheme)
    }

    // ---------------------------------------------------------------- Sitzung

    @Test
    fun parseCookieHeaderFromTheWebView() {
        val c = UniversitySession.parseCookieHeader("Seminar_Session=abc; shib=s1=x;  leer=; junk ; =ohnename", "studip.uni-hannover.de")
        assertEquals(listOf("Seminar_Session" to "abc", "shib" to "s1=x", "leer" to ""), c.map { it.name to it.value })
        assertTrue(c.all { it.domain == "studip.uni-hannover.de" && it.path == "/" && it.expires == null })
        assertEquals(emptyList(), UniversitySession.parseCookieHeader(null, "h"))
        assertEquals(emptyList(), UniversitySession.parseCookieHeader("  ", "h"))
        assertEquals(emptyList(), UniversitySession.parseCookieHeader(";;", "h"))
        assertTrue(luh.loggedIn(c, "https://studip.uni-hannover.de/dispatch.php/my_courses"))
        assertEquals("Seminar_Session=abc; shib=s1=x; leer=", UniversitySession("luh", c).cookieHeader("https://studip.uni-hannover.de/x"))
        assertEquals("", UniversitySession("luh", c).cookieHeader("https://sso.idm.uni-hannover.de/"), "nur fuer den Host der WebView-Seite")
    }

    @Test
    fun sessionJsonRoundTrip() {
        val s = UniversitySession("hildesheim", listOf(
            UniCookie("MoodleSession", "m1", "www.uni-hildesheim.de"),
            UniCookie("shib", "s=1; x\"y", ".uni-hildesheim.de", "/learnweb2026", 1761700000L),
            UniCookie("alt", "x", "www.uni-hildesheim.de", "/", -1L)),
            learnwebToken = "tok-123", savedAt = 1761600000L, expired = true)
        assertEquals(s, UniversitySession.fromJson(s.toJson()))
        val plain = UniversitySession("luh", emptyList())
        assertEquals(plain, UniversitySession.fromJson(plain.toJson()))
        val j = Json.parseToJsonElement(s.toJson()) as JsonObject
        assertEquals("tok-123", j["learnweb_token"]!!.jsonPrimitive.content)
        assertEquals("hildesheim", j["university"]!!.jsonPrimitive.content)
        assertEquals("true", j["expired"]!!.jsonPrimitive.content)
        assertFalse((Json.parseToJsonElement(plain.toJson()) as JsonObject).containsKey("learnweb_token"))
        assertNull(UniversitySession.fromJson("kaputt"))
        assertNull(UniversitySession.fromJson(""))
        assertNull(UniversitySession.fromJson("[]"))
        assertNull(UniversitySession.fromJson("""{"cookies":[]}"""), "ohne Hochschule")
        // Cookies ohne Namen fallen weg, der Rest bleibt; fehlende Felder haben Standardwerte
        val tolerant = UniversitySession.fromJson("""{"university":"luh","cookies":[{"value":"x","domain":"d"},{"name":"a","value":"1","domain":"d","expires":-1}]}""")!!
        assertEquals(listOf(UniCookie("a", "1", "d", "/", -1L)), tolerant.cookies)
        assertNull(tolerant.learnwebToken); assertEquals(0L, tolerant.savedAt); assertFalse(tolerant.expired)
    }

    @Test
    fun hasSessionCookiePerProfile() {
        assertTrue(studipSession.hasSessionCookie(luh))
        assertFalse(studipSession.hasSessionCookie(hildesheim))
        assertTrue(UniversitySession("luh", listOf(UniCookie("Seminar_Session", "abc", ".uni-hannover.de"))).hasSessionCookie(luh))
        assertFalse(UniversitySession("luh", listOf(UniCookie("Seminar_Session", "abc", "uni-hannover.de.example"))).hasSessionCookie(luh))
        assertFalse(UniversitySession("luh", listOf(UniCookie("Seminar_Session", " ", "studip.uni-hannover.de"))).hasSessionCookie(luh))
        assertFalse(UniversitySession("hildesheim", emptyList(), learnwebToken = "t").hasSessionCookie(hildesheim), "Schluessel ist kein Cookie")
    }

    @Test
    fun cookieHeaderExpiryAndDomains() {
        val s = UniversitySession("luh", listOf(
            UniCookie("a", "1", "studip.uni-hannover.de"),                      // Sitzung
            UniCookie("b", "2", ".uni-hannover.de", expires = 200),              // laeuft spaeter ab
            UniCookie("c", "3", "studip.uni-hannover.de", expires = 100),        // genau jetzt: weg
            UniCookie("d", "4", "uni-hannover.de", expires = 0),                 // 0 = Sitzung
            UniCookie("e", "5", "sso.idm.uni-hannover.de")))                      // anderer Host
        assertEquals("a=1; b=2; d=4", s.cookieHeader("https://studip.uni-hannover.de/sendfile.php?x=1", 100))
        assertEquals("a=1; d=4", s.cookieHeader("https://studip.uni-hannover.de/", 300))
        assertEquals("b=2; d=4; e=5", s.cookieHeader("https://sso.idm.uni-hannover.de/idp/", 100))
        assertEquals("a=1; b=2; d=4", s.cookieHeader("HTTPS://Studip.Uni-Hannover.DE/", 100))
        assertEquals("", s.cookieHeader("https://example.org/", 100))
        assertEquals("b=2; d=4", s.cookieHeader("https://xstudip.uni-hannover.de/", 100), "Unter-Domain der Eltern-Domain")
        assertEquals("", s.cookieHeader("https://xuni-hannover.de/", 100), "Suffix ohne Punkt")
        assertEquals("", s.cookieHeader("kaputt", 100))
        assertTrue(UniCookie("x", "1", "d", expires = 5).isExpired(5))
        assertFalse(UniCookie("x", "1", "d", expires = 6).isExpired(5))
        assertFalse(UniCookie("x", "1", "d", expires = -1).isExpired(Long.MAX_VALUE))
        assertFalse(UniCookie("x", "1", "d").isExpired(Long.MAX_VALUE))
    }

    // ---------------------------------------------------------------- Download

    @Test
    fun requestStudipWithCookieAndLearnwebWithTokenOrCookie() {
        val r = DirectDownload.request(studipUrl, "studip", studipSession)
        assertEquals("GET", r.method); assertEquals(studipUrl, r.url); assertNull(r.body)
        assertEquals("Seminar_Session=abc", r.headers["Cookie"])
        assertEquals("UniFlow-Android", r.headers["User-Agent"])
        assertEquals("*/*", r.headers["Accept"])
        assertNull(r.headers["Content-Type"])

        val lwCookies = listOf(UniCookie("MoodleSession", "m1", "www.uni-hildesheim.de"))
        val withToken = DirectDownload.request(learnwebUrl, "learnweb", UniversitySession("hildesheim", lwCookies, learnwebToken = "tok-123"))
        assertEquals("POST", withToken.method); assertEquals(learnwebUrl, withToken.url)
        assertEquals("token=tok-123", withToken.body!!.toString(Charsets.UTF_8))
        assertFalse(withToken.url.contains("tok-123"), "Schluessel nie in der Adresse")
        assertNull(withToken.headers["Cookie"], "mit Schluessel keine Cookies")
        assertEquals("application/x-www-form-urlencoded", withToken.headers["Content-Type"])
        assertEquals("UniFlow-Android", withToken.headers["User-Agent"])

        val withCookie = DirectDownload.request(learnwebUrl, "learnweb", UniversitySession("hildesheim", lwCookies))
        assertEquals("GET", withCookie.method); assertNull(withCookie.body)
        assertEquals("MoodleSession=m1", withCookie.headers["Cookie"])
        assertFalse(withCookie.url.contains("token"))

        assertEquals("GET", DirectDownload.request(learnwebUrl, "learnweb", UniversitySession("hildesheim", lwCookies, learnwebToken = " ")).method, "leerer Schluessel zaehlt nicht")
        assertEquals("GET", DirectDownload.request(studipUrl, "studip", studipSession.copy(learnwebToken = "tok")).method, "Schluessel nur fuer Learnweb")
        // ohne passende Cookies: GET ohne Cookie-Kopfzeile (die Hochschule antwortet mit der Anmeldeseite -> SessionExpired)
        assertNull(DirectDownload.request(studipUrl, "studip", UniversitySession("luh", emptyList())).headers["Cookie"])
        assertNull(DirectDownload.request(studipUrl, "studip", UniversitySession("luh", lwCookies)).headers["Cookie"], "Cookies der anderen Hochschule")
        // Sonderzeichen im Schluessel bleiben im Formular kodiert (urllib.parse.urlencode)
        assertEquals("token=a%2Bb+c%3D%C3%A4", Learnweb.tokenRequest(learnwebUrl, "a+b c=ä").body!!.toString(Charsets.UTF_8))
    }

    @Test
    fun fetchReturnsBytesOrFails() {
        val pdf = "%PDF-1.7 inhalt".toByteArray()
        val req = DirectDownload.request(studipUrl, "studip", studipSession)
        val ok = Fixed(200, pdf, mapOf("content-type" to "application/pdf"))
        assertTrue(DirectDownload.fetch(ok, req).contentEquals(pdf))
        assertEquals(req, ok.seen)
        assertTrue(DirectDownload.fetch(Fixed(200, pdf), req).contentEquals(pdf), "ohne Content-Type")
        // Anmeldeseite statt Datei
        assertFailsWith<DirectDownload.SessionExpired> {
            DirectDownload.fetch(Fixed(200, "<!DOCTYPE html><html>login".toByteArray(), mapOf("Content-Type" to "text/html; charset=utf-8")), req)
        }
        assertFailsWith<DirectDownload.SessionExpired> { DirectDownload.fetch(Fixed(200, "\n <html>".toByteArray(), mapOf("content-type" to "application/pdf")), req) }
        assertFailsWith<DirectDownload.SessionExpired> { DirectDownload.fetch(Fixed(200, "%PDF".toByteArray(), mapOf("Content-Type" to "TEXT/HTML")), req) }
        // Weiterleitung auf die Anmeldeseite (Moodle: 303 auf login/index.php, Stud.IP: 302 auf dispatch.php/login) ist dasselbe
        assertFailsWith<DirectDownload.SessionExpired> {
            DirectDownload.fetch(Fixed(303, ByteArray(0), mapOf("location" to "https://www.uni-hildesheim.de/learnweb2026/login/index.php")), req)
        }
        assertFailsWith<DirectDownload.SessionExpired> {
            DirectDownload.fetch(Fixed(302, ByteArray(0), mapOf("Location" to "/dispatch.php/login?again=yes")), req)
        }
        // andere Fehler
        val forbidden = assertFailsWith<ApiError> { DirectDownload.fetch(Fixed(403, "nein".toByteArray()), req) }
        assertEquals(403, forbidden.status); assertEquals("download", forbidden.code); assertFalse(forbidden.isNetwork)
        assertTrue(forbidden.message!!.contains("403"), forbidden.message)
        val redirect = assertFailsWith<ApiError> { DirectDownload.fetch(Fixed(302, ByteArray(0), mapOf("location" to "https://studip.uni-hannover.de/other")), req) }
        assertEquals(302, redirect.status); assertEquals("download", redirect.code)
        assertTrue(redirect.message!!.contains("https://studip.uni-hannover.de/other"), redirect.message)
        assertEquals(404, assertFailsWith<ApiError> { DirectDownload.fetch(Fixed(404, ByteArray(0)), req) }.status)
        assertEquals(500, assertFailsWith<ApiError> { DirectDownload.fetch(Fixed(500, "<html>".toByteArray()), req) }.status, "Status vor Inhalt")
        // zu gross
        val big = assertFailsWith<ApiError> { DirectDownload.fetch(Fixed(200, ByteArray(11), mapOf("content-type" to "application/pdf")), req, maxBytes = 10) }
        assertEquals(413, big.status); assertEquals("too_large", big.code)
        assertEquals(10, DirectDownload.fetch(Fixed(200, ByteArray(10)), req, maxBytes = 10).size)
        assertEquals(300 shl 20, DirectDownload.MAX_BYTES)
        // Netzfehler wie beim ApiClient
        val net = object : HttpTransport { override fun send(request: HttpRequest): HttpResponse = throw java.net.ConnectException("refused") }
        assertTrue(assertFailsWith<ApiError> { DirectDownload.fetch(net, req) }.isNetwork)
    }

    @Test
    fun sha256Hex() {
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Sha256.hex(ByteArray(0)))
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", Sha256.hex("abc".toByteArray()))
        assertEquals(64, Sha256.hex(ByteArray(1000) { it.toByte() }).length)
    }

    // ---------------------------------------------------------------- Dienst

    @Test
    fun deviceSyncApiPathsAndBodies() {
        val profileJson = """{"key":"hildesheim","name":"Universität Hildesheim",
            "login_url":"https://www.uni-hildesheim.de/learnweb2026/login/index.php?authCAS=CAS",
            "logged_in_check_url":"https://www.uni-hildesheim.de/learnweb2026/my/","session_cookie":"MoodleSession",
            "hosts":["www.uni-hildesheim.de","lsf.uni-hildesheim.de"],"file_host":"www.uni-hildesheim.de",
            "learnweb_base":"https://www.uni-hildesheim.de/learnweb2026","cas_base":"https://www.uni-hildesheim.de/sso"}"""
        val t = Recorder(profileJson)
        val api = DeviceSyncApi(ApiClient("https://dienst.test", t, Auth.Bearer("x")))
        assertEquals(hildesheim, api.profile())
        assertEquals("GET", t.seen[0].method); assertEquals("https://dienst.test/api/university/profile", t.seen[0].url)
        assertEquals("Bearer x", t.seen[0].headers["Authorization"])
        // auch eingepackt als {"profile": {...}}
        assertEquals(hildesheim, DeviceSyncApi(ApiClient("https://dienst.test", Recorder("""{"profile":$profileJson}"""))).profile())
        assertEquals("no_profile", assertFailsWith<ApiError> { DeviceSyncApi(ApiClient("https://dienst.test", Recorder("[]"))).profile() }.code)

        val t2 = Recorder("{}")
        val api2 = DeviceSyncApi(ApiClient("https://dienst.test", t2, Auth.Bearer("x")))
        api2.reportFingerprint("lw-21-abcd1234", "ba78")
        assertEquals("PUT", t2.seen[0].method); assertEquals("https://dienst.test/api/files/lw-21-abcd1234/fingerprint", t2.seen[0].url)
        assertEquals("""{"sha256":"ba78"}""", t2.seen[0].body!!.toString(Charsets.UTF_8))
        assertEquals("application/json", t2.seen[0].headers["Content-Type"])
        api2.reportPageText("f1", listOf("Seite 1", "Seite \"2\""))
        assertEquals("PUT", t2.seen[1].method); assertEquals("https://dienst.test/api/files/f1/pagetext", t2.seen[1].url)
        assertEquals("""{"pages":["Seite 1","Seite \"2\""]}""", t2.seen[1].body!!.toString(Charsets.UTF_8))
        api2.reportPageText("f2", emptyList())
        assertEquals("""{"pages":[]}""", t2.seen[2].body!!.toString(Charsets.UTF_8))
        // Fehler des Dienstes laufen wie ueberall als ApiError durch (nur 2xx ist Erfolg)
        val e = assertFailsWith<ApiError> { DeviceSyncApi(ApiClient("https://dienst.test", Recorder("""{"detail":"Datei nicht gefunden.","code":"not_found"}""", 404))).reportFingerprint("x", "y") }
        assertEquals(404, e.status); assertEquals("not_found", e.code)
        assertEquals(302, assertFailsWith<ApiError> { DeviceSyncApi(ApiClient("https://dienst.test", Recorder("", 302))).reportPageText("x", listOf("a")) }.status)
    }

    @Test
    fun libraryFileCarriesSourceDownloadUrlAndFingerprint() {
        val lib = Library.from(Json.parseToJsonElement("""{"files":[
            {"id":"f1","name":"a.pdf","course_id":"c1","download_url":"https://studip.uni-hannover.de/sendfile.php?file_id=f1","content_sha256":"ab"},
            {"id":"lw-1-x","name":"b.pdf","source":"learnweb","download_url":"https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/1/x.pdf"},
            {"id":"u1","name":"eigen.pdf","course_id":"__user__"},
            {"id":"u2","name":"eigen2.pdf","course_id":"__user__","source":"own","download_url":null},
            {"id":"f3","name":"c.pdf"}],"modules":[]}"""))
        assertEquals(listOf("studip", "learnweb", "own", "own", "studip"), lib.files.map { it.source })
        assertEquals("ab", lib.files[0].contentSha256); assertNull(lib.files[1].contentSha256)
        assertTrue(Learnweb.isPluginfile(lib.files[1].downloadUrl!!)); assertFalse(Learnweb.isPluginfile(lib.files[0].downloadUrl!!))
        assertNull(lib.files[2].downloadUrl); assertNull(lib.files[3].downloadUrl); assertNull(lib.files[4].downloadUrl)
        assertEquals("a.pdf", lib.files[0].title)
    }
}
