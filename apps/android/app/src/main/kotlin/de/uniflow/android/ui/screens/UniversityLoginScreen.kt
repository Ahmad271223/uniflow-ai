package de.uniflow.android.ui.screens

import android.annotation.SuppressLint
import android.view.View
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import de.uniflow.android.Repo
import de.uniflow.android.UniversityStore
import de.uniflow.android.ui.Loaded
import de.uniflow.android.ui.rememberLoaded
import de.uniflow.android.ui.theme.Bad
import de.uniflow.android.ui.theme.Warn
import de.uniflow.core.Learnweb
import de.uniflow.core.UniCookie
import de.uniflow.core.UniversityProfile
import de.uniflow.core.UniversitySession
import java.util.UUID

/** Route `uni-login`: Profil der Hochschule des Kontos laden (Dienst, sonst eingebaut), dann die Anmeldeseite. */
@Composable
fun UniversityLoginRoute(repo: Repo, onDone: () -> Unit) {
    val (state, reload) = rememberLoaded("uni-profile") { repo.universityProfile() }
    Loaded(state, reload) { profile ->
        if (profile == null) {
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Für die Hochschule deines Kontos gibt es noch kein Anmeldeprofil; Dateien kommen weiter über den Dienst.", color = Warn)
                Button(onClick = onDone, modifier = Modifier.padding(top = 12.dp)) { Text("Zurück") }
            }
        } else UniversityLoginScreen(profile, repo.universities, onDone, onSession = repo::reportUniversitySession)
    }
}

/**
 * Anmeldung bei der Hochschule in einer WebView, wie auf dem iPad: die Seite der Hochschule selbst (WebSSO der LUH bzw.
 * CAS Hildesheim), JavaScript und DOM-Speicher an, weil die SSO-Seiten sie brauchen. Die App fuellt nichts vor und
 * merkt sich kein Passwort; sie liest nach jeder fertigen Seite nur die Cookies der Profil-Hosts und speichert sie
 * als Hochschul-Sitzung, sobald das Profil die Anmeldung erkennt. Fuer das Learnweb (Hildesheim) holt sie danach den
 * Mobile-Schluessel ueber die Rueckleitung `uniflow://token=…` (Moodle-Launch mit Passport dieses Bildschirms).
 * Adressen ausserhalb der Hochschule werden nicht geoeffnet (Hinweis), Fehler bleiben sichtbar, Abbrechen ist immer
 * moeglich (Zurueck-Geste geht erst in der Seite zurueck).
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun UniversityLoginScreen(profile: UniversityProfile, store: UniversityStore, onDone: () -> Unit, onCancel: () -> Unit = onDone,
                          onSession: (UniversitySession) -> Unit = {}) {
    val passport = remember { UUID.randomUUID().toString() }
    var progress by remember { mutableIntStateOf(0) }
    var hint by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val flow = remember(profile) {
        UniversityLoginFlow(profile, passport, store, onHint = { hint = it }, onError = { error = it }, onDone = onDone, onSession = onSession)
    }

    DisposableEffect(Unit) { onDispose { webView?.let { runCatching { it.stopLoading(); it.destroy() } }; webView = null } }
    BackHandler { val w = webView; if (w != null && w.canGoBack()) w.goBack() else onCancel() }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Anmelden: ${profile.name}", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).padding(start = 16.dp), maxLines = 1)
            TextButton(onClick = { webView?.let { flow.restart(it) } }) { Text("Neu laden") }
            IconButton(onClick = onCancel) { Icon(Icons.Filled.Close, contentDescription = "Abbrechen") }
        }
        if (progress in 1..99) LinearProgressIndicator(progress = { progress / 100f }, modifier = Modifier.fillMaxWidth())
        Text("Du meldest dich direkt bei deiner Hochschule an. UniFlow merkt sich nur die Sitzung dieses Geräts, kein Passwort.",
            style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        hint?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Warn, modifier = Modifier.padding(horizontal = 16.dp)) }
        val err = error
        if (err != null) {
            Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Fehler: $err", color = Bad)
                Button(onClick = { error = null; webView?.let { flow.restart(it) } }, modifier = Modifier.padding(top = 12.dp)) { Text("Erneut versuchen") }
                TextButton(onClick = onCancel) { Text("Abbrechen") }
            }
        }
        // Die WebView bleibt immer dieselbe (sonst bliebe die alte offen); bei einem Fehler ist sie nur eingeklappt
        AndroidView(modifier = if (err == null) Modifier.weight(1f).fillMaxWidth() else Modifier.size(0.dp), factory = { ctx ->
            WebView(ctx).apply {
                // Passwort merken uebernimmt der Passwort-Manager des Systems (Google Password Manager, Samsung Pass):
                // die WebView nimmt am Android-Autofill teil, die App speichert nie Benutzername oder Passwort und fuellt
                // nichts selbst aus (Vorgabe des Inhabers, 27.10.2026)
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.loadWithOverviewMode = true
                settings.useWideViewPort = true
                settings.builtInZoomControls = true
                settings.displayZoomControls = false
                settings.setSupportMultipleWindows(false)
                CookieManager.getInstance().setAcceptCookie(true)
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)     // SSO-Weiterleitungen zwischen den Hosts der Hochschule
                webChromeClient = object : WebChromeClient() {
                    override fun onProgressChanged(view: WebView, newProgress: Int) { progress = newProgress }
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = flow.shouldBlock(request)
                    override fun onPageFinished(view: WebView, url: String?) { progress = 100; flow.pageFinished(view, url) }
                    override fun onReceivedError(view: WebView, request: WebResourceRequest, err: WebResourceError) {
                        if (request.isForMainFrame) error = "${err.description} (${request.url.host ?: request.url})"
                    }
                }
                webView = this
                flow.restart(this)
            }
        })
    }
}

/**
 * Ablauf der Anmeldung ohne Compose-Zustand: entscheidet je Adresse und je fertiger Seite. Ein Bildschirm hat einen
 * Passport (UUID), mit dem der Moodle-Launch den Learnweb-Schluessel verschluesselt zurueckgibt; `done` sorgt dafuer,
 * dass `onDone` nur einmal kommt (onPageFinished kann mehrfach feuern).
 */
private class UniversityLoginFlow(
    private val profile: UniversityProfile,
    private val passport: String,
    private val store: UniversityStore,
    private val onHint: (String?) -> Unit,
    private val onError: (String) -> Unit,
    private val onDone: () -> Unit,
    private val onSession: (UniversitySession) -> Unit = {},
) {
    private var done = false
    private var launchStarted = false
    private var session: UniversitySession? = null

    fun restart(view: WebView) {
        done = false; launchStarted = false; session = null
        onHint(null)
        view.loadUrl(profile.loginUrl)
    }

    /** true = nicht laden (Rueckleitung verarbeitet oder fremde Adresse blockiert). */
    fun shouldBlock(request: WebResourceRequest): Boolean {
        val url = request.url
        val s = url.toString()
        if (url.scheme.equals(profile.launchScheme, ignoreCase = true)) { tokenReceived(s); return true }
        if (!request.isForMainFrame) return false
        if (s.startsWith("about:") || s.startsWith("data:")) return false
        if (!profile.allows(s)) {
            onHint("Nur Seiten deiner Hochschule – „${url.host ?: s.take(60)}“ wurde nicht geöffnet.")
            return true
        }
        return false
    }

    /** Rueckleitung des Moodle-Launch (`uniflow://token=…`): Schluessel in die Sitzung, fertig. */
    private fun tokenReceived(url: String) {
        if (done) return
        val base = profile.learnwebBase
        val token = if (base != null) Learnweb.parseLaunchToken(url, base, passport) else null
        if (token == null) { onError("Der Learnweb-Schlüssel konnte nicht gelesen werden (Rückleitung passt nicht zum Passport)."); return }
        val s = session ?: UniversitySession(profile.key, collectCookies(), savedAt = now())
        finish(s.copy(learnwebToken = token.token, savedAt = now()))
    }

    fun pageFinished(view: WebView, url: String?) {
        if (done || url == null) return
        val cookies = collectCookies()
        if (!profile.loggedIn(cookies, url)) return
        val s = UniversitySession(profile.key, cookies, learnwebToken = session?.learnwebToken, savedAt = now())
        session = s
        store.save(s)                                       // schon jetzt gesichert: auch ohne Learnweb-Schluessel sind die Cookies nutzbar
        val base = profile.learnwebBase
        if (base != null && s.learnwebToken == null && !launchStarted) {
            launchStarted = true
            onHint("Angemeldet – Learnweb-Schlüssel wird geholt …")
            view.loadUrl(Learnweb.launchUrl(base, passport, profile.launchScheme))
            return
        }
        finish(s)        // nach dem Launch ohne Rueckleitung: Sitzung mit Cookies, ohne Schluessel
    }

    private fun finish(s: UniversitySession) {
        if (done) return
        done = true
        store.save(s)
        onSession(s)                                        // Dienst bekommt die Sitzung (Cookies) fuer den Abgleich ohne Zugangsdaten
        onHint(null)
        onDone()
    }

    /** Cookies je Host des Profils aus der WebView (Name=Wert; Ablauf ist dort nicht lesbar). */
    private fun collectCookies(): List<UniCookie> {
        val cm = CookieManager.getInstance()
        return profile.hosts.flatMap { host -> UniversitySession.parseCookieHeader(cm.getCookie("https://$host"), host) }
    }

    private fun now(): Long = System.currentTimeMillis() / 1000
}
