import Foundation

/// Stundenplan wie app/timetable.py: Vorkommen der Serien mit Ausnahmen (`occurrences`, `_matches`), Tages- und
/// Wochenansicht (`day_timeline`, `week_grid`), Ausnahmen und Teilnahme (`set_exception`, `set_attendance`),
/// Unterlagen zum Termin (`materials_for_event`) und Konflikte mit Lernslots (`study.slot_conflicts`, gehoert zu
/// /api/timetable/conflicts). Freie Fenster: `LocalFreeWindows`, Import: `LocalTimetableImport`.
///
/// Tage sind Tagesnummern wie in `BerlinClock` (Tage seit 1970-01-01), Datumsangaben in der Datenbank ISO-Texte,
/// Uhrzeiten "HH:MM". Zeilen werden als JSON-Objekte gelesen (`db.rows`), damit die Antworten Feld fuer Feld wie in
/// Python bleiben. Ergebnisgleichheit mit Python: `LocalTimetableTests` gegen timetable-logic.json.
enum LocalTimetable {

    // MARK: Python-Werte

    // Wahrheitswert wie in Python (`x or y`, `if x`): LocalModules.truthy

    /// `a or b`
    static func or(_ a: JSONValue?, _ b: JSONValue) -> JSONValue { LocalModules.truthy(a) ? a! : b }

    /// `int(v)`: Zahl (abgeschnitten), Wahrheitswert, Text mit ganzer Zahl. Was Python scheitern laesst, wird 500.
    static func int(_ v: JSONValue?, _ field: String) throws -> Int {
        switch v {
        case .number(let n)?:
            guard n.isFinite, abs(n) < 9.0e15 else { throw LocalHTTPError(status: 500, message: "\(field) ist keine ganze Zahl") }
            return Int(n)
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?:
            guard let i = PyConvert.int(s) else { throw LocalHTTPError(status: 500, message: "\(field) ist keine ganze Zahl: \(s)") }
            return i
        default:
            throw LocalHTTPError(status: 500, message: "\(field) fehlt oder ist keine Zahl")
        }
    }

    /// Wert zum Binden wie Pythons sqlite3; Listen und Objekte lassen sich dort nicht binden (500)
    static func bind(_ v: JSONValue?, _ field: String) throws -> SQLiteValue {
        guard let v else { return .null }
        guard let s = SQLiteValue(json: v) else {
            throw LocalHTTPError(status: 500, message: "\(field): Listen und Objekte lassen sich nicht speichern")
        }
        return s
    }

    /// `str(v)` in f-Texten ("None" fuer fehlende Werte)
    static func text(_ v: JSONValue?) -> String {
        switch v {
        case nil, .null?: return "None"
        case .bool(let b)?: return b ? "True" : "False"
        case .number(let n)?: return JSONValue.format(n)
        case .string(let s)?: return s
        case let x?: return x.jsonString()
        }
    }

    /// Textvergleich `a <= b` wie Python (nach Codepunkten). Andere Typen scheitern in Python (500).
    static func lessOrEqual(_ a: JSONValue, _ b: JSONValue) throws -> Bool {
        guard let x = a.string, let y = b.string else {
            throw LocalHTTPError(status: 500, message: "Datum ist kein Text")
        }
        return !y.unicodeScalars.lexicographicallyPrecedes(x.unicodeScalars)
    }

    /// Datum aus der Query wie `date.fromisoformat` (Python antwortet bei falschem Datum mit 500, hier 422)
    static func queryDay(_ req: LocalRequest, _ name: String) throws -> Int {
        let text = try req.requiredQuery(name)
        guard let d = BerlinClock.parseISODate(text) else {
            throw LocalHTTPError(status: 422, message: "Ungültiges Datum: \(text)")
        }
        return d
    }

    /// `date.fromisoformat(v)` fuer Werte aus Anfragen und der Datenbank (500 wie in Python; die Lernpfade antworten
    /// mit 422, `status`)
    static func day(_ v: JSONValue?, _ field: String, status: Int = 500) throws -> Int {
        guard let s = v?.string, let d = BerlinClock.parseISODate(s) else {
            throw LocalHTTPError(status: status, message: "Ungültiges Datum in \(field): \(text(v))")
        }
        return d
    }

    /// Laengster Zeitraum in Tagen fuer Stundenplan, Konflikte, Lernkalender und Planung (Schutz vor endlosen
    /// Schleifen; Python kennt keine Grenze)
    static let maxDays = 3660

    /// Zeitraum pruefen: hoechstens `maxDays` Tage, sonst 422
    static func span(_ n: Int) throws -> Int {
        guard n <= maxDays else { throw LocalHTTPError(status: 422, message: "Höchstens \(maxDays) Tage") }
        return n
    }

    static func iso(_ day: Int) -> String { BerlinClock.isoDate(day) }

    static func weekday(_ day: Int) -> Int { BerlinClock.weekday(day) }

    static func today(_ clock: UniFlowClock) -> Int { BerlinClock.parseISODate(clock.today) ?? 0 }

    /// Stabil sortieren (wie `sorted`/`list.sort` in Python)
    static func stableSorted<T>(_ items: [T], by less: (T, T) throws -> Bool) rethrows -> [T] {
        try items.enumerated().sorted { a, b in
            if try less(a.element, b.element) { return true }
            if try less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Semester und Sperrzeiten

    /// `term(conn)`
    static func term(_ c: SQLiteConnection) throws -> JSONValue { try LocalTerms.current(c) }

    /// Sperrzeiten eines Wochentags: `[b for b in s["blocked_times"] if int(b.get("weekday", -1)) == d.weekday()]`
    static func blocked(_ day: Int, settings s: [String: JSONValue]) throws -> [JSONValue] {
        let wd = weekday(day)
        return try (s["blocked_times"]?.array ?? []).filter { b in
            guard let o = b.object else { throw LocalHTTPError(status: 500, message: "Sperrzeit ist kein Objekt") }
            guard let w = o["weekday"] else { return -1 == wd }
            return try int(w, "Wochentag der Sperrzeit") == wd
        }
    }

    // MARK: Vorkommen

    /// `occurrences(conn, start, end, include_skipped)`: alle Termine im Zeitraum mit angewendeten Ausnahmen
    /// (verschoben, ausgefallen, nicht besucht), dazu hierher verschobene Termine anderer Tage; nach Datum und Beginn.
    static func occurrences(_ c: SQLiteConnection, from start: Int, to end: Int, includeSkipped: Bool = true) throws -> [JSONValue] {
        let events = try c.rows("SELECT e.*, m.name AS module_name, m.color AS module_color FROM course_events e LEFT JOIN modules m ON m.id=e.module_id")
        if events.isEmpty { return [] }
        let ids = events.compactMap { $0["id"].flatMap(SQLiteValue.init(json:)) }
        // je Termin und Datum die Ausnahme; bei mehreren gilt wie im dict von Python die letzte
        var exc: [JSONValue: [String: [String: JSONValue]]] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        for x in try c.rows("SELECT * FROM event_exceptions WHERE event_id IN (\(marks))", ids) {
            guard let eid = x["event_id"], let d = x["date"]?.string else { continue }
            exc[eid, default: [:]][d] = x
        }
        let t = try term(c)
        var out: [JSONValue] = []
        var d = start
        while d <= end {
            let di = iso(d)
            for e in events {
                guard try matches(e, day: d, term: t) else { continue }
                let x = e["id"].flatMap { exc[$0]?[di] }
                var occ: [String: JSONValue] = [
                    "event_id": e["id"] ?? .null, "date": .string(di), "start": e["start_time"] ?? .null, "end": e["end_time"] ?? .null,
                    "title": e["title"] ?? .null, "kind": e["kind"] ?? .null, "module_id": e["module_id"] ?? .null,
                    "module_name": e["module_name"] ?? .null,
                    "color": or(e["color"], or(e["module_color"], "#4f5bd5")), "room": e["room"] ?? .null,
                    "lecturer": e["lecturer"] ?? .null, "course_id": e["course_id"] ?? .null,
                    "status": LocalModules.truthy(e["attend"]) ? "teilnahme" : "nicht_teilnahme", "permanent_skip": .bool(!LocalModules.truthy(e["attend"])),
                    "exception": .null,
                ]
                if let x {
                    let type = x["type"] ?? .null
                    occ["exception"] = type
                    switch type.string {
                    case "skip": occ["status"] = "nicht_teilnahme"
                    case "attend": occ["status"] = "teilnahme"
                    case "cancelled": occ["status"] = "ausfall"
                    case "moved", "edit":
                        occ["start"] = or(x["new_start"], occ["start"] ?? .null)
                        occ["end"] = or(x["new_end"], occ["end"] ?? .null)
                        if type.string == "moved", LocalModules.truthy(x["new_date"]), x["new_date"] != .string(di) {
                            occ["moved_to"] = x["new_date"]
                            occ["status"] = "verschoben"
                        }
                    default: break
                    }
                }
                if occ["status"] == "nicht_teilnahme" && !includeSkipped { continue }
                out.append(.object(occ))
            }
            // Hierher verschobene Termine anderer Tage
            for x in try c.rows("SELECT x.*, e.* , x.id AS xid FROM event_exceptions x JOIN course_events e ON e.id=x.event_id WHERE x.type='moved' AND x.new_date=? AND x.date!=?",
                                [.text(di), .text(di)]) {
                let m = LocalModules.truthy(x["module_id"]) ? try c.rows("SELECT name, color FROM modules WHERE id=?", [try bind(x["module_id"], "module_id")]).first : nil
                out.append([
                    "event_id": x["event_id"] ?? .null, "date": .string(di), "start": or(x["new_start"], x["start_time"] ?? .null),
                    "end": or(x["new_end"], x["end_time"] ?? .null), "title": x["title"] ?? .null, "kind": x["kind"] ?? .null,
                    "module_id": x["module_id"] ?? .null, "module_name": m.map { $0["name"] ?? .null } ?? .null,
                    "color": or(x["color"], or(m?["color"], "#4f5bd5")), "room": x["room"] ?? .null, "lecturer": x["lecturer"] ?? .null,
                    "course_id": x["course_id"] ?? .null, "status": "teilnahme", "permanent_skip": false, "exception": "moved_here",
                    "moved_from": x["date"] ?? .null,
                ])
            }
            d += 1
        }
        // out.sort(key=lambda o: (o["date"], o["start"])), stabil
        return try stableSorted(out) { a, b in
            let da = a["date"]?.string ?? "", db = b["date"]?.string ?? ""
            if da != db { return da.unicodeScalars.lexicographicallyPrecedes(db.unicodeScalars) }
            guard let sa = a["start"]?.string, let sb = b["start"]?.string else {
                if a["start"] == b["start"] { return false }
                throw LocalHTTPError(status: 500, message: "Termin ohne Beginn")
            }
            return sa.unicodeScalars.lexicographicallyPrecedes(sb.unicodeScalars)
        }
    }

    /// `_matches(e, d, t)`: Zeitraum (sonst Semester), einmalig, Wochentag, alle zwei Wochen ab dem ersten Tag
    static func matches(_ e: [String: JSONValue], day d: Int, term t: JSONValue) throws -> Bool {
        let df = or(e["date_from"], t["start"] ?? .null)
        let dt = or(e["date_to"], t["end"] ?? .null)
        let di: JSONValue = .string(iso(d))
        guard try lessOrEqual(df, di), try lessOrEqual(di, dt) else { return false }
        if e["rrule"] == "once" { return di == or(e["date_from"], "") }
        guard let wd = e["weekday"]?.double, wd == Double(weekday(d)) else { return false }
        if e["rrule"] == "biweekly" {
            let weeks = BerlinClock.floorDiv(d - (try day(df, "date_from")), 7)
            return ((weeks % 2) + 2) % 2 == 0
        }
        return true
    }

    // MARK: Tag und Woche

    /// `day_timeline(conn, d)`
    static func dayTimeline(_ c: SQLiteConnection, day d: Int) throws -> JSONValue {
        let s = try LocalSettings.read(c)
        let occ = try occurrences(c, from: d, to: d)
        let pk = try c.rows("SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date=? ORDER BY p.start_time, p.id",
                            [.text(iso(d))])
        return ["date": .string(iso(d)), "events": .array(occ), "packages": .array(pk.map(JSONValue.object)),
                "free": .array(try LocalFreeWindows.compute(c, day: d, settings: s)), "blocked": .array(try blocked(d, settings: s)),
                "learn_start": s["learn_start"] ?? .null, "learn_end": s["learn_end"] ?? .null]
    }

    /// `week_grid(conn, start)`
    static func weekGrid(_ c: SQLiteConnection, start: Int) throws -> JSONValue {
        let end = start + 6
        let occ = try occurrences(c, from: start, to: end)
        let pk = try c.rows("SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date BETWEEN ? AND ? ORDER BY p.date, p.start_time",
                            [.text(iso(start)), .text(iso(end))])
        let s = try LocalSettings.read(c)
        var days: [JSONValue] = []
        for d in start...end {
            let di: JSONValue = .string(iso(d))
            days.append(["date": di, "weekday": .number(Double(weekday(d))), "events": .array(occ.filter { $0["date"] == di }),
                         "packages": .array(pk.filter { $0["date"] == di }.map(JSONValue.object)),
                         "free": .array(try LocalFreeWindows.compute(c, day: d, settings: s)), "blocked": .array(try blocked(d, settings: s))])
        }
        return ["start": .string(iso(start)), "end": .string(iso(end)), "days": .array(days),
                "learn_start": s["learn_start"] ?? .null, "learn_end": s["learn_end"] ?? .null, "term": try term(c)]
    }

    // MARK: Ausnahmen und Teilnahme

    /// `set_exception(conn, event_id, d, typ, new_date, new_start, new_end, note)`
    static func setException(_ c: SQLiteConnection, eventID: SQLiteValue, date: SQLiteValue, type: SQLiteValue,
                             newDate: SQLiteValue = .null, newStart: SQLiteValue = .null, newEnd: SQLiteValue = .null,
                             note: SQLiteValue = "", clock: UniFlowClock) throws {
        try c.execute("DELETE FROM event_exceptions WHERE event_id=? AND date=?", [eventID, date])
        if type != .text("reset") {
            try c.execute("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,?,?,?,?,?,?)",
                          [eventID, date, type, newDate, newStart, newEnd, note, .text(clock.nowISO)])
        }
    }

    /// `set_attendance(conn, event_id, d, mode)`: today_skip | today_attend | permanent_skip | permanent_attend |
    /// cancelled | reset; anderes aendert nichts
    static func setAttendance(_ c: SQLiteConnection, eventID: SQLiteValue, date: SQLiteValue, mode: JSONValue?, clock: UniFlowClock) throws {
        switch mode?.string {
        case "permanent_skip", "permanent_attend":
            try c.execute("UPDATE course_events SET attend=? WHERE id=?", [mode?.string == "permanent_skip" ? 0 : 1, eventID])
            try c.execute("DELETE FROM event_exceptions WHERE event_id=? AND date>=? AND type IN ('skip','attend')", [eventID, date])
        case "today_skip": try setException(c, eventID: eventID, date: date, type: "skip", clock: clock)
        case "today_attend": try setException(c, eventID: eventID, date: date, type: "attend", clock: clock)
        case "cancelled": try setException(c, eventID: eventID, date: date, type: "cancelled", clock: clock)
        case "reset": try setException(c, eventID: eventID, date: date, type: "reset", clock: clock)
        default: break
        }
    }

    /// `materials_for_event(conn, event, d)`: passende Unterlagen des Moduls aus derselben Semesterwoche, sonst die
    /// neuesten; ohne Modul keine. Eine Fassung mit den Modulen (`LocalModules.eventMaterials`, S4): Dateien mit
    /// Einordnung aus dem Stud.IP-Abgleich (S3) und die Semesterwochen aus `StudyWeeks`.
    static func materials(_ c: SQLiteConnection, event: [String: JSONValue], day: Int, clock: UniFlowClock) throws -> [JSONValue] {
        try LocalModules.eventMaterials(c, event: event, day: day, clock: clock)
    }

    // MARK: Konflikte

    /// `study.slot_conflicts(conn, start, end)`: Lernslots, die sich mit besuchten Hochschulterminen ueberschneiden
    static func slotConflicts(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var d = start
        while d <= end {
            let occ = try occurrences(c, from: d, to: d).filter { $0["status"] == "teilnahme" }
            for p in try c.rows("SELECT id, subject, title, start_time, end_time FROM study_packages WHERE date=? AND start_time IS NOT NULL AND status IN ('geplant','in_bearbeitung')",
                                [.text(iso(d))]) {
                let ps = try LocalFreeWindows.hm(p["start_time"], key: "start_time")
                let pe = try LocalFreeWindows.hm(p["end_time"], key: "end_time")
                for o in occ {
                    let os = try LocalFreeWindows.hm(o["start"], key: "start"), oe = try LocalFreeWindows.hm(o["end"], key: "end")
                    guard ps < oe && pe > os else { continue }
                    out.append(["date": .string(iso(d)), "package_id": p["id"] ?? .null, "subject": p["subject"] ?? .null,
                                "title": p["title"] ?? .null, "slot": .string("\(text(p["start_time"]))–\(text(p["end_time"]))"),
                                "event": o["title"] ?? .null, "event_time": .string("\(text(o["start"]))–\(text(o["end"]))")])
                    break
                }
            }
            d += 1
        }
        return out
    }
}
