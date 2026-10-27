package de.uniflow.android

import de.uniflow.core.ApiError
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Ablage im Cache wie bisher: Name aus ID und Aenderungszeit, erst `.part`, nur geprueft uebernommen, nie eine halbe Datei. */
class PdfCacheTest {
    private fun pdfBytes(tag: String = "1"): ByteArray =
        "%PDF-1.4\n% $tag\n1 0 obj << >> endobj\nxref\ntrailer\n%%EOF\n".toByteArray(Charsets.US_ASCII).let { it + ByteArray(200) }

    @Test
    fun fileNameCarriesIdAndChangeTime() {
        val dir = File("cache")
        assertEquals(File(dir, "abc-1700000000.pdf"), PdfCache.fileFor(dir, "abc", 1_700_000_000L))
        assertEquals(File(dir, "abc-0.pdf"), PdfCache.fileFor(dir, "abc", null))
    }

    @Test
    fun storeWritesAtomicallyAndRejectsNonPdf() {
        val root = Files.createTempDirectory("uniflow-cache").toFile()
        try {
            val dir = PdfCache.dir(root)
            assertTrue(dir.isDirectory && dir.name == "pdf")
            val f = PdfCache.fileFor(dir, "f1", 5)
            PdfCache.store(dir, f, pdfBytes())
            assertTrue(PdfRules.looksLikePdf(f)); assertFalse(File(dir, f.name + ".part").exists(), "keine .part-Datei bleibt liegen")

            PdfCache.store(dir, f, pdfBytes("2"))
            assertTrue(f.readBytes().toString(Charsets.US_ASCII).contains("% 2"), "vorhandene Datei wird ersetzt")

            val g = PdfCache.fileFor(dir, "f2", 5)
            val e = assertFailsWith<ApiError> { PdfCache.store(dir, g, ("<html>Anmeldung" + " ".repeat(300)).toByteArray(), origin = "Die Hochschule") }
            assertEquals("not_pdf", e.code); assertTrue(e.message!!.startsWith("Die Hochschule"))
            assertFalse(g.exists()); assertFalse(File(dir, g.name + ".part").exists())
        } finally { root.deleteRecursively() }
    }
}
