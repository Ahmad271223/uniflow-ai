package de.uniflow.android

import java.time.LocalDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** Reine Regeln der App (ohne Android-Laufzeit): Adressen, Datum, Stiftgeometrie. */
class RulesTest {

    @Test
    fun urlsForPcAndService() {
        assertEquals("http://192.168.1.5:8765", SessionRules.normalizeUrl(" 192.168.1.5:8765/ "))
        assertEquals("https://dienst.example.de", SessionRules.normalizeUrl("dienst.example.de"))
        assertEquals("http://laptop.local:8765", SessionRules.normalizeUrl("laptop.local:8765"))
        assertEquals("https://x.de", SessionRules.normalizeUrl("https://x.de/"))
        assertEquals("", SessionRules.normalizeUrl("   "))
        assertTrue(SessionRules.isHttpAllowed("http://10.0.0.7:8765") && SessionRules.isHttpAllowed("https://dienst.example.de"))
        assertFalse(SessionRules.isHttpAllowed("http://dienst.example.de"))
        assertTrue(SessionRules.isPrivateHost("172.20.1.1") && !SessionRules.isPrivateHost("172.40.1.1") && !SessionRules.isPrivateHost("8.8.8.8"))
    }

    @Test
    fun dates() {
        assertEquals(LocalDate.of(2026, 10, 26), Dates.mondayOf(LocalDate.of(2026, 10, 29)))
        assertEquals(LocalDate.of(2026, 10, 26), Dates.mondayOf(LocalDate.of(2026, 10, 26)))
        assertEquals(LocalDate.of(2026, 10, 26), Dates.mondayOf(LocalDate.of(2026, 11, 1)))
        assertEquals("Mo., 02.11.", Dates.short("2026-11-02T23:59"))
        assertEquals("26.10. – 1.11.2026", Dates.weekLabel(LocalDate.of(2026, 10, 26)))
        assertEquals("1 h 30 min", Dates.minutes(90)); assertEquals("45 min", Dates.minutes(45)); assertEquals("2 h", Dates.minutes(120))
    }

    @Test
    fun inkGeometryMatchesTheSharedFormat() {
        assertEquals(listOf(10f, 20f, 30f, 40f), InkMath.toPoints(listOf(20f to 40f, 60f to 80f), 2f))
        val thin = InkMath.thin(listOf(0f to 0f, 0.5f to 0.5f, 1f to 1f, 10f to 10f, 10.2f to 10.2f))
        assertEquals(listOf(0f to 0f, 10f to 10f, 10.2f to 10.2f), thin)
        val strokes = listOf(de.uniflow.core.AnnotationDocument.stroke(listOf(100f, 100f, 120f, 100f), id = "s1"),
            de.uniflow.core.AnnotationDocument.stroke(listOf(300f, 300f, 320f, 300f), id = "s2"))
        assertEquals(listOf("s1"), InkMath.strokesNear(strokes, 118f, 103f, 6f))
        assertEquals(emptyList(), InkMath.strokesNear(strokes, 200f, 200f, 6f))
        assertEquals(0xFF1F2937L, InkMath.parseColor("#1f2937")); assertEquals(0xFF1F2937L, InkMath.parseColor(null))
        val s = Json.parseToJsonElement(strokes[0].toString()) as JsonObject
        assertEquals("pen", (s["tool"] as kotlinx.serialization.json.JsonPrimitive).content)
    }
}
