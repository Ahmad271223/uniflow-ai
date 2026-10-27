package de.uniflow.android

import de.uniflow.core.UniCookie
import de.uniflow.core.UniversitySession
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Texte der Hochschul-Karte: nicht verbunden, abgelaufen, verbunden seit; Hinweis im Dokument nach dem Direkt-Download. */
class UniversityRulesTest {
    private val berlin = ZoneId.of("Europe/Berlin")
    private val session = UniversitySession("luh", listOf(UniCookie("Seminar_Session", "abc", "studip.uni-hannover.de")), savedAt = 1_793_192_580)  // 2026-10-28 13:03 UTC = 14:03 MEZ

    @Test
    fun statusTexts() {
        assertTrue(UniversityRules.statusText(null).startsWith("Nicht verbunden"))
        assertTrue(UniversityRules.statusText(session.copy(expired = true)).startsWith("Sitzung abgelaufen"))
        assertEquals("Verbunden seit 28.10.2026, 14:03 – Dateien werden direkt auf dieses Gerät geladen.", UniversityRules.statusText(session, berlin))
        assertEquals("28.10.2026, 14:03", Dates.dateTime(1_793_192_580, berlin))
        assertEquals("Anmelden", UniversityRules.loginLabel(null)); assertEquals("Anmelden", UniversityRules.loginLabel(session))
        assertEquals("Neu anmelden", UniversityRules.loginLabel(session.copy(expired = true)))
    }

    @Test
    fun sourceHints() {
        assertNull(UniversityRules.sourceHint(null))
        assertEquals("Direkt von Stud.IP geladen", UniversityRules.sourceHint("studip"))
        assertEquals("Direkt aus dem Learnweb geladen", UniversityRules.sourceHint("learnweb"))
        assertEquals("Direkt von der Hochschule geladen", UniversityRules.sourceHint("ilias"))
    }
}
