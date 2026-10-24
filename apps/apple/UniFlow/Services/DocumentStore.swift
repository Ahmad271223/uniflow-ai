import Foundation
import PDFKit
import PencilKit

/// Zustand eines geoeffneten Dokuments: PDF, Notizmodell, Speichern und Synchronisieren.
///
/// Ablauf beim Schreiben: Strich fertig -> `update(drawing:pageIndex:)` -> sofort lokal gespeichert ->
/// nach 1,2 s Pause Upload mit `base_version`. Bei 409 (anderes Geraet war schneller) werden die Seiten,
/// die hier geaendert wurden, auf den Serverstand gelegt und erneut gesendet. Ohne Netz: Wiederholung mit
/// wachsendem Abstand (2 s … 60 s). Der lokale Stand wird nie durch eine aeltere Serverantwort ersetzt.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var pdf: PDFDocument?
    @Published private(set) var status = "Lädt…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var insertedPages = 0

    let file: LibFile
    private let api: APIClient
    private var doc = AnnotationDocument.empty()
    private var dirtyPages = Set<String>()
    private var lastData: [Int: Data] = [:]
    private var saveTask: Task<Void, Never>?
    private var retrySeconds: UInt64 = 2

    nonisolated init(file: LibFile, api: APIClient) {
        self.file = file
        self.api = api
    }

    // MARK: Laden

    func load() async {
        do {
            let url = LocalStore.pdfURL(file.id)
            if !FileManager.default.fileExists(atPath: url.path) {
                let (data, http) = try await api.data("/api/files/\(file.id)/content")
                guard http.statusCode == 200, data.starts(with: Array("%PDF".utf8)) else {
                    throw APIError(status: http.statusCode, message: "Keine PDF-Datei erhalten")
                }
                try data.write(to: url, options: .atomic)
            }
            guard let document = PDFDocument(url: url) else { throw APIError(status: 0, message: "PDF lässt sich nicht öffnen") }

            let server = try? await api.json("/api/files/\(file.id)/annotations", as: AnnotationsResponse.self)
            if let local = LocalStore.loadState(file.id), !local.dirtyPages.isEmpty {
                // Ungesendete Aenderungen vom letzten Mal haben Vorrang
                doc = AnnotationDocument(root: local.root, version: local.version)
                dirtyPages = Set(local.dirtyPages)
                if let server, server.version != local.version, let data = server.data { merge(serverRoot: data, version: server.version) }
            } else if let server {
                doc = AnnotationDocument(root: server.data ?? AnnotationDocument.empty().root, version: server.version)
            } else if let local = LocalStore.loadState(file.id) {
                doc = AnnotationDocument(root: local.root, version: local.version)
            }
            doc.ensurePDFPages(count: document.pageCount)
            insertedPages = doc.insertedPageCount
            pdf = document
            status = dirtyPages.isEmpty ? "Gespeichert" : "Ungesendet"
            if !dirtyPages.isEmpty { scheduleSave(after: 0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Zeichnungen

    func drawing(forPageIndex index: Int) -> PKDrawing {
        guard let key = doc.pageKey(forPDFIndex: index + 1) else { return PKDrawing() }
        let objects = doc.objects(page: key)
        var result: PKDrawing
        if let pk = doc.pkDrawing(page: key), pk.signature == StrokeConverter.signature(objects),
           let data = Data(base64Encoded: pk.data), let d = try? PKDrawing(data: data) {
            result = d                                   // verlustfrei: unveraenderte native Zeichnung
        } else {
            result = StrokeConverter.drawing(from: objects)   // im Browser bearbeitet -> aus den Objekten aufbauen
        }
        lastData[index] = result.dataRepresentation()
        return result
    }

    func update(drawing: PKDrawing, pageIndex index: Int) {
        let data = drawing.dataRepresentation()
        guard data != lastData[index], let key = doc.pageKey(forPDFIndex: index + 1) else { return }
        lastData[index] = data
        let others = doc.objects(page: key).filter { $0["type"]?.string != "stroke" }   // Text, Formen, Bilder bleiben
        let all = others + StrokeConverter.objects(from: drawing)
        doc.setPage(key, objects: all, pkData: data.base64EncodedString(), signature: StrokeConverter.signature(all))
        dirtyPages.insert(key)
        persistLocal()
        status = "Ungesendet"
        scheduleSave(after: 1.2)
    }

    private func persistLocal() {
        LocalStore.saveState(LocalDocState(root: doc.root, version: doc.version, dirtyPages: Array(dirtyPages)), file.id)
    }

    // MARK: Synchronisieren

    func scheduleSave(after seconds: Double) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync(attempt: Int = 0) async {
        guard !dirtyPages.isEmpty else { status = "Gespeichert"; return }
        status = "Speichert…"
        do {
            let body = try JSONEncoder().encode(doc.root)
            let (data, http) = try await api.data("/api/files/\(file.id)/annotations?base_version=\(doc.version)", method: "PUT", body: body)
            if http.statusCode == 409, attempt < 3 {
                let conflict = try JSONDecoder().decode(ConflictResponse.self, from: data)
                merge(serverRoot: conflict.data, version: conflict.version)
                persistLocal()
                await sync(attempt: attempt + 1)
                return
            }
            guard (200..<300).contains(http.statusCode) else { throw APIError(status: http.statusCode, message: "Speichern abgelehnt") }
            let saved = try JSONDecoder().decode(SaveResponse.self, from: data)
            doc.version = saved.version
            dirtyPages.removeAll()
            persistLocal()
            retrySeconds = 2
            status = "Gespeichert"
        } catch {
            status = "Offline – wird nachgeholt"
            let wait = retrySeconds
            retrySeconds = min(retrySeconds * 2, 60)
            scheduleSave(after: Double(wait))
        }
    }

    /// Serverstand uebernehmen, aber hier geaenderte Seiten behalten (seitenweise Zusammenfuehrung).
    private func merge(serverRoot: JSONValue, version: Int) {
        var merged = AnnotationDocument(root: serverRoot, version: version)
        for key in dirtyPages {
            if let page = doc.page(key) { merged.setPageRaw(key, page) }
        }
        if let count = pdf?.pageCount { merged.ensurePDFPages(count: count) }
        doc = merged
    }
}
