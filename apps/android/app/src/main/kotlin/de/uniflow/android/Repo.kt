package de.uniflow.android

import de.uniflow.core.AccountApi
import de.uniflow.core.AnnotationStore
import de.uniflow.core.ApiClient
import de.uniflow.core.ApiError
import de.uniflow.core.Auth
import de.uniflow.core.CalendarRange
import de.uniflow.core.Dashboard
import de.uniflow.core.JvmTransport
import de.uniflow.core.Library
import de.uniflow.core.LibraryFile
import de.uniflow.core.LoginResult
import de.uniflow.core.TimetableWeek
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject

/** Alle Serverzugriffe der Oberflaeche, blockierend im IO-Dispatcher; PDFs werden im Cache des Geraets abgelegt. */
class Repo(private val session: Session, private val cacheDir: File) {

    private fun client(): ApiClient = session.client()

    suspend fun login(url: String, email: String, password: String): LoginResult = withContext(Dispatchers.IO) {
        val c = ApiClient(SessionRules.normalizeUrl(url), JvmTransport())
        AccountApi(c).login(email, password, session.deviceId, android.os.Build.MODEL)
    }

    suspend fun register(url: String, email: String, password: String, university: String): LoginResult = withContext(Dispatchers.IO) {
        val c = ApiClient(SessionRules.normalizeUrl(url), JvmTransport())
        AccountApi(c).register(email, password, university, session.deviceId, android.os.Build.MODEL)
    }

    /** PC im WLAN: die PIN wird mit einem Aufruf der Einstellungen geprueft (401 = falsch). */
    suspend fun checkPin(url: String, pin: String): String = withContext(Dispatchers.IO) {
        val c = ApiClient(SessionRules.normalizeUrl(url), JvmTransport(), Auth.Pin(pin))
        c.get("/api/settings").let { ApiClient.str(it, "university") ?: "luh" }
    }

    /**
     * Abmelden: die Sitzung wird sofort verworfen, die Oberflaeche wechselt ohne Wartezeit zur Anmeldung. Das Konto-Token
     * wird beim Dienst im Hintergrund entwertet (kurzer Timeout); schlaegt das fehl, bleibt es folgenlos, denn lokal ist
     * das Token schon weg. Mit PIN (PC im WLAN) gibt es nichts beim Server zu tun.
     */
    fun logout(background: CoroutineScope) {
        val token = session.token
        val url = session.baseUrl
        session.clear()
        if (token != null && url.isNotEmpty()) background.launch(Dispatchers.IO) {
            runCatching { AccountApi(ApiClient(url, JvmTransport(LOGOUT_TIMEOUT_MS), Auth.Bearer(token))).logout() }
        }
    }

    suspend fun dashboard(): Dashboard = withContext(Dispatchers.IO) { Dashboard.from(client().get("/api/dashboard")) }
    suspend fun library(): Library = withContext(Dispatchers.IO) { Library.from(client().get("/api/library")) }
    suspend fun timetableWeek(start: String): TimetableWeek = withContext(Dispatchers.IO) { TimetableWeek.from(client().get("/api/timetable/week", mapOf("start" to start))) }
    suspend fun calendar(start: String, end: String): CalendarRange = withContext(Dispatchers.IO) {
        CalendarRange.from(client().get("/api/calendar", mapOf("start" to start, "end" to end)))
    }

    suspend fun setTaskStatus(taskId: Int, status: String) = withContext(Dispatchers.IO) {
        client().post("/api/tasks/$taskId/status", ApiClient.obj("status" to status))
    }

    suspend fun startSync(): String = withContext(Dispatchers.IO) {
        val j = client().post("/api/sync")
        ApiClient.str(j, "started") ?: "Sync"
    }

    /** Hintergrundjob des Servers (laeuft der Abgleich noch?), wie `pollBg` im Web. */
    suspend fun bg(): BgStatus = withContext(Dispatchers.IO) { BgStatus.from(client().get("/api/bg")) }

    /**
     * PDF aus dem Cache oder vom Server (unveraenderte Originalbytes); Cache-Schluessel enthaelt die Aenderungszeit.
     * Uebernommen wird nur, was mit `%PDF-` beginnt und gross genug ist (PdfRules); eine beschaedigte Cache-Datei
     * (abgebrochener Download, Fehlerseite) wird geloescht und neu geladen. Der Download geht zuerst in eine `.part`-Datei
     * und wird erst nach der Pruefung umbenannt, so liegt nie eine halbe Datei unter dem endgueltigen Namen.
     */
    suspend fun pdfFile(file: LibraryFile): File = withContext(Dispatchers.IO) {
        val dir = File(cacheDir, "pdf").apply { mkdirs() }
        val f = File(dir, "${file.id}-${file.chdate ?: 0}.pdf")
        if (f.exists() && !PdfRules.looksLikePdf(f)) f.delete()
        if (!f.exists()) {
            val bytes = client().getBytes("/api/files/${file.id}/content")
            if (!PdfRules.isPdf(bytes)) throw ApiError(0, "not_pdf", "Der Server hat keine PDF geliefert (${bytes.size} Bytes)")
            val tmp = File(dir, f.name + ".part")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(f)) {
                f.delete()
                if (!tmp.renameTo(f)) { tmp.delete(); throw ApiError(0, "cache", "PDF konnte nicht im Cache abgelegt werden") }
            }
        }
        f
    }

    /** Cache-Datei verwerfen (z. B. wenn der Renderer sie nicht oeffnen kann); der naechste Aufruf von `pdfFile` laedt neu. */
    fun discardPdf(f: File) { f.delete() }

    suspend fun loadAnnotations(fileId: String): AnnotationStore.Loaded = withContext(Dispatchers.IO) { AnnotationStore(client()).load(fileId) }

    suspend fun saveAnnotations(fileId: String, local: JsonObject, base: JsonObject?, baseVersion: Int): AnnotationStore.Saved = withContext(Dispatchers.IO) {
        AnnotationStore(client()).save(fileId, local, base, baseVersion)
    }

    companion object {
        /** Server-Logout im Hintergrund: kurz, die Oberflaeche wartet nicht darauf. */
        const val LOGOUT_TIMEOUT_MS = 5_000
    }
}
