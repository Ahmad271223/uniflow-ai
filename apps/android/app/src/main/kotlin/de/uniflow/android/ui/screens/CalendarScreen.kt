package de.uniflow.android.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.uniflow.android.Dates
import de.uniflow.android.Repo
import de.uniflow.android.ui.DayExtras
import de.uniflow.android.ui.Loaded
import de.uniflow.android.ui.SectionCard
import de.uniflow.android.ui.colorOf
import de.uniflow.android.ui.rememberLoaded
import de.uniflow.android.ui.theme.Bad
import de.uniflow.core.Labels
import kotlinx.coroutines.launch

/** Lernkalender: Woche mit Lernpaketen und Aufgaben; Abhaken geht direkt zum Server (POST /api/tasks/{id}/status). */
@Composable
fun CalendarScreen(repo: Repo) {
    var monday by remember { mutableStateOf(Dates.mondayOf(Dates.today())) }
    val start = Dates.format(monday)
    val end = Dates.format(monday.plusDays(6))
    val (state, reload) = rememberLoaded(start) { repo.calendar(start, end) }
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { monday = monday.minusWeeks(1) }) { Text("◀") }
            Text("Lernkalender ${Dates.weekLabel(monday)}", modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = { monday = Dates.mondayOf(Dates.today()) }) { Text("Heute") }
            TextButton(onClick = { monday = monday.plusWeeks(1) }) { Text("▶") }
        }
        error?.let { Text(it, color = Bad, modifier = Modifier.padding(horizontal = 12.dp)) }
        Loaded(state, reload) { range ->
            LazyColumn(Modifier.fillMaxSize()) {
                items(range.days.size) { i ->
                    val d = range.days[i]
                    SectionCard("${Dates.weekdaysLong[d.weekday]}, ${Dates.short(d.date).substringAfter(", ")}  ·  ${Labels.status[d.status] ?: d.status}" +
                        (if (d.minutes > 0) " · ${Dates.minutes(d.minutes)}" else "")) {
                        DayExtras(d.marks, d.deadlines, d.notices)
                        d.events.filter { it.status == "teilnahme" }.forEach { e ->
                            Text("${e.start}–${e.end}  ${e.title}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
                        }
                        if (d.packages.isEmpty()) Text("Nichts geplant.", style = MaterialTheme.typography.bodyMedium)
                        d.packages.forEach { p ->
                            Text("${p.subject}: ${p.title}" + (p.startTime?.let { "  $it–${p.endTime}" } ?: ""), fontWeight = FontWeight.SemiBold,
                                color = colorOf(p.color, MaterialTheme.colorScheme.primary), modifier = Modifier.padding(top = 6.dp))
                            p.tasks.forEach { t ->
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Checkbox(checked = t.done, onCheckedChange = { checked ->
                                        scope.launch {
                                            try { repo.setTaskStatus(t.id, if (checked) "erledigt" else "geplant"); error = null; reload() }
                                            catch (e: Exception) { error = "Status nicht gespeichert: ${e.message}" }
                                        }
                                    })
                                    Text("${t.title}  ·  ${Labels.taskType[t.type] ?: t.type}, ${t.estMinutes} min", style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
