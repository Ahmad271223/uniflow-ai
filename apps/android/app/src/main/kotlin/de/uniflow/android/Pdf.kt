package de.uniflow.android

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
