package de.uniflow.android

import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationMerge
import de.uniflow.core.AnnotationStore
import de.uniflow.core.ApiError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlinx.serialization.json.JsonObject

/** Speicherpfad der Notizen: serialisiert, kein Strich geht waehrend des Sendens verloren, Fehler bleiben sichtbar. */
class AnnotationSessionTest {

    private fun stroke(id: String) = AnnotationDocument.stroke(listOf(1f, 2f, 3f, 4f), id = id)
    private fun ids(doc: JsonObject, key: String = "p1") = AnnotationDocument.objects(doc, key).map { AnnotationMerge.objectId(it) }
    private fun add(session: AnnotationSession, id: String) = session.edit { AnnotationDocument.addObject(it, "p1", stroke(id)) }
    private fun fresh(server: FakeSend) = AnnotationSession("f1", server::send).also { it.loaded(AnnotationStore.Loaded(AnnotationDocument.empty(), 0, null)) }

    /**
     * Attrappe des Servers: bestaetigt jeden Stand mit neuer Version. `gate` haelt den ersten Sendevorgang an (so kann
     * waehrenddessen gezeichnet werden), `extra` legt beim ersten Senden einen fremden Strich dazu (wie eine
     * 409-Zusammenfuehrung in AnnotationStore), `failFirst` laesst den ersten Sendevorgang scheitern.
     */
    private class FakeSend(private val gate: CompletableDeferred<Unit>? = null, private val extra: String? = null, private val failFirst: Boolean = false) {
        var version = 0
        var inFlight = 0
        var maxInFlight = 0
        val calls = ArrayList<Triple<JsonObject, JsonObject?, Int>>()

        suspend fun send(local: JsonObject, base: JsonObject?, baseVersion: Int): AnnotationStore.Saved {
            inFlight++; maxInFlight = maxOf(maxInFlight, inFlight)
            try {
                calls += Triple(local, base, baseVersion)
                if (calls.size == 1) {
                    gate?.await()
                    if (failFirst) throw ApiError(0, "network", "Keine Verbindung")
                }
                val doc = if (calls.size == 1 && extra != null) AnnotationDocument.addObject(local, "p1", AnnotationDocument.stroke(listOf(9f, 9f, 9f, 9f), id = extra)) else local
                version++
                return AnnotationStore.Saved(doc, version, if (doc === local) 0 else 1, 1)
            } finally { inFlight-- }
        }
    }

    @Test
    fun strokeDrawnWhileSavingIsNotLost() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val server = FakeSend(gate)
        val session = fresh(server)
        add(session, "a")
        val job = launch { session.save() }
        yield()                                                 // Senden laeuft und haengt an der Schranke
        assertTrue(session.saving)
        add(session, "b")                                       // waehrend des Sendens gezeichnet
        gate.complete(Unit)
        job.join()
        assertEquals(listOf("a", "b"), ids(session.doc), "der bestaetigte Stand ersetzt den neuen Strich nicht")
        assertFalse(session.dirty); assertFalse(session.saving)
        assertEquals(2, session.sends, "der neue Strich wird gleich nachgesendet")
        assertEquals(2, session.baseVersion)
        assertEquals(listOf("a", "b"), ids(server.calls[1].first))
        assertEquals(1, server.calls[1].third, "zweites Senden mit der bestaetigten Version als base_version")
    }

    @Test
    fun concurrentSavesRunOneAfterAnother() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val server = FakeSend(gate)
        val session = fresh(server)
        add(session, "a")
        val first = launch { session.save() }
        val second = launch { session.save() }                  // „Seite ▶“ zweimal schnell getippt
        yield()
        gate.complete(Unit)
        first.join(); second.join()
        assertEquals(1, server.maxInFlight, "nie zwei Sendevorgaenge gleichzeitig")
        assertEquals(1, session.sends, "der zweite Aufruf findet nichts Ungesendetes mehr vor")
        assertEquals(listOf("a"), ids(session.doc)); assertFalse(session.dirty)
    }

    @Test
    fun remoteStrokesMergedByTheServerSurviveLocalEditsDuringSave() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val server = FakeSend(gate, extra = "r")
        val session = fresh(server)
        add(session, "a")
        val job = launch { session.save() }
        yield()
        add(session, "b")
        gate.complete(Unit)
        job.join()
        assertEquals(listOf("a", "r", "b"), ids(session.doc), "Serverreihenfolge zuerst, dann der hier neue Strich")
        assertFalse(session.dirty)
        assertEquals(2, session.sends)
        assertEquals(listOf("a", "r", "b"), ids(server.calls[1].first), "das zweite Senden enthaelt auch den fremden Strich")
        assertTrue(session.status.startsWith("Gespeichert"), session.status)
    }

    @Test
    fun failureStaysVisibleAndTheNextSaveRetries() = runBlocking {
        val server = FakeSend(failFirst = true)
        val session = fresh(server)
        add(session, "a")
        assertFalse(session.save())
        assertTrue(session.status.startsWith("Nicht gespeichert"), session.status)
        assertTrue(session.dirty, "der Strich bleibt lokal erhalten"); assertFalse(session.saving)
        assertEquals(listOf("a"), ids(session.doc))
        assertTrue(session.save())
        assertFalse(session.dirty); assertEquals(1, session.baseVersion); assertEquals(2, session.sends)
        assertEquals("Gespeichert (Version 1)", session.status)
    }

    @Test
    fun flushSendsOnlyWhenSomethingIsUnsent() {
        val server = FakeSend()
        val session = fresh(server)
        runBlocking { session.flush(this) }
        assertEquals(0, session.sends)
        add(session, "a")
        runBlocking { session.flush(this) }                     // Verlassen der Ansicht, App im Hintergrund
        assertEquals(1, session.sends); assertFalse(session.dirty)
    }

    @Test
    fun loadedServerStateIsTheBaseOnlyWithAVersion() {
        val server = FakeSend()
        val session = AnnotationSession("f1", server::send)
        val doc = AnnotationDocument.addObject(AnnotationDocument.empty(), "p1", stroke("s"))
        session.loaded(AnnotationStore.Loaded(doc, 3, "t"))
        assertEquals(doc, session.doc); assertEquals(doc, session.base); assertEquals(3, session.baseVersion); assertFalse(session.dirty)
        assertEquals("Notizen geladen (Version 3)", session.status)
        session.loaded(AnnotationStore.Loaded(AnnotationDocument.empty(), 0, null))
        assertNull(session.base); assertEquals("Noch keine Notizen", session.status)
        assertTrue(runBlocking { session.save() }, "ohne Aenderung wird nichts gesendet"); assertEquals(0, session.sends)
    }

    // ---- lokaler Entwurf und Nachlieferung ----

    /** Attrappe der Ablage: merkt sich den letzten Entwurf und die eingeplanten/abgesagten Nachlieferungen. */
    private class FakeDrafts : AnnotationSession.Drafts {
        val written = ArrayList<Draft>()
        var stored: Draft? = null
        val scheduled = ArrayList<String>()
        val cancelled = ArrayList<String>()
        override suspend fun write(draft: Draft) { written += draft; stored = draft }
        override suspend fun clear(fileId: String) { stored = null }
        override fun scheduleUpload(fileId: String) { scheduled += fileId }
        override fun cancelUpload(fileId: String) { cancelled += fileId }
    }

    private fun CoroutineScope.withDrafts(server: FakeSend, drafts: FakeDrafts, delayMs: Long = 20) =
        AnnotationSession("f1", server::send, drafts, this, delayMs).also { it.loaded(AnnotationStore.Loaded(AnnotationDocument.empty(), 0, null)) }

    @Test
    fun draftIsWrittenDebouncedAfterEdits() = runBlocking {
        val drafts = FakeDrafts()
        val session = withDrafts(FakeSend(), drafts)
        add(session, "a"); add(session, "b")                     // zwei Striche kurz nacheinander: ein Entwurf
        assertEquals(AnnotationSession.DraftState.Pending, session.draftState); assertEquals(0, drafts.written.size)
        delay(200)
        assertEquals(1, drafts.written.size, "entprellt: ein Entwurf fuer beide Striche")
        assertEquals(listOf("a", "b"), ids(drafts.stored!!.doc)); assertEquals(0, drafts.stored!!.baseVersion); assertNull(drafts.stored!!.base)
        assertEquals(AnnotationSession.DraftState.Saved, session.draftState)
        assertTrue(drafts.scheduled.isEmpty(), "ohne Fehlschlag keine Nachlieferung")
        assertTrue(session.dirty)
    }

    @Test
    fun draftIsDeletedOnlyAfterTheServerConfirmed() = runBlocking {
        val drafts = FakeDrafts()
        val session = withDrafts(FakeSend(failFirst = true), drafts)
        add(session, "a")
        assertFalse(session.save())
        assertEquals(listOf("a"), ids(drafts.stored!!.doc), "Fehlschlag: Entwurf liegt sofort auf der Platte, nicht erst nach der Entprellung")
        assertEquals(listOf("f1"), drafts.scheduled, "Nachlieferung eingeplant")
        assertEquals(AnnotationSession.DraftState.Queued, session.draftState)
        assertTrue(session.status.startsWith("Nicht gespeichert"))
        assertTrue(session.save())
        assertNull(drafts.stored, "erst nach 2xx geloescht")
        assertEquals(listOf("f1"), drafts.cancelled, "Nachlieferung abgesagt")
        assertEquals(AnnotationSession.DraftState.Sent, session.draftState); assertFalse(session.dirty)
        delay(100)
        assertNull(drafts.stored, "die Entprellung schreibt nach dem Senden keinen alten Entwurf mehr")
    }

    @Test
    fun strokeDrawnDuringSaveKeepsItsDraftUntilSent() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val drafts = FakeDrafts()
        val session = withDrafts(FakeSend(gate), drafts)
        add(session, "a")
        val job = launch { session.save() }
        yield()
        assertEquals(AnnotationSession.DraftState.Sending, session.draftState)
        add(session, "b")                                         // waehrend des Sendens gezeichnet
        delay(60)                                                 // Entwurf mit beiden Strichen, waehrend das Senden noch haengt
        assertEquals(listOf("a", "b"), ids(drafts.stored!!.doc))
        gate.complete(Unit)
        job.join()
        assertNull(drafts.stored, "nach dem Nachsenden ist nichts Ungesendetes mehr da"); assertFalse(session.dirty)
        assertEquals(AnnotationSession.DraftState.Sent, session.draftState)
    }

    @Test
    fun flushWritesTheDraftAndSchedulesTheUploadBeforeSending() = runBlocking {
        val drafts = FakeDrafts()
        val session = withDrafts(FakeSend(), drafts)
        session.flush(this)
        assertTrue(drafts.scheduled.isEmpty(), "nichts ungesendet: nichts einplanen")
        add(session, "a")
        session.flush(this)                                       // App in den Hintergrund: einplanen, Entwurf, senden
        assertEquals(listOf("f1"), drafts.scheduled)
        delay(100)
        assertEquals(listOf("a"), ids(drafts.written.single().doc), "Entwurf sofort, nicht erst nach der Entprellung")
        assertNull(drafts.stored); assertEquals(listOf("f1"), drafts.cancelled); assertFalse(session.dirty)
    }
}
