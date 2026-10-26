package de.uniflow.android

import de.uniflow.core.AnnotationDocument
import de.uniflow.core.AnnotationMerge
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Stiftgeometrie und Pruefung gespeicherter Werte (Massstab, Farben, Breite, Deckkraft, Seitenmass, fremde Objekte). */
class InkTest {

    @Test
    fun scaleMustBeFiniteAndPositive() {
        assertEquals(listOf(5f, 10f), InkMath.toPoints(listOf(10f to 20f), 2f))
        assertFailsWith<IllegalArgumentException> { InkMath.toPoints(listOf(1f to 2f), 0f) }
        assertFailsWith<IllegalArgumentException> { InkMath.toPoints(listOf(1f to 2f), -1f) }
        assertFailsWith<IllegalArgumentException> { InkMath.toPoints(listOf(1f to 2f), Float.NaN) }
        assertFailsWith<IllegalArgumentException> { InkMath.toPoints(listOf(1f to 2f), Float.POSITIVE_INFINITY) }
        assertEquals(emptyList(), InkMath.toPoints(emptyList(), 1f))
    }

    @Test
    fun onlySharedColorFormatsAreAccepted() {
        assertEquals(0xFF1F2937L, InkMath.parseColor("#1f2937"))
        assertEquals(0xFFE5322DL, InkMath.parseColor("#E5322D"), "Grossbuchstaben")
        assertEquals(0xFF4F5BD5L, InkMath.parseColor(" #4f5bd5 "), "Leerzeichen am Rand")
        assertEquals(0x80FFD400L, InkMath.parseColor("#ffd40080"), "CSS #RRGGBBAA wird zu ARGB")
        // alles andere: Standardfarbe statt unsichtbarer oder falscher Farbe
        for (bad in listOf(null, "", "#", "#fff", "#12345", "#1234567", "1f2937", "#gg0000", "red", "#1f2937ff00", "rgb(1,2,3)")) {
            assertEquals(InkMath.DEFAULT_COLOR, InkMath.parseColor(bad), "'$bad'")
        }
    }

    @Test
    fun singleTapBecomesAShortStrokeLikeTheWebEditor() {
        assertEquals(listOf(10f, 20f, 10.05f, 20.05f), InkMath.asStroke(listOf(10f, 20f)))
        assertEquals(listOf(1f, 2f, 3f, 4f), InkMath.asStroke(listOf(1f, 2f, 3f, 4f)), "echte Striche bleiben")
        assertEquals(emptyList(), InkMath.asStroke(emptyList()))
        // Tipp ohne Bewegung: Ausduennung laesst einen Punkt uebrig, der Strich hat danach zwei
        val tap = InkMath.thin(listOf(100f to 100f, 100f to 100f, 100f to 100f))
        assertEquals(1, tap.size)
        val points = InkMath.asStroke(InkMath.toPoints(tap, 2f))
        assertEquals(4, points.size)
        val stroke = AnnotationDocument.stroke(points)
        assertEquals(4, AnnotationDocument.strokePoints(stroke).size)
    }

    @Test
    fun thinningKeepsEndpointsAndDropsJitter() {
        assertEquals(listOf(1f to 1f), InkMath.thin(listOf(1f to 1f)))
        assertEquals(listOf(1f to 1f, 1.1f to 1.1f), InkMath.thin(listOf(1f to 1f, 1.1f to 1.1f)), "zwei Punkte bleiben unveraendert")
        assertEquals(listOf(0f to 0f, 2f to 0f, 3f to 0f), InkMath.thin(listOf(0f to 0f, 1f to 0f, 2f to 0f, 3f to 0f)))
        assertEquals(listOf(0f to 0f, 10f to 10f, 10.2f to 10.2f), InkMath.thin(listOf(0f to 0f, 0.5f to 0.5f, 1f to 1f, 10f to 10f, 10.2f to 10.2f)))
        assertEquals(listOf(5f to 5f), InkMath.thin(listOf(5f to 5f, 5f to 5f, 5f to 5f)), "ohne Bewegung bleibt ein Punkt")
        val thin = InkMath.thin(List(50) { it * 0.5f to 0f })
        assertEquals(0f to 0f, thin.first()); assertEquals(24.5f to 0f, thin.last()); assertTrue(thin.size < 50)
    }

    @Test
    fun widthAndOpacityAreClamped() {
        assertEquals(2f, InkMath.strokeWidth(null)); assertEquals(2f, InkMath.strokeWidth(Float.NaN))
        assertEquals(3.5f, InkMath.strokeWidth(3.5f))
        assertEquals(InkMath.MIN_WIDTH, InkMath.strokeWidth(0f)); assertEquals(InkMath.MIN_WIDTH, InkMath.strokeWidth(-5f))
        assertEquals(InkMath.MAX_WIDTH, InkMath.strokeWidth(1000f))
        assertEquals(2f, InkMath.strokeWidth(Float.POSITIVE_INFINITY), "unendlich ist kein Mass: Standardbreite wie bei NaN")
        assertEquals(1f, InkMath.opacity(null)); assertEquals(1f, InkMath.opacity(Float.NaN))
        assertEquals(0.35f, InkMath.opacity(0.35f)); assertEquals(1f, InkMath.opacity(2f)); assertEquals(0f, InkMath.opacity(-1f))
        val obj = Json.parseToJsonElement("""{"type":"stroke","width":"abc","opacity":7,"points":[1,2,3,4]}""") as JsonObject
        assertNull(InkMath.num(obj, "width")); assertEquals(7f, InkMath.num(obj, "opacity")); assertNull(InkMath.num(obj, "fehlt"))
        assertEquals(1f, InkMath.opacity(InkMath.num(obj, "opacity")))
    }

    @Test
    fun pageRatioFallsBackToA4() {
        assertEquals(595f / 842f, InkMath.pageRatio(595f, 842f))
        assertEquals(2f, InkMath.pageRatio(200f, 100f))
        val a4 = InkMath.A4.first / InkMath.A4.second
        assertEquals(a4, InkMath.pageRatio(595f, 0f)); assertEquals(a4, InkMath.pageRatio(0f, 842f))
        assertEquals(a4, InkMath.pageRatio(Float.NaN, 842f)); assertEquals(a4, InkMath.pageRatio(-1f, 5f)); assertEquals(a4, InkMath.pageRatio(1f, Float.POSITIVE_INFINITY))
        assertTrue(InkMath.validPageSize(1f, 1f)); assertFalse(InkMath.validPageSize(0f, 1f))
    }

    @Test
    fun foreignObjectsAreCountedAndNeverTouched() {
        val text = Json.parseToJsonElement("""{"id":"t1","type":"text","text":"Hallo","x":100,"y":100,"width":200,"fill":"#4f5bd5"}""") as JsonObject
        val shape = Json.parseToJsonElement("""{"id":"s1","type":"shape","shape":"rect","x":100,"y":100,"width":120,"height":40,"stroke":"#e5322d"}""") as JsonObject
        var doc = AnnotationDocument.empty()
        doc = AnnotationDocument.addObject(doc, "p1", text)
        doc = AnnotationDocument.addObject(doc, "p1", shape)
        doc = AnnotationDocument.addObject(doc, "p1", AnnotationDocument.stroke(listOf(100f, 100f, 120f, 100f), id = "k1"))
        val objects = AnnotationDocument.objects(doc, "p1")
        assertEquals(2, InkMath.foreignCount(objects))
        assertEquals("2 weitere Objekte (Text/Formen/Bilder) nur auf PC/iPad sichtbar", InkMath.foreignHint(2))
        assertEquals("1 weiteres Objekt (Text/Form/Bild) nur auf PC/iPad sichtbar", InkMath.foreignHint(1))
        assertNull(InkMath.foreignHint(0))
        // Radierer trifft nur Striche, auch wenn Text und Form an derselben Stelle liegen
        assertEquals(listOf("k1"), InkMath.strokesNear(objects, 101f, 101f, 6f))
        val erased = AnnotationDocument.removeObject(doc, "p1", "k1")
        assertEquals(listOf("t1", "s1"), AnnotationDocument.objects(erased, "p1").map { AnnotationMerge.objectId(it) })
        assertEquals(text, AnnotationDocument.objects(erased, "p1")[0]); assertEquals(shape, AnnotationDocument.objects(erased, "p1")[1])
        assertEquals("stroke", (AnnotationDocument.stroke(listOf(1f, 2f, 3f, 4f))["type"] as JsonPrimitive).content)
    }
}
