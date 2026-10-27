package de.uniflow.android.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.uniflow.android.AppScope
import de.uniflow.android.Dates
import de.uniflow.android.Repo
import de.uniflow.android.SyncRules
import de.uniflow.android.UniversityRules
import de.uniflow.android.ui.Loaded
import de.uniflow.android.ui.SectionCard
import de.uniflow.android.ui.UiState
import de.uniflow.android.ui.rememberLoaded
import de.uniflow.android.ui.theme.Bad
import de.uniflow.android.ui.theme.Ok
import de.uniflow.android.ui.theme.Warn
import de.uniflow.core.ApiError
import de.uniflow.core.Labels
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun HomeScreen(repo: Repo, onLogout: () -> Unit, onOpenLibrary: () -> Unit, onUniversityLogin: () -> Unit) {
    val (state, reload) = rememberLoaded("dashboard") { repo.dashboard() }
    // Hochschul-Sitzung dieses Geraets: beim Zurueckkehren von der Anmeldung wird die Ansicht neu aufgebaut und laedt den Stand neu
    val (uniState, reloadUni) = rememberLoaded("university") { repo.universityStatus() }
    val scope = rememberCoroutineScope()
    var info by remember { mutableStateOf<String?>(null) }
    var syncing by remember { mutableStateOf(false) }

    /** Abgleich wie `pollBg` im Web: starten, /api/bg abfragen bis fertig, dann die Uebersicht neu laden. */
    fun startSync() {
        scope.launch {
            syncing = true
            try {
                info = try { "${repo.startSync()}: gestartet …" }
                catch (e: ApiError) { if (e.status == 409) e.message else throw e }        // laeuft schon: trotzdem abwarten
                val end = SyncRules.waitUntilIdle(fetch = { repo.bg() }, wait = { delay(SyncRules.POLL_MS) },
                    onUpdate = { bg -> if (bg.running) info = bg.message ?: "${bg.task ?: "Abgleich"} läuft …" })
                info = end?.message ?: if (end == null) "Abgleich läuft noch; später „Aktualisieren“ tippen" else "Abgleich fertig"
                reload()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { info = e.message ?: e.toString() }
            finally { syncing = false }
        }
    }

    Loaded(state, reload) { d ->
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                Text("Guten Tag!", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                // Sitzung sofort verwerfen und wechseln; der Server-Logout laeuft im Hintergrund (kein Warten bei langsamem Netz)
                TextButton(onClick = { repo.logout(AppScope.main); onLogout() }) { Text("Abmelden") }
            }
            Text(buildString {
                append(d.lastSyncAt?.let { "Zuletzt synchronisiert: ${it.take(16).replace('T', ' ')}" } ?: "Noch kein Abgleich")
                if (d.bgRunning) append(" · ${d.bgMessage ?: "läuft"}")
            }, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp))
            Row(Modifier.padding(horizontal = 12.dp)) {
                TextButton(enabled = !syncing, onClick = { startSync() }) { Text(if (syncing) "Abgleich läuft …" else "Abgleich starten") }
                TextButton(onClick = reload) { Text("Aktualisieren") }
            }
            info?.let { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp)) }

            SectionCard("Heute an der Uni") {
                if (d.todayEvents.isEmpty()) Text("Keine Termine heute.", style = MaterialTheme.typography.bodyMedium)
                d.todayEvents.forEach { e ->
                    val off = e.status != "teilnahme"
                    Text("${e.start}–${e.end}  ${e.title}" + (e.room?.let { "  ·  $it" } ?: "") + (Labels.occurrence[e.status]?.takeIf { it.isNotEmpty() }?.let { "  ($it)" } ?: ""),
                        style = MaterialTheme.typography.bodyMedium, color = if (off) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface)
                }
            }
            SectionCard("Heute für dich geplant") {
                if (d.todayPackages.isEmpty()) Text("Für heute ist nichts geplant.", style = MaterialTheme.typography.bodyMedium)
                d.todayPackages.forEach { p ->
                    Text("${p.subject}: ${p.title}  ·  ${Labels.status[p.status] ?: p.status}", fontWeight = FontWeight.SemiBold)
                    p.tasks.forEach { t -> Text((if (t.done) "✓ " else "• ") + t.title + "  ${t.estMinutes} min", style = MaterialTheme.typography.bodySmall) }
                }
            }
            SectionCard("Nächste Termine") {
                if (d.upcoming.isEmpty()) Text("Keine Termine.", style = MaterialTheme.typography.bodyMedium)
                d.upcoming.take(8).forEach { u ->
                    val label = u.kindLabel ?: when (u.kind) { "klausur" -> "Klausur"; "test" -> "Wochentest"; else -> "Lernpaket" }
                    Text(u.title, fontWeight = FontWeight.SemiBold, color = if (u.overdue) Bad else MaterialTheme.colorScheme.onSurface)
                    Text("${Dates.short(u.date)}${u.time?.let { " $it" } ?: ""} · $label${u.courseTitle?.let { " · $it" } ?: ""}", style = MaterialTheme.typography.bodySmall)
                }
            }
            if (d.announcements.isNotEmpty()) SectionCard("Ankündigungen") {
                d.announcements.take(5).forEach { a ->
                    Text(a.title, fontWeight = FontWeight.SemiBold)
                    Text("${Dates.short(a.postedAt)}${a.courseTitle?.let { " · $it" } ?: ""} · ${if (a.source == "studip") "Stud.IP" else "Learnweb"}", style = MaterialTheme.typography.bodySmall)
                    Text(a.text.take(240) + if (a.text.length > 240) "…" else "", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(bottom = 6.dp))
                }
            }
            SectionCard("Neu aus der Hochschule") {
                Text(if (d.newTotal == 0) "Nichts Neues." else "${d.newTotal} neue Dateien", style = MaterialTheme.typography.bodyMedium)
                if (d.newTotal > 0) TextButton(onClick = onOpenLibrary) { Text("Dokumente öffnen") }
            }
            SectionCard("Hochschule") {
                when (val u = uniState) {
                    is UiState.Loading -> Text("Lade …", style = MaterialTheme.typography.bodySmall)
                    is UiState.Failed -> Text(u.message, style = MaterialTheme.typography.bodySmall, color = Bad)
                    is UiState.Ready -> {
                        val profile = u.value.profile
                        val uni = u.value.session
                        Text(profile?.name ?: "Hochschule des Kontos", fontWeight = FontWeight.SemiBold)
                        Text(UniversityRules.statusText(uni), style = MaterialTheme.typography.bodySmall,
                            color = if (uni == null) MaterialTheme.colorScheme.onSurface else if (uni.expired) Warn else Ok)
                        if (profile == null) Text("Für diese Hochschule gibt es noch kein Anmeldeprofil.", style = MaterialTheme.typography.bodySmall, color = Warn)
                        Row {
                            TextButton(enabled = profile != null, onClick = onUniversityLogin) { Text(UniversityRules.loginLabel(uni)) }
                            if (uni != null) TextButton(onClick = { repo.universityLogout(); reloadUni() }) { Text("Abmelden") }
                        }
                    }
                }
            }
        }
    }
}
