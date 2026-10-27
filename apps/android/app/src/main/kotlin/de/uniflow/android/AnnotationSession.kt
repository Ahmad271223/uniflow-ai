package de.uniflow.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject

/**
 * Notizstand eines geoeffneten Dokuments mit serialisiertem Speichern und lokalem Entwurf (reines Kotlin, im JVM-Test
 * pruefbar).
 *
 * - Nie zwei Speichervorgaenge gleichzeitig: `save` haelt einen Mutex; ein zweiter Aufruf wartet und findet danach
 *   meist nichts Ungesendetes mehr vor.
 * - Striche, die waehrend des Sendens dazukommen, gehen nicht verloren: der bestaetigte Serverstand ersetzt den lokalen
 *   nur, wenn der seit dem Senden unveraendert ist. Sonst werden die neuen Striche auf den bestaetigten Stand gelegt
 *   (Drei-Wege-Zusammenfuehrung mit dem gesendeten Stand als Basis, so bleiben auch vom Server zusammengefuehrte
 *   Striche anderer Geraete) und sofort erneut gesendet.
 * - Fehler bleiben als `status` sichtbar und `dirty` bleibt gesetzt; der naechste `save` versucht es erneut.
 * - `base`/`baseVersion` sind der letzte vom Server bestaetigte Stand; 409 loest AnnotationStore selbst auf.
 * - Entwurf (`drafts`): jede Aenderung wird entprellt (`draftDelayMs`) als Entwurf abgelegt, vor jedem Senden aus dem
 *   Hintergrund und bei jedem Fehlschlag sofort. Geloescht wird er erst, wenn der Dienst das Speichern bestaetigt hat
 *   (2xx); scheitert das Senden, wird die Nachlieferung eingeplant. Beim Oeffnen fuehrt `loaded` einen vorhandenen
 *   Entwurf mit dem Serverstand nach den gemeinsamen Regeln zusammen (AnnotationDocument.mergeDetailed: Entwurf gewinnt
 *   bei Feldern, Seitenreihenfolge-Konflikt wird sichtbar) und sendet ihn als ungesendet weiter.
 */
class AnnotationSession(
    val fileId: String,
    private val send: suspend (local: JsonObject, base: JsonObject?, baseVersion: Int) -> AnnotationStore.Saved,
    private val drafts: Drafts? = null,
    private val draftScope: CoroutineScope? = null,
    private val draftDelayMs: Long = DRAFT_DELAY_MS,
) {
    /** Ablage und Nachlieferung der Entwuerfe (Android: DraftKeeper mit DraftStore und WorkManager). */
    interface Drafts {
        suspend fun write(draft: Draft)
        suspend fun clear(fileId: String)
        fun scheduleUpload(fileId: String)
        fun cancelUpload(fileId: String)
    }

    /** Kleiner Status des Entwurfs fuer die Anzeige (`label` null = nichts anzeigen). */
    enum class DraftState(val label: String?) {
        None(null),
        Pending("ungesendet"),
        Saved("Entwurf gespeichert"),
        Sending("wird gesendet"),
        Sent("gesendet"),
        Queued("Entwurf gespeichert – wird nachgeliefert"),
        Conflict("Konflikt"),
    }

    /** Ergebnis der Wiederherstellung eines Entwurfs beim Oeffnen. */
    data class Restored(val conflicts: Int, val orderConflict: Boolean, val fromFailedUpload: Boolean)

    var doc: JsonObject by mutableStateOf(AnnotationDocument.empty())
        private set
    var base: JsonObject? = null
        private set
    var baseVersion: Int = 0
        private set
    var dirty: Boolean by mutableStateOf(false)
        private set
    var saving: Boolean by mutableStateOf(false)
        private set
    var status: String by mutableStateOf("Lade …")
    var draftState: DraftState by mutableStateOf(DraftState.None)
        private set
    var restored: Restored? = null
        private set

    /** Anzahl der Sendevorgaenge (Diagnose, Tests). */
    var sends: Int = 0
        private set

    private val mutex = Mutex()
    private val draftMutex = Mutex()
    private var draftJob: Job? = null

    /**
     * Geladener Serverstand; `base` nur, wenn der Server schon Notizen hat (Version > 0). Mit `draft` (Entwurf vom
     * letzten Mal, ungesendet): ist der Server seit dem Entwurf unveraendert, gilt der Entwurf unveraendert; sonst wird
     * er mit dem Serverstand zusammengefuehrt (Basis = Basis des Entwurfs). In beiden Faellen bleibt er ungesendet.
     */
    fun loaded(l: AnnotationStore.Loaded, draft: Draft? = null) {
        if (draft == null) {
            doc = l.doc; base = if (l.version > 0) l.doc else null; baseVersion = l.version; dirty = false
            draftState = DraftState.None; restored = null
            status = if (l.version > 0) "Notizen geladen (Version ${l.version})" else "Noch keine Notizen"
            return
        }
        var conflicts = 0; var orderConflict = false
        if (l.version == draft.baseVersion) {
            doc = draft.doc; base = draft.base; baseVersion = draft.baseVersion
        } else {
            val m = AnnotationDocument.mergeDetailed(draft.base, draft.doc, l.doc)
            doc = m.doc; base = if (l.version > 0) l.doc else null; baseVersion = l.version
            conflicts = m.conflicts; orderConflict = m.orderConflict
        }
        dirty = true
        restored = Restored(conflicts, orderConflict, draft.conflict)
        draftState = if (draft.conflict || conflicts > 0) DraftState.Conflict else DraftState.Saved
        status = when {
            draft.conflict -> "Konflikt – Entwurf konnte im Hintergrund nicht gesendet werden; mit dem Serverstand zusammengeführt, dieses Gerät gilt"
            orderConflict -> "Entwurf wiederhergestellt – Seitenreihenfolge auf beiden Geräten geändert, die Reihenfolge dieses Geräts gilt"
            conflicts > 0 -> "Entwurf wiederhergestellt – mit anderem Gerät zusammengeführt, $conflicts Konflikt${if (conflicts > 1) "e" else ""}, dieses Gerät gilt"
            else -> "Entwurf wiederhergestellt (noch nicht gesendet)"
        }
    }

    /** Lokale Aenderung (Strich dazu, Radierer); ab jetzt ungesendet, Entwurf folgt entprellt. */
    fun edit(change: (JsonObject) -> JsonObject) {
        doc = change(doc); dirty = true
        draftState = DraftState.Pending
        scheduleDraft()
    }

    private fun scheduleDraft() {
        if (drafts == null) return
        val scope = draftScope ?: return
        draftJob?.cancel()
        draftJob = scope.launch { delay(draftDelayMs); writeDraft() }
    }

    /** Entwurf jetzt ablegen (nur, wenn etwas ungesendet ist); ein Fehler der Ablage bleibt folgenlos, die naechste Aenderung versucht es erneut. */
    suspend fun writeDraftNow() { draftJob?.cancel(); writeDraft() }

    private suspend fun writeDraft() {
        val sink = drafts ?: return
        draftMutex.withLock {
            if (!dirty) return
            val d = Draft(fileId, doc, base, baseVersion, System.currentTimeMillis())
            try { sink.write(d); if (draftState == DraftState.Pending) draftState = DraftState.Saved }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { }                                           // Ablage fehlgeschlagen (Speicher voll): Stand bleibt im Speicher
        }
    }

    private suspend fun clearDraft() {
        val sink = drafts ?: return
        draftMutex.withLock { runCatching { sink.clear(fileId) } }
        sink.cancelUpload(fileId)
    }

    /**
     * Sendet, bis nichts Ungesendetes mehr da ist. false, wenn der Server nicht erreicht wurde (`status` sagt warum);
     * dann liegt der Entwurf auf der Platte und die Nachlieferung ist eingeplant.
     */
    suspend fun save(): Boolean = mutex.withLock {
        saving = true
        var sentSomething = false
        if (dirty) draftState = DraftState.Sending
        try {
            while (dirty) {
                val sent = doc
                val s = try { sends++; send(sent, base, baseVersion) }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) {
                    status = "Nicht gespeichert: ${e.message ?: e.toString()}"
                    writeDraftNow()                                             // Entwurf sicher, bevor der Hintergrund uebernimmt
                    drafts?.scheduleUpload(fileId)
                    draftState = if (drafts != null) DraftState.Queued else DraftState.Pending
                    return false
                }
                sentSomething = true
                base = s.doc; baseVersion = s.version
                if (doc === sent) { doc = s.doc; dirty = false; draftJob?.cancel(); clearDraft() }
                else doc = AnnotationDocument.merge(sent, doc, s.doc).first       // inzwischen gezeichnet: darauflegen, erneut senden
                status = if (s.mergedConflicts > 0) "Gespeichert, ${s.mergedConflicts} Stellen zusammengeführt" else "Gespeichert (Version ${s.version})"
            }
            if (sentSomething) draftState = DraftState.Sent
            true
        } finally { saving = false }
    }

    /**
     * Ungesendetes im Hintergrund sichern (Verlassen der Ansicht, App in den Hintergrund): Nachlieferung einplanen (falls
     * das Senden hier nicht mehr zu Ende kommt), Entwurf sofort ablegen, senden. Nichts zu tun, wenn alles gesendet ist.
     */
    fun flush(scope: CoroutineScope) {
        if (!dirty) return
        drafts?.scheduleUpload(fileId)
        scope.launch { writeDraftNow(); save() }
    }

    companion object {
        /** Entprellung des Entwurfs: zwischen zwei Strichen, nicht bei jedem Punkt. */
        const val DRAFT_DELAY_MS = 500L
    }
}
