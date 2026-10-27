package de.uniflow.android

import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import de.uniflow.core.LibraryFile
import de.uniflow.core.UniversitySession
import java.io.File

/**
 * Woher eine Datei kommt (reine Regel, im JVM-Test pruefbar): direkt von der Hochschule mit der Sitzung dieses Geraets
 * oder wie bisher ueber den UniFlow-Dienst (`/api/files/{id}/content`). Direkt nur, wenn eine nicht abgelaufene
 * Hochschul-Sitzung vorliegt, die Datei eine Quelladresse (https) hat und aus Stud.IP oder dem Learnweb stammt;
 * eigene Dateien ("own") liegen nur beim Dienst.
 */
object FetchPolicy {
    sealed interface Decision {
        data object Service : Decision
        data class Direct(val url: String, val source: String) : Decision
    }

    val DIRECT_SOURCES = setOf("studip", "learnweb")

    fun decide(file: LibraryFile, session: UniversitySession?): Decision {
        if (session == null || session.expired) return Decision.Service
        val url = file.downloadUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return Decision.Service
        if (file.source !in DIRECT_SOURCES) return Decision.Service
        if (!url.startsWith("https://")) return Decision.Service          // Sitzungs-Cookies nie im Klartext
        return Decision.Direct(url, file.source)
    }
}

/** Seitentext einer PDF-Datei (eine Zeichenkette je Seite); die Umsetzung mit PdfBox liegt in [PdfBoxPageText]. */
fun interface PageTextExtractor {
    fun extract(file: File): List<String>

    companion object {
        /** Kein Seitentext (Tests, Rueckfall). */
        val None = PageTextExtractor { emptyList() }
    }
}

/**
 * Grenzen des Dienstes fuer gemeldeten Seitentext (PUT /api/files/{id}/pagetext): hoechstens 2000 Seiten, je Seite
 * hoechstens 20000 Zeichen. Fehler beim Auslesen ergeben eine leere Liste, der Download wird nie blockiert.
 */
object PageTextRules {
    const val MAX_PAGES = 2000
    const val MAX_CHARS = 20_000

    fun limit(pages: List<String>): List<String> = pages.take(MAX_PAGES).map { cut(it) }

    /** Kuerzt auf MAX_CHARS, ohne ein Ersatzzeichenpaar (Emoji, seltene Schriftzeichen) zu zerschneiden. */
    fun cut(text: String): String {
        if (text.length <= MAX_CHARS) return text
        val end = if (Character.isHighSurrogate(text[MAX_CHARS - 1])) MAX_CHARS - 1 else MAX_CHARS
        return text.substring(0, end)
    }

    /** Seitentext nur fuer PDF-Dateien, begrenzt; jede Ausnahme des Extraktors ergibt eine leere Liste. */
    fun collect(extractor: PageTextExtractor, file: File): List<String> {
        if (!PdfRules.looksLikePdf(file)) return emptyList()
        return runCatching { limit(extractor.extract(file)) }.getOrElse { emptyList() }
    }
}

/**
 * Seitentext mit PdfBox-Android (`PDFBoxResourceLoader.init` in UniFlowApplication). Liest hoechstens MAX_PAGES Seiten;
 * eine Seite, die sich nicht auslesen laesst, wird leer gemeldet, damit die Seitenzahlen stimmen. Grosse Dateien
 * werden ueber temporaere Dateien statt im Speicher verarbeitet.
 */
class PdfBoxPageText : PageTextExtractor {
    override fun extract(file: File): List<String> =
        PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly()).use { doc ->
            val n = minOf(doc.numberOfPages, PageTextRules.MAX_PAGES)
            val stripper = PDFTextStripper()
            (1..n).map { i ->
                stripper.startPage = i
                stripper.endPage = i
                runCatching { stripper.getText(doc) }.getOrDefault("")
            }
        }
}
