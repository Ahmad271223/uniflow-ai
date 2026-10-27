package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonPrimitive

/** Lokale Ablage: Rundlauf, Trigger wie beim Dienst (dirty, Tombstone, Ausnahme waehrend der Uebernahme), Momentaufnahmen, Neustart. */
class LocalStoreTest {
    private var now = "2026-10-27T10:00:00.000Z"
    private fun store(db: SqlDb = JdbcSqlDb.memory()) = LocalStore(db, "android-test", clock = { now })
    private fun obj(vararg p: Pair<String, Any?>) = ApiClient.obj(*p)

    @Test
    fun localInsertUpdateAndDeleteAreMarkedForPush() {
        val s = store()
        val id = s.insertLocal("modules", obj("name" to "Mathe I", "color" to "#4f5bd5"))
        assertEquals(-1L, id)
        assertEquals(-2L, s.insertLocal("study_packages", obj("date" to "2026-11-02", "module_id" to -1)))
        val m = s.row("modules", "-1")!!
        assertTrue(m.dirty && m.allFieldsDirty && m.isLocalNew)
        assertEquals("2026-10-27T10:00:00.000Z", m.updatedAt)
        assertEquals(2, s.pendingCount())

        // Serverzeile ablegen, dann ein Feld aendern: nur dieses Feld ist dirty, Basisversion bleibt die des Servers
        s.applying { s.putServerRow("study_tasks", "5", obj("id" to 5, "title" to "Blatt 3", "status" to "geplant"), 3, "2026-10-26T08:00:00.000Z", "mac-1") }
        assertFalse(s.row("study_tasks", "5")!!.dirty)
        now = "2026-10-27T11:00:00.000Z"
        assertTrue(s.update("study_tasks", "5", obj("status" to "erledigt", "done_at" to now)))
        val t = s.row("study_tasks", "5")!!
        assertTrue(t.dirty); assertEquals(setOf("status", "done_at"), t.dirtyFields); assertEquals(3, t.syncVersion); assertEquals(now, t.updatedAt)
        assertEquals("erledigt", t.data.s("status")); assertEquals("Blatt 3", t.data.s("title"))
        assertFalse(s.update("study_tasks", "99", obj("status" to "x")))

        // Loeschen: Tombstone fuer Serverzeilen, keiner fuer nie gesendete
        s.delete("study_tasks", "5"); s.delete("modules", "-1")
        assertNull(s.row("study_tasks", "5")); assertNull(s.row("modules", "-1"))
        assertEquals(listOf(LocalStore.Tombstone("study_tasks", "5", now, "android-test")), s.tombstones())
    }

    @Test
    fun triggersMirrorTheServer() {
        val s = store()
        s.applying { s.putServerRow("modules", "1", obj("id" to 1, "name" to "Physik"), 2, "2026-10-26T08:00:00.000Z", null) }
        // Rohe Aenderung der Daten ohne neue Serverversion (wie ein App-Schreibpfad): Trigger markiert dirty mit Zeitstempel
        s.db.exec("UPDATE sync_rows SET data = ? WHERE entity = 'modules' AND id = '1'", listOf(obj("id" to 1, "name" to "Physik I").toString()))
        val r = s.row("modules", "1")!!
        assertTrue(r.dirty); assertTrue(r.allFieldsDirty); assertNotNull(r.updatedAt); assertTrue(r.updatedAt!!.endsWith("Z")); assertEquals(2, r.syncVersion)
        // Uebernahme vom Server (Version und Zeitstempel kommen mit): kein Trigger
        s.applying { s.putServerRow("modules", "1", obj("id" to 1, "name" to "Physik II"), 3, "2026-10-27T08:00:00.000Z", "mac-1") }
        assertFalse(s.row("modules", "1")!!.dirty)
        assertNull(s.state("applying"))
        // Rohes Loeschen: Tombstone mit Geraet; waehrend der Uebernahme keiner
        s.db.exec("DELETE FROM sync_rows WHERE entity = 'modules' AND id = '1'")
        assertEquals("android-test", s.tombstones().single().device)
        s.applying { s.putServerRow("modules", "2", obj("id" to 2), 1, null, null); s.removeRow("modules", "2") }
        assertEquals(1, s.tombstones().size)
        // Abbruch waehrend der Uebernahme laesst den Schalter nicht stehen
        runCatching { s.applying { throw IllegalStateException("abbruch") } }
        assertNull(s.state("applying"))
    }

    @Test
    fun settingsUseTheKeyAsId() {
        val s = store()
        s.setSetting("hours_per_day", "6")
        val r = s.row("settings", "hours_per_day")!!
        assertEquals(setOf("value"), r.dirtyFields); assertEquals("6", s.setting("hours_per_day"))
        s.applying { s.markSynced("settings", "hours_per_day", 2, now, "android-test") }
        s.setSetting("hours_per_day", "7")
        assertEquals("7", s.setting("hours_per_day")); assertEquals(setOf("value"), s.row("settings", "hours_per_day")!!.dirtyFields)
        assertNull(s.setting("gibt_es_nicht"))
    }

    @Test
    fun snapshotsStateAndRestart() {
        val dir = File(System.getProperty("java.io.tmpdir"), "uniflow-localstore-" + System.nanoTime()).apply { mkdirs() }
        val f = File(dir, "local.db")
        try {
            val s = store(JdbcSqlDb.file(f))
            s.putSnapshot("library", obj("files" to kotlinx.serialization.json.JsonArray(listOf(obj("id" to "f1")))), "2026-10-27T09:00:00.000Z")
            s.cursor = "2026-10-27T09:00:00.000Z"
            s.insertLocal("flashcards", obj("question" to "Q"))
            s.db.close()
            val again = store(JdbcSqlDb.file(f))
            val snap = again.snapshot("library")!!
            assertEquals("2026-10-27T09:00:00.000Z", snap.fetchedAt); assertEquals("f1", snap.json.list("files").single().s("id"))
            assertEquals("2026-10-27T09:00:00.000Z", again.cursor)
            assertTrue(again.row("flashcards", "-1")!!.dirty)
            assertEquals(-2L, again.insertLocal("flashcards", obj("question" to "Q2")))        // Zaehler laeuft weiter
            assertNull(again.snapshot("fehlt"))
            again.clearAll()
            assertNull(again.cursor); assertNull(again.snapshot("library")); assertEquals(0, again.pendingCount())
            assertEquals("android-test", again.state("device_id"))
            again.db.close()
        } finally { dir.deleteRecursively() }
    }

    @Test
    fun serverRowHelpers() {
        val row = obj("id" to 7, "name" to "x", "sync_version" to 3, "sync_updated_at" to "t", "sync_device" to "ipad-1")
        assertEquals(obj("id" to 7, "name" to "x"), LocalStore.dataOf(row))
        assertEquals("7", LocalStore.idOf(SyncEntities.byName("modules")!!, row))
        assertEquals("hours_per_day", LocalStore.idOf(SyncEntities.byName("settings")!!, obj("key" to "hours_per_day")))
        assertNull(LocalStore.idOf(SyncEntities.byName("modules")!!, obj("name" to "ohne id")))
        assertEquals(JsonPrimitive(7L), LocalStore.Row("modules", "7", row, 1, null, null, false, null, null).idElement(SyncEntities.byName("modules")!!))
        assertEquals(listOf("modules", "folders", "course_events", "event_exceptions", "study_packages", "study_tasks", "flashcards", "settings"), SyncEntities.stored.map { it.name })
    }
}
