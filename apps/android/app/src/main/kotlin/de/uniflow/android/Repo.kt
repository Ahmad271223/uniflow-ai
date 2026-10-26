package de.uniflow.android

import de.uniflow.core.AccountApi
import de.uniflow.core.AnnotationStore
import de.uniflow.core.ApiClient
import de.uniflow.core.CalendarRange
import de.uniflow.core.Dashboard
import de.uniflow.core.Library
import de.uniflow.core.LibraryFile
import de.uniflow.core.LoginResult
import de.uniflow.core.TimetableWeek
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject

/** Alle Serverzugriffe der Oberflaeche, blockierend im IO-Dispatcher; PDFs werden im Cache des Geraets abgelegt. */
class Repo(private val session: Session, private val cacheDir: File) {

    private fun client(): ApiClient = session.client()

    suspend fun login(url: String, email: String, password: String): LoginResult = withContext(Dispatchers.IO) {
        val c = ApiClient(SessionRules.normalizeUrl(url), de.uniflow.core.JvmTransport())
        AccountApi(c).login(email, password, session.deviceId, android.os.Build.MODEL)
    }

    suspend fun register(url: String, email: String, password: String, university: String): LoginResult = withContext(Dispatchers.IO) {
        val c = ApiClient(SessionRules.normalizeUrl(url), de.uniflow.core.JvmTransport())
        AccountApi(c).register(email, password, university, session.deviceId, android.os.Build.MODEL)
    }

    /** PC im WLAN: die PIN wird mit einem Aufruf der Einstellungen geprueft (401 = falsch). */
    suspend fun checkPin(url: String, pin: String): String = withContext(Dispatchers.IO) {
        val c = ApiClient(SessionRules.normalizeUrl(url), de.uniflow.core.JvmTransport(), de.uniflow.core.Auth.Pin(pin))
        c.get("/api/settings").let { de.uniflow.core.ApiClient.str(it, "university") ?: "luh" }
    }

    suspend fun logout() = withContext(Dispatchers.IO) {
        if (session.token != null) runCatching { AccountApi(client()).logout() }
        session.clear()
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
        de.uniflow.core.ApiClient.str(j, "started") ?: "Sync"
    }

    /** PDF aus dem Cache oder vom Server (unveraenderte Originalbytes); Cache-Schluessel enthaelt die Aenderungszeit. */
    suspend fun pdfFile(file: LibraryFile): File = withContext(Dispatchers.IO) {
        val dir = File(cacheDir, "pdf").apply { mkdirs() }
        val f = File(dir, "${file.id}-${file.chdate ?: 0}.pdf")
        if (!f.exists() || f.length() == 0L) {
            val bytes = client().getBytes("/api/files/${file.id}/content")
            val tmp = File(dir, f.name + ".part")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
        }
        f
    }

    suspend fun loadAnnotations(fileId: String): AnnotationStore.Loaded = withContext(Dispatchers.IO) { AnnotationStore(client()).load(fileId) }

    suspend fun saveAnnotations(fileId: String, local: JsonObject, base: JsonObject?, baseVersion: Int): AnnotationStore.Saved = withContext(Dispatchers.IO) {
        AnnotationStore(client()).save(fileId, local, base, baseVersion)
    }
}
