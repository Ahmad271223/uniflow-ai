import Foundation

/// Dateien, deren Download gescheitert ist (07.11.2026, Befund vom iPad: Dateien "erkannt, aber nicht geladen", ohne
/// sichtbaren Grund). Je Datei der letzte Fehler als verstaendlicher Text, der HTTP-Status (wenn es einen gab), die
/// Zahl der Versuche und der Zeitpunkt. Ein erfolgreicher Download (`UniStore.markDownloaded`) loescht den Eintrag.
///
/// Die Tabelle entsteht erst bei Bedarf (wie `studip_file_links`); ohne Tabelle gibt es keine Fehler. Sie haengt nur
/// an der Datei-ID, ihre Zeilen gehen nicht ueber Geraete (jedes Geraet laedt selbst).
///
/// Wiederholen: jeder Abgleich versucht jede gelistete, nicht geladene Datei erneut (`UniStore.storeFiles` meldet sie,
/// solange `local_path` fehlt). Nur wenn Stud.IP die Datei ausdruecklich verweigert (403) oder nicht kennt (404),
/// wartet der automatische Abgleich `refusedRetryAfter`, damit nicht jeder Lauf dieselben Absagen sammelt; "Jetzt
/// laden" und "Erneut versuchen" in der Dateiansicht fragen immer sofort.
public enum DownloadFailures {
    static let table = """
        CREATE TABLE IF NOT EXISTS file_download_failures (
            id TEXT PRIMARY KEY,               -- files.id
            message TEXT NOT NULL,             -- verstaendlicher Grund
            status INTEGER,                    -- HTTP-Status, sonst NULL
            attempts INTEGER NOT NULL DEFAULT 1,
            failed_at TEXT NOT NULL            -- Ortszeit wie files.downloaded_at
        )
        """

    /// Wartezeit nach einer ausdruecklichen Absage (403/404), bevor der automatische Abgleich die Datei wieder fragt
    public static let refusedRetryAfter: TimeInterval = 6 * 3600

    public struct Entry: Sendable, Equatable {
        public let id: String
        public let message: String
        public let status: Int?
        public let attempts: Int
        public let failedAt: String

        public init(id: String, message: String, status: Int?, attempts: Int, failedAt: String) {
            self.id = id
            self.message = message
            self.status = status
            self.attempts = attempts
            self.failedAt = failedAt
        }

        /// Stud.IP hat die Datei ausdruecklich verweigert oder kennt sie nicht
        public var refused: Bool { status == 403 || status == 404 }
    }

    static func exists(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='file_download_failures'") != nil
    }

    /// Fehlversuch eintragen (Versuche zaehlen hoch)
    public static func record(_ c: SQLiteConnection, fileID: String, message: String, status: Int?, now: String) throws {
        try c.executeScript(table)
        try c.execute("""
            INSERT INTO file_download_failures(id, message, status, attempts, failed_at) VALUES (?,?,?,1,?)
            ON CONFLICT(id) DO UPDATE SET message=excluded.message, status=excluded.status,
                attempts=file_download_failures.attempts + 1, failed_at=excluded.failed_at
            """, [.text(fileID), .text(message), SQLiteValue(status), .text(now)])
    }

    /// Eintrag weg (Datei geladen)
    public static func clear(_ c: SQLiteConnection, fileID: String) throws {
        guard try exists(c) else { return }
        try c.execute("DELETE FROM file_download_failures WHERE id=?", [.text(fileID)])
    }

    public static func entry(_ c: SQLiteConnection, fileID: String) throws -> Entry? {
        guard try exists(c), let r = try c.queryOne("SELECT * FROM file_download_failures WHERE id=?", [.text(fileID)]) else { return nil }
        return row(r)
    }

    public static func all(_ c: SQLiteConnection) throws -> [String: Entry] {
        guard try exists(c) else { return [:] }
        var out: [String: Entry] = [:]
        for r in try c.query("SELECT * FROM file_download_failures") { if let e = row(r) { out[e.id] = e } }
        return out
    }

    private static func row(_ r: SQLiteRow) -> Entry? {
        guard let id = r["id"]?.string else { return nil }
        return Entry(id: id, message: r["message"]?.string ?? "", status: r["status"]?.int,
                     attempts: r["attempts"]?.int ?? 1, failedAt: r["failed_at"]?.string ?? "")
    }

    /// Versucht der automatische Abgleich die Datei jetzt? Ohne Eintrag und bei jedem anderen Fehler ja; nach einer
    /// Absage (403/404) erst nach `refusedRetryAfter`. `now`/`failedAt` als Ortszeit (`BerlinClock`).
    public static func dueForAutomaticRetry(_ e: Entry?, now: String) -> Bool {
        guard let e, e.refused else { return true }
        guard let t = BerlinClock.utcSeconds(localISO: e.failedAt), let n = BerlinClock.utcSeconds(localISO: now) else { return true }
        return Double(n - t) >= refusedRetryAfter || n < t
    }

    /// Verstaendlicher Grund und HTTP-Status eines gescheiterten Downloads (fuer die Dateiansicht "Nicht geladen")
    public static func describe(_ error: Error) -> (message: String, status: Int?) {
        switch error {
        case StudIPError.http(let status, _) where status == 403:
            return ("Stud.IP gibt diese Datei gerade nicht zum Herunterladen frei (Fehler 403). In Stud.IP selbst lässt sie sich "
                    + "vielleicht öffnen; sonst hilft eine Nachricht an die Lehrenden.", status)
        case StudIPError.http(let status, _) where status == 404:
            return ("Stud.IP findet diese Datei nicht mehr (Fehler 404). Sie wurde vielleicht entfernt oder verschoben.", status)
        case StudIPError.http(let status, _) where status == 429 || status >= 500:
            return ("Stud.IP ist gerade überlastet oder gestört (Fehler \(status)). Später erneut versuchen.", status)
        case StudIPError.http(let status, _):
            return ("Stud.IP hat die Datei nicht geliefert (Fehler \(status)).", status)
        case StudIPError.sessionExpired:
            return ("Die Stud.IP-Anmeldung ist abgelaufen. Bitte neu bei Stud.IP anmelden.", nil)
        case StudIPError.badResponse:
            return ("Statt der Datei kam eine Webseite von Stud.IP zurück.", nil)
        case is UniDownloads.Failure:
            return ("Die Datei kam leer oder unvollständig an und wurde nicht gespeichert.", nil)
        case let e as URLError:
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return ("Keine Internetverbindung. Mit WLAN oder mobilen Daten erneut versuchen.", nil)
            case .timedOut:
                return ("Die Verbindung zu Stud.IP war zu langsam (Zeitüberschreitung).", nil)
            default:
                return ("Verbindung zu Stud.IP gestört (\(e.code.rawValue)).", nil)
            }
        default:
            return ("Die Datei ließ sich nicht laden.", nil)
        }
    }
}
