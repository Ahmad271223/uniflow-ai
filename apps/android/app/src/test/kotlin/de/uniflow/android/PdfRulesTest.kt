package de.uniflow.android

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** PDF-Pruefung vor Uebernahme in den Cache: Kopfzeile `%PDF-` und Mindestgroesse, fuer Bytes und fuer Cache-Dateien. */
class PdfRulesTest {
    private fun pdfBytes(size: Int = 200, lead: String = ""): ByteArray =
        (lead + "%PDF-1.4\n1 0 obj << >> endobj\nxref\ntrailer\n%%EOF\n").toByteArray(Charsets.US_ASCII).let { it + ByteArray(maxOf(0, size - it.size)) }

    @Test
    fun bytesNeedHeaderAndMinimumSize() {
        assertTrue(PdfRules.isPdf(pdfBytes()))
        assertTrue(PdfRules.isPdf(pdfBytes(lead = "ï»¿junk\n")), "Kopfzeile darf in den ersten 1024 Bytes stehen")
        assertFalse(PdfRules.isPdf("%PDF-1.4".toByteArray()), "zu kurz fuer eine PDF")
        assertFalse(PdfRules.isPdf(ByteArray(0)))
        assertFalse(PdfRules.isPdf(("<html><body>Anmeldung erforderlich</body></html>" + " ".repeat(200)).toByteArray()), "Fehlerseite")
        assertFalse(PdfRules.isPdf(("{\"detail\":\"not found\"}" + " ".repeat(200)).toByteArray()))
        assertFalse(PdfRules.isPdf(pdfBytes(lead = "x".repeat(1100))), "Kopfzeile erst nach 1024 Bytes gilt nicht")
        assertTrue(PdfRules.hasHeader("%PDF-".toByteArray())); assertFalse(PdfRules.hasHeader("%PDF".toByteArray())); assertFalse(PdfRules.hasHeader(ByteArray(0)))
    }

    @Test
    fun cacheFilesAreCheckedByTheirHeader() {
        val dir = Files.createTempDirectory("uniflow-pdf").toFile()
        try {
            val good = File(dir, "a.pdf").apply { writeBytes(pdfBytes()) }
            val html = File(dir, "b.pdf").apply { writeBytes(("<html>" + " ".repeat(300)).toByteArray()) }
            val empty = File(dir, "c.pdf").apply { writeBytes(ByteArray(0)) }
            val short = File(dir, "d.pdf").apply { writeBytes("%PDF-1.7".toByteArray()) }
            val big = File(dir, "e.pdf").apply { writeBytes(pdfBytes(size = 5000)) }
            assertTrue(PdfRules.looksLikePdf(good)); assertTrue(PdfRules.looksLikePdf(big))
            assertFalse(PdfRules.looksLikePdf(html)); assertFalse(PdfRules.looksLikePdf(empty)); assertFalse(PdfRules.looksLikePdf(short))
            assertFalse(PdfRules.looksLikePdf(File(dir, "fehlt.pdf"))); assertFalse(PdfRules.looksLikePdf(dir), "Verzeichnis ist keine Datei")
        } finally { dir.deleteRecursively() }
    }
}
