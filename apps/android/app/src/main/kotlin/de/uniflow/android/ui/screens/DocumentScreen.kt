package de.uniflow.android.ui.screens

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
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
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import de.uniflow.android.InkMath
import de.uniflow.android.InkTool
import de.uniflow.android.Repo
import de.uniflow.android.ui.theme.Bad
import de.uniflow.android.ui.theme.Ok
import de.uniflow.core.AnnotationDocument
import de.uniflow.core.ApiError
import de.uniflow.core.LibraryFile
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * PDF-Seite mit Stift-Notizen. Die Striche liegen im gemeinsamen Notizformat (PDF-Punkte); gespeichert wird mit
 * base_version, Konflikte werden zusammengefuehrt (AnnotationStore). Eine aeltere Serverantwort ersetzt nie den
 * lokalen, ungesendeten Stand: `doc` bleibt, bis `save` bestaetigt hat.
 */
@Composable
fun DocumentScreen(repo: Repo, fileId: String, onBack: () -> Unit) {
    var file by remember { mutableStateOf<LibraryFile?>(null) }
    var pdf by remember { mutableStateOf<File?>(null) }
    var pageCount by remember { mutableStateOf(0) }
    var pageIndex by remember { mutableStateOf(1) }          // PDF-Seite, 1-basiert
    var bitmap by remember { mutableStateOf<Bitmap?>(null) }
    var pageSizePt by remember { mutableStateOf(595f to 842f) }
    var doc by remember { mutableStateOf(AnnotationDocument.empty()) }
    var base by remember { mutableStateOf<JsonObject?>(null) }
    var baseVersion by remember { mutableStateOf(0) }
    var dirty by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf("Lade …") }
    var tool by remember { mutableStateOf(InkTool.Pen) }
    var stylusOnly by remember { mutableStateOf(false) }
    var current by remember { mutableStateOf<List<Offset>>(emptyList()) }
    val scope = rememberCoroutineScope()
    val renderer = remember { mutableStateOf<PdfRenderer?>(null) }

    suspend fun renderPage(index: Int) {
        val r = renderer.value ?: return
        withContext(Dispatchers.IO) {
            synchronized(r) {
                r.openPage(index - 1).use { page ->
                    val scale = 2f
                    val bmp = Bitmap.createBitmap((page.width * scale).toInt(), (page.height * scale).toInt(), Bitmap.Config.ARGB_8888)
                    bmp.eraseColor(android.graphics.Color.WHITE)
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    pageSizePt = page.width.toFloat() to page.height.toFloat()
                    bitmap = bmp
                }
            }
        }
    }

    suspend fun save(): Boolean {
        if (!dirty) return true
        return try {
            val s = repo.saveAnnotations(fileId, doc, base, baseVersion)
            doc = s.doc; base = s.doc; baseVersion = s.version; dirty = false
            status = if (s.mergedConflicts > 0) "Gespeichert, ${s.mergedConflicts} Stellen zusammengeführt" else "Gespeichert (Version ${s.version})"
            true
        } catch (e: ApiError) { status = "Nicht gespeichert: ${e.message}"; false }
    }

    LaunchedEffect(fileId) {
        try {
            val lib = repo.library()
            val f = lib.files.firstOrNull { it.id == fileId } ?: throw ApiError(404, "not_found", "Datei nicht gefunden")
            file = f
            val pf = repo.pdfFile(f)
            pdf = pf
            val r = withContext(Dispatchers.IO) { PdfRenderer(ParcelFileDescriptor.open(pf, ParcelFileDescriptor.MODE_READ_ONLY)) }
            renderer.value = r
            pageCount = r.pageCount
            val loaded = repo.loadAnnotations(fileId)
            doc = loaded.doc; base = if (loaded.version > 0) loaded.doc else null; baseVersion = loaded.version
            renderPage(1)
            status = if (loaded.version > 0) "Notizen geladen (Version ${loaded.version})" else "Noch keine Notizen"
        } catch (e: Exception) { status = "Fehler: ${e.message}" }
    }
    DisposableEffect(fileId) {
        onDispose { scope.launch { save() }; renderer.value?.close(); renderer.value = null }
    }

    val pageKey = AnnotationDocument.keyForPdfPage(doc, pageIndex)
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            IconButton(onClick = { scope.launch { save(); onBack() } }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Zurück") }
            Text(file?.title ?: "Dokument", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), maxLines = 1)
            TextButton(onClick = { scope.launch { save() } }, enabled = dirty) { Text(if (dirty) "Speichern" else "Gespeichert") }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp)) {
            InkTool.entries.forEach { t ->
                FilterChip(selected = tool == t, onClick = { tool = t }, label = { Text(t.label) }, modifier = Modifier.padding(end = 6.dp))
            }
            FilterChip(selected = stylusOnly, onClick = { stylusOnly = !stylusOnly }, label = { Text("Nur Stift") })
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            TextButton(enabled = pageIndex > 1, onClick = { scope.launch { save(); pageIndex -= 1; renderPage(pageIndex) } }) { Text("◀ Seite") }
            Text(if (pageCount > 0) "Seite $pageIndex / $pageCount" else "", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            TextButton(enabled = pageIndex < pageCount, onClick = { scope.launch { save(); pageIndex += 1; renderPage(pageIndex) } }) { Text("Seite ▶") }
        }
        Text(status, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp),
            color = if (status.startsWith("Nicht") || status.startsWith("Fehler")) Bad else Ok)

        val bmp = bitmap
        if (bmp != null) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                val ratio = pageSizePt.first / pageSizePt.second
                Canvas(Modifier.fillMaxWidth().aspectRatio(ratio).pointerInput(tool, stylusOnly, pageKey) {
                    awaitPointerEventScope {
                        while (true) {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            if (stylusOnly && down.type != PointerType.Stylus) continue
                            val scale = size.width / pageSizePt.first
                            if (tool == InkTool.Eraser) {
                                var pos = down.position
                                while (true) {
                                    val hits = InkMath.strokesNear(AnnotationDocument.objects(doc, pageKey), pos.x / scale, pos.y / scale, 6f)
                                    if (hits.isNotEmpty()) { var d = doc; hits.forEach { d = AnnotationDocument.removeObject(d, pageKey, it) }; doc = d; dirty = true }
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
                            if (thin.size >= 2) {
                                val stroke = AnnotationDocument.stroke(InkMath.toPoints(thin, scale), tool.key, tool.color, tool.width, tool.opacity)
                                doc = AnnotationDocument.addObject(doc, pageKey, stroke); dirty = true
                            }
                            current = emptyList()
                        }
                    }
                }) {
                    val scale = size.width / pageSizePt.first
                    drawImage(bmp.asImageBitmap(), dstSize = IntSize(size.width.toInt(), size.height.toInt()))
                    for (o in AnnotationDocument.objects(doc, pageKey)) {
                        val obj = o as? JsonObject ?: continue
                        if ((obj["type"] as? JsonPrimitive)?.content != "stroke") continue
                        val p = AnnotationDocument.strokePoints(obj)
                        if (p.size < 4) continue
                        val path = Path().apply { moveTo(p[0] * scale, p[1] * scale); for (i in 2 until p.size step 2) lineTo(p[i] * scale, p[i + 1] * scale) }
                        val w = ((obj["width"] as? JsonPrimitive)?.content?.toFloatOrNull() ?: 2f) * scale
                        val alpha = (obj["opacity"] as? JsonPrimitive)?.content?.toFloatOrNull() ?: 1f
                        drawPath(path, Color(InkMath.parseColor((obj["color"] as? JsonPrimitive)?.content)), alpha = alpha,
                            style = Stroke(width = w, cap = StrokeCap.Round, join = StrokeJoin.Round))
                    }
                    if (current.size >= 2 && tool != InkTool.Eraser) {
                        val path = Path().apply { moveTo(current[0].x, current[0].y); current.drop(1).forEach { lineTo(it.x, it.y) } }
                        drawPath(path, Color(InkMath.parseColor(tool.color)), alpha = tool.opacity, style = Stroke(width = tool.width * scale, cap = StrokeCap.Round, join = StrokeJoin.Round))
                    }
                }
            }
        }
    }
}
