import Foundation

/// Module ("Faecher") wie app/study.py: `ensure_modules`, `_file_rows`, `week_topic`, `module_detail`,
/// `modules_overview`. Ein Modul fasst die Stud.IP-Kurse eines Fachs zusammen (Vorlesung, Uebung, ...); das
/// Moduldetail ordnet die Dateien nach Lehrwoche (`StudyWeeks`) und Art (`StudyClassify`).
public enum LocalModules {
    /// `PALETTE` in app/study.py (Fachfarben: `ModuleColors`, app/colors.py)
    public static var palette: [String] { ModuleColors.palette }

    /// `OPEN`: offene Aufgaben
    static let open: Set<String> = ["geplant", "in_bearbeitung", "nachholen"]

    /// Wahrheitswert eines gespeicherten Werts wie in Python (`not c["subject"]`)
    static func truthy(_ v: SQLiteValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .integer(let i)?: return i != 0
        case .real(let d)?: return d != 0
        case .text(let s)?: return !s.isEmpty
        case .blob(let b)?: return !b.isEmpty
        }
    }

    /// Wahrheitswert eines JSON-Werts wie in Python (`if f["has_notes"]`, `x or y`); die einzige Fassung fuer Zeilen,
    /// Anfragen und Stundenplan (LocalTimetable, Import, Platzhalter)
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?: return !s.isEmpty
        case .array(let a)?: return !a.isEmpty
        case .object(let o)?: return !o.isEmpty
        }
    }

    // MARK: ensure_modules

    /// `ensure_modules(conn)`: je Fach (`courses.subject`) ein Modul, Kurse ohne Modul werden zugeordnet (Art
    /// "sonstiges" und Kurse ohne Fach nicht). Gleiche Reihenfolge, Farben und Sortierung wie Python. Seit c0721da nur
    /// fuer aktive Kurse (alte Semester bekommen kein Modul), danach gehen Module ohne aktiven Kurs aus
    /// (`Semesters.deactivateStaleModules`). Schreibt.
    public static func ensureModules(_ c: SQLiteConnection, clock: UniFlowClock) throws {
        // Schluessel wie ein Python-dict mit str: Codepunkte (Swift-Strings waeren kanonisch aequivalent gleich, also
        // "ü" und "u" + U+0308 ein Fach)
        var existing: [[Unicode.Scalar]: SQLiteValue] = [:]
        for r in try c.query("SELECT id, name FROM modules") {
            guard let name = r["name"]?.string else { continue }
            existing[Array(name.unicodeScalars)] = r["id"] ?? .null      // letzter gewinnt
        }
        var n = existing.count                                             // len(existing)
        for course in try c.query("SELECT id, subject, kind, semester FROM courses WHERE module_id IS NULL AND COALESCE(active, 1)=1") {
            if course["kind"]?.string == "sonstiges" || !truthy(course["subject"]) { continue }
            let subject = course["subject"] ?? .null
            let name = Array((subject.string ?? "").unicodeScalars)
            if existing[name] == nil {
                try c.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                              [subject, course["semester"] ?? .null, .text(try ModuleColors.next(c)), .integer(Int64(n)), .text(clock.nowISO)])
                existing[name] = .integer(c.lastInsertRowID)
                n += 1
            }
            try c.execute("UPDATE courses SET module_id=? WHERE id=?", [existing[name] ?? .null, course["id"] ?? .null])
        }
        try Semesters.deactivateStaleModules(c)
    }

    // MARK: Dateien eines Moduls

    static let fileRowsSQL = """
        SELECT f.id, f.name, f.chdate, f.status, f.favorite, f.last_opened, f.size, f.course_id, f.studip_folder,
                        c.title AS course_title, c.kind AS course_kind, c.subject, c.module_id,
                        a.doc_type, a.title AS ai_title, a.difficulty, a.est_minutes, a.topics, a.summary,
                        (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes
                 FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                 WHERE c.active=1
        """

    /// Eine Datei mit Einordnung; `chdate` bleibt als gespeicherter Wert fuer `StudyWeeks` erhalten
    struct FileRow {
        var json: [String: JSONValue]
        let chdate: SQLiteValue
        var id: JSONValue { json["id"] ?? .null }
        var docType: String? { json["doc_type"]?.string }
    }

    /// `_file_rows(conn, module_id)`: Dateien aktiver Kurse (eines Moduls), aelteste zuerst, mit `enrich_file`
    static func fileRows(_ c: SQLiteConnection, moduleID: SQLiteValue?) throws -> [FileRow] {
        var sql = fileRowsSQL
        var params: [SQLiteValue] = []
        if let moduleID {
            sql += " AND c.module_id=?"
            params.append(moduleID)
        }
        return try c.query(sql + " ORDER BY f.chdate", params).map { r in
            FileRow(json: StudyClassify.enrichFile(r.json), chdate: r["chdate"] ?? .null)
        }
    }

    /// `week_topic(files)`: erstes Analyse-Thema einer Vorlesung (sonst Uebung, Skript), sonst der KI-Titel des
    /// ersten Dokuments damit. Ohne KI (iPad) gibt es beides nicht: "".
    static func weekTopic(_ files: [FileRow]) throws -> String {
        for pref in ["vorlesung", "uebung", "skript"] {
            for f in files where f.docType == pref && truthy(f.json["topics"]) {
                guard let text = f.json["topics"]?.string else {
                    throw LocalHTTPError(status: 500, message: "Themen einer Analyse sind kein Text")   // json.loads(Zahl)
                }
                guard let t = try? PyJSON.parse(text) else { continue }                               // JSONDecodeError
                if let first = try firstItem(t) { return PyText.str(first) }
            }
        }
        for f in files where truthy(f.json["ai_title"]) {
            return f.json["ai_title"]?.string ?? PyText.str(PyJSON(f.json["ai_title"] ?? .null))
        }
        return ""
    }

    /// `t[0]`, wenn `t` wahr ist (Liste: erster Eintrag, Text: erstes Zeichen); Python scheitert sonst (500)
    private static func firstItem(_ t: PyJSON) throws -> PyJSON? {
        switch t {
        case .null: return nil
        case .bool(false): return nil
        case .int(let d) where d == "0": return nil
        case .float(let f) where f == 0: return nil
        case .array(let a): return a.first
        case .string(let s): return s.unicodeScalars.first.map { .string(String($0)) }
        case .object(let m) where m.isEmpty: return nil
        default: throw LocalHTTPError(status: 500, message: "Themen einer Analyse sind keine Liste")
        }
    }

    // MARK: module_detail

    /// Gruppen eines Wochenblocks in der Reihenfolge von Python
    static let groupKeys = ["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"]
    static let groupOf = ["vorlesung": "vorlesungen", "uebung": "uebungen", "loesung": "loesungen", "skript": "skripte", "klausur": "klausuren"]

    /// Zeitpunkte, die das Moduldetail braucht: heute (Berlin) und der Semesterbeginn
    struct Dates {
        let today: Int
        let start: Int

        init(_ c: SQLiteConnection, clock: UniFlowClock) throws {
            today = BerlinClock.parseISODate(clock.today) ?? 0
            start = try StudyWeeks.semesterStart(c, today: today)
        }
    }

    /// Lehrwoche einer Datei wie `file_week` in app/study.py, eine Regel fuer Moduldetail, Lernplan (`StudyPlan.units`),
    /// Unterlagen zum Termin (`eventMaterials`) und Aufzeichnungen (`OpencastStore`): Klausuren und Klausur-Loesungen
    /// eigener Block (-2, keine Lehrwoche), sonst der Hinweis aus Name/Ordner (Blatt 3 / VL03 -> Lehrwoche 3), wenn die
    /// Datei aus diesem Semester ist, sonst die Woche der Aenderung (`StudyWeeks.weekIndex`). Vorher nahmen Lernplan und
    /// Termin nur die Woche der Aenderung ("Blatt 3", in Woche 5 hochgeladen: Moduldetail Woche 3, Lernplan Woche 5).
    static func week(_ f: FileRow, dates: Dates) throws -> Int {
        try week(docType: f.docType, subLabel: f.json["sub_label"]?.string, weekHint: f.json["week_hint"]?.int, chdate: f.chdate,
                 start: dates.start, today: dates.today)
    }

    /// Wie oben, mit den Feldern einzeln (Aufzeichnungen ohne Dateizeile)
    static func week(docType: String?, subLabel: String?, weekHint: Int?, chdate: SQLiteValue, start: Int, today: Int) throws -> Int {
        if docType == "klausur" || subLabel == "Klausur-Lösung" { return -2 }
        let index = try StudyWeeks.weekIndex(start: start, chdate: chdate, today: today)
        if let hint = weekHint, hint != 0, index >= 0 { return hint }
        return index
    }

    /// `sorted(weeks, key=lambda w: (w == -2, w == -1, w))`: Lehrwochen, dann aeltere Unterlagen, dann Klausuren
    static func weekOrder(_ a: Int, _ b: Int) -> Bool {
        let ka = (a == -2 ? 1 : 0, a == -1 ? 1 : 0, a), kb = (b == -2 ? 1 : 0, b == -1 ? 1 : 0, b)
        return ka < kb
    }

    /// `module_detail(conn, module_id)`; nil, wenn es das Modul nicht gibt (Python: `{}` und 404)
    public static func detail(_ c: SQLiteConnection, moduleID: SQLiteValue, clock: UniFlowClock) throws -> [String: JSONValue]? {
        try detail(c, moduleID: moduleID, dates: Dates(c, clock: clock))
    }

    static func detail(_ c: SQLiteConnection, moduleID: SQLiteValue, dates: Dates) throws -> [String: JSONValue]? {
        guard let m = try c.queryOne("SELECT * FROM modules WHERE id=?", [moduleID]) else { return nil }
        let start = dates.start
        let files = try fileRows(c, moduleID: moduleID)
        var weeks: [Int: [FileRow]] = [:]
        for f in files { weeks[try week(f, dates: dates), default: []].append(f) }
        let order = weeks.keys.sorted(by: weekOrder)
        var outWeeks: [JSONValue] = []
        for w in order {
            let fl = weeks[w]!
            var grp: [String: [FileRow]] = Dictionary(uniqueKeysWithValues: groupKeys.map { ($0, []) })
            for f in fl { grp[groupOf[f.docType ?? ""] ?? "sonstiges"]!.append(f) }
            var block: [String: JSONValue] = ["week": .number(Double(w)), "label": .string(StudyWeeks.weekLabel(start: start, week: w)),
                                              "topic": .string(try weekTopic(fl)), "count": .number(Double(fl.count))]
            for k in groupKeys {
                // sort(key=(sub_label or "", name or "")), stabil wie Python
                let sorted = grp[k]!.enumerated().sorted { x, y in
                    let lx = x.element.json["sub_label"]?.string ?? "", ly = y.element.json["sub_label"]?.string ?? ""
                    if PyText.less(lx, ly) { return true }
                    if PyText.less(ly, lx) { return false }
                    let nx = x.element.json["name"]?.string ?? "", ny = y.element.json["name"]?.string ?? ""
                    if PyText.less(nx, ny) { return true }
                    if PyText.less(ny, nx) { return false }
                    return x.offset < y.offset
                }
                block[k] = .array(sorted.map { .object($0.element.json) })
            }
            outWeeks.append(.object(block))
        }
        let courses = try c.rows("SELECT id, title, kind, number FROM courses WHERE module_id=? ORDER BY kind, title", [moduleID])
        let tasks = try c.rows("""
            SELECT t.*, p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
                                         WHERE p.module_id=? ORDER BY p.date
            """, [moduleID])
        var done = Set(tasks.filter { $0["status"]?.string == "erledigt" && truthy($0["file_id"]) }.map { $0["file_id"] ?? .null })
        done.formUnion(files.filter { $0.json["status"]?.string == "erledigt" }.map(\.id))
        let learnable = files.filter { ["vorlesung", "uebung", "skript"].contains($0.docType ?? "") }
        var progress = 0
        if !learnable.isEmpty {
            let k = learnable.filter { done.contains($0.id) }.count
            progress = Int((100.0 * Double(k) / Double(learnable.count)).rounded(.toNearestOrEven))    // round() in Python
        }
        let next = try c.queryOne("""
            SELECT date, title FROM study_packages WHERE module_id=? AND date>=? AND status IN ('geplant','in_bearbeitung') ORDER BY date LIMIT 1
            """, [moduleID, .text(BerlinClock.isoDate(dates.today))])
        return ["module": .object(m.json), "courses": .array(courses.map(JSONValue.object)), "weeks": .array(outWeeks),
                "files": .array(files.map { .object($0.json) }), "progress": .number(Double(progress)),
                "new_count": .number(Double(files.filter { $0.json["status"]?.string == "neu" }.count)),
                "open_tasks": .number(Double(tasks.filter { open.contains($0["status"]?.string ?? "") }.count)),
                "next_package": next.map { .object($0.json) } ?? .null,
                "notes": .array(files.filter { truthy($0.json["has_notes"]) }.map { .object($0.json) })]
    }

    // MARK: modules_overview

    /// Termine der naechsten 14 Tage wie in `modules_overview`: `timetable.occurrences` (Port in `LocalTimetable`,
    /// S5) von heute bis heute + 14, nur Status None/"teilnahme" und noch nicht vorbei, nach Datum und Beginn (schon so
    /// sortiert). "Noch nicht vorbei" ist dort `o["date"] > heute or o["end"] >= t.strftime("%H:%M")` mit einem
    /// `date` t, also immer gegen "00:00": auch heute schon beendete Termine zaehlen wie am PC. Scheitert etwas (z. B.
    /// ein Termin ohne Ende), gibt es wie im `except` dort keine Termine.
    static func upcomingOccurrences(_ c: SQLiteConnection, today: Int, clock: UniFlowClock) throws -> [[String: JSONValue]] {
        guard let all = try? LocalTimetable.occurrences(c, from: today, to: today + 14) else { return [] }
        let todayISO = BerlinClock.isoDate(today)
        var out: [[String: JSONValue]] = []
        for o in all {
            guard let occ = o.object else { continue }
            let status = occ["status"] ?? .null
            guard status == .null || status == "teilnahme" else { continue }
            // date ist immer Text (isoformat); ein Ende, das kein Text ist, laesst den Vergleich scheitern (TypeError)
            if let d = occ["date"]?.string, PyText.less(todayISO, d) {
                out.append(occ)
                continue
            }
            guard let end = occ["end"]?.string else { return [] }
            if !PyText.less(end, "00:00") { out.append(occ) }
        }
        return out
    }

    /// `modules_overview(conn)`: alle Module mit Zahlen fuer die Karten auf "Meine Module". Schreibt
    /// (`ensure_modules`), darum in einer Transaktion aufrufen.
    public static func overview(_ c: SQLiteConnection, clock: UniFlowClock) throws -> [JSONValue] {
        try ensureModules(c, clock: clock)
        let dates = try Dates(c, clock: clock)
        let occ = try upcomingOccurrences(c, today: dates.today, clock: clock)
        var out: [JSONValue] = []
        for m in try c.query("SELECT * FROM modules ORDER BY sort, name") {
            let id = m["id"] ?? .null
            guard let d = try detail(c, moduleID: id, dates: dates) else { continue }
            let mid = m.json["id"] ?? .null
            let next = occ.first { $0["module_id"] == mid }
            let weeks = d["weeks"]?.array ?? []
            let topics = weeks.filter { truthy($0["topic"]) && ($0["week"]?.int ?? 0) >= 1 }.compactMap { $0["topic"] }
            let tests = try c.scalar("SELECT COUNT(*) AS n FROM tests WHERE module_id=?", [id])?.int ?? 0
            let tasks = try c.scalar("SELECT COUNT(*) AS n FROM study_tasks st JOIN study_packages p ON p.id=st.package_id WHERE p.module_id=?", [id])?.int ?? 0
            var row = m.json
            row["file_count"] = .number(Double(d["files"]?.array?.count ?? 0))
            row["new_count"] = d["new_count"]
            row["open_tasks"] = d["open_tasks"]
            row["progress"] = d["progress"]
            row["next_package"] = d["next_package"]
            row["next_event"] = next.map(JSONValue.object) ?? .null
            row["task_count"] = .number(Double(tasks))
            row["test_count"] = .number(Double(tests))
            row["topics"] = .array(Array(topics.suffix(3)))
            row["courses"] = .number(Double(d["courses"]?.array?.count ?? 0))
            row["weeks"] = .number(Double(weeks.filter { ($0["week"]?.int ?? 0) >= 1 }.count))
            out.append(.object(row))
        }
        return out
    }
}

extension PyJSON {
    /// Wert aus der Datenbank als Python-Wert (fuer `str()` von Zahlen und Text)
    init(_ v: JSONValue) {
        switch v {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .number(let n): self = n == n.rounded() && abs(n) < 9e15 ? .int(String(Int64(n))) : .float(n)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map(PyJSON.init))
        case .object(let o): self = .object(o.keys.sorted().map { PyJSON.Member($0, PyJSON(o[$0]!)) })
        }
    }
}
