package de.uniflow.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/** Vertrag G2: die Faelle aus fixtures/sync/cases.json, gespielt gegen eine Attrappe mit den aufgezeichneten Antworten. */
class SyncContractTest {
    private val fixtures = File(System.getProperty("uniflow.fixtures") ?: "../../../packages/shared-contracts/fixtures")
    private val cases = Json.parseToJsonElement(File(fixtures, "sync/cases.json").readText()) as JsonObject

    @Test
    fun rulesAreKnown() {
        val rules = cases["rules"] as JsonObject
        val entities = (rules["entities"] as JsonArray).map { it.jsonPrimitive.content }
        assertEquals(listOf("modules", "folders", "course_events", "event_exceptions", "study_packages", "study_tasks", "flashcards", "settings", "annotations"), entities)
        assertEquals(listOf("sync_version", "sync_updated_at", "sync_device"), (rules["columns"] as JsonArray).map { it.jsonPrimitive.content })
    }

    @Test
    fun everyStepParsesAsRecorded() {
        var steps = 0
        for (c in cases["cases"] as JsonArray) {
            c as JsonObject
            for (st in c["steps"] as JsonArray) {
                st as JsonObject
                val expect = st["expect"] as JsonObject
                val transport = object : HttpTransport {
                    override fun send(request: HttpRequest): HttpResponse {
                        if (st["op"]!!.jsonPrimitive.content == "push") {
                            assertEquals("POST", request.method)
                            val sent = Json.parseToJsonElement(request.body!!.toString(Charsets.UTF_8)) as JsonObject
                            assertEquals(AnnotationMerge.canonical(st["items"]), AnnotationMerge.canonical(sent["items"]), c["name"]!!.jsonPrimitive.content)
                            assertEquals(AnnotationMerge.canonical(st["deletes"]), AnnotationMerge.canonical(sent["deletes"]))
                            assertEquals(st["device"]!!.jsonPrimitive.content, sent["device_id"]!!.jsonPrimitive.content)
                        } else {
                            assertEquals("GET", request.method)
                            assertTrue(request.url.contains("/api/sync/changes"))
                        }
                        return HttpResponse(200, emptyMap(), expect.toString().toByteArray())
                    }
                }
                val api = SyncApi(ApiClient("http://pc", transport))
                if (st["op"]!!.jsonPrimitive.content == "push") {
                    val items = (st["items"] as JsonArray).map { it as JsonObject
                        PushItem(it["entity"]!!.jsonPrimitive.content, it["id"], it["local_id"], (it["base_version"] as? JsonPrimitive)?.content?.toInt(),
                            (it["updated_at"] as? JsonPrimitive)?.content, it["data"] as? JsonObject ?: JsonObject(emptyMap()))
                    }
                    val deletes = (st["deletes"] as JsonArray).map { it as JsonObject
                        PushDelete(it["entity"]!!.jsonPrimitive.content, it["id"]!!, (it["deleted_at"] as? JsonPrimitive)?.content)
                    }
                    val r = api.push(st["device"]!!.jsonPrimitive.content, items, deletes)
                    val expStatuses = (expect["results"] as JsonArray).map { (it as JsonObject)["status"]!!.jsonPrimitive.content }
                    assertEquals(expStatuses, r.results.map { it.status })
                    for (m in expect["mapping"] as JsonArray) {
                        m as JsonObject
                        assertEquals(m["id"]!!.jsonPrimitive.content.toLong(), r.serverId(m["entity"]!!.jsonPrimitive.content, m["local_id"]!!.jsonPrimitive.content.toLong()))
                    }
                    assertEquals((expect["conflicts"] as JsonArray).size, r.conflicts.size)
                    r.results.filter { it.status == "conflict" && it.entity == "annotations" }.forEach { assertTrue(it.serverData != null, "Konflikt bei Notizen bringt den Serverstand mit") }
                } else {
                    val since = (st["since"] as? JsonPrimitive)?.takeIf { !it.isString || it.content != "null" }?.content
                    val r = api.pull(since?.let { "2026-10-26T00:00:00.000Z" })
                    val expChanges = expect["changes"] as JsonObject
                    assertEquals(expChanges.keys, r.changes.keys)
                    for ((k, v) in expChanges) assertEquals((v as JsonArray).size, r.changes[k]!!.size, k)
                    assertEquals((expect["tombstones"] as JsonArray).size, r.tombstones.size)
                    assertEquals((expect["cursor"] as? JsonPrimitive)?.content, r.cursor)
                }
                steps++
            }
        }
        assertTrue(steps >= 15)
    }
}
