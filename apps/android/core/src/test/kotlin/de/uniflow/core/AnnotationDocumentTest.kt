package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/** Gemeinsames Notizformat: verlustfrei, Seitenreihenfolge, Strich-Form wie im Web-Editor, Zusammenfuehrung. */
class AnnotationDocumentTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")
    private val webDoc = Json.parseToJsonElement(File(fixtures, "documents/web-editor.json").readText()) as JsonObject

    @Test
    fun webEditorDocumentSurvivesUnchanged() {
        val again = Json.parseToJsonElement(webDoc.toString()) as JsonObject
        assertEquals(AnnotationMerge.canonical(webDoc), AnnotationMerge.canonical(again))
        // eine Seite anfassen: alle anderen Felder (auch unbekannte wie zukunftsFeld) bleiben
        val key = AnnotationDocument.keyForPdfPage(webDoc, 2)
        val changed = AnnotationDocument.addObject(webDoc, key, AnnotationDocument.stroke(listOf(1f, 2f, 3f, 4f), id = "neu1"))
        assertEquals(webDoc["zukunftsFeld"], changed["zukunftsFeld"])
        assertEquals(webDoc["pageOrder"], changed["pageOrder"])
        assertEquals(AnnotationDocument.objects(webDoc, key).size + 1, AnnotationDocument.objects(changed, key).size)
        assertEquals(AnnotationDocument.objects(webDoc, "p1"), AnnotationDocument.objects(changed, "p1"))
    }

    @Test
    fun pageOrderAndKeys() {
        assertEquals("p1", AnnotationDocument.keyForPdfPage(webDoc, 1))
        assertEquals("p2", AnnotationDocument.keyForPdfPage(webDoc, 2))
        assertEquals("p7", AnnotationDocument.keyForPdfPage(webDoc, 7), "unbekannte Seite: Konvention p<n>")
        val ordered = AnnotationDocument.orderedPages(webDoc, 3)
        assertEquals(listOf("p1" to 1, "b7x2k9" to null, "p2" to 2, "p3" to 3), ordered)
        assertEquals(listOf("p1" to 1, "p2" to 2), AnnotationDocument.orderedPages(AnnotationDocument.empty(), 2))
    }

    @Test
    fun strokeHasTheWebEditorShape() {
        val ref = (AnnotationDocument.objects(webDoc, "p1")[0] as JsonObject)
        val mine = AnnotationDocument.stroke(listOf(10f, 20f, 30.456f, 40f), widths = listOf(2.1f, 2.2f))
        assertEquals(ref.keys, mine.keys, "gleiche Felder wie ein Strich des Web-Editors")
        assertEquals("stroke", mine["type"]!!.jsonPrimitive.content)
        assertEquals(listOf(10f, 20f, 30.46f, 40f), AnnotationDocument.strokePoints(mine))
        assertTrue(mine["id"]!!.jsonPrimitive.content.matches(Regex("a[0-9a-f]{12}")))
        val removed = AnnotationDocument.removeObject(AnnotationDocument.addObject(webDoc, "p1", mine), "p1", mine["id"]!!.jsonPrimitive.content)
        assertEquals(AnnotationDocument.objects(webDoc, "p1"), AnnotationDocument.objects(removed, "p1"))
    }

    @Test
    fun mergeKeepsBothDevicesStrokesAndServerFields() {
        val base = webDoc
        val local = AnnotationDocument.addObject(base, "p1", AnnotationDocument.stroke(listOf(1f, 1f, 2f, 2f), id = "android1"))
        val server = AnnotationDocument.addObject(base, "p2", AnnotationDocument.stroke(listOf(5f, 5f, 6f, 6f), id = "ipad1"))
            .let { JsonObject(it.toMutableMap().apply { this["note"] = JsonPrimitive("vom iPad") }) }
        val (merged, conflicts) = AnnotationDocument.merge(base, local, server)
        assertEquals(0, conflicts)
        val ids1 = AnnotationDocument.objects(merged, "p1").map { AnnotationMerge.objectId(it) }
        val ids2 = AnnotationDocument.objects(merged, "p2").map { AnnotationMerge.objectId(it) }
        assertTrue("android1" in ids1 && "ipad1" in ids2)
        assertEquals("vom iPad", merged["note"]!!.jsonPrimitive.content, "Dokumentfelder vom Server")
        assertEquals(webDoc["zukunftsFeld"], merged["zukunftsFeld"])
        // dieselbe Seite auf beiden Seiten geaendert (gleiches Objekt verschieden): lokal gewinnt, ein Konflikt
        val o = (AnnotationDocument.objects(base, "p1")[0] as JsonObject)
        val localEdit = AnnotationDocument.withObjects(base, "p1", listOf(JsonObject(o.toMutableMap().apply { this["color"] = JsonPrimitive("#000000") })) + AnnotationDocument.objects(base, "p1").drop(1))
        val serverEdit = AnnotationDocument.withObjects(base, "p1", listOf(JsonObject(o.toMutableMap().apply { this["color"] = JsonPrimitive("#ff0000") })) + AnnotationDocument.objects(base, "p1").drop(1))
        val (m2, c2) = AnnotationDocument.merge(base, localEdit, serverEdit)
        assertEquals(1, c2)
        assertEquals("#000000", (AnnotationDocument.objects(m2, "p1")[0] as JsonObject)["color"]!!.jsonPrimitive.content)
        assertTrue((m2["pages"] as JsonObject).keys.containsAll(listOf("p1", "b7x2k9", "p2")))
        assertTrue(AnnotationDocument.pages(m2)["b7x2k9"] is JsonObject && (AnnotationDocument.pages(m2)["b7x2k9"] as JsonObject)["objects"] is JsonArray)
    }

    @Test
    fun rootFieldsMergeLikePageFields() {
        val base = webDoc
        // nur hier geaendert: Notiz, Lesezeichen, Seite in den Papierkorb (aus pageOrder nach deletedPages) -> bleibt alles
        val trash = Json.parseToJsonElement("""[{"entry":{"key":"b7x2k9","type":"blank","template":"lined","w":595,"h":842},"objects":[],"at":1,"pos":1}]""")
        val local = JsonObject(base.toMutableMap().apply {
            this["note"] = JsonPrimitive("meine Notiz")
            this["bookmarks"] = JsonArray(emptyList())
            this["pageOrder"] = JsonArray(AnnotationDocument.pageOrder(base).filter { it.s("key") != "b7x2k9" })
            this["deletedPages"] = trash
        })
        // nur dort geaendert: Zoom und Gliederung -> vom Server
        val outline = Json.parseToJsonElement("""[{"key":"p1","title":"Kapitel 1"}]""")
        val server = JsonObject(base.toMutableMap().apply { this["zoom"] = JsonPrimitive(1.5); this["outline"] = outline })
        val (m, c) = AnnotationDocument.merge(base, local, server)
        assertEquals(0, c)
        assertEquals("meine Notiz", m["note"]!!.jsonPrimitive.content)
        assertEquals(JsonArray(emptyList()), m["bookmarks"])
        assertEquals(local["pageOrder"], m["pageOrder"])
        assertEquals(trash, m["deletedPages"], "Papierkorb wandert mit der Seitenreihenfolge")
        assertEquals(JsonPrimitive(1.5), m["zoom"]); assertEquals(outline, m["outline"])
        assertEquals(webDoc["zukunftsFeld"], m["zukunftsFeld"]); assertEquals(webDoc["version"], m["version"])
        assertEquals(listOf("p1", "p2"), AnnotationDocument.orderedPages(m, 2).map { it.first })
        // beidseitig verschieden: dieses Geraet gewinnt, ein Konflikt
        val server2 = JsonObject(base.toMutableMap().apply { this["note"] = JsonPrimitive("vom iPad") })
        val (m2, c2) = AnnotationDocument.merge(base, local, server2)
        assertEquals(1, c2); assertEquals("meine Notiz", m2["note"]!!.jsonPrimitive.content)
        // Feld hier entfernt, dort unveraendert -> bleibt entfernt; dort entfernt, hier unveraendert -> ebenso
        val ohneNotiz = JsonObject(base.toMutableMap().apply { remove("note") })
        assertEquals(null, AnnotationDocument.merge(base, ohneNotiz, base).first["note"])
        assertEquals(null, AnnotationDocument.merge(base, base, ohneNotiz).first["note"])
        // ohne Basis (erstes Speichern): gleiche Felder ohne Konflikt, eigene Seitenreihenfolge gilt
        val (m3, c3) = AnnotationDocument.merge(null, local, base)
        assertEquals(local["pageOrder"], m3["pageOrder"]); assertTrue(c3 >= 1)
    }
}
