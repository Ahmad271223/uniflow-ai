import Foundation
import PDFKit
import UIKit
import UniFlowCore
import Vision

// Notizen und Blaetter mitschicken (Wunsch des Inhabers 05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md):
// Seitennotizen (Leerseiten hinter einer Folie) und Seiten des Blatts daneben gehen bei PDF-Export, "Abgeben",
// "Lösung teilen" und in der KI-Hilfe mit, direkt hinter der Folie, neben der sie geschrieben wurden.

/// Blaetter daneben eines Dokuments lesen (nur lesen, nie schreiben).
@MainActor
enum SideSheetLoader {
    /// Ein gelesenes Blatt mit den Bildern seiner Seiten
    struct Part {
        let sheet: SideNotes.Sheet
        let images: [String: UIImage]
    }

    /// Blaetter zu `store`: alle verknuepften Notizbuecher (`sideSheets`, nur die in `only`, wenn angegeben) und das
    /// gerade daneben offene Notizbuch `open`, wenn es verknuepft ist oder zum selben Modul gehoert. Ein Blatt, das in
    /// einem Fenster offen ist, wird ueber dessen Store gelesen; sonst kurz geoeffnet und wieder freigegeben. Was sich
    /// nicht lesen laesst (geloescht, kein Notizbuch), bleibt still weg.
    static func sheets(for store: DocumentStore, api: APIClient, open: DocumentStore? = nil, only: Set<String>? = nil,
                       excluding: Set<String> = [], loadImage: ShareExport.ImageLoader?) async -> [Part] {
        var ids = candidateIDs(for: store, open: open)
        if let only { ids = ids.filter(only.contains) }
        ids.removeAll(where: excluding.contains)
        var out: [Part] = []
        for id in ids where id != store.file.id {
            if let part = await read(id, api: api, root: store.dataRoot, open: open, loadImage: loadImage) { out.append(part) }
        }
        return out
    }

    /// Verknuepfte Blaetter (`sideSheets`) und das gerade daneben offene Notizbuch, wenn es verknuepft ist oder zum
    /// selben Modul gehoert, in dieser Reihenfolge
    static func candidateIDs(for store: DocumentStore, open: DocumentStore?) -> [String] {
        var ids = store.sideSheetFileIDs
        if let open, open.isNotebook, open.file.id != store.file.id, !ids.contains(open.file.id),
           open.file.module_id == store.file.module_id {
            ids.append(open.file.id)
        }
        return ids.filter { $0 != store.file.id }
    }

    /// Ein Blatt daneben, wie es Druck, Export und "Daneben öffnen" nennen: Titel, zuletzt bearbeitet, im Papierkorb
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        /// zuletzt geoeffnet bzw. angelegt (ISO), fuer die Anzeige
        let edited: String?
        /// im Papierkorb: geht nirgends mit, laesst sich unter "Daneben öffnen" wiederherstellen
        let trashed: Bool

        /// "zuletzt offen am 13.11., 09:40" (nur mit lesbarem Datum)
        var editedLabel: String? {
            guard let edited, let d = Fmt.dateTime(edited) else { return nil }
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.dateFormat = "dd.MM., HH:mm"
            return "zuletzt offen am \(f.string(from: d))"
        }
    }

    /// Blaetter daneben eines Dokuments (Fehlerbericht des Inhabers 13.11.2026: ein altes Blatt erschien beim Drucken,
    /// war in der App aber nirgends zu finden). Verknuepfte Blaetter und das offene; geloeschte Dateien fallen weg,
    /// solche im Papierkorb bleiben mit `trashed` (wiederherstellbar).
    static func entries(for store: DocumentStore, api: APIClient, open: DocumentStore? = nil) async -> [Entry] {
        var out: [Entry] = []
        for id in candidateIDs(for: store, open: open) {
            if let e = await entry(id, api: api) { out.append(e) }
        }
        return out
    }

    /// Ein Blatt nach seiner ID: nil, wenn es die Datei nicht (mehr) gibt oder sie kein Notizbuch ist
    static func entry(_ id: String, api: APIClient) async -> Entry? {
        guard let meta = try? await api.value("/api/files/\(id)"), let kind = meta.s("kind"),
              kind == "notebook" || kind == "whiteboard" else { return nil }
        let title = meta.s("ai_title") ?? meta.s("title") ?? meta.s("name") ?? "Blatt"
        return Entry(id: id, title: title, edited: meta.s("last_opened") ?? meta.s("downloaded_at"),
                     trashed: !(meta.s("deleted_at") ?? "").isEmpty)
    }

    private static func read(_ id: String, api: APIClient, root: URL, open: DocumentStore?, loadImage: ShareExport.ImageLoader?) async -> Part? {
        if let open, open.file.id == id { return await part(of: open, loadImage: loadImage) }
        // Blatt im Papierkorb geht nirgends mit (vorher druckte "Drucken" ein geloeschtes Blatt mit, 13.11.2026)
        guard let meta = try? await api.value("/api/files/\(id)"), (meta.s("deleted_at") ?? "").isEmpty else { return nil }
        if let shown = OpenDocuments.shared.openStore(fileID: id, namespace: api.namespace), shown.pdf != nil {
            return await part(of: shown, loadImage: loadImage)
        }
        guard let file = try? await api.json("/api/files/\(id)", as: LibFile.self), file.isNotebook else { return nil }
        let temp = DocumentStore(file: file, api: api, root: root)
        temp.setShown(false)
        await temp.load()
        defer { Task { await temp.closeAfterReading() } }
        guard temp.errorMessage == nil, temp.pdf != nil else { return nil }
        return await part(of: temp, loadImage: loadImage)
    }

    private static func part(of s: DocumentStore, loadImage: ShareExport.ImageLoader?) async -> Part? {
        guard s.isNotebook else { return nil }
        let doc = SolutionSharing.withObjectsForLegacyStrokes(await s.pageStructureDocument())
        let keys = doc.pageOrder.compactMap { $0["key"]?.string }
        let loaded = await ShareExport.completeImages(s.images, sources: SolutionBuilder.imageSources(doc, keys: keys), load: loadImage)
        return Part(sheet: SideNotes.Sheet(fileID: s.file.id, document: doc), images: loaded.images)
    }
}

/// PDF mit Notizen fuer Export, Teilen-Menue und "Abgeben" in Stud.IP: EINE Funktion fuer alle Wege nach draussen.
enum NotesExport {
    struct Options: Sendable, Equatable {
        /// `.page(i)`: angezeigte Seite i (0-basiert) mit ihren Notizseiten
        var scope: ShareScope = .document
        /// Blaetter daneben mitschicken ("Notizen und Blätter mitschicken")
        var includeSideNotes = true
        /// leere Seitennotizen und Blattseiten weglassen (nur ganzes Dokument; reine Notizbuecher bleiben ganz)
        var skipEmptyNotePages = true
        /// Dateiname ohne ".pdf" (Standard: Titel des Dokuments)
        var fileStem: String?
        /// Unterordner in `AppTemp` (z. B. "abgabe"); der vorige Inhalt dieses Ordners wird entfernt
        var folder = "teilen"
        /// Blaetter daneben, die diesmal nicht mitgehen (im Hinweis vor Drucken, Sichern, Teilen abgewaehlt)
        var excludedSheets: Set<String> = []

        init(scope: ShareScope = .document, includeSideNotes: Bool = true, skipEmptyNotePages: Bool = true,
             fileStem: String? = nil, folder: String = "teilen") {
            self.scope = scope
            self.includeSideNotes = includeSideNotes
            self.skipEmptyNotePages = skipEmptyNotePages
            self.fileStem = fileStem
            self.folder = folder
        }
    }

    struct Result: Sendable, Equatable {
        /// fertige PDF im `AppTemp`-Ordner
        let url: URL
        let payload: SharePayload
        /// davon Seitennotizen und Blattseiten
        let notePages: Int
    }

    /// Dokument fuer den Export: Notizmodell mit den Blattseiten hinter ihrer Folie, die angezeigten Seiten dazu und
    /// die Bilder (eigene und die der Blaetter)
    @MainActor
    /// - Parameter open: gerade daneben offenes Blatt (geht mit, auch wenn noch nicht verknuepft; wie "Lösung teilen")
    static func exportDocument(for store: DocumentStore, api: APIClient?, options: Options, open: DocumentStore? = nil) async throws
        -> (document: AnnotationDocument, layout: DisplayLayout, indices: [Int], images: [String: UIImage]) {
        await store.flush()
        await open?.flush()
        guard store.originalPDF != nil else { throw ShareExportError.notLoaded }
        let main = SolutionSharing.withObjectsForLegacyStrokes(await store.pageStructureDocument())
        let loader = api.map(ShareExport.serverImageLoader)
        let parts = options.includeSideNotes && api != nil
            ? await SideSheetLoader.sheets(for: store, api: api!, open: open, excluding: options.excludedSheets, loadImage: loader) : []
        let wholeDocument = options.scope == .document
        let merged = SideNotes.interleaved(main: main, sheets: parts.map(\.sheet),
                                           skipEmptyNotePages: options.skipEmptyNotePages && wholeDocument)
        guard let layout = store.displayLayout(for: merged) else { throw ShareExportError.notLoaded }
        var indices: [Int]
        switch options.scope {
        case .document:
            guard layout.pdf.pageCount > 0 else { throw ShareExportError.notLoaded }
            indices = Array(0..<layout.pdf.pageCount)
        case .page(let i):
            guard let key = store.pageKey(forPageIndex: i), let at = layout.index(ofKey: key) else {
                throw ShareExportError.pageOutOfRange(i)
            }
            let notes = options.includeSideNotes ? SideNotes.notePages(merged, of: key) : []
            indices = [at] + notes.compactMap(layout.index(ofKey:))
        }
        var images = store.images
        for p in parts { images.merge(p.images) { mine, _ in mine } }
        let keys = indices.compactMap(layout.key(at:))
        let loaded = await ShareExport.completeImages(images, sources: SolutionBuilder.imageSources(merged, keys: keys), load: loader)
        return (merged, layout, indices, loaded.images)
    }

    /// PDF mit Notizen; Seitennotizen und Blattseiten direkt hinter ihrer Folie (docs/NOTIZEN-MITSCHICKEN-2026-11-05.md).
    /// `store` muss geladen sein; ausstehende Striche werden vorher verarbeitet. Bilder werden nachgeladen
    /// (Zeitlimit), was fehlt, steht in `payload.missingImages`.
    @MainActor
    static func pdf(for store: DocumentStore, api: APIClient, options: Options = Options(), open: DocumentStore? = nil) async throws -> Result {
        let (doc, layout, indices, images) = try await exportDocument(for: store, api: api, options: options, open: open)
        var pages: [String: JSONValue] = [:]
        var missing = 0
        for i in indices {
            guard let key = layout.key(at: i) else { continue }
            let objects = doc.objects(page: key)
            pages[key] = .object(["objects": .array(objects)])
            missing += objects.filter { o in
                o["type"]?.string == "image" && (o["src"]?.string).map { !$0.isEmpty && images[$0] == nil } == true
            }.count
        }
        let title = ShareExport.cleanTitle(options.fileStem ?? store.file.displayTitle)
        let data = PDFExporter.render(layout: layout, pages: pages, images: images, pageIndices: indices, title: title)
        let sorted = indices.sorted()
        let payload = SharePayload(pdf: data, title: title, fileID: store.file.id, moduleID: store.file.module_id,
                                   module: store.file.subject, pageRange: (sorted[0] + 1)...(sorted[sorted.count - 1] + 1),
                                   createdAt: Date(), missingImages: missing)
        let url = try AppTemp.fresh(options.folder).appendingPathComponent(payload.fileName)
        try payload.pdf.write(to: url, options: .atomic)
        // Seitennotizen und Blattseiten unter den exportierten Seiten
        let exported = Set(indices.compactMap(layout.key(at:)))
        var notePages = 0, sawPDF = false
        for e in doc.pageOrder {
            let type = e["type"]?.string ?? "pdf"
            if type == "pdf" { sawPDF = true; continue }
            if let k = e["key"]?.string, exported.contains(k), SideNotes.isSheetKey(k) || (sawPDF && type == "blank") { notePages += 1 }
        }
        return Result(url: url, payload: payload, notePages: notePages)
    }
}

extension SolutionSource {
    /// Mit Seitennotizen und Blattseiten hinter ihrer Folie (`SideNotes.interleaved`); Bilder der Blaetter eingebettet
    func withSideNotes(_ parts: [SideSheetLoader.Part]) async -> SolutionSource {
        guard !parts.isEmpty else { return self }
        var more: [String: UIImage] = [:]
        for p in parts { more.merge(p.images) { mine, _ in mine } }
        let sendable = SendableImages(more)
        let embedded = await Task.detached(priority: .userInitiated) { SolutionSharing.embed(sendable.images) }.value
        return SolutionSource(document: SideNotes.interleaved(main: document, sheets: parts.map(\.sheet)),
                              originalPDF: originalPDF, pdfPageCount: pdfPageCount, pageInfos: pageInfos,
                              fingerprint: fingerprint, images: images.merging(embedded) { mine, _ in mine }, title: title)
    }
}

private struct SendableImages: @unchecked Sendable {
    let images: [String: UIImage]
    init(_ images: [String: UIImage]) { self.images = images }
}

/// Notizen einer Folie fuer die KI-Hilfe: Seitennotizen dahinter und Blattseiten daneben als Text (Textfelder und
/// Haftnotizen direkt, Handschrift mit Vision erkannt, auf dem Geraet). Leer, wenn die Folie keine Notizseiten hat.
@MainActor
enum AttachedNotes {
    /// Erkannter Text je Seite und Inhalt (Signatur der Objekte), damit Rueckfragen nicht erneut erkennen
    private static var recognized: [Int: String] = [:]

    /// - Parameter pageKey: angezeigte Seite; bei einer Seitennotiz gilt ihre Folie
    static func text(for store: DocumentStore, pageKey: String?, api: APIClient?, open: DocumentStore? = nil) async -> String {
        guard let pageKey, store.originalPDF != nil, !store.isNotebook else { return "" }
        let main = await store.pageStructureDocument()
        let slide = owner(main, pageKey) ?? pageKey
        // nur Blaetter laden, die zu dieser Folie etwas haben (Seitennotizen dahinter und Blattseiten daneben)
        let group = Set([slide] + SideNotes.notePages(main, of: slide))
        let linked = Set(SideNotes.links(main).filter { $0.value.values.contains(where: group.contains) }.keys)
        var parts: [SideSheetLoader.Part] = []
        if let api, !linked.isEmpty {
            parts = await SideSheetLoader.sheets(for: store, api: api, open: open, only: linked, loadImage: nil)
        }
        let merged = SideNotes.interleaved(main: SolutionSharing.withObjectsForLegacyStrokes(main), sheets: parts.map(\.sheet))
        var blocks: [String] = []
        for key in SideNotes.notePages(merged, of: slide) {
            let objects = merged.objects(page: key)
            guard !objects.isEmpty else { continue }
            var lines: [String] = []
            let typed = SideNotes.typedText(merged, keys: [key])
            if !typed.isEmpty { lines.append(typed) }
            let ink = await handwriting(objects, entry: merged.pageOrder.first { $0["key"]?.string == key })
            if !ink.isEmpty { lines.append(ink) }
            guard !lines.isEmpty else { continue }
            let label = SideNotes.isSheetKey(key) ? "Blatt daneben" : "Seitennotiz"
            blocks.append("[\(label) \(blocks.count + 1)]\n" + lines.joined(separator: "\n"))
        }
        return String(blocks.joined(separator: "\n\n").prefix(SideNotes.aiNotesChars))
    }

    /// PDF-Seite, zu der eine Seite gehoert (sie selbst oder die letzte PDF-Seite davor)
    static func owner(_ doc: AnnotationDocument, _ key: String) -> String? {
        let order = doc.pageOrder
        guard let i = order.firstIndex(where: { $0["key"]?.string == key }) else { return nil }
        for e in order[...i].reversed() where (e["type"]?.string ?? "pdf") == "pdf" { return e["key"]?.string }
        return nil
    }

    /// Handschrift einer Seite erkennen: Striche und Formen auf weissem Grund (ohne Vorlage und Textfelder), Vision
    /// mit Deutsch und Englisch
    static func handwriting(_ objects: [JSONValue], entry: JSONValue?) async -> String {
        let ink = objects.filter { ["stroke", "shape"].contains($0["type"]?.string ?? "") }
        guard !ink.isEmpty else { return "" }
        var h = Hasher()
        h.combine(ink)
        let sig = h.finalize()
        if let hit = recognized[sig] { return hit }
        let (w, hgt) = PageOrder.blankSize(entry ?? .object([:]))
        let size = CGSize(width: w, height: hgt)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            PageRenderer.drawObjects(ink, images: [:], in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return "" }
        let box = CGImageBox(cg)
        let text = await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = VisionPageOCR.languages
            do { try VNImageRequestHandler(cgImage: box.image, options: [:]).perform([request]) } catch { return "" }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
        recognized[sig] = text
        return text
    }
}

private struct CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
