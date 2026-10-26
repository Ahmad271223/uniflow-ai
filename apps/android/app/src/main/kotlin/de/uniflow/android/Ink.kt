package de.uniflow.android

import de.uniflow.core.AnnotationDocument
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Stiftwerkzeuge wie im Web-Editor. Koordinaten der Striche sind PDF-Punkte; die Ansicht rechnet mit `scale` um. */
enum class InkTool(val label: String, val color: String, val width: Float, val opacity: Float, val key: String) {
    Pen("Stift", "#1f2937", 2f, 1f, "pen"),
    Red("Rot", "#e5322d", 2f, 1f, "pen"),
    Blue("Blau", "#4f5bd5", 2f, 1f, "pen"),
    Marker("Marker", "#ffd400", 14f, 0.35f, "marker"),
    Eraser("Radierer", "#000000", 0f, 0f, "eraser"),
}

/** Reine Geometrie ohne Android, im JVM-Test pruefbar. */
object InkMath {
    /** Standardfarbe des Stifts (ARGB), wenn ein gespeicherter Farbwert unbrauchbar ist. */
    const val DEFAULT_COLOR = 0xFF1F2937L

    /** Zeichenbare Strichbreite in PDF-Punkten (Web-Editor: Regler 0,5–40 px, Marker 14–16). */
    const val MIN_WIDTH = 0.3f
    const val MAX_WIDTH = 60f

    /** A4 in PDF-Punkten: Rueckfall bei unbrauchbaren Seitenmassen. */
    val A4: Pair<Float, Float> = 595f to 842f

    /** Bildschirmpixel -> PDF-Punkte (Ursprung oben links wie im Web-Editor). `scale` muss endlich und groesser 0 sein. */
    fun toPoints(px: List<Pair<Float, Float>>, scale: Float): List<Float> {
        require(scale > 0f && scale.isFinite()) { "Massstab muss endlich und groesser 0 sein: $scale" }
        val out = ArrayList<Float>(px.size * 2)
        for ((x, y) in px) { out += x / scale; out += y / scale }
        return out
    }

    /**
     * Ein einzelner Tipp (nur ein Punkt) wird wie im Web-Editor (`strokeEnd`) als kurzer Strich gespeichert:
     * der Punkt doppelt, um 0,05 pt versetzt. So bleibt er im gemeinsamen Format ein Strich mit mindestens zwei Punkten.
     */
    fun asStroke(points: List<Float>): List<Float> =
        if (points.size == 2) listOf(points[0], points[1], points[0] + 0.05f, points[1] + 0.05f) else points

    /** Striche mit einem Punkt naeher als `radiusPt` am Radierer; andere Objektarten (Text, Formen) bleiben unberuehrt. */
    fun strokesNear(objects: List<JsonElement>, xPt: Float, yPt: Float, radiusPt: Float): List<String> {
        val r2 = radiusPt * radiusPt
        return objects.filter { o ->
            isStroke(o) &&
                AnnotationDocument.strokePoints(o).chunked(2).any { p -> p.size == 2 && (p[0] - xPt).let { dx -> dx * dx } + (p[1] - yPt).let { dy -> dy * dy } <= r2 }
        }.map { de.uniflow.core.AnnotationMerge.objectId(it) }
    }

    /** Punkte ausduennen: nur Bewegungen ab `minDistPx` Pixel behalten (weniger Daten, glattere Striche); erster und letzter Punkt bleiben. */
    fun thin(points: List<Pair<Float, Float>>, minDistPx: Float = 1.5f): List<Pair<Float, Float>> {
        if (points.size < 3) return points
        val out = ArrayList<Pair<Float, Float>>()
        out += points.first()
        for (p in points.drop(1)) {
            val (lx, ly) = out.last()
            if (Math.hypot((p.first - lx).toDouble(), (p.second - ly).toDouble()) >= minDistPx) out += p
        }
        if (out.last() != points.last()) out += points.last()
        return out
    }

    /**
     * Farbe eines gespeicherten Objekts als ARGB. Erlaubt sind nur `#RRGGBB` (Schema annotations.schema.json; so schreibt
     * der Web-Editor) und CSS-`#RRGGBBAA`; alles andere (fehlend, `#FFF`, Namen, Fremdzeichen) ergibt die Standardfarbe.
     */
    fun parseColor(hex: String?): Long {
        val s = hex?.trim() ?: return DEFAULT_COLOR
        if (!s.startsWith("#")) return DEFAULT_COLOR
        val h = s.substring(1)
        if (h.length != 6 && h.length != 8) return DEFAULT_COLOR
        if (!h.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return DEFAULT_COLOR
        val v = h.toLong(16)
        return if (h.length == 6) 0xFF000000L or v else ((v and 0xFFL) shl 24) or (v ushr 8)     // CSS: RGBA -> ARGB
    }

    /** Strichbreite aus gespeicherten Daten, auf den zeichenbaren Bereich geklemmt; fehlend oder NaN -> `fallback`. */
    fun strokeWidth(raw: Float?, fallback: Float = 2f): Float = raw?.takeIf { it.isFinite() }?.coerceIn(MIN_WIDTH, MAX_WIDTH) ?: fallback

    /** Deckkraft 0..1; fehlend oder NaN -> 1 (deckend). */
    fun opacity(raw: Float?): Float = raw?.takeIf { it.isFinite() }?.coerceIn(0f, 1f) ?: 1f

    /** Seitenmass brauchbar: endlich und groesser 0 (sonst keine Division, kein Bild der Groesse 0). */
    fun validPageSize(widthPt: Float, heightPt: Float): Boolean = widthPt.isFinite() && heightPt.isFinite() && widthPt > 0f && heightPt > 0f

    /** Seitenverhaeltnis Breite/Hoehe fuer die Ansicht; bei unbrauchbaren Massen das von A4. */
    fun pageRatio(widthPt: Float, heightPt: Float): Float = if (validPageSize(widthPt, heightPt)) widthPt / heightPt else A4.first / A4.second

    /** Zahl aus einem JSON-Feld (fehlend, kein Zahlwert -> null). */
    fun num(o: JsonObject, key: String): Float? = (o[key] as? JsonPrimitive)?.content?.toFloatOrNull()

    fun isStroke(o: JsonElement): Boolean = ((o as? JsonObject)?.get("type") as? JsonPrimitive)?.content == "stroke"

    /** Objekte anderer Art (Text, Formen, Bilder, Haftnotizen des Web-Editors): hier nicht gezeichnet, beim Speichern unveraendert. */
    fun foreignCount(objects: List<JsonElement>): Int = objects.count { !isStroke(it) }

    /** Hinweis fuer die Ansicht, wenn eine Seite solche Objekte hat; null, wenn keine. */
    fun foreignHint(count: Int): String? = when {
        count <= 0 -> null
        count == 1 -> "1 weiteres Objekt (Text/Form/Bild) nur auf PC/iPad sichtbar"
        else -> "$count weitere Objekte (Text/Formen/Bilder) nur auf PC/iPad sichtbar"
    }
}
