import Foundation
import Network
import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Ordner im App-Container.
enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UniFlow", isDirectory: true)
    }
    /// Journal aller Dokumente (Seiten, Revisionen, Basis fuer Konflikte).
    static var journal: URL { support.appendingPathComponent("journal", isDirectory: true) }
    static func pdf(_ fileID: String) -> URL {
        support.appendingPathComponent("pdf", isDirectory: true).appendingPathComponent(LocalJournalName.safe(fileID) + ".pdf")
    }
}

enum LocalJournalName {
    static func safe(_ s: String) -> String {
        let ok = s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        return ok && !s.isEmpty ? s : s.utf8.map { String(format: "%02x", $0) }.joined()
    }
}

/// Umrechnung PencilKit <-> Seiten-JSON abseits des Hauptthreads, mit gemerkter Strich-Identitaet je Seite.
actor InkProcessor {
    private var states: [String: InkPageState] = [:]

    func drawing(key: String, page: JSONValue?) -> DrawingBox {
        let (d, state) = StrokeConverter.drawing(fromPage: page)
        states[key] = state
        return DrawingBox(drawing: d)
    }

    func page(key: String, drawing: DrawingBox, previous: JSONValue?) -> JSONValue {
        let state: InkPageState
        if let s = states[key] { state = s } else { state = StrokeConverter.drawing(fromPage: previous).1 }
        let (page, next) = StrokeConverter.page(from: drawing.drawing, previous: previous, state: state)
        states[key] = next
        return page
    }
}

/// Lesezeichen (gleiches Feld `bookmarks` wie im Web-Editor).
struct Bookmark: Identifiable, Equatable {
    let key: String
    let title: String
    var id: String { key }
}

/// Suchtreffer im PDF.
struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: String
    let selection: PDFSelection
}

/// Kennzahlen fuer die Dokumentinformation.
struct DocumentInfo {
    var title: String
    var fileName: String
    var subject: String?
    var folder: String?
    var displayPages: Int
    var pdfPages: Int
    var insertedPages: Int
    var removedPDFPages: [Int]
    var bookmarks: Int
    var unsentPages: Int
    var serverVersion: Int
    var status: String
}

/// Zustand eines geoeffneten Dokuments.
///
/// Ablauf beim Schreiben: Strich fertig -> `canvasChanged` merkt nur die neueste Zeichnung (Hauptthread, sofort
/// zurueck) -> nach 0,25 s Pause Umrechnung im `InkProcessor` -> `SyncEngine.updatePage` sichert lokal und laedt hoch.
/// Eingabe, Umrechnung, lokales Sichern und Upload laufen dadurch getrennt; ein Upload unterbricht nie einen Strich.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var layout: DisplayLayout?
    @Published private(set) var layoutVersion = 0
    @Published private(set) var status: SyncStatus = .loading
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var insertedPages = 0
    @Published private(set) var removedPDFPages: [Int] = []
    @Published private(set) var bookmarks: [Bookmark] = []

    var pdf: PDFDocument? { layout?.pdf }

    let file: LibFile
    private let api: APIClient
    private let engine: SyncEngine
    private let ink = InkProcessor()
    private var original: PDFDocument?
    private var document = AnnotationDocument.empty()
    private var structure = ""
    private var pendingDrawings: [String: DrawingBox] = [:]
    private var processing = false
    private var processTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lifecycle: [NSObjectProtocol] = []
    private(set) var images: [String: UIImage] = [:]
    private var loadingImages: Set<String> = []

    /// Seiten (Anzeige-Indizes), deren Inhalt sich durch den Server oder eine Zusammenfuehrung geaendert hat.
    var onPagesChanged: (([Int]) -> Void)?

    init(file: LibFile, api: APIClient) {
        self.file = file
        self.api = api
        let journal = LocalJournal(store: FileBlobStore(root: AppPaths.journal), documentID: file.id)
        self.engine = SyncEngine(documentID: file.id, transport: HTTPAnnotationTransport(api: api), journal: journal)
    }

    // MARK: Laden

    func load() async {
        do {
            let url = AppPaths.pdf(file.id)
            if !FileManager.default.fileExists(atPath: url.path) {
                let (data, http) = try await api.data("/api/files/\(file.id)/content")
                guard http.statusCode == 200, data.starts(with: Array("%PDF".utf8)) else {
                    throw APIError(status: http.statusCode, message: "Keine PDF-Datei erhalten")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            guard let pdfDocument = PDFDocument(url: url) else {
                throw APIError(status: 0, message: "PDF lässt sich nicht öffnen")
            }
            original = pdfDocument
            await engine.setHandlers(
                onStatus: { [weak self] s in Task { @MainActor in self?.status = s } },
                onRemoteChange: { [weak self] keys in Task { @MainActor in await self?.remoteChanged(keys) } })
            let opened = await engine.open(pdfPageCount: pdfDocument.pageCount)
            apply(document: opened.document, forceLayout: true)
            if !opened.damagedFiles.isEmpty {
                notice = "\(opened.damagedFiles.count) lokale Datei(en) beschädigt – Serverstand verwendet, wo möglich."
            } else if opened.restoredUnsentPages > 0 {
                notice = "\(opened.restoredUnsentPages) ungesendete Seite(n) wiederhergestellt."
            }
            startMonitoring()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Neuen Modellstand uebernehmen; Anzeige-PDF nur neu aufbauen, wenn sich die Seitenstruktur geaendert hat.
    private func apply(document doc: AnnotationDocument, forceLayout: Bool = false) {
        document = doc
        insertedPages = doc.insertedPageCount
        bookmarks = (doc.root["bookmarks"]?.array ?? []).compactMap { b in
            guard let k = b["key"]?.string else { return nil }
            return Bookmark(key: k, title: b["title"]?.string ?? "Lesezeichen")
        }
        guard let original else { return }
        removedPDFPages = doc.removedPDFIndices(pdfPageCount: original.pageCount)
        let sig = DisplayLayout.structureSignature(doc)
        if forceLayout || sig != structure || layout == nil {
            structure = sig
            layout = DisplayLayout.build(original: original, document: doc)
            layoutVersion += 1
        }
    }

    // MARK: Seiten und Zeichnungen

    func pageKey(forPageIndex index: Int) -> String? { layout?.key(at: index) }

    func entry(forPageIndex index: Int) -> DisplayLayout.Entry? { layout?.entry(at: index) }

    /// Zeichnung einer Seite (Anzeige-Index). Wird im Hintergrund aufgebaut.
    func drawing(forPageIndex index: Int) async -> PKDrawing {
        guard let key = pageKey(forPageIndex: index) else { return PKDrawing() }
        if let pending = pendingDrawings[key] { return pending.drawing }      // noch nicht verarbeitet: neuester Stand
        let page = await engine.page(key)
        return await ink.drawing(key: key, page: page).drawing
    }

    /// Text, Formen, Bilder einer Seite.
    func objects(forPageIndex index: Int) async -> [JSONValue] {
        guard let key = pageKey(forPageIndex: index) else { return [] }
        return (await engine.page(key))?["objects"]?.array ?? []
    }

    /// Bild eines Bildobjekts laden (ueber den Server, mit PIN). Ruft `done` auf, sobald es da ist.
    func loadImage(_ src: String, done: @escaping () -> Void) {
        guard images[src] == nil, !loadingImages.contains(src), src.hasPrefix("/") else { return }
        loadingImages.insert(src)
        Task {
            defer { loadingImages.remove(src) }
            guard let (data, http) = try? await api.data(src), http.statusCode == 200, let img = UIImage(data: data) else { return }
            images[src] = img
            done()
        }
    }

    /// Vom Editor nach jeder Aenderung einer Canvas. Kehrt sofort zurueck.
    func canvasChanged(pageIndex index: Int, drawing: PKDrawing) {
        guard let key = pageKey(forPageIndex: index) else {
            notice = "Seite \(index + 1) ist nicht mehr im Dokument – Striche dort werden nicht gespeichert."
            return
        }
        pendingDrawings[key] = DrawingBox(drawing: drawing)
        processTask?.cancel()
        processTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.processPending()
        }
    }

    /// Alles Ausstehende sofort verarbeiten (vor dem Schliessen, beim Wechsel in den Hintergrund).
    func flush() async {
        processTask?.cancel()
        await processPending()
        await engine.requestUpload()
    }

    private func processPending() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while let (key, box) = pendingDrawings.first {
            pendingDrawings.removeValue(forKey: key)
            let previous = await engine.page(key)
            let page = await ink.page(key: key, drawing: box, previous: previous)
            await engine.updatePage(key, page)
        }
    }

    private func remoteChanged(_ keys: [String]) async {
        apply(document: await engine.currentDocument())
        let indices = keys.compactMap { layout?.index(ofKey: $0) }
        if !indices.isEmpty { onPagesChanged?(indices) }
    }

    // MARK: Bearbeiten der Struktur (gleiches Format wie der Web-Editor)

    private func updateMeta(_ change: (inout [String: JSONValue]) -> Void) async {
        await processPending()
        var doc = await engine.currentDocument()
        var meta = doc.rootMeta.object ?? [:]
        change(&meta)
        await engine.updateRootMeta(.object(meta))
        doc = await engine.currentDocument()
        apply(document: doc)
    }

    func isBookmarked(pageIndex: Int) -> Bool {
        guard let key = pageKey(forPageIndex: pageIndex) else { return false }
        return bookmarks.contains { $0.key == key }
    }

    func toggleBookmark(pageIndex: Int) async {
        guard let key = pageKey(forPageIndex: pageIndex) else { return }
        await updateMeta { meta in
            var list = meta["bookmarks"]?.array ?? []
            if let i = list.firstIndex(where: { $0["key"]?.string == key }) { list.remove(at: i) }
            else { list.append(.object(["key": .string(key), "title": .string("Seite \(pageIndex + 1)")])) }
            meta["bookmarks"] = .array(list)
        }
    }

    /// Leere Seite nach der angegebenen Seite einfuegen (Vorlage: blank, lined, grid, dotted, mm, cornell).
    func addBlankPage(after index: Int, template: String) async {
        let size = layout?.pdf.page(at: index).map { PageGeometry(boxSize: $0.bounds(for: .cropBox).size, rotation: $0.rotation).pageSize }
            ?? CGSize(width: 595, height: 842)
        let key = "b" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11).lowercased()
        let afterKey = pageKey(forPageIndex: index)
        await engine.updatePage(key, .object(["objects": .array([]), "template": .string(template)]))
        await updateMeta { meta in
            var order = meta["pageOrder"]?.array ?? []
            let entry: JSONValue = .object(["key": .string(key), "type": "blank", "template": .string(template),
                                            "w": .number(Double(size.width)), "h": .number(Double(size.height))])
            if let afterKey, let i = order.firstIndex(where: { $0["key"]?.string == afterKey }) { order.insert(entry, at: i + 1) }
            else { order.append(entry) }
            meta["pageOrder"] = .array(order)
        }
    }

    /// Seite um 90 Grad drehen (wie "Drehen" im Web-Editor; Notizen behalten ihre Koordinaten).
    func rotatePage(_ index: Int) async {
        guard let key = pageKey(forPageIndex: index) else { return }
        await updateMeta { meta in
            var order = meta["pageOrder"]?.array ?? []
            guard let i = order.firstIndex(where: { $0["key"]?.string == key }) else { return }
            let r = (order[i]["rotation"]?.int ?? 0) + 90
            order[i]["rotation"] = .number(Double(DisplayLayout.normalized(r)))
            meta["pageOrder"] = .array(order)
        }
    }

    /// Textfeld auf der Seite anlegen (im Web-Editor bearbeitbar).
    func addText(_ text: String, pageIndex: Int) async {
        guard let key = pageKey(forPageIndex: pageIndex), !text.isEmpty else { return }
        await processPending()
        var page = (await engine.page(key)) ?? .object(["objects": .array([])])
        var objects = page["objects"]?.array ?? []
        objects.append(.object([
            "id": .string(StrokeConverter.newID()), "type": "text", "text": .string(text),
            "x": 40, "y": .number(40 + Double(objects.filter { $0["type"]?.string == "text" }.count % 10) * 30),
            "fontFamily": "Arial", "fontSize": 14, "fill": "#1d2130", "bold": false, "italic": false, "underline": false,
            "align": "left", "bg": "", "opacity": 1, "width": 220, "lineHeight": 1.25,
            "rotation": 0, "scaleX": 1, "scaleY": 1, "source": "ipad",
        ]))
        page["objects"] = .array(objects)
        await engine.updatePage(key, page)
        onPagesChanged?([pageIndex])
    }

    // MARK: Suche, Export, Information

    func search(_ query: String) -> [SearchHit] {
        guard let pdf = layout?.pdf, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]).prefix(200).compactMap { sel in
            guard let page = sel.pages.first else { return nil }
            let index = pdf.index(for: page)
            let context = sel.copy() as? PDFSelection ?? sel
            context.extendForLineBoundaries()
            let text = (context.string ?? sel.string ?? "").replacingOccurrences(of: "\n", with: " ")
            return SearchHit(pageIndex: index, snippet: String(text.prefix(160)), selection: sel)
        }
    }

    func exportPDF() async throws -> URL {
        await processPending()
        guard let layout else { throw APIError(status: 0, message: "Dokument nicht geladen") }
        let doc = await engine.currentDocument()
        var srcs = Set<String>()
        for p in doc.pages.values { for o in p["objects"]?.array ?? [] where o["type"]?.string == "image" { if let s = o["src"]?.string { srcs.insert(s) } } }
        for s in srcs where images[s] == nil {
            if let (data, http) = try? await api.data(s), http.statusCode == 200, let img = UIImage(data: data) { images[s] = img }
        }
        return try PDFExporter.export(layout: layout, pages: doc.pages, images: images, title: file.displayTitle)
    }

    func info() async -> DocumentInfo {
        let unsent = await engine.unsentPageKeys.count
        let version = await engine.confirmedServerVersion
        return DocumentInfo(title: file.displayTitle, fileName: file.name, subject: file.subject, folder: file.studip_folder,
                            displayPages: layout?.pdf.pageCount ?? 0, pdfPages: original?.pageCount ?? 0,
                            insertedPages: insertedPages, removedPDFPages: removedPDFPages, bookmarks: bookmarks.count,
                            unsentPages: unsent, serverVersion: version, status: status.label)
    }

    // MARK: Netz und App-Lebenszyklus

    private func startMonitoring() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.engine.requestUpload() }
        }
        m.start(queue: DispatchQueue(label: "uniflow.network"))
        monitor = m
        let center = NotificationCenter.default
        lifecycle.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.flushInBackground() }
        })
        lifecycle.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.engine.requestUpload() }
        })
    }

    private func flushInBackground() async {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "UniFlow speichern") {
            UIApplication.shared.endBackgroundTask(taskID)
        }
        processTask?.cancel()
        await processPending()
        await engine.syncNow()
        if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
    }

    /// Dokument schliessen: Ausstehendes sichern, Wiederholungen beenden (Ungesendetes bleibt im Journal).
    func close() async {
        await flush()
        await engine.syncNow()
        await engine.shutdown()
        monitor?.cancel()
        lifecycle.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycle = []
    }
}
