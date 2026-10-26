package de.uniflow.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Geraete-Synchronisierung (Vertrag G2, packages/shared-contracts/fixtures/sync/cases.json):
 * Abruf mit Cursor, Senden mit lokalen IDs (negativ) und Zuordnung in der Antwort, Konflikte je Feld,
 * Loeschen als Tombstone. Die lokale Ablage (Room) kommt in der App; hier die Nachrichtenform.
 */
data class PushItem(val entity: String, val id: JsonElement? = null, val localId: JsonElement? = null, val baseVersion: Int? = null,
                    val updatedAt: String? = null, val data: JsonObject) {
    fun toJson(): JsonObject = buildJsonObject {
        put("entity", entity)
        if (id != null) put("id", id)
        if (localId != null) put("local_id", localId)
        if (baseVersion != null) put("base_version", baseVersion)
        if (updatedAt != null) put("updated_at", updatedAt)
        put("data", data)
    }
}

data class PushDelete(val entity: String, val id: JsonElement, val deletedAt: String? = null) {
    fun toJson(): JsonObject = buildJsonObject { put("entity", entity); put("id", id); if (deletedAt != null) put("deleted_at", deletedAt) }
}

data class PushResultItem(val entity: String?, val id: JsonElement?, val localId: JsonElement?, val status: String, val version: Int?,
                          val clientWon: List<String>, val serverData: JsonObject?)

data class PushResult(val results: List<PushResultItem>, val mapping: Map<Pair<String, Long>, Long>, val conflicts: List<JsonObject>,
                      val serverTime: String?) {
    /** Neue Server-ID zu einer lokalen (negativen) ID. */
    fun serverId(entity: String, localId: Long): Long? = mapping[entity to localId]
    val applied: Int get() = results.count { it.status in setOf("applied", "created", "resurrected", "deleted") }
    val conflicted: Int get() = results.count { it.status in setOf("conflict", "edit_wins") }
}

data class PullResult(val cursor: String?, val changes: Map<String, List<JsonObject>>, val tombstones: List<JsonObject>) {
    val isEmpty: Boolean get() = changes.values.all { it.isEmpty() } && tombstones.isEmpty()
}

class SyncApi(private val client: ApiClient) {

    fun pull(since: String?, deviceId: String? = null): PullResult =
        parsePull(client.get("/api/sync/changes", mapOf("since" to since, "device_id" to deviceId)))

    fun push(deviceId: String, items: List<PushItem>, deletes: List<PushDelete> = emptyList()): PushResult =
        parsePush(client.post("/api/sync/push", buildJsonObject {
            put("device_id", deviceId)
            put("items", JsonArray(items.map { it.toJson() }))
            put("deletes", JsonArray(deletes.map { it.toJson() }))
        }))

    companion object {
        /**
         * Antworten werden strikt gelesen: ein Eintrag, der nicht zum Vertrag passt, ist ein Fehler mit Position
         * (SyncFormatError) und wird nicht still uebersprungen, sonst gingen Aenderungen oder ID-Zuordnungen verloren.
         * Fehlende Listen gelten als leer.
         */
        fun parsePull(j: JsonElement): PullResult {
            val root = j as? JsonObject ?: throw SyncFormatError("Antwort", "ist kein Objekt")
            val changes = LinkedHashMap<String, List<JsonObject>>()
            root["changes"]?.takeIf { it !is JsonNull }?.let { c ->
                val byEntity = c as? JsonObject ?: throw SyncFormatError("changes", "ist kein Objekt")
                for ((entity, v) in byEntity) changes[entity] = objects(v, "changes.$entity")
            }
            return PullResult(root.s("cursor"), changes, objects(root["tombstones"], "tombstones"))
        }

        fun parsePush(j: JsonElement): PushResult {
            val root = j as? JsonObject ?: throw SyncFormatError("Antwort", "ist kein Objekt")
            val results = objects(root["results"], "results").mapIndexed { i, r ->
                PushResultItem(r.s("entity"), r["id"], r["local_id"], string(r["status"]) ?: throw SyncFormatError("results[$i].status", "fehlt"),
                    r.i("version"), ApiClient.arr(r, "client_won").mapNotNull { c -> (c as? JsonPrimitive)?.content }, r.o("data"))
            }
            val mapping = HashMap<Pair<String, Long>, Long>()
            objects(root["mapping"], "mapping").forEachIndexed { i, m ->
                val e = string(m["entity"])?.takeIf { it.isNotEmpty() } ?: throw SyncFormatError("mapping[$i].entity", "fehlt")
                val l = integer(m["local_id"], "mapping[$i].local_id")
                val id = integer(m["id"], "mapping[$i].id")
                if (mapping.put(e to l, id) != null) throw SyncFormatError("mapping[$i]", "ordnet $e/$l doppelt zu")
            }
            return PushResult(results, mapping, objects(root["conflicts"], "conflicts"), root.s("server_time"))
        }

        /** Liste von Objekten an `position`; fehlt sie, ist sie leer. Andere Formen sind ein Fehler. */
        private fun objects(e: JsonElement?, position: String): List<JsonObject> {
            if (e == null || e is JsonNull) return emptyList()
            val arr = e as? JsonArray ?: throw SyncFormatError(position, "ist keine Liste")
            return arr.mapIndexed { i, x -> x as? JsonObject ?: throw SyncFormatError("$position[$i]", "ist kein Objekt") }
        }

        private fun string(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.content

        private fun integer(e: JsonElement?, position: String): Long {
            val p = e as? JsonPrimitive ?: throw SyncFormatError(position, "fehlt oder ist keine ganze Zahl")
            if (p.isString) throw SyncFormatError(position, "ist keine ganze Zahl")
            return p.content.toLongOrNull() ?: throw SyncFormatError(position, "ist keine ganze Zahl")
        }
    }
}

/** Antwort des Servers passt nicht zum Vertrag G2; `position` nennt den Eintrag (z. B. changes.modules[2], mapping[0].id). */
class SyncFormatError(val position: String, reason: String) : Exception("Ungueltige Sync-Antwort: $position $reason")
