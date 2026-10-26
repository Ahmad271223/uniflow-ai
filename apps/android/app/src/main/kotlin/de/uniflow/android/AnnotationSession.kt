package de.uniflow.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject

/**
 * Notizstand eines geoeffneten Dokuments mit serialisiertem Speichern (reines Kotlin, im JVM-Test pruefbar).
 *
 * - Nie zwei Speichervorgaenge gleichzeitig: `save` haelt einen Mutex; ein zweiter Aufruf wartet und findet danach
 *   meist nichts Ungesendetes mehr vor.
 * - Striche, die waehrend des Sendens dazukommen, gehen nicht verloren: der bestaetigte Serverstand ersetzt den lokalen
 *   nur, wenn der seit dem Senden unveraendert ist. Sonst werden die neuen Striche auf den bestaetigten Stand gelegt
 *   (Drei-Wege-Zusammenfuehrung mit dem gesendeten Stand als Basis, so bleiben auch vom Server zusammengefuehrte
 *   Striche anderer Geraete) und sofort erneut gesendet.
 * - Fehler bleiben als `status` sichtbar und `dirty` bleibt gesetzt; der naechste `save` versucht es erneut.
 * - `base`/`baseVersion` sind der letzte vom Server bestaetigte Stand; 409 loest AnnotationStore selbst auf.
 */
class AnnotationSession(
    val fileId: String,
    private val send: suspend (local: JsonObject, base: JsonObject?, baseVersion: Int) -> AnnotationStore.Saved,
) {
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

    /** Anzahl der Sendevorgaenge (Diagnose, Tests). */
    var sends: Int = 0
        private set

    private val mutex = Mutex()

    /** Geladener Serverstand; `base` nur, wenn der Server schon Notizen hat (Version > 0). */
    fun loaded(l: AnnotationStore.Loaded) {
        doc = l.doc; base = if (l.version > 0) l.doc else null; baseVersion = l.version; dirty = false
        status = if (l.version > 0) "Notizen geladen (Version ${l.version})" else "Noch keine Notizen"
    }

    /** Lokale Aenderung (Strich dazu, Radierer); ab jetzt ungesendet. */
    fun edit(change: (JsonObject) -> JsonObject) { doc = change(doc); dirty = true }

    /** Sendet, bis nichts Ungesendetes mehr da ist. false, wenn der Server nicht erreicht wurde (`status` sagt warum). */
    suspend fun save(): Boolean = mutex.withLock {
        saving = true
        try {
            while (dirty) {
                val sent = doc
                val s = try { sends++; send(sent, base, baseVersion) }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) { status = "Nicht gespeichert: ${e.message ?: e.toString()}"; return false }
                base = s.doc; baseVersion = s.version
                if (doc === sent) { doc = s.doc; dirty = false }
                else doc = AnnotationDocument.merge(sent, doc, s.doc).first       // inzwischen gezeichnet: darauflegen, erneut senden
                status = if (s.mergedConflicts > 0) "Gespeichert, ${s.mergedConflicts} Stellen zusammengeführt" else "Gespeichert (Version ${s.version})"
            }
            true
        } finally { saving = false }
    }

    /** Ungesendetes im Hintergrund sichern (Verlassen der Ansicht, App in den Hintergrund); nichts zu tun, wenn alles gesendet ist. */
    fun flush(scope: CoroutineScope) { if (dirty) scope.launch { save() } }
}
