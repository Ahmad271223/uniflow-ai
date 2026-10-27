package de.uniflow.android.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import de.uniflow.android.ui.StandHinweis
import de.uniflow.android.ui.rememberStand
import de.uniflow.android.ui.theme.Ok
import de.uniflow.core.Labels

@Composable
fun TimetableScreen(repo: Repo) {
    var monday by remember { mutableStateOf(Dates.mondayOf(Dates.today())) }
    val start = Dates.format(monday)
    // Gespeicherte Woche sofort (oder Termine aus dem letzten Abgleich), dann frisch vom Dienst
    val (state, reload) = rememberStand(start, local = { repo.localTimetableWeek(start) }, remote = { repo.timetableWeek(start) })
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { monday = monday.minusWeeks(1) }) { Text("◀") }
            Text(Dates.weekLabel(monday), modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = { monday = Dates.mondayOf(Dates.today()) }) { Text("Heute") }
            TextButton(onClick = { monday = monday.plusWeeks(1) }) { Text("▶") }
        }
        Loaded(state, reload) { stand ->
            val week = stand.value
            LazyColumn(Modifier.fillMaxSize()) {
                item { StandHinweis(stand) }
                week.termName?.let { item { Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp)) } }
                items(week.days.size) { i ->
                    val d = week.days[i]
                    val free = d.marks.any { it.kind == "feiertag" || it.kind == "pause" }
                    SectionCard("${Dates.weekdaysLong[d.weekday]}, ${Dates.short(d.date).substringAfter(", ")}") {
                        DayExtras(d.marks, d.deadlines, d.notices)
                        if (d.events.isEmpty()) Text(if (free) "Vorlesungsfrei" else "Keine Termine", color = if (free) Ok else MaterialTheme.colorScheme.outline,
                            style = MaterialTheme.typography.bodyMedium)
                        d.events.filter { it.status != "verschoben" }.forEach { e ->
                            val off = e.status != "teilnahme"
                            Text("${e.start}–${e.end}  ${e.title}", fontWeight = FontWeight.SemiBold,
                                color = if (off) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface)
                            Text(listOfNotNull(Labels.kind[e.kind] ?: e.kind, e.room, Labels.occurrence[e.status]?.takeIf { it.isNotEmpty() }, e.note).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline, modifier = Modifier.padding(bottom = 4.dp))
                        }
                    }
                }
            }
        }
    }
}
