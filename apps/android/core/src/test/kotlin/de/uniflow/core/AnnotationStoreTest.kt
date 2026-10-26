package de.uniflow.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive

/** Speichern mit base_version; bei 409 Zusammenfuehrung mit dem Serverstand und erneutes Senden (API.md, Regeln 1-3). */
class AnnotationStoreTest {

    /** Attrappe des Servers: haelt Version und Dokument, antwortet wie app/server.py put_annotations. */
    private class FakeServer : HttpTransport {
        var version = 0
        var doc: JsonObject? = null
        val puts = ArrayList<Int>()
        override fun send(request: HttpRequest): HttpResponse {
            if (request.method == "GET") {
                val body = if (doc == null) """{"data":{"version":2,"pages":{},"zoom":1.2},"updated_at":null,"version":0}"""
                else """{"data":${doc},"updated_at":"t","version":$version}"""
                return HttpResponse(200, emptyMap(), body.toByteArray())
            }
            val base = Regex("base_version=(\\d+)").find(request.url)!!.groupValues[1].toInt()
            puts += base
            if (doc != null && base != version) {
                return HttpResponse(409, emptyMap(), """{"detail":"Konflikt","version":$version,"data":${doc}}""".toByteArray())
            }
            doc = Json.parseToJsonElement(request.body!!.toString(Charsets.UTF_8)) as JsonObject
            version += 1
            return HttpResponse(200, emptyMap(), """{"ok":true,"version":$version}""".toByteArray())
        }
    }

    private fun strokeDoc(vararg ids: String, page: String = "p1"): JsonObject {
        var d = AnnotationDocument.empty()
        for (id in ids) d = AnnotationDocument.addObject(d, page, AnnotationDocument.stroke(listOf(1f, 2f, 3f, 4f), id = id))
        return d
    }

    @Test
    fun firstSaveAndPlainUpdate() {
        val server = FakeServer()
        val store = AnnotationStore(ApiClient("http://pc", server))
        val loaded = store.load("f1")
        assertEquals(0, loaded.version)
        val s1 = store.save("f1", strokeDoc("a1"), null, 0)
        assertEquals(1, s1.version); assertEquals(0, s1.mergedConflicts); assertEquals(1, s1.attempts)
        val s2 = store.save("f1", strokeDoc("a1", "a2"), strokeDoc("a1"), 1)
        assertEquals(2, s2.version)
        assertEquals(listOf(0, 1), server.puts)
    }

    @Test
    fun conflictIsMergedAndResent() {
        val server = FakeServer()
        val store = AnnotationStore(ApiClient("http://pc", server))
        val base = strokeDoc("a1")
        store.save("f1", base, null, 0)                                   // Version 1
        server.doc = strokeDoc("a1", "ipad1"); server.version = 2        // anderes Geraet hat gespeichert
        val local = AnnotationDocument.addObject(base, "p1", AnnotationDocument.stroke(listOf(9f, 9f, 8f, 8f), id = "android1"))
        val saved = store.save("f1", local, base, 1)
        assertEquals(3, saved.version)
        assertEquals(2, saved.attempts)
        val ids = AnnotationDocument.objects(server.doc!!, "p1").map { AnnotationMerge.objectId(it) }
        assertEquals(listOf("a1", "ipad1", "android1"), ids, "beide Striche bleiben, Reihenfolge wie beim Web-Editor")
        assertEquals(listOf(0, 1, 2), server.puts)
    }

    @Test
    fun givesUpAfterRepeatedConflicts() {
        val always409 = object : HttpTransport {
            override fun send(request: HttpRequest) = HttpResponse(409, emptyMap(), """{"version":9,"data":{"version":2,"pages":{}}}""".toByteArray())
        }
        val e = assertFailsWith<ApiError> { AnnotationStore(ApiClient("http://pc", always409)).save("f1", strokeDoc("x"), null, 0, maxAttempts = 2) }
        assertEquals(409, e.status)
        assertTrue(e.message!!.contains("2 Versuchen"))
    }

    @Test
    fun unknownFieldsOfTheServerDocumentArePreserved() {
        val server = FakeServer()
        // Server: eigenes Dokumentfeld, Seitenfeld und eine iPad-Zeichnung v2 (bleibt laut Regel auch bei anderen Objekten)
        server.doc = Json.parseToJsonElement("""{"version":2,"pages":{"p1":{"objects":[],"notiz":"Seite 1",
            "pkdrawing":{"data":"AAAA","format":"pkdrawing-v2","strokeIds":[],"strokeSigs":[]}}},"fremd":1}""") as JsonObject
        server.version = 1
        val store = AnnotationStore(ApiClient("http://pc", server))
        val saved = store.save("f1", strokeDoc("android1"), null, 0)
        assertEquals(2, saved.version)
        assertEquals(JsonPrimitive(1), server.doc!!["fremd"])
        val p1 = AnnotationDocument.pages(server.doc!!)["p1"] as JsonObject
        assertEquals("Seite 1", p1["notiz"]!!.jsonPrimitive.content)
        assertEquals("AAAA", (p1["pkdrawing"] as JsonObject)["data"]!!.jsonPrimitive.content)
        assertEquals(listOf("android1"), AnnotationDocument.objects(server.doc!!, "p1").map { AnnotationMerge.objectId(it) })
    }
}
