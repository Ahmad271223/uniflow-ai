package de.uniflow.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Geraete-Abgleich (Vertrag G2) zwischen der lokalen Ablage ([LocalStore]) und dem Server ([SyncApi]):
 *
 * - **Push**: alle dirty Zeilen (neue mit negativer `local_id` und allen Feldern; geaenderte mit `id`, `base_version`
 *   = bekannte Serverversion, `updated_at` dieses Geraets und nur den geaenderten Feldern) und alle Tombstones, Eltern
 *   vor Kindern. Die Antwort wird uebernommen: `created` ersetzt die lokale ID (auch in Fremdschluesseln anderer
 *   Zeilen), `applied`/`resurrected` setzen die Version, `conflict` legt den Serverstand ab und behaelt die Felder,
 *   die der Server dem Geraet zugesprochen hat (`client_won`), `deleted` (Tombstone war neuer) entfernt die Zeile,
 *   `edit_wins` verwirft die lokale Loeschung und holt die Serverzeile zurueck, `ignored` (private Einstellung) entfernt die
 *   Zeile aus der Ablage, `error`/`unknown_entity` bleiben dirty und werden gemeldet.
 * - **Pull**: `/api/sync/changes?since=<cursor>`; Zeilen ersetzen den lokalen Stand, ausser die Zeile ist lokal dirty:
 *   dann gilt die Regel des Vertrags je Feld (spaeterer Schreiber gewinnt: `updated_at` des Geraets gegen
 *   `sync_updated_at` des Servers), und die Basisversion wird die des Servers. Tombstones loeschen die Zeile; eine
 *   juengere lokale Aenderung ueberlebt und wird beim naechsten Push mit allen Feldern wiederhergestellt (`resurrected`).
 *
 * Notizen (`annotations`) laufen nicht hier, sondern ueber AnnotationStore mit den Merge-Regeln (fixtures/merge).
 */
class SyncEngine(private val store: LocalStore, private val api: SyncApi, private val deviceId: String, private val clock: () -> String = SyncClock::now) {

    data class Report(val sentItems: Int = 0, val sentDeletes: Int = 0, val applied: Int = 0, val conflicts: List<String> = emptyList(),
                      val errors: List<String> = emptyList(), val pulledRows: Int = 0, val pulledTombstones: Int = 0, val cursor: String? = null) {
        operator fun plus(o: Report) = Report(sentItems + o.sentItems, sentDeletes + o.sentDeletes, applied + o.applied, conflicts + o.conflicts,
            errors + o.errors, pulledRows + o.pulledRows, pulledTombstones + o.pulledTombstones, o.cursor ?: cursor)

        /** Kurzer Text fuer die Oberflaeche. */
        fun summary(): String = buildList {
            if (sentItems + sentDeletes > 0) add("${sentItems + sentDeletes} Änderung${if (sentItems + sentDeletes == 1) "" else "en"} gesendet")
            if (pulledRows + pulledTombstones > 0) add("${pulledRows + pulledTombstones} übernommen")
            if (conflicts.isNotEmpty()) add("${conflicts.size} Konflikt${if (conflicts.size == 1) "" else "e"} aufgelöst")
            if (errors.isNotEmpty()) add("${errors.size} Fehler")
        }.joinToString(", ").ifEmpty { "Alles aktuell" }
    }

    /** Erst senden, dann holen: so kommt der eigene Stand nicht als fremde Aenderung zurueck. */
    fun sync(): Report {
        val pushed = push()
        val pulled = pull()
        store.lastSyncAt = clock()
        return pushed + pulled
    }

    // ---- Push ----

    /** Nachricht aus der lokalen Ablage (ohne Senden; im Test gegen die Fixture-Faelle vergleichbar). */
    fun buildPush(): Pair<List<PushItem>, List<PushDelete>> {
        val items = ArrayList<PushItem>()
        for (entity in SyncEntities.stored) {
            // neue Zeilen in der Reihenfolge ihres Anlegens (-1, -2, ...), dann bestehende nach ID: Eltern vor Kindern auch innerhalb einer Entitaet
            val dirty = store.rows(entity.name).filter { it.dirty }
                .sortedWith(compareBy({ !it.isLocalNew }, { if (it.isLocalNew) -it.id.toLong() else (it.id.toLongOrNull() ?: 0L) }))
            for (r in dirty) items.add(itemFor(entity, r))
        }
        val deletes = store.tombstones().filter { !it.id.startsWith("-") && SyncEntities.byName(it.entity) != null && it.entity != "annotations" }
            .map { PushDelete(it.entity, idElement(SyncEntities.byName(it.entity)!!, it.id), it.deletedAt) }
        return items to deletes
    }

    private fun itemFor(entity: SyncEntities.Entity, r: LocalStore.Row): PushItem {
        if (entity.name == "settings") {
            // Einstellungen: immer local_id = Schluessel und data.value (der Server legt an oder ueberschreibt)
            return PushItem(entity.name, localId = JsonPrimitive(r.id), data = JsonObject(mapOf("value" to (r.data["value"] ?: JsonNull))))
        }
        val withoutPk = JsonObject(r.data.filterKeys { it != entity.pk })
        if (r.isLocalNew) return PushItem(entity.name, localId = JsonPrimitive(r.id.toLong()), data = withoutPk)
        val data = if (r.allFieldsDirty) withoutPk else JsonObject(withoutPk.filterKeys { it in (r.dirtyFields ?: emptySet()) })
        return PushItem(entity.name, id = r.idElement(entity), baseVersion = r.syncVersion, updatedAt = r.updatedAt, data = data)
    }

    fun push(): Report {
        val (items, deletes) = buildPush()
        if (items.isEmpty() && deletes.isEmpty()) return Report()
        val result = api.push(deviceId, items, deletes)
        return applyPush(items, deletes, result)
    }

    /** Antwort des Servers in die Ablage uebernehmen (getrennt vom Senden, damit die Fixture-Antworten im Test eingespielt werden koennen). */
    fun applyPush(items: List<PushItem>, deletes: List<PushDelete>, result: PushResult): Report {
        val conflicts = ArrayList<String>()
        val errors = ArrayList<String>()
        var applied = 0
        val deleteKeys = deletes.map { it.entity to it.id.content() }.toSet()
        val serverTime = result.serverTime
        store.applying {
            for (res in result.results) {
                val entityName = res.entity ?: continue
                val entity = SyncEntities.byName(entityName)
                if (entity == null) { errors.add("Unbekannte Entität „$entityName“ in der Antwort"); continue }
                val label = SyncEntities.labels[entityName] ?: entityName
                val id = res.id?.content()
                val localId = res.localId?.content()
                if (id != null && (entityName to id) in deleteKeys && res.status in setOf("deleted", "edit_wins")) {
                    // Antwort auf eine lokale Loeschung
                    store.removeTombstone(entityName, id)
                    if (res.status == "edit_wins") {
                        val server = result.conflicts.firstOrNull { it.s("entity") == entityName && it["id"]?.content() == id }?.o("server")
                        if (server != null) {
                            store.putServerRow(entityName, id, LocalStore.dataOf(server), server.i("sync_version") ?: (res.version ?: 1), server.s("sync_updated_at"), server.s("sync_device"))
                            conflicts.add("$label „${title(server)}“: auf einem anderen Gerät inzwischen geändert, Löschen verworfen")
                        }
                    } else applied++
                    continue
                }
                when (res.status) {
                    "created" -> {
                        val local = localId ?: continue
                        val newId = (result.serverId(entityName, local.toLongOrNull() ?: Long.MIN_VALUE) ?: id?.toLongOrNull())?.toString()
                        if (newId == null) { errors.add("$label: Server nannte keine ID für die neue Zeile $local"); continue }
                        store.rename(entityName, local, newId, res.version ?: 1, serverTime, deviceId)
                        remapForeignKeys(entityName, local.toLong(), newId.toLong())
                        applied++
                    }
                    "applied", "resurrected" -> {
                        val rid = id ?: localId ?: continue
                        store.markSynced(entityName, rid, res.version ?: 1, serverTime, deviceId); applied++
                    }
                    "conflict" -> {
                        val rid = id ?: continue
                        val local = store.row(entityName, rid)
                        val server = result.conflicts.firstOrNull { it.s("entity") == entityName && it["id"]?.content() == rid }?.o("server")
                        if (local == null) continue
                        val base = if (server != null) LocalStore.dataOf(server) else local.data
                        val merged = JsonObject(base + local.data.filterKeys { it in res.clientWon })
                        store.putServerRow(entityName, rid, merged, res.version ?: local.syncVersion, serverTime, if (res.clientWon.isEmpty()) server?.s("sync_device") else deviceId)
                        conflicts.add(if (res.clientWon.isEmpty()) "$label „${title(merged)}“: anderes Gerät war später, dessen Stand gilt"
                                      else "$label „${title(merged)}“: ${res.clientWon.joinToString(", ")} von diesem Gerät übernommen")
                        applied++
                    }
                    "deleted" -> { val rid = id ?: continue; store.removeRow(entityName, rid); conflicts.add("$label $rid: auf einem anderen Gerät gelöscht, lokale Änderung verworfen") }
                    // private Einstellung (lan_pin, university): gehoert nicht in die Ablage, der Server nimmt sie nie
                    "ignored" -> { val rid = id ?: localId ?: continue; store.removeRow(entityName, rid) }
                    "unknown_file", "unknown_entity", "error" -> errors.add("$label ${id ?: localId ?: ""}: ${res.status}".trim())
                    else -> errors.add("$label ${id ?: localId ?: ""}: unbekannter Status „${res.status}“")
                }
            }
        }
        return Report(sentItems = items.size, sentDeletes = deletes.size, applied = applied, conflicts = conflicts, errors = errors)
    }

    /** Nach `created`: Zeilen, deren Fremdschluessel auf die alte negative ID zeigen, auf die Server-ID umstellen. */
    private fun remapForeignKeys(parent: String, oldId: Long, newId: Long) {
        for (child in SyncEntities.stored) {
            val cols = child.fk.filterValues { it == parent }.keys
            if (cols.isEmpty()) continue
            for (r in store.rows(child.name)) {
                val hit = cols.filter { c -> (r.data[c] as? JsonPrimitive)?.content?.toLongOrNull() == oldId }
                if (hit.isEmpty()) continue
                store.rewriteData(child.name, r.id, JsonObject(r.data + hit.associateWith { JsonPrimitive(newId) }))
            }
        }
    }

    // ---- Pull ----

    fun pull(): Report {
        val result = api.pull(store.cursor, deviceId)
        return applyPull(result)
    }

    fun applyPull(result: PullResult): Report {
        var rows = 0
        var tombstones = 0
        store.applying {
            for (entity in SyncEntities.stored) {
                for (server in result.changes[entity.name] ?: emptyList()) {
                    val id = LocalStore.idOf(entity, server) ?: continue
                    if (entity.name == "settings" && id in SyncEntities.privateSettings) continue
                    val version = server.i("sync_version") ?: 1
                    val updatedAt = server.s("sync_updated_at")
                    val device = server.s("sync_device")
                    val data = LocalStore.dataOf(server)
                    val local = store.row(entity.name, id)
                    if (local == null || !local.dirty) {
                        store.putServerRow(entity.name, id, data, version, updatedAt, device)
                    } else {
                        // Lokal geaendert: je Feld gewinnt der spaetere Schreiber (Regel des Vertrags, lokal angewandt)
                        val dirtyFields = if (local.allFieldsDirty) local.data.keys else (local.dirtyFields ?: emptySet())
                        val clientWins = (local.updatedAt ?: "") >= (updatedAt ?: "")
                        val kept = if (clientWins) dirtyFields.filter { local.data[it] != data[it] }.toSet() else emptySet()
                        val merged = JsonObject(data + local.data.filterKeys { it in kept })
                        store.putRow(entity.name, id, merged, version, updatedAt, device, kept, allDirty = false, localUpdatedAt = local.updatedAt)
                    }
                    rows++
                }
            }
            for (t in result.tombstones) {
                val entityName = t.s("entity") ?: continue
                val id = t["entity_id"]?.content() ?: continue
                val deletedAt = t.s("deleted_at") ?: ""
                val local = store.row(entityName, id)
                if (local != null) {
                    if (local.dirty && (local.updatedAt ?: "") > deletedAt) {
                        // juengere lokale Aenderung ueberlebt den Tombstone: beim naechsten Push mit allen Feldern wiederherstellen
                        store.putRow(entityName, id, local.data, local.syncVersion, local.syncUpdatedAt, local.syncDevice, null, allDirty = true, localUpdatedAt = local.updatedAt)
                    } else store.removeRow(entityName, id)
                }
                store.removeTombstone(entityName, id)          // der Server kennt die Loeschung schon
                tombstones++
            }
            if (result.cursor != null) store.cursor = result.cursor
        }
        return Report(pulledRows = rows, pulledTombstones = tombstones, cursor = result.cursor)
    }

    companion object {
        private fun idElement(entity: SyncEntities.Entity, id: String): JsonElement = if (entity.pk == "id") JsonPrimitive(id.toLong()) else JsonPrimitive(id)

        private fun JsonElement.content(): String? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

        /** Bezeichnung einer Zeile fuer Meldungen: Name, Titel, Frage oder Schluessel. */
        fun title(data: JsonObject): String = data.s("name") ?: data.s("title") ?: data.s("question") ?: data.s("key") ?: data.s("id") ?: "?"
    }
}
