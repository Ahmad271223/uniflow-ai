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

    /**
     * Kanonisches JSON wie stableStringify in merge.js: Schluessel sortiert, Zahlen in der Form von JSON.stringify.
     * Vergleiche sind damit unabhaengig von der Feldreihenfolge, und die aus dem Inhalt abgeleitete Kennung
     * (objectId) ist fuer dieselbe Eingabe zeichengleich mit der des Web-Editors.
     */
    fun canonical(e: JsonElement?): String = when (e) {
        null, is JsonNull -> "null"
        is JsonObject -> e.keys.sorted().joinToString(",", "{", "}") { k -> quote(k) + ":" + canonical(e[k]) }
        is JsonArray -> e.joinToString(",", "[", "]") { canonical(it) }
        is JsonPrimitive -> when {
            e.isString -> quote(e.content)
            e.content == "true" || e.content == "false" -> e.content
            else -> e.content.toDoubleOrNull()?.let { number(it) } ?: e.content
        }
    }

    /**
     * Zahl wie Number::toString in JavaScript (ECMAScript 6.1.6.1.20), also wie JSON.stringify nach JSON.parse:
     * JavaScript rechnet jede JSON-Zahl in ein Double um (9007199254740993 wird dort wie hier zu 9007199254740992),
     * schreibt ganze Zahlen bis 1e21 ausgeschrieben, darueber und unter 1e-6 mit Exponent ("1e+21", "1e-7").
     * Die Ziffernfolge stammt aus Double.toString (kuerzeste eindeutige Darstellung; JDK 17 weicht in seltenen
     * Faellen um eine Ziffer ab, bleibt aber je Wert eindeutig, Gleichheit ist also nicht betroffen).
     */
    private fun number(d: Double): String {
        if (d.isNaN() || d.isInfinite()) return "null"                   // JSON.stringify(Infinity) === "null"
        if (d == 0.0) return "0"                                          // auch -0
        val bd = java.math.BigDecimal(Math.abs(d).toString()).stripTrailingZeros()
        val digits = bd.unscaledValue().toString()
        val k = digits.length
        val n = k - bd.scale()                                            // Wert = digits * 10^(n-k)
        val body = when {
            n in k..21 -> digits + "0".repeat(n - k)
            n in 1..21 -> digits.substring(0, n) + "." + digits.substring(n)
            n in -5..0 -> "0." + "0".repeat(-n) + digits
            else -> (if (k == 1) digits else digits.substring(0, 1) + "." + digits.substring(1)) +
                "e" + (if (n - 1 < 0) "-" else "+") + Math.abs(n - 1)
        }
        return if (d < 0) "-$body" else body
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
        // native iPad-Zeichnung: v1 nur, wenn sie noch genau zu den Objekten passt. v2 prueft das iPad je Strich selbst
        // (strokeSigs) und bleibt deshalb auch bei abweichenden Objekten erhalten (wie merge.js und AnnotationMerge.swift)
        val merged = JsonArray(objects)
        val lpk = lp["pkdrawing"]?.takeIf { it !is JsonNull }
        val spk = sp["pkdrawing"]?.takeIf { it !is JsonNull }
        when {
            lpk != null && same(merged, lo) -> result["pkdrawing"] = lpk
            spk != null && same(merged, so) -> result["pkdrawing"] = spk
            perStroke(lpk) -> result["pkdrawing"] = lpk!!
            perStroke(spk) -> result["pkdrawing"] = spk!!
        }
        return Result(JsonObject(result), conflicts)
    }

    private fun perStroke(pk: JsonElement?): Boolean {
        val o = pk as? JsonObject ?: return false
        return (o["format"] as? JsonPrimitive)?.content == "pkdrawing-v2" && o["strokeSigs"] is JsonArray
    }
}
