import Foundation

/// Vorlesungs-Seitenmarker, Stoffumfang, Aufgabenindex, gemeinsame Wochentests, Nachtraege und Probeklausuren wie
/// app/weekly.py (PR #6, zusammengefuehrt am 30.10.2026; Regel des Inhabers 4/6/5). Gleiche Tabellen
/// (`SchemaSQL.weekly`), gleiche Texte in der Datenbank (JSON in Python-Reihenfolge ueber `PyJSON`), gleiche Antworten;
/// gemeinsame Faelle: packages/shared-contracts/fixtures/local-backend/weekly.json (tools/gen-weekly-fixture.py).
///
/// Ablauf auf dem Geraet wie am PC: Seitentexte werden vor jedem Schritt asynchron sichergestellt
/// (`ScriptSearch.pageTexts`), danach liest der Kern sie synchron aus `page_texts` (`Weekly.Pages`).
enum Weekly {
    static let localUser = "local"
    static let lectureTypes: Set<String> = ["vorlesung", "skript"]
    static let taskTypes: Set<String> = ["uebung", "loesung", "klausur"]
    static let sourceText: [String: String] = [
        "hoersaaluebung": "Hörsaalübung", "gruppenuebung": "Gruppenübung", "uebungsblatt": "Übungsblatt",
        "zusatz": "Zusatzübung", "tutorium": "Tutorium", "altklausur": "Altklausur", "loesung": "Musterlösung",
    ]
    static let expectable = ["hoersaaluebung", "gruppenuebung", "uebungsblatt", "zusatz", "tutorium"]
    /// Vorlesungsseiten mit mindestens 60 % der besten Trefferguete muessen behandelt sein
    static let strong = 0.6
    /// Mindestguete einer Seitenzuordnung (BM25)
    static let minRefScore = 6.0

    struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { message = m }
        var description: String { message }
    }

    // MARK: Hilfen wie in Python

    /// `_h(*parts)`: sha1 von `json.dumps(parts, ensure_ascii=False, sort_keys=True)`, erste 16 Zeichen
    static func h(_ parts: PyJSON...) -> String {
        String(WeeklySHA1.hex(sorted(.array(parts)).dumps(ensureASCII: false)).prefix(16))
    }

    /// Schluessel von Objekten sortiert (`sort_keys=True`)
    static func sorted(_ v: PyJSON) -> PyJSON {
        switch v {
        case .array(let a): return .array(a.map(sorted))
        case .object(let m): return .object(m.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
                                                .map { PyJSON.Member($0.key, sorted($0.value)) })
        default: return v
        }
    }

    static func s(_ t: String) -> PyJSON { .string(t) }
    static func i(_ n: Int) -> PyJSON { .int(String(n)) }

    /// `_norm(t)`: Suchform, Leerraum zu einem Zeichen, klein
    static func norm(_ t: String) -> String {
        PyText.lower(PyText.strip(spaces.sub(ScriptSearch.normalize(t), " ")))
    }
    static let spaces = PyRegex(#"\s+"#)

    /// `page_fp(text)`: Seiten-Fingerabdruck (leer bei weniger als 12 Zeichen)
    static func pageFP(_ text: String) -> String {
        let n = norm(text)
        return n.unicodeScalars.count >= 12 ? String(WeeklySHA1.hex(n).prefix(16)) : ""
    }

    /// Codepunkte wie `len(str)` in Python
    static func len(_ s: String) -> Int { s.unicodeScalars.count }

    // MARK: Zeit (naive Ortszeit wie datetime ohne Zone)

    /// "YYYY-MM-DDTHH:MM:SS" (auch ohne Sekunden) -> Sekunden ohne Zone
    static func seconds(_ iso: String) -> Int? { AnnotationEndpoints.naiveSeconds(iso) }

    /// Sekunden ohne Zone -> `datetime.isoformat()` ohne Sekundenbruchteile
    static func iso(_ seconds: Int) -> String {
        let day = Int((Double(seconds) / 86_400).rounded(.down))
        let rest = seconds - day * 86_400
        return BerlinClock.isoDate(day) + "T" + BerlinClock.pad(rest / 3600, 2) + ":" + BerlinClock.pad(rest % 3600 / 60, 2)
            + ":" + BerlinClock.pad(rest % 60, 2)
    }

    static func day(_ iso: String) -> Int? { BerlinClock.parseISODate(String(iso.prefix(10))) }

    /// `date.isocalendar()`: (ISO-Jahr, Woche)
    static func isoWeek(_ day: Int) -> (year: Int, week: Int) {
        let thursday = day - BerlinClock.weekday(day) + 3
        let year = BerlinClock.civil(thursday).year
        let jan1 = BerlinClock.dayNumber(year: year, month: 1, day: 1)
        return (year, (thursday - jan1) / 7 + 1)
    }

    static func isoWeekText(_ day: Int) -> String {
        let w = isoWeek(day)
        return "\(w.year)-W\(BerlinClock.pad(w.week, 2))"
    }

    // MARK: Einstellungen

    struct Settings {
        var publishHours: Double, maxDelayHours: Double, dailyLimit: Int, questions: Int
        var json: PyJSON {
            .object([.init("publish_hours", .float(publishHours)), .init("max_delay_hours", .float(maxDelayHours)),
                     .init("daily_limit", Weekly.i(dailyLimit)), .init("questions", Weekly.i(questions))])
        }
    }

    /// `_settings(conn)`
    static func settings(_ c: SQLiteConnection) throws -> Settings {
        var s: [String: String] = [:]
        for r in try c.query("SELECT key, value FROM settings") { if let k = r["key"]?.string { s[k] = r["value"]?.string ?? "" } }
        let defaults = Dictionary(uniqueKeysWithValues: Migrations.weeklyDefaults.map { ($0.0, $0.1) })
        func num(_ k: String) -> Double {
            let raw = s[k].flatMap { $0.isEmpty ? nil : $0 } ?? defaults[k]!
            return PyConvert.float(raw) ?? PyConvert.float(defaults[k]!)!
        }
        return Settings(publishHours: num("weekly_publish_hours"), maxDelayHours: num("weekly_max_delay_hours"),
                        dailyLimit: Int(num("weekly_ai_daily_limit")), questions: Int(num("weekly_questions")))
    }

    // MARK: Seitentexte

    /// Gespeicherte Seitentexte (vorher mit `ensurePages` gelesen)
    static func pageTexts(_ c: SQLiteConnection, _ fileID: String) throws -> [String] {
        if case .fresh(let pages) = try ScriptSearch.storedPages(c, fileID: fileID, files: nil) { return pages }
        return []
    }

    /// Seitentexte der Dateien sicherstellen (aus der PDF lesen und speichern, wenn noetig)
    static func ensurePages(_ fileIDs: [String], _ ctx: LocalContext) async throws {
        for id in fileIDs { _ = try await ScriptSearch.pageTexts(fileID: id, database: ctx.database, files: ctx.files, clock: ctx.clock) }
    }

    /// PDFs eines Moduls (Vorlesungen, Skripte, Uebungen, Loesungen, Klausuren)
    static func moduleFileIDs(_ moduleID: Int, _ ctx: LocalContext) async throws -> [String] {
        try await ctx.database.withConnection { c in
            try LocalModules.fileRows(c, moduleID: .integer(Int64(moduleID))).compactMap { f in
                let t = f.docType ?? ""
                guard lectureTypes.contains(t) || taskTypes.contains(t), PyText.lower(f.json["name"]?.string ?? "").hasSuffix(".pdf") else { return nil }
                return f.json["id"]?.string
            }
        }
    }

    /// `doc_version(conn, file_id)`
    static func docVersion(_ c: SQLiteConnection, _ fileID: String) throws -> String {
        let ch = try c.queryOne("SELECT chdate FROM files WHERE id=?", [.text(fileID)])?["chdate"]
        let pages = try pageTexts(c, fileID)
        let chText = ch.flatMap { LocalModules.truthy($0) ? PyJSON(($0.json ?? .null)).dumps : nil } ?? "0"
        return "\(chText)-\(pages.count)-\(h(.array(pages.map { s(norm($0)) })).prefix(10))"
    }

    /// `_file(conn, file_id)`
    static func file(_ c: SQLiteConnection, _ fileID: String) throws -> [String: JSONValue]? {
        try c.rows("""
            SELECT f.id, f.name, f.chdate, f.studip_folder, f.local_path, f.first_seen, c.module_id, c.title AS course_title,
                   a.doc_type, a.title AS ai_title FROM files f JOIN courses c ON c.id=f.course_id
            LEFT JOIN analysis a ON a.file_id=f.id WHERE f.id=?
            """, [.text(fileID)]).first.map(StudyClassify.enrichFile)
    }

    // MARK: Lehrwoche und Vorlesungstermin

    /// `lecture_week(conn, d)`
    static func lectureWeek(_ c: SQLiteConnection, _ d: Int, today: Int) throws -> Int {
        let t = try LocalTimetable.term(c)
        var start: Int
        if let ts = t["start"]?.string.flatMap(BerlinClock.parseISODate), let te = t["end"]?.string.flatMap(BerlinClock.parseISODate),
           ts <= d, d <= te + 21 {
            start = StudyWeeks.monday(ts)
        } else {
            start = try StudyWeeks.semesterStart(c, today: today)
        }
        return max(1, (StudyWeeks.monday(d) - start) / 7 + 1)
    }

    /// `lecture_occurrence(conn, module_id, d)`: letzter Vorlesungstermin des Moduls an dem Tag (ohne Ausfaelle)
    static func lectureOccurrence(_ c: SQLiteConnection, _ moduleID: Int, _ d: Int) -> [String: JSONValue]? {
        guard let occ = try? LocalTimetable.occurrences(c, from: d, to: d) else { return nil }
        let mine = occ.compactMap(\.object).filter { o in
            o["module_id"]?.int == moduleID && [nil, "vorlesung"].contains(o["kind"]?.string)
                && !["ausfall", "verschoben"].contains(o["status"]?.string ?? "")
        }
        return mine.enumerated().sorted { ($0.element["end"]?.string ?? "", $0.offset) < ($1.element["end"]?.string ?? "", $1.offset) }
            .last?.element
    }

    /// `last_lecture_date(conn, module_id, today)`
    static func lastLectureDate(_ c: SQLiteConnection, _ moduleID: Int, today: Int) -> (Int, [String: JSONValue]?) {
        for back in 0..<15 {
            if let o = lectureOccurrence(c, moduleID, today - back) { return (today - back, o) }
        }
        return (today, nil)
    }

    /// `_lecture_end(conn, module_id, d, now)`
    static func lectureEnd(_ c: SQLiteConnection, _ moduleID: Int, _ d: Int, now: Int) -> (String, String) {
        if let o = lectureOccurrence(c, moduleID, d), let end = o["end"]?.string { return ("\(BerlinClock.isoDate(d))T\(end):00", "stundenplan") }
        if d == Int((Double(now) / 86_400).rounded(.down)) { return (iso(now), "manuell") }
        return ("\(BerlinClock.isoDate(d))T18:00:00", "manuell")
    }
}

// MARK: - Marker

extension Weekly {
    static func markerRow(_ c: SQLiteConnection, _ id: Int64) throws -> [String: JSONValue]? {
        try c.rows("SELECT * FROM lecture_markers WHERE id=? AND deleted_at IS NULL", [.integer(id)]).first
    }

    /// `list_markers(conn, module_id, file_id)`
    static func listMarkers(_ c: SQLiteConnection, moduleID: Int?, fileID: String?, user: String = localUser) throws -> [[String: JSONValue]] {
        var sql = "SELECT * FROM lecture_markers WHERE deleted_at IS NULL AND (user_id=? OR scope='course')"
        var p: [SQLiteValue] = [.text(user)]
        if let moduleID { sql += " AND module_id=?"; p.append(.integer(Int64(moduleID))) }
        if let fileID { sql += " AND file_id=?"; p.append(.text(fileID)) }
        return try c.rows(sql + " ORDER BY file_id, page", p).map { m in
            var m = m
            m["page_range"] = .array(try range(c, m).map { .number(Double($0)) })
            return m
        }
    }

    /// `_range_of(conn, m)`
    static func range(_ c: SQLiteConnection, _ m: [String: JSONValue]) throws -> [Int] {
        let prev = try c.scalar("""
            SELECT MAX(page) AS p FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope=?
            AND (scope='course' OR user_id=?) AND page < ?
            """, [v(m["file_id"]), v(m["scope"]), v(m["user_id"]), v(m["page"])])?.int ?? 0
        return [prev + 1, m["page"]?.int ?? 0]
    }

    static func v(_ j: JSONValue?) -> SQLiteValue { j.flatMap(SQLiteValue.init(json:)) ?? .null }

    /// `_check_order(conn, m, exclude_id)`
    static func checkOrder(_ c: SQLiteConnection, _ m: [String: JSONValue], exclude: Int64? = nil) throws {
        let others = try c.rows("""
            SELECT id, page, lecture_date FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope=?
            AND (scope='course' OR user_id=?) AND id IS NOT ?
            """, [v(m["file_id"]), v(m["scope"]), v(m["user_id"]), exclude.map { .integer($0) } ?? .null])
        let page = m["page"]?.int ?? 0, date = m["lecture_date"]?.string ?? ""
        for o in others {
            let op = o["page"]?.int ?? 0, od = o["lecture_date"]?.string ?? ""
            if op == page { throw Failure("Auf Seite \(page) liegt bereits ein Marker.") }
            if (op < page && od > date) || (op > page && od < date) {
                throw Failure("Reihenfolge passt nicht: Seite \(op) ist am \(od) markiert. Spätere Seiten können nicht vor früheren behandelt worden sein.")
            }
        }
    }

    static let headSkip = PyRegex(#"^(seite|folie|page)\s*\d"#, ignoreCase: true)
    static let headLetters = PyRegex(#"[A-Za-zÄÖÜäöü]{4}"#)
    static let headNoise = PyRegex(#"universit|institut|hannover|prof\.|dr\.|©|\d{1,2}\.\d{1,2}\.\d{2,4}"#, ignoreCase: true)

    /// `str.splitlines()`: Zeilenenden wie Python (\n, \r, \r\n, \v, \f, \x1c–\x1e, \x85, \u2028, \u2029)
    static func splitLines(_ s: String) -> [String] {
        var out: [String] = [], cur = String.UnicodeScalarView()
        var it = Array(s.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar? = it.next()
        while let u = pending {
            pending = it.next()
            switch u.value {
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                out.append(String(cur)); cur = .init()
            case 0x0D:
                out.append(String(cur)); cur = .init()
                if pending?.value == 0x0A { pending = it.next() }
            default:
                cur.append(u)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    /// `suggest_topic(pages, frm, to)`: haeufigste erste sinnvolle Zeilen der Seiten im Bereich
    static func suggestTopic(_ pages: [String], from frm: Int, to: Int) -> String {
        var counts: [String: Int] = [:], order: [String] = []
        let lo = max(0, frm - 1), hi = min(pages.count, max(lo, to))
        for t in pages[lo..<hi] {
            for raw in splitLines(ScriptSearch.normalize(t)) {
                let line = PyText.strip(raw, chars: " \t•-–:")
                let n = len(line)
                if n >= 4, n <= 70, headLetters.found(in: line), headSkip.match(line) == nil, !headNoise.found(in: line) {
                    if counts[line] == nil { order.append(line) }
                    counts[line, default: 0] += 1
                    break
                }
            }
        }
        // Counter.most_common: nach Anzahl, bei Gleichstand in der Reihenfolge des ersten Auftretens
        let top = order.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }.prefix(3).map(\.element)
        return String(top.joined(separator: " · ").unicodeScalars.prefix(120))
    }

    /// `marker_preview(conn, file_id, page, ...)`
    static func markerPreview(_ c: SQLiteConnection, fileID: String, page: Int, user: String = localUser, now: Int,
                              lectureDate: String? = nil) throws -> [String: JSONValue] {
        guard let f = try file(c, fileID), let moduleID = f["module_id"]?.int else {
            throw Failure("Das Dokument gehört zu keinem Modul. Bitte zuerst einem Modul zuordnen.")
        }
        let pages = try pageTexts(c, fileID)
        guard !pages.isEmpty else { throw Failure("Für dieses Dokument liegt kein Seitentext vor (nur PDFs mit Textebene).") }
        guard (1...pages.count).contains(page) else { throw Failure("Seite \(page) gibt es nicht (1–\(pages.count)).") }
        let prev = try c.scalar("""
            SELECT MAX(page) AS p FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope='personal'
            AND user_id=? AND page < ?
            """, [.text(fileID), .text(user), .integer(Int64(page))])?.int ?? 0
        let frm = prev + 1
        let existing = try c.rows("""
            SELECT id, lecture_date, topic FROM lecture_markers WHERE deleted_at IS NULL AND file_id=? AND scope='personal'
            AND user_id=? AND page=?
            """, [.text(fileID), .text(user), .integer(Int64(page))]).first
        let today = Int((Double(now) / 86_400).rounded(.down))
        var d: Int, occ: [String: JSONValue]?
        if let lectureDate {
            guard let x = BerlinClock.parseISODate(lectureDate) else { throw Failure("Ungültiges Datum: \(lectureDate)") }
            d = x; occ = lectureOccurrence(c, moduleID, d)
        } else if let e = existing, let x = e["lecture_date"]?.string.flatMap(BerlinClock.parseISODate) {
            d = x; occ = lectureOccurrence(c, moduleID, d)
        } else {
            (d, occ) = lastLectureDate(c, moduleID, today: today)
        }
        if d > today { throw Failure("Der Vorlesungstermin liegt in der Zukunft. Markiert wird nur bereits behandelter Stoff.") }
        let (end, src) = lectureEnd(c, moduleID, d, now: now)
        let st = try settings(c)
        let pub = (seconds(end) ?? now) + Int((st.publishHours * 3600).rounded())
        var lecture: JSONValue = .null
        if let occ { lecture = ["title": occ["title"] ?? .null, "start": occ["start"] ?? .null, "end": occ["end"] ?? .null, "room": occ["room"] ?? .null] }
        let topic = existing?["topic"].flatMap { LocalModules.truthy($0) ? $0.string : nil } ?? suggestTopic(pages, from: frm, to: page)
        return [
            "file_id": .string(fileID), "module_id": .number(Double(moduleID)), "page": .number(Double(page)),
            "page_count": .number(Double(pages.count)), "range": [.number(Double(frm)), .number(Double(page))],
            "lecture_date": .string(BerlinClock.isoDate(d)), "lecture_end": .string(end), "lecture_source": .string(src),
            "lecture": lecture, "week_no": .number(Double(try lectureWeek(c, d, today: today))), "topic": .string(topic),
            "existing": existing.map(JSONValue.object) ?? .null, "publish_at": .string(iso(pub)), "publish_hours": .number(st.publishHours),
        ]
    }

    /// `create_marker(conn, file_id, page, ...)`
    static func createMarker(_ c: SQLiteConnection, fileID: String, page: Int, user: String = localUser, lectureDate: String? = nil,
                             topic: String? = nil, pageKey: String? = nil, now: Int) throws -> [String: JSONValue] {
        let pv = try markerPreview(c, fileID: fileID, page: page, user: user, now: now, lectureDate: lectureDate)
        let pages = try pageTexts(c, fileID)
        let d = BerlinClock.parseISODate(pv["lecture_date"]?.string ?? "")!
        let t = PyText.strip(topic ?? "")
        let cols: [(String, SQLiteValue)] = [
            ("user_id", .text(user)), ("module_id", v(pv["module_id"])), ("file_id", .text(fileID)), ("doc_version", .text(try docVersion(c, fileID))),
            ("page", .integer(Int64(page))), ("page_key", pageKey.map { .text($0) } ?? .null), ("page_fingerprint", .text(pageFP(pages[page - 1]))),
            ("page_count", .integer(Int64(pages.count))), ("lecture_date", .text(BerlinClock.isoDate(d))), ("lecture_end", v(pv["lecture_end"])),
            ("lecture_source", v(pv["lecture_source"])), ("iso_week", .text(isoWeekText(d))), ("week_no", v(pv["week_no"])),
            ("topic", t.isEmpty ? v(pv["topic"]) : .text(t)), ("scope", .text("personal")), ("created_at", .text(iso(now))),
        ]
        var m: [String: JSONValue] = [:]
        for (k, x) in cols { m[k] = x.json ?? .null }
        try checkOrder(c, m)
        try c.execute("INSERT INTO lecture_markers(\(cols.map(\.0).joined(separator: ","))) VALUES (\(Array(repeating: "?", count: cols.count).joined(separator: ",")))",
                      cols.map(\.1))
        var row = try markerRow(c, c.lastInsertRowID) ?? [:]
        row["page_range"] = pv["range"]
        row["publish_at"] = pv["publish_at"]
        return row
    }

    /// `update_marker(conn, marker_id, ...)`
    static func updateMarker(_ c: SQLiteConnection, id: Int64, user: String = localUser, page: Int? = nil, lectureDate: String? = nil,
                             topic: String? = nil, pageKey: String? = nil, now: Int) throws -> [String: JSONValue] {
        guard let m = try markerRow(c, id) else { throw Failure("Marker nicht gefunden.") }
        if m["scope"]?.string == "course", m["user_id"]?.string != user {
            throw Failure("Kursmarker können nur von der Person geändert werden, die sie freigegeben hat.")
        }
        var new = m
        if let page {
            let pages = try pageTexts(c, m["file_id"]?.string ?? "")
            guard (1...max(1, pages.count)).contains(page), page <= pages.count else { throw Failure("Seite \(page) gibt es nicht (1–\(pages.count)).") }
            new["page"] = .number(Double(page)); new["page_fingerprint"] = .string(pageFP(pages[page - 1]))
            new["doc_version"] = .string(try docVersion(c, m["file_id"]?.string ?? "")); new["page_count"] = .number(Double(pages.count))
            new["needs_review"] = 0; new["review_note"] = .null; new["page_key"] = pageKey.map { .string($0) } ?? .null
        }
        if let lectureDate, !lectureDate.isEmpty {
            guard let d = BerlinClock.parseISODate(lectureDate) else { throw Failure("Ungültiges Datum: \(lectureDate)") }
            if d > Int((Double(now) / 86_400).rounded(.down)) {
                throw Failure("Der Vorlesungstermin liegt in der Zukunft. Markiert wird nur bereits behandelter Stoff.")
            }
            let mid = m["module_id"]?.int ?? 0
            let (end, src) = lectureEnd(c, mid, d, now: now)
            new["lecture_date"] = .string(BerlinClock.isoDate(d)); new["lecture_end"] = .string(end); new["lecture_source"] = .string(src)
            new["week_no"] = .number(Double(try lectureWeek(c, d, today: Int((Double(now) / 86_400).rounded(.down)))))
            new["iso_week"] = .string(isoWeekText(d))
        }
        if let topic { new["topic"] = .string(PyText.strip(topic)) }
        try checkOrder(c, new, exclude: id)
        try c.execute("""
            UPDATE lecture_markers SET page=?, page_key=?, page_fingerprint=?, doc_version=?, page_count=?, needs_review=?, review_note=?,
            lecture_date=?, lecture_end=?, lecture_source=?, week_no=?, iso_week=?, topic=?, updated_at=? WHERE id=?
            """, [v(new["page"]), v(new["page_key"]), v(new["page_fingerprint"]), v(new["doc_version"]), v(new["page_count"]),
                  v(new["needs_review"]), v(new["review_note"]), v(new["lecture_date"]), v(new["lecture_end"]), v(new["lecture_source"]),
                  v(new["week_no"]), v(new["iso_week"]), v(new["topic"]), .text(iso(now)), .integer(id)])
        return try markerRow(c, id) ?? [:]
    }

    /// `delete_marker(conn, marker_id)`
    static func deleteMarker(_ c: SQLiteConnection, id: Int64, user: String = localUser, now: Int) throws {
        guard let m = try markerRow(c, id) else { throw Failure("Marker nicht gefunden.") }
        guard m["user_id"]?.string == user else { throw Failure("Nur eigene Marker können gelöscht werden.") }
        try c.execute("UPDATE lecture_markers SET deleted_at=? WHERE id=?", [.text(iso(now)), .integer(id)])
    }

    /// `release_marker(conn, marker_id, confirm)`: ausdruecklich als Kursmarker freigeben
    static func releaseMarker(_ c: SQLiteConnection, id: Int64, user: String = localUser, confirm: Bool, now: Int) throws -> [String: JSONValue] {
        guard confirm else { throw Failure("Freigabe muss ausdrücklich bestätigt werden (confirm=true).") }
        guard let m = try markerRow(c, id), m["user_id"]?.string == user else { throw Failure("Marker nicht gefunden.") }
        if try c.queryOne("SELECT 1 FROM lecture_markers WHERE deleted_at IS NULL AND scope='course' AND file_id=? AND page=?",
                          [v(m["file_id"]), v(m["page"])]) != nil {
            throw Failure("Für diese Seite gibt es bereits einen Kursmarker.")
        }
        var course = m
        course["scope"] = "course"
        try checkOrder(c, course)
        let cols = try c.columnNames("lecture_markers").filter { $0 != "id" }
        var vals = cols.map { v(course[$0]) }
        vals[cols.firstIndex(of: "released_at")!] = .text(iso(now))
        vals[cols.firstIndex(of: "released_by")!] = .text(user)
        try c.execute("INSERT INTO lecture_markers(\(cols.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: cols.count).joined(separator: ",")))", vals)
        return try markerRow(c, c.lastInsertRowID) ?? [:]
    }

    /// `revalidate_markers(conn, file_id)`: nach einer Dokumentaenderung Marker wiederfinden oder zur Pruefung markieren
    @discardableResult
    static func revalidateMarkers(_ c: SQLiteConnection, fileID: String?, now: Int) throws -> [JSONValue] {
        var changes: [JSONValue] = []
        let sql = "SELECT * FROM lecture_markers WHERE deleted_at IS NULL" + (fileID != nil ? " AND file_id=?" : "")
        for m in try c.rows(sql, fileID.map { [.text($0)] } ?? []) {
            let fid = m["file_id"]?.string ?? ""
            let ver = try docVersion(c, fid)
            if ver == m["doc_version"]?.string { continue }
            let pages = try pageTexts(c, fid)
            let fps = pages.map(pageFP)
            let mp = m["page"]?.int ?? 0, mfp = m["page_fingerprint"]?.string ?? ""
            var note: String?, page = mp, review = 0
            if mp <= fps.count, mp >= 1, !mfp.isEmpty, fps[mp - 1] == mfp {
                // Seite unveraendert an gleicher Stelle
            } else {
                let hits = fps.enumerated().filter { !$0.element.isEmpty && $0.element == mfp }.map { $0.offset + 1 }
                if hits.count == 1 {
                    note = "Dokument wurde geändert: Marker von Seite \(mp) auf Seite \(hits[0]) verschoben (gleicher Seiteninhalt)."
                    page = hits[0]
                } else {
                    review = 1
                    note = "Dokument wurde geändert und die markierte Seite ist nicht mehr eindeutig auffindbar. Bitte Marker prüfen – bis dahin zählt dieser Stoff nicht für Wochentests."
                }
            }
            try c.execute("UPDATE lecture_markers SET page=?, doc_version=?, page_count=?, needs_review=?, review_note=COALESCE(?, review_note), updated_at=? WHERE id=?",
                          [.integer(Int64(page)), review == 0 ? .text(ver) : v(m["doc_version"]), .integer(Int64(pages.count)),
                           .integer(Int64(review)), note.map { .text($0) } ?? .null, .text(iso(now)), v(m["id"])])
            changes.append(["id": m["id"] ?? .null, "from": .number(Double(mp)), "to": .number(Double(page)),
                            "needs_review": .bool(review == 1), "note": note.map { .string($0) } ?? .null])
        }
        return changes
    }
}

// MARK: - Stoffumfang

extension Weekly {
    struct Segment {
        var fileID: String, version: String, from: Int, to: Int, week: Int?, markerID: Int64, topic: String?, lectureDate: String, lectureEnd: String

        /// in der Reihenfolge von Python (`coverage` -> json.dumps)
        var py: PyJSON {
            .object([.init("file_id", .string(fileID)), .init("version", .string(version)), .init("from", Weekly.i(from)),
                     .init("to", Weekly.i(to)), .init("week", week.map(Weekly.i) ?? .null), .init("marker_id", .int(String(markerID))),
                     .init("topic", topic.map { .string($0) } ?? .null), .init("lecture_date", .string(lectureDate)),
                     .init("lecture_end", .string(lectureEnd))])
        }

        init(fileID: String, version: String, from: Int, to: Int, week: Int?, markerID: Int64, topic: String?, lectureDate: String, lectureEnd: String) {
            self.fileID = fileID; self.version = version; self.from = from; self.to = to; self.week = week
            self.markerID = markerID; self.topic = topic; self.lectureDate = lectureDate; self.lectureEnd = lectureEnd
        }

        /// aus dem gespeicherten JSON eines Plans
        init(_ j: JSONValue) {
            fileID = j["file_id"]?.string ?? ""; version = j["version"]?.string ?? ""
            from = j["from"]?.int ?? 0; to = j["to"]?.int ?? 0; week = j["week"]?.int
            markerID = Int64(j["marker_id"]?.int ?? 0); topic = j["topic"]?.string
            lectureDate = j["lecture_date"]?.string ?? ""; lectureEnd = j["lecture_end"]?.string ?? ""
        }
    }

    struct PageKey: Hashable { let file: String; let page: Int }

    struct Coverage {
        var scope: String
        var segments: [Segment]
        var pages: Set<PageKey>
        var blocked: [PyJSON]
    }

    /// `coverage(conn, module_id, upto_week, user_id, scope)`
    static func coverage(_ c: SQLiteConnection, moduleID: Int, uptoWeek: Int? = nil, user: String = localUser, scope: String? = nil) throws -> Coverage {
        let mid = SQLiteValue.integer(Int64(moduleID))
        let sc = try scope ?? (c.queryOne("SELECT 1 FROM lecture_markers WHERE deleted_at IS NULL AND module_id=? AND scope='course'", [mid]) != nil
                               ? "course" : "personal")
        let rows = try c.rows("""
            SELECT * FROM lecture_markers WHERE deleted_at IS NULL AND module_id=? AND scope=? AND (scope='course' OR user_id=?)
            ORDER BY file_id, page
            """, [mid, .text(sc), .text(user)])
        var segs: [Segment] = [], blocked: [PyJSON] = []
        var order: [String] = [], byFile: [String: [[String: JSONValue]]] = [:]
        for m in rows {
            let f = m["file_id"]?.string ?? ""
            if byFile[f] == nil { order.append(f) }
            byFile[f, default: []].append(m)
        }
        for fid in order {
            var prev = 0
            for m in byFile[fid]! {
                if LocalModules.truthy(v(m["needs_review"])) {
                    blocked.append(.object([.init("marker_id", PyJSON(m["id"] ?? .null)), .init("file_id", .string(fid)),
                                            .init("page", PyJSON(m["page"] ?? .null)), .init("note", PyJSON(m["review_note"] ?? .null))]))
                    break
                }
                let week = m["week_no"]?.int
                if uptoWeek == nil || (week ?? 0) <= uptoWeek! {
                    segs.append(Segment(fileID: fid, version: m["doc_version"]?.string ?? "", from: prev + 1, to: m["page"]?.int ?? 0, week: week,
                                        markerID: Int64(m["id"]?.int ?? 0), topic: m["topic"]?.string, lectureDate: m["lecture_date"]?.string ?? "",
                                        lectureEnd: m["lecture_end"]?.string ?? ""))
                }
                prev = m["page"]?.int ?? 0
            }
        }
        segs = segs.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if (x.week ?? 0) != (y.week ?? 0) { return (x.week ?? 0) < (y.week ?? 0) }
            if x.lectureDate != y.lectureDate { return x.lectureDate < y.lectureDate }
            if x.fileID != y.fileID { return x.fileID.unicodeScalars.lexicographicallyPrecedes(y.fileID.unicodeScalars) }
            if x.from != y.from { return x.from < y.from }
            return a.offset < b.offset
        }.map(\.element)
        var pages = Set<PageKey>()
        for s in segs where s.to >= s.from { for p in s.from...s.to { pages.insert(PageKey(file: s.fileID, page: p)) } }
        return Coverage(scope: sc, segments: segs, pages: pages, blocked: blocked)
    }

    /// `scope_key(segs)`
    static func scopeKey(_ segs: [Segment]) -> String {
        h(.array(segs.map { .array([.string($0.fileID), .string($0.version), i($0.from), i($0.to), $0.week.map(i) ?? .null]) }))
    }
}

extension JSONValue {
    /// ganze Zahl einer Datenbankzeile (Kennungen)
    var weeklyInt64: Int64? { double.flatMap { $0 == $0.rounded() ? Int64($0) : nil } }
}
