package de.uniflow.android

import de.uniflow.core.LibraryFile
import de.uniflow.core.UniCookie
import de.uniflow.core.UniversitySession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** Woher eine Datei kommt: direkt von der Hochschule nur mit gueltiger Sitzung, Quelladresse (https) und Quelle Stud.IP/Learnweb. */
class FetchPolicyTest {
    private fun file(json: String): LibraryFile = LibraryFile.from(Json.parseToJsonElement(json) as JsonObject)
    private val studip = file("""{"id":"f1","name":"skript.pdf","kind":"pdf","download_url":"https://studip.uni-hannover.de/sendfile.php?file_id=abc","source":"studip"}""")
    private val learnweb = file("""{"id":"lw-7","name":"folien.pdf","kind":"pdf","download_url":"https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/1/mod_resource/content/1/folien.pdf","source":"learnweb"}""")
    private val own = file("""{"id":"u1","name":"eigene.pdf","kind":"pdf","download_url":"https://dienst.example.de/x","source":"own"}""")
    private val session = UniversitySession("luh", listOf(UniCookie("Seminar_Session", "abc", "studip.uni-hannover.de")), savedAt = 1_700_000_000)

    @Test
    fun withoutSessionTheServiceDelivers() {
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(studip, null))
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(learnweb, null))
    }

    @Test
    fun sessionWithDownloadUrlGoesDirect() {
        val d = assertIs<FetchPolicy.Decision.Direct>(FetchPolicy.decide(studip, session))
        assertEquals("studip", d.source); assertEquals(studip.downloadUrl, d.url)
        val l = assertIs<FetchPolicy.Decision.Direct>(FetchPolicy.decide(learnweb, session.copy(university = "hildesheim", learnwebToken = "t")))
        assertEquals("learnweb", l.source)
    }

    @Test
    fun expiredSessionFallsBackToTheService() {
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(studip, session.copy(expired = true)))
    }

    @Test
    fun ownFilesStayWithTheService() {
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(own, session))
    }

    @Test
    fun withoutUrlOrWithoutHttpsTheServiceDelivers() {
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(file("""{"id":"f2","name":"a.pdf","kind":"pdf","source":"studip"}"""), session))
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(file("""{"id":"f3","name":"a.pdf","kind":"pdf","download_url":"  ","source":"studip"}"""), session))
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(file("""{"id":"f4","name":"a.pdf","kind":"pdf","download_url":"http://studip.uni-hannover.de/x","source":"studip"}"""), session),
            "Sitzungs-Cookies nie im Klartext")
        assertEquals(FetchPolicy.Decision.Service, FetchPolicy.decide(file("""{"id":"f5","name":"a.pdf","kind":"pdf","download_url":"https://x.de/a","source":"ilias"}"""), session),
            "unbekannte Quelle")
    }
}
