package de.uniflow.android

import android.util.Log
import de.uniflow.core.AccountApi
import de.uniflow.core.AnnotationDocument
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
import de.uniflow.core.LocalStore
import de.uniflow.core.LocalViews
import de.uniflow.core.LoginResult
import de.uniflow.core.Sha256
import de.uniflow.core.SyncApi
import de.uniflow.core.SyncClock
import de.uniflow.core.SyncEngine
import de.uniflow.core.TimetableWeek
import de.uniflow.core.UniversityProfile
import de.uniflow.core.UniversitySession
import de.uniflow.core.i
import de.uniflow.core.o
import de.uniflow.core.s
import java.io.File
import java.time.LocalDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Alle Serverzugriffe der Oberflaeche, blockierend im IO-Dispatcher; PDFs werden im Cache des Geraets abgelegt.
 * Hochschuldateien kommen, wenn eine Hochschul-Sitzung dieses Geraets vorliegt, direkt von Stud.IP bzw. dem Learnweb
 * (`universities`), sonst wie bisher ueber den Dienst. `pageText` liest nach einem Direkt-Download den Seitentext fuer
 * die Meldung an den Dienst; `background` traegt die Meldungen ueber die Ansicht hinaus.
 *
 * Offline: Jede Ansicht hat eine lokale Form (`localX`, sofort aus der Ablage [LocalStore]) und eine frische
 * (`x()`, vom Dienst; legt die Antwort als Momentaufnahme ab). Faellt der Dienst aus (kein Netz, 5xx), liefert `x()`
 * die Ablage mit `offline = true` und dem Zeitpunkt der Momentaufnahme. Lernpakete und Aufgaben kommen aus den
 * G2-Zeilen der Ablage (`syncNow`: Push der eigenen Aenderungen, Pull der fremden); Abhaken schreibt nur lokal und
 * laesst den Abgleich nachliefern (`schedulePush`, WorkManager).
 */
class Repo(private val session: Session, private val cacheDir: File, val universities: UniversityStore, val drafts: DraftStore,
           val local: LocalStore, private val pageText: PageTextExtractor = PageTextExtractor.None,
           private val background: CoroutineScope = AppScope.main, private val schedulePush: () -> Unit = {}) {

    private fun client(): ApiClient = session.client()
    private val syncLock = Mutex()

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
     * das Token schon weg. Mit PIN (PC im WLAN) gibt es nichts beim Server zu tun. Die lokale Ablage wird geleert
     * (ein anderes Konto erbt nichts) – offene lokale Aenderungen gehen dabei verloren, die Oberflaeche weist vorher darauf hin.
     */
    fun logout(background: CoroutineScope) {
        val token = session.token
        val url = session.baseUrl
        session.clear()
        universities.clearAll()          // Hochschul-Sitzungen gehoeren zur Person, nicht zum Geraet: ein anderes Konto erbt sie nicht
        runCatching { local.clearAll() }.onFailure { Log.w(TAG, "Lokale Ablage nicht geleert: ${it.message}") }
        if (token != null && url.isNotEmpty()) background.launch(Dispatchers.IO) {
            runCatching { AccountApi(ApiClient(url, JvmTransport(LOGOUT_TIMEOUT_MS), Auth.Bearer(token))).logout() }
        }
    }

    /** Offene lokale Aenderungen, die noch nicht beim Dienst sind. */
    fun pendingCount(): Int = runCatching { local.pendingCount() }.getOrDefault(0)

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

    // ---- Geraete-Abgleich (G2) ----

    /** Eigene Aenderungen senden, fremde holen; nie zwei Laeufe gleichzeitig (ein zweiter wartet und findet nichts Ungesendetes mehr). */
    suspend fun syncNow(): SyncEngine.Report = withContext(Dispatchers.IO) {
        syncLock.withLock { SyncEngine(local, SyncApi(client()), session.deviceId).sync() }
    }

    /** Abgleich fuer eine Ansicht: Fehler werden gemeldet, nicht geworfen (die Ansicht zeigt dann den letzten Stand). */
    private suspend fun trySync(): Throwable? = try { syncNow(); null } catch (e: CancellationException) { throw e } catch (e: Exception) {
        Log.w(TAG, "Geraete-Abgleich: ${e.message}"); e
    }

    // ---- Ansichten: frisch vom Dienst oder aus der Ablage ----

    /** Antwort holen und als Momentaufnahme ablegen. */
    private fun fetchSnapshot(key: String, path: String, query: Map<String, String?> = emptyMap()): JsonElement {
        val j = client().get(path, query)
        local.putSnapshot(key, j)
        return j
    }

    /**
     * Frisch vom Dienst; bei Ausfall (OfflineRules.fallsBackToLocal) der gespeicherte Stand mit `offline = true`.
     * Andere Fehler (401, 404) gehen durch – sie sind eine Aussage des Dienstes, kein Ausfall.
     */
    private inline fun <T> fresh(remote: () -> Stand<T>, fallback: () -> Stand<T>?): Stand<T> = try { remote() } catch (e: Exception) {
        if (e is CancellationException || !OfflineRules.fallsBackToLocal(e)) throw e
        Log.w(TAG, "Dienst nicht erreichbar (${e.message}), zeige den gespeicherten Stand")
        fallback()?.copy(note = e.message) ?: throw e
    }

    private fun <T> fromSnapshot(key: String, parse: (JsonElement) -> T): Stand<T>? = local.snapshot(key)?.let { Stand(parse(it.json), it.fetchedAt, offline = true) }

    fun localLibrary(): Stand<Library>? = fromSnapshot(KEY_LIBRARY) { Library.from(it) }
    suspend fun library(): Stand<Library> = withContext(Dispatchers.IO) {
        fresh({ Stand(Library.from(fetchSnapshot(KEY_LIBRARY, "/api/library")), SyncClock.now(), offline = false) }, { localLibrary() })
    }

    fun localDashboard(): Stand<Dashboard>? {
        val snap = local.snapshot(KEY_DASHBOARD)
        val d = LocalViews.dashboard(local, snap?.let { Dashboard.from(it.json) }) ?: return null
        return Stand(d, snap?.fetchedAt ?: local.lastSyncAt, offline = true, pending = pendingCount())
    }
    suspend fun dashboard(): Stand<Dashboard> = withContext(Dispatchers.IO) {
        val syncError = trySync()
        fresh({
            val d = LocalViews.dashboard(local, Dashboard.from(fetchSnapshot(KEY_DASHBOARD, "/api/dashboard")))!!
            Stand(d, SyncClock.now(), offline = false, note = syncError?.let { "Geräte-Abgleich: ${it.message}" }, pending = pendingCount())
        }, { localDashboard() })
    }

    fun localTimetableWeek(start: String): Stand<TimetableWeek>? {
        val snap = local.snapshot(KEY_TIMETABLE + start)
        val week = LocalViews.timetable(local, LocalDate.parse(start), snap?.let { TimetableWeek.from(it.json) }) ?: return null
        return Stand(week, snap?.fetchedAt ?: local.lastSyncAt, offline = true, note = if (snap == null) "Termine aus dem letzten Abgleich, ohne Feiertage und Fristen" else null)
    }
    suspend fun timetableWeek(start: String): Stand<TimetableWeek> = withContext(Dispatchers.IO) {
        fresh({ Stand(TimetableWeek.from(fetchSnapshot(KEY_TIMETABLE + start, "/api/timetable/week", mapOf("start" to start))), SyncClock.now(), offline = false) },
            { localTimetableWeek(start) })
    }

    fun localCalendar(start: String, end: String): Stand<CalendarRange>? {
        val snap = local.snapshot("$KEY_CALENDAR$start:$end")
        if (snap == null && local.cursor == null) return null
        val range = LocalViews.calendar(local, start, end, snap?.let { CalendarRange.from(it.json) })
        return Stand(range, snap?.fetchedAt ?: local.lastSyncAt, offline = true, pending = pendingCount())
    }
    /** Lernkalender: erst Abgleich (eigene Haken senden, fremde Aenderungen holen), dann Feiertage/Fristen/Termine der Woche vom Dienst. */
    suspend fun calendar(start: String, end: String): Stand<CalendarRange> = withContext(Dispatchers.IO) {
        val syncError = trySync()
        fresh({
            val snap = CalendarRange.from(fetchSnapshot("$KEY_CALENDAR$start:$end", "/api/calendar", mapOf("start" to start, "end" to end)))
            Stand(LocalViews.calendar(local, start, end, snap), SyncClock.now(), offline = false,
                note = syncError?.let { "Geräte-Abgleich: ${it.message}" }, pending = pendingCount())
        }, { localCalendar(start, end) })
    }

    /**
     * Aufgabe abhaken: nur in der Ablage (sofort sichtbar, auch ohne Netz), der Abgleich sendet sie als G2-Aenderung
     * (`study_tasks.status`, `done_at`). Kennt die Ablage die Aufgabe nicht (noch nie abgeglichen), geht es wie frueher
     * direkt an den Dienst (POST /api/tasks/{id}/status).
     */
    suspend fun setTaskStatus(taskId: Int, status: String) = withContext(Dispatchers.IO) {
        val data = JsonObject(mapOf("status" to JsonPrimitive(status), "done_at" to (if (status == "erledigt") JsonPrimitive(SyncClock.now()) else JsonNull)))
        if (local.update("study_tasks", taskId.toString(), data)) schedulePush()
        else client().post("/api/tasks/$taskId/status", ApiClient.obj("status" to status))
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
     * Sitzung aus dem Anmeldefenster (nur Cookies) in den Tresor des Kontos, im Hintergrund: der Abgleich im Dienst
     * (Kurse, Termine, Dateiliste) laeuft damit ohne gespeicherte Zugangsdaten. Fehler werden nur protokolliert.
     */
    fun reportUniversitySession(s: UniversitySession) {
        background.launch(Dispatchers.IO) {
            runCatching { DeviceSyncApi(client()).reportSession(s) }
                .onFailure { Log.w(TAG, "Hochschul-Sitzung nicht an den Dienst gemeldet: ${it.message}") }
        }
    }

    /**
     * Fingerabdruck und Seitentext an den Dienst, im Hintergrund; Fehler werden nur protokolliert. Der Seitentext folgt
     * nur einem angenommenen Fingerabdruck: lehnt der Dienst ihn ab (Datei liegt schon beim Dienst, 400; andere Fassung
     * bekannt, 409), will er auch keinen Seitentext dieser Fassung.
     */
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

    /**
     * Notizen vom Dienst; der Stand wird als Momentaufnahme abgelegt. Ohne Verbindung der zuletzt gesehene Stand, sonst
     * die Basis eines vorhandenen Entwurfs (AnnotationSession.loaded stellt den Entwurf dann wieder her), sonst leer mit
     * Version 0 – was offline gezeichnet wird, bleibt Entwurf und wird beim naechsten Senden mit dem Serverstand
     * zusammengefuehrt (409-Regel, fixtures/merge). Die Entwuerfe selbst bleiben in `files/drafts` (DraftStore).
     */
    suspend fun loadAnnotations(fileId: String): AnnotationStore.Loaded = withContext(Dispatchers.IO) {
        try {
            val l = AnnotationStore(client()).load(fileId)
            local.putSnapshot(KEY_ANNOTATIONS + fileId, ApiClient.obj("data" to l.doc, "version" to l.version, "updated_at" to l.updatedAt))
            l
        } catch (e: Exception) {
            if (e is CancellationException || !OfflineRules.fallsBackToLocal(e)) throw e
            Log.w(TAG, "Notizen $fileId nicht vom Dienst (${e.message}), nehme den gespeicherten Stand")
            local.snapshot(KEY_ANNOTATIONS + fileId)?.let { s -> AnnotationStore.Loaded(s.json.o("data") ?: AnnotationDocument.empty(), s.json.i("version") ?: 0, s.json.s("updated_at")) }
                ?: drafts.read(fileId)?.let { d -> AnnotationStore.Loaded(d.base ?: AnnotationDocument.empty(), d.baseVersion, null) }
                ?: AnnotationStore.Loaded(AnnotationDocument.empty(), 0, null)
        }
    }

    /** Lokaler Entwurf der Datei (ungesendeter Stand vom letzten Mal) oder null. */
    suspend fun loadDraft(fileId: String): Draft? = withContext(Dispatchers.IO) { drafts.read(fileId) }

    suspend fun saveAnnotations(fileId: String, local: JsonObject, base: JsonObject?, baseVersion: Int): AnnotationStore.Saved = withContext(Dispatchers.IO) {
        val saved = AnnotationStore(client()).save(fileId, local, base, baseVersion)
        this@Repo.local.putSnapshot(KEY_ANNOTATIONS + fileId, ApiClient.obj("data" to saved.doc, "version" to saved.version))
        saved
    }

    companion object {
        private const val TAG = "UniFlow"

        /** Server-Logout im Hintergrund: kurz, die Oberflaeche wartet nicht darauf. */
        const val LOGOUT_TIMEOUT_MS = 5_000

        /** Direkt-Download von der Hochschule: grosse Skripte ueber langsames WLAN. */
        const val DIRECT_TIMEOUT_MS = 120_000

        /** Schluessel der Momentaufnahmen in der Ablage. */
        const val KEY_LIBRARY = "library"
        const val KEY_DASHBOARD = "dashboard"
        const val KEY_TIMETABLE = "timetable:"
        const val KEY_CALENDAR = "calendar:"
        const val KEY_ANNOTATIONS = "annotations:"
    }
}
