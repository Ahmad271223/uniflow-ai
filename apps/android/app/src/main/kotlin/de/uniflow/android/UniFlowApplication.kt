package de.uniflow.android

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Arbeiten, die eine Ansicht ueberleben muessen (letztes Senden der Notizen beim Verlassen, Abmelden beim Server). */
object AppScope {
    val main: CoroutineScope by lazy { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
}

class UniFlowApplication : Application() {
    lateinit var session: Session
        private set
    lateinit var repo: Repo
        private set

    override fun onCreate() {
        super.onCreate()
        session = Session(this)
        repo = Repo(session, cacheDir)
    }
}
