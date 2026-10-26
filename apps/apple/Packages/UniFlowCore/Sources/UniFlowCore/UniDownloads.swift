import Foundation

/// Datei einer Hochschul-Quelle in den Container laden und eintragen: die eine Fassung fuer den Stud.IP-Abgleich der
/// App (`StudIP/`, StudIPSync) und den Learnweb-Abgleich (`Learnweb/`, `HildesheimSync`), wie `stream_download` und
/// `store_course_files` in app/studip_sync.py.
///
/// Ablauf je Datei (`load`):
/// 1. `fetch` laedt in eine eigene Zwischendatei im Ordner `.laden` der Quelle und prueft, was nur die Quelle weiss
///    (Anmeldung abgelaufen, HTTP-Status, Webseite oder Fehlermeldung statt der Datei, `UniStore.isWebPage`)
/// 2. keine leere Antwort statt der Datei, wenn die Quelle eine Groesse meldet oder es schon eine Fassung gibt
///    (`empty_download` am PC): eine leere Antwort ersetzt und loescht nie etwas
/// 3. der Container besteht noch (`DataContainerLayout.verifyPresent`, vor jedem Anlegen und vor dem Ersetzen)
/// 4. atomar an ihren Platz (`rename` ersetzt eine aeltere Fassung, nie halb), Dateischutz wie die Datenbank
/// 5. Inhalts-Hash (`TestShare.contentHash(file:)`, ausserhalb der Transaktion), dann `UniStore.markDownloaded` in
///    einer kurzen Transaktion
/// Ein Fehler hinterlaesst keine Datei; die alte Fassung bleibt und gilt beim naechsten Abgleich weiter als geaendert.
/// Vor dem Lauf raeumt `begin` Reste eines abgebrochenen Laufs weg, danach entfernt `end` den Zwischenordner.
public struct UniDownloads: Sendable {
    /// Ordner der Quelle im Container (`DataContainerLayout.studip`, `.learnweb`); ohne iCloud-Backup
    public let folder: URL
    /// Dateiablage des Containers: `files.local_path` relativ zu ihm
    public let files: LocalFiles
    /// Container, in den geschrieben wird; nil nur fuer eine Ablage ohne Container (Tests mit eigenem Ordner)
    public let container: DataContainerLayout?

    public init(folder: URL, files: LocalFiles, container: DataContainerLayout?) {
        self.folder = folder
        self.files = files
        self.container = container
    }

    /// Ablage einer Quelle im Container (`layout.studip`, `layout.learnweb`)
    public init(_ layout: DataContainerLayout, folder: URL) {
        self.init(folder: folder, files: layout.files(), container: layout)
    }

    /// Zwischenordner der laufenden Downloads
    public var partial: URL { Self.partial(in: folder) }

    /// Zwischenordner im Ordner einer Quelle (auch fuer "Dateien löschen")
    public static func partial(in folder: URL) -> URL { folder.appendingPathComponent(".laden", isDirectory: true) }

    public enum Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        /// 0 Bytes statt der Datei (Quelle meldet eine Groesse oder es gibt schon eine Fassung): nichts ersetzt
        case empty(String)
        /// Ziel liegt nicht im Container (nichts eingetragen)
        case notStored(String)

        public var description: String {
            switch self {
            case .empty(let name): return "Leere Antwort statt der Datei: \(name)"
            case .notStored(let name): return "Datei nicht gespeichert: \(name)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// Vor einem Lauf: Ordner der Quelle anlegen (ohne iCloud-Backup) und Reste eines abgebrochenen Laufs im
    /// Zwischenordner entfernen. Nur in einem bestehenden Container.
    public func begin() throws {
        try container?.verifyPresent()
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var f = folder
        try? f.setResourceValues(values)
        try? fm.removeItem(at: partial)
    }

    /// Nach einem Lauf (auch einem abgebrochenen): Zwischenordner entfernen
    public func end() {
        try? FileManager.default.removeItem(at: partial)
    }

    /// Eine Datei laden, an `relativePath` (relativ zu `folder`) ablegen und in `db` eintragen (Ablauf oben).
    /// Rueckgabe: Ablageort relativ zum Container (`files.local_path`).
    @discardableResult
    public func load(_ row: UniStore.FileRow, to relativePath: String, db: SQLiteDatabase, clock: UniFlowClock,
                     fetch: @Sendable (URL) async throws -> Void) async throws -> String {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(relativePath)
        try container?.verifyPresent()
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        let part = partial.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? fm.removeItem(at: part) }
        try await fetch(part)
        if Self.isEmpty(part), row.size > 0 || fm.fileExists(atPath: target.path) { throw Failure.empty(row.name) }
        try container?.verifyPresent()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try container?.verifyPresent()
        // rename ersetzt atomar: entweder die alte oder die neue Datei, nie eine halbe
        guard rename(part.path, target.path) == 0 else { throw Failure.notStored(row.name) }
        #if canImport(Darwin)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        #endif
        guard let stored = files.stored(target) else { throw Failure.notStored(row.name) }
        let sha = TestShare.contentHash(file: target)
        let now = clock.nowISO
        try await db.transaction { try UniStore.markDownloaded($0, row, localPath: stored, sha256: sha, now: now) }
        return stored
    }

    /// Datei ohne Inhalt (fehlt sie, zaehlt sie als leer)
    static func isEmpty(_ file: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0) == 0
    }
}
