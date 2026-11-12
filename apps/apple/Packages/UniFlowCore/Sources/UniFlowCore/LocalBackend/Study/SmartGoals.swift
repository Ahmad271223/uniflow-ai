import Foundation

/// Smart Planner 2.0 wie app/smart_goals.py (Auftrag des Inhabers vom 12.11.2026): Lernziele in Stunden je Modul,
/// Lernzeit, gemeinsamer Lernplan ueber alle Klausuren. Rechnung in `SmartPlanner` (ohne KI). Schreibt: in einer
/// Transaktion aufrufen (`SmartGoalsEndpoints`, `StudyCalendar.calendar`).
///
/// - Lernbloecke sind Lernpakete mit source='smart'; erledigte, gesperrte, von Hand geaenderte, heutige und vergangene
///   Bloecke bleiben, der Planer aendert nur die automatisch gelegten kuenftigen (`autoSQL`).
/// - Neu geplant wird nur bei geaenderten Eingaben (Pruefsumme): bis `autoLimit` geaenderte Bloecke sofort, mehr erst
///   nach Bestaetigung; Unterdeckung nie still (dann Vorschlag mit Optionen, alter Plan bleibt).
enum SmartGoals {
    typealias T = LocalTimetable
    typealias SP = SmartPlanner

    static let settingsKey = "smart_planner"
    static let stateKey = "smart_plan_state"
    static let proposalKey = "smart_plan_proposal"
    static let defaults: [String: JSONValue] = ["sleep_minutes": 600, "bedtime": 1380, "leisure_minutes": 120, "utilization": 60,
                                                "min_block": 30, "max_block": 120, "break": 10, "max_week_minutes": 0,
                                                "max_day_minutes": 0, "commitments": []]
    static let defaultKeys = ["sleep_minutes", "bedtime", "leisure_minutes", "utilization", "min_block", "max_block", "break",
                              "max_week_minutes", "max_day_minutes", "commitments"]
    static let autoLimit = 8
    static let extraDays = 42
    static let minDays = 28, maxDays = 400
    static let materialKinds: [String: String] = ["vorlesung": "vorlesung", "skript": "vorlesung", "uebung": "uebung",
                                                  "loesung": "uebung", "klausur": "wiederholung"]
    static let blockTitle = "Selbststudium"

    /// automatisch gelegte, kuenftige, unberuehrte Bloecke: nur diese darf der Planer aendern
    static let autoSQL = """
        SELECT * FROM study_packages p WHERE source='smart' AND COALESCE(locked,0)=0 AND COALESCE(manual,0)=0
        AND date > ? AND status='geplant'
        AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id AND t.status='erledigt')
        AND NOT EXISTS (SELECT 1 FROM study_sessions s WHERE s.package_id=p.id AND s.deleted_at IS NULL)
        """

    static func bad(_ message: String) -> LocalHTTPError { LocalHTTPError(status: 400, message: message) }
    static func n(_ i: Int) -> JSONValue { .number(Double(i)) }
    static func hm(_ v: JSONValue?) -> Int? {
        guard let s = v?.string, let (h, m) = LocalFreeWindows.hourMinute(s) else { return nil }
        return h * 60 + m
    }
    static func mh(_ m: Int) -> String { LocalFreeWindows.mh(m) }

    // MARK: Einstellungen als JSON

    static func pyJSON(_ v: JSONValue) -> PyJSON {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let d): return d == d.rounded() && abs(d) < 9.0e15 ? .int(String(Int(d))) : .float(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(pyJSON))
        case .object(let o): return .object(o.keys.sorted(by: PyText.less).map { PyJSON.Member($0, pyJSON(o[$0]!)) })
        }
    }

    static func readJSON(_ c: SQLiteConnection, _ key: String) throws -> JSONValue? {
        guard let text = try c.scalar("SELECT value FROM settings WHERE key=?", [.text(key)])?.string, !text.isEmpty else { return nil }
        return try? JSONValue.parse(Data(text.utf8))
    }

    static func object(_ c: SQLiteConnection, _ key: String) throws -> [String: JSONValue] { try readJSON(c, key)?.object ?? [:] }

    static func put(_ c: SQLiteConnection, _ key: String, _ value: JSONValue?) throws {
        guard let value, value != .null, value != .object([:]) else {
            try c.execute("DELETE FROM settings WHERE key=?", [.text(key)])
            return
        }
        if try readJSON(c, key) == value { return }
        try c.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      [.text(key), .text(pyJSON(value).dumps(ensureASCII: false))])
    }

    // MARK: Uhr

    static func nowTs(_ clock: UniFlowClock) -> Int { Int(clock.now.timeIntervalSince1970.rounded(.down)) }

    /// Aenderungszeit mit Millisekunden in UTC (spaetere Aenderung gewinnt beim Zusammenfuehren)
    static func stamp(_ clock: UniFlowClock) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: clock.now)
    }

    // MARK: Einstellungen

    static func settings(_ c: SQLiteConnection) throws -> [String: JSONValue] {
        var s = defaults
        let stored = try object(c, settingsKey)
        for k in defaultKeys where stored[k] != nil { s[k] = stored[k] }
        s["learn_days"] = try LocalSettings.read(c)["learn_days"] ?? .array([])
        return s
    }

    static func number(_ b: [String: JSONValue], _ key: String, _ lo: Double, _ hi: Double, _ label: String) throws -> Int? {
        guard let v = b[key], v != .null else { return nil }
        guard let d = v.double, d.isFinite, lo <= d, d <= hi else { throw bad("\(label): Zahl von \(Int(lo)) bis \(Int(hi)).") }
        return Int(d.rounded(.toNearestOrEven))
    }

    static func clock(_ v: JSONValue?, _ label: String) throws -> Int {
        guard let s = v?.string, s.unicodeScalars.count == 5, let (h, m) = LocalFreeWindows.hourMinute(s), h <= 23, m <= 59,
              Array(s)[2] == ":" else { throw bad("\(label): Uhrzeit als HH:MM.") }
        return h * 60 + m
    }

    static func saveSettings(_ c: SQLiteConnection, _ body: [String: JSONValue]) throws -> [String: JSONValue] {
        let cur = try object(c, settingsKey)
        var s: [String: JSONValue] = [:]
        for k in defaultKeys { s[k] = cur[k] ?? defaults[k] }
        if let h = body["sleep_hours"], h != .null {
            guard let d = h.double, d.isFinite, 4 <= d, d <= 14 else { throw bad("Schlaf: 4 bis 14 Stunden.") }
            s["sleep_minutes"] = n(Int((d * 60).rounded(.toNearestOrEven)))
        }
        if let v = body["bedtime"], v != .null { s["bedtime"] = n(try clock(v, "Schlafenszeit")) }
        for (key, lo, hi, label) in [("leisure_minutes", 0.0, 600.0, "Freizeit pro Tag"), ("utilization", 10, 100, "Nutzungsquote"),
                                     ("min_block", 15, 120, "Kürzester Block"), ("max_block", 30, 240, "Längster Block"),
                                     ("break", 0, 60, "Pause"), ("max_week_minutes", 0, 7 * 1440, "Höchstens pro Woche"),
                                     ("max_day_minutes", 0, 1440, "Höchstens pro Tag")] {
            if let v = try number(body, key, lo, hi, label) { s[key] = n(v) }
        }
        if SP.num(s["max_block"]) < SP.num(s["min_block"]) { throw bad("Der längste Block muss mindestens so lang sein wie der kürzeste.") }
        if let items = body["commitments"], items != .null {
            guard let list = items.array, list.count <= 50 else { throw bad("Verpflichtungen als Liste (höchstens 50).") }
            var out: [(wd: Int, a: Int, b: Int, json: JSONValue)] = []
            for x in list {
                guard let o = x.object else { throw bad("Verpflichtung als Objekt.") }
                guard let wd = o["weekday"]?.double, wd == wd.rounded(), (0...6).contains(Int(wd)) else {
                    throw bad("Wochentag 0 (Montag) bis 6 (Sonntag).")
                }
                let a = try clock(o["start"], "Beginn"), b = try clock(o["end"], "Ende")
                if b <= a { throw bad("Das Ende muss nach dem Beginn liegen.") }
                let kind = ["arbeit", "verpflichtung"].contains(o["kind"]?.string ?? "") ? o["kind"]!.string! : "verpflichtung"
                var title = o["title"].flatMap { $0 == .null || $0 == .string("") ? nil : SP.pyStr($0) } ?? (kind == "arbeit" ? "Arbeit" : "Verpflichtung")
                title = String(title.prefix(80))
                out.append((Int(wd), a, b, ["weekday": n(Int(wd)), "start": n(a), "end": n(b), "kind": .string(kind), "title": .string(title)]))
            }
            out.sort { ($0.wd, $0.a, $0.b) < ($1.wd, $1.a, $1.b) }
            s["commitments"] = .array(out.map(\.json))
        }
        try put(c, settingsKey, .object(s))
        return try settings(c)
    }

    static func publicSettings(_ s: [String: JSONValue]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for k in defaultKeys { out[k] = s[k] }
        out["sleep_hours"] = .number(Double(SP.num(s["sleep_minutes"])) / 60)
        out["bedtime_hm"] = .string(mh(SP.num(s["bedtime"])))
        out["learn_days"] = s["learn_days"] ?? .array([])
        return .object(out)
    }

    // MARK: Ziele

    static func goals(_ c: SQLiteConnection) throws -> [[String: JSONValue]] {
        try c.rows("""
            SELECT g.*, m.name, m.color, m.exam_date AS module_exam, m.priority AS module_priority
            FROM study_goals g JOIN modules m ON m.id=g.module_id
            WHERE COALESCE(m.active,1)=1 ORDER BY m.sort, m.id
            """)
    }

    struct Exam {
        let date: String?
        let source: String?
        let confirmed: Bool
        var json: [String: JSONValue] { ["date": date.map(JSONValue.string) ?? .null, "source": source.map(JSONValue.string) ?? .null, "confirmed": .bool(confirmed)] }
    }

    /// `exam_of`: Zweittermin (wenn gewaehlt), sonst der Termin des Moduls; Quelle und Bestaetigung
    static func exam(_ g: [String: JSONValue], auto: [String: JSONValue]) -> Exam {
        if SP.num(g["exam_attempt"]) == 2, let d = g["exam_date_2"]?.string, !d.isEmpty {
            return Exam(date: d, source: "zweittermin", confirmed: true)
        }
        guard let d = g["module_exam"]?.string, !d.isEmpty else { return Exam(date: nil, source: nil, confirmed: false) }
        let source = auto[SP.pyStr(g["module_id"])]?.string == d ? "automatisch" : "selbst"
        return Exam(date: d, source: source, confirmed: source != "automatisch" || g["exam_confirmed"]?.string == d)
    }

    static func checkDate(_ v: JSONValue?, _ label: String) throws -> String? {
        guard let v, v != .null, v != .string("") else { return nil }
        guard let s = v.string, let d = BerlinClock.parseISODate(s) else { throw bad("\(label): Datum als JJJJ-MM-TT.") }
        return BerlinClock.isoDate(d)
    }

    static func saveGoal(_ c: SQLiteConnection, moduleID: Int, _ body: [String: JSONValue], clock uc: UniFlowClock) throws -> JSONValue {
        let mid = SQLiteValue.integer(Int64(moduleID))
        guard let m = try c.queryOne("SELECT * FROM modules WHERE id=?", [mid]) else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
        let ts = SQLiteValue.text(uc.nowISO)
        if try c.queryOne("SELECT 1 FROM study_goals WHERE module_id=?", [mid]) == nil {
            try c.execute("INSERT INTO study_goals(module_id, target_minutes, created_at, updated_at) VALUES (?,0,?,?)", [mid, ts, ts])
        }
        let g = try c.rows("SELECT * FROM study_goals WHERE module_id=?", [mid])[0]
        var upd: [(String, JSONValue)] = []
        for (key, col, label) in [("target_hours", "target_minutes", "Ziel"), ("learned_before_hours", "learned_before_minutes", "Schon gelernt")] {
            if let v = body[key], v != .null {
                guard let d = v.double, d.isFinite, 0 <= d, d <= 2000 else { throw bad("\(label): 0 bis 2000 Stunden.") }
                upd.append((col, n(Int((d * 60).rounded(.toNearestOrEven)))))
            }
        }
        for key in ["include_lectures", "writing"] {
            if let v = body[key], v != .null {
                guard let b = v.bool else { throw bad("\(key): ja oder nein.") }
                upd.append((key, n(b ? 1 : 0)))
            }
        }
        if let v = body["exam_attempt"], v != .null {
            guard v == .number(1) || v == .number(2) else { throw bad("Termin: 1 (Ersttermin) oder 2 (Zweittermin).") }
            upd.append(("exam_attempt", v))
        }
        if body.keys.contains("exam_date_2") {
            upd.append(("exam_date_2", try checkDate(body["exam_date_2"], "Zweittermin").map(JSONValue.string) ?? .null))
        }
        if let v = body["priority"], v != .null {
            guard [1, 2, 3].map({ JSONValue.number(Double($0)) }).contains(v) else { throw bad("Priorität 1 bis 3.") }
            upd.append(("priority", v))
        }
        var merged = g
        for (k, v) in upd { merged[k] = v }
        if SP.num(merged["exam_attempt"]) == 2 && (merged["exam_date_2"]?.string ?? "").isEmpty { throw bad("Für den Zweittermin fehlt das Datum.") }
        if body["confirm_exam"] == .bool(true) {
            merged["module_exam"] = m["exam_date"]?.json ?? .null
            let ex = exam(merged, auto: try object(c, Exams.autoKey))
            guard let d = ex.date else { throw bad("Kein Klausurtermin zum Bestätigen.") }
            upd.append(("exam_confirmed", .string(d)))
        }
        if !upd.isEmpty {
            upd.append(("updated_at", .string(uc.nowISO)))
            try c.execute("UPDATE study_goals SET \(upd.map { "\($0.0)=?" }.joined(separator: ", ")) WHERE module_id=?",
                          upd.map { SQLiteValue(json: $0.1) ?? .null } + [mid])
        }
        if upd.contains(where: { $0.0 == "writing" && $0.1 == .number(0) }) {        // "schreibe ich nicht": Bloecke fallen weg
            for p in try c.query(autoSQL + " AND module_id=?", [.text(uc.today), mid]) { try dropBlock(c, p["id"] ?? .null) }
        }
        return .object(try c.rows("SELECT * FROM study_goals WHERE module_id=?", [mid])[0])
    }

    static func deleteGoal(_ c: SQLiteConnection, moduleID: Int, clock: UniFlowClock) throws {
        let mid = SQLiteValue.integer(Int64(moduleID))
        guard try c.queryOne("SELECT 1 FROM study_goals WHERE module_id=?", [mid]) != nil else { throw LocalHTTPError.notFound("Lernziel nicht gefunden") }
        try c.execute("DELETE FROM study_goals WHERE module_id=?", [mid])
        for p in try c.query(autoSQL + " AND module_id=?", [.text(clock.today), mid]) { try dropBlock(c, p["id"] ?? .null) }
    }

    // MARK: Lernzeit

    static func segments(_ v: JSONValue?) -> JSONValue {
        guard let s = v?.string, !s.isEmpty, let j = try? JSONValue.parse(Data(s.utf8)), j.array != nil else { return .array([]) }
        return j
    }

    static func sessionRows(_ c: SQLiteConnection) throws -> [JSONValue] {
        try c.rows("SELECT * FROM study_sessions ORDER BY id").map { r in
            ["uuid": r["uuid"] ?? .null, "module_id": r["module_id"] ?? .null, "package_id": r["package_id"] ?? .null,
             "kind": r["kind"] ?? .null, "segments": segments(r["segments"]), "minutes": r["minutes"] ?? .null,
             "updated_at": r["updated_at"] ?? .null, "deleted": .bool(LocalModules.truthy(r["deleted_at"])), "day": r["day"] ?? .null]
        }
    }

    static func sessionOut(_ r: [String: JSONValue], clock: UniFlowClock) -> JSONValue {
        var o = r
        o["segments"] = segments(r["segments"])
        let kind = r["kind"]?.string == "block" ? "manual" : (r["kind"] ?? .null)
        let cr = SP.credit([["uuid": r["uuid"] ?? .null, "module_id": r["module_id"] ?? .null, "kind": kind,
                              "segments": o["segments"]!, "minutes": r["minutes"] ?? .null]], nowTs: nowTs(clock))
        o["credited_minutes"] = cr["modules"]?[SP.pyStr(r["module_id"])] ?? n(0)
        return .object(o)
    }

    static func session(_ c: SQLiteConnection, _ uid: String) throws -> [String: JSONValue] {
        guard let r = try c.rows("SELECT * FROM study_sessions WHERE uuid=? AND deleted_at IS NULL", [.text(uid)]).first else {
            throw LocalHTTPError.notFound("Lerneinheit nicht gefunden")
        }
        return r
    }

    static func uuid(_ b: [String: JSONValue]) throws -> String {
        guard let v = b["uuid"], v != .null, v != .string("") else { return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        guard let s = v.string, (8...80).contains(s.unicodeScalars.count),
              s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_.:-".unicodeScalars.contains($0) }) else {
            throw bad("uuid: 8 bis 80 Zeichen aus Buchstaben, Ziffern, - _ . :")
        }
        return s
    }

    static func intValue(_ v: JSONValue?) -> Int? {
        guard let d = v?.double, d.isFinite, d == d.rounded(), abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }

    static func moduleAndPackage(_ c: SQLiteConnection, _ b: [String: JSONValue]) throws -> (Int, Int?) {
        var mid = b["module_id"].flatMap { $0 == .null ? nil : $0 }
        var pid: Int?
        if let p = b["package_id"], p != .null {
            guard let i = intValue(p) else { throw bad("package_id ist keine Zahl.") }
            guard let row = try c.queryOne("SELECT id, module_id FROM study_packages WHERE id=?", [.integer(Int64(i))]) else {
                throw LocalHTTPError.notFound("Lernblock nicht gefunden")
            }
            pid = i
            if mid == nil { mid = row["module_id"]?.json }
        }
        guard let m = intValue(mid) else { throw bad("module_id fehlt.") }
        guard try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(Int64(m))]) != nil else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
        return (m, pid)
    }

    static func addSession(_ c: SQLiteConnection, _ b: [String: JSONValue], clock uc: UniFlowClock) throws -> JSONValue {
        let uid = try uuid(b)
        if let old = try c.rows("SELECT * FROM study_sessions WHERE uuid=?", [.text(uid)]).first { return sessionOut(old, clock: uc) }
        let (mid, pid) = try moduleAndPackage(c, b)
        let ts = nowTs(uc)
        var seg: SQLiteValue = .null, minutes: SQLiteValue = .null
        let day: String
        if (b["start"] ?? .null) != .null || (b["end"] ?? .null) != .null {
            guard let a = intValue(b["start"]), let e = intValue(b["end"]) else { throw bad("Beginn und Ende als Unix-Sekunden.") }
            if e <= a || e - a > 16 * 3600 { throw bad("Das Ende muss nach dem Beginn liegen (höchstens 16 Stunden).") }
            if e > ts + 300 { throw bad("Lernzeit in der Zukunft kann nicht eingetragen werden.") }
            seg = .text("[[\(a), \(e)]]")
            day = BerlinClock.isoDate(BerlinClock.local(utc: a).day)
        } else {
            guard let m = try number(b, "minutes", 1, 16 * 60, "Minuten") else { throw bad("Minuten oder Beginn und Ende angeben.") }
            minutes = .integer(Int64(m))
            day = try checkDate(b["day"], "Tag") ?? uc.today
            if PyText.less(uc.today, day) { throw bad("Lernzeit in der Zukunft kann nicht eingetragen werden.") }
        }
        let st = SQLiteValue.text(stamp(uc))
        let note = String((b["note"].flatMap { $0 == .null ? nil : SP.pyStr($0) } ?? "").prefix(500))
        let device = String((b["device"].flatMap { $0 == .null ? nil : SP.pyStr($0) } ?? "").prefix(80))
        try c.execute("""
            INSERT INTO study_sessions(uuid, module_id, package_id, kind, state, segments, minutes, day, note, device, created_at, updated_at)
            VALUES (?,?,?,'manual','fertig',?,?,?,?,?,?,?)
            """, [.text(uid), .integer(Int64(mid)), pid.map { .integer(Int64($0)) } ?? .null, seg, minutes, .text(day), .text(note),
                  device.isEmpty ? .null : .text(device), st, st])
        return sessionOut(try session(c, uid), clock: uc)
    }

    static func segmentList(_ r: [String: JSONValue]) -> [[JSONValue]] { (segments(r["segments"]).array ?? []).compactMap(\.array) }

    static func segText(_ s: [[JSONValue]]) -> SQLiteValue {
        .text("[" + s.map { "[" + $0.map { $0 == .null ? "null" : String(SP.num($0)) }.joined(separator: ", ") + "]" }.joined(separator: ", ") + "]")
    }

    static func startSession(_ c: SQLiteConnection, _ b: [String: JSONValue], clock uc: UniFlowClock) throws -> JSONValue {
        let uid = try uuid(b)
        if let old = try c.rows("SELECT * FROM study_sessions WHERE uuid=?", [.text(uid)]).first { return sessionOut(old, clock: uc) }
        let (mid, pid) = try moduleAndPackage(c, b)
        for r in try c.query("SELECT uuid FROM study_sessions WHERE state='laeuft' AND deleted_at IS NULL") {
            _ = try pauseSession(c, r["uuid"]?.string ?? "", clock: uc)
        }
        let st = SQLiteValue.text(stamp(uc))
        let device = String((b["device"].flatMap { $0 == .null ? nil : SP.pyStr($0) } ?? "").prefix(80))
        try c.execute("""
            INSERT INTO study_sessions(uuid, module_id, package_id, kind, state, segments, minutes, day, device, created_at, updated_at)
            VALUES (?,?,?,'timer','laeuft',?,NULL,?,?,?,?)
            """, [.text(uid), .integer(Int64(mid)), pid.map { .integer(Int64($0)) } ?? .null, segText([[n(nowTs(uc)), .null]]), .text(uc.today),
                  device.isEmpty ? .null : .text(device), st, st])
        return sessionOut(try session(c, uid), clock: uc)
    }

    static func closeOpen(_ r: [String: JSONValue], clock uc: UniFlowClock) -> [[JSONValue]] {
        var s = segmentList(r)
        if let last = s.last, last.count >= 2, last[1] == .null { s[s.count - 1][1] = n(max(SP.num(last[0]), nowTs(uc))) }
        return s
    }

    static func pauseSession(_ c: SQLiteConnection, _ uid: String, clock uc: UniFlowClock) throws -> JSONValue {
        let r = try session(c, uid)
        if r["state"]?.string == "laeuft" {
            try c.execute("UPDATE study_sessions SET state='pause', segments=?, updated_at=? WHERE uuid=?", [segText(closeOpen(r, clock: uc)), .text(stamp(uc)), .text(uid)])
        }
        return sessionOut(try session(c, uid), clock: uc)
    }

    static func resumeSession(_ c: SQLiteConnection, _ uid: String, clock uc: UniFlowClock) throws -> JSONValue {
        let r = try session(c, uid)
        if r["state"]?.string == "pause" {
            for o in try c.query("SELECT uuid FROM study_sessions WHERE state='laeuft' AND deleted_at IS NULL AND uuid<>?", [.text(uid)]) {
                _ = try pauseSession(c, o["uuid"]?.string ?? "", clock: uc)
            }
            try c.execute("UPDATE study_sessions SET state='laeuft', segments=?, updated_at=? WHERE uuid=?",
                          [segText(segmentList(r) + [[n(nowTs(uc)), .null]]), .text(stamp(uc)), .text(uid)])
        } else if r["state"]?.string == "fertig" {
            throw LocalHTTPError(status: 409, message: "Die Lerneinheit ist schon beendet.")
        }
        return sessionOut(try session(c, uid), clock: uc)
    }

    static func stopSession(_ c: SQLiteConnection, _ uid: String, clock uc: UniFlowClock) throws -> JSONValue {
        let r = try session(c, uid)
        if r["state"]?.string != "fertig" {
            try c.execute("UPDATE study_sessions SET state='fertig', segments=?, updated_at=? WHERE uuid=?", [segText(closeOpen(r, clock: uc)), .text(stamp(uc)), .text(uid)])
        }
        return sessionOut(try session(c, uid), clock: uc)
    }

    static func correctSession(_ c: SQLiteConnection, _ uid: String, _ b: [String: JSONValue], clock uc: UniFlowClock) throws -> JSONValue {
        let r = try session(c, uid)
        var upd: [(String, SQLiteValue)] = []
        if let m = try number(b, "minutes", 0, 16 * 60, "Minuten") {
            if r["state"]?.string != "fertig" { throw LocalHTTPError(status: 409, message: "Erst die Stoppuhr beenden, dann korrigieren.") }
            upd += [("minutes", .integer(Int64(m))), ("segments", .null), ("kind", .text(r["kind"]?.string == "timer" ? "manual" : (r["kind"]?.string ?? "manual")))]
        }
        if b.keys.contains("note") { upd.append(("note", .text(String((b["note"].flatMap { $0 == .null ? nil : SP.pyStr($0) } ?? "").prefix(500))))) }
        if b.keys.contains("module_id") {
            let (mid, _) = try moduleAndPackage(c, ["module_id": b["module_id"] ?? .null])
            upd.append(("module_id", .integer(Int64(mid))))
        }
        if !upd.isEmpty {
            upd.append(("updated_at", .text(stamp(uc))))
            try c.execute("UPDATE study_sessions SET \(upd.map { "\($0.0)=?" }.joined(separator: ", ")) WHERE uuid=?", upd.map(\.1) + [.text(uid)])
        }
        return sessionOut(try session(c, uid), clock: uc)
    }

    static func deleteSession(_ c: SQLiteConnection, _ uid: String, clock uc: UniFlowClock) throws {
        _ = try session(c, uid)
        try c.execute("UPDATE study_sessions SET deleted_at=?, state='fertig', updated_at=? WHERE uuid=?", [.text(uc.nowISO), .text(stamp(uc)), .text(uid)])
    }

    static func listSessions(_ c: SQLiteConnection, moduleID: Int?, start: String?, end: String?, clock uc: UniFlowClock) throws -> JSONValue {
        var sql = "SELECT * FROM study_sessions WHERE deleted_at IS NULL"
        var params: [SQLiteValue] = []
        if let moduleID { sql += " AND module_id=?"; params.append(.integer(Int64(moduleID))) }
        if let start { sql += " AND day>=?"; params.append(.text(start)) }
        if let end { sql += " AND day<=?"; params.append(.text(end)) }
        return ["items": .array(try c.rows(sql + " ORDER BY day DESC, id DESC LIMIT 500", params).map { sessionOut($0, clock: uc) })]
    }

    // MARK: Bloecke

    static func dropBlock(_ c: SQLiteConnection, _ id: SQLiteValue) throws {
        try c.execute("DELETE FROM study_tasks WHERE package_id=? AND status<>'erledigt'", [id])
        if try c.queryOne("SELECT 1 FROM study_tasks WHERE package_id=?", [id]) == nil {
            try c.execute("UPDATE study_sessions SET package_id=NULL WHERE package_id=?", [id])
            try c.execute("DELETE FROM study_packages WHERE id=?", [id])
        }
    }

    /// `dedupe_blocks`: gleiche Bloecke doppelt (zwei Geraete offline): einer bleibt, Aufgaben und Lernzeit wandern mit
    @discardableResult
    static func dedupeBlocks(_ c: SQLiteConnection) throws -> Int {
        var n = 0
        for g in try c.query("""
            SELECT module_id, date, start_time, end_time, MIN(id) AS keep FROM study_packages
            WHERE source='smart' AND status<>'erledigt' AND start_time IS NOT NULL
            GROUP BY module_id, date, start_time, end_time HAVING COUNT(*) > 1
            """) {
            let keep = g["keep"] ?? .null
            for d in try c.query("""
                SELECT id FROM study_packages WHERE source='smart' AND status<>'erledigt' AND module_id IS ?
                AND date=? AND start_time=? AND end_time=? AND id<>?
                """, [g["module_id"] ?? .null, g["date"] ?? .null, g["start_time"] ?? .null, g["end_time"] ?? .null, keep]) {
                let id = d["id"] ?? .null
                try c.execute("UPDATE study_tasks SET package_id=? WHERE package_id=?", [keep, id])
                try c.execute("UPDATE study_sessions SET package_id=? WHERE package_id=?", [keep, id])
                try c.execute("UPDATE study_packages SET locked=MAX(COALESCE(locked,0), (SELECT COALESCE(locked,0) FROM study_packages WHERE id=?)) WHERE id=?", [id, keep])
                try c.execute("DELETE FROM study_packages WHERE id=?", [id])
                n += 1
            }
        }
        return n
    }

    /// `mark_missed`: vergangene Bloecke mit Lernzeit "teilweise", ohne "verpasst"; offene Aufgaben werden frei
    static func markMissed(_ c: SQLiteConnection, today t: Int, blockCredit: [String: JSONValue]) throws {
        for p in try c.query("SELECT id FROM study_packages WHERE source='smart' AND date < ? AND status IN ('geplant','in_bearbeitung','nachholen')",
                             [.text(T.iso(t))]) {
            let id = p["id"] ?? .null
            let st = SP.num(blockCredit[SP.pyStr(id.json)]) > 0 ? "teilweise" : "verpasst"
            try c.execute("UPDATE study_packages SET status=? WHERE id=?", [.text(st), id])
            try c.execute("UPDATE study_tasks SET status='verschoben' WHERE package_id=? AND status IN ('geplant','in_bearbeitung','nachholen')", [id])
        }
    }

    static func blockDone(_ c: SQLiteConnection, packageID pid: Int, _ b: [String: JSONValue], clock uc: UniFlowClock) throws -> JSONValue {
        let id = SQLiteValue.integer(Int64(pid))
        guard let p = try c.queryOne("SELECT * FROM study_packages WHERE id=?", [id]) else { throw LocalHTTPError.notFound("Lernblock nicht gefunden") }
        guard b.keys.contains("minutes"), let m = try number(b, "minutes", 0, 16 * 60, "Minuten") else {
            throw bad("Wie lange hast du gelernt? Minuten angeben.")
        }
        if PyText.less(uc.today, p["date"]?.string ?? "") { throw bad("Ein Block in der Zukunft kann noch nicht abgehakt werden.") }
        guard let module = p["module_id"], module != .null else { throw bad("Der Block gehört zu keinem Modul.") }
        let st = SQLiteValue.text(stamp(uc))
        try c.execute("UPDATE study_sessions SET deleted_at=?, updated_at=? WHERE package_id=? AND kind='block' AND deleted_at IS NULL", [.text(uc.nowISO), st, id])
        for r in try c.query("SELECT uuid FROM study_sessions WHERE package_id=? AND state<>'fertig' AND deleted_at IS NULL", [id]) {
            _ = try stopSession(c, r["uuid"]?.string ?? "", clock: uc)
        }
        try c.execute("""
            INSERT INTO study_sessions(uuid, module_id, package_id, kind, state, minutes, day, created_at, updated_at)
            VALUES (?,?,?,'block','fertig',?,?,?,?)
            """, [.text(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()), module, id, .integer(Int64(m)), p["date"] ?? .null, st, st])
        let status = m > 0 ? "erledigt" : "verpasst"
        try c.execute("UPDATE study_packages SET status=? WHERE id=?", [.text(status), id])
        return ["package_id": n(pid), "minutes": n(m), "status": .string(status)]
    }

    static func blockUndone(_ c: SQLiteConnection, packageID pid: Int, clock uc: UniFlowClock) throws -> JSONValue {
        let id = SQLiteValue.integer(Int64(pid))
        guard try c.queryOne("SELECT 1 FROM study_packages WHERE id=?", [id]) != nil else { throw LocalHTTPError.notFound("Lernblock nicht gefunden") }
        try c.execute("UPDATE study_sessions SET deleted_at=?, updated_at=? WHERE package_id=? AND kind='block' AND deleted_at IS NULL",
                      [.text(uc.nowISO), .text(stamp(uc)), id])
        try c.execute("UPDATE study_packages SET status='geplant' WHERE id=?", [id])
        return ["package_id": n(pid), "status": "geplant"]
    }

    static func setLocked(_ c: SQLiteConnection, packageID pid: Int, _ b: [String: JSONValue]) throws -> JSONValue {
        let id = SQLiteValue.integer(Int64(pid))
        guard try c.queryOne("SELECT 1 FROM study_packages WHERE id=?", [id]) != nil else { throw LocalHTTPError.notFound("Lernblock nicht gefunden") }
        guard let locked = b["locked"]?.bool else { throw bad("locked: ja oder nein.") }
        try c.execute("UPDATE study_packages SET locked=? WHERE id=?", [.integer(locked ? 1 : 0), id])
        return .object(try c.rows("SELECT * FROM study_packages WHERE id=?", [id])[0])
    }

    static func checkSlot(_ c: SQLiteConnection, packageID pid: Int, _ b: [String: JSONValue]) throws -> JSONValue {
        let id = SQLiteValue.integer(Int64(pid))
        guard let p = try c.rows("SELECT * FROM study_packages WHERE id=?", [id]).first else { throw LocalHTTPError.notFound("Lernblock nicht gefunden") }
        let d = try checkDate(b["date"], "Tag") ?? (p["date"]?.string ?? "")
        let ps = hm(p["start_time"]), pe = hm(p["end_time"])
        let a: Int
        if let v = b["start"], v != .null { a = try clock(v, "Beginn") } else if let ps { a = ps } else { throw bad("Beginn fehlt.") }
        let dur = (ps != nil && pe != nil) ? pe! - ps! : (SP.num(p["planned_minutes"]) == 0 ? 60 : SP.num(p["planned_minutes"]))
        let e: Int
        if let v = b["end"], v != .null { e = try clock(v, "Ende") } else { e = a + dur }
        if e <= a { throw bad("Das Ende muss nach dem Beginn liegen.") }
        guard let day = BerlinClock.parseISODate(d) else { throw bad("Tag: Datum als JJJJ-MM-TT.") }
        return ["date": .string(d), "start": n(a), "end": n(e), "conflicts": .array(try slotConflicts(c, p, day: day, a, e).map(JSONValue.object))]
    }

    static func slotConflicts(_ c: SQLiteConnection, _ p: [String: JSONValue], day d: Int, _ a: Int, _ b: Int, occ: [JSONValue]? = nil) throws -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        let di = T.iso(d)
        for o in try occ ?? T.occurrences(c, from: d, to: d) {
            guard o["date"]?.string == di, o["status"]?.string == "teilnahme", let s = hm(o["start"]), let e = hm(o["end"]), a < e, b > s else { continue }
            out.append(["kind": "termin", "text": .string("Überschneidet „\(T.text(o["title"]))“ (\(T.text(o["start"]))–\(T.text(o["end"])))")])
        }
        for x in (try LocalSettings.read(c)["blocked_times"]?.array ?? []) {
            guard SP.num(x["weekday"]) == BerlinClock.weekday(d), x["weekday"] != nil, let s = hm(x["start"]), let e = hm(x["end"]), a < e, b > s else { continue }
            let title = x["title"].flatMap { $0 == .null || $0 == .string("") ? nil : SP.pyStr($0) } ?? "Sperrzeit"
            out.append(["kind": "sperrzeit", "text": .string("Überschneidet die Sperrzeit „\(title)“")])
        }
        for q in try c.rows("""
            SELECT id, subject, start_time, end_time FROM study_packages WHERE date=? AND id<>? AND start_time IS NOT NULL
            AND status NOT IN ('verschoben','uebersprungen')
            """, [.text(di), SQLiteValue(json: p["id"] ?? .null) ?? .null]) {
            guard let s = hm(q["start_time"]), let e = hm(q["end_time"]), a < e, b > s else { continue }
            let text = "Überschneidet den Lernblock \(q["subject"]?.string ?? "") (\(T.text(q["start_time"]))–\(T.text(q["end_time"])))"
            out.append(["kind": "block", "text": .string(text.replacingOccurrences(of: "  ", with: " "))])
        }
        if let mid = p["module_id"], mid != .null,
           let g = try c.rows("SELECT g.*, m.exam_date AS module_exam FROM study_goals g JOIN modules m ON m.id=g.module_id WHERE g.module_id=?",
                              [SQLiteValue(json: mid) ?? .null]).first {
            let ex = exam(g, auto: try object(c, Exams.autoKey))
            if let e = ex.date, !PyText.less(di, e) {
                out.append(["kind": "klausur", "text": .string("Liegt am oder nach der Klausur (\(e))")])
            }
        }
        return out
    }

    // MARK: Eingabe des Planers

    struct Build {
        var input: JSONValue
        let hash: String
        let info: [String: (goal: [String: JSONValue], exam: Exam, learned: Int, lecture: Int)]
        let sessions: [JSONValue]
        let occ: [JSONValue]
        let settings: [String: JSONValue]
        let goals: [[String: JSONValue]]
    }

    static func days(_ c: SQLiteConnection, from t: Int, to last: Int, settings s: [String: JSONValue], occ: [JSONValue]) throws -> [JSONValue] {
        let st = try LocalSettings.read(c)
        let travel = st["travel_minutes"]?.int ?? 30
        let blocked = st["blocked_times"]?.array ?? []
        var per: [String: [(Int, Int)]] = [:]
        for o in occ where o["status"]?.string == "teilnahme" {
            if let a = hm(o["start"]), let b = hm(o["end"]), let d = o["date"]?.string { per[d, default: []].append((a, b)) }
        }
        var dates: [JSONValue] = []
        var d = t
        while d <= last {
            let ev = (per[T.iso(d)] ?? []).sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var busy: [JSONValue] = ev.map { [n($0.0), n($0.1)] }
            if let first = ev.first {
                let end = ev.map(\.1).max()!
                busy.append([n(first.0 - travel), n(first.0)])
                busy.append([n(end), n(end + travel)])
            }
            for x in blocked where x["weekday"] != nil && SP.num(x["weekday"]) == BerlinClock.weekday(d) {
                if let a = hm(x["start"]), let b = hm(x["end"]) { busy.append([n(a), n(b)]) }
            }
            dates.append(["date": .string(T.iso(d)), "weekday": n(BerlinClock.weekday(d)), "busy": .array(busy)])
            d += 1
        }
        return SP.buildDays(dates, settings: s)
    }

    static func lectureMinutes(_ occ: [JSONValue], module: JSONValue, from start: String, until end: String?) -> Int {
        var total = 0
        for o in occ where o["module_id"] == module && o["status"]?.string == "teilnahme" {
            guard let d = o["date"]?.string, !PyText.less(d, start), end.map({ PyText.less(d, $0) }) ?? true,
                  let a = hm(o["start"]), let b = hm(o["end"]) else { continue }
            total += max(0, b - a)
        }
        return total
    }

    static func sha(_ text: String) -> String {
        // SHA-256 wie hashlib.sha256 (auch unter Linux)
        String(SolutionSHA256.hex(Data(text.utf8)).prefix(24))
    }

    static func build(_ c: SQLiteConnection, today t: Int, partial: Bool, clock uc: UniFlowClock) throws -> Build {
        let s = try settings(c)
        let auto = try object(c, Exams.autoKey)
        let gs = try goals(c)
        let sessions = try sessionRows(c)
        let cr = SP.credit(sessions, nowTs: nowTs(uc))
        let ti = T.iso(t)
        var exams: [String: Exam] = [:]
        for g in gs { exams[SP.pyStr(g["module_id"])] = exam(g, auto: auto) }
        var last = t
        for g in gs where SP.num(g["writing"]) != 0 {
            if let d = exams[SP.pyStr(g["module_id"])]?.date, PyText.less(ti, d), let x = BerlinClock.parseISODate(d) { last = max(last, x) }
        }
        last = min(max(last + extraDays, t + minDays - 1), t + maxDays - 1)
        var since = t
        for g in gs where SP.num(g["include_lectures"]) != 0 {
            since = min(since, BerlinClock.parseISODate(String((g["created_at"]?.string ?? ti).prefix(10))) ?? t)
        }
        let occ = try T.occurrences(c, from: min(since, t), to: last)
        let dayList = try days(c, from: t, to: last, settings: s, occ: occ.filter { !PyText.less($0["date"]?.string ?? "", ti) })
        let autoIDs = Set(try c.query(autoSQL, [.text(ti)]).compactMap { $0["id"]?.json })
        let goalMods = Set(gs.map { $0["module_id"] ?? .null })
        var fixed: [JSONValue] = []
        for p in try c.rows("""
            SELECT id, module_id, date, start_time, end_time, status, source FROM study_packages
            WHERE date >= ? AND start_time IS NOT NULL AND end_time IS NOT NULL
            AND status NOT IN ('verschoben','uebersprungen') ORDER BY date, start_time, id
            """, [.text(ti)]) {
            if autoIDs.contains(p["id"] ?? .null) { continue }
            guard let a = hm(p["start_time"]), let b = hm(p["end_time"]), b > a else { continue }
            let counts = goalMods.contains(p["module_id"] ?? .null) && !["erledigt", "verpasst", "teilweise"].contains(p["status"]?.string ?? "")
            fixed.append(["module_id": p["module_id"] ?? .null, "date": p["date"] ?? .null, "start": n(a), "end": n(b), "counts": .bool(counts)])
        }
        var modules: [JSONValue] = []
        var info: [String: (goal: [String: JSONValue], exam: Exam, learned: Int, lecture: Int)] = [:]
        for g in gs {
            let key = SP.pyStr(g["module_id"])
            let ex = exams[key]!
            let learned = SP.num(g["learned_before_minutes"]) + SP.num(cr["modules"]?[key])
            let created = String((g["created_at"]?.string ?? ti).prefix(10))
            let lecture = SP.num(g["include_lectures"]) != 0 ? lectureMinutes(occ, module: g["module_id"] ?? .null, from: created, until: ex.date) : 0
            let st = SP.moduleStats(["target_minutes": g["target_minutes"] ?? .null, "learned_minutes": n(learned), "lecture_minutes": n(lecture)])
            info[key] = (g, ex, learned, lecture)
            if SP.num(g["writing"]) != 0 {
                var pr = SP.num(g["priority"])
                if pr == 0 { pr = SP.num(g["module_priority"]) }
                if pr == 0 { pr = 2 }
                modules.append(["id": g["module_id"] ?? .null, "exam_date": ex.date.map(JSONValue.string) ?? .null,
                                "remaining_minutes": st["remaining_minutes"] ?? n(0), "priority": n(pr),
                                "exam_date_2": SP.num(g["exam_attempt"]) == 2 ? .null : (g["exam_date_2"] ?? .null)])
            }
        }
        var setsOut: [String: JSONValue] = [:]
        for k in ["utilization", "min_block", "max_block", "break", "max_week_minutes", "max_day_minutes"] { setsOut[k] = s[k] }
        var inp: [String: JSONValue] = ["days": .array(dayList), "modules": .array(modules), "fixed": .array(fixed),
                                        "settings": .object(setsOut), "accept_partial": .bool(partial)]
        // bisheriger Plan: Lagen behalten, wo es geht; Teil der Pruefsumme (ein geloeschter Block wird neu verteilt)
        inp["prefer"] = .array(try c.rows(autoSQL + " ORDER BY date, start_time, id", [.text(ti)]).compactMap { p in
            guard let a = hm(p["start_time"]), let b = hm(p["end_time"]) else { return nil }
            return ["module_id": p["module_id"] ?? .null, "date": p["date"] ?? .null, "start": n(a), "end": n(b)]
        })
        let hash = sha(pyJSON(.object(inp)).dumps(ensureASCII: true))
        inp["now_minute"] = n(uc.minutesOfDay)
        return Build(input: .object(inp), hash: hash, info: info, sessions: sessions, occ: occ, settings: s, goals: gs)
    }

    // MARK: Planen und anwenden

    static func existingAuto(_ c: SQLiteConnection, today ti: String) throws -> [JSONValue] {
        try c.rows(autoSQL, [.text(ti)]).compactMap { p in
            guard let a = hm(p["start_time"]), let b = hm(p["end_time"]) else { return nil }
            return ["id": p["id"] ?? .null, "module_id": p["module_id"] ?? .null, "date": p["date"] ?? .null, "start": n(a), "end": n(b)]
        }
    }

    static func apply(_ c: SQLiteConnection, _ result: JSONValue, today t: Int, clock uc: UniFlowClock) throws -> (added: Int, removed: Int, kept: Int) {
        let ti = T.iso(t)
        var new: [JSONValue] = []
        for b in result["blocks"]?.array ?? [] {
            if PyText.less(ti, b["date"]?.string ?? "") { new.append(b); continue }
            let exists = try c.queryOne("SELECT 1 FROM study_packages WHERE source='smart' AND module_id=? AND date=? AND start_time=? AND end_time=?",
                                        [SQLiteValue(json: b["module_id"] ?? .null) ?? .null, .text(b["date"]?.string ?? ""),
                                         .text(mh(SP.num(b["start"]))), .text(mh(SP.num(b["end"])))]) != nil
            if !exists { new.append(b) }
        }
        let d = SP.diff(try existingAuto(c, today: ti), new)
        for id in d["remove"]?.array ?? [] { try dropBlock(c, SQLiteValue(json: id) ?? .null) }
        var names: [JSONValue: JSONValue] = [:]
        for r in try c.rows("SELECT id, name FROM modules") { names[r["id"] ?? .null] = r["name"] ?? .null }
        let ts = SQLiteValue.text(uc.nowISO)
        for b in d["add"]?.array ?? [] {
            try c.execute("""
                INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at,
                                           start_time, end_time, source, locked, manual)
                VALUES (?,?,?,?,NULL,?,'geplant',0,1,?,?,?,'smart',0,0)
                """, [.text(b["date"]?.string ?? ""), SQLiteValue(json: b["module_id"] ?? .null) ?? .null,
                      SQLiteValue(json: names[b["module_id"] ?? .null] ?? .null) ?? .null, .text(blockTitle), .integer(Int64(SP.num(b["minutes"]))),
                      ts, .text(mh(SP.num(b["start"]))), .text(mh(SP.num(b["end"])))])
        }
        return (d["add"]?.array?.count ?? 0, d["remove"]?.array?.count ?? 0, d["keep"]?.array?.count ?? 0)
    }

    static func fillMaterials(_ c: SQLiteConnection, today t: Int, clock uc: UniFlowClock) throws -> JSONValue {
        let gs = try goals(c).filter { SP.num($0["writing"]) != 0 }
        if gs.isEmpty { return ["assign": [], "overflow": []] }
        var blocks: [JSONValue] = []
        for p in try c.rows("""
            SELECT p.id, p.module_id, p.date, p.start_time, p.end_time, p.planned_minutes,
                   (SELECT COALESCE(SUM(est_minutes),0) FROM study_tasks t WHERE t.package_id=p.id
                    AND t.status NOT IN ('verschoben','uebersprungen')) AS used
            FROM study_packages p WHERE p.source='smart' AND p.date >= ? AND p.status='geplant'
            AND p.start_time IS NOT NULL AND p.end_time IS NOT NULL
            """, [.text(T.iso(t))]) {
            guard let a = hm(p["start_time"]), let b = hm(p["end_time"]) else { continue }
            blocks.append(["id": p["id"] ?? .null, "module_id": p["module_id"] ?? .null, "date": p["date"] ?? .null, "start": n(a),
                           "minutes": n(b - a), "used": n(SP.num(p["used"]))])
        }
        let planned = try StudyPlan.plannedFiles(c)
        let trashed = Set(try c.query("SELECT id FROM files WHERE deleted_at IS NOT NULL").compactMap { $0[0].string })
        let dates = try LocalModules.Dates(c, clock: uc)
        var mats: [JSONValue] = []
        var titles: [String: (String, String)] = [:]
        for g in gs {
            for f in try LocalModules.fileRows(c, moduleID: SQLiteValue(json: g["module_id"] ?? .null)) {
                guard let id = f.id.string, let kind = f.docType, materialKinds[kind] != nil, !planned.contains(id), !trashed.contains(id),
                      f.json["status"]?.string != "erledigt" else { continue }
                let w = try LocalModules.week(f, dates: dates)
                if kind != "klausur" && w < 1 { continue }
                let from: JSONValue = kind == "klausur" ? .null : .string(T.iso(dates.start + 7 * (w - 1)))
                mats.append(["file_id": .string(id), "module_id": g["module_id"] ?? .null, "kind": .string(kind), "from_date": from,
                             "est": n(try StudyPlan.est(f))])
                let title = T.or(f.json["ai_title"], f.json["name"] ?? .null).string ?? "Unterlage"
                titles[id] = (title.isEmpty ? "Unterlage" : title, kind)
            }
        }
        var r = SP.assignMaterials(blocks, mats, maxBlock: SP.num(try settings(c)["max_block"]))
        let ts = SQLiteValue.text(uc.nowISO)
        for a in r["assign"]?.array ?? [] {
            guard let fid = a["file_id"]?.string, let (title0, kind) = titles[fid] else { continue }
            var title = title0
            if SP.num(a["parts"]) > 1 { title += " (Teil \(SP.num(a["part"]))/\(SP.num(a["parts"])))" }
            let bid = SQLiteValue(json: a["block_id"] ?? .null) ?? .null
            let cnt = try c.scalar("SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", [bid]) ?? .integer(0)
            try c.execute("""
                INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at)
                VALUES (?,?,?,?,?,?,'geplant',?)
                """, [bid, .text(materialKinds[kind] ?? "frei"), .text(fid), .text(title), cnt, .integer(Int64(SP.num(a["minutes"]))), ts])
        }
        if case .array(let over) = r["overflow"] ?? .null {
            r["overflow"] = .array(over.map { o in
                var x = o
                x["title"] = .string(titles[o["file_id"]?.string ?? ""]?.0 ?? "Unterlage")
                return x
            })
        }
        return r
    }

    struct Ensured {
        let build: Build
        let result: JSONValue?
        let state: [String: JSONValue]
        let proposal: JSONValue?
        let fill: JSONValue
    }

    /// `ensure`: Doppel zusammenfuehren, Verpasstes markieren, bei geaenderten Eingaben neu planen (klein sofort,
    /// gross oder Unterdeckung als Vorschlag). `auto: false` (Tarif ohne automatischen Lernplan): nur rechnen.
    static func ensure(_ c: SQLiteConnection, today t: Int, auto: Bool, clock uc: UniFlowClock) throws -> Ensured {
        try dedupeBlocks(c)
        try markMissed(c, today: t, blockCredit: SP.credit(try sessionRows(c), nowTs: nowTs(uc))["blocks"]?.object ?? [:])
        var state = try object(c, stateKey)
        let b = try build(c, today: t, partial: state["partial"]?.bool ?? false, clock: uc)
        if (b.input["modules"]?.array ?? []).isEmpty {
            return Ensured(build: b, result: nil, state: state, proposal: nil, fill: ["assign": [], "overflow": []])
        }
        let result = try SP.plan(b.input)
        var proposal: JSONValue? = try readJSON(c, proposalKey)
        if let h = state["hash"]?.string, h != b.hash, auto {
            if result["status"]?.string == "unterdeckt" {
                proposal = ["kind": "unterdeckt", "hash": .string(b.hash), "message": result["message"] ?? .null]
            } else {
                let ti = T.iso(t)
                let d = SP.diff(try existingAuto(c, today: ti), (result["blocks"]?.array ?? []).filter { PyText.less(ti, $0["date"]?.string ?? "") })
                let added = d["add"]?.array?.count ?? 0, removed = d["remove"]?.array?.count ?? 0
                if added + removed <= autoLimit {
                    let ch = try apply(c, result, today: t, clock: uc)
                    state["hash"] = .string(b.hash)
                    state["at"] = .string(uc.nowISO)
                    if ch.added > 0 || ch.removed > 0 {
                        state["last_change"] = ["added": n(ch.added), "removed": n(ch.removed), "kept": n(ch.kept), "at": .string(uc.nowISO)]
                    }
                    proposal = nil
                    try put(c, stateKey, .object(state))
                } else {
                    proposal = ["kind": "umplanung", "hash": .string(b.hash), "added": n(added), "removed": n(removed),
                                "message": .string("Größere Änderung: \(added) neue und \(removed) wegfallende Lernblöcke.")]
                }
            }
            try put(c, proposalKey, proposal)
        } else if state["hash"]?.string == b.hash, proposal != nil {
            proposal = nil
            try put(c, proposalKey, nil)
        }
        let fill: JSONValue = state["hash"] != nil ? try fillMaterials(c, today: t, clock: uc) : ["assign": [], "overflow": []]
        return Ensured(build: b, result: result, state: state, proposal: proposal == .object([:]) ? nil : proposal, fill: fill)
    }

    static func resultOut(_ r: JSONValue) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for k in ["status", "feasible", "message", "deadlines", "options", "missing_minutes"] { out[k] = r[k] ?? .null }
        return .object(out)
    }

    static func planNow(_ c: SQLiteConnection, _ body: [String: JSONValue], clock uc: UniFlowClock) throws -> JSONValue {
        let t = T.today(uc)
        if let v = body["accept_partial"], v.bool == nil { throw bad("accept_partial: ja oder nein.") }
        try dedupeBlocks(c)
        try markMissed(c, today: t, blockCredit: SP.credit(try sessionRows(c), nowTs: nowTs(uc))["blocks"]?.object ?? [:])
        let state = try object(c, stateKey)
        let partial = body["accept_partial"]?.bool ?? (state["partial"]?.bool ?? false)
        let b = try build(c, today: t, partial: partial, clock: uc)
        if (b.input["modules"]?.array ?? []).isEmpty { throw bad("Erst für mindestens ein Modul ein Lernziel in Stunden eintragen.") }
        let result = try SP.plan(b.input)
        if result["status"]?.string == "unterdeckt" { return ["applied": false, "result": resultOut(result)] }
        let ch = try apply(c, result, today: t, clock: uc)
        let change: JSONValue = ["added": n(ch.added), "removed": n(ch.removed), "kept": n(ch.kept), "at": .string(uc.nowISO)]
        try put(c, stateKey, ["hash": .string(b.hash), "at": .string(uc.nowISO), "partial": .bool(partial), "last_change": change])
        try put(c, proposalKey, nil)
        _ = try fillMaterials(c, today: t, clock: uc)
        return ["applied": true, "change": ["added": n(ch.added), "removed": n(ch.removed), "kept": n(ch.kept)], "result": resultOut(result)]
    }

    static func keepPlan(_ c: SQLiteConnection, clock uc: UniFlowClock) throws -> JSONValue {
        var state = try object(c, stateKey)
        let b = try build(c, today: T.today(uc), partial: state["partial"]?.bool ?? false, clock: uc)
        state["hash"] = .string(b.hash)
        state["at"] = .string(uc.nowISO)
        try put(c, stateKey, .object(state))
        try put(c, proposalKey, nil)
        return ["ok": true]
    }

    // MARK: Uebersicht

    static func minutes(_ p: [String: JSONValue]) -> Int {
        if let a = hm(p["start_time"]), let b = hm(p["end_time"]) { return max(0, b - a) }
        return SP.num(p["planned_minutes"])
    }

    static func overview(_ c: SQLiteConnection, auto: Bool, clock uc: UniFlowClock) throws -> JSONValue {
        let t = T.today(uc), ti = T.iso(t)
        try LocalModules.ensureModules(c, clock: uc)
        let e = try ensure(c, today: t, auto: auto, clock: uc)
        let b = e.build
        let cr = SP.credit(try sessionRows(c), nowTs: nowTs(uc))
        let goalIDs = Set(b.goals.map { $0["module_id"] ?? .null })
        let plannedRows = try c.rows("""
            SELECT module_id, date, start_time, end_time, planned_minutes, status, source FROM study_packages
            WHERE date >= ? AND status NOT IN ('verschoben','uebersprungen','erledigt','verpasst','teilweise')
            """, [.text(ti)])
        let past = try c.rows("SELECT id, module_id, start_time, end_time, planned_minutes FROM study_packages WHERE source='smart' AND date >= ? AND date < ?",
                              [.text(T.iso(t - 14)), .text(ti)])
        var modules: [JSONValue] = []
        var next: JSONValue = .null
        var nextDate: String?
        for g in b.goals {
            let mid = g["module_id"] ?? .null, key = SP.pyStr(mid)
            guard let info = b.info[key] else { continue }
            let ex = info.exam
            let fut = plannedRows.filter { r in r["module_id"] == mid && (ex.date.map { d in PyText.less(r["date"]?.string ?? "", d) } ?? true) }
                .reduce(0) { $0 + minutes($1) }
            let mine = past.filter { $0["module_id"] == mid }
            let planPast = mine.reduce(0) { $0 + minutes($1) }
            let adherence: JSONValue = planPast > 0
                ? n(mine.reduce(0) { $0 + SP.num(cr["blocks"]?[SP.pyStr($1["id"])]) } * 100 / planPast) : .null
            let daysLeft: JSONValue = ex.date.flatMap(BerlinClock.parseISODate).map { n($0 - t) } ?? .null
            let st = SP.moduleStats(["target_minutes": g["target_minutes"] ?? .null, "learned_minutes": n(info.learned),
                                     "lecture_minutes": n(info.lecture), "days_left": daysLeft, "planned_minutes": n(fut), "adherence": adherence])
            var pr = SP.num(g["priority"])
            if pr == 0 { pr = SP.num(g["module_priority"]) }
            if pr == 0 { pr = 2 }
            modules.append(["module_id": mid, "name": g["name"] ?? .null, "color": g["color"] ?? .null, "target_minutes": g["target_minutes"] ?? .null,
                            "learned_before_minutes": n(SP.num(g["learned_before_minutes"])), "credited_minutes": n(SP.num(cr["modules"]?[key])),
                            "include_lectures": .bool(SP.num(g["include_lectures"]) != 0), "writing": .bool(SP.num(g["writing"]) != 0),
                            "exam_attempt": n(SP.num(g["exam_attempt"]) == 0 ? 1 : SP.num(g["exam_attempt"])),
                            "exam_date": ex.date.map(JSONValue.string) ?? .null, "exam_source": ex.source.map(JSONValue.string) ?? .null,
                            "exam_confirmed": .bool(ex.confirmed), "exam_date_2": g["exam_date_2"] ?? .null, "module_exam_date": g["module_exam"] ?? .null,
                            "priority": n(pr), "adherence": adherence, "stats": st])
            if SP.num(g["writing"]) != 0, let d = ex.date, !PyText.less(d, ti), nextDate.map({ PyText.less(d, $0) }) ?? true {
                nextDate = d
                next = ["module_id": mid, "name": g["name"] ?? .null, "date": .string(d), "days": daysLeft, "confirmed": .bool(ex.confirmed)]
            }
        }
        let others: [JSONValue] = try c.rows("SELECT id, name, color, exam_date FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, id")
            .filter { !goalIDs.contains($0["id"] ?? .null) }
            .map { ["module_id": $0["id"] ?? .null, "name": $0["name"] ?? .null, "color": $0["color"] ?? .null, "exam_date": $0["exam_date"] ?? .null] }
        let mon = StudyWeeks.monday(t)
        let wkSessions = b.sessions.filter { s in
            guard let d = s["day"]?.string else { return false }
            return !PyText.less(d, T.iso(mon)) && !PyText.less(T.iso(mon + 6), d)
        }
        let wkCredit = SP.credit(wkSessions, nowTs: nowTs(uc))
        var weekDays: [JSONValue] = []
        var weekPlanned = 0
        for i in 0..<7 {
            let d = T.iso(mon + i)
            let rows = try c.rows("SELECT id, module_id, start_time, end_time, planned_minutes, status FROM study_packages WHERE source='smart' AND date=? AND status NOT IN ('verschoben','uebersprungen')",
                                  [.text(d)])
            let dc = SP.credit(wkSessions.filter { $0["day"]?.string == d }, nowTs: nowTs(uc))
            let pm = rows.reduce(0) { $0 + minutes($1) }
            weekPlanned += pm
            weekDays.append(["date": .string(d), "planned_minutes": n(pm), "learned_minutes": n((dc["modules"]?.object ?? [:]).values.reduce(0) { $0 + SP.num($1) }),
                             "blocks": n(rows.count)])
        }
        return ["enabled": .bool(!b.goals.isEmpty), "today": .string(ti), "settings": publicSettings(b.settings), "next_exam": next,
                "modules": .array(modules), "modules_without_goal": .array(others),
                "plan": e.result.map(resultOut) ?? .null, "planned": .bool(e.state["hash"] != nil), "proposal": e.proposal ?? .null,
                "last_change": e.state["last_change"] ?? .null,
                "week": ["start": .string(T.iso(mon)), "days": .array(weekDays), "planned_minutes": n(weekPlanned),
                         "learned_minutes": n((wkCredit["modules"]?.object ?? [:]).values.reduce(0) { $0 + SP.num($1) })],
                "conflicts": .array(try conflicts(c, today: t, b, e)),
                "running": .array(try c.rows("SELECT * FROM study_sessions WHERE state IN ('laeuft','pause') AND deleted_at IS NULL ORDER BY id").map { sessionOut($0, clock: uc) })]
    }

    static func conflicts(_ c: SQLiteConnection, today t: Int, _ b: Build, _ e: Ensured) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var names: [JSONValue: String] = [:]
        for g in b.goals { names[g["module_id"] ?? .null] = g["name"]?.string ?? "" }
        let ti = T.iso(t)
        let occ = b.occ.filter { !PyText.less($0["date"]?.string ?? "", ti) }
        for p in try c.rows("""
            SELECT * FROM study_packages WHERE source='smart' AND date >= ? AND (COALESCE(locked,0)=1 OR COALESCE(manual,0)=1)
            AND status='geplant' AND start_time IS NOT NULL AND end_time IS NOT NULL ORDER BY date, start_time
            """, [.text(ti)]) {
            guard let d = p["date"]?.string, let day = BerlinClock.parseISODate(d), let a = hm(p["start_time"]), let z = hm(p["end_time"]) else { continue }
            for x in try slotConflicts(c, p, day: day, a, z, occ: occ.filter { $0["date"]?.string == d }) {
                let who = names[p["module_id"] ?? .null] ?? (p["subject"]?.string ?? "Block")
                out.append(["kind": x["kind"] ?? .null, "package_id": p["id"] ?? .null, "module_id": p["module_id"] ?? .null, "date": .string(d),
                            "text": .string("\(who) am \(d) \(T.text(p["start_time"])): \(x["text"]?.string ?? "")")])
            }
        }
        for g in b.goals where SP.num(g["writing"]) != 0 {
            guard let ex = b.info[SP.pyStr(g["module_id"])]?.exam else { continue }
            let name = g["name"]?.string ?? ""
            if ex.date == nil {
                out.append(["kind": "kein_termin", "module_id": g["module_id"] ?? .null, "text": .string("\(name): Klausurtermin fehlt")])
            } else if !ex.confirmed {
                out.append(["kind": "unbestaetigt", "module_id": g["module_id"] ?? .null, "text": .string("\(name): Klausurtermin \(ex.date!) ist nicht bestätigt")])
            }
        }
        if let r = e.result, r["status"]?.string == "unterdeckt" { out.append(["kind": "unterdeckt", "text": r["message"] ?? .null]) }
        for o in (e.fill["overflow"]?.array ?? []).prefix(20) {
            let who = names[o["module_id"] ?? .null] ?? "Modul"
            out.append(["kind": "material", "module_id": o["module_id"] ?? .null, "file_id": o["file_id"] ?? .null,
                        "text": .string("\(who): „\(o["title"]?.string ?? "")“ passt nicht mehr ins Stundenbudget")])
        }
        return out
    }

    /// Smart Planner an: mindestens ein Lernziel fuer ein aktives Modul, das man schreibt (`study.smart_active`)
    static func active(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("""
            SELECT 1 FROM study_goals g JOIN modules m ON m.id=g.module_id
            WHERE COALESCE(m.active,1)=1 AND g.writing=1 AND g.target_minutes>0 LIMIT 1
            """) != nil
    }
}
