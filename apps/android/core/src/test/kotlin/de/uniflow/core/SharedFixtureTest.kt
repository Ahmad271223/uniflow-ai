package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
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
}
