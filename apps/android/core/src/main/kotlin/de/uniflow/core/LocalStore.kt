package de.uniflow.core

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/** Zeitstempel wie im Vertrag G2: UTC, YYYY-MM-DDTHH:MM:SS.mmmZ, Vergleich als Text. */
object SyncClock {
    private val fmt: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)
    fun now(): String = fmt.format(Instant.now())
    fun format(epochMillis: Long): String = fmt.format(Instant.ofEpochMilli(epochMillis))
}

/** Die Entitaeten des Vertrags G2 (fixtures/sync/cases.json -> rules), Eltern vor Kindern; Fremdschluessel -> Elterntabelle. */
object SyncEntities {
    data class Entity(val name: String, val pk: String, val fk: Map<String, String>)

    val all: List<Entity> = listOf(
        Entity("modules", "id", emptyMap()),
        Entity("folders", "id", mapOf("module_id" to "modules", "parent_id" to "folders")),
        Entity("course_events", "id", mapOf("module_id" to "modules")),
        Entity("event_exceptions", "id", mapOf("event_id" to "course_events")),
        Entity("study_packages", "id", mapOf("module_id" to "modules")),
        Entity("study_tasks", "id", mapOf("package_id" to "study_packages")),
        Entity("flashcards", "id", emptyMap()),
        Entity("settings", "key", emptyMap()),
        Entity("annotations", "file_id", emptyMap()),
    )

    /** In der lokalen Ablage: alles ausser Notizen – die gehen weiter ueber AnnotationStore und die Entwuerfe (Drafts). */
    val stored: List<Entity> = all.filter { it.name != "annotations" }
    val syncColumns = setOf("sync_version", "sync_updated_at", "sync_device")
    val privateSettings = setOf("lan_pin", "university")

    fun byName(name: String): Entity? = all.firstOrNull { it.name == name }

    /** Lesbare Bezeichnung fuer Meldungen. */
    val labels = mapOf("modules" to "Modul", "folders" to "Ordner", "course_events" to "Termin", "event_exceptions" to "Terminausnahme",
        "study_packages" to "Lernpaket", "study_tasks" to "Aufgabe", "flashcards" to "Karteikarte", "settings" to "Einstellung", "annotations" to "Notizen")
}

/**
 * Lokale Ablage der App (SQLite ueber [SqlDb]): die synchronisierten Zeilen aller G2-Entitaeten, Tombstones, der
 * Sync-Cursor und Momentaufnahmen der Server-Ansichten (Bibliothek, Stundenplan-Woche, Kalenderbereich, Uebersicht),
 * damit die Ansichten ohne Netz den letzten Stand zeigen.
 *
 * Eine Zeile je Entitaet und ID in `sync_rows` (Spalten des Servers als JSON in `data`, dazu dieselben drei Spalten
 * wie beim Dienst: `sync_version`, `sync_updated_at`, `sync_device`). Lokale Aenderungen markieren die Zeile als
 * `dirty` mit `dirty_fields` (nur diese Felder gehen beim Push mit, wie im Vertrag "data" = geaenderte Felder) und
 * `updated_at` (Zeitstempel dieses Geraets fuer die Konfliktregel "spaeterer Schreiber gewinnt"). Neue Zeilen haben
 * negative IDs, bis der Server die Zuordnung liefert. Trigger wie beim Dienst: eine Aenderung an `data` ohne neue
 * Serverversion markiert die Zeile als dirty, ein Loeschen schreibt einen Tombstone – ausser waehrend der Uebernahme
 * vom Server (`applying`), die Version und Zeitstempel selbst setzt (gleiche Ausnahme wie im Server-Trigger).
 */
class LocalStore(val db: SqlDb, val deviceId: String, private val clock: () -> String = SyncClock::now) {

    data class Row(val entity: String, val id: String, val data: JsonObject, val syncVersion: Int, val syncUpdatedAt: String?,
                   val syncDevice: String?, val dirty: Boolean, val dirtyFields: Set<String>?, val updatedAt: String?) {
        val isLocalNew: Boolean get() = id.startsWith("-")
        /** Alle Felder (neue Zeile, Wiederherstellung) statt einer Auswahl. */
        val allFieldsDirty: Boolean get() = dirtyFields == null && dirty
        fun idElement(entity: SyncEntities.Entity): JsonElement = if (entity.pk == "id") JsonPrimitive(id.toLong()) else JsonPrimitive(id)
    }

    data class Tombstone(val entity: String, val id: String, val deletedAt: String, val device: String?)
    data class Snapshot(val key: String, val json: JsonElement, val fetchedAt: String)

    init { ensureSchema() }

    private fun ensureSchema() {
        db.exec("""CREATE TABLE IF NOT EXISTS sync_rows (
            entity TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL,
            sync_version INTEGER DEFAULT 0, sync_updated_at TEXT, sync_device TEXT,
            dirty INTEGER DEFAULT 0, dirty_fields TEXT, updated_at TEXT,
            PRIMARY KEY (entity, id))""")
        db.exec("CREATE INDEX IF NOT EXISTS idx_sync_rows_dirty ON sync_rows(dirty)")
        db.exec("""CREATE TABLE IF NOT EXISTS sync_tombstones (
            entity TEXT NOT NULL, entity_id TEXT NOT NULL, deleted_at TEXT NOT NULL, device TEXT,
            PRIMARY KEY (entity, entity_id))""")
        db.exec("CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT)")
        db.exec("CREATE TABLE IF NOT EXISTS snapshots (key TEXT PRIMARY KEY, json TEXT NOT NULL, fetched_at TEXT NOT NULL)")
        // Aenderung durch die App an den Daten (Version und Zeitstempel des Servers unberuehrt, keine Uebernahme vom
        // Server): Zeile wird dirty, Zeitstempel dieses Geraets. Der Kotlin-Pfad (update) setzt dazu dirty_fields.
        db.exec("""CREATE TRIGGER IF NOT EXISTS sync_upd_rows AFTER UPDATE OF data ON sync_rows
            WHEN NEW.sync_version IS OLD.sync_version AND NEW.sync_updated_at IS OLD.sync_updated_at
                 AND (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
            BEGIN UPDATE sync_rows SET dirty = 1, updated_at = COALESCE(NEW.updated_at, $NOW_SQL)
                  WHERE entity = NEW.entity AND id = NEW.id; END""")
        // Loeschen durch die App: Tombstone fuer den Push (nicht fuer Zeilen, die der Server noch nie gesehen hat)
        db.exec("""CREATE TRIGGER IF NOT EXISTS sync_del_rows AFTER DELETE ON sync_rows
            WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL AND substr(OLD.id, 1, 1) <> '-'
            BEGIN INSERT OR REPLACE INTO sync_tombstones(entity, entity_id, deleted_at, device)
                  VALUES (OLD.entity, OLD.id, $NOW_SQL, (SELECT value FROM sync_state WHERE key = 'device_id')); END""")
        db.exec("INSERT OR REPLACE INTO sync_state(key, value) VALUES ('device_id', ?)", listOf(deviceId))
        db.exec("DELETE FROM sync_state WHERE key = 'applying'")        // Abbruch waehrend einer Uebernahme hinterlaesst keinen Schalter
    }

    // ---- Zustand ----

    fun state(key: String): String? = db.query("SELECT value FROM sync_state WHERE key = ?", listOf(key)).firstOrNull()?.text("value")
    fun setState(key: String, value: String?) {
        if (value == null) db.exec("DELETE FROM sync_state WHERE key = ?", listOf(key))
        else db.exec("INSERT OR REPLACE INTO sync_state(key, value) VALUES (?, ?)", listOf(key, value))
    }

    /** Cursor der letzten Antwort von /api/sync/changes; null = noch nie abgeglichen. */
    var cursor: String?
        get() = state("cursor")
        set(v) = setState("cursor", v)

    /** Zeitpunkt des letzten erfolgreichen Abgleichs (UTC). */
    var lastSyncAt: String?
        get() = state("last_sync_at")
        set(v) = setState("last_sync_at", v)

    /** Uebernahme vom Server: Trigger schweigen, Version und Zeitstempel kommen vom Server. */
    fun <T> applying(block: () -> T): T = db.transaction {
        setState("applying", "1")
        try { block() } finally { setState("applying", null) }
    }

    // ---- Zeilen ----

    fun rows(entity: String): List<Row> =
        db.query("SELECT * FROM sync_rows WHERE entity = ? ORDER BY CAST(id AS INTEGER), id", listOf(entity)).map { toRow(it) }

    fun row(entity: String, id: String): Row? =
        db.query("SELECT * FROM sync_rows WHERE entity = ? AND id = ?", listOf(entity, id)).firstOrNull()?.let { toRow(it) }

    fun dirtyRows(): List<Row> =
        db.query("SELECT * FROM sync_rows WHERE dirty = 1 ORDER BY entity, CAST(id AS INTEGER), id").map { toRow(it) }

    fun count(entity: String): Int = db.query("SELECT COUNT(*) AS n FROM sync_rows WHERE entity = ?", listOf(entity)).first().long("n")!!.toInt()

    /** Offene lokale Aenderungen (Zeilen und Loeschungen), die noch nicht beim Server sind. */
    fun pendingCount(): Int = db.query("SELECT (SELECT COUNT(*) FROM sync_rows WHERE dirty = 1) + (SELECT COUNT(*) FROM sync_tombstones) AS n").first().long("n")!!.toInt()

    /**
     * Neue Zeile dieses Geraets: negative ID bis zur Zuordnung durch den Server, alle Felder gehen beim Push mit.
     * Fremdschluessel duerfen auf andere negative IDs zeigen (der Server loest sie im selben Push auf).
     */
    fun insertLocal(entity: String, data: JsonObject, at: String = clock()): Long {
        val id = nextLocalId()
        db.exec("INSERT INTO sync_rows(entity, id, data, sync_version, sync_updated_at, sync_device, dirty, dirty_fields, updated_at) VALUES (?,?,?,0,NULL,NULL,1,NULL,?)",
            listOf(entity, id.toString(), data.toString(), at))
        return id
    }

    private fun nextLocalId(): Long {
        val next = (state("next_local_id")?.toLongOrNull() ?: -1L)
        setState("next_local_id", (next - 1).toString())
        return next
    }

    /**
     * Lokale Aenderung einzelner Felder (z. B. Aufgabe abhaken): Daten zusammenfuehren, Felder als geaendert merken,
     * Zeitstempel dieses Geraets. false, wenn es die Zeile nicht gibt.
     */
    fun update(entity: String, id: String, patch: JsonObject, at: String = clock()): Boolean {
        val cur = row(entity, id) ?: return false
        val data = JsonObject(cur.data + patch)
        val fields: Set<String>? = if (cur.allFieldsDirty) null else (cur.dirtyFields ?: emptySet()) + patch.keys
        db.exec("UPDATE sync_rows SET data = ?, dirty = 1, dirty_fields = ?, updated_at = ? WHERE entity = ? AND id = ?",
            listOf(data.toString(), fields?.let { JsonArray(it.map { f -> JsonPrimitive(f) }).toString() }, at, entity, id))
        return true
    }

    /** Einstellung setzen (Schluessel = ID; beim Push als `local_id` mit `data.value`, wie im Vertrag). */
    fun setSetting(key: String, value: String, at: String = clock()) {
        val data = JsonObject(mapOf("key" to JsonPrimitive(key), "value" to JsonPrimitive(value)))
        if (row("settings", key) == null) {
            db.exec("INSERT INTO sync_rows(entity, id, data, sync_version, dirty, dirty_fields, updated_at) VALUES ('settings', ?, ?, 0, 1, '[\"value\"]', ?)",
                listOf(key, data.toString(), at))
        } else update("settings", key, JsonObject(mapOf("value" to JsonPrimitive(value))), at)
    }

    fun setting(key: String): String? = row("settings", key)?.data?.s("value")

    /** Lokales Loeschen: Zeile weg, Tombstone fuer den Push (nicht fuer Zeilen, die der Server noch nicht kennt). */
    fun delete(entity: String, id: String, at: String = clock()) {
        applying {
            db.exec("DELETE FROM sync_rows WHERE entity = ? AND id = ?", listOf(entity, id))
            if (!id.startsWith("-")) db.exec("INSERT OR REPLACE INTO sync_tombstones(entity, entity_id, deleted_at, device) VALUES (?,?,?,?)", listOf(entity, id, at, deviceId))
        }
    }

    fun tombstones(): List<Tombstone> = db.query("SELECT * FROM sync_tombstones ORDER BY deleted_at, entity, entity_id").map {
        Tombstone(it.text("entity")!!, it.text("entity_id")!!, it.text("deleted_at")!!, it.text("device"))
    }

    fun removeTombstone(entity: String, id: String) { db.exec("DELETE FROM sync_tombstones WHERE entity = ? AND entity_id = ?", listOf(entity, id)) }

    // ---- Uebernahme vom Server (nur innerhalb von applying) ----

    /** Zeile so ablegen, wie der Server sie liefert (Daten ohne sync_*-Spalten), nicht dirty. */
    fun putServerRow(entity: String, id: String, data: JsonObject, version: Int, updatedAt: String?, device: String?) {
        db.exec("""INSERT OR REPLACE INTO sync_rows(entity, id, data, sync_version, sync_updated_at, sync_device, dirty, dirty_fields, updated_at)
                   VALUES (?,?,?,?,?,?,0,NULL,NULL)""", listOf(entity, id, data.toString(), version, updatedAt, device))
    }

    /** Daten und Markierung einer Zeile setzen (Zusammenfuehrung beim Pull, Konflikt-Ergebnis beim Push). */
    fun putRow(entity: String, id: String, data: JsonObject, version: Int, updatedAt: String?, device: String?, dirtyFields: Set<String>?, allDirty: Boolean, localUpdatedAt: String?) {
        val dirty = allDirty || !dirtyFields.isNullOrEmpty()
        db.exec("""INSERT OR REPLACE INTO sync_rows(entity, id, data, sync_version, sync_updated_at, sync_device, dirty, dirty_fields, updated_at)
                   VALUES (?,?,?,?,?,?,?,?,?)""",
            listOf(entity, id, data.toString(), version, updatedAt, device, if (dirty) 1 else 0,
                if (!dirty || allDirty) null else JsonArray(dirtyFields!!.map { JsonPrimitive(it) }).toString(), if (dirty) localUpdatedAt else null))
    }

    /** Nur die Daten ersetzen (Fremdschluessel nach einer ID-Zuordnung); Markierungen bleiben. */
    fun rewriteData(entity: String, id: String, data: JsonObject) {
        db.exec("UPDATE sync_rows SET data = ? WHERE entity = ? AND id = ?", listOf(data.toString(), entity, id))
    }

    /** Server hat die Zeile angelegt: lokale (negative) ID durch die Server-ID ersetzen, Zeile ist synchron. */
    fun rename(entity: String, oldId: String, newId: String, version: Int, updatedAt: String?, device: String?) {
        db.exec("DELETE FROM sync_rows WHERE entity = ? AND id = ?", listOf(entity, newId))
        db.exec("UPDATE sync_rows SET id = ?, sync_version = ?, sync_updated_at = ?, sync_device = ?, dirty = 0, dirty_fields = NULL, updated_at = NULL WHERE entity = ? AND id = ?",
            listOf(newId, version, updatedAt, device, entity, oldId))
    }

    fun markSynced(entity: String, id: String, version: Int, updatedAt: String?, device: String?) {
        db.exec("UPDATE sync_rows SET sync_version = ?, sync_updated_at = ?, sync_device = ?, dirty = 0, dirty_fields = NULL, updated_at = NULL WHERE entity = ? AND id = ?",
            listOf(version, updatedAt, device, entity, id))
    }

    fun removeRow(entity: String, id: String) { db.exec("DELETE FROM sync_rows WHERE entity = ? AND id = ?", listOf(entity, id)) }

    // ---- Momentaufnahmen der Server-Ansichten ----

    fun snapshot(key: String): Snapshot? = db.query("SELECT * FROM snapshots WHERE key = ?", listOf(key)).firstOrNull()?.let {
        val json = runCatching { Json.parseToJsonElement(it.text("json")!!) }.getOrNull() ?: return null
        Snapshot(key, json, it.text("fetched_at")!!)
    }

    fun putSnapshot(key: String, json: JsonElement, at: String = clock()) {
        db.exec("INSERT OR REPLACE INTO snapshots(key, json, fetched_at) VALUES (?,?,?)", listOf(key, json.toString(), at))
    }

    /** Alles verwerfen (Abmelden: ein anderes Konto erbt nichts). */
    fun clearAll() {
        db.transaction {
            db.exec("DELETE FROM sync_rows"); db.exec("DELETE FROM sync_tombstones"); db.exec("DELETE FROM snapshots")
            db.exec("DELETE FROM sync_state WHERE key <> 'device_id'")
        }
    }

    private fun toRow(r: Map<String, Any?>): Row {
        val fieldsText = r.text("dirty_fields")
        val fields = fieldsText?.let { t -> runCatching { (Json.parseToJsonElement(t) as JsonArray).map { it.jsonPrimitive.content }.toSet() }.getOrNull() }
        return Row(r.text("entity")!!, r.text("id")!!, parseObject(r.text("data")), (r.long("sync_version") ?: 0).toInt(), r.text("sync_updated_at"),
            r.text("sync_device"), (r.long("dirty") ?: 0L) != 0L, fields, r.text("updated_at"))
    }

    companion object {
        const val NOW_SQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

        fun parseObject(text: String?): JsonObject =
            text?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() } ?: JsonObject(emptyMap())

        /** Serverzeile ohne die drei Sync-Spalten. */
        fun dataOf(serverRow: JsonObject): JsonObject = JsonObject(serverRow.filterKeys { it !in SyncEntities.syncColumns })

        /** Primaerschluessel einer Serverzeile als Text (IDs sind Zahlen, Einstellungen Schluessel, Notizen Datei-IDs). */
        fun idOf(entity: SyncEntities.Entity, row: JsonObject): String? = (row[entity.pk] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    }
}
