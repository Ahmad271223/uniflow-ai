package de.uniflow.core

import java.io.File
import java.net.URLEncoder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/**
 * Vertrag G2 gegen die lokale Ablage: jeder Push-Schritt aus fixtures/sync/cases.json wird aus dem Zustand der Ablage
 * erzeugt (die gesendete Nachricht muss der aufgezeichneten gleichen), die aufgezeichnete Antwort wird uebernommen und
 * der Zustand danach geprueft (IDs zugeordnet, Versionen, Konflikte je Feld, Loeschen, Wiederherstellen). Pull-Schritte
 * spielen die aufgezeichnete Antwort ein; der Cursor der Antwort geht in die naechste Anfrage.
 */
class SyncEngineContractTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")
    private val root = Json.parseToJsonElement(File(fixtures, "sync/cases.json").readText()) as JsonObject
    private fun str(e: kotlinx.serialization.json.JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    /** Attrappe: prueft die Anfrage und antwortet mit der aufgezeichneten Antwort. */
    private fun transport(step: JsonObject, store: LocalStore): HttpTransport = object : HttpTransport {
        override fun send(request: HttpRequest): HttpResponse {
            val expect = step["expect"] as JsonObject
            if (str(step["op"]) == "push") {
                assertEquals("POST", request.method); assertTrue(request.url.endsWith("/api/sync/push"))
                val sent = Json.parseToJsonElement(request.body!!.toString(Charsets.UTF_8)) as JsonObject
                assertEquals(str(step["device"]), str(sent["device_id"]))
                assertEquals(AnnotationMerge.canonical(step["items"]), AnnotationMerge.canonical(sent["items"]), "items: " + str(step["label"]))
                assertEquals(AnnotationMerge.canonical(step["deletes"]), AnnotationMerge.canonical(sent["deletes"]), "deletes: " + str(step["label"]))
            } else {
                assertEquals("GET", request.method); assertTrue(request.url.contains("/api/sync/changes"))
                val since = str(step["since"])
                if (since == null) assertFalse(request.url.contains("since="), "ohne Cursor kein since: ${request.url}")
                else assertTrue(request.url.contains("since=" + URLEncoder.encode(store.cursor!!, "UTF-8").replace("+", "%20")), "Cursor der letzten Antwort: ${request.url}")
                assertTrue(request.url.contains("device_id="))
            }
            return HttpResponse(200, emptyMap(), expect.toString().toByteArray())
        }
    }

    private fun engine(store: LocalStore, step: JsonObject, device: String) =
        SyncEngine(store, SyncApi(ApiClient("http://pc", transport(step, store))), device, clock = { "2026-10-27T12:00:00.000Z" })

    /** Ablage so vorbereiten, dass der Push genau die Nachricht des Schritts erzeugt. */
    private fun seed(store: LocalStore, step: JsonObject) {
        for (it in step["items"] as JsonArray) {
            it as JsonObject
            val entity = str(it["entity"])!!
            val data = it["data"] as? JsonObject ?: JsonObject(emptyMap())
            if (entity == "settings") { store.setSetting(str(it["local_id"])!!, str(data["value"])!!); continue }
            val localId = str(it["local_id"])?.toLongOrNull()
            if (localId != null) { assertEquals(localId, store.insertLocal(entity, data), "lokale ID in Reihenfolge"); continue }
            val id = str(it["id"])!!
            val base = str(it["base_version"])!!.toInt()
            store.applying {
                val cur = store.row(entity, id)
                store.putServerRow(entity, id, cur?.data ?: ApiClient.obj("id" to id.toLong()), base, cur?.syncUpdatedAt ?: "2026-10-01T00:00:00.000Z", cur?.syncDevice)
            }
            assertTrue(store.update(entity, id, data, str(it["updated_at"])!!))
        }
        for (d in step["deletes"] as JsonArray) {
            d as JsonObject
            val entity = str(d["entity"])!!; val id = str(d["id"])!!
            if (store.row(entity, id) == null) store.applying { store.putServerRow(entity, id, ApiClient.obj("id" to id.toLong()), 1, "2026-10-01T00:00:00.000Z", null) }
            store.delete(entity, id, str(d["deleted_at"])!!)
        }
    }

    private fun checkAfterPush(store: LocalStore, step: JsonObject, label: String) {
        val expect = step["expect"] as JsonObject
        val deletes = (step["deletes"] as JsonArray).map { (it as JsonObject).let { d -> str(d["entity"])!! to str(d["id"])!! } }.toSet()
        for (r in expect["results"] as JsonArray) {
            r as JsonObject
            val entity = str(r["entity"])!!; val status = str(r["status"])!!
            val id = str(r["id"]); val localId = str(r["local_id"])
            val version = str(r["version"])?.toInt()
            val isDelete = id != null && (entity to id) in deletes
            when {
                isDelete && status == "deleted" -> { assertNull(store.row(entity, id!!), "$label: $entity $id weg"); assertTrue(store.tombstones().none { it.entity == entity && it.id == id }, "$label: Tombstone erledigt") }
                isDelete && status == "edit_wins" -> {
                    assertTrue(store.tombstones().none { it.entity == entity && it.id == id }, "$label: Loeschen verworfen")
                    val server = (expect["conflicts"] as JsonArray).map { it as JsonObject }.first { str(it["entity"]) == entity && str(it["id"]) == id }["server"] as JsonObject
                    val row = store.row(entity, id!!)!!
                    assertEquals(LocalStore.dataOf(server), row.data, "$label: Serverzeile zurueck"); assertFalse(row.dirty)
                }
                status == "created" -> {
                    assertNull(store.row(entity, localId!!), "$label: lokale ID $localId ersetzt")
                    val row = store.row(entity, id!!)!!
                    assertFalse(row.dirty); assertEquals(version, row.syncVersion)
                    assertNull(row.data["id"], "$label: neue Zeile traegt keine fremde ID in den Daten")
                }
                status == "error" -> { val row = store.row(entity, localId!!)!!; assertTrue(row.dirty, "$label: Fehlerzeile bleibt dirty") }
                status == "applied" || status == "resurrected" -> {
                    val row = store.row(entity, id!!)!!
                    assertFalse(row.dirty, "$label: $entity $id synchron"); assertEquals(version, row.syncVersion)
                    if (entity == "settings") assertEquals(str(((step["items"] as JsonArray).map { it as JsonObject }.first { str(it["local_id"]) == id }["data"] as JsonObject)["value"]), store.setting(id))
                }
                status == "conflict" -> {
                    val c = (expect["conflicts"] as JsonArray).map { it as JsonObject }.first { str(it["entity"]) == entity && str(it["id"]) == id }
                    val server = LocalStore.dataOf(c["server"] as JsonObject)
                    val client = c["client"] as JsonObject
                    val won = (r["client_won"] as JsonArray).map { it.jsonPrimitive.content }
                    val row = store.row(entity, id!!)!!
                    assertEquals(JsonObject(server + client.filterKeys { it in won }), row.data, "$label: Serverstand + gewonnene Felder")
                    assertFalse(row.dirty); assertEquals(version, row.syncVersion)
                }
                status == "deleted" -> assertNull(store.row(entity, id!!), "$label: Tombstone war neuer, Zeile weg")
                status == "ignored" -> assertNull(store.row(entity, id!!), "$label: private Einstellung bleibt nicht in der Ablage")
                else -> error("$label: unerwarteter Status $status")
            }
        }
        for (m in expect["mapping"] as JsonArray) {
            m as JsonObject
            val child = store.row(str(m["entity"])!!, str(m["id"])!!)!!
            // Fremdschluessel auf neue Zeilen zeigen nach der Zuordnung auf Server-IDs
            for ((col, _) in SyncEntities.byName(child.entity)!!.fk) {
                val v = str(child.data[col])?.toLongOrNull() ?: continue
                assertTrue(v > 0, "$label: ${child.entity}.$col zeigt auf Server-ID, nicht auf $v")
            }
        }
        // Nach dem Push bleibt nur dirty, was der Server abgewiesen hat (error)
        val rejected = (expect["results"] as JsonArray).map { it as JsonObject }.filter { str(it["status"]) == "error" }.map { str(it["entity"])!! to str(it["local_id"])!! }.toSet()
        assertEquals(rejected, store.dirtyRows().map { it.entity to it.id }.toSet(), label)
    }

    private fun checkAfterPull(store: LocalStore, step: JsonObject, label: String) {
        val expect = step["expect"] as JsonObject
        assertEquals(str(expect["cursor"]), store.cursor, "$label: Cursor gemerkt")
        for ((entityName, rows) in expect["changes"] as JsonObject) {
            val entity = SyncEntities.byName(entityName)!!
            if (entityName == "annotations") continue
            for (row in rows as JsonArray) {
                row as JsonObject
                val id = LocalStore.idOf(entity, row)!!
                if (entityName == "settings") assertTrue(id !in SyncEntities.privateSettings, "$label: private Einstellung kommt nie")
                val local = store.row(entityName, id) ?: error("$label: $entityName $id fehlt nach dem Pull")
                assertEquals(LocalStore.dataOf(row), local.data, "$label: $entityName $id")
                assertEquals(row.i("sync_version"), local.syncVersion); assertFalse(local.dirty)
            }
        }
        for (t in expect["tombstones"] as JsonArray) { t as JsonObject; assertNull(store.row(str(t["entity"])!!, str(t["entity_id"])!!), "$label: Tombstone geloescht") }
        assertNull(store.row("settings", "lan_pin")); assertNull(store.row("settings", "university"))
    }

    @Test
    fun everyCaseRunsAgainstTheLocalStore() {
        var pushes = 0; var pulls = 0; var skipped = 0
        for (c in root["cases"] as JsonArray) {
            c as JsonObject
            val name = str(c["name"])!!
            val store = LocalStore(JdbcSqlDb.memory(), "test-device", clock = { "2026-10-27T12:00:00.000Z" })
            for (st in c["steps"] as JsonArray) {
                st as JsonObject
                val label = "$name / ${str(st["label"])}"
                if (str(st["op"]) == "push") {
                    if ((st["items"] as JsonArray).any { str((it as JsonObject)["entity"]) == "annotations" }) { skipped++; continue }   // Notizen: AnnotationStore, nicht die Ablage
                    seed(store, st)
                    val report = engine(store, st, str(st["device"])!!).push()
                    assertEquals((st["items"] as JsonArray).size, report.sentItems, label); assertEquals((st["deletes"] as JsonArray).size, report.sentDeletes, label)
                    val expectedErrors = ((st["expect"] as JsonObject)["results"] as JsonArray).count { str((it as JsonObject)["status"]) in setOf("error", "unknown_entity", "unknown_file") }
                    assertEquals(expectedErrors, report.errors.size, "$label: ${report.errors}")
                    // Konflikte: je Feld entschieden (conflict), Loeschen verworfen (edit_wins) oder Tombstone war neuer (deleted mit deleted_at)
                    val expectedConflicts = ((st["expect"] as JsonObject)["results"] as JsonArray).map { it as JsonObject }
                        .count { str(it["status"]) in setOf("conflict", "edit_wins") || (str(it["status"]) == "deleted" && str(it["deleted_at"]) != null) }
                    assertEquals(expectedConflicts, report.conflicts.size, "$label: ${report.conflicts}")
                    checkAfterPush(store, st, label)
                    pushes++
                } else {
                    val report = engine(store, st, "test-device").pull()
                    val expect = st["expect"] as JsonObject
                    // gezaehlt werden die Zeilen der Ablage-Entitaeten (Notizen laufen nicht ueber die Ablage)
                    assertEquals((expect["changes"] as JsonObject).filterKeys { k -> SyncEntities.stored.any { it.name == k } }.values.sumOf { (it as JsonArray).size }, report.pulledRows, label)
                    checkAfterPull(store, st, label)
                    pulls++
                }
            }
        }
        assertTrue(pushes >= 10 && pulls >= 5, "pushes=$pushes pulls=$pulls")
        assertEquals(4, skipped, "die vier Notiz-Schritte laufen nicht ueber die Ablage")
    }

    @Test
    fun syncIsPushThenPullAndIdleWithoutChanges() {
        val store = LocalStore(JdbcSqlDb.memory(), "test-device", clock = { "2026-10-27T12:00:00.000Z" })
        val calls = ArrayList<String>()
        val api = SyncApi(ApiClient("http://pc", object : HttpTransport {
            override fun send(request: HttpRequest): HttpResponse {
                calls.add(request.method)
                return HttpResponse(200, emptyMap(), (if (request.method == "POST") """{"results":[],"mapping":[],"conflicts":[],"server_time":"t"}"""
                                                        else """{"cursor":"c1","changes":{},"tombstones":[]}""").toByteArray())
            }
        }))
        val r = SyncEngine(store, api, "test-device", clock = { "2026-10-27T12:00:00.000Z" }).sync()
        assertEquals(listOf("GET"), calls, "nichts zu senden: kein Push")
        assertEquals("c1", store.cursor); assertEquals("2026-10-27T12:00:00.000Z", store.lastSyncAt); assertEquals("Alles aktuell", r.summary())
        store.insertLocal("flashcards", ApiClient.obj("question" to "Q"))
        calls.clear()
        SyncEngine(store, api, "test-device").sync()
        assertEquals(listOf("POST", "GET"), calls, "erst senden, dann holen")
    }

    @Test
    fun pullAppliesTheFieldRuleToDirtyRows() {
        val store = LocalStore(JdbcSqlDb.memory(), "test-device")
        store.applying { store.putServerRow("modules", "1", ApiClient.obj("id" to 1, "name" to "Physik", "priority" to 2, "color" to "#111111"), 1, "2026-10-01T00:00:00.000Z", null) }
        store.update("modules", "1", ApiClient.obj("name" to "Physik 1"), "2099-01-01T00:00:00.000Z")
        val later = SyncApi.parsePull(Json.parseToJsonElement("""{"cursor":"c2","changes":{"modules":[{"id":1,"name":"Physik I","priority":3,"color":"#111111","sync_version":2,"sync_updated_at":"2026-10-26T00:00:00.000Z","sync_device":"mac-1"}]},"tombstones":[]}"""))
        SyncEngine(store, SyncApi(ApiClient("http://pc", object : HttpTransport { override fun send(request: HttpRequest) = error("kein Netz noetig") })), "test-device").applyPull(later)
        var row = store.row("modules", "1")!!
        assertEquals("Physik 1", row.data.s("name"), "dieses Geraet war spaeter: Name bleibt")
        assertEquals(3, row.data.i("priority"), "nicht geaendertes Feld kommt vom Server")
        assertTrue(row.dirty); assertEquals(setOf("name"), row.dirtyFields); assertEquals(2, row.syncVersion, "Basis ist jetzt die Serverversion")

        // Aelteres Geraet: Server gewinnt, nichts bleibt zu senden
        store.update("modules", "1", ApiClient.obj("color" to "#222222"), "2000-01-01T00:00:00.000Z")
        store.applying { store.putRow("modules", "1", JsonObject(row.data + ApiClient.obj("color" to "#222222")), 2, row.syncUpdatedAt, row.syncDevice, setOf("color"), false, "2000-01-01T00:00:00.000Z") }
        val newer = SyncApi.parsePull(Json.parseToJsonElement("""{"cursor":"c3","changes":{"modules":[{"id":1,"name":"Physik II","priority":3,"color":"#333333","sync_version":3,"sync_updated_at":"2026-10-27T00:00:00.000Z","sync_device":"mac-1"}]},"tombstones":[]}"""))
        SyncEngine(store, SyncApi(ApiClient("http://pc", object : HttpTransport { override fun send(request: HttpRequest) = error("kein Netz noetig") })), "test-device").applyPull(newer)
        row = store.row("modules", "1")!!
        assertEquals("#333333", row.data.s("color")); assertEquals("Physik II", row.data.s("name")); assertFalse(row.dirty); assertEquals(3, row.syncVersion)

        // Tombstone gegen juengere lokale Aenderung: Zeile bleibt und geht beim naechsten Push mit allen Feldern (resurrected)
        store.update("modules", "1", ApiClient.obj("name" to "Physik III"), "2099-06-01T00:00:00.000Z")
        val tomb = SyncApi.parsePull(Json.parseToJsonElement("""{"cursor":"c4","changes":{},"tombstones":[{"entity":"modules","entity_id":"1","deleted_at":"2026-10-28T00:00:00.000Z","device":"mac-1"}]}"""))
        val eng = SyncEngine(store, SyncApi(ApiClient("http://pc", object : HttpTransport { override fun send(request: HttpRequest) = error("kein Netz noetig") })), "test-device")
        eng.applyPull(tomb)
        row = store.row("modules", "1")!!
        assertTrue(row.dirty && row.allFieldsDirty)
        val (items, _) = eng.buildPush()
        assertEquals(1, items.size); assertEquals(JsonPrimitive(1L), items[0].id); assertEquals(3, items[0].baseVersion)
        assertEquals(setOf("name", "priority", "color"), items[0].data.keys, "alle Felder ohne id")
        // Tombstone gegen unveraenderte Zeile: weg, auch ein eigener Tombstone derselben Zeile ist erledigt
        store.applying { store.putServerRow("modules", "1", ApiClient.obj("id" to 1, "name" to "x"), 3, "2026-10-27T00:00:00.000Z", null) }
        eng.applyPull(tomb)
        assertNull(store.row("modules", "1")); assertEquals("c4", store.cursor)
    }

    @Test
    fun createdRowsRemapForeignKeysOfTheirChildren() {
        val store = LocalStore(JdbcSqlDb.memory(), "test-device")
        store.insertLocal("modules", ApiClient.obj("name" to "Mathe"))
        store.insertLocal("study_packages", ApiClient.obj("date" to "2026-11-02", "module_id" to -1, "title" to "Woche 3"))
        store.insertLocal("study_tasks", ApiClient.obj("package_id" to -2, "title" to "Blatt 3"))
        store.applying { store.putServerRow("study_packages", "40", ApiClient.obj("id" to 40, "module_id" to 3, "title" to "alt"), 1, "t", null) }
        store.update("study_packages", "40", ApiClient.obj("module_id" to -1))                 // bestehendes Paket an das neue Modul gehaengt
        val eng = SyncEngine(store, SyncApi(ApiClient("http://pc", object : HttpTransport { override fun send(request: HttpRequest) = error("kein Netz noetig") })), "test-device")
        val (items, deletes) = eng.buildPush()
        assertEquals(listOf("modules", "study_packages", "study_packages", "study_tasks"), items.map { it.entity }, "Eltern vor Kindern")
        assertTrue(deletes.isEmpty())
        val result = SyncApi.parsePush(Json.parseToJsonElement("""{"results":[
            {"entity":"modules","local_id":-1,"id":7,"status":"created","version":1},
            {"entity":"study_packages","local_id":-2,"id":9,"status":"created","version":1},
            {"entity":"study_packages","id":40,"status":"applied","version":2,"client_won":["module_id"]},
            {"entity":"study_tasks","local_id":-3,"id":11,"status":"created","version":1}],
            "mapping":[{"entity":"modules","local_id":-1,"id":7},{"entity":"study_packages","local_id":-2,"id":9},{"entity":"study_tasks","local_id":-3,"id":11}],
            "conflicts":[],"server_time":"2026-10-27T12:00:00.000Z"}"""))
        val report = eng.applyPush(items, deletes, result)
        assertEquals(4, report.applied); assertTrue(report.errors.isEmpty() && report.conflicts.isEmpty())
        assertEquals(7, store.row("study_packages", "9")!!.data.i("module_id"))
        assertEquals(7, store.row("study_packages", "40")!!.data.i("module_id"))
        assertEquals(9, store.row("study_tasks", "11")!!.data.i("package_id"))
        assertEquals(0, store.pendingCount())
        assertNotNull(store.row("modules", "7")); assertNull(store.row("modules", "-1"))
        assertEquals("4 Änderungen gesendet", report.summary())
    }
}
