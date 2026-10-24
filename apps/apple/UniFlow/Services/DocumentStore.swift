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

/// Zustand eines geoeffneten Dokuments.
///
/// Ablauf: Strich fertig -> `canvasChanged` merkt nur die neueste Zeichnung (Hauptthread, sofort zurueck) ->
/// nach 0,25 s Pause Umrechnung im `InkProcessor` -> `SyncEngine.updatePage` sichert lokal und laedt hoch.
/// Eingabe, Umrechnung, lokales Sichern und Upload laufen dadurch getrennt; ein Upload unterbricht nie einen Strich.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var pdf: PDFDocument?
    @Published private(set) var status: SyncStatus = .loading
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var insertedPages = 0
    @Published private(set) var removedPDFPages: [Int] = []

    let file: LibFile
    private let api: APIClient
    private let engine: SyncEngine
    private let ink = InkProcessor()
    private var document = AnnotationDocument.empty()
    private var pendingDrawings: [String: DrawingBox] = [:]
    private var processing = false
    private var processTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lifecycle: [NSObjectProtocol] = []

    /// Seiten (0-basierte PDF-Indizes), deren Inhalt sich durch den Server oder eine Zusammenfuehrung geaendert hat.
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
            await engine.setHandlers(
                onStatus: { [weak self] s in Task { @MainActor in self?.status = s } },
                onRemoteChange: { [weak self] keys in Task { @MainActor in await self?.remoteChanged(keys) } })
            let opened = await engine.open(pdfPageCount: pdfDocument.pageCount)
            document = opened.document
            insertedPages = document.insertedPageCount
            removedPDFPages = document.removedPDFIndices(pdfPageCount: pdfDocument.pageCount)
            if !opened.damagedFiles.isEmpty {
                notice = "\(opened.damagedFiles.count) lokale Datei(en) beschädigt – Serverstand verwendet, wo möglich."
            } else if opened.restoredUnsentPages > 0 {
                notice = "\(opened.restoredUnsentPages) ungesendete Seite(n) wiederhergestellt."
            }
            pdf = pdfDocument
            startMonitoring()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Zeichnungen

    func pageKey(forPageIndex index: Int) -> String? { document.pageKey(forPDFIndex: index + 1) }

    /// Zeichnung einer PDF-Seite (0-basiert). Wird im Hintergrund aufgebaut.
    func drawing(forPageIndex index: Int) async -> PKDrawing {
        guard let key = pageKey(forPageIndex: index) else { return PKDrawing() }
        if let pending = pendingDrawings[key] { return pending.drawing }      // noch nicht verarbeitet: neuester Stand
        let page = await engine.page(key)
        return await ink.drawing(key: key, page: page).drawing
    }

    /// Vom Editor nach jeder Aenderung einer Canvas. Kehrt sofort zurueck.
    func canvasChanged(pageIndex index: Int, drawing: PKDrawing) {
        guard let key = pageKey(forPageIndex: index) else {
            notice = "Seite \(index + 1) wurde im Browser entfernt – Striche dort werden nicht gespeichert."
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
        let doc = await engine.currentDocument()
        document = doc
        insertedPages = doc.insertedPageCount
        let indices = keys.compactMap { doc.pdfIndex(forPageKey: $0) }.map { $0 - 1 }
        if !indices.isEmpty { onPagesChanged?(indices) }
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
