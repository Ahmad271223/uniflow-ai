package de.uniflow.android

import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationMerge
import de.uniflow.core.AnnotationStore
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Entwurf + Serverstand beim Oeffnen: dieselben Regeln wie beim 409 (fixtures/merge/cases.json, verbindlich fuer alle
 * Plattformen) – Entwurf gewinnt bei Feldern, Seitenreihenfolge-Konflikt wird sichtbar, der Entwurf bleibt ungesendet.
 */
class DraftRestoreTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")
    private val root = Json.parseToJsonElement(File(fixtures, "merge/cases.json").readText()) as JsonObject

    private fun session() = AnnotationSession("f1", { _, _, _ -> throw IllegalStateException("beim Oeffnen wird nicht gesendet") })
    private fun strings(a: JsonElement?) = (a as JsonArray).map { (it as JsonPrimitive).content }
    private fun obj(e: JsonElement?): JsonObject? = e as? JsonObject

    @Test
    fun documentCasesMergeDraftWithServerState() {
        val cases = root["documentCases"] as JsonArray
        assertTrue(cases.size >= 15)
        for (c in cases) {
            c as JsonObject
            val name = c["name"]!!.jsonPrimitive.content
            val s = session()
            val draft = Draft("f1", c["local"] as JsonObject, obj(c["base"]), 1, 1L)
            s.loaded(AnnotationStore.Loaded(c["server"] as JsonObject, 2, null), draft)        // Server ist weiter als der Entwurf
            assertEquals(strings(c["expectOrder"]), (s.doc["pageOrder"] as JsonArray).map { AnnotationDocument.keyOf(it) }, name)
            assertEquals(strings(c["expectTrash"]), (s.doc["deletedPages"] as JsonArray).map { AnnotationDocument.keyOf(it) }, name)
            val expectConflicts = c["expectConflicts"]!!.jsonPrimitive.int
            val expectOrderConflict = c["expectOrderConflict"]!!.jsonPrimitive.content == "true"
            assertEquals(expectConflicts, s.restored!!.conflicts, name)
            assertEquals(expectOrderConflict, s.restored!!.orderConflict, name)
            assertTrue(s.dirty, "$name: Entwurf bleibt ungesendet")
            assertEquals(c["server"], s.base, "$name: Basis ist der Serverstand"); assertEquals(2, s.baseVersion)
            (c["expectPageIds"] as? JsonObject)?.forEach { (k, ids) ->
                assertEquals(strings(ids), AnnotationDocument.objects(s.doc, k).map { AnnotationMerge.objectId(it) }, name)
            }
            when {
                expectOrderConflict -> { assertTrue(s.status.contains("Seitenreihenfolge auf beiden Geräten geändert"), name); assertEquals(AnnotationSession.DraftState.Conflict, s.draftState, name) }
                expectConflicts > 0 -> { assertTrue(s.status.contains("Konflikt"), name); assertEquals(AnnotationSession.DraftState.Conflict, s.draftState, name) }
                else -> { assertEquals("Entwurf wiederhergestellt (noch nicht gesendet)", s.status, name); assertEquals(AnnotationSession.DraftState.Saved, s.draftState, name) }
            }
        }
    }

    @Test
    fun pageCasesMergeDraftWithServerState() {
        fun doc(page: JsonElement?): JsonObject? {
            if (page == null || page is JsonNull) return null
            return buildJsonObject { put("version", 2); put("pages", buildJsonObject { put("p1", page) }) }
        }
        val cases = root["cases"] as JsonArray
        assertTrue(cases.size > 5)
        for (c in cases) {
            c as JsonObject
            val name = c["name"]!!.jsonPrimitive.content
            val s = session()
            val local = doc(c["local"]) ?: buildJsonObject { put("version", 2); put("pages", JsonObject(emptyMap())) }
            val server = doc(c["server"]) ?: buildJsonObject { put("version", 2); put("pages", JsonObject(emptyMap())) }
            s.loaded(AnnotationStore.Loaded(server, 2, null), Draft("f1", local, doc(c["base"]), 1, 1L))
            val expectIds = c["expectIds"]
            if (expectIds == null || expectIds is JsonNull) assertFalse("p1" in AnnotationDocument.pages(s.doc), name)
            else assertEquals((expectIds as JsonArray).map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content },
                AnnotationDocument.objects(s.doc, "p1").map { ((it as JsonObject)["id"] as? JsonPrimitive)?.content }, name)
            assertEquals(c["expectConflicts"]!!.jsonPrimitive.int, s.restored!!.conflicts, name)
            assertTrue(s.dirty, name)
        }
    }

    @Test
    fun unchangedServerKeepsTheDraftAsItIs() {
        val base = AnnotationDocument.addObject(AnnotationDocument.empty(), "p1", AnnotationDocument.stroke(listOf(1f, 1f, 2f, 2f), id = "alt"))
        val local = AnnotationDocument.addObject(base, "p1", AnnotationDocument.stroke(listOf(3f, 3f, 4f, 4f), id = "neu"))
        val s = session()
        s.loaded(AnnotationStore.Loaded(base, 3, null), Draft("f1", local, base, 3, 1L))
        assertSame(local, s.doc, "Server unveraendert: der Entwurf gilt unveraendert"); assertSame(base, s.base); assertEquals(3, s.baseVersion)
        assertTrue(s.dirty); assertEquals(AnnotationSession.DraftState.Saved, s.draftState)
        assertEquals("Entwurf wiederhergestellt (noch nicht gesendet)", s.status)
        assertEquals(AnnotationSession.Restored(0, false, false), s.restored)
        // erstes Speichern (Server ohne Notizen, Entwurf ohne Basis)
        val s2 = session()
        s2.loaded(AnnotationStore.Loaded(AnnotationDocument.empty(), 0, null), Draft("f1", local, null, 0, 1L))
        assertSame(local, s2.doc); assertNull(s2.base); assertEquals(0, s2.baseVersion); assertTrue(s2.dirty)
        // ohne Entwurf wie bisher
        val s3 = session()
        s3.loaded(AnnotationStore.Loaded(base, 3, null))
        assertFalse(s3.dirty); assertNull(s3.restored); assertEquals(AnnotationSession.DraftState.None, s3.draftState)
    }

    @Test
    fun draftLeftByAFailedBackgroundUploadShowsAConflict() {
        val base = AnnotationDocument.addObject(AnnotationDocument.empty(), "p1", AnnotationDocument.stroke(listOf(1f, 1f, 2f, 2f), id = "alt"))
        val local = AnnotationDocument.addObject(base, "p1", AnnotationDocument.stroke(listOf(3f, 3f, 4f, 4f), id = "neu"))
        val server = AnnotationDocument.addObject(base, "p1", AnnotationDocument.stroke(listOf(5f, 5f, 6f, 6f), id = "fremd"))
        val s = session()
        s.loaded(AnnotationStore.Loaded(server, 7, null), Draft("f1", local, base, 3, 1L, attempts = 3, conflict = true, lastError = "Konflikt"))
        assertTrue(s.status.startsWith("Konflikt"), s.status)
        assertEquals(AnnotationSession.DraftState.Conflict, s.draftState)
        assertTrue(s.restored!!.fromFailedUpload)
        assertEquals(listOf("alt", "fremd", "neu"), AnnotationDocument.objects(s.doc, "p1").map { AnnotationMerge.objectId(it) }, "beide Striche bleiben")
        assertTrue(s.dirty); assertEquals(7, s.baseVersion)
    }
}
