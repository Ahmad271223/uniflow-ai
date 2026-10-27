package de.uniflow.android

import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationMerge
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Ablage der Entwuerfe: atomar (erst `.tmp`, dann umbenennen), wiederherstellbar, Reste und Beschaedigtes zaehlen nicht. */
class DraftStoreTest {
    private fun doc(id: String) = AnnotationDocument.addObject(AnnotationDocument.empty(), "p1", AnnotationDocument.stroke(listOf(1f, 2f, 3f, 4f), id = id))
    private fun ids(d: JsonObject) = AnnotationDocument.objects(d, "p1").map { AnnotationMerge.objectId(it) }

    private fun <T> withStore(block: (DraftStore) -> T): T {
        val root = Files.createTempDirectory("uniflow-drafts").toFile()
        try { return block(DraftStore(DraftStore.dir(root))) } finally { root.deleteRecursively() }
    }

    @Test
    fun writesAtomicallyAndReadsBack() = withStore { store ->
        val id = "f/1 ä"                                                     // Datei-ID darf alles enthalten, der Dateiname nicht
        val d = Draft(id, doc("a"), doc("b"), 3, 1234L)
        store.write(d)
        assertEquals(d, store.read(id))
        assertEquals("drafts", store.dir.name)
        assertTrue(store.fileFor(id).name.matches(Regex("[A-Za-z0-9._-]+\\.json")), store.fileFor(id).name)
        assertFalse(File(store.dir, store.fileFor(id).name + ".tmp").exists(), "keine .tmp-Datei bleibt liegen")

        store.write(d.copy(doc = doc("c"), savedAt = 2000L))
        assertEquals(listOf("c"), ids(store.read(id)!!.doc), "vorhandener Entwurf wird ersetzt")
        assertNull(store.read("andere"), "ohne Entwurf null")
    }

    @Test
    fun leftoversAndDamageDoNotCountAsDrafts() = withStore { store ->
        store.write(Draft("g", doc("x"), null, 0, 5L))
        store.write(Draft("h", doc("y"), null, 0, 6L))
        // abgebrochenes Schreiben: `.tmp` bleibt liegen -> der vorige Entwurf gilt weiter
        File(store.dir, store.fileFor("g").name + ".tmp").writeText("""{"fileId":"g","doc":{""")
        assertEquals(listOf("x"), ids(store.read("g")!!.doc))
        // beschaedigte Datei, Datei einer anderen ID, Fremddatei
        store.fileFor("h").writeText("kaputt")
        store.fileFor("k").writeText(Draft("anders", doc("z"), null, 0, 7L).toJson().toString())
        File(store.dir, "notiz.txt").writeText("x")
        assertNull(store.read("h")); assertNull(store.read("k"))
        assertEquals(listOf("g"), store.pending().map { it.fileId }, "pending: nur lesbare .json unter dem Namen ihrer ID")
        store.delete("g")
        assertNull(store.read("g")); assertFalse(File(store.dir, store.fileFor("g").name + ".tmp").exists(), "delete raeumt auch .tmp weg")
    }

    @Test
    fun deleteAndReplaceOnlyWhenUnchanged() = withStore { store ->
        val read = Draft("f", doc("a"), null, 0, 100L)
        store.write(read)
        store.write(read.copy(doc = doc("b"), savedAt = 200L))                // Ansicht schreibt inzwischen einen neueren Entwurf
        assertFalse(store.deleteIfUnchanged(read)); assertEquals(listOf("b"), ids(store.read("f")!!.doc), "der neuere bleibt")
        assertFalse(store.replaceIfUnchanged(read, read.copy(attempts = 1))); assertEquals(0, store.read("f")!!.attempts)
        val newest = store.read("f")!!
        assertTrue(store.replaceIfUnchanged(newest, newest.copy(attempts = 1, conflict = true, lastError = "409")))
        store.read("f")!!.let { assertEquals(1, it.attempts); assertTrue(it.conflict); assertEquals("409", it.lastError); assertEquals(200L, it.savedAt) }
        assertTrue(store.deleteIfUnchanged(store.read("f")!!)); assertNull(store.read("f"))
        assertTrue(store.deleteIfUnchanged(newest), "nichts mehr da: gilt als erledigt")
        assertTrue(store.replaceIfUnchanged(newest, newest), "ohne vorhandenen Entwurf wird geschrieben")
    }

    @Test
    fun jsonRoundTripKeepsEverything() {
        val raw = Json.parseToJsonElement("""{"version":2,"pages":{"p1":{"objects":[{"id":"a","type":"stroke","points":[1,2,3,4]}]}},"zukunftsFeld":{"x":1}}""") as JsonObject
        val d = Draft("f1", raw, raw, 4, 99L, attempts = 2, conflict = true, lastError = "Konflikt")
        val again = Draft.fromJson(Json.parseToJsonElement(d.toJson().toString()))
        assertEquals(d, again)
        assertEquals(JsonPrimitive(Draft.FORMAT), d.toJson()["format"])
        assertNotNull(again); assertEquals(raw["zukunftsFeld"], again.doc["zukunftsFeld"], "unbekannte Felder bleiben")
        assertEquals(Draft("f1", raw, null, 0, 1L), Draft.fromJson(Json.parseToJsonElement("""{"fileId":"f1","doc":${raw},"savedAt":1}""")))
        assertNull(Draft.fromJson(null)); assertNull(Draft.fromJson(Json.parseToJsonElement("""{"fileId":"f1","doc":{}}""")), "ohne savedAt kein Entwurf")
        assertNull(Draft.fromJson(Json.parseToJsonElement("""{"fileId":"f1","savedAt":1}""")), "ohne Dokument kein Entwurf")
    }

    @Test
    fun safeNames() {
        assertEquals("abc-1_2.3", DraftStore.safeName("abc-1_2.3"))
        assertEquals("a_b_c_", DraftStore.safeName("a/b\\c:"))
        assertEquals("_", DraftStore.safeName(""))
    }
}
