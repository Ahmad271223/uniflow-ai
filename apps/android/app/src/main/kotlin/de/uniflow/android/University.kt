package de.uniflow.android

import android.content.Context
import android.content.SharedPreferences
import android.webkit.CookieManager
import android.webkit.WebStorage
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import de.uniflow.core.UniversitySession
import java.time.ZoneId

/**
 * Hochschul-Sitzung dieses Geraets (Cookies der Anmeldung in der WebView, Learnweb-Schluessel), verschluesselt in den
 * App-Einstellungen wie [Session]. Je Hochschule ein Eintrag; nie Benutzername oder Passwort. Beim Abmelden werden
 * auch die Cookies der WebView geloescht: die App nutzt die WebView nur fuer diese Anmeldung, darum darf alles weg.
 */
class UniversityStore(context: Context) {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context, "uniflow.university",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    private fun key(university: String) = "session.$university"

    fun load(university: String): UniversitySession? = prefs.getString(key(university), null)?.let { UniversitySession.fromJson(it) }

    fun save(session: UniversitySession) { prefs.edit().putString(key(session.university), session.toJson()).apply() }

    /** Die Hochschule hat statt der Datei eine Anmeldeseite geliefert: Sitzung bleibt sichtbar, gilt aber nicht mehr. */
    fun markExpired(university: String) { load(university)?.let { save(it.copy(expired = true)) } }

    fun clear(university: String) {
        prefs.edit().remove(key(university)).apply()
        clearWebCookies()
    }

    /** Alle Hochschul-Sitzungen (beim Abmelden vom UniFlow-Konto, damit ein anderes Konto sie nicht erbt). */
    fun clearAll() {
        prefs.edit().clear().apply()
        clearWebCookies()
    }

    private fun clearWebCookies() {
        runCatching {
            CookieManager.getInstance().apply { removeAllCookies(null); flush() }
            WebStorage.getInstance().deleteAllData()
        }
    }
}

/** Texte der Hochschul-Karte und des Dokument-Hinweises (reines Kotlin, im JVM-Test pruefbar). */
object UniversityRules {
    fun statusText(session: UniversitySession?, zone: ZoneId = ZoneId.systemDefault()): String = when {
        session == null -> "Nicht verbunden – Dateien kommen über den UniFlow-Dienst."
        session.expired -> "Sitzung abgelaufen – bitte neu anmelden; bis dahin kommen Dateien über den Dienst."
        else -> "Verbunden seit ${Dates.dateTime(session.savedAt, zone)} – Dateien werden direkt auf dieses Gerät geladen."
    }

    fun loginLabel(session: UniversitySession?): String = if (session?.expired == true) "Neu anmelden" else "Anmelden"

    /** Hinweis im Dokument nach einem Direkt-Download; null, wenn die Datei vom Dienst oder aus dem Cache kam. */
    fun sourceHint(source: String?): String? = when (source) {
        null -> null
        "studip" -> "Direkt von Stud.IP geladen"
        "learnweb" -> "Direkt aus dem Learnweb geladen"
        else -> "Direkt von der Hochschule geladen"
    }
}
