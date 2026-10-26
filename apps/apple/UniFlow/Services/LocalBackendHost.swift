import Foundation
import PDFKit
import UIKit
import UniFlowCore

/// Besitzt die lokale Datenbank und das lokale Backend eines Containers (docs/IPAD-OHNE-PC.md, Abschnitt 4;
/// je Apple-Nutzer und Hochschule ein Container, `ContainerManager`).
///
/// Die Datenbank liegt unter <Container>/db/uniflow.sqlite. Der Ordner hat den Dateischutz
/// `completeUntilFirstUserAuthentication` (nach dem ersten Entsperren lesbar, auch fuer spaetere Hintergrundarbeit)
/// und gehoert ins iCloud-Backup (Notizen, Plan, Einstellungen; Entscheidung 6 in IPAD-OHNE-PC.md). SQLite legt
/// -wal/-shm im selben Ordner an, sie erben den Schutz des Ordners.
///
/// Dateien (Stud.IP-Downloads, eigene Dokumente, Bilder der Notizen) stehen in der Datenbank mit Pfaden relativ zum
/// Container (`DataContainerLayout.files`); ein Pfad ausserhalb des Containers gilt als nicht vorhanden.
///
/// Geoeffnet wird erst bei der ersten Anfrage, und nur fuer die Hochschule des Containers: gehoert die Datenbank einer
/// anderen (`UniversityMismatch`), oeffnet sie nicht. Scheitert das Oeffnen (z. B. Speicher voll), antworten alle
/// Pfade mit 503 und Meldung; die naechste Anfrage versucht es erneut.
final class LocalBackendHost: @unchecked Sendable {
    /// Backend des aktiven Containers; ohne Anmeldung und Hochschulwahl eines, das nichts oeffnet
    static var shared: LocalBackendHost { ActiveContainer.current?.host ?? unavailable }

    /// Antwortet immer mit 503, legt nichts an (vor der Anmeldung, bevor eine Hochschule gewaehlt ist)
    static let unavailable = LocalBackendHost(refusing: "Keine Hochschule gewählt. Bitte melde dich an und wähle deine Hochschule.")

    static let fileName = "uniflow.sqlite"

    let directory: URL
    /// Dateiablage des Backends; nil = keine Dateien (Tests ohne Stud.IP)
    let files: LocalFiles?
    /// Hochschule des Containers (`settings.university` der Datenbank muss passen)
    let university: UniversityKey
    private let clock: UniFlowClock
    private let refusal: String?
    private let lock = NSLock()
    private var opening: Task<LocalBackend, Error>?

    init(directory: URL, clock: UniFlowClock = .system, files: LocalFiles? = nil, university: UniversityKey = .luh) {
        self.directory = directory
        self.clock = clock
        self.files = files
        self.university = university
        self.refusal = nil
    }

    private init(refusing reason: String) {
        directory = URL(fileURLWithPath: "/dev/null")
        clock = .system
        files = nil
        university = .luh
        refusal = reason
    }

    var databaseURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Backend (oeffnet die Datenbank beim ersten Aufruf; parallele Aufrufe warten auf dasselbe Oeffnen)
    func backend() async throws -> LocalBackend {
        if let refusal { throw LocalHTTPError(status: 503, message: refusal) }
        let task: Task<LocalBackend, Error> = lock.withLock {
            if let opening { return opening }
            let dir = directory, url = databaseURL, clock = clock, files = files, uni = university.rawValue
            let t = Task { try await Self.open(directory: dir, database: url, clock: clock, files: files, university: uni) }
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
            if let refusal { return .detail(503, refusal) }
            return .detail(503, "Lokale Datenbank nicht verfügbar: \(Self.message(for: error))")
        }
    }

    /// Verstaendliche Meldung (UniversityMismatch, DataContainerError haben eigene Texte)
    static func message(for error: Error) -> String {
        if DeviceStorage.isFull(error) { return DeviceStorage.fullMessage }
        switch error {
        case let e as UniversityMismatch: return e.description
        case let e as DataContainerError: return e.description
        case let e as LocalHTTPError: return e.detail.string ?? e.description
        // SQLiteError ist kein LocalizedError ("…SQLiteError-Fehler 1."): verstaendlich, mit Code
        case let e as SQLiteError: return "Die Datenbank auf diesem iPad meldet einen Fehler (\(e.code)). Versuche es erneut."
        default: return error.localizedDescription
        }
    }

    /// Ordner mit Dateischutz anlegen (bestehende Ordner bekommen ihn nachtraeglich), Datenbank oeffnen, migrieren
    private static func open(directory: URL, database: URL, clock: UniFlowClock, files: LocalFiles?,
                             university: String) async throws -> LocalBackend {
        let fm = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? fm.setAttributes(protection, ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false                                    // ausdruecklich ins Backup
        try? dir.setResourceValues(values)
        let backend = try await LocalBackend.open(path: database.path, clock: clock, files: files, university: university)
        try? fm.setAttributes(protection, ofItemAtPath: database.path)
        return backend
    }
}

extension LocalFiles {
    /// Dateiablage eines Containers: eigene Dokumente und Bilder (`files/`, `assets/`, im Backup), Stud.IP-Dateien
    /// unter `StudIP/` (ohne Backup, StudIPSync). Pfade in der Datenbank relativ zum Container.
    static func container(_ layout: DataContainerLayout) -> LocalFiles { layout.files(tools: AppDocumentTools()) }
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
