package de.uniflow.core

import kotlinx.serialization.json.JsonObject

/**
 * Notizen laden und speichern nach den Regeln aus API.md: immer mit base_version; bei 409 den Serverstand holen,
 * eigene Aenderungen mit AnnotationDocument.merge darauflegen und erneut senden. Eine aeltere Serverantwort
 * ersetzt nie den lokalen, ungesendeten Stand (der Aufrufer behaelt `local`, bis `save` bestaetigt hat).
 */
class AnnotationStore(private val client: ApiClient) {

    data class Loaded(val doc: JsonObject, val version: Int, val updatedAt: String?)
    data class Saved(val doc: JsonObject, val version: Int, val mergedConflicts: Int, val attempts: Int)

    fun load(fileId: String): Loaded {
        val j = client.get("/api/files/$fileId/annotations")
        val doc = (j.o("data")) ?: AnnotationDocument.empty()
        return Loaded(doc, j.i("version") ?: 0, j.s("updated_at"))
    }

    /**
     * @param base letzter vom Server bestaetigter Stand (fuer die Zusammenfuehrung), null beim ersten Speichern
     * @param baseVersion Version dieses Standes (0 ohne Notizen)
     */
    fun save(fileId: String, local: JsonObject, base: JsonObject?, baseVersion: Int, maxAttempts: Int = 3): Saved {
        var doc = local
        var b = base
        var version = baseVersion
        var conflicts = 0
        for (attempt in 1..maxAttempts) {
            val resp = client.raw("PUT", "/api/files/$fileId/annotations", doc, mapOf("base_version" to version.toString()), allowStatus = setOf(409))
            val j = resp.json()
            if (resp.status != 409) {
                return Saved(doc, j.i("version") ?: (version + 1), conflicts, attempt)
            }
            val serverDoc = j.o("data") ?: AnnotationDocument.empty()
            val serverVersion = j.i("version") ?: (version + 1)
            val (merged, n) = AnnotationDocument.merge(b, doc, serverDoc)
            conflicts += n
            doc = merged
            b = serverDoc
            version = serverVersion
        }
        throw ApiError(409, "conflict", "Notizen konnten nach $maxAttempts Versuchen nicht zusammengefuehrt werden")
    }
}
