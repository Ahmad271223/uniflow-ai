package de.uniflow.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
        fun parsePull(j: JsonElement): PullResult {
            val changes = (j.o("changes") ?: JsonObject(emptyMap())).mapValues { (_, v) -> (v as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList() }
            return PullResult(j.s("cursor"), changes, j.list("tombstones"))
        }

        fun parsePush(j: JsonElement): PushResult {
            val results = j.list("results").map {
                PushResultItem(it.s("entity"), it["id"], it["local_id"], it.s("status") ?: "unknown", it.i("version"),
                    ApiClient.arr(it, "client_won").mapNotNull { c -> (c as? JsonPrimitive)?.content }, it.o("data"))
            }
            val mapping = HashMap<Pair<String, Long>, Long>()
            for (m in j.list("mapping")) {
                val e = m.s("entity") ?: continue
                val l = (m["local_id"] as? JsonPrimitive)?.content?.toLongOrNull() ?: continue
                val id = (m["id"] as? JsonPrimitive)?.content?.toLongOrNull() ?: continue
                mapping[e to l] = id
            }
            return PushResult(results, mapping, j.list("conflicts"), j.s("server_time"))
        }
    }
}
