package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive

/** Gemeinsame Zusammenfuehrungs-Faelle (gleiche Erwartungen wie Swift und Web). */
class SharedFixtureTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")

    @Test
    fun mergeCasesMatchOtherPlatforms() {
        val root = Json.parseToJsonElement(File(fixtures, "merge/cases.json").readText()) as JsonObject
        val cases = root["cases"] as JsonArray
        assertTrue(cases.size > 5)
        for (c in cases) {
            c as JsonObject
            val name = c["name"]!!.jsonPrimitive.content
            val r = AnnotationMerge.mergePage(c["base"], c["local"], c["server"])
            val expectIds = c["expectIds"]
            if (expectIds == null || expectIds is JsonNull) {
                assertNull(r.page, name)
            } else {
                val ids = (r.page!!["objects"] as JsonArray).map { o ->
                    ((o as JsonObject)["id"] as? JsonPrimitive)?.content
                }
                val expected = (expectIds as JsonArray).map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                assertEquals(expected, ids, name)
            }
            assertEquals(c["expectConflicts"]!!.jsonPrimitive.int, r.conflicts, name)
            (c["expectField"] as? JsonObject)?.let { f ->
                val o = (r.page!!["objects"] as JsonArray)[f["index"]!!.jsonPrimitive.int] as JsonObject
                assertEquals(AnnotationMerge.canonical(f["value"]), AnnotationMerge.canonical(o[f["key"]!!.jsonPrimitive.content]), name)
            }
            (c["expectPageField"] as? JsonObject)?.let { f ->
                assertEquals(AnnotationMerge.canonical(f["value"]), AnnotationMerge.canonical(r.page!![f["key"]!!.jsonPrimitive.content]), name)
            }
        }
    }

    @Test
    fun canonicalIgnoresKeyOrderAndNumberFormat() {
        val a = Json.parseToJsonElement("""{"b":1,"a":[2.0,{"d":3,"c":4}]}""")
        val b = Json.parseToJsonElement("""{"a":[2,{"c":4,"d":3}],"b":1.0}""")
        assertEquals(AnnotationMerge.canonical(a), AnnotationMerge.canonical(b))
    }

    @Test
    fun documentCasesMatchOtherPlatforms() {
        val root = Json.parseToJsonElement(File(fixtures, "merge/cases.json").readText()) as JsonObject
        val cases = root["documentCases"] as JsonArray
        assertTrue(cases.size >= 15)
        for (c in cases) {
            c as JsonObject
            val name = c["name"]!!.jsonPrimitive.content
            val r = AnnotationDocument.mergeDetailed(c["base"] as? JsonObject, c["local"] as JsonObject, c["server"] as JsonObject)
            val order = (r.doc["pageOrder"] as JsonArray).map { AnnotationDocument.keyOf(it) }
            val trash = (r.doc["deletedPages"] as JsonArray).map { AnnotationDocument.keyOf(it) }
            val strings = { a: JsonElement? -> (a as JsonArray).map { (it as JsonPrimitive).content } }
            assertEquals(strings(c["expectOrder"]), order, name)
            assertEquals(strings(c["expectTrash"]), trash, name)
            assertEquals(c["expectConflicts"]!!.jsonPrimitive.int, r.conflicts, name)
            assertEquals(c["expectOrderConflict"]!!.jsonPrimitive.content == "true", r.orderConflict, name)
            val pages = r.doc["pages"] as JsonObject
            for (k in order) assertTrue(k in pages, name + ": Seite " + k + " fehlt")
            (c["expectPageIds"] as? JsonObject)?.forEach { (k, ids) ->
                val got = ((pages[k] as JsonObject)["objects"] as JsonArray).map { ((it as JsonObject)["id"] as JsonPrimitive).content }
                assertEquals(strings(ids), got, name)
            }
            (c["expectEntry"] as? JsonObject)?.let { e ->
                val entry = (r.doc["pageOrder"] as JsonArray).first { AnnotationDocument.keyOf(it) == e["key"]!!.jsonPrimitive.content } as JsonObject
                assertEquals(AnnotationMerge.canonical(e["value"]), AnnotationMerge.canonical(entry[e["field"]!!.jsonPrimitive.content]), name)
            }
            c["expectNote"]?.let { assertEquals(AnnotationMerge.canonical(it), AnnotationMerge.canonical(r.doc["note"]), name) }
            c["expectBookmarks"]?.let { assertEquals(AnnotationMerge.canonical(it), AnnotationMerge.canonical(r.doc["bookmarks"]), name) }
        }
    }
}
