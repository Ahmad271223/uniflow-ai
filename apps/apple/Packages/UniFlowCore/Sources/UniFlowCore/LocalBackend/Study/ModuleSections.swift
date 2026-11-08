import Foundation

/// Wochen von Hand (07.11.2026, Vorgabe des Inhabers fuer Version 1.0, alle Hochschulen).
///
/// Die automatische Zuordnung (Stud.IP: Aenderungszeit und Hinweis im Namen, `StudyClassify.weekHint`; Moodle/Learnweb:
/// `LectureWeeks`) stimmt oft nicht. Darum zwei Tabellen, die ueber ALLEN Quellen liegen und die der Abgleich nie
/// anfasst:
///
/// - `file_week_override`: die Woche einer Datei, wie der Nutzer sie gesetzt hat (`source` "manual"). Entweder eine
///   Lehrwoche (`week`: Index der Anzeige wie `LocalModules.week`, -3 Allgemein, -2 Klausuren, -1 aeltere Unterlagen,
///   ab 1 die Woche ab Semesterbeginn) oder ein eigener Abschnitt (`section_id`). Gesetzt gewinnt immer
///   (`LocalModules.week` fragt zuerst hier); "Zurueck auf automatisch" loescht die Zeile. Neue Dateien ohne Zeile
///   werden weiter automatisch zugeordnet.
/// - `module_sections`: eigene Wochen/Abschnitte je Modul ("Woche 7b Klausurvorbereitung", "Altklausuren", …) mit
///   Reihenfolge: `after_week` ist die Lehrwoche, hinter der der Abschnitt steht (`topAnchor` = ganz oben), `position`
///   die Reihenfolge mehrerer Abschnitte hinter derselben Woche. Die Anzeige mischt Lehrwochen und Abschnitte und
///   sortiert nach dieser Position (`order`).
///
/// Ein Abschnitt erscheint in allen Ansichten als Wochenblock mit der Nummer `weekCode(sectionID:)` (-1000 - ID): so
/// brauchen Moduldetail, Regal, Lernplan, Wochentest-Auswahl und KI keine zweite Kennung; fuer sie ist ein Abschnitt
/// eine Woche "unter 1" (nicht automatisch eingeplant, wie Klausuren und aeltere Unterlagen). `Dates.label` liefert den
/// Namen. Beide Tabellen entstehen erst beim ersten Schreiben (wie `lecture_file_weeks`); nur lesen legt nichts an.
public enum ModuleSections {

    /// `after_week` fuer "ganz oben" (vor "Allgemein")
    public static let topAnchor = -4

    /// Woche in der Anzeige fuer einen Abschnitt (unter -1000, damit nichts mit -3 … n zusammenfaellt)
    public static func weekCode(sectionID: Int) -> Int { -1000 - sectionID }

    /// Abschnitts-ID einer Anzeige-Woche, nil fuer Lehrwochen
    public static func sectionID(week: Int) -> Int? { week <= -1000 ? -1000 - week : nil }

    public struct Section: Sendable, Equatable {
        public let id: Int
        public let moduleID: Int
        public var name: String
        public var afterWeek: Int
        public var position: Int

        public init(id: Int, moduleID: Int, name: String, afterWeek: Int, position: Int) {
            self.id = id; self.moduleID = moduleID; self.name = name; self.afterWeek = afterWeek; self.position = position
        }

        public var week: Int { ModuleSections.weekCode(sectionID: id) }

        public var json: JSONValue {
            ["id": .number(Double(id)), "module_id": .number(Double(moduleID)), "name": .string(name),
             "after_week": .number(Double(afterWeek)), "position": .number(Double(position)), "week": .number(Double(week))]
        }
    }

    /// Von Hand gesetzte Woche einer Datei
    public struct Override: Sendable, Equatable {
        public let week: Int?
        public let sectionID: Int?
        public let source: String

        public init(week: Int?, sectionID: Int?, source: String = "manual") {
            self.week = week; self.sectionID = sectionID; self.source = source
        }
    }

    // MARK: Speicher

    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS module_sections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            after_week INTEGER NOT NULL DEFAULT -4,
            position INTEGER NOT NULL DEFAULT 0,
            created_at TEXT);
        CREATE INDEX IF NOT EXISTS idx_module_sections_module ON module_sections(module_id);
        CREATE TABLE IF NOT EXISTS file_week_override (
            file_id TEXT PRIMARY KEY,
            week INTEGER,
            section_id INTEGER,
            source TEXT NOT NULL DEFAULT 'manual',
            set_at TEXT);
        """

    static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTables(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='file_week_override'") != nil
    }

    static func section(row r: SQLiteRow) -> Section? {
        guard let id = r["id"]?.int, let mid = r["module_id"]?.int else { return nil }
        return Section(id: id, moduleID: mid, name: r["name"]?.string ?? "", afterWeek: r["after_week"]?.int ?? topAnchor,
                       position: r["position"]?.int ?? 0)
    }

    /// Abschnitte eines Moduls (nil: aller Module) in ihrer Reihenfolge
    public static func sections(_ c: SQLiteConnection, moduleID: Int? = nil) throws -> [Section] {
        guard try hasTables(c) else { return [] }
        let rows = try moduleID.map { try c.query("SELECT * FROM module_sections WHERE module_id=?", [.integer(Int64($0))]) }
            ?? c.query("SELECT * FROM module_sections")
        return rows.compactMap(section(row:)).sorted(by: sectionOrder)
    }

    /// Alle Abschnitte nach ID (fuer `LocalModules.Dates`)
    public static func allSections(_ c: SQLiteConnection) throws -> [Int: Section] {
        Dictionary(uniqueKeysWithValues: try sections(c).map { ($0.id, $0) })
    }

    /// Alle von Hand gesetzten Wochen (Datei-ID -> Wahl); leer ohne Tabelle
    public static func overrides(_ c: SQLiteConnection) throws -> [String: Override] {
        guard try hasTables(c) else { return [:] }
        var out: [String: Override] = [:]
        for r in try c.query("SELECT file_id, week, section_id, source FROM file_week_override") {
            guard let id = r["file_id"]?.string else { continue }
            out[id] = Override(week: r["week"]?.int, sectionID: r["section_id"]?.int, source: r["source"]?.string ?? "manual")
        }
        return out
    }

    /// Anzeige-Woche einer Wahl; nil, wenn der Abschnitt nicht (mehr) existiert
    public static func week(of o: Override, sections: [Int: Section]) -> Int? {
        if let s = o.sectionID { return sections[s] != nil ? weekCode(sectionID: s) : nil }
        return o.week
    }

    // MARK: Reihenfolge

    /// Schluessel von `LocalModules.weekOrder`: Lehrwochen aufsteigend (Allgemein -3, 0, 1, 2, …), dann aeltere
    /// Unterlagen (-1), dann Klausuren (-2)
    static func weekKey(_ w: Int) -> (Int, Int, Int) { (w == -2 ? 1 : 0, w == -1 ? 1 : 0, w) }

    /// Sortierschluessel eines Wochenblocks: eine Lehrwoche steht vor den Abschnitten hinter ihr; ein Abschnitt sortiert
    /// nach seiner Ankerwoche, dann der Position
    public static func orderKey(week w: Int, sections: [Int: Section]) -> (Int, Int, Int, Int, Int) {
        if let id = sectionID(week: w), let s = sections[id] {
            let k = weekKey(s.afterWeek)
            return (k.0, k.1, k.2, 1, s.position)
        }
        let k = weekKey(w)
        return (k.0, k.1, k.2, 0, 0)
    }

    public static func order(_ a: Int, _ b: Int, sections: [Int: Section]) -> Bool {
        orderKey(week: a, sections: sections) < orderKey(week: b, sections: sections)
    }

    static func sectionOrder(_ a: Section, _ b: Section) -> Bool {
        let ka = weekKey(a.afterWeek), kb = weekKey(b.afterWeek)
        if ka != kb { return ka < kb }
        return a.position != b.position ? a.position < b.position : a.id < b.id
    }

    // MARK: Abschnitte anlegen, aendern, loeschen, ordnen

    /// Neuer Abschnitt hinter `afterWeek` (Vorgabe: ganz oben), als letzter hinter dieser Woche
    @discardableResult
    public static func create(_ c: SQLiteConnection, moduleID: Int, name: String, afterWeek: Int = topAnchor, now: String) throws -> Section {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw LocalHTTPError(status: 400, message: "Name fehlt") }
        guard try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(Int64(moduleID))]) != nil else {
            throw LocalHTTPError.notFound("Modul nicht gefunden")
        }
        try ensureTables(c)
        let anchor = sectionID(week: afterWeek) == nil ? afterWeek : topAnchor         // kein Abschnitt als Anker
        let last = try c.scalar("SELECT MAX(position) FROM module_sections WHERE module_id=? AND after_week=?",
                                [.integer(Int64(moduleID)), .integer(Int64(anchor))])?.int ?? -1
        try c.execute("INSERT INTO module_sections(module_id, name, after_week, position, created_at) VALUES (?,?,?,?,?)",
                      [.integer(Int64(moduleID)), .text(String(n.prefix(80))), .integer(Int64(anchor)), .integer(Int64(last + 1)), .text(now)])
        return Section(id: Int(c.lastInsertRowID), moduleID: moduleID, name: String(n.prefix(80)), afterWeek: anchor, position: last + 1)
    }

    public static func get(_ c: SQLiteConnection, id: Int) throws -> Section? {
        guard try hasTables(c), let r = try c.queryOne("SELECT * FROM module_sections WHERE id=?", [.integer(Int64(id))]) else { return nil }
        return section(row: r)
    }

    /// Umbenennen und/oder hinter eine andere Woche setzen (dann als letzter dort)
    @discardableResult
    public static func update(_ c: SQLiteConnection, id: Int, name: String? = nil, afterWeek: Int? = nil) throws -> Section {
        guard var s = try get(c, id: id) else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
        if let name {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { throw LocalHTTPError(status: 400, message: "Name fehlt") }
            s.name = String(n.prefix(80))
            try c.execute("UPDATE module_sections SET name=? WHERE id=?", [.text(s.name), .integer(Int64(id))])
        }
        if let afterWeek, sectionID(week: afterWeek) == nil, afterWeek != s.afterWeek {
            let last = try c.scalar("SELECT MAX(position) FROM module_sections WHERE module_id=? AND after_week=?",
                                    [.integer(Int64(s.moduleID)), .integer(Int64(afterWeek))])?.int ?? -1
            s.afterWeek = afterWeek
            s.position = last + 1
            try c.execute("UPDATE module_sections SET after_week=?, position=? WHERE id=?",
                          [.integer(Int64(afterWeek)), .integer(Int64(last + 1)), .integer(Int64(id))])
        }
        return s
    }

    /// Abschnitt loeschen; seine Dateien gehen zurueck auf automatisch
    public static func delete(_ c: SQLiteConnection, id: Int) throws {
        guard try get(c, id: id) != nil else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
        try c.execute("DELETE FROM file_week_override WHERE section_id=?", [.integer(Int64(id))])
        try c.execute("DELETE FROM module_sections WHERE id=?", [.integer(Int64(id))])
    }

    /// Abschnitt eine Stelle nach oben oder unten, gemessen an der Anzeige: `weeks` sind die Lehrwochen, die das Modul
    /// gerade zeigt (ohne Abschnitte). Danach bekommen alle Abschnitte des Moduls Anker und Position neu aus der Liste.
    @discardableResult
    public static func move(_ c: SQLiteConnection, id: Int, up: Bool, weeks: [Int]) throws -> [Section] {
        guard let s = try get(c, id: id) else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
        let all = try sections(c, moduleID: s.moduleID)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var blocks = (weeks.filter { sectionID(week: $0) == nil } + all.map(\.week)).sorted { order($0, $1, sections: byID) }
        guard let i = blocks.firstIndex(of: s.week) else { return all }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < blocks.count else { return all }
        blocks.swapAt(i, j)
        return try renumber(c, moduleID: s.moduleID, blocks: blocks, sections: byID)
    }

    /// Anker und Position aller Abschnitte eines Moduls aus einer Blockreihenfolge ableiten
    static func renumber(_ c: SQLiteConnection, moduleID: Int, blocks: [Int], sections: [Int: Section]) throws -> [Section] {
        var anchor = topAnchor, position = 0
        var out: [Section] = []
        for w in blocks {
            if let id = sectionID(week: w) {
                guard var s = sections[id] else { continue }
                s.afterWeek = anchor
                s.position = position
                position += 1
                try c.execute("UPDATE module_sections SET after_week=?, position=? WHERE id=?",
                              [.integer(Int64(anchor)), .integer(Int64(position - 1)), .integer(Int64(id))])
                out.append(s)
            } else {
                anchor = w
                position = 0
            }
        }
        return out.sorted(by: sectionOrder)
    }

    // MARK: Wochen von Hand setzen

    /// Dateien in eine Woche (Index der Anzeige) oder einen Abschnitt (`weekCode`) legen; Rueckgabe: Zahl der Dateien
    @discardableResult
    public static func set(_ c: SQLiteConnection, fileIDs: [String], week: Int, now: String) throws -> Int {
        let ids = Array(Set(fileIDs.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return 0 }
        try ensureTables(c)
        var section: Int?
        if let sid = sectionID(week: week) {
            guard try get(c, id: sid) != nil else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
            section = sid
        } else if week < -3 {
            throw LocalHTTPError(status: 400, message: "Keine gültige Woche")
        }
        var n = 0
        for id in ids {
            guard try c.queryOne("SELECT 1 FROM files WHERE id=?", [.text(id)]) != nil else { continue }
            try c.execute("INSERT OR REPLACE INTO file_week_override(file_id, week, section_id, source, set_at) VALUES (?,?,?,?,?)",
                          [.text(id), section == nil ? .integer(Int64(week)) : .null, section.map { .integer(Int64($0)) } ?? .null,
                           .text("manual"), .text(now)])
            n += 1
        }
        return n
    }

    /// Zurueck auf automatisch
    @discardableResult
    public static func reset(_ c: SQLiteConnection, fileIDs: [String]) throws -> Int {
        guard try hasTables(c) else { return 0 }
        var n = 0
        for id in Set(fileIDs) where !id.isEmpty {
            try c.execute("DELETE FROM file_week_override WHERE file_id=?", [.text(id)])
            n += c.changes
        }
        return n
    }

    // MARK: Wochenliste fuer "In Woche verschieben"

    /// Eine waehlbare Woche: `week` fuer `set`, `label` wie der Wochenblock, `custom` fuer eigene Abschnitte
    public struct Choice: Sendable, Equatable {
        public let week: Int
        public let label: String
        public let custom: Bool

        public var json: JSONValue { ["week": .number(Double(week)), "label": .string(label), "custom": .bool(custom)] }
    }

    /// Alle Wochen, in die eine Datei des Moduls wandern kann, in der Reihenfolge der Anzeige: Allgemein, die Lehrwochen
    /// des Semesters (mit gemerktem Semester bis zu dessen Ende, sonst mindestens 14 bzw. bis zur laufenden oder
    /// hoechsten belegten Woche), die eigenen Abschnitte an ihrer Stelle, aeltere Unterlagen, Klausuren
    public static func choices(moduleID: Int, dates: LocalModules.Dates, presentWeeks: [Int]) -> [Choice] {
        var last = max(14, presentWeeks.filter { $0 >= 1 && $0 < 60 }.max() ?? 0,
                       StudyWeeks.dayWeek(start: dates.start, day: dates.today, today: dates.today))
        if let t = dates.term { last = max(1, min(last, BerlinClock.floorDiv(t.end - dates.start, 7) + 1)) }
        var weeks: [Int] = [LectureWeeks.generalWeek] + Array(1...last) + [-1, -2]
        weeks += dates.sections.values.filter { $0.moduleID == moduleID }.map(\.week)
        return weeks.sorted { dates.order($0, $1) }.map { w in
            Choice(week: w, label: dates.label(w), custom: sectionID(week: w) != nil)
        }
    }
}
