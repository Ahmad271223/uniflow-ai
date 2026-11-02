import Foundation

/// Texterkennung (OCR) als Ersatz fuer PDF-Seiten ohne Textebene (Scans, abfotografierte Blaetter, Folien als Bild),
/// nur auf dem Geraet. Die eingebettete Textebene bleibt die erste Wahl (genauer und schneller); erkannt wird nur eine
/// Seite, deren Textebene fast leer ist (`PageOCRStore.minimumLetters`), und nur dann, wenn ihr Text gebraucht wird
/// (`ScriptSearch.pageTexts` mit `OCRScope`), nie beim blossen Oeffnen fuer alle Seiten.
///
/// Gespeichert wird je Datei, Seite und Aenderungszeit in `page_ocr` (nur auf dem Geraet, erst bei Bedarf angelegt wie
/// `file_versions`); ein erkannter Text ersetzt ausserdem den fast leeren Text der Seite in `page_texts` (mit
/// Suchform), damit alle Leser dort (Suche, Skriptsuche, Wochentests, Abgaben, KI-Hilfe) ihn ohne Aenderung finden.
/// Eine Seite, die schon erkannt wurde (auch ohne Ergebnis), wird nicht noch einmal erkannt; eine neue Fassung der
/// Datei (andere Aenderungszeit, `storePages`) verwirft die Ergebnisse.
public protocol PageOCR: Sendable {
    /// Text der Seiten `pages` (1-basiert) der PDF unter `url`; eine Seite ohne erkannten Text fehlt oder ist "".
    /// Wirft, wenn sich die Datei nicht lesen laesst; laeuft nie auf dem Hauptthread (lokales Backend).
    func recognize(pdf url: URL, pages: [Int]) async throws -> [Int: String]
}

/// OCR-Anschluss des lokalen Backends wie `LocalAI`: die App setzt die Erkennung (Vision, `VisionPageOCR`), ohne sie
/// (Kern unter Linux, Tests) bleibt es bei der Textebene der PDF.
public final class LocalOCR: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PageOCR?

    public init() {}

    public var provider: PageOCR? { lock.withLock { current } }

    public func set(_ provider: PageOCR?) { lock.withLock { current = provider } }
}

/// Welche Seiten `ScriptSearch.pageTexts` bei fast leerer Textebene erkennen darf
public enum OCRScope: Sendable, Equatable {
    /// keine (Hintergrund ueber viele Dateien, z. B. Abgaben nachlesen, Seitenzuordnung einer neuen Fassung)
    case none
    /// nur diese Seiten (1-basiert), z. B. die offene Seite fuer die KI-Hilfe
    case pages(Set<Int>)
    /// die ersten n Seiten (Einordnung, Auszug fuer einen Test)
    case leading(Int)
    /// alle Seiten (Index der Skriptsuche, Wochentests)
    case all

    func contains(_ page: Int) -> Bool {
        switch self {
        case .none: return false
        case .pages(let s): return s.contains(page)
        case .leading(let n): return page <= n
        case .all: return true
        }
    }
}

enum PageOCRStore {
    /// "Fast leer": weniger Buchstaben als das auf der Seite. Eine Folie mit Text hat deutlich mehr; Seitenzahl,
    /// Kopfzeile oder ein einzelnes Wort aus einer Bildbeschriftung bleiben darunter. Ziffern und Zeichen zaehlen nicht
    /// (eine reine Formelseite mit Textebene hat trotzdem meist Buchstaben).
    static let minimumLetters = 20

    /// so viele Seiten je Erkennung; danach wird gespeichert (ein Abbruch verliert hoechstens diese Seiten)
    static let batchSize = 4

    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS page_ocr (
            file_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            chdate INTEGER,
            embedded TEXT,                     -- Textebene der Seite vor der Erkennung
            text TEXT,                         -- erkannter Text ("" = nichts erkannt)
            PRIMARY KEY (file_id, page))
        """

    static func ensureTable(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTable(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_ocr'") != nil
    }

    /// Buchstaben eines Textes (Unicode, auch Umlaute)
    static func letters(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.letters.contains($1) ? 1 : 0) }
    }

    static func isSparse(_ text: String) -> Bool { letters(text) < minimumLetters }

    /// Ergebnisse einer Datei verwerfen (neue Seitentexte, neue Fassung, Demo entfernt)
    static func delete(_ c: SQLiteConnection, fileID: String) throws {
        guard try hasTable(c) else { return }
        try c.execute("DELETE FROM page_ocr WHERE file_id=?", [.text(fileID)])
    }

    /// Textebene statt erkanntem Text (Seitenzuordnung einer neuen Fassung vergleicht Textebene mit Textebene)
    static func embedded(_ c: SQLiteConnection, fileID: String, pages: [String]) throws -> [String] {
        guard try hasTable(c) else { return pages }
        var out = pages
        for r in try c.query("SELECT page, embedded, text FROM page_ocr WHERE file_id=?", [.text(fileID)]) {
            guard let p = r["page"]?.int, p >= 1, p <= out.count, let t = r["text"]?.string, !t.isEmpty, out[p - 1] == t else { continue }
            out[p - 1] = r["embedded"]?.string ?? ""
        }
        return out
    }

    /// Fast leere Seiten in `scope` erkennen, die noch nicht erkannt wurden, und speichern; `pages` sind die Texte
    /// aus `page_texts`. Nur fuer eine lokale PDF derselben Aenderungszeit. Fehler der Erkennung lassen die Texte wie
    /// sie sind (der naechste Bedarf versucht es erneut); ein Abbruch wirft `CancellationError`.
    static func fill(fileID: String, pages: [String], scope: OCRScope, ocr: PageOCR, database: SQLiteDatabase,
                     files: LocalFiles, clock: UniFlowClock) async throws -> [String] {
        let sparse = pages.indices.map { $0 + 1 }.filter { scope.contains($0) && isSparse(pages[$0 - 1]) }
        if sparse.isEmpty { return pages }
        // nur lesen (haeufiger Fall: alle fast leeren Seiten schon erkannt); die Tabelle entsteht beim ersten Speichern
        let plan = try await database.withConnection { c -> (url: URL, stamp: SQLiteValue, todo: [Int])? in
            guard let f = try c.queryOne("SELECT local_path, chdate FROM files WHERE id=?", [.text(fileID)]),
                  let path = f["local_path"]?.string, !path.isEmpty, ScriptSearch.hasPDFSuffix(path), files.exists(stored: path),
                  let url = files.url(stored: path) else { return nil }
            let chdate = f["chdate"] ?? .null
            let stamp: SQLiteValue = LocalModules.truthy(chdate) ? chdate : .integer(0)
            let done = try hasTable(c) ? Set(try c.query("SELECT page FROM page_ocr WHERE file_id=? AND COALESCE(chdate, 0)=?",
                                                         [.text(fileID), stamp]).compactMap { $0["page"]?.int }) : []
            return (url, stamp, sparse.filter { !done.contains($0) })
        }
        guard let plan, !plan.todo.isEmpty else { return pages }
        var out = pages
        var start = 0
        while start < plan.todo.count {
            try Task.checkCancellation()
            let batch = Array(plan.todo[start..<min(start + batchSize, plan.todo.count)])
            start += batch.count
            let found: [Int: String]
            do {
                found = try await ocr.recognize(pdf: plan.url, pages: batch)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return out
            }
            try Task.checkCancellation()
            let current = out
            let applied = try await database.transaction { c -> [Int: String]? in
                // inzwischen eine neue Fassung oder neu gelesene Texte: die Erkennung gehoert nicht mehr dazu
                guard let now = try c.queryOne("SELECT chdate FROM files WHERE id=?", [.text(fileID)]),
                      (now["chdate"]?.double ?? 0) == (plan.stamp.double ?? 0),
                      try c.scalar("SELECT COUNT(*) FROM page_texts WHERE file_id=? AND COALESCE(chdate, 0)=?",
                                   [.text(fileID), plan.stamp])?.int == current.count else { return nil }
                try ensureTable(c)
                var applied: [Int: String] = [:]
                for p in batch {
                    let embedded = current[p - 1]
                    let text = (found[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    try c.execute("INSERT OR REPLACE INTO page_ocr(file_id, page, chdate, embedded, text) VALUES (?,?,?,?,?)",
                                  [.text(fileID), .integer(Int64(p)), plan.stamp, .text(embedded), .text(text)])
                    // nur, wenn die Erkennung mehr Text findet als die Textebene
                    guard letters(text) > letters(embedded) else { continue }
                    try c.execute("UPDATE page_texts SET text=?, search=? WHERE file_id=? AND page=?",
                                  [.text(text), .text(ScriptSearch.searchForm(text)), .text(fileID), .integer(Int64(p))])
                    applied[p] = text
                }
                if !applied.isEmpty { try DueStore.refreshFile(c, fileID: fileID, clock: clock) }
                return applied
            }
            guard let applied else { return out }
            for (p, t) in applied { out[p - 1] = t }
        }
        return out
    }
}
