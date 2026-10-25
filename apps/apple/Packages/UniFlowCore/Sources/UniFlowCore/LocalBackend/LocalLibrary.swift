import Foundation

/// Bibliothek, Module und neue Dateien wie app/server.py und app/study.py, soweit S3 sie braucht.
///
/// Die Einordnung der Dateien (`study.effective_type`, `study.week_hint`) und der Kurse (`studip_sync.classify`)
/// kommt mit S4; bis dahin liefert `enrich` dieselben Felder mit dem Rueckfall von Python (Typ aus `analysis`, ohne
/// KI "sonstiges", keine Lehrwoche). `ensureModules` ist schon der vollstaendige Port: ohne Fach legt er nichts an.
public enum LocalLibrary {
    /// `PALETTE` in app/study.py
    static let palette = ["#4f6df5", "#0ea5a0", "#e0803a", "#9b59d9", "#d94f6b", "#2f9e5a", "#c7891a", "#3b82c4", "#7c5cd6", "#1aa39a"]

    /// Bezeichnungen aus `study.effective_type`
    static let typeLabels = ["vorlesung": "Vorlesung", "uebung": "Übung", "loesung": "Lösung", "skript": "Skript", "klausur": "Klausur",
                             "organisatorisch": "Organisatorisches"]

    /// `study.ensure_modules(conn)`: je Fach ein Modul, Kurse ohne Modul werden zugeordnet (Art "sonstiges" und
    /// Kurse ohne Fach nicht). Gleiche Reihenfolge, Farben und Sortierung wie Python.
    public static func ensureModules(_ c: SQLiteConnection, clock: UniFlowClock) throws {
        var existing: [String: Int64] = [:]
        for r in try c.query("SELECT id, name FROM modules") {
            if let name = r["name"]?.string, let id = r["id"]?.int64 { existing[name] = id }    // dict(): letzter gewinnt
        }
        var n = Int64(existing.count)                                                     // len(existing) wie Python
        for course in try c.query("SELECT id, subject, kind, semester FROM courses WHERE module_id IS NULL") {
            if course["kind"]?.string == "sonstiges" { continue }
            guard let subject = course["subject"], truthy(subject), let name = subject.string else { continue }
            if existing[name] == nil {
                try c.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                              [.text(name), course["semester"] ?? .null, .text(palette[Int(n) % palette.count]), .integer(n), .text(clock.nowISO)])
                existing[name] = c.lastInsertRowID
                n += 1
            }
            try c.execute("UPDATE courses SET module_id=? WHERE id=?", [.integer(existing[name]!), course["id"] ?? .null])
        }
    }

    // MARK: Einordnung (S4)

    /// `study.effective_type(name, folder, ai_type)`. S3: nur der Rueckfall ohne die Regeln fuer Ordner und
    /// Dateinamen (die portiert S4); `ai_type or "sonstiges"` wie Python.
    static func effectiveType(name: String?, folder: String?, aiType: String?) -> (type: String, label: String) {
        let t = (aiType?.isEmpty ?? true) ? "sonstiges" : aiType!
        return (t, typeLabels[t] ?? "Sonstiges")
    }

    /// `study.week_hint(name, folder)`. S3: keine Lehrwoche (Port mit S4).
    static func weekHint(name: String?, folder: String?) -> Int? { nil }

    /// `study.enrich_file(f)`: `ai_doc_type` = Einschaetzung aus `analysis`, `doc_type`/`sub_label` aus
    /// `effectiveType`, `week_hint` nur fuer Vorlesung, Uebung, Loesung und Skript.
    static func enrich(_ f: [String: JSONValue]) -> [String: JSONValue] {
        var out = f
        let ai = f["doc_type"] ?? .null
        let (t, label) = effectiveType(name: f["name"]?.string, folder: f["studip_folder"]?.string, aiType: ai.string)
        out["ai_doc_type"] = ai
        out["doc_type"] = .string(t)
        out["sub_label"] = .string(label)
        let hint = ["vorlesung", "uebung", "loesung", "skript"].contains(t) ? weekHint(name: f["name"]?.string, folder: f["studip_folder"]?.string) : nil
        out["week_hint"] = hint.map { .number(Double($0)) } ?? .null
        return out
    }

    // MARK: Abfragen wie app/server.py

    /// Dateien in `GET /api/library`
    static let librarySQL = """
        SELECT f.id, f.name, COALESCE(f.title, f.name) AS title, f.chdate, f.status, f.favorite, f.last_opened, f.folder_id, f.kind, f.page_count, f.size, f.downloaded_at, f.course_id, f.studip_folder,
               c.module_id, c.subject, c.kind AS course_kind, a.doc_type, a.title AS ai_title, a.difficulty,
               (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes, (SELECT updated_at FROM annotations an WHERE an.file_id=f.id) AS edited_at
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
        WHERE f.deleted_at IS NULL AND c.active=1 ORDER BY f.chdate DESC
        """

    /// `GET /api/library`: Ordner, Dateien (mit Einordnung), Module, Papierkorb. Schreibt (ensure_modules), darum in
    /// einer Transaktion aufrufen.
    static func library(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue {
        try ensureModules(c, clock: clock)
        let folders = try c.rows("SELECT * FROM folders ORDER BY name")
        let files = try c.rows(librarySQL).map(enrich)
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

    /// Wahrheitswert eines gespeicherten Werts wie in Python (`not c["subject"]`)
    static func truthy(_ v: SQLiteValue) -> Bool {
        switch v {
        case .null: return false
        case .integer(let i): return i != 0
        case .real(let d): return d != 0
        case .text(let s): return !s.isEmpty
        case .blob(let b): return !b.isEmpty
        }
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
