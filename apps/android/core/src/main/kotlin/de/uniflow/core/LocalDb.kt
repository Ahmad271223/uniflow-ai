package de.uniflow.core

/**
 * Kleinste SQL-Schnittstelle fuer die lokale Ablage (LocalStore): die App setzt sie mit android.database.sqlite um,
 * der JVM-Test mit sqlite-jdbc. Beide sprechen dieselbe SQLite-Sprache, deshalb liegen Schema, Trigger und die
 * Abgleich-Logik vollstaendig im Kern und sind ohne Geraet pruefbar.
 *
 * Werte: Zeichenketten, ganze Zahlen (Long/Int) und null. Abfrage-Parameter werden auf Android als Text gebunden
 * (rawQuery); Vergleiche in WHERE-Klauseln gelten daher nur fuer Textspalten – Zahlen stehen als Literal im SQL.
 */
interface SqlDb {
    fun exec(sql: String, args: List<Any?> = emptyList())
    fun query(sql: String, args: List<Any?> = emptyList()): List<Map<String, Any?>>
    fun <T> transaction(block: () -> T): T
    fun close()
}

/** Ganze Zahl aus einer Ergebnisspalte (SQLite liefert je Treiber Long, Int oder Text). */
fun Map<String, Any?>.long(key: String): Long? = when (val v = this[key]) {
    null -> null
    is Number -> v.toLong()
    is String -> v.toLongOrNull()
    else -> null
}

fun Map<String, Any?>.text(key: String): String? = this[key]?.toString()
