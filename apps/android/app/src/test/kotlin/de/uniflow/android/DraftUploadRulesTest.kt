package de.uniflow.android

import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationMerge
import de.uniflow.core.ApiError
import java.io.IOException
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/** Entscheidungslogik der Nachlieferung (ohne WorkManager): Ergebnis nach Antwortcode, Entwurf erst nach 2xx weg. */
class DraftUploadRulesTest {
    private fun doc(id: String) = AnnotationDocument.addObject(AnnotationDocument.empty(), "p1", AnnotationDocument.stroke(listOf(1f, 2f, 3f, 4f), id = id))
    private fun ids(d: Draft) = AnnotationDocument.objects(d.doc, "p1").map { AnnotationMerge.objectId(it) }

    @Test
    fun outcomeByResponse() {
        assertEquals(DraftUploadRules.Outcome.Success, DraftUploadRules.outcome(null))
        for (status in listOf(0, 500, 502, 503, 408, 429)) assertEquals(DraftUploadRules.Outcome.Retry, DraftUploadRules.outcome(ApiError(status, null, "x")), "Status $status")
        assertEquals(DraftUploadRules.Outcome.Retry, DraftUploadRules.outcome(IOException("Platte")), "Unerwartetes: spaeter erneut")
        assertEquals(DraftUploadRules.Outcome.Failure(true, "nicht zusammengefuehrt"), DraftUploadRules.outcome(ApiError(409, "conflict", "nicht zusammengefuehrt")))
        for (status in listOf(400, 401, 403, 404)) {
            val o = DraftUploadRules.outcome(ApiError(status, null, "HTTP $status"))
            assertEquals(DraftUploadRules.Outcome.Failure(false, "HTTP $status"), o, "Status $status: ohne Aenderung sinnlos zu wiederholen")
        }
        assertEquals("draft-upload-abc", DraftUploadRules.workName("abc"))
    }

    @Test
    fun draftIsDeletedOnlyAfterTheServiceConfirmed() = runBlocking {
        val root = Files.createTempDirectory("uniflow-upload").toFile()
        try {
            val store = DraftStore(DraftStore.dir(root))
            store.write(Draft("f1", doc("a"), null, 0, 10L))
            val sent = ArrayList<Draft>()
            var answer: Throwable? = ApiError(0, "network", "Keine Verbindung")
            val send: suspend (Draft) -> Unit = { d -> sent += d; answer?.let { throw it } }

            assertEquals(DraftUploadRules.Outcome.Retry, DraftUploadRules.upload("f1", store, send))
            store.read("f1")!!.let { assertEquals(listOf("a"), ids(it)); assertEquals(1, it.attempts); assertEquals("Keine Verbindung", it.lastError); assertTrue(!it.conflict) }

            answer = ApiError(409, "conflict", "Notizen konnten nach 3 Versuchen nicht zusammengefuehrt werden")
            assertEquals(DraftUploadRules.Outcome.Failure(true, "Notizen konnten nach 3 Versuchen nicht zusammengefuehrt werden"), DraftUploadRules.upload("f1", store, send))
            store.read("f1")!!.let { assertEquals(2, it.attempts); assertTrue(it.conflict, "Konflikt bleibt sichtbar fuer das naechste Oeffnen"); assertEquals(10L, it.savedAt) }

            answer = ApiError(401, "unauthorized", "Sitzung abgelaufen")
            assertEquals(DraftUploadRules.Outcome.Failure(false, "Sitzung abgelaufen"), DraftUploadRules.upload("f1", store, send))
            assertNotNull(store.read("f1"), "Entwurf bleibt")

            answer = null
            assertEquals(DraftUploadRules.Outcome.Success, DraftUploadRules.upload("f1", store, send))
            assertNull(store.read("f1"), "erst nach 2xx geloescht")
            assertEquals(4, sent.size); assertEquals(0, sent[0].baseVersion)

            assertEquals(DraftUploadRules.Outcome.Success, DraftUploadRules.upload("f1", store, send))
            assertEquals(4, sent.size, "ohne Entwurf wird nichts gesendet")
        } finally { root.deleteRecursively() }
    }

    @Test
    fun aNewerDraftWrittenDuringTheSendSurvives() = runBlocking {
        val root = Files.createTempDirectory("uniflow-upload").toFile()
        try {
            val store = DraftStore(DraftStore.dir(root))
            store.write(Draft("f1", doc("a"), null, 0, 10L))
            val out = DraftUploadRules.upload("f1", store) { d ->
                store.write(d.copy(doc = doc("b"), savedAt = 11L))        // die Ansicht zeichnet weiter, waehrend der Worker sendet
            }
            assertEquals(DraftUploadRules.Outcome.Success, out)
            assertEquals(listOf("b"), ids(store.read("f1")!!), "der neuere Entwurf wird nicht geloescht")
            // und bei einem Fehlschlag nicht ueberschrieben
            val out2 = DraftUploadRules.upload("f1", store) { d -> store.write(d.copy(doc = doc("c"), savedAt = 12L)); throw ApiError(0, "network", "weg") }
            assertEquals(DraftUploadRules.Outcome.Retry, out2)
            store.read("f1")!!.let { assertEquals(listOf("c"), ids(it)); assertEquals(0, it.attempts) }
        } finally { root.deleteRecursively() }
    }
}
