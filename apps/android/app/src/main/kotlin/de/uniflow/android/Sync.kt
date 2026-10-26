package de.uniflow.android

import de.uniflow.core.b
import de.uniflow.core.s
import kotlinx.serialization.json.JsonElement

/** Zustand des Hintergrundjobs auf dem Server (GET /api/bg); gleiche Felder im Dienst (Job-Warteschlange) und auf dem PC. */
data class BgStatus(val running: Boolean, val task: String?, val message: String?) {
    companion object {
        fun from(j: JsonElement?): BgStatus = BgStatus(j.b("running"), j.s("task"), j.s("message")?.takeIf { it.isNotEmpty() })
    }
}

/** Abgleich wie `pollBg` im Web: nach dem Start /api/bg abfragen, bis der Job fertig ist, dann die Ansicht neu laden. */
object SyncRules {
    const val POLL_MS = 3_000L

    /** Hoechstens so viele Abfragen (bei 3 s Abstand rund 15 Minuten); danach meldet der Aufrufer, dass der Abgleich noch laeuft. */
    const val MAX_POLLS = 300

    /**
     * Fragt `fetch` ab, bis `running` falsch ist, und wartet dazwischen mit `wait`. Liefert den letzten Zustand oder null,
     * wenn der Job nach `maxPolls` Abfragen noch laeuft.
     */
    suspend fun waitUntilIdle(fetch: suspend () -> BgStatus, wait: suspend () -> Unit, maxPolls: Int = MAX_POLLS, onUpdate: (BgStatus) -> Unit = {}): BgStatus? {
        repeat(maxPolls) {
            val bg = fetch()
            onUpdate(bg)
            if (!bg.running) return bg
            wait()
        }
        return null
    }
}
