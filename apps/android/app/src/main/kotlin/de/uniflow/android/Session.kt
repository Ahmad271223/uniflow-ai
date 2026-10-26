package de.uniflow.android

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import de.uniflow.core.ApiClient
import de.uniflow.core.Auth
import de.uniflow.core.JvmTransport

/**
 * Sitzung dieses Geraets: Serveradresse und Zugang (Konto-Token des Dienstes oder PIN des PCs im WLAN),
 * verschluesselt in den App-Einstellungen (Android-Schluesselbund). Nie Passwoerter: nur das Sitzungs-Token.
 */
class Session(context: Context) {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context, "uniflow.session",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    var baseUrl: String
        get() = prefs.getString("base_url", "") ?: ""
        set(v) = prefs.edit().putString("base_url", SessionRules.normalizeUrl(v)).apply()

    var token: String?
        get() = prefs.getString("token", null)
        set(v) = prefs.edit().putString("token", v).apply()

    var pin: String?
        get() = prefs.getString("pin", null)
        set(v) = prefs.edit().putString("pin", v).apply()

    var email: String?
        get() = prefs.getString("email", null)
        set(v) = prefs.edit().putString("email", v).apply()

    var university: String
        get() = prefs.getString("university", "luh") ?: "luh"
        set(v) = prefs.edit().putString("university", v).apply()

    val deviceId: String
        get() = prefs.getString("device_id", null) ?: ("android-" + java.util.UUID.randomUUID().toString().take(8)).also {
            prefs.edit().putString("device_id", it).apply()
        }

    val isLoggedIn: Boolean get() = baseUrl.isNotEmpty() && (token != null || pin != null)

    fun auth(): Auth = token?.let { Auth.Bearer(it) } ?: pin?.let { Auth.Pin(it) } ?: Auth.None

    fun client(): ApiClient = ApiClient(baseUrl, JvmTransport(), auth())

    fun clear() {
        prefs.edit().remove("token").remove("pin").remove("email").apply()
    }
}

/** Reine Regeln ohne Android, damit sie im JVM-Test laufen. */
object SessionRules {
    /** Eingabe wie "192.168.1.5:8765" oder "dienst.example.de" -> vollstaendige Adresse ohne Schraegstrich am Ende. */
    fun normalizeUrl(input: String): String {
        var s = input.trim().trimEnd('/')
        if (s.isEmpty()) return ""
        if (!s.startsWith("http://") && !s.startsWith("https://")) {
            s = if (isPrivateHost(s.substringBefore('/'))) "http://$s" else "https://$s"
        }
        return s.trimEnd('/')
    }

    /** PC im eigenen Netz (http erlaubt) oder Dienst (nur https). */
    fun isPrivateHost(hostPort: String): Boolean {
        val host = hostPort.substringBefore(':').lowercase()
        if (host == "localhost" || host.endsWith(".local") || host.endsWith(".fritz.box") || host.endsWith(".lan")) return true
        val parts = host.split('.')
        if (parts.size != 4 || parts.any { it.toIntOrNull() == null }) return false
        val (a, b) = parts[0].toInt() to parts[1].toInt()
        return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b in 16..31) || (a == 169 && b == 254)
    }

    fun isHttpAllowed(url: String): Boolean = url.startsWith("https://") || isPrivateHost(url.removePrefix("http://").substringBefore('/'))
}
