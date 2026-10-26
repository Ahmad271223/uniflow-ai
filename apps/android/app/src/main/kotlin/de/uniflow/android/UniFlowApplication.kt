package de.uniflow.android

import android.app.Application

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
