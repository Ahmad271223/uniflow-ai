package de.uniflow.core

import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Hochschul-Anmeldung auf dem Geraet und direkter Download (Vertrag packages/shared-contracts/fixtures/learnweb/launch.json,
 * Python-Referenz app/learnweb.py und app/filestream.py). Die App meldet sich in einer WebView selbst bei der Hochschule an;
 * der Kern entscheidet, welche Adressen die WebView zeigen darf und wann die Anmeldung fertig ist, bewahrt die Sitzung
 * (Cookies, bei Hildesheim dazu der Learnweb-Schluessel aus der Moodle-App-Anmeldung) und baut die Download-Anfragen
 * damit. Reines Kotlin/JVM ohne Android-Abhaengigkeiten, damit alles hier testbar ist.
 */

/** Profil einer Hochschule fuer die Anmeldung auf dem Geraet (Felder wie `profiles` in der Fixture bzw. GET /api/university/profile). */
data class UniversityProfile(val key: String, val name: String, val loginUrl: String, val loggedInCheckUrl: String, val sessionCookie: String,
                             val hosts: List<String>, val fileHost: String, val learnwebBase: String?, val casBase: String?,
                             val launchScheme: String = "uniflow") {

    /**
     * Darf die WebView diese Adresse laden? Nur https auf einem der Hosts (oder einer Unter-Domain davon); dazu die
     * Rueckleitung der Moodle-App-Anmeldung im eigenen Schema (uniflow://token=...). Alles andere (http, fremde Rechner,
     * javascript:, ein Host nur als Praefix oder im Benutzerteil der Adresse) bleibt draussen.
     */
    fun allows(url: String): Boolean {
        val scheme = Urls.scheme(url) ?: return false
        if (scheme == launchScheme.lowercase()) return true
        if (scheme != "https") return false
        val host = Urls.host(url) ?: return false
        return hosts.any { Urls.hostMatches(host, it) }
    }

    /** Anmeldeseite (Stud.IP-Login, Shibboleth, IdP der LUH, CAS Hildesheim, Moodle-Login)? Entscheidet allein der Pfad. */
    fun isLoginPage(url: String): Boolean = Urls.isLoginPage(url)

    /** Fertig angemeldet: Sitzungscookie fuer einen der Hosts da, die aktuelle Seite erlaubt und keine Anmeldeseite mehr. */
    fun loggedIn(cookies: List<UniCookie>, currentUrl: String): Boolean =
        cookies.any { isSessionCookie(it) } && allows(currentUrl) && !isLoginPage(currentUrl)

    /** Ist das das Sitzungscookie dieser Hochschule: richtiger Name, nicht leer, Domain passt zu einem der Hosts? */
    fun isSessionCookie(c: UniCookie): Boolean =
        c.name == sessionCookie && c.value.isNotBlank() && hosts.any { c.matchesHost(it) }

    companion object {
        fun from(o: JsonObject): UniversityProfile = UniversityProfile(
            key = o.s("key") ?: "", name = o.s("name") ?: "", loginUrl = o.s("login_url") ?: "",
            loggedInCheckUrl = o.s("logged_in_check_url") ?: "", sessionCookie = o.s("session_cookie") ?: "",
            hosts = ApiClient.arr(o, "hosts").mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content },
            fileHost = o.s("file_host") ?: "", learnwebBase = o.s("learnweb_base"), casBase = o.s("cas_base"),
            launchScheme = o.s("launch_scheme") ?: "uniflow",
        )

        /** Die beiden bekannten Hochschulen mit genau den Werten der Fixture (app/universities.py, app/studip_sync.py); sonst null. */
        fun builtIn(key: String): UniversityProfile? = when (key) {
            "luh" -> UniversityProfile(
                key = "luh", name = "Leibniz Universität Hannover",
                loginUrl = "https://studip.uni-hannover.de/dispatch.php/login",
                loggedInCheckUrl = "https://studip.uni-hannover.de/jsonapi.php/v1/users/me", sessionCookie = "Seminar_Session",
                hosts = listOf("studip.uni-hannover.de", "sso.idm.uni-hannover.de", "login.uni-hannover.de"),
                fileHost = "studip.uni-hannover.de", learnwebBase = null, casBase = null,
            )
            "hildesheim" -> UniversityProfile(
                key = "hildesheim", name = "Universität Hildesheim",
                loginUrl = "https://www.uni-hildesheim.de/learnweb2026/login/index.php?authCAS=CAS",
                loggedInCheckUrl = "https://www.uni-hildesheim.de/learnweb2026/my/", sessionCookie = "MoodleSession",
                hosts = listOf("www.uni-hildesheim.de", "lsf.uni-hildesheim.de"), fileHost = "www.uni-hildesheim.de",
                learnwebBase = "https://www.uni-hildesheim.de/learnweb2026", casBase = "https://www.uni-hildesheim.de/sso",
            )
            else -> null
        }
    }
}

/**
 * Cookie der Hochschulsitzung (Form wie Playwright context.cookies() bzw. der Tresor am PC). `expires` in Unix-Sekunden;
 * fehlend, -1 oder 0 = Sitzungscookie (gilt, bis die WebView es verwirft).
 */
data class UniCookie(val name: String, val value: String, val domain: String, val path: String = "/", val expires: Long? = null) {
    /** Domain passt zum Host: gleich oder dessen Unter-Domain, fuehrender Punkt egal (wie filestream.cookie_header). */
    fun matchesHost(host: String): Boolean = Urls.hostMatches(host, domain)

    /** Abgelaufen zum Zeitpunkt `nowSeconds`? Sitzungscookies (expires fehlend oder <= 0) laufen nie ab. */
    fun isExpired(nowSeconds: Long): Boolean = expires != null && expires > 0 && expires <= nowSeconds

    fun toJson(): JsonObject = buildJsonObject {
        put("name", name); put("value", value); put("domain", domain); put("path", path)
        if (expires != null) put("expires", expires)
    }

    companion object {
        /** Cookie aus JSON (eigene Ablage oder Playwright-Form); ohne Namen null. */
        fun from(o: JsonObject): UniCookie? {
            val name = o.s("name")?.takeIf { it.isNotEmpty() } ?: return null
            return UniCookie(name, o.s("value") ?: "", o.s("domain") ?: "", o.s("path") ?: "/", o.s("expires")?.toDoubleOrNull()?.toLong())
        }
    }
}

/**
 * Hochschulsitzung des Geraets: Cookies der WebView und bei Hildesheim der Learnweb-Schluessel aus der Moodle-App-Anmeldung.
 * Die App legt sie verschluesselt ab (toJson/fromJson); `savedAt` ist der Zeitpunkt der Ablage (Unix-Sekunden, 0 = unbekannt),
 * `expired` merkt, dass ein Download an der Anmeldung gescheitert ist (SessionExpired) und die App neu anmelden muss.
 */
data class UniversitySession(val university: String, val cookies: List<UniCookie>, val learnwebToken: String? = null,
                             val savedAt: Long = 0L, val expired: Boolean = false) {

    /**
     * Cookie-Kopfzeile fuer eine Adresse wie filestream.cookie_header: nur Cookies, deren Domain zum Host passt und die
     * nicht abgelaufen sind, in der gespeicherten Reihenfolge. Leer, wenn nichts passt oder die Adresse keinen Host hat.
     */
    fun cookieHeader(url: String, nowSeconds: Long = System.currentTimeMillis() / 1000): String {
        val host = Urls.host(url) ?: return ""
        return cookies.filter { it.name.isNotEmpty() && it.matchesHost(host) && !it.isExpired(nowSeconds) }
            .joinToString("; ") { "${it.name}=${it.value}" }
    }

    fun hasSessionCookie(profile: UniversityProfile): Boolean = cookies.any { profile.isSessionCookie(it) }

    fun toJson(): String = buildJsonObject {
        put("university", university)
        put("cookies", JsonArray(cookies.map { it.toJson() }))
        if (learnwebToken != null) put("learnweb_token", learnwebToken)
        put("saved_at", savedAt)
        put("expired", expired)
    }.toString()

    companion object {
        /** Gespeicherte Sitzung; null bei kaputtem JSON oder ohne Hochschule. Cookies ohne Namen fallen weg. */
        fun fromJson(s: String): UniversitySession? {
            val o = runCatching { Json.parseToJsonElement(s) }.getOrNull() as? JsonObject ?: return null
            val university = o.s("university")?.takeIf { it.isNotEmpty() } ?: return null
            return UniversitySession(
                university = university,
                cookies = o.list("cookies").mapNotNull { UniCookie.from(it) },
                learnwebToken = o.s("learnweb_token")?.takeIf { it.isNotEmpty() },
                savedAt = o.s("saved_at")?.toDoubleOrNull()?.toLong() ?: 0L,
                expired = o.b("expired"),
            )
        }

        /**
         * "a=1; b=2" (Android CookieManager.getCookie) -> Cookies mit domain = host und ohne Ablauf (den verraet die
         * WebView nicht). Eintraege ohne Namen oder ohne "=" fallen weg; der Wert darf selbst "=" enthalten.
         */
        fun parseCookieHeader(header: String?, host: String): List<UniCookie> {
            if (header.isNullOrBlank()) return emptyList()
            return header.split(';').mapNotNull { part ->
                val p = part.trim()
                val eq = p.indexOf('=')
                if (eq <= 0) null else UniCookie(p.substring(0, eq).trim(), p.substring(eq + 1).trim(), host)
            }
        }
    }
}

/** Moodle-Anmeldung fuer Apps (learnweb.launch_url, learnweb.parse_launch_token) und Download mit Schluessel (learnweb.token_request). */
object Learnweb {
    const val SERVICE = "moodle_mobile_app"
    const val DEFAULT_SCHEME = "moodlemobile"
    private val TOKEN_RE = Regex("token=([A-Za-z0-9+/=_-]+)")

    data class LaunchToken(val token: String, val privateToken: String?)

    /**
     * Startadresse der Moodle-App-Anmeldung. Nach dem Login (Hildesheim: CAS) leitet Moodle auf <scheme>://token=<base64>
     * weiter; die WebView faengt diese Adresse ab (UniversityProfile.allows laesst sie durch) und gibt sie an parseLaunchToken.
     */
    fun launchUrl(base: String, passport: String, scheme: String = DEFAULT_SCHEME): String =
        "${base.trimEnd('/')}/admin/tool/mobile/launch.php?service=$SERVICE&passport=${Urls.quote(passport)}&urlscheme=${Urls.quote(scheme)}"

    /**
     * <scheme>://token=<base64(md5(base + passport) ':::' token [':::' private])>, auch mit URL-sicherem Base64 ohne Auffuellung.
     * Prueft die Signatur gegen die eigene Learnweb-Adresse und den eigenen Passport; bei fremder Adresse, fremdem Passport,
     * leerem Schluessel oder kaputtem Base64: null.
     */
    fun parseLaunchToken(redirectUrl: String, base: String, passport: String): LaunchToken? {
        val m = TOKEN_RE.find(redirectUrl) ?: return null
        val raw = m.groupValues[1].replace('-', '+').replace('_', '/')
        val padded = raw + "=".repeat((4 - raw.length % 4) % 4)
        val bytes = runCatching { Base64.getDecoder().decode(padded) }.getOrNull() ?: return null
        val text = Urls.utf8(bytes) ?: return null
        val parts = text.split(":::")
        if (parts.size < 2 || parts[1].isEmpty()) return null
        if (parts[0].lowercase() != Hashes.md5Hex(base.trimEnd('/') + passport)) return null
        return LaunchToken(parts[1], parts.getOrNull(2)?.takeIf { it.isNotEmpty() })
    }

    /**
     * Download mit Schluessel wie auf dem iPad und am PC: Adresse unveraendert, der Schluessel nur im POST-Koerper
     * (Formular token=...), nie in der Adresse und damit nie in Zugriffsprotokollen.
     */
    fun tokenRequest(url: String, token: String): HttpRequest = HttpRequest("POST", url,
        mapOf("Content-Type" to "application/x-www-form-urlencoded", "User-Agent" to DirectDownload.USER_AGENT, "Accept" to "*/*"),
        ("token=" + Urls.formEncode(token)).toByteArray(Charsets.UTF_8))

    /** Datei aus dem Learnweb (Moodle-Pluginfile), wie filestream.is_learnweb. */
    fun isPluginfile(url: String): Boolean = url.contains("pluginfile.php")
}

/**
 * Download einer Hochschuldatei direkt auf das Geraet mit der Sitzung des Geraets (wie filestream.fetch am PC, nur ohne die
 * erneute Anmeldung: die macht die App in der WebView, wenn SessionExpired kommt).
 */
object DirectDownload {
    const val USER_AGENT = "UniFlow-Android"
    /** Groessere Dateien laedt das Geraet nicht (wie MAX_BYTES in filestream.py). */
    const val MAX_BYTES = 300 shl 20

    /** Die Hochschule hat statt der Datei eine Anmeldeseite geliefert: Sitzung abgelaufen, die App muss neu anmelden. */
    class SessionExpired(message: String) : Exception(message)

    /**
     * Anfrage fuer eine Datei: "learnweb" mit Schluessel als POST (tokenRequest, ohne Cookies), sonst GET mit der
     * Cookie-Kopfzeile der Sitzung (Stud.IP immer, Learnweb ohne Schluessel ueber die CAS-Sitzung der WebView).
     */
    fun request(downloadUrl: String, source: String, session: UniversitySession): HttpRequest {
        if (source == "learnweb") {
            val token = session.learnwebToken
            if (!token.isNullOrBlank()) return Learnweb.tokenRequest(downloadUrl, token)
        }
        val headers = LinkedHashMap<String, String>()
        headers["User-Agent"] = USER_AGENT
        headers["Accept"] = "*/*"
        val cookie = session.cookieHeader(downloadUrl)
        if (cookie.isNotEmpty()) headers["Cookie"] = cookie
        return HttpRequest("GET", downloadUrl, headers, null)
    }

    /** Anmeldeseite statt Datei (filestream.looks_like_html): Content-Type text/html oder Inhalt beginnt (nach Leerraum) mit <!doctype oder <html. */
    fun looksLikeHtml(contentType: String?, body: ByteArray): Boolean {
        val ctype = (contentType ?: "").substringBefore(';').trim().lowercase()
        if (ctype.startsWith("text/html")) return true
        val head = String(body, 0, minOf(body.size, 600), Charsets.ISO_8859_1)
            .trimStart(' ', '\t', '\r', '\n', '\u000b', '\u000c').lowercase()
        return head.startsWith("<!doctype") || head.startsWith("<html")
    }

    /**
     * Datei holen. Netzfehler -> ApiError(0, "network"); Status ausserhalb 2xx -> ApiError(status, "download"), ausser einer
     * Weiterleitung auf eine Anmeldeseite (Moodle schickt bei abgelaufener Sitzung 303 auf login/index.php) -> SessionExpired;
     * Anmeldeseite statt Datei -> SessionExpired; groesser als maxBytes -> ApiError(413, "too_large").
     */
    fun fetch(transport: HttpTransport, request: HttpRequest, maxBytes: Int = MAX_BYTES): ByteArray {
        val resp = try {
            transport.send(request)
        } catch (e: Exception) {
            throw ApiError(0, "network", e.message ?: "Keine Verbindung")
        }
        val location = header(resp, "location")
        if (resp.status in 300..399 && location != null && Urls.isLoginPage(location)) {
            throw SessionExpired("Die Hochschule verlangt eine neue Anmeldung (Weiterleitung nach $location).")
        }
        if (resp.status !in 200..299) {
            throw ApiError(resp.status, "download", "Die Hochschule hat die Datei nicht herausgegeben (HTTP ${resp.status})" +
                (if (location != null) ", Weiterleitung nach $location" else "") + ".")
        }
        if (looksLikeHtml(header(resp, "content-type"), resp.body)) {
            throw SessionExpired("Die Hochschule hat statt der Datei eine Anmeldeseite geliefert – die Sitzung ist abgelaufen.")
        }
        if (resp.body.size > maxBytes) {
            throw ApiError(413, "too_large", "Die Datei ist zu groß (${resp.body.size shr 20} MB, erlaubt sind ${maxBytes shr 20} MB).")
        }
        return resp.body
    }

    private fun header(resp: HttpResponse, name: String): String? =
        resp.headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

/** Fingerabdruck einer Datei (wie hashlib.sha256(...).hexdigest() am PC), Kleinbuchstaben. */
object Sha256 {
    fun hex(bytes: ByteArray): String = Hashes.hex(MessageDigest.getInstance("SHA-256").digest(bytes))
}

/** Endpunkte des Dienstes fuer den Download auf dem Geraet: Hochschulprofil holen, Fingerabdruck und Seitentext zurueckmelden. */
class DeviceSyncApi(private val client: ApiClient) {

    fun profile(): UniversityProfile {
        val j = client.get("/api/university/profile")
        val o = j.o("profile") ?: j.obj ?: throw ApiError(0, "no_profile", "Antwort ohne Hochschulprofil")
        return UniversityProfile.from(o)
    }

    fun reportFingerprint(fileId: String, sha256: String) {
        client.put("/api/files/$fileId/fingerprint", ApiClient.obj("sha256" to sha256))
    }

    fun reportPageText(fileId: String, pages: List<String>) {
        client.put("/api/files/$fileId/pagetext", buildJsonObject { put("pages", JsonArray(pages.map { JsonPrimitive(it) })) })
    }
}

/** Adress-Helfer ohne Netz: Schema, Host und Pfad einer Adresse, Prozent-Kodierung wie urllib.parse.quote. */
internal object Urls {
    private val SCHEME_RE = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")
    private val LOGIN_PATHS = listOf("/dispatch.php/login", "/shibboleth.sso", "/idp/", "/sso/login", "/login/index.php")
    private const val HEX = "0123456789ABCDEF"

    fun scheme(url: String): String? = SCHEME_RE.find(url.trim())?.groupValues?.get(1)?.lowercase()

    fun host(url: String): String? =
        runCatching { URI(url.trim()).host }.getOrNull()?.lowercase()?.trimEnd('.')?.takeIf { it.isNotEmpty() }

    /** Pfad (dekodiert, ohne Abfrage); bei Adressen, die java.net.URI nicht lesen kann, von Hand abgetrennt. */
    fun path(url: String): String {
        val u = url.trim()
        runCatching { URI(u).path }.getOrNull()?.let { return it }
        var rest = if (SCHEME_RE.containsMatchIn(u)) u.substringAfter(':') else u
        if (rest.startsWith("//")) {
            val slash = rest.indexOf('/', 2)
            rest = if (slash < 0) "" else rest.substring(slash)
        }
        return rest.substringBefore('?').substringBefore('#')
    }

    fun isLoginPage(url: String): Boolean {
        val path = path(url).lowercase()
        return LOGIN_PATHS.any { path.contains(it) }
    }

    /** Host gleich der Domain oder deren Unter-Domain; fuehrender Punkt der Domain egal, Gross-/Kleinschreibung egal. */
    fun hostMatches(host: String, domain: String): Boolean {
        val h = host.lowercase().trimEnd('.')
        val d = domain.lowercase().trimStart('.').trimEnd('.')
        if (h.isEmpty() || d.isEmpty()) return false
        return h == d || h.endsWith(".$d")
    }

    /** urllib.parse.quote(s, safe=''): alles ausser A-Z a-z 0-9 _ . - ~ als %XX (UTF-8). */
    fun quote(s: String): String = percent(s, plusForSpace = false)

    /** urllib.parse.urlencode / quote_plus: wie quote, nur das Leerzeichen als "+". */
    fun formEncode(s: String): String = percent(s, plusForSpace = true)

    private fun percent(s: String, plusForSpace: Boolean): String {
        val sb = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            when {
                ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '_' || ch == '.' || ch == '~' -> sb.append(ch)
                plusForSpace && ch == ' ' -> sb.append('+')
                else -> sb.append('%').append(HEX[c shr 4]).append(HEX[c and 15])
            }
        }
        return sb.toString()
    }

    /** Strikt dekodiertes UTF-8; null bei ungueltigen Bytes (Python: decode("utf-8") wirft). */
    fun utf8(bytes: ByteArray): String? = runCatching {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrNull()
}

/** Hashwerte als Hex in Kleinbuchstaben; MD5 nur fuer die Signatur der Moodle-Rueckleitung (Moodle-Format, keine Sicherheit). */
internal object Hashes {
    private const val HEX = "0123456789abcdef"

    fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xff
            sb.append(HEX[v shr 4]).append(HEX[v and 15])
        }
        return sb.toString()
    }

    fun md5Hex(s: String): String = hex(MessageDigest.getInstance("MD5").digest(s.toByteArray(Charsets.UTF_8)))
}
