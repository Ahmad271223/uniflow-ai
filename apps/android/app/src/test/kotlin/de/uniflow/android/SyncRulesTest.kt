package de.uniflow.android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json

/** Abgleich wie pollBg im Web: /api/bg abfragen, bis der Job fertig ist. */
class SyncRulesTest {

    @Test
    fun pollsUntilTheJobIsDone() = runBlocking {
        val states = ArrayDeque(listOf(BgStatus(true, "Sync", null), BgStatus(true, "Sync", "Sync: läuft seit 12:00"), BgStatus(false, null, "Sync: fertig (3 neue Dateien)")))
        var waits = 0
        val seen = ArrayList<BgStatus>()
        val end = SyncRules.waitUntilIdle(fetch = { states.removeFirst() }, wait = { waits++ }, onUpdate = { seen += it })
        assertEquals("Sync: fertig (3 neue Dateien)", end?.message)
        assertEquals(2, waits, "gewartet wird nur, solange der Job laeuft")
        assertEquals(3, seen.size); assertTrue(states.isEmpty())
    }

    @Test
    fun givesUpAfterMaxPolls() = runBlocking {
        var fetches = 0
        var waits = 0
        val end = SyncRules.waitUntilIdle(fetch = { fetches++; BgStatus(true, "Sync", null) }, wait = { waits++ }, maxPolls = 3)
        assertNull(end, "nach maxPolls meldet der Aufrufer, dass der Abgleich noch laeuft")
        assertEquals(3, fetches); assertEquals(3, waits)
    }

    @Test
    fun bgStatusFromServerJson() {
        val running = BgStatus.from(Json.parseToJsonElement("""{"running":true,"task":"Sync","message":""}"""))
        assertTrue(running.running); assertEquals("Sync", running.task); assertNull(running.message, "leere Meldung wird null")
        val done = BgStatus.from(Json.parseToJsonElement("""{"running":false,"task":null,"message":"Sync: fertig","job":{"id":1}}"""))
        assertFalse(done.running); assertNull(done.task); assertEquals("Sync: fertig", done.message)
        assertFalse(BgStatus.from(null).running)
    }
}
