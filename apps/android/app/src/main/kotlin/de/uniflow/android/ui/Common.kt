package de.uniflow.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import de.uniflow.android.ui.theme.Bad
import de.uniflow.android.ui.theme.Ok
import de.uniflow.core.ApiError
import de.uniflow.core.DayMark
import de.uniflow.core.Deadline
import de.uniflow.core.Notice

/** Ladezustand einer Ansicht. */
sealed class UiState<out T> {
    data object Loading : UiState<Nothing>()
    data class Ready<T>(val value: T) : UiState<T>()
    data class Failed(val message: String, val auth: Boolean = false) : UiState<Nothing>()
}

/**
 * Laedt `load` beim ersten Anzeigen und bei jeder Aenderung von `key`. Beim Neuladen ueber die zweite Rueckgabe bleibt
 * der bisherige Inhalt stehen, bis die neue Antwort da ist (kein Flackern, Scrollposition bleibt); nur der erste Aufruf
 * und ein Schluesselwechsel zeigen den Ladekreis.
 */
@Composable
fun <T> rememberLoaded(key: Any?, load: suspend () -> T): Pair<UiState<T>, () -> Unit> {
    var state by remember(key) { mutableStateOf<UiState<T>>(UiState.Loading) }
    var tick by remember(key) { mutableStateOf(0) }
    LaunchedEffect(key, tick) {
        if (state !is UiState.Ready) state = UiState.Loading
        state = try {
            UiState.Ready(load())
        } catch (e: ApiError) {
            UiState.Failed(e.message ?: "Fehler", e.isAuth)
        } catch (e: Exception) {
            UiState.Failed(e.message ?: e.toString())
        }
    }
    return state to { tick++ }
}

@Composable
fun <T> Loaded(state: UiState<T>, retry: () -> Unit, content: @Composable (T) -> Unit) {
    when (state) {
        is UiState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        is UiState.Failed -> Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(if (state.auth) "Anmeldung abgelaufen oder PIN falsch." else "Keine Verbindung: ${state.message}", color = Bad)
            Button(onClick = retry, modifier = Modifier.padding(top = 12.dp)) { Text("Erneut versuchen") }
        }
        is UiState.Ready -> content(state.value)
    }
}

@Composable
fun SectionCard(title: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Card(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Column(Modifier.padding(14.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            content()
        }
    }
}

@Composable
fun Chip(text: String, color: Color, modifier: Modifier = Modifier) {
    Text(text, color = color, style = MaterialTheme.typography.labelSmall,
        modifier = modifier.padding(end = 6.dp, top = 2.dp).background(color.copy(alpha = 0.14f), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
}

@Composable
fun DayExtras(marks: List<DayMark>, deadlines: List<Deadline>, notices: List<Notice>) {
    if (marks.isEmpty() && deadlines.isEmpty() && notices.isEmpty()) return
    Row(Modifier.fillMaxWidth().padding(top = 2.dp)) {
        Column {
            marks.distinctBy { it.label }.forEach { Chip(it.label, Ok) }
            deadlines.forEach { Chip("${it.time ?: ""} ${it.kindLabel}: ${it.title}".trim(), if (it.overdue) Bad else MaterialTheme.colorScheme.primary) }
            notices.forEach { Chip("${it.kindLabel}: ${it.title}", MaterialTheme.colorScheme.secondary) }
        }
    }
}

fun colorOf(hex: String?, fallback: Color): Color = hex?.removePrefix("#")?.toLongOrNull(16)?.let { Color(0xFF000000L or it) } ?: fallback
