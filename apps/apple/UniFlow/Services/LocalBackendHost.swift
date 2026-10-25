import Foundation
import UniFlowCore

/// Besitzt die lokale Datenbank und das lokale Backend des Geraets (docs/IPAD-OHNE-PC.md, Abschnitt 4).
///
/// Die Datenbank liegt unter Application Support/UniFlow/db/uniflow.sqlite. Der Ordner hat den Dateischutz
/// `completeUntilFirstUserAuthentication` (nach dem ersten Entsperren lesbar, auch fuer spaetere Hintergrundarbeit)
/// und gehoert ins iCloud-Backup (Notizen, Plan, Einstellungen; Entscheidung 6 in IPAD-OHNE-PC.md). SQLite legt
/// -wal/-shm im selben Ordner an, sie erben den Schutz des Ordners.
///
/// Geoeffnet wird erst bei der ersten Anfrage. Scheitert das (z. B. Speicher voll), antworten alle Pfade mit 503 und
/// Meldung; die naechste Anfrage versucht es erneut.
final class LocalBackendHost: @unchecked Sendable {
    static let shared = LocalBackendHost(directory: AppPaths.support.appendingPathComponent("db", isDirectory: true))

    static let fileName = "uniflow.sqlite"

    let directory: URL
    private let clock: UniFlowClock
    private let lock = NSLock()
    private var opening: Task<LocalBackend, Error>?

    init(directory: URL, clock: UniFlowClock = .system) {
        self.directory = directory
        self.clock = clock
    }

    var databaseURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Backend (oeffnet die Datenbank beim ersten Aufruf; parallele Aufrufe warten auf dasselbe Oeffnen)
    func backend() async throws -> LocalBackend {
        let task: Task<LocalBackend, Error> = lock.withLock {
            if let opening { return opening }
            let dir = directory, url = databaseURL, clock = clock
            let t = Task { try await Self.open(directory: dir, database: url, clock: clock) }
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
    private static func open(directory: URL, database: URL, clock: UniFlowClock) async throws -> LocalBackend {
        let fm = FileManager.default
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? fm.setAttributes(protection, ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false                                    // ausdruecklich ins Backup
        try? dir.setResourceValues(values)
        let backend = try await LocalBackend.open(path: database.path, clock: clock)
        try? fm.setAttributes(protection, ofItemAtPath: database.path)
        return backend
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
