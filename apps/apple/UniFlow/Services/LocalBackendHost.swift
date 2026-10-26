import Foundation
import PDFKit
import UIKit
import UniFlowCore

/// Besitzt die lokale Datenbank und das lokale Backend des Geraets (docs/IPAD-OHNE-PC.md, Abschnitt 4).
///
/// Die Datenbank liegt unter Application Support/UniFlow/db/uniflow.sqlite. Der Ordner hat den Dateischutz
/// `completeUntilFirstUserAuthentication` (nach dem ersten Entsperren lesbar, auch fuer spaetere Hintergrundarbeit)
/// und gehoert ins iCloud-Backup (Notizen, Plan, Einstellungen; Entscheidung 6 in IPAD-OHNE-PC.md). SQLite legt
/// -wal/-shm im selben Ordner an, sie erben den Schutz des Ordners.
///
/// Dateien (Stud.IP-Downloads, eigene Dokumente, Bilder der Notizen) stehen in der Datenbank mit Pfaden relativ zum
/// App-Container (`LocalFiles.app`), denn dessen Pfad aendert sich zwischen Installationen.
///
/// Geoeffnet wird erst bei der ersten Anfrage. Scheitert das (z. B. Speicher voll), antworten alle Pfade mit 503 und
/// Meldung; die naechste Anfrage versucht es erneut.
final class LocalBackendHost: @unchecked Sendable {
    static let shared = LocalBackendHost(directory: AppPaths.support.appendingPathComponent("db", isDirectory: true), files: .app)

    static let fileName = "uniflow.sqlite"

    let directory: URL
    /// Dateiablage des Backends; nil = keine Dateien (Tests ohne Stud.IP)
    let files: LocalFiles?
    private let clock: UniFlowClock
    private let lock = NSLock()
    private var opening: Task<LocalBackend, Error>?

    init(directory: URL, clock: UniFlowClock = .system, files: LocalFiles? = nil) {
        self.directory = directory
        self.clock = clock
        self.files = files
    }

    var databaseURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Backend (oeffnet die Datenbank beim ersten Aufruf; parallele Aufrufe warten auf dasselbe Oeffnen)
    func backend() async throws -> LocalBackend {
        let task: Task<LocalBackend, Error> = lock.withLock {
            if let opening { return opening }
            let dir = directory, url = databaseURL, clock = clock, files = files
            let t = Task { try await Self.open(directory: dir, database: url, clock: clock, files: files) }
            opening = t
            return t
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { if opening == task { opening = nil } }          // naechste Anfrage versucht es erneut
            throw error
        }
    }

    func handle(_ request: LocalRequest) async -> LocalResponse {
        do {
            let b = try await backend()
            return await b.handle(request)
        } catch {
            return .detail(503, "Lokale Datenbank nicht verfügbar: \(error.localizedDescription)")
        }
    }

    /// Ordner mit Dateischutz anlegen (bestehende Ordner bekommen ihn nachtraeglich), Datenbank oeffnen, migrieren
    private static func open(directory: URL, database: URL, clock: UniFlowClock, files: LocalFiles?) async throws -> LocalBackend {
        let fm = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? fm.setAttributes(protection, ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false                                    // ausdruecklich ins Backup
        try? dir.setResourceValues(values)
        let backend = try await LocalBackend.open(path: database.path, clock: clock, files: files)
        try? fm.setAttributes(protection, ofItemAtPath: database.path)
        return backend
    }
}

extension LocalFiles {
    /// App-Container mit dem Datenordner Application Support/UniFlow (eigene Dokumente und Bilder im Backup);
    /// Stud.IP-Dateien liegen daneben unter Application Support/StudIP (ohne Backup, StudIPSync).
    static var app: LocalFiles {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let data = LocalFiles(container: home, dataDirectory: "").stored(AppPaths.support) ?? "Library/Application Support/UniFlow"
        return LocalFiles(container: home, dataDirectory: data, tools: AppDocumentTools())
    }
}

/// Seitenzahl und Seitentexte (PDFKit) und Bild als einseitige PDF (UIKit), wie pypdf und Pillow am PC.
struct AppDocumentTools: LocalDocumentTools {
    func pdfPageCount(_ data: Data) -> Int? { PDFDocument(data: data)?.pageCount }

    /// Text je Seite (Skriptsuche, Suche, Seitenzuordnung einer neuen Fassung); laeuft nie auf dem Hauptthread
    /// (lokales Backend, Abgleich)
    func pdfPageTexts(_ url: URL) -> [String]? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    func pdfFromImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        // Seite in Bildgroesse wie Pillow (ein Pixel = ein Punkt)
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsPDFRendererFormat()
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size), format: format).pdfData { ctx in
            ctx.beginPage()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Anfragen der App an das lokale Backend statt ins Netz. Baut aus der Antwort eine HTTPURLResponse wie vom
/// PC-Server, damit `APIClient` und alle Ansichten unveraendert bleiben.
struct LocalTransport: APITransport {
    let host: LocalBackendHost

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw APIError(status: -1, message: "Anfrage ohne Adresse") }
        let local = LocalRequest(method: request.httpMethod ?? "GET", url: url,
                                 headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
        let r = await host.handle(local)
        guard let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers) else {
            throw APIError(status: -1, message: "Keine HTTP-Antwort")
        }
        return (r.body, http)
    }
}
