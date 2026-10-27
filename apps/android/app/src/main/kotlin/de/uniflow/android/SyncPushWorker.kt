package de.uniflow.android

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import de.uniflow.core.ApiError
import java.util.concurrent.TimeUnit

/**
 * Geraete-Abgleich (G2) im Hintergrund: offene lokale Aenderungen (abgehakte Aufgaben) an den Dienst senden und
 * Aenderungen anderer Geraete holen, sobald Netz da ist. Eingeplant nach jeder lokalen Aenderung und beim App-Start,
 * wenn etwas liegen geblieben ist; ein Name fuer alle (ein Lauf genuegt). Das Konto-Token kommt aus der Sitzung
 * (EncryptedSharedPreferences), nie aus den WorkManager-Daten.
 */
class SyncPushWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as? UniFlowApplication ?: return Result.failure()
        if (!app.session.isLoggedIn) { Log.w(TAG, "Abgleich: nicht angemeldet, Aenderungen bleiben liegen"); return Result.failure() }
        return try {
            val r = app.repo.syncNow()
            Log.i(TAG, "Abgleich im Hintergrund: ${r.summary()}")
            Result.success()
        } catch (e: ApiError) {
            if (DraftUploadRules.shouldRetry(e.status)) { Log.w(TAG, "Abgleich: Dienst nicht erreichbar (${e.message}), spaeter erneut"); Result.retry() }
            else { Log.w(TAG, "Abgleich abgebrochen: ${e.message}"); Result.failure() }
        } catch (e: Exception) {
            Log.w(TAG, "Abgleich: ${e.message}, spaeter erneut"); Result.retry()
        }
    }

    companion object {
        private const val TAG = "UniFlow"
        const val WORK_NAME = "sync-push"

        /** Abgleich einplanen, sobald Netz da ist; ein schon eingeplanter Lauf bleibt (KEEP). */
        fun enqueue(context: Context) {
            val req = OneTimeWorkRequestBuilder<SyncPushWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, DraftUploadRules.BACKOFF_SECONDS, TimeUnit.SECONDS)
                .build()
            runCatching { WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.KEEP, req) }
                .onFailure { Log.w(TAG, "Abgleich nicht eingeplant: ${it.message}") }
        }
    }
}
