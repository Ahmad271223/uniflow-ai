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
    /** Bildschirmpixel -> PDF-Punkte (Ursprung oben links wie im Web-Editor). */
    fun toPoints(px: List<Pair<Float, Float>>, scale: Float): List<Float> {
        val out = ArrayList<Float>(px.size * 2)
        for ((x, y) in px) { out += x / scale; out += y / scale }
        return out
    }

    /** Striche mit einem Punkt naeher als `radiusPt` am Radierer. */
    fun strokesNear(objects: List<JsonElement>, xPt: Float, yPt: Float, radiusPt: Float): List<String> {
        val r2 = radiusPt * radiusPt
        return objects.filter { o ->
            (o as? JsonObject)?.get("type")?.let { (it as? JsonPrimitive)?.content } == "stroke" &&
                AnnotationDocument.strokePoints(o).chunked(2).any { p -> p.size == 2 && (p[0] - xPt).let { dx -> dx * dx } + (p[1] - yPt).let { dy -> dy * dy } <= r2 }
        }.map { de.uniflow.core.AnnotationMerge.objectId(it) }
    }

    /** Punkte ausduennen: nur Bewegungen ab `minDistPx` Pixel behalten (weniger Daten, glattere Striche). */
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

    fun parseColor(hex: String?): Long {
        val h = (hex ?: "#1f2937").removePrefix("#")
        val v = h.toLongOrNull(16) ?: 0x1f2937
        return if (h.length == 6) 0xFF000000L or v else v
    }
}
