package de.uniflow.android

import de.uniflow.core.ApiError
import de.uniflow.core.i
import de.uniflow.core.o
import de.uniflow.core.s
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Lokaler Entwurf eines Dokuments: der ungesendete Notizstand samt der Basis (letzter bestaetigter Serverstand und
 * dessen Version), gegen die er beim Senden oder beim naechsten Oeffnen zusammengefuehrt wird. `attempts`, `conflict`
 * und `lastError` schreibt die Nachlieferung im Hintergrund (DraftUploadRules), `savedAt` erkennt, ob der Entwurf
 * seit dem Lesen ersetzt wurde.
 */
data class Draft(
    val fileId: String,
    val doc: JsonObject,
    val base: JsonObject?,
    val baseVersion: Int,
    val savedAt: Long,
    val attempts: Int = 0,
    val conflict: Boolean = false,
    val lastError: String? = null,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("format", FORMAT); put("fileId", fileId); put("doc", doc)
        if (base != null) put("base", base)
        put("baseVersion", baseVersion); put("savedAt", savedAt); put("attempts", attempts); put("conflict", conflict)
        if (lastError != null) put("lastError", lastError)
    }

    companion object {
        const val FORMAT = 1

        /** null, wenn die Daten kein Entwurf sind (beschaedigt, anderes Format). */
        fun fromJson(e: JsonElement?): Draft? {
            val j = e as? JsonObject ?: return null
            val fileId = j.s("fileId") ?: return null
            val doc = j.o("doc") ?: return null
            val savedAt = (j["savedAt"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return null
            return Draft(fileId, doc, j.o("base"), j.i("baseVersion") ?: 0, savedAt, j.i("attempts") ?: 0,
                (j["conflict"] as? JsonPrimitive)?.content == "true", j.s("lastError"))
        }
    }
}

/**
 * Ablage der Entwuerfe im App-Speicher (`files/drafts/<id>.json`; reines Kotlin, im JVM-Test pruefbar). Geschrieben wird
 * wie bei PdfCache erst in eine `.tmp`-Datei (mit fsync), die dann umbenannt wird: unter dem endgueltigen Namen liegt
 * nie ein halber Entwurf, und ein Abbruch waehrend des Schreibens laesst den vorigen Entwurf unangetastet.
 */
class DraftStore(val dir: File) {

    fun fileFor(fileId: String): File = File(dir, safeName(fileId) + ".json")

    fun write(d: Draft) {
        dir.mkdirs()
        val f = fileFor(d.fileId)
        val tmp = File(dir, f.name + ".tmp")
        FileOutputStream(tmp).use { out -> out.write(d.toJson().toString().toByteArray(Charsets.UTF_8)); out.fd.sync() }
        if (!tmp.renameTo(f)) {
            f.delete()
            if (!tmp.renameTo(f)) { tmp.delete(); throw IOException("Entwurf konnte nicht abgelegt werden: ${f.name}") }
        }
    }

    /** Entwurf der Datei oder null (keiner da, beschaedigt, gehoert zu einer anderen Datei). */
    fun read(fileId: String): Draft? = parse(fileFor(fileId))?.takeIf { it.fileId == fileId }

    fun delete(fileId: String) {
        val f = fileFor(fileId)
        f.delete(); File(dir, f.name + ".tmp").delete()
    }

    /**
     * Loescht den Entwurf nur, wenn er noch der gelesene ist (`savedAt` gleich): hat die Ansicht inzwischen einen
     * neueren geschrieben, bleibt der erhalten. true, wenn geloescht oder keiner mehr da.
     */
    fun deleteIfUnchanged(expected: Draft): Boolean {
        val cur = read(expected.fileId) ?: return true
        if (cur.savedAt != expected.savedAt) return false
        delete(expected.fileId); return true
    }

    /** Ersetzt den Entwurf nur, wenn er noch der gelesene ist (siehe deleteIfUnchanged). */
    fun replaceIfUnchanged(expected: Draft, replacement: Draft): Boolean {
        val cur = read(expected.fileId)
        if (cur != null && cur.savedAt != expected.savedAt) return false
        write(replacement); return true
    }

    /** Alle abgelegten Entwuerfe (fuer die Nachlieferung beim App-Start); `.tmp`-Reste, Beschaedigtes und falsch benannte Dateien zaehlen nicht. */
    fun pending(): List<Draft> =
        dir.listFiles { f -> f.isFile && f.name.endsWith(".json") }?.mapNotNull { f -> parse(f)?.takeIf { fileFor(it.fileId) == f } } ?: emptyList()

    private fun parse(f: File): Draft? {
        if (!f.isFile) return null
        return runCatching { Draft.fromJson(Json.parseToJsonElement(f.readText(Charsets.UTF_8))) }.getOrNull()
    }

    companion object {
        fun dir(filesDir: File): File = File(filesDir, "drafts")

        /** Dateiname aus der Datei-ID: nur Buchstaben, Ziffern, `.`, `_`, `-`; der Rest wird zu `_` (die ID steht im Inhalt). */
        fun safeName(fileId: String): String = fileId.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "_" }
    }
}

/**
 * Anbindung der Ablage an AnnotationSession: Schreiben und Loeschen im IO-Dispatcher, die Nachlieferung uebernimmt der
 * Aufrufer (WorkManager, siehe DraftUploadWorker) ueber `schedule`/`cancel`.
 */
class DraftKeeper(private val store: DraftStore, private val schedule: (String) -> Unit, private val cancel: (String) -> Unit) : AnnotationSession.Drafts {
    override suspend fun write(draft: Draft) = withContext(Dispatchers.IO) { store.write(draft) }
    override suspend fun clear(fileId: String) = withContext(Dispatchers.IO) { store.delete(fileId) }
    override fun scheduleUpload(fileId: String) = schedule(fileId)
    override fun cancelUpload(fileId: String) = cancel(fileId)
}

/**
 * Entscheidungslogik der Nachlieferung (reines Kotlin, ohne WorkManager): Entwurf lesen, senden, nach der Antwort des
 * Dienstes Erfolg, Wiederholung oder Abbruch. Der Entwurf wird erst geloescht, wenn der Dienst das Speichern bestaetigt
 * hat (2xx); 409 loest `AnnotationStore.save` selbst auf (Serverstand holen, zusammenfuehren, erneut senden, hoechstens
 * 3 Versuche) – bleibt es dabei, wird der Entwurf mit `conflict` behalten und beim naechsten Oeffnen sichtbar gemacht.
 */
object DraftUploadRules {
    const val WORK_PREFIX = "draft-upload-"

    /** Erster Abstand der exponentiellen Wiederholung (WorkManager verdoppelt bis hoechstens 5 Stunden). */
    const val BACKOFF_SECONDS = 30L

    fun workName(fileId: String): String = WORK_PREFIX + fileId

    sealed interface Outcome {
        /** Gesendet (oder nichts mehr zu senden): Entwurf geloescht. */
        data object Success : Outcome
        /** Dienst nicht erreichbar oder voruebergehend gestoert: Entwurf bleibt, spaeter erneut. */
        data object Retry : Outcome
        /** Ohne Aenderung sinnlos zu wiederholen (Konflikt nicht aufloesbar, Anmeldung fehlt, Datei unbekannt): Entwurf bleibt. */
        data class Failure(val conflict: Boolean, val reason: String) : Outcome
    }

    /** Status, der eine Wiederholung lohnt: kein Netz (0), Server gestoert (5xx), Zeitueberschreitung (408), zu viele Anfragen (429). */
    fun shouldRetry(status: Int): Boolean = status == 0 || status in 500..599 || status == 408 || status == 429

    /** Antwort des Dienstes (null = 2xx) -> was der Worker tut. */
    fun outcome(error: Throwable?): Outcome = when {
        error == null -> Outcome.Success
        error is ApiError && error.status == 409 -> Outcome.Failure(conflict = true, reason = error.message ?: "Konflikt")
        error is ApiError && shouldRetry(error.status) -> Outcome.Retry
        error is ApiError -> Outcome.Failure(conflict = false, reason = error.message ?: "HTTP ${error.status}")
        else -> Outcome.Retry                                                     // Unerwartetes (IO): spaeter erneut
    }

    /**
     * Ein Sendeversuch fuer den Entwurf der Datei. Ein waehrenddessen von der Ansicht geschriebener neuerer Entwurf wird
     * weder geloescht noch ueberschrieben (savedAt-Vergleich).
     */
    suspend fun upload(fileId: String, store: DraftStore, send: suspend (Draft) -> Unit): Outcome {
        val d = store.read(fileId) ?: return Outcome.Success
        val error = try { send(d); null } catch (e: CancellationException) { throw e } catch (e: Exception) { e }
        val out = outcome(error)
        when (out) {
            Outcome.Success -> store.deleteIfUnchanged(d)
            Outcome.Retry -> store.replaceIfUnchanged(d, d.copy(attempts = d.attempts + 1, lastError = error?.message))
            is Outcome.Failure -> store.replaceIfUnchanged(d, d.copy(attempts = d.attempts + 1, conflict = out.conflict, lastError = out.reason))
        }
        return out
    }
}
