package de.uniflow.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json

/** Vertrag G2, kaputte Antworten: ungueltige Eintraege werden nicht still verworfen, sondern mit Position gemeldet. */
class SyncApiTest {
    private fun j(s: String) = Json.parseToJsonElement(s)
    private fun pullFails(body: String): SyncFormatError = assertFailsWith<SyncFormatError>(body) { SyncApi.parsePull(j(body)) }
    private fun pushFails(body: String): SyncFormatError = assertFailsWith<SyncFormatError>(body) { SyncApi.parsePush(j(body)) }
    private fun pushWith(mapping: String, results: String = "[]", conflicts: String = "[]") =
        """{"results":$results,"mapping":[$mapping],"conflicts":$conflicts,"server_time":"t"}"""

    @Test
    fun pullRejectsInvalidEntriesWithPosition() {
        assertEquals("changes.modules[1]", pullFails("""{"cursor":"c","changes":{"modules":[{"id":1},"kaputt"]},"tombstones":[]}""").position)
        assertEquals("changes.flashcards[0]", pullFails("""{"changes":{"flashcards":[null]}}""").position)
        assertEquals("changes.modules", pullFails("""{"changes":{"modules":{"id":1}},"tombstones":[]}""").position)
        assertEquals("changes", pullFails("""{"changes":[]}""").position)
        assertEquals("tombstones[0]", pullFails("""{"changes":{},"tombstones":[1]}""").position)
        assertEquals("tombstones", pullFails("""{"changes":{},"tombstones":{}}""").position)
        assertEquals("Antwort", pullFails("""[]""").position)
        assertEquals("Antwort", pullFails("""null""").position)
        val e = pullFails("""{"changes":{"modules":[{"id":1},"kaputt"]}}""")
        assertTrue(e.message!!.contains("changes.modules[1]") && e.message!!.contains("kein Objekt"), e.message)
    }

    @Test
    fun pullParsesValidAndMinimalResponses() {
        val r = SyncApi.parsePull(j("""{"cursor":"2026-10-26T10:00:00.000Z","changes":{"modules":[{"id":1},{"id":2}],"settings":[]},"tombstones":[{"entity":"modules","entity_id":"3"}]}"""))
        assertEquals("2026-10-26T10:00:00.000Z", r.cursor)
        assertEquals(listOf("modules", "settings"), r.changes.keys.toList())
        assertEquals(2, r.changes["modules"]!!.size); assertEquals(0, r.changes["settings"]!!.size)
        assertEquals("3", r.tombstones[0].s("entity_id"))
        assertTrue(!r.isEmpty)
        val empty = SyncApi.parsePull(j("""{"cursor":null}"""))              // fehlende Listen gelten als leer
        assertNull(empty.cursor); assertTrue(empty.isEmpty)
    }

    @Test
    fun pushRejectsBrokenMappingWithPosition() {
        assertEquals("mapping[0].id", pushFails(pushWith("""{"entity":"modules","local_id":-1}""")).position)
        assertEquals("mapping[0].id", pushFails(pushWith("""{"entity":"modules","local_id":-1,"id":1.5}""")).position)
        assertEquals("mapping[0].id", pushFails(pushWith("""{"entity":"modules","local_id":-1,"id":"7"}""")).position)
        assertEquals("mapping[0].local_id", pushFails(pushWith("""{"entity":"modules","local_id":"abc","id":1}""")).position)
        assertEquals("mapping[0].local_id", pushFails(pushWith("""{"entity":"modules","local_id":null,"id":1}""")).position)
        assertEquals("mapping[0].entity", pushFails(pushWith("""{"local_id":-1,"id":1}""")).position)
        assertEquals("mapping[0].entity", pushFails(pushWith("""{"entity":"","local_id":-1,"id":1}""")).position)
        assertEquals("mapping[0].entity", pushFails(pushWith("""{"entity":5,"local_id":-1,"id":1}""")).position)
        assertEquals("mapping[1]", pushFails(pushWith("""{"entity":"modules","local_id":-1,"id":1}, 7""")).position)
        assertEquals("mapping[1]", pushFails(pushWith("""{"entity":"modules","local_id":-1,"id":1},{"entity":"modules","local_id":-1,"id":2}""")).position)
        assertEquals("mapping", pushFails("""{"results":[],"mapping":{},"conflicts":[]}""").position)
    }

    @Test
    fun pushRejectsBrokenResultsAndConflicts() {
        assertEquals("results[1]", pushFails(pushWith("", results = """[{"entity":"modules","id":1,"status":"applied"},7]""")).position)
        assertEquals("results[0].status", pushFails(pushWith("", results = """[{"entity":"modules","id":1}]""")).position)
        assertEquals("results[0].status", pushFails(pushWith("", results = """[{"entity":"modules","id":1,"status":3}]""")).position)
        assertEquals("conflicts[0]", pushFails(pushWith("", conflicts = """["x"]""")).position)
        assertEquals("Antwort", pushFails("""[]""").position)
    }

    @Test
    fun pushParsesValidResponse() {
        val r = SyncApi.parsePush(j("""{"results":[{"entity":"modules","local_id":-1,"id":4,"status":"created","version":1},
            {"entity":"modules","id":2,"status":"conflict","version":3,"client_won":["name"],"data":{"name":"x"}}],
            "mapping":[{"entity":"modules","local_id":-1,"id":4},{"entity":"flashcards","local_id":-1,"id":9}],"conflicts":[{"entity":"modules","id":2}],"server_time":"t"}"""))
        assertEquals(4L, r.serverId("modules", -1)); assertEquals(9L, r.serverId("flashcards", -1)); assertNull(r.serverId("modules", -2))
        assertEquals(1, r.applied); assertEquals(1, r.conflicted)
        assertEquals(listOf("name"), r.results[1].clientWon)
        assertEquals("t", r.serverTime)
        val minimal = SyncApi.parsePush(j("""{"results":[]}"""))
        assertTrue(minimal.mapping.isEmpty() && minimal.conflicts.isEmpty() && minimal.serverTime == null)
    }

    @Test
    fun errorsSurfaceThroughTheClient() {
        val transport = object : HttpTransport {
            override fun send(request: HttpRequest) = HttpResponse(200, emptyMap(), """{"changes":{"modules":["kaputt"]},"tombstones":[]}""".toByteArray())
        }
        val e = assertFailsWith<SyncFormatError> { SyncApi(ApiClient("http://pc", transport)).pull(null) }
        assertEquals("changes.modules[0]", e.position)
    }
}
