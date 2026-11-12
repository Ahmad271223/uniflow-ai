import Foundation

/// Eigene Wochen und Abschnitte je Modul (Auftrag des Inhabers 12.11.2026: "Wenn keine klaren Vorlesungswochen
/// bestehen, soll der Nutzer selbst welche anlegen koennen. Wir geben ihm alle Dateien so gut geordnet wie moeglich,
/// und den Rest darf er selbst umstrukturieren"; zuerst Uni Hildesheim, dann LUH, spaeter HsH).
///
/// Die App ordnet weiter selbst (Stud.IP: Aenderungszeit und Nummer im Namen; Moodle/Learnweb: `LectureWeeks`). Darueber
/// liegt die Ordnung des Nutzers, die nur er aendert:
/// - `module_sections`: je Modul Zeilen fuer automatische Wochen (`week` gesetzt: eigener Titel, ausgeblendet, eigener
///   Platz) und eigene Abschnitte (`week` NULL, z. B. "Kapitel Graphen"). `rank` legt den Platz eines eigenen
///   Abschnitts zwischen den automatischen Wochen fest (10 * n + 0,5 = nach Woche n), `sort` gilt erst, wenn der Nutzer
///   die Reihenfolge selbst geaendert hat.
/// - `module_file_places`: je Datei der Abschnitt, in den der Nutzer sie gelegt hat ("w:3" Woche 3, "s:12" eigener
///   Abschnitt 12, "w:-4" Nicht zugeordnet). Ein Abgleich schreibt hier nie; neue Dateien ordnet die App selbst ein.
///
/// Lehrwoche fuer Lernkalender, Wochentests und "Zum Modul" (`planningWeek`): die Woche, in die der Nutzer die Datei
/// gelegt hat; in einem eigenen Abschnitt die Woche, nach der er steht; sonst die automatische. Angezeigter Block
/// (`displayWeek`): der Abschnitt der Datei; Unsicheres der App (Moodle ohne Hinweis, Stud.IP-Sammelupload zu
/// Semesterbeginn ohne Nummer) steht in "Nicht zugeordnet" mit Vorschlag, plant aber wie bisher.
///
/// Gleiche Regeln in Python: `app/module_layout.py`, gemeinsame Faelle
/// `packages/shared-contracts/fixtures/module-layout/cases.json`.
public enum ModuleLayout {
    /// Block "Nicht zugeordnet" (-3 Allgemein, -2 Klausuren, -1 aeltere Unterlagen, 0 vor Beginn)
    public static let unassignedWeek = -4
    /// eigene Abschnitte haben im Moduldetail die Blocknummer -(1000 + id)
    static let customBase = 1000

    public static func customWeek(_ id: Int64) -> Int { -(customBase + Int(id)) }
    public static func sectionID(ofWeek w: Int) -> Int64? { w <= -customBase ? Int64(-w - customBase) : nil }

    /// Schluessel eines Blocks: "w:3", eigener Abschnitt "s:12"
    public static func key(week w: Int) -> String {
        if let id = sectionID(ofWeek: w) { return "s:\(id)" }
        return "w:\(w)"
    }

    /// Blocknummer zu einem Schluessel; nil, wenn er nicht passt
    public static func week(ofKey k: String) -> Int? {
        let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "w": return (unassignedWeek...60).contains(n) ? n : nil
        case "s": return n > 0 ? customWeek(Int64(n)) : nil
        default: return nil
        }
    }

    /// Platz eines automatischen Blocks: Nicht zugeordnet, Allgemein, vor Beginn, Wochen, aeltere Unterlagen, Klausuren
    /// (dieselbe Folge wie `LocalModules.weekOrder`)
    public static func defaultRank(_ w: Int) -> Double {
        switch w {
        case unassignedWeek: return -40
        case LectureWeeks.generalWeek: return -30
        case -2: return 1_000_010
        case -1: return 1_000_000
        default: return w <= 0 ? Double(w) : Double(10 * w)
        }
    }

    /// Lehrwoche, nach der ein eigener Abschnitt steht (rank 30,5 -> Woche 3); nil davor
    public static func weekAfter(rank: Double) -> Int? {
        guard rank >= 10, rank < 1_000_000 else { return nil }
        return Int((rank / 10).rounded(.down))
    }

    // MARK: Speicher

    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS module_sections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_id INTEGER NOT NULL,
            week INTEGER,
            title TEXT,
            rank REAL,
            sort REAL,
            hidden INTEGER NOT NULL DEFAULT 0,
            created_at TEXT);
        CREATE UNIQUE INDEX IF NOT EXISTS module_sections_week ON module_sections(module_id, week) WHERE week IS NOT NULL;
        CREATE TABLE IF NOT EXISTS module_file_places (
            file_id TEXT PRIMARY KEY,
            module_id INTEGER NOT NULL,
            section TEXT NOT NULL,
            placed_at TEXT);
        """

    public static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTables(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='module_sections'") != nil
    }

    public struct Section: Sendable, Equatable {
        public let id: Int64
        /// automatische Woche, auf die sich die Zeile bezieht; nil = eigener Abschnitt
        public let week: Int?
        public let title: String?
        public let rank: Double?
        public let sort: Double?
        public let hidden: Bool

        public init(id: Int64, week: Int?, title: String?, rank: Double? = nil, sort: Double? = nil, hidden: Bool = false) {
            self.id = id; self.week = week; self.title = title; self.rank = rank; self.sort = sort; self.hidden = hidden
        }

        /// Blocknummer im Moduldetail
        public var blockWeek: Int { week ?? ModuleLayout.customWeek(id) }
    }

    /// Ordnung eines Moduls
    public struct Layout: Sendable, Equatable {
        public var sections: [Section] = []
        /// Datei-ID -> Schluessel des Abschnitts
        public var places: [String: String] = [:]

        public init(sections: [Section] = [], places: [String: String] = [:]) { self.sections = sections; self.places = places }

        public var isEmpty: Bool { sections.isEmpty && places.isEmpty }

        public func row(week w: Int) -> Section? { sections.first { $0.week == w } }
        public func custom(_ id: Int64) -> Section? { sections.first { $0.id == id && $0.week == nil && !$0.hidden } }
        public var customs: [Section] { sections.filter { $0.week == nil && !$0.hidden } }
        public func isHidden(week w: Int) -> Bool { row(week: w)?.hidden ?? false }

        /// Gibt es den Block (eigener Abschnitt vorhanden, automatische Woche nicht ausgeblendet)?
        public func exists(_ blockWeek: Int) -> Bool {
            if let id = ModuleLayout.sectionID(ofWeek: blockWeek) { return custom(id) != nil }
            return !isHidden(week: blockWeek)
        }

        /// Platz ohne eigene Sortierung
        public func rank(_ blockWeek: Int) -> Double {
            if let id = ModuleLayout.sectionID(ofWeek: blockWeek), let s = custom(id) { return s.rank ?? (999_000 + Double(id)) }
            return ModuleLayout.defaultRank(blockWeek)
        }

        public func sort(_ blockWeek: Int) -> Double? {
            if let id = ModuleLayout.sectionID(ofWeek: blockWeek) { return custom(id)?.sort }
            return row(week: blockWeek)?.sort
        }

        /// Woche einer Datei fuer Lernkalender, Wochentests und Spruenge: gelegt in Woche n -> n; in einen eigenen
        /// Abschnitt -> die Woche davor (sonst automatisch); "Nicht zugeordnet" oder ein geloeschter Abschnitt ->
        /// automatisch
        public func planningWeek(fileID: String?, auto: Int) -> Int {
            guard let id = fileID, let k = places[id], let w = ModuleLayout.week(ofKey: k) else { return auto }
            if let sid = ModuleLayout.sectionID(ofWeek: w) {
                guard let s = custom(sid) else { return auto }
                return s.rank.flatMap(ModuleLayout.weekAfter(rank:)) ?? auto
            }
            if w == ModuleLayout.unassignedWeek || isHidden(week: w) { return auto }
            return w
        }

        /// Block einer Datei im Moduldetail: der Abschnitt des Nutzers, sonst automatisch (Unsicheres und Dateien
        /// einer geloeschten Woche in "Nicht zugeordnet")
        public func displayWeek(fileID: String?, auto: Int, unsure: Bool) -> Int {
            if let id = fileID, let k = places[id], let w = ModuleLayout.week(ofKey: k), exists(w) { return w }
            let w = unsure ? ModuleLayout.unassignedWeek : auto
            return exists(w) ? w : ModuleLayout.unassignedWeek
        }

        /// Selbst angelegte, leere Abschnitte und Wochen, die trotzdem einen Block bekommen
        public var shownEmpty: [Int] {
            sections.filter { !$0.hidden && ($0.week ?? 1) >= 1 }.map(\.blockWeek)
        }
    }

    /// Alle Ordnungen (leer ohne Tabelle)
    public static func load(_ c: SQLiteConnection) throws -> [Int64: Layout] {
        guard try hasTables(c) else { return [:] }
        var out: [Int64: Layout] = [:]
        for r in try c.query("SELECT * FROM module_sections ORDER BY id") {
            guard let m = r["module_id"]?.int64, let id = r["id"]?.int64 else { continue }
            out[m, default: Layout()].sections.append(Section(id: id, week: r["week"]?.int, title: r["title"]?.string,
                                                              rank: r["rank"]?.double, sort: r["sort"]?.double,
                                                              hidden: (r["hidden"]?.int ?? 0) != 0))
        }
        for r in try c.query("SELECT file_id, module_id, section FROM module_file_places") {
            guard let m = r["module_id"]?.int64, let f = r["file_id"]?.string, let s = r["section"]?.string else { continue }
            out[m, default: Layout()].places[f] = s
        }
        return out
    }

    // MARK: Reihenfolge

    /// Reihenfolge der Bloecke: selbst sortierte nach `sort`; die anderen nach ihrem Platz (`rank`): ans Ende, wenn kein
    /// Block einen groesseren Platz hat, sonst direkt hinter den Block mit dem naechstkleineren Platz (eine spaeter neu
    /// dazukommende Woche 9 steht hinter Woche 8, wo auch immer der Nutzer Woche 8 hingeschoben hat), ganz vorn, wenn
    /// es keinen gibt. Gleichstand: eigene Abschnitte in der Reihenfolge des Anlegens, sonst kleinere Blocknummer.
    public static func order(_ weeks: [Int], layout: Layout) -> [Int] {
        // Gleichstand: eigene Abschnitte in der Reihenfolge des Anlegens, sonst kleinere Blocknummer zuerst
        let tie: (Int) -> Int = { w in sectionID(ofWeek: w).map { 1_000_000 + Int($0) } ?? w }
        let byRank: (Int, Int) -> Bool = { a, b in
            let ra = layout.rank(a), rb = layout.rank(b)
            return ra != rb ? ra < rb : tie(a) < tie(b)
        }
        let explicit = weeks.filter { layout.sort($0) != nil }.sorted { a, b in
            let sa = layout.sort(a)!, sb = layout.sort(b)!
            return sa != sb ? sa < sb : byRank(a, b)
        }
        var out = explicit
        for w in weeks.filter({ layout.sort($0) == nil }).sorted(by: byRank) {
            let r = layout.rank(w)
            // Vorgaenger: groesster Platz kleiner als der eigene (bei Gleichstand der zuletzt eingefuegte)
            var best: Int?
            for (i, x) in out.enumerated() where layout.rank(x) < r || (layout.rank(x) == r && byRank(x, w)) {
                if let b = best, layout.rank(out[b]) > layout.rank(x) { continue }
                best = i
            }
            // ohne groesseren Platz ans Ende (Klausuren bleiben hinten, eine neue letzte Woche kommt nach unten)
            if !weeks.contains(where: { layout.rank($0) > r }) { out.append(w) } else if let b = best { out.insert(w, at: b + 1) } else { out.insert(w, at: 0) }
        }
        return out
    }

    // MARK: Vorschlaege fuer "Nicht zugeordnet"

    /// Vorschlag fuer eine Datei ohne sichere Woche: Blocknummer und kurze Begruendung
    public struct Suggestion: Sendable, Equatable {
        public let week: Int
        public let reason: String
    }

    /// Nummer am Anfang des Namens ("01 Einleitung", "3_Graphen"): bei Sammeluploads oft die Reihenfolge der Sitzungen
    private static let leadingNumberRE = HText.regex(#"^0?(\d{1,2})(?:[ ._\-)]|$)"#)

    /// Lehrwoche n -> Blocknummer im Moduldetail (mit gemerktem Semester ohne Pausenwochen)
    static func blockWeek(lectureWeek n: Int, start: Int, term: LectureWeeks.Term?) -> Int? {
        guard n >= 1 else { return nil }
        guard let term else { return n <= 40 ? n : nil }
        guard let m = term.monday(ofLectureWeek: n) else { return nil }
        return BerlinClock.floorDiv(m - start, 7) + 1
    }

    /// Tag -> Blocknummer (nur in der Vorlesungszeit)
    static func blockWeek(day d: Int, start: Int, term: LectureWeeks.Term?) -> Int? {
        if let term {
            guard let m = term.weekMonday(forDay: d) else { return nil }
            return BerlinClock.floorDiv(m - start, 7) + 1
        }
        let w = BerlinClock.floorDiv(StudyWeeks.monday(d) - start, 7) + 1
        return (1...20).contains(w) ? w : nil
    }

    /// Hinweis aus einem Text (Name oder erste Seite) als Lehrwoche
    static func hintWeek(_ text: String, start: Int, term: LectureWeeks.Term?) -> (week: Int, what: String)? {
        if let h = LectureWeeks.nameHint(text, stripExtension: false) {
            switch h.kind {
            case .calendarWeek:
                if let term, let m = term.monday(ofCalendarWeek: h.number) { return (BerlinClock.floorDiv(m - start, 7) + 1, "KW \(h.number)") }
            case .solution:
                if let w = blockWeek(lectureWeek: h.number + 1, start: start, term: term) { return (w, "Lösung \(h.number)") }
            default:
                if let w = blockWeek(lectureWeek: h.number, start: start, term: term) { return (w, "\(label(h.kind)) \(h.number)") }
            }
        }
        if let d = LectureWeeks.dateInName(text), let w = blockWeek(day: d, start: start, term: term) {
            return (w, "Datum \(StudyWeeks.dayMonth(d))")
        }
        return nil
    }

    static func label(_ k: LectureWeeks.NumberKind) -> String {
        switch k {
        case .calendarWeek: return "KW"
        case .week: return "Woche"
        case .solution: return "Lösung"
        case .sheet: return "Blatt"
        case .tutorial: return "Tutorium"
        case .lecture: return "Vorlesung"
        case .part: return "Teil"
        case .chapter: return "Kapitel"
        }
    }

    /// Vorschlag: zuerst die erste Seite (Titel der Folien: "Vorlesung 3", "Übungsblatt 2", ein Datum), dann die Nummer
    /// am Anfang des Namens. `firstPage` nur, wenn der Text schon gelesen ist (Suche, Wochentests, "Vorschläge suchen").
    public static func suggest(name: String, firstPage: String?, start: Int, term: LectureWeeks.Term?) -> Suggestion? {
        if let p = firstPage, !p.isEmpty {
            let head = String(HText.collapse(p).prefix(400))
            if let h = hintWeek(head, start: start, term: term) { return Suggestion(week: h.week, reason: "Inhalt: \(h.what)") }
        }
        if let m = HText.match(leadingNumberRE, HText.nfc(name)), let n = Int(m.groups[1] ?? ""), n >= 1,
           let w = blockWeek(lectureWeek: n, start: start, term: term) {
            return Suggestion(week: w, reason: "Nummer \(n) am Anfang des Namens")
        }
        return nil
    }

    // MARK: Sammelupload (Stud.IP)

    /// So viele Dateien eines Kurses an einem Tag ohne Nummer im Namen heissen "Sammelupload"
    public static let bulkMinimum = 6

    /// Stud.IP-Sammelupload zu Semesterbeginn (Woche 0 oder 1): Die Aenderungszeit sagt dann nichts ueber die Lehrwoche
    /// ("alle Folien am ersten Tag hochgeladen"). Diese Dateien stehen in "Nicht zugeordnet" mit Vorschlag. Nur Dateien
    /// ohne Zuordnung durch `LectureWeeks` und ohne Nummer im Namen, nur Vorlesung/Skript/Uebung/Loesung, keine eigenen.
    /// `files`: (id, Kurs, Tag der Aenderung, automatische Woche, Art, Nummer im Namen)
    public static func bulkUploads(_ files: [(id: String, course: String, day: Int?, week: Int, docType: String?, hint: Int?)]) -> Set<String> {
        var groups: [String: [String]] = [:]
        for f in files where f.course != "__user__" && f.hint == nil && (0...1).contains(f.week)
            && StudyClassify.lectureWeekTypes.contains(f.docType ?? "") {
            guard let d = f.day else { continue }
            groups["\(f.course)|\(d)", default: []].append(f.id)
        }
        return Set(groups.values.filter { $0.count >= bulkMinimum }.flatMap { $0 })
    }

    // MARK: Aendern (Endpunkte `ModuleLayoutEndpoints`)

    public struct EditError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// "Woche 5", "5. Woche", "Week 5" -> 5
    static let weekTitleRE = HText.regex(#"^(?:(?:lehr|vorlesungs)?woche|week)\s*0?(\d{1,2})$|^0?(\d{1,2})\.\s*(?:lehr|vorlesungs)?woche$"#)

    public static func weekNumber(inTitle t: String) -> Int? {
        guard let m = HText.match(weekTitleRE, HText.collapse(HText.nfc(t).lowercased())),
              let n = Int(m.groups[1] ?? m.groups[2] ?? ""), (1...40).contains(n) else { return nil }
        return n
    }

    static func cleanTitle(_ t: String) -> String { String(HText.collapse(t).prefix(80)) }

    /// Zeile einer automatischen Woche (anlegen, wenn noetig)
    static func autoRow(_ c: SQLiteConnection, _ m: Int64, _ w: Int, now: String) throws -> Int64 {
        if let id = try c.scalar("SELECT id FROM module_sections WHERE module_id=? AND week=?", [.integer(m), .integer(Int64(w))])?.int64 { return id }
        try c.execute("INSERT INTO module_sections(module_id, week, created_at) VALUES (?,?,?)", [.integer(m), .integer(Int64(w)), .text(now)])
        return c.lastInsertRowID
    }

    /// Neuen Abschnitt anlegen. "Woche n" ist die Lehrwoche n (eine geloeschte kommt wieder), alles andere ein eigener
    /// Abschnitt hinter `after` (sonst hinter den Lehrwochen). Rueckgabe: Schluessel des Blocks.
    @discardableResult
    public static func create(_ c: SQLiteConnection, moduleID m: Int64, title raw: String, after: String?, start: Int,
                              term: LectureWeeks.Term?, now: String) throws -> String {
        try ensureTables(c)
        let title = cleanTitle(raw)
        guard !title.isEmpty else { throw EditError(message: "Bitte einen Namen eingeben.") }
        if let n = weekNumber(inTitle: title), let w = blockWeek(lectureWeek: n, start: start, term: term) {
            let id = try autoRow(c, m, w, now: now)
            try c.execute("UPDATE module_sections SET hidden=0 WHERE id=?", [.integer(id)])
            return key(week: w)
        }
        let layout = try load(c)[m] ?? Layout()
        let rank: SQLiteValue = after.flatMap(week(ofKey:)).map { .real(layout.rank($0) + 0.5) } ?? .null
        try c.execute("INSERT INTO module_sections(module_id, title, rank, created_at) VALUES (?,?,?,?)",
                      [.integer(m), .text(title), rank, .text(now)])
        let id = c.lastInsertRowID
        // nach einer eigenen Sortierung: direkt hinter `after` einreihen
        if let a = after.flatMap(week(ofKey:)), let s = layout.sort(a) {
            try c.execute("UPDATE module_sections SET sort=sort+1 WHERE module_id=? AND sort>?", [.integer(m), .real(s)])
            try c.execute("UPDATE module_sections SET sort=? WHERE id=?", [.real(s + 1), .integer(id)])
        }
        return "s:\(id)"
    }

    /// Umbenennen; leerer Titel: wieder der automatische Name
    public static func rename(_ c: SQLiteConnection, moduleID m: Int64, key k: String, title raw: String, now: String) throws {
        try ensureTables(c)
        guard let w = week(ofKey: k) else { throw EditError(message: "Unbekannter Abschnitt.") }
        let title = cleanTitle(raw)
        if let sid = sectionID(ofWeek: w) {
            guard !title.isEmpty else { throw EditError(message: "Bitte einen Namen eingeben.") }
            try c.execute("UPDATE module_sections SET title=? WHERE id=? AND module_id=? AND week IS NULL", [.text(title), .integer(sid), .integer(m)])
            if c.changes == 0 { throw EditError(message: "Abschnitt nicht gefunden.") }
            return
        }
        let id = try autoRow(c, m, w, now: now)
        try c.execute("UPDATE module_sections SET title=? WHERE id=?", [title.isEmpty ? .null : .text(title), .integer(id)])
    }

    /// Loeschen: eigener Abschnitt weg, seine Dateien wieder automatisch; eine automatische Woche wird ausgeblendet,
    /// ihre Dateien stehen in "Nicht zugeordnet" ("Woche n" anlegen holt sie zurueck)
    public static func remove(_ c: SQLiteConnection, moduleID m: Int64, key k: String, now: String) throws {
        try ensureTables(c)
        guard let w = week(ofKey: k), w != unassignedWeek else { throw EditError(message: "Dieser Abschnitt lässt sich nicht löschen.") }
        if let sid = sectionID(ofWeek: w) {
            try c.execute("DELETE FROM module_sections WHERE id=? AND module_id=? AND week IS NULL", [.integer(sid), .integer(m)])
            if c.changes == 0 { throw EditError(message: "Abschnitt nicht gefunden.") }
        } else {
            let id = try autoRow(c, m, w, now: now)
            try c.execute("UPDATE module_sections SET hidden=1, title=NULL, sort=NULL WHERE id=?", [.integer(id)])
        }
        try c.execute("DELETE FROM module_file_places WHERE module_id=? AND section=?", [.integer(m), .text(k)])
    }

    /// Reihenfolge festlegen (alle Bloecke in der neuen Folge). Eigene Abschnitte gehoeren danach planerisch zur
    /// Lehrwoche davor.
    public static func reorder(_ c: SQLiteConnection, moduleID m: Int64, keys: [String], now: String) throws {
        try ensureTables(c)
        let weeks = keys.compactMap(week(ofKey:))
        guard weeks.count == keys.count, Set(weeks).count == weeks.count else { throw EditError(message: "Ungültige Reihenfolge.") }
        var lastWeek: Int?
        for (i, w) in weeks.enumerated() {
            if let sid = sectionID(ofWeek: w) {
                let rank: SQLiteValue = lastWeek.map { .real(Double(10 * $0) + 0.5) } ?? .real(0.5)
                try c.execute("UPDATE module_sections SET sort=?, rank=? WHERE id=? AND module_id=?", [.real(Double(i)), rank, .integer(sid), .integer(m)])
            } else {
                let id = try autoRow(c, m, w, now: now)
                try c.execute("UPDATE module_sections SET sort=? WHERE id=?", [.real(Double(i)), .integer(id)])
                if w >= 1 { lastWeek = w }
            }
        }
    }

    /// Dateien in einen Abschnitt legen (`to` nil: wieder automatisch). Nur Dateien dieses Moduls; Rueckgabe: Anzahl.
    @discardableResult
    public static func place(_ c: SQLiteConnection, moduleID m: Int64, fileIDs: [String], to: String?, now: String) throws -> Int {
        try ensureTables(c)
        if let to {
            guard let w = week(ofKey: to), (try load(c)[m] ?? Layout()).exists(w) else { throw EditError(message: "Unbekannter Abschnitt.") }
        }
        var n = 0
        for id in Set(fileIDs) {
            guard try c.queryOne("SELECT 1 FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=? AND c.module_id=?",
                                 [.text(id), .integer(m)]) != nil else { continue }
            if let to {
                try c.execute("INSERT OR REPLACE INTO module_file_places(file_id, module_id, section, placed_at) VALUES (?,?,?,?)",
                              [.text(id), .integer(m), .text(to), .text(now)])
            } else {
                try c.execute("DELETE FROM module_file_places WHERE file_id=?", [.text(id)])
            }
            n += 1
        }
        return n
    }

    /// Eigene Ordnung eines Moduls verwerfen (die App ordnet wieder selbst)
    public static func reset(_ c: SQLiteConnection, moduleID m: Int64) throws {
        guard try hasTables(c) else { return }
        try c.execute("DELETE FROM module_sections WHERE module_id=?", [.integer(m)])
        try c.execute("DELETE FROM module_file_places WHERE module_id=?", [.integer(m)])
    }
}
