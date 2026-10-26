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
        val deleted = (doc["deletedPages"] as? JsonArray)?.mapNotNull { keyOf(it) }?.toSet() ?: emptySet()   // Web: {entry: {key}}, sonst String
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

    /** Ergebnis der Dokument-Zusammenfuehrung; orderConflict = beide Geraete haben die Seiten verschieden umsortiert (anzeigen!). */
    data class MergeResult(val doc: JsonObject, val conflicts: Int, val orderConflict: Boolean)

    /** Ergebnis von mergePageOrder: Schluessel in Reihenfolge und ob die Reihenfolge ein Konflikt war. */
    data class OrderResult(val keys: List<String>, val conflict: Boolean)

    /**
     * Vollstaendige Zusammenfuehrung zweier Dokumente auf Basis des letzten bestaetigten Standes, wie merge.js
     * mergeDocument (gemeinsame Faelle: documentCases in fixtures/merge/cases.json): je Seite AnnotationMerge.mergePage;
     * Seitenreihenfolge mit mergePageOrder; Papierkorb beider Seiten vereinigt; Eintraege und Wurzelfelder (note,
     * bookmarks, outline, zoom, unbekannte) nach der Feldregel: nur hier geaendert -> hier, nur dort -> dort,
     * beidseitig verschieden -> hier (Konflikt).
     */
    fun merge(base: JsonObject?, local: JsonObject, server: JsonObject): Pair<JsonObject, Int> =
        mergeDetailed(base, local, server).let { it.doc to it.conflicts }

    fun mergeDetailed(base: JsonObject?, local: JsonObject, server: JsonObject): MergeResult {
        val keys = LinkedHashSet<String>()
        keys += pages(server).keys; keys += pages(local).keys; if (base != null) keys += pages(base).keys
        val mergedPages = LinkedHashMap<String, JsonElement>()
        var conflicts = 0
        for (k in keys) {
            val r = AnnotationMerge.mergePage(base?.let { pages(it)[k] }, pages(local)[k], pages(server)[k])
            if (r.page != null) mergedPages[k] = r.page
            conflicts += r.conflicts
        }
        val order = mergePageOrder(base, local, server)
        if (order.conflict) conflicts++
        val pageOrder = order.keys.map { k ->
            val lE = entryOf(local, k)
            val sE = entryOf(server, k)
            if (lE != null && sE != null) {
                val f = mergeField(entryOf(base, k), lE, sE); conflicts += f.second; f.first ?: lE
            } else (lE ?: sE)!!
        }
        for (k in order.keys) if (k !in mergedPages) {
            mergedPages[k] = pages(local)[k] ?: pages(server)[k] ?: buildJsonObject { put("objects", JsonArray(emptyList())) }
        }
        val out = LinkedHashMap<String, JsonElement>()
        for (k in server.keys + local.keys + (base?.keys ?: emptySet())) {        // Serverreihenfolge zuerst, unbekannte Felder bleiben
            if (k == "pages" || k == "pageOrder" || k == "deletedPages") continue
            val f = mergeField(base?.get(k), local[k], server[k])
            conflicts += f.second
            f.first?.let { out[k] = it }
        }
        out["pages"] = JsonObject(mergedPages)
        out["pageOrder"] = JsonArray(pageOrder)
        out["deletedPages"] = JsonArray(mergeTrash(local, server, order.keys.toSet()))
        return MergeResult(JsonObject(out), conflicts, order.conflict)
    }

    /**
     * Seitenreihenfolge (nur Schluessel), Loeschen gegen Aenderung wie mergePage: nur auf einer Seite geaendert -> diese;
     * beide geaendert, auf den gemeinsamen Seiten aber gleich -> vertraeglich (eingefuegte Seiten hinter ihrem Vorgaenger,
     * Serverseiten zuerst); beide verschieden umsortiert -> dieses Geraet mit Konflikt.
     */
    fun mergePageOrder(base: JsonObject?, local: JsonObject?, server: JsonObject?): OrderResult {
        val b = orderKeys(base); val l = orderKeys(local); val s = orderKeys(server)
        val bSet = b.toSet(); val lSet = l.toSet(); val sSet = s.toSet()
        fun dropped(k: String): Boolean = when {
            k in lSet && k in sSet -> false
            k !in bSet -> false                                                          // neu auf einer Seite: bleibt
            k !in lSet -> sameElement(pageOf(server, k), pageOf(base, k))                // hier geloescht: weg, wenn dort unveraendert
            else -> sameElement(pageOf(local, k), pageOf(base, k))                       // dort geloescht: weg, wenn hier unveraendert
        }
        val lk = l.filter { !dropped(it) }; val sk = s.filter { !dropped(it) }; val bk = b.filter { !dropped(it) }
        val common = lk.filter { it in sk }.toSet()
        val oL = lk.filter { it in common }; val oS = sk.filter { it in common }; val oB = bk.filter { it in common }
        val primary: List<String>; val secondary: List<String>; var conflict = false
        when {
            oL == oS || oS == oB -> { primary = lk; secondary = sk }                     // vertraeglich oder nur hier umsortiert
            oL == oB -> { primary = sk; secondary = lk }                                 // nur dort umsortiert
            else -> { primary = lk; secondary = sk; conflict = true }                    // beide verschieden: dieses Geraet, Konflikt
        }
        val out = primary.toMutableList()
        for (i in secondary.indices) {
            val k = secondary[i]
            if (k in out) continue
            var at = 0                                                                   // hinter dem naechsten Vorgaenger, der schon drin ist
            for (j in i - 1 downTo 0) { val p = out.indexOf(secondary[j]); if (p >= 0) { at = p + 1; break } }
            out.add(at, k)
        }
        return OrderResult(out, conflict)
    }

    /** Papierkorb beider Seiten: je Schluessel einmal (hier zuerst), ohne Seiten, die in der Reihenfolge stehen. */
    fun mergeTrash(local: JsonObject?, server: JsonObject?, inOrder: Set<String>): List<JsonElement> {
        val seen = HashSet<String>(); val out = ArrayList<JsonElement>()
        for (e in trashEntries(local) + trashEntries(server)) {
            val k = keyOf(e) ?: continue
            if (k in seen || k in inOrder) continue
            seen += k; out += e
        }
        return out
    }

    /** Feldregel wie in merge.js mergePage: nur hier geaendert -> hier, nur dort -> dort, beide verschieden -> hier + Konflikt. */
    fun mergeField(bv: JsonElement?, lv: JsonElement?, sv: JsonElement?): Pair<JsonElement?, Int> = when {
        sameElement(lv, bv) -> sv to 0
        sameElement(sv, bv) || sameElement(sv, lv) -> lv to 0
        else -> lv to 1
    }

    /** Schluessel eines pageOrder-Eintrags, eines Papierkorb-Eintrags ({entry: {key}} wie im Web) oder eines Strings. */
    fun keyOf(e: JsonElement?): String? = when (e) {
        is JsonObject -> (e["key"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: ((e["entry"] as? JsonObject)?.get("key") as? JsonPrimitive)?.takeIf { it.isString }?.content
        is JsonPrimitive -> e.takeIf { it.isString }?.content
        else -> null
    }

    private fun orderKeys(doc: JsonObject?): List<String> = (doc?.get("pageOrder") as? JsonArray)?.mapNotNull { keyOf(it) } ?: emptyList()
    private fun trashEntries(doc: JsonObject?): List<JsonElement> = (doc?.get("deletedPages") as? JsonArray)?.toList() ?: emptyList()
    private fun pageOf(doc: JsonObject?, k: String): JsonElement? = doc?.let { pages(it)[k] }
    private fun entryOf(doc: JsonObject?, k: String): JsonElement? = (doc?.get("pageOrder") as? JsonArray)?.firstOrNull { keyOf(it) == k }

    private fun sameElement(a: JsonElement?, b: JsonElement?) = AnnotationMerge.canonical(a ?: JsonNull) == AnnotationMerge.canonical(b ?: JsonNull)
}
