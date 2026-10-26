package de.uniflow.core

import kotlin.random.Random
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Gemeinsames Notizformat (packages/shared-contracts/annotations.schema.json, Beispiel fixtures/documents/web-editor.json).
 * Das Dokument bleibt ein JsonObject: unbekannte Felder (auch pkdrawing des iPads) werden unveraendert weitergegeben.
 * Koordinaten der Objekte sind PDF-Punkte der Seite (A4 = 595 x 842); die App rechnet Bildschirmpixel dorthin um.
 */
object AnnotationDocument {

    fun empty(): JsonObject = buildJsonObject { put("version", 2); put("pages", JsonObject(emptyMap())); put("zoom", 1.2) }

    fun pages(doc: JsonObject): JsonObject = (doc["pages"] as? JsonObject) ?: JsonObject(emptyMap())

    fun pageOrder(doc: JsonObject): List<JsonObject> = (doc["pageOrder"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

    /** Schluessel der Seite zu einer PDF-Seite (1-basiert): aus pageOrder, sonst die Konvention "p<index>". */
    fun keyForPdfPage(doc: JsonObject, index: Int): String {
        val entry = pageOrder(doc).firstOrNull { it.s("type") == "pdf" && it.i("index") == index }
        return entry?.s("key") ?: "p$index"
    }

    /** Seiten in Anzeigereihenfolge: (Schluessel, PDF-Seite oder null fuer eingefuegte Seiten). */
    fun orderedPages(doc: JsonObject, pdfPageCount: Int): List<Pair<String, Int?>> {
        val order = pageOrder(doc)
        if (order.isEmpty()) return (1..pdfPageCount).map { "p$it" to it }
        val deleted = (doc["deletedPages"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }?.toSet() ?: emptySet()
        val out = order.filter { it.s("key") !in deleted }.map { (it.s("key") ?: "") to it.i("index").takeIf { _ -> it.s("type") == "pdf" } }
        val known = out.mapNotNull { it.second }.toSet()
        return out + (1..pdfPageCount).filter { it !in known }.map { "p$it" to it }     // Seiten, die pageOrder nicht kennt
    }

    fun objects(doc: JsonObject, key: String): List<JsonElement> =
        ((pages(doc)[key] as? JsonObject)?.get("objects") as? JsonArray)?.toList() ?: emptyList()

    /** Neue Objektliste einer Seite; andere Felder der Seite und des Dokuments bleiben erhalten. */
    fun withObjects(doc: JsonObject, key: String, objects: List<JsonElement>): JsonObject {
        val page = (pages(doc)[key] as? JsonObject) ?: JsonObject(emptyMap())
        val newPage = JsonObject(page.toMutableMap().apply { this["objects"] = JsonArray(objects) })
        val newPages = JsonObject(pages(doc).toMutableMap().apply { this[key] = newPage })
        return JsonObject(doc.toMutableMap().apply { this["pages"] = newPages })
    }

    fun addObject(doc: JsonObject, key: String, obj: JsonObject): JsonObject = withObjects(doc, key, objects(doc, key) + obj)

    fun removeObject(doc: JsonObject, key: String, id: String): JsonObject =
        withObjects(doc, key, objects(doc, key).filter { AnnotationMerge.objectId(it) != id })

    /** Strich in der Form des Web-Editors (Konva): Punkte abwechselnd x, y in PDF-Punkten. */
    fun stroke(points: List<Float>, tool: String = "pen", color: String = "#1f2937", width: Float = 2f, opacity: Float = 1f,
               widths: List<Float>? = null, id: String = newId()): JsonObject = buildJsonObject {
        put("id", id); put("type", "stroke"); put("tool", tool); put("color", color); put("width", width)
        if (widths != null) put("widths", JsonArray(widths.map { JsonPrimitive(round2(it)) }))
        put("opacity", opacity); put("points", JsonArray(points.map { JsonPrimitive(round2(it)) }))
        put("x", 0); put("y", 0); put("rotation", 0); put("scaleX", 1); put("scaleY", 1)
    }

    fun strokePoints(o: JsonElement): List<Float> = ((o as? JsonObject)?.get("points") as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content?.toFloatOrNull() } ?: emptyList()

    fun newId(): String = "a" + List(12) { HEX[Random.nextInt(16)] }.joinToString("")

    private const val HEX = "0123456789abcdef"
    private fun round2(f: Float): Double = Math.round(f * 100.0) / 100.0

    /** Vollstaendige Zusammenfuehrung zweier Dokumente auf Basis des letzten bestaetigten Standes (je Seite AnnotationMerge). */
    fun merge(base: JsonObject?, local: JsonObject, server: JsonObject): Pair<JsonObject, Int> {
        val keys = LinkedHashSet<String>()
        keys += pages(server).keys; keys += pages(local).keys; if (base != null) keys += pages(base).keys
        val mergedPages = LinkedHashMap<String, JsonElement>()
        var conflicts = 0
        for (k in keys) {
            val r = AnnotationMerge.mergePage(base?.let { pages(it)[k] }, pages(local)[k], pages(server)[k])
            if (r.page != null) mergedPages[k] = r.page
            conflicts += r.conflicts
        }
        // Dokumentfelder: Serverstand als Grundlage (unbekannte Felder bleiben), eigene Anzeigefelder darueber
        val out = server.toMutableMap()
        out["pages"] = JsonObject(mergedPages)
        local["zoom"]?.let { out["zoom"] = it }
        if (base != null && !sameElement(local["pageOrder"], base["pageOrder"]) && local["pageOrder"] != null) out["pageOrder"] = local["pageOrder"]!!
        return JsonObject(out) to conflicts
    }

    private fun sameElement(a: JsonElement?, b: JsonElement?) = AnnotationMerge.canonical(a ?: JsonNull) == AnnotationMerge.canonical(b ?: JsonNull)
}
