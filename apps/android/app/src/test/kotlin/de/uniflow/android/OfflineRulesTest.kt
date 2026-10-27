package de.uniflow.android

import de.uniflow.core.ApiError
import java.io.IOException
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Offline-Betrieb: wann die Ablage einspringt und wie der Stand-Hinweis lautet. */
class OfflineRulesTest {
    private val berlin = ZoneId.of("Europe/Berlin")

    @Test
    fun onlyOutagesFallBackToTheLocalStore() {
        assertTrue(OfflineRules.fallsBackToLocal(ApiError(0, "network", "Keine Verbindung")))
        assertTrue(OfflineRules.fallsBackToLocal(ApiError(503, null, "Wartung")))
        assertTrue(OfflineRules.fallsBackToLocal(ApiError(408, null, "Zeit")))
        assertTrue(OfflineRules.fallsBackToLocal(ApiError(429, null, "zu viele")))
        assertTrue(OfflineRules.fallsBackToLocal(IOException("Leitung weg")))
        assertFalse(OfflineRules.fallsBackToLocal(ApiError(401, null, "Anmeldung erforderlich.")), "abgelaufene Anmeldung ist kein Ausfall")
        assertFalse(OfflineRules.fallsBackToLocal(ApiError(404, "not_found", "weg")))
        assertFalse(OfflineRules.fallsBackToLocal(IllegalStateException("Programmfehler")))
    }

    @Test
    fun standTextNamesTimeAndReason() {
        assertNull(OfflineRules.standText(Stand(1, "2026-10-27T10:00:00.000Z", offline = false), berlin), "frischer Stand: kein Hinweis")
        assertEquals("Stand vom 27.10.2026, 11:00 – keine Verbindung", OfflineRules.standText(Stand(1, "2026-10-27T10:00:00.000Z", offline = true), berlin))
        assertEquals("Stand vom 27.10.2026, 11:00 – keine Verbindung", OfflineRules.standText(Stand(1, "2026-10-27T10:00:00.000Z", offline = true, note = "Keine Verbindung"), berlin))
        assertEquals("Stand vom 27.10.2026, 11:00 – Wartung (503)", OfflineRules.standText(Stand(1, "2026-10-27T10:00:00.000Z", offline = true, note = "Wartung (503)"), berlin))
        assertEquals("Gespeicherter Stand – keine Verbindung", OfflineRules.standText(Stand(1, null, offline = true), berlin))
        assertEquals("Gespeicherter Stand – keine Verbindung", OfflineRules.standText(Stand(1, "gestern", offline = true), berlin), "unlesbarer Zeitstempel")
        assertEquals(1793095200L, OfflineRules.epochSeconds("2026-10-27T10:00:00.000Z"))
    }

    @Test
    fun pendingText() {
        assertNull(OfflineRules.pendingText(0))
        assertEquals("1 Änderung wird gesendet, sobald der Dienst erreichbar ist", OfflineRules.pendingText(1))
        assertEquals("3 Änderungen werden gesendet, sobald der Dienst erreichbar ist", OfflineRules.pendingText(3))
    }
}
