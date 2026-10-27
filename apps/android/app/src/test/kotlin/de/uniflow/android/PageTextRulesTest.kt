package de.uniflow.android

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Grenzen des gemeldeten Seitentexts (Dienst: hoechstens 2000 Seiten, je 20000 Zeichen); Fehler ergeben eine leere Liste. */
class PageTextRulesTest {
    private fun pdfFile(dir: File, name: String = "a.pdf"): File = File(dir, name).apply {
        writeBytes("%PDF-1.4\n1 0 obj << >> endobj\nxref\ntrailer\n%%EOF\n".toByteArray(Charsets.US_ASCII).let { it + ByteArray(200) })
    }

    @Test
    fun pagesAndCharactersAreLimited() {
        val pages = List(2500) { i -> if (i == 1) "x".repeat(25_000) else "Seite $i" }
        val out = PageTextRules.limit(pages)
        assertEquals(2000, out.size)
        assertEquals(20_000, out[1].length)
        assertEquals("Seite 0", out[0]); assertEquals("Seite 1999", out[1999])
        assertEquals("kurz", PageTextRules.cut("kurz"))
    }

    @Test
    fun cutDoesNotSplitASurrogatePair() {
        val text = "a".repeat(19_999) + "😀" + "rest"      // Emoji genau an der Grenze
        val cut = PageTextRules.cut(text)
        assertEquals(19_999, cut.length, "das halbe Paar faellt weg")
        assertTrue(cut.all { it == 'a' })
    }

    @Test
    fun collectUsesTheExtractorOnlyForPdfsAndSwallowsErrors() {
        val dir = Files.createTempDirectory("uniflow-pagetext").toFile()
        try {
            val pdf = pdfFile(dir)
            val fake = PageTextExtractor { f -> List(3) { "Text ${f.name} ${it + 1}" } + List(2100) { "mehr" } }
            val pages = PageTextRules.collect(fake, pdf)
            assertEquals(2000, pages.size); assertEquals("Text a.pdf 1", pages[0])

            val html = File(dir, "b.pdf").apply { writeBytes(("<html>" + " ".repeat(300)).toByteArray()) }
            assertEquals(emptyList(), PageTextRules.collect(fake, html), "keine PDF: Extraktor wird nicht gefragt")
            assertEquals(emptyList(), PageTextRules.collect(fake, File(dir, "fehlt.pdf")))

            val failing = PageTextExtractor { throw IllegalStateException("PDF verschluesselt") }
            assertEquals(emptyList(), PageTextRules.collect(failing, pdf), "Fehler blockieren nichts")
            assertEquals(emptyList(), PageTextRules.collect(PageTextExtractor.None, pdf))
        } finally { dir.deleteRecursively() }
    }
}
