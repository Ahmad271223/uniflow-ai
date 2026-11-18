import Foundation

/// Bibliothek und neue Dateien wie app/server.py und app/study.py.
///
/// Die Einordnung der Dateien (`study.enrich_file`: Art und Lehrwoche) kommt aus `StudyClassify`, die Module
/// (`study.ensure_modules`) aus `LocalModules` (S4); hier gibt es davon keine zweite Fassung.
public enum LocalLibrary {
    // MARK: Abfragen wie app/server.py

    /// Dateien in `GET /api/library` (mit Quelle und Fingerabdruck wie am PC: `download_url`, `content_sha256`;
    /// `source` setzt `StudyClassify.enrichFile`). `is_new` (1/0) rechnet der Kern aus (`newFileSQL`), die App zeigt
    /// und zaehlt "Neu" nur danach.
    static func librarySQL(newSince: String) -> String {
        """
        SELECT f.id, f.name, COALESCE(f.title, f.name) AS title, f.chdate, f.status, f.favorite, f.last_opened, f.folder_id, f.kind, f.page_count, f.size, f.downloaded_at, f.course_id, f.studip_folder,
               f.download_url, f.content_sha256, f.seen_by_user, \(isNewColumn(since: newSince)),
               c.module_id, c.subject, c.kind AS course_kind, a.doc_type, a.title AS ai_title, a.difficulty,
               (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes, (SELECT updated_at FROM annotations an WHERE an.file_id=f.id) AS edited_at
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
        WHERE f.deleted_at IS NULL AND c.active=1 ORDER BY f.chdate DESC
        """
    }

    /// `GET /api/library`: Ordner, Dateien (mit Einordnung), Module, Papierkorb. Schreibt (ensure_modules), darum in
    /// einer Transaktion aufrufen.
    static func library(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue {
        try LocalModules.ensureModules(c, clock: clock)
        let folders = try c.rows("SELECT * FROM folders ORDER BY name")
        let files = try c.rows(librarySQL(newSince: newSince(clock))).map(StudyClassify.enrichFile)
        let trash = try c.rows("SELECT id, COALESCE(title, name) AS title, deleted_at, kind FROM files WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC")
        let mods = try c.rows("SELECT id, name, color FROM modules ORDER BY sort, name")
        return ["folders": .array(folders.map(JSONValue.object)), "files": .array(files.map(JSONValue.object)),
                "modules": .array(mods.map(JSONValue.object)), "trash": .array(trash.map(JSONValue.object))]
    }

    // MARK: "Neu" (eine Regel fuer alle Stellen)

    /// So viele Stunden gilt eine Datei nach dem Eintragen in die App (`files.first_seen`) hoechstens als "neu"
    /// (Auftrag des Inhabers 17.11.2026: "wenn etwas laenger als 24 Std in der App ist, automatisch nicht mehr neu").
    public static let newFileHours = 24

    /// Grenze fuer `first_seen` (Ortszeit Berlin wie `UniFlowClock.nowISO`): ab diesem Zeitpunkt eingetragene Dateien
    /// sind noch neu. Wirkliche 24 Stunden, auch ueber die Zeitumstellung.
    public static func newSince(_ clock: UniFlowClock) -> String {
        BerlinClock.localISO(utc: clock.utcSeconds - newFileHours * 3600)
    }

    /// "Neu" an allen Stellen gleich (`study.new_file_sql`): noch nicht angesehen (`seen_by_user = 0`; Oeffnen und
    /// "Gesehen" setzen es), vor hoechstens `newFileHours` Stunden eingetragen (`first_seen`; fehlt es, ist die Datei
    /// nicht neu) UND nach dem ersten vollstaendigen Einlesen ihres Kurses dazugekommen (`afterFirstListingSQL`).
    /// Danach verschwindet "Neu" von selbst; `seen_by_user` und der Lernstand `status` bleiben, wie sie sind (Audit
    /// 03.11.2026: der Lernstand zaehlt fuer "Neu" nicht). Gilt fuer die Uebersicht "Neu aus …", Modulkarten, Kurse,
    /// Bibliothek und die Dateizeilen in Modulen und im Stundenplan (`is_new` je Datei).
    /// `since` kommt aus `newSince` (nur Ziffern, "-", "T", ":"), darum als Text in der Abfrage.
    public static func newFileSQL(since: String) -> String {
        "(f.seen_by_user=0 AND f.first_seen IS NOT NULL AND f.first_seen>='\(since)' AND \(afterFirstListingSQL))"
    }

    /// `study.AFTER_FIRST_LISTING_SQL`: nach dem ersten Einlesen des Kurses dazugekommen (`courses.first_listed_at`,
    /// `UniStore.markFirstListing`). Was beim allerersten Einlesen eines Kurses schon da war, gilt gar nicht als neu
    /// (Auftrag des Inhabers 17.11.2026, "Ja, so bauen") - auch nicht bei einer zweiten Quelle, einem spaeter belegten
    /// Kurs oder frueheren Semestern. Ohne Zeitpunkt (Liste noch nie fertig gelesen, eigene Dokumente `__user__`) ist
    /// nichts neu; Demo-Dateien (`DemoContent.idPrefix`) sind ausgenommen, damit "Neue Dateien (Demo)" nicht leer ist.
    public static let afterFirstListingSQL =
        "(f.id LIKE '\(DemoContent.idPrefix)%' OR f.first_seen>(SELECT k.first_listed_at FROM courses k WHERE k.id=f.course_id))"

    public static func newFileSQL(_ clock: UniFlowClock) -> String { newFileSQL(since: newSince(clock)) }

    /// Spalte `is_new` (1/0) fuer Dateilisten mit `files f`
    static func isNewColumn(since: String) -> String {
        "CASE WHEN \(newFileSQL(since: since)) THEN 1 ELSE 0 END AS is_new"
    }

    /// Neue Dateien in `study.dashboard`: neu (`newFileSQL`), aus aktiven Kursen, neueste zuerst
    static func newFiles(_ c: SQLiteConnection, clock: UniFlowClock) throws -> [JSONValue] {
        try c.rows("""
            SELECT f.id, f.name, f.first_seen, f.chdate, c.subject, c.module_id, a.doc_type, a.title AS ai_title, a.difficulty, a.est_minutes
            FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
            WHERE \(newFileSQL(clock)) AND c.active=1 ORDER BY f.first_seen DESC, f.chdate DESC
            """).map(JSONValue.object)
    }

    /// `study.new_file_ids`: Kennungen der neuen Dateien eines Moduls (aktive Kurse); ihre Zahl ist `new_count`
    static func newFileIDs(_ c: SQLiteConnection, moduleID: SQLiteValue, since: String) throws -> Set<String> {
        Set(try c.query("SELECT f.id FROM files f JOIN courses c ON c.id=f.course_id WHERE c.active=1 AND c.module_id=? AND \(newFileSQL(since: since))",
                        [moduleID]).compactMap { $0["id"]?.string })
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
