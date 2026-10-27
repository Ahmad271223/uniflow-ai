package de.uniflow.android

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import de.uniflow.core.ApiError
import de.uniflow.core.SqlDb
import java.io.File
import java.io.IOException
import java.time.Instant
import java.time.ZoneId

/**
 * Ergebnis einer Ansicht mit Herkunft: frisch vom Dienst (`offline = false`) oder aus der lokalen Ablage
 * (`offline = true`, `fetchedAt` = Zeitpunkt der Momentaufnahme in UTC, `note` = Grund). `pending` zaehlt lokale
 * Aenderungen, die noch nicht beim Dienst sind.
 */
data class Stand<T>(val value: T, val fetchedAt: String?, val offline: Boolean, val note: String? = null, val pending: Int = 0)

/** Reine Regeln des Offline-Betriebs (ohne Android, im JVM-Test pruefbar). */
object OfflineRules {
    /**
     * Bei diesen Fehlern springt die Ablage ein: kein Netz (0), Zeitueberschreitung (408), Server gestoert (5xx), zu
     * viele Anfragen (429), Ein-/Ausgabefehler. Nicht bei 401 (Anmeldung), 404 oder anderen Antworten des Dienstes –
     * die sind eine Aussage, kein Ausfall.
     */
    fun fallsBackToLocal(e: Throwable): Boolean = when (e) {
        is ApiError -> e.status == 0 || e.status == 408 || e.status == 429 || e.status in 500..599
        is IOException -> true
        else -> false
    }

    /** Zeitstempel der Ablage (UTC, YYYY-MM-DDTHH:MM:SS.mmmZ) als Sekunden seit 1970, null bei fremder Form. */
    fun epochSeconds(fetchedAt: String?): Long? = fetchedAt?.let { runCatching { Instant.parse(it).epochSecond }.getOrNull() }

    /** Hinweis ueber einer Ansicht: null, wenn der Stand frisch ist. */
    fun standText(stand: Stand<*>, zone: ZoneId = ZoneId.systemDefault()): String? {
        if (!stand.offline) return null
        val at = epochSeconds(stand.fetchedAt)?.let { "Stand vom ${Dates.dateTime(it, zone)}" } ?: "Gespeicherter Stand"
        val why = stand.note?.takeIf { it.isNotBlank() }?.let { if (it.contains("Keine Verbindung") || it.contains("network")) "keine Verbindung" else it }
        return listOfNotNull(at, why ?: "keine Verbindung").joinToString(" – ")
    }

    /** Zeile unter dem Stand-Hinweis: offene lokale Aenderungen. */
    fun pendingText(pending: Int): String? = when {
        pending <= 0 -> null
        pending == 1 -> "1 Änderung wird gesendet, sobald der Dienst erreichbar ist"
        else -> "$pending Änderungen werden gesendet, sobald der Dienst erreichbar ist"
    }
}

/** SqlDb ueber android.database.sqlite; die Datei liegt im App-Speicher (`files/uniflow-local.db`). */
class AndroidSqlDb(private val db: SQLiteDatabase) : SqlDb {

    override fun exec(sql: String, args: List<Any?>) {
        if (args.isEmpty()) db.execSQL(sql) else db.execSQL(sql, args.map { if (it is Boolean) (if (it) 1 else 0) else it }.toTypedArray())
    }

    override fun query(sql: String, args: List<Any?>): List<Map<String, Any?>> {
        // rawQuery bindet alle Parameter als Text; LocalStore vergleicht in WHERE nur Textspalten (entity, id, key)
        db.rawQuery(sql, args.map { it.toString() }.toTypedArray()).use { c ->
            val out = ArrayList<Map<String, Any?>>(c.count)
            val names = c.columnNames
            while (c.moveToNext()) {
                val row = LinkedHashMap<String, Any?>(names.size)
                for (i in names.indices) row[names[i]] = when (c.getType(i)) {
                    Cursor.FIELD_TYPE_NULL -> null
                    Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                    Cursor.FIELD_TYPE_FLOAT -> c.getDouble(i)
                    Cursor.FIELD_TYPE_BLOB -> c.getBlob(i)
                    else -> c.getString(i)
                }
                out.add(row)
            }
            return out
        }
    }

    override fun <T> transaction(block: () -> T): T {
        db.beginTransaction()
        try {
            val r = block(); db.setTransactionSuccessful(); return r
        } finally { db.endTransaction() }
    }

    override fun close() { db.close() }

    companion object {
        const val FILE_NAME = "uniflow-local.db"

        fun open(context: Context): AndroidSqlDb = AndroidSqlDb(SQLiteDatabase.openOrCreateDatabase(File(context.filesDir, FILE_NAME), null))
    }
}
