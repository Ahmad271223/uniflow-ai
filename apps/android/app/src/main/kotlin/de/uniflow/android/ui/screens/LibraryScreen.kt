package de.uniflow.android.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.uniflow.android.Repo
import de.uniflow.android.ui.Loaded
import de.uniflow.android.ui.rememberLoaded
import de.uniflow.android.ui.theme.Warn
import de.uniflow.core.LibraryFile

/** Dokumente nach Modul; PDFs, die der Server geladen hat, oeffnen sich im Stift-Editor. */
@Composable
fun LibraryScreen(repo: Repo, onOpen: (LibraryFile) -> Unit) {
    val (state, reload) = rememberLoaded("library") { repo.library() }
    var hint by remember { mutableStateOf<String?>(null) }
    Loaded(state, reload) { lib ->
        val groups = lib.byModule().entries.sortedBy { it.key?.name ?: "~" }
        LazyColumn(Modifier.fillMaxSize()) {
            item { Text("Dokumente", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(16.dp, 12.dp, 16.dp, 4.dp)) }
            hint?.let { item { Text(it, color = Warn, modifier = Modifier.padding(horizontal = 16.dp)) } }
            for ((module, files) in groups) {
                item {
                    Text(module?.name ?: "Ohne Modul", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(16.dp, 14.dp, 16.dp, 4.dp))
                }
                items(files.size) { i ->
                    val f = files[i]
                    Column(Modifier.fillMaxWidth().clickable {
                        if (f.isPdf && f.isLocal) onOpen(f) else hint = if (!f.isPdf) "„${f.title}“ ist keine PDF." else "„${f.title}“ ist auf dem Server noch nicht geladen (Abgleich abwarten)."
                    }.padding(horizontal = 16.dp, vertical = 10.dp)) {
                        Text(f.title, style = MaterialTheme.typography.bodyLarge)
                        Text(listOfNotNull(f.docType, f.kind.takeIf { it != "pdf" }, if (!f.isLocal && f.isPdf) "nicht geladen" else null).joinToString(" · ").ifEmpty { f.name },
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
                    }
                    HorizontalDivider()
                }
            }
            if (lib.files.isEmpty()) item { Text("Noch keine Dokumente. Nach dem ersten Abgleich erscheinen sie hier.", modifier = Modifier.padding(16.dp)) }
        }
    }
}
