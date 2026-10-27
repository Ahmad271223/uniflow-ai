import Foundation

/// Bibliothek und neue Dateien wie app/server.py und app/study.py.
///
/// Die Einordnung der Dateien (`study.enrich_file`: Art und Lehrwoche) kommt aus `StudyClassify`, die Module
/// (`study.ensure_modules`) aus `LocalModules` (S4); hier gibt es davon keine zweite Fassung.
public enum LocalLibrary {
    // MARK: Abfragen wie app/server.py

    /// Dateien in `GET /api/library` (mit Quelle und Fingerabdruck wie am PC: `download_url`, `content_sha256`;
    /// `source` setzt `StudyClassify.enrichFile`)
    static let librarySQL = """
        SELECT f.id, f.name, COALESCE(f.title, f.name) AS title, f.chdate, f.status, f.favorite, f.last_opened, f.folder_id, f.kind, f.page_count, f.size, f.downloaded_at, f.course_id, f.studip_folder,
               f.download_url, f.content_sha256,
               c.module_id, c.subject, c.kind AS course_kind, a.doc_type, a.title AS ai_title, a.difficulty,
               (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes, (SELECT updated_at FROM annotations an WHERE an.file_id=f.id) AS edited_at
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
        WHERE f.deleted_at IS NULL AND c.active=1 ORDER BY f.chdate DESC
        """

    /// `GET /api/library`: Ordner, Dateien (mit Einordnung), Module, Papierkorb. Schreibt (ensure_modules), darum in
    /// einer Transaktion aufrufen.
    static func library(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue {
        try LocalModules.ensureModules(c, clock: clock)
        let folders = try c.rows("SELECT * FROM folders ORDER BY name")
        let files = try c.rows(librarySQL).map(StudyClassify.enrichFile)
        let trash = try c.rows("SELECT id, COALESCE(title, name) AS title, deleted_at, kind FROM files WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC")
        let mods = try c.rows("SELECT id, name, color FROM modules ORDER BY sort, name")
        return ["folders": .array(folders.map(JSONValue.object)), "files": .array(files.map(JSONValue.object)),
                "modules": .array(mods.map(JSONValue.object)), "trash": .array(trash.map(JSONValue.object))]
    }

    /// Neue Dateien in `study.dashboard`: nicht gesehen, aus aktiven Kursen, neueste zuerst
    static func newFiles(_ c: SQLiteConnection) throws -> [JSONValue] {
        try c.rows("""
            SELECT f.id, f.name, f.first_seen, f.chdate, c.subject, c.module_id, a.doc_type, a.title AS ai_title, a.difficulty, a.est_minutes
            FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
            WHERE f.seen_by_user=0 AND c.active=1 ORDER BY f.first_seen DESC, f.chdate DESC
            """).map(JSONValue.object)
    }

    /// Letzter Abgleich (`SELECT * FROM sync_log ORDER BY id DESC LIMIT 1`)
    static func lastSync(_ c: SQLiteConnection) throws -> JSONValue {
        try c.queryOne("SELECT * FROM sync_log ORDER BY id DESC LIMIT 1").map { .object($0.json) } ?? .null
    }
}

// MARK: - Werte aus dem Rumpf wie in Python

extension LocalTerms {
    /// `int(value)` wie Python: ganze Zahl, abgeschnittene Kommazahl, True/False, Text mit Ziffern; sonst 422
    /// (Python scheitert mit 500).
    static func pyInt(_ v: PyJSON?, field: String) throws -> Int {
        switch v {
        case .int(let digits)?:
            guard let i = Int(digits) else { throw LocalHTTPError(status: 422, message: "\(field): Zahl zu groß") }
            return i
        case .float(let d)?:
            guard d.isFinite, abs(d) < 9e15 else { throw LocalHTTPError(status: 422, message: "\(field): keine endliche Zahl") }
            return Int(d)
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?:
            guard let i = PyConvert.int(s) else { throw LocalHTTPError(status: 422, message: "\(field): keine ganze Zahl") }
            return i
        default: throw LocalHTTPError(status: 422, message: "\(field): ganze Zahl erwartet")
        }
    }
}

extension Array where Element == PyJSON.Member {
    /// Wert eines Schluessels (`body.get(key)`); doppelte Schluessel hat PyJSON schon wie Python zusammengefasst
    func value(_ key: String) -> PyJSON? { first { $0.key == key }?.value }

    func has(_ key: String) -> Bool { contains { $0.key == key } }
}
