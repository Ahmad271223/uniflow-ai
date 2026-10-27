package de.uniflow.android

import android.util.Log
import de.uniflow.core.AccountApi
import de.uniflow.core.AnnotationStore
import de.uniflow.core.ApiClient
import de.uniflow.core.ApiError
import de.uniflow.core.Auth
import de.uniflow.core.CalendarRange
import de.uniflow.core.Dashboard
import de.uniflow.core.DeviceSyncApi
import de.uniflow.core.DirectDownload
import de.uniflow.core.JvmTransport
import de.uniflow.core.Library
import de.uniflow.core.LibraryFile
import de.uniflow.core.LoginResult
import de.uniflow.core.Sha256
import de.uniflow.core.TimetableWeek
import de.uniflow.core.UniversityProfile
import de.uniflow.core.UniversitySession
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject

/**
 * Alle Serverzugriffe der Oberflaeche, blockierend im IO-Dispatcher; PDFs werden im Cache des Geraets abgelegt.
 * Hochschuldateien kommen, wenn eine Hochschul-Sitzung dieses Geraets vorliegt, direkt von Stud.IP bzw. dem Learnweb
 * (`universities`), sonst wie bisher ueber den Dienst. `pageText` liest nach einem Direkt-Download den Seitentext fuer
 * die Meldung an den Dienst; `background` traegt die Meldungen ueber die Ansicht hinaus.
 */
class Repo(private val session: Session, private val cacheDir: File, val universities: UniversityStore, val drafts: DraftStore,
           private val pageText: PageTextExtractor = PageTextExtractor.None, private val background: CoroutineScope = AppScope.main) {

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
        universities.clearAll()          // Hochschul-Sitzungen gehoeren zur Person, nicht zum Geraet: ein anderes Konto erbt sie nicht
        if (token != null && url.isNotEmpty()) background.launch(Dispatchers.IO) {
            runCatching { AccountApi(ApiClient(url, JvmTransport(LOGOUT_TIMEOUT_MS), Auth.Bearer(token))).logout() }
        }
    }

    // ---- Hochschule (Anmeldung auf dem Geraet) ----

    /**
     * Profil der Hochschule des Kontos vom Dienst (GET /api/university/profile); ohne Verbindung das eingebaute Profil.
     * null, wenn die Hochschule unbekannt ist. Nennt der Dienst eine andere Hochschule als die gemerkte (am Konto
     * geaendert), wird die gemerkte nachgezogen, damit Sitzung und Dateien zur selben Hochschule gehoeren.
     */
    suspend fun universityProfile(): UniversityProfile? = withContext(Dispatchers.IO) {
        val fromService = runCatching { DeviceSyncApi(client()).profile() }
            .onFailure { Log.w(TAG, "Hochschulprofil nicht vom Dienst: ${it.message}") }.getOrNull()
        if (fromService != null && fromService.key != session.university) session.university = fromService.key
        fromService ?: UniversityProfile.builtIn(session.university)
    }

    fun universitySession(): UniversitySession? = universities.load(session.university)

    fun universityLogout() { universities.clear(session.university) }

    data class UniversityStatus(val profile: UniversityProfile?, val session: UniversitySession?)

    suspend fun universityStatus(): UniversityStatus = UniversityStatus(universityProfile(), universitySession())

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

    /** Ergebnis von [pdf]: die Cache-Datei und, wenn sie gerade direkt von der Hochschule kam, die Quelle ("studip"/"learnweb"). */
    data class PdfResult(val file: File, val directFrom: String?)

    /**
     * PDF aus dem Cache, direkt von der Hochschule oder vom Dienst (unveraenderte Originalbytes); Cache-Schluessel
     * enthaelt die Aenderungszeit (PdfCache). Uebernommen wird nur, was mit `%PDF-` beginnt und gross genug ist
     * (PdfRules); eine beschaedigte Cache-Datei (abgebrochener Download, Fehlerseite) wird geloescht und neu geladen.
     *
     * Direkt (FetchPolicy): mit der Hochschul-Sitzung dieses Geraets ueber `DirectDownload`. Liefert die Hochschule statt
     * der Datei eine Anmeldeseite (SessionExpired), wird die Sitzung als abgelaufen markiert; dann – wie bei jedem anderen
     * Fehler des Direktwegs – kommt die Datei ueber den Dienst, damit niemand blockiert ist. Nach einem Direkt-Download
     * meldet das Geraet dem Dienst im Hintergrund nur Fingerabdruck (SHA-256) und Seitentext, nie die Datei.
     */
    suspend fun pdf(file: LibraryFile): PdfResult = withContext(Dispatchers.IO) {
        val dir = PdfCache.dir(cacheDir)
        val f = PdfCache.fileFor(dir, file.id, file.chdate)
        if (f.exists() && !PdfRules.looksLikePdf(f)) f.delete()
        if (f.exists()) return@withContext PdfResult(f, null)

        var direct: String? = null
        var bytes: ByteArray? = null
        val uni = universities.load(session.university)
        val decision = FetchPolicy.decide(file, uni)
        if (decision is FetchPolicy.Decision.Direct && uni != null) {
            try {
                val got = DirectDownload.fetch(JvmTransport(DIRECT_TIMEOUT_MS), DirectDownload.request(decision.url, decision.source, uni))
                if (PdfRules.isPdf(got)) { bytes = got; direct = decision.source }
                else Log.w(TAG, "Direkt-Download ${file.id}: keine PDF (${got.size} Bytes), Rueckfall auf den Dienst")
            } catch (e: DirectDownload.SessionExpired) {
                Log.w(TAG, "Hochschul-Sitzung abgelaufen (${e.message}), Rueckfall auf den Dienst")
                universities.markExpired(session.university)
            } catch (e: ApiError) {
                Log.w(TAG, "Direkt-Download ${file.id} fehlgeschlagen (${e.message}), Rueckfall auf den Dienst")
            }
        }
        val data = bytes ?: client().getBytes("/api/files/${file.id}/content")
        PdfCache.store(dir, f, data, origin = if (direct != null) "Die Hochschule" else "Der Server")
        if (direct != null) report(file, f, data)
        PdfResult(f, direct)
    }

    /** Wie [pdf], nur die Datei. */
    suspend fun pdfFile(file: LibraryFile): File = pdf(file).file

    /**
     * Fingerabdruck und Seitentext an den Dienst, im Hintergrund; Fehler werden nur protokolliert. Der Seitentext folgt
     * nur einem angenommenen Fingerabdruck: lehnt der Dienst ihn ab (Datei liegt schon beim Dienst, 400; andere Fassung
     * bekannt, 409), will er auch keinen Seitentext dieser Fassung.
     */
    /**
     * Sitzung aus dem Anmeldefenster (nur Cookies) in den Tresor des Kontos, im Hintergrund: der Abgleich im Dienst
     * (Kurse, Termine, Dateiliste) laeuft damit ohne gespeicherte Zugangsdaten. Fehler werden nur protokolliert.
     */
    fun reportUniversitySession(s: UniversitySession) {
        background.launch(Dispatchers.IO) {
            runCatching { DeviceSyncApi(client()).reportSession(s) }
                .onFailure { Log.w(TAG, "Hochschul-Sitzung nicht an den Dienst gemeldet: ${it.message}") }
        }
    }

    private fun report(file: LibraryFile, f: File, bytes: ByteArray) {
        background.launch(Dispatchers.IO) {
            val api = DeviceSyncApi(client())
            val accepted = runCatching { api.reportFingerprint(file.id, Sha256.hex(bytes)) }
                .onFailure { Log.w(TAG, "Fingerabdruck ${file.id} nicht gemeldet: ${it.message}") }.isSuccess
            if (!accepted) return@launch
            val pages = PageTextRules.collect(pageText, f)
            if (pages.isNotEmpty()) runCatching { api.reportPageText(file.id, pages) }
                .onFailure { Log.w(TAG, "Seitentext ${file.id} nicht gemeldet: ${it.message}") }
        }
    }

    /** Cache-Datei verwerfen (z. B. wenn der Renderer sie nicht oeffnen kann); der naechste Aufruf von `pdfFile` laedt neu. */
    fun discardPdf(f: File) { f.delete() }

    suspend fun loadAnnotations(fileId: String): AnnotationStore.Loaded = withContext(Dispatchers.IO) { AnnotationStore(client()).load(fileId) }

    /** Lokaler Entwurf der Datei (ungesendeter Stand vom letzten Mal) oder null. */
    suspend fun loadDraft(fileId: String): Draft? = withContext(Dispatchers.IO) { drafts.read(fileId) }

    suspend fun saveAnnotations(fileId: String, local: JsonObject, base: JsonObject?, baseVersion: Int): AnnotationStore.Saved = withContext(Dispatchers.IO) {
        AnnotationStore(client()).save(fileId, local, base, baseVersion)
    }

    companion object {
        private const val TAG = "UniFlow"

        /** Server-Logout im Hintergrund: kurz, die Oberflaeche wartet nicht darauf. */
        const val LOGOUT_TIMEOUT_MS = 5_000

        /** Direkt-Download von der Hochschule: grosse Skripte ueber langsames WLAN. */
        const val DIRECT_TIMEOUT_MS = 120_000
    }
}
