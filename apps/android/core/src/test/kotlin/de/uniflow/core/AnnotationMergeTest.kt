package de.uniflow.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Regeln aus merge.js, die die gemeinsamen Faelle (fixtures/merge/cases.json) nicht abdecken: Zahlenform der
 * Signaturen, doppelte IDs, Zeichnung v2 auf beiden Seiten, Seite geloescht und zugleich geaendert.
 * Die Erwartungen sind das Verhalten von merge.js (und AnnotationMerge.swift), nicht eine eigene Regel.
 */
class AnnotationMergeTest {
    private fun j(s: String) = Json.parseToJsonElement(s)
    private fun page(vararg objects: String) = j("""{"objects":[${objects.joinToString(",")}]}""")

    @Test
    fun canonicalNumbersMatchJsonStringify() {
        // Erwartung = JSON.stringify(JSON.parse(x)) in JavaScript (stableStringify in merge.js)
        val cases = listOf(
            "1e21" to "1e+21", "1000000000000000000000" to "1e+21", "1e20" to "100000000000000000000",
            "1e15" to "1000000000000000", "9007199254740993" to "9007199254740992", "9007199254740992" to "9007199254740992",
            "12345678901234567890" to "12345678901234567000", "0.30000000000000004" to "0.30000000000000004", "0.1" to "0.1",
            "2.0" to "2", "100" to "100", "1E+2" to "100", "0.5e1" to "5", "-0" to "0", "-0.0" to "0", "-7.25" to "-7.25",
            "123.456" to "123.456", "0.000001" to "0.000001", "1e-7" to "1e-7", "1.5e-10" to "1.5e-10", "-1.5e300" to "-1.5e+300",
        )
        for ((input, js) in cases) assertEquals(js, AnnotationMerge.canonical(j(input)), input)
        // Praezisionsverlust wie in JavaScript: beide Zahlen sind dasselbe Double, also dasselbe Objekt
        assertEquals(AnnotationMerge.canonical(j("""{"x":9007199254740993}""")), AnnotationMerge.canonical(j("""{"x":9007199254740992}""")))
        assertEquals("~" + """{"x":1e+21}""", AnnotationMerge.objectId(j("""{"x":1000000000000000000000}""")))
        assertNotEquals(AnnotationMerge.canonical(j("0.30000000000000004")), AnnotationMerge.canonical(j("0.3")))
        assertEquals("[1,0,2.5,null]", AnnotationMerge.canonical(j("[1.0,-0,2.50,null]")))
    }

    @Test
    fun duplicateIdsBehaveLikeMergeJs() {
        // merge.js: der Index (Map.set) behaelt je ID den letzten Eintrag, ausgegeben wird je ID nur der erste (emitted)
        val r1 = AnnotationMerge.mergeObjects(emptyList(), listOf(j("""{"id":"a","v":1}"""), j("""{"id":"a","v":2}""")), emptyList())
        assertEquals(listOf("""{"id":"a","v":1}"""), r1.first.map { AnnotationMerge.canonical(it) }, "neu auf diesem Geraet: erster Eintrag")
        assertEquals(0, r1.second)
        val base = listOf(j("""{"id":"a","v":1}"""))
        val r2 = AnnotationMerge.mergeObjects(base, listOf(j("""{"id":"a","v":1}"""), j("""{"id":"a","v":2}""")), base)
        assertEquals(listOf("""{"id":"a","v":2}"""), r2.first.map { AnnotationMerge.canonical(it) }, "Vergleich gegen den letzten lokalen Eintrag")
        assertEquals(0, r2.second)
        val r3 = AnnotationMerge.mergeObjects(base, base, listOf(j("""{"id":"a","v":3}"""), j("""{"id":"a","v":4}""")))
        assertEquals(listOf("""{"id":"a","v":3}"""), r3.first.map { AnnotationMerge.canonical(it) }, "vom Server: erster Eintrag")
    }

    @Test
    fun drawingV2OnBothSidesTakesLocalWithoutComparingSignatures() {
        // merge.js mergePage Zeilen 62-66: passt keine Zeichnung genau zu den Objekten, gewinnt die lokale v2-Zeichnung
        val local = j("""{"objects":[{"id":"a"},{"id":"b"}],"pkdrawing":{"data":"L","format":"pkdrawing-v2","strokeIds":[["a"],["b"]],"strokeSigs":["sa","sb"]}}""")
        val server = j("""{"objects":[{"id":"a"},{"id":"c"}],"pkdrawing":{"data":"S","format":"pkdrawing-v2","strokeIds":[["a"],["c"]],"strokeSigs":["sa","sc"]}}""")
        val r = AnnotationMerge.mergePage(page("""{"id":"a"}"""), local, server)
        val p = r.page!!
        assertEquals(listOf("a", "c", "b"), (p["objects"] as JsonArray).map { (it as JsonObject)["id"]!!.jsonPrimitive.content })
        assertEquals("L", ((p["pkdrawing"] as JsonObject)["data"]).toString().trim('"'))
        assertEquals(0, r.conflicts)
        // v2 genuegt die Form (format + strokeSigs als Liste); ob die Signaturen zu den Strichen passen, prueft der Leser
        val odd = j("""{"objects":[],"pkdrawing":{"data":"X","format":"pkdrawing-v2","strokeIds":[],"strokeSigs":["ohne Strich"]}}""")
        val r2 = AnnotationMerge.mergePage(page("""{"id":"a"}"""), page("""{"id":"a"}""", """{"id":"n"}"""), odd)
        assertEquals("X", ((r2.page!!["pkdrawing"] as JsonObject)["data"]).toString().trim('"'))
    }

    @Test
    fun pageDeletedOnOneSideAndChangedOnTheOtherStays() {
        // merge.js mergePage Zeilen 47-48: Loeschen gegen Aenderung -> die geaenderte Seite bleibt, ein Konflikt
        val base = page("""{"id":"a"}""")
        val changed = page("""{"id":"a"}""", """{"id":"b"}""")
        val r = AnnotationMerge.mergePage(base, null, changed)
        assertEquals(AnnotationMerge.canonical(changed), AnnotationMerge.canonical(r.page)); assertEquals(1, r.conflicts)
        val r2 = AnnotationMerge.mergePage(base, changed, null)
        assertEquals(AnnotationMerge.canonical(changed), AnnotationMerge.canonical(r2.page)); assertEquals(1, r2.conflicts)
        // unveraendert gegen geloescht -> weg, kein Konflikt
        assertEquals(null, AnnotationMerge.mergePage(base, base, null).page)
        assertEquals(null, AnnotationMerge.mergePage(base, null, base).page)
    }
}
