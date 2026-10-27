package de.uniflow.android

import android.app.Application
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Arbeiten, die eine Ansicht ueberleben muessen (letztes Senden der Notizen beim Verlassen, Abmelden beim Server, Meldungen nach einem Direkt-Download). */
object AppScope {
    val main: CoroutineScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
}

class UniFlowApplication : Application() {
    lateinit var session: Session
        private set
    lateinit var universities: UniversityStore
        private set
    lateinit var repo: Repo
        private set

    override fun onCreate() {
        super.onCreate()
        PDFBoxResourceLoader.init(applicationContext)        // Schriftmetriken fuer den Seitentext (PdfBoxPageText)
        session = Session(this)
        universities = UniversityStore(this)
        repo = Repo(session, cacheDir, universities, PdfBoxPageText())
    }
}
