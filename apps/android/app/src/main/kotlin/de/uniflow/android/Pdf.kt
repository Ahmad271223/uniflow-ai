package de.uniflow.android

import de.uniflow.core.ApiError
import java.io.File

/**
 * Pruefung von PDF-Daten, bevor sie in den Cache uebernommen oder daraus verwendet werden (reines Kotlin, im JVM-Test
 * pruefbar). Eine Fehlerseite, ein abgebrochener Download oder eine leere Datei soll nie als PDF geoeffnet werden.
 */
object PdfRules {
    /** Kleinste plausible PDF (Kopfzeile, ein Objekt, xref, Trailer); kuerzere Dateien sind abgebrochen oder keine PDF. */
    const val MIN_SIZE = 64L

    /** Die Kopfzeile darf wie in PDF-Lesern innerhalb der ersten 1024 Bytes stehen (manche Erzeuger setzen Bytes davor). */
    private const val HEADER_WINDOW = 1024
    private val HEADER = "%PDF-".toByteArray(Charsets.US_ASCII)

    /** Heruntergeladene Bytes: gross genug und mit Kopfzeile `%PDF-`. */
    fun isPdf(bytes: ByteArray): Boolean = bytes.size >= MIN_SIZE && hasHeader(bytes)

    /** Kopfzeile `%PDF-` im Anfang der Daten (`head` sind die ersten Bytes, hoechstens 1024 werden beachtet). */
    fun hasHeader(head: ByteArray): Boolean {
        val end = minOf(head.size, HEADER_WINDOW) - HEADER.size
        for (start in 0..end) {
            var i = 0
            while (i < HEADER.size && head[start + i] == HEADER[i]) i++
            if (i == HEADER.size) return true
        }
        return false
    }

    /** Datei im Cache: vorhanden, gross genug, Kopfzeile vorhanden (nur der Anfang wird gelesen). */
    fun looksLikePdf(f: File): Boolean {
        if (!f.isFile || f.length() < MIN_SIZE) return false
        val head = ByteArray(HEADER_WINDOW)
        val n = runCatching { f.inputStream().use { it.read(head) } }.getOrDefault(-1)
        return n >= HEADER.size && hasHeader(head.copyOf(n))
    }
}

/**
 * Ablage der PDFs im Cache des Geraets (reines Kotlin, im JVM-Test pruefbar). Der Cache-Schluessel enthaelt die
 * Aenderungszeit; der Download geht zuerst in eine `.part`-Datei und wird erst nach der Pruefung umbenannt, so liegt nie
 * eine halbe Datei unter dem endgueltigen Namen.
 */
object PdfCache {
    fun dir(cacheDir: File): File = File(cacheDir, "pdf").apply { mkdirs() }

    fun fileFor(dir: File, id: String, chdate: Long?): File = File(dir, "$id-${chdate ?: 0}.pdf")

    /**
     * Uebernimmt `bytes` als `f`; nur, was mit `%PDF-` beginnt und gross genug ist (PdfRules), sonst ApiError `not_pdf`
     * und keine Datei. Eine vorhandene Datei wird ersetzt.
     */
    fun store(dir: File, f: File, bytes: ByteArray, origin: String = "Der Server") {
        if (!PdfRules.isPdf(bytes)) throw ApiError(0, "not_pdf", "$origin hat keine PDF geliefert (${bytes.size} Bytes)")
        val tmp = File(dir, f.name + ".part")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(f)) {
            f.delete()
            if (!tmp.renameTo(f)) { tmp.delete(); throw ApiError(0, "cache", "PDF konnte nicht im Cache abgelegt werden") }
        }
    }
}
