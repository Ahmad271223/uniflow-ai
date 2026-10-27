package de.uniflow.android

import android.app.Application
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import de.uniflow.core.LocalStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Arbeiten, die eine Ansicht ueberleben muessen (letztes Senden der Notizen beim Verlassen, Abmelden beim Server, Meldungen nach einem Direkt-Download). */
object AppScope {
    val main: CoroutineScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
}

class UniFlowApplication : Application() {
    lateinit var session: Session
        private set
    lateinit var universities: UniversityStore
        private set
    lateinit var drafts: DraftStore
        private set
    lateinit var local: LocalStore
        private set
    lateinit var repo: Repo
        private set

    override fun onCreate() {
        super.onCreate()
        PDFBoxResourceLoader.init(applicationContext)        // Schriftmetriken fuer den Seitentext (PdfBoxPageText)
        session = Session(this)
        universities = UniversityStore(this)
        drafts = DraftStore(DraftStore.dir(filesDir))        // ungesendete Notizstaende (files/drafts)
        local = LocalStore(AndroidSqlDb.open(this), session.deviceId)   // lokale Ablage: G2-Zeilen, Tombstones, Cursor, Momentaufnahmen (files/uniflow-local.db)
        repo = Repo(session, cacheDir, universities, drafts, local, PdfBoxPageText(), schedulePush = { SyncPushWorker.enqueue(this) })
        DraftUploadWorker.enqueuePending(this, drafts)        // liegen gebliebene Entwuerfe (App im Hintergrund beendet) nachliefern
        AppScope.main.launch(Dispatchers.IO) {                // liegen gebliebene G2-Aenderungen (abgehakt ohne Netz) nachliefern
            if (session.isLoggedIn && repo.pendingCount() > 0) SyncPushWorker.enqueue(this@UniFlowApplication)
        }
    }
}
