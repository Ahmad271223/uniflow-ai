package de.uniflow.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Drei-Wege-Zusammenfuehrung einer Notizseite (Basis = letzter bestaetigter Serverstand, lokal, Server).
 * Gleiche Regeln wie UniFlowCore/AnnotationMerge.swift und app/static/merge.js; gemeinsame Testfaelle:
 * packages/shared-contracts/fixtures/merge/cases.json.
 */
object AnnotationMerge {

    data class Result(val page: JsonObject?, val conflicts: Int)

    /** Kanonisches JSON (Schluessel sortiert, Zahlen einheitlich) fuer Vergleiche unabhaengig von der Feldreihenfolge. */
    fun canonical(e: JsonElement?): String = when (e) {
        null, is JsonNull -> "null"
        is JsonObject -> e.keys.sorted().joinToString(",", "{", "}") { k -> quote(k) + ":" + canonical(e[k]) }
        is JsonArray -> e.joinToString(",", "[", "]") { canonical(it) }
        is JsonPrimitive -> when {
            e.isString -> quote(e.content)
            e.content == "true" || e.content == "false" -> e.content
            else -> e.content.toDoubleOrNull()?.let { d ->
                if (d == Math.rint(d) && Math.abs(d) < 1e15) d.toLong().toString() else d.toString()
            } ?: e.content
        }
    }

    private fun quote(s: String) = JsonPrimitive(s).toString()

    private fun same(a: JsonElement?, b: JsonElement?): Boolean = canonical(a) == canonical(b)

    private fun pageOrNull(e: JsonElement?): JsonObject? = e as? JsonObject

    fun objectId(o: JsonElement): String {
        val id = ((o as? JsonObject)?.get("id") as? JsonPrimitive)?.takeIf { it.isString }?.content
        return if (!id.isNullOrEmpty()) id else "~" + canonical(o)
    }

    fun mergeObjects(base: List<JsonElement>, local: List<JsonElement>, server: List<JsonElement>): Pair<List<JsonElement>, Int> {
        val b = base.associateBy { objectId(it) }
        val l = local.associateBy { objectId(it) }
        val out = ArrayList<JsonElement>(maxOf(local.size, server.size))
        val emitted = HashSet<String>()
        var conflicts = 0
        for (o in server) {
            val id = objectId(o)
            if (!emitted.add(id)) continue
            val bo = b[id]
            val lo = l[id]
            when {
                lo != null -> when {
                    same(lo, bo) || same(lo, o) -> out.add(o)
                    same(o, bo) -> out.add(lo)
                    else -> { out.add(lo); conflicts++ }
                }
                bo == null -> out.add(o)                           // neu auf dem anderen Geraet
                !same(o, bo) -> { out.add(o); conflicts++ }       // hier geloescht, dort geaendert -> behalten
            }
        }
        for (o in local) {
            val id = objectId(o)
            if (!emitted.add(id)) continue
            val bo = b[id]
            when {
                bo == null -> out.add(o)                           // neu auf diesem Geraet
                !same(o, bo) -> { out.add(o); conflicts++ }       // dort geloescht, hier geaendert -> behalten
            }
        }
        return out to conflicts
    }

    fun mergePage(base: JsonElement?, local: JsonElement?, server: JsonElement?): Result {
        val bp = pageOrNull(base)
        val lp = pageOrNull(local)
        val sp = pageOrNull(server)
        if (same(lp, bp)) return Result(sp, 0)
        if (same(sp, bp) || same(sp, lp)) return Result(lp, 0)
        if (lp == null) return Result(sp, 1)
        if (sp == null) return Result(lp, 1)
        val result = LinkedHashMap<String, JsonElement>()
        var conflicts = 0
        for (k in (lp.keys + sp.keys + (bp?.keys ?: emptySet()))) {
            if (k == "objects" || k == "pkdrawing") continue
            val bv = bp?.get(k)
            val lv = lp[k]
            val sv = sp[k]
            val v = when {
                same(lv, bv) -> sv
                same(sv, bv) || same(sv, lv) -> lv
                else -> { conflicts++; lv }
            }
            if (v != null) result[k] = v
        }
        val lo = (lp["objects"] as? JsonArray) ?: JsonArray(emptyList())
        val so = (sp["objects"] as? JsonArray) ?: JsonArray(emptyList())
        val (objects, c) = mergeObjects((bp?.get("objects") as? JsonArray) ?: emptyList(), lo, so)
        conflicts += c
        result["objects"] = JsonArray(objects)
        // native iPad-Zeichnung nur behalten, wenn sie noch genau zu den Objekten passt
        if (lp["pkdrawing"] != null && same(JsonArray(objects), lo)) result["pkdrawing"] = lp["pkdrawing"]!!
        else if (sp["pkdrawing"] != null && same(JsonArray(objects), so)) result["pkdrawing"] = sp["pkdrawing"]!!
        return Result(JsonObject(result), conflicts)
    }
}
