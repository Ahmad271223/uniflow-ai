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
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Nachlieferung eines Entwurfs an den Dienst, wenn die Ansicht ihn nicht mehr senden konnte (System beendet die App im
 * Hintergrund, kein Netz). Eindeutig je Datei, nur mit Netz, exponentieller Abstand bei Wiederholung. Die Eingabe ist
 * nur die Datei-ID: das Konto-Token kommt wie in der Ansicht aus der Sitzung (EncryptedSharedPreferences), nie aus den
 * WorkManager-Daten. Was nach der Antwort geschieht, entscheidet DraftUploadRules (im JVM-Test geprueft).
 */
class DraftUploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val fileId = inputData.getString(KEY_FILE_ID)?.takeIf { it.isNotEmpty() } ?: return Result.failure()
        val app = applicationContext as? UniFlowApplication ?: return Result.failure()
        if (!app.session.isLoggedIn) {
            Log.w(TAG, "Entwurf $fileId: nicht angemeldet, bleibt liegen")       // beim naechsten Oeffnen nach der Anmeldung
            return Result.failure()
        }
        val out = DraftUploadRules.upload(fileId, app.repo.drafts) { d -> app.repo.saveAnnotations(fileId, d.doc, d.base, d.baseVersion) }
        return when (out) {
            DraftUploadRules.Outcome.Success -> Result.success()
            DraftUploadRules.Outcome.Retry -> { Log.w(TAG, "Entwurf $fileId: Dienst nicht erreichbar, spaeter erneut"); Result.retry() }
            is DraftUploadRules.Outcome.Failure -> { Log.w(TAG, "Entwurf $fileId bleibt liegen: ${out.reason}"); Result.failure() }
        }
    }

    companion object {
        private const val TAG = "UniFlow"
        const val KEY_FILE_ID = "fileId"

        /** Plant die Nachlieferung der Datei ein; ein schon eingeplanter Versuch derselben Datei wird ersetzt. */
        fun enqueue(context: Context, fileId: String, policy: ExistingWorkPolicy = ExistingWorkPolicy.REPLACE) {
            val req = OneTimeWorkRequestBuilder<DraftUploadWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, DraftUploadRules.BACKOFF_SECONDS, TimeUnit.SECONDS)
                .setInputData(workDataOf(KEY_FILE_ID to fileId))
                .build()
            runCatching { WorkManager.getInstance(context).enqueueUniqueWork(DraftUploadRules.workName(fileId), policy, req) }
                .onFailure { Log.w(TAG, "Nachlieferung $fileId nicht eingeplant: ${it.message}") }
        }

        fun cancel(context: Context, fileId: String) {
            runCatching { WorkManager.getInstance(context).cancelUniqueWork(DraftUploadRules.workName(fileId)) }
        }

        /** Beim App-Start: liegen gebliebene Entwuerfe (App im Hintergrund beendet) einplanen, ohne eingeplante zu stoeren. */
        fun enqueuePending(context: Context, store: DraftStore) {
            AppScope.main.launch(Dispatchers.IO) {
                for (d in store.pending()) enqueue(context, d.fileId, ExistingWorkPolicy.KEEP)
            }
        }
    }
}
