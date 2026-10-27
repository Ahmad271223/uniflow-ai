package de.uniflow.android.ui.screens

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import de.uniflow.android.AnnotationSession
import de.uniflow.android.AppScope
import de.uniflow.android.DraftKeeper
import de.uniflow.android.DraftUploadWorker
import de.uniflow.android.InkMath
import de.uniflow.android.InkTool
import de.uniflow.android.Repo
import de.uniflow.android.UniversityRules
import de.uniflow.android.ui.theme.Bad
import de.uniflow.android.ui.theme.Ok
import de.uniflow.android.ui.theme.Warn
import de.uniflow.core.AnnotationDocument
import de.uniflow.core.ApiError
import de.uniflow.core.LibraryFile
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Geoeffnete PDF-Datei mit Seitenbildern; `close` gibt den Renderer frei. Zugriffe auf den Renderer sind serialisiert. */
private class PageRenderer(file: File) {
    private val renderer = PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY))
    val pageCount: Int get() = renderer.pageCount

    /** Seite (1-basiert) als Bild mit Seitenmass in PDF-Punkten; null bei unbrauchbaren Massen (kein Bild der Groesse 0). */
    fun render(index: Int, scale: Float = 2f): Pair<Bitmap, Pair<Float, Float>>? = synchronized(renderer) {
        renderer.openPage(index - 1).use { page ->
            val w = page.width.toFloat(); val h = page.height.toFloat()
            if (!InkMath.validPageSize(w, h)) return null
            val bmp = Bitmap.createBitmap((w * scale).toInt(), (h * scale).toInt(), Bitmap.Config.ARGB_8888)
            bmp.eraseColor(android.graphics.Color.WHITE)
            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            bmp to (w to h)
        }
    }

    fun close() { runCatching { renderer.close() } }
}

/**
 * PDF-Seite mit Stift-Notizen. Die Striche liegen im gemeinsamen Notizformat (PDF-Punkte); gespeichert wird mit
 * base_version, Konflikte werden zusammengefuehrt (AnnotationStore). Eine aeltere Serverantwort ersetzt nie den
 * lokalen, ungesendeten Stand: AnnotationSession behaelt ihn, bis das Senden bestaetigt ist, und serialisiert alle
 * Speichervorgaenge (Seitenwechsel, Verlassen, App im Hintergrund). Objekte anderer Art (Text, Formen, Bilder) werden
 * hier nicht gezeichnet, bleiben aber im Dokument und damit beim Speichern erhalten.
 */
@Composable
fun DocumentScreen(repo: Repo, fileId: String, onBack: () -> Unit) {
    // Alles je Datei-ID: eine andere Datei beginnt mit leerem Zustand, nie mit Seiten oder Strichen der vorigen.
    // Entwuerfe liegen im App-Speicher (DraftStore), die Nachlieferung uebernimmt WorkManager (DraftUploadWorker).
    val appContext = LocalContext.current.applicationContext
    val session = remember(fileId) {
        AnnotationSession(fileId,
            send = { local, base, version -> repo.saveAnnotations(fileId, local, base, version) },
            drafts = DraftKeeper(repo.drafts, schedule = { DraftUploadWorker.enqueue(appContext, it) }, cancel = { DraftUploadWorker.cancel(appContext, it) }),
            draftScope = AppScope.main)
    }
    var file by remember(fileId) { mutableStateOf<LibraryFile?>(null) }
    var pages by remember(fileId) { mutableStateOf<PageRenderer?>(null) }
    var pageCount by remember(fileId) { mutableStateOf(0) }
    var pageIndex by remember(fileId) { mutableStateOf(1) }          // PDF-Seite, 1-basiert
    var bitmap by remember(fileId) { mutableStateOf<Bitmap?>(null) }
    var pageSizePt by remember(fileId) { mutableStateOf(InkMath.A4) }
    var loadError by remember(fileId) { mutableStateOf<String?>(null) }
    var sourceHint by remember(fileId) { mutableStateOf<String?>(null) }   // „Direkt von Stud.IP geladen“ nach einem Direkt-Download
    var loadTick by remember(fileId) { mutableStateOf(0) }           // „Erneut versuchen“
    var leaveArmed by remember(fileId) { mutableStateOf(false) }     // zweites „Zurück“ nach fehlgeschlagenem Speichern
    var tool by remember { mutableStateOf(InkTool.Pen) }
    var stylusOnly by remember { mutableStateOf(false) }
    var current by remember(fileId) { mutableStateOf<List<Offset>>(emptyList()) }
    val scope = rememberCoroutineScope()

    suspend fun showPage(index: Int) {
        val r = pages ?: return
        val out = withContext(Dispatchers.IO) { runCatching { r.render(index) } }
        val rendered = out.getOrNull()
        if (rendered == null) {
            session.status = "Seite $index kann nicht angezeigt werden" + (out.exceptionOrNull()?.message?.let { ": $it" } ?: " (Seitenmaß unbrauchbar)")
            return
        }
        bitmap = rendered.first; pageSizePt = rendered.second; pageIndex = index
    }

    LaunchedEffect(fileId, loadTick) {
        loadError = null
        var opened: PageRenderer? = null
        try {
            val lib = repo.library().value          // frisch oder aus der Ablage (offline: Dateiliste vom letzten Mal, PDF aus dem Cache)
            val f = lib.files.firstOrNull { it.id == fileId } ?: throw ApiError(404, "not_found", "Datei nicht gefunden")
            file = f
            val got = repo.pdf(f)
            val pf = got.file
            sourceHint = UniversityRules.sourceHint(got.directFrom)
            opened = withContext(Dispatchers.IO) {
                try { PageRenderer(pf) }
                catch (e: Exception) { repo.discardPdf(pf); throw ApiError(0, "pdf_invalid", "PDF kann nicht geöffnet werden: ${e.message}") }   // naechster Versuch laedt neu
            }
            // Entwurf vom letzten Mal (ungesendet) wird mit dem Serverstand zusammengefuehrt und gleich gesendet
            session.loaded(repo.loadAnnotations(fileId), repo.loadDraft(fileId))
            pages?.close(); pages = opened; pageCount = opened.pageCount
            showPage(1)
            if (session.dirty) session.save()
        } catch (e: CancellationException) {
            opened?.close(); throw e
        } catch (e: Exception) {
            // Scheitert ein Schritt nach dem Oeffnen (z. B. Notizen laden), bleibt kein Renderer offen; „Erneut versuchen“ laedt alles neu
            opened?.close(); pages?.close(); pages = null; bitmap = null; pageCount = 0
            loadError = e.message ?: e.toString()
        }
    }
    DisposableEffect(session) {
        onDispose {
            session.flush(AppScope.main)      // letztes Senden ueberlebt die Ansicht (der Scope der Ansicht wird gleich beendet)
            pages?.close(); pages = null
        }
    }
    // App in den Hintergrund: Entwurf ablegen, Nachlieferung einplanen (WorkManager), senden – beendet das System die App, holt der Worker nach
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { session.flush(AppScope.main) }

    /** Zurueck: erst speichern. Klappt das nicht, bleibt die Ansicht mit der Meldung; ein zweites „Zurück“ verlaesst sie trotzdem (Senden im Hintergrund). */
    fun leave() {
        scope.launch {
            if (!session.dirty || leaveArmed || session.save()) onBack()
            else { leaveArmed = true; session.status = session.status + " – noch einmal „Zurück“ verlässt die Seite, gesendet wird im Hintergrund weiter" }
        }
    }
    BackHandler(enabled = session.dirty) { leave() }

    fun goTo(index: Int) {
        if (session.saving) return                 // Seitenwechsel waehrend des Sendens gesperrt
        scope.launch { if (index in 1..pageCount) { session.save(); showPage(index) } }
    }

    val pageKey = AnnotationDocument.keyForPdfPage(session.doc, pageIndex)
    val pageObjects = AnnotationDocument.objects(session.doc, pageKey)
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { leave() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Zurück") }
            Text(file?.title ?: "Dokument", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), maxLines = 1)
            TextButton(onClick = { scope.launch { session.save() } }, enabled = session.dirty && !session.saving) {
                Text(if (session.saving) "Speichert …" else if (session.dirty) "Speichern" else "Gespeichert")
            }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp)) {
            InkTool.entries.forEach { t ->
                FilterChip(selected = tool == t, onClick = { tool = t }, label = { Text(t.label) }, modifier = Modifier.padding(end = 6.dp))
            }
            FilterChip(selected = stylusOnly, onClick = { stylusOnly = !stylusOnly }, label = { Text("Nur Stift") })
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(enabled = pageIndex > 1 && !session.saving, onClick = { goTo(pageIndex - 1) }) { Text("◀ Seite") }
            Text(if (pageCount > 0) "Seite $pageIndex / $pageCount" else "", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            TextButton(enabled = pageIndex < pageCount && !session.saving, onClick = { goTo(pageIndex + 1) }) { Text("Seite ▶") }
        }
        Text(session.status, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp),
            color = when {
                session.status.startsWith("Nicht") || session.status.startsWith("Seite") -> Bad
                session.status.startsWith("Konflikt") || session.status.startsWith("Entwurf") -> Warn
                else -> Ok
            })
        // Stand des Entwurfs: gespeichert / wird gesendet / gesendet / Konflikt
        session.draftState.label?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp),
                color = if (session.draftState == AnnotationSession.DraftState.Conflict) Warn else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        InkMath.foreignHint(InkMath.foreignCount(pageObjects))?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = Warn, modifier = Modifier.padding(horizontal = 12.dp))
        }
        sourceHint?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Ok, modifier = Modifier.padding(horizontal = 12.dp)) }

        val err = loadError
        val bmp = bitmap
        if (err != null) {
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Fehler: $err", color = Bad)
                Button(onClick = { loadTick++ }, modifier = Modifier.padding(top = 12.dp)) { Text("Erneut versuchen") }
            }
        } else if (bmp != null) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                val ratio = InkMath.pageRatio(pageSizePt.first, pageSizePt.second)
                Canvas(Modifier.fillMaxWidth().aspectRatio(ratio).pointerInput(tool, stylusOnly, pageKey) {
                    awaitPointerEventScope {
                        while (true) {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            // „Nur Stift“: Finger wird nicht verarbeitet und nicht verbraucht, damit er die Seite scrollen kann (wie pen_only im Web)
                            if (stylusOnly && down.type != PointerType.Stylus) continue
                            val scale = size.width / pageSizePt.first
                            if (!(scale > 0f && scale.isFinite())) continue
                            if (tool == InkTool.Eraser) {
                                var pos = down.position
                                while (true) {
                                    val hits = InkMath.strokesNear(AnnotationDocument.objects(session.doc, pageKey), pos.x / scale, pos.y / scale, 6f)
                                    if (hits.isNotEmpty()) session.edit { d -> hits.fold(d) { acc, id -> AnnotationDocument.removeObject(acc, pageKey, id) } }
                                    val ev = awaitPointerEvent(); val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                                    if (!ch.pressed) break
                                    pos = ch.position; ch.consume()
                                }
                                continue
                            }
                            val pts = ArrayList<Offset>(); pts += down.position; current = pts.toList()
                            down.consume()
                            while (true) {
                                val ev = awaitPointerEvent(); val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                                if (!ch.pressed) break
                                pts += ch.position; ch.consume(); current = pts.toList()
                            }
                            val thin = InkMath.thin(pts.map { it.x to it.y })
                            if (thin.isNotEmpty()) {
                                val points = InkMath.asStroke(InkMath.toPoints(thin, scale))     // einzelner Tipp -> kurzer Strich
                                val stroke = AnnotationDocument.stroke(points, tool.key, tool.color, tool.width, tool.opacity)
                                session.edit { d -> AnnotationDocument.addObject(d, pageKey, stroke) }
                            }
                            current = emptyList()
                        }
                    }
                }) {
                    val scale = size.width / pageSizePt.first
                    drawImage(bmp.asImageBitmap(), dstSize = IntSize(size.width.toInt(), size.height.toInt()))
                    for (o in pageObjects) {
                        val obj = o as? JsonObject ?: continue
                        if (!InkMath.isStroke(obj)) continue
                        val p = AnnotationDocument.strokePoints(obj)
                        val w = InkMath.strokeWidth(InkMath.num(obj, "width")) * scale
                        val alpha = InkMath.opacity(InkMath.num(obj, "opacity"))
                        val color = Color(InkMath.parseColor((obj["color"] as? JsonPrimitive)?.content))
                        if (p.size == 2) { drawCircle(color, radius = w / 2, center = Offset(p[0] * scale, p[1] * scale), alpha = alpha); continue }
                        if (p.size < 4) continue
                        val path = Path().apply { moveTo(p[0] * scale, p[1] * scale); for (i in 2 until p.size - 1 step 2) lineTo(p[i] * scale, p[i + 1] * scale) }
                        drawPath(path, color, alpha = alpha, style = Stroke(width = w, cap = StrokeCap.Round, join = StrokeJoin.Round))
                    }
                    if (current.isNotEmpty() && tool != InkTool.Eraser) {
                        val path = Path().apply { moveTo(current[0].x, current[0].y); current.drop(1).forEach { lineTo(it.x, it.y) } }
                        if (current.size == 1) path.lineTo(current[0].x + 0.1f, current[0].y + 0.1f)
                        drawPath(path, Color(InkMath.parseColor(tool.color)), alpha = tool.opacity, style = Stroke(width = tool.width * scale, cap = StrokeCap.Round, join = StrokeJoin.Round))
                    }
                }
            }
        }
    }
}
