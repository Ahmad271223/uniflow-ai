import Foundation
import XCTest
@testable import UniFlowCore

// Smart Planner 2.0 (Auftrag des Inhabers vom 12.11.2026) im iPad-Kern ueber die Endpunkte, dieselben Szenarien wie
// tests/test_smart_goals.py: Pflichtbeispiel 670/350/320 h, Kalender neben Vorlesungen, Lernzeit ohne Doppelzaehlung,
// Haken nur mit Minuten, Neuplanung (Ziel erhoeht, Klausur verschoben, gesperrt/manuell bleibt), verpasste Bloecke,
// doppelt gestartete Neuplanung, zwei Geraete (eines offline), Material im Budget. Feste Uhr: Mo 16.11.2026 08:00.

private final class Now: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ local: String) { date = UniFlowClock.fixed(berlin: local)!.now }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    var clock: UniFlowClock { UniFlowClock { [self] in lock.withLock { date } } }
}

final class SmartGoalsTests: XCTestCase {
    private func backend(_ now: Now) async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: now.clock)
    }

    @discardableResult
    private func send(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil, status: Int = 200,
                      file: StaticString = #filePath, line: UInt = #line) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!, body: body.map { $0.serialized() } ?? Data()))
        XCTAssertEqual(r.status, status, "\(method) \(path): \(String(data: r.body, encoding: .utf8) ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    private func sql(_ b: LocalBackend, _ q: String, _ p: [SQLiteValue] = []) async throws {
        try await b.context.database.transaction { try $0.execute(q, p) }
    }

    private func rows(_ b: LocalBackend, _ q: String, _ p: [SQLiteValue] = []) async throws -> [[String: JSONValue]] {
        try await b.context.database.withConnection { try $0.rows(q, p) }
    }

    private func module(_ b: LocalBackend, _ name: String, exam: String?, course: String? = nil, sort: Int = 0) async throws -> Int {
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(name, color, sort, exam_date, created_at) VALUES (?, '#336699', ?, ?, '2026-10-01T09:00:00')",
                          [.text(name), .integer(Int64(sort)), exam.map { .text($0) } ?? .null])
            let id = c.lastInsertRowID
            if let course {
                try c.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES (?, ?, ?, 'vorlesung', ?, 1, '2026-10-01')",
                              [.text(course), .text(name), .text(name), .integer(id)])
            }
            return Int(id)
        }
    }

    private func blocks(_ b: LocalBackend, _ module: Int? = nil) async throws -> [[String: JSONValue]] {
        try await rows(b, "SELECT * FROM study_packages WHERE source='smart'" + (module != nil ? " AND module_id=?" : "") + " ORDER BY date, start_time",
                       module.map { [.integer(Int64($0))] } ?? [])
    }

    private func three(_ b: LocalBackend, hours: [Double] = [200, 250, 220]) async throws -> [Int] {
        var ids: [Int] = []
        for (i, (name, w)) in [("Mathematik", 10), ("Programmieren", 12), ("Elektrotechnik", 14)].enumerated() {
            let exam = BerlinClock.isoDate(BerlinClock.parseISODate("2026-11-16")! + 7 * w)
            ids.append(try await module(b, name, exam: exam, sort: i))
        }
        for (id, h) in zip(ids, hours) { await send(b, "PUT", "/api/goals/\(id)", ["target_hours": .number(h)]) }
        return ids
    }

    private func minutes(_ rows: [[String: JSONValue]]) -> Int { rows.reduce(0) { $0 + ($1["planned_minutes"]?.int ?? 0) } }

    // MARK: Pflichtbeispiel

    func testPflichtbeispielUnterdeckungDannTeilplan() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        _ = try await three(b)
        await send(b, "PUT", "/api/settings", ["free_days": [5, 6]])
        await send(b, "PUT", "/api/goals/settings", ["utilization": 100, "bedtime": "23:00", "sleep_hours": 10, "leisure_minutes": 540])
        let o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["plan"]?["status"]?.string, "unterdeckt")
        XCTAssertEqual(o["plan"]?["message"]?.string, "670 h nötig, 350 h verfügbar, fehlen 320 h")
        var bl = try await blocks(b)
        XCTAssertTrue(bl.isEmpty)
        let r = await send(b, "POST", "/api/goals/plan", [:])
        XCTAssertEqual(r["applied"], false)
        bl = try await blocks(b)
        XCTAssertTrue(bl.isEmpty, "kein scheinbar vollstaendiger Plan")
        let kinds = Set((r["result"]?["options"]?.array ?? []).compactMap { $0["kind"]?.string })
        XCTAssertTrue(kinds.isSuperset(of: ["ziele", "teilplan", "freizeit"]))
        XCTAssertFalse(kinds.contains("nutzungsquote"), "bei 100 % keine Stunden erfinden")
        let p = await send(b, "POST", "/api/goals/plan", ["accept_partial": true])
        XCTAssertEqual(p["result"]?["status"]?.string, "teilplan")
        bl = try await blocks(b)
        XCTAssertEqual(minutes(bl), 350 * 60)
        XCTAssertTrue(bl.allSatisfy { ($0["start_time"]?.string ?? "") >= "09:00" && ($0["end_time"]?.string ?? "") <= "14:00" })
    }

    func testPlanImKalenderNebenVorlesungenSchlafUndFreizeit() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let ids = try await three(b, hours: [60, 80, 70])
        try await sql(b, "INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, created_at) VALUES (?, 'Mathe-VL', 'vorlesung', 1, '10:00', '12:00', 'weekly', 1, '2026-10-01')",
                      [.integer(Int64(ids[0]))])
        let r = await send(b, "POST", "/api/goals/plan", [:])
        XCTAssertEqual(r["result"]?["status"]?.string, "ok")
        let cal = await send(b, "GET", "/api/calendar?start=2026-11-17&end=2026-11-17")
        let smart = (cal["days"]?.array?.first?["packages"]?.array ?? []).filter { $0["source"]?.string == "smart" }
        XCTAssertFalse(smart.isEmpty)
        for p in smart {
            let s = p["start_time"]?.string ?? "", e = p["end_time"]?.string ?? ""
            XCTAssertFalse(s < "12:30" && e > "09:30", "Block ueber Vorlesung samt Fahrtzeit: \(s)-\(e)")
            XCTAssertTrue(s >= "09:00" && e <= "21:00", "Schlaf/Freizeit: \(s)-\(e)")
        }
        let o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["next_exam"]?["days"], 70)
        XCTAssertEqual(o["modules"]?.array?.first?["stats"]?["status"]?.string, "auf_kurs")
        for m in o["modules"]?.array ?? [] {
            let exam = m["exam_date"]?.string ?? ""
            for x in try await blocks(b, m["module_id"]?.int) { XCTAssertLessThan(x["date"]?.string ?? "", exam, "nie am/nach der Klausur") }
        }
    }

    // MARK: Lernzeit

    func testStoppuhrDoppelbuchungUeberlappungKorrektur() async throws {
        let now = Now("2026-11-16T08:00:00")
        let b = try await backend(now)
        let mid = try await module(b, "Programmieren", exam: "2027-02-08")
        await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 100, "learned_before_hours": 2])
        let s = await send(b, "POST", "/api/sessions/start", ["uuid": "timer-aaaa-1", "module_id": .number(Double(mid))])
        XCTAssertEqual(s["state"]?.string, "laeuft")
        now.advance(30 * 60)
        await send(b, "POST", "/api/sessions/timer-aaaa-1/pause")
        now.advance(20 * 60)
        await send(b, "POST", "/api/sessions/timer-aaaa-1/resume")
        now.advance(15 * 60)
        let stop = await send(b, "POST", "/api/sessions/timer-aaaa-1/stop")
        XCTAssertEqual(stop["credited_minutes"], 45)
        let again = await send(b, "POST", "/api/sessions/start", ["uuid": "timer-aaaa-1", "module_id": .number(Double(mid))])
        XCTAssertEqual(again["state"]?.string, "fertig", "dieselbe uuid zaehlt einmal")
        let a = BerlinClock.utcSeconds(localISO: "2026-11-16T08:00:00")!
        await send(b, "POST", "/api/sessions", ["uuid": "eintrag-bbbb-2", "module_id": .number(Double(mid)), "start": .number(Double(a)), "end": .number(Double(a + 3600))])
        var o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["credited_minutes"], 65)
        XCTAssertEqual(o["modules"]?.array?.first?["stats"]?["learned_minutes"], 185)
        await send(b, "POST", "/api/sessions", ["module_id": .number(Double(mid)), "start": .number(Double(a + 99999)), "end": .number(Double(a + 100000))], status: 400)
        await send(b, "POST", "/api/sessions", ["module_id": .number(Double(mid)), "minutes": 0], status: 400)
        await send(b, "POST", "/api/sessions", ["module_id": .number(Double(mid)), "minutes": 30, "day": "2026-12-24"], status: 400)
        await send(b, "POST", "/api/sessions", ["module_id": 4242, "minutes": 30], status: 404)
        let fix = await send(b, "PATCH", "/api/sessions/timer-aaaa-1", ["minutes": 30])
        XCTAssertEqual(fix["credited_minutes"], 30)
        await send(b, "DELETE", "/api/sessions/eintrag-bbbb-2")
        o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["credited_minutes"], 30)
        await send(b, "POST", "/api/sessions/nicht-da-123/stop", status: 404)
    }

    func testAbgehakterBlockZaehltNurMitMinuten() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let mid = try await module(b, "Elektrotechnik", exam: "2027-02-22")
        await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 40])
        await send(b, "POST", "/api/goals/plan", [:])
        let all = try await blocks(b, mid)
        let today = try XCTUnwrap(all.first { $0["date"]?.string == "2026-11-16" }?["id"]?.int)
        await send(b, "POST", "/api/goals/blocks/\(today)/done", [:], status: 400)
        await send(b, "POST", "/api/goals/blocks/\(today)/done", ["minutes": 40])
        await send(b, "POST", "/api/goals/blocks/\(today)/done", ["minutes": 25])
        var o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["credited_minutes"], 25, "zweiter Haken ersetzt den ersten")
        let future = try XCTUnwrap(all.first { ($0["date"]?.string ?? "") > "2026-11-16" }?["id"]?.int)
        await send(b, "POST", "/api/goals/blocks/\(future)/done", ["minutes": 10], status: 400)
        await send(b, "POST", "/api/goals/blocks/\(today)/undone")
        o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["credited_minutes"], 0)
    }

    // MARK: Neuplanung

    func testZielErhoehtKlausurVerschobenGesperrtUndManuellBleiben() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let ids = try await three(b, hours: [30, 40, 30])
        await send(b, "POST", "/api/goals/plan", [:])
        let before = try await blocks(b)
        let locked = try XCTUnwrap(before.first { ($0["date"]?.string ?? "") > "2026-11-18" })
        let moved = try XCTUnwrap(before.first { ($0["date"]?.string ?? "") > "2026-11-20" && $0["id"] != locked["id"] })
        await send(b, "PATCH", "/api/goals/blocks/\(locked["id"]!.int!)", ["locked": true])
        let p = await send(b, "PATCH", "/api/packages/\(moved["id"]!.int!)", ["start_time": "06:00", "end_time": "07:00"])
        XCTAssertEqual(p["manual"], 1)
        await send(b, "PUT", "/api/goals/\(ids[2])", ["target_hours": 31])
        var o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["proposal"], .null, "kleine Aenderung sofort")
        XCTAssertGreaterThanOrEqual(o["last_change"]?["added"]?.int ?? 0, 1)
        try await sql(b, "UPDATE modules SET exam_date='2027-01-11' WHERE id=?", [.integer(Int64(ids[0]))])
        let count = try await blocks(b).count
        o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["proposal"]?["kind"]?.string, "umplanung")
        var now = try await blocks(b)
        XCTAssertEqual(now.count, count, "grosse Umplanung erst nach Bestaetigung")
        let r = await send(b, "POST", "/api/goals/plan", [:])
        XCTAssertEqual(r["applied"], true)
        now = try await blocks(b)
        let after = Dictionary(uniqueKeysWithValues: now.map { ($0["id"]!, $0) })
        XCTAssertEqual(after[locked["id"]!]?["date"], locked["date"])
        XCTAssertEqual(after[locked["id"]!]?["start_time"], locked["start_time"])
        XCTAssertEqual(after[moved["id"]!]?["start_time"], "06:00")
        for x in try await blocks(b, ids[0]) where x["locked"] == 0 && x["manual"] == 0 {
            XCTAssertLessThan(x["date"]?.string ?? "", "2027-01-11")
        }
        o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["proposal"], .null)
        try await sql(b, "UPDATE study_packages SET date='2027-01-20', module_id=? WHERE id=?", [.integer(Int64(ids[0])), SQLiteValue(json: locked["id"]!)!])
        o = await send(b, "GET", "/api/goals")
        XCTAssertTrue((o["conflicts"]?.array ?? []).contains { $0["kind"] == "klausur" && $0["package_id"] == locked["id"] })
    }

    func testVerpassteBloeckeWerdenNachgeplant() async throws {
        let now = Now("2026-11-16T08:00:00")
        let b = try await backend(now)
        let mid = try await module(b, "Mathematik", exam: "2027-01-25")
        await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 20])
        await send(b, "POST", "/api/goals/plan", [:])
        let first = try await blocks(b, mid).filter { ($0["date"]?.string ?? "") <= "2026-11-17" }
        XCTAssertFalse(first.isEmpty)
        now.advance(2 * 86400)
        await send(b, "GET", "/api/goals")
        let all = try await blocks(b, mid)
        for f in first { XCTAssertEqual(all.first { $0["id"] == f["id"] }?["status"]?.string, "verpasst") }
        XCTAssertEqual(minutes(all.filter { ($0["date"]?.string ?? "") >= "2026-11-18" && $0["status"] == "geplant" }), 20 * 60)
    }

    func testKlausurEntferntUndZielErreicht() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let a = try await module(b, "Mathematik", exam: "2027-01-25")
        let c = try await module(b, "Programmieren", exam: "2027-02-08", sort: 1)
        await send(b, "PUT", "/api/goals/\(a)", ["target_hours": 10])
        await send(b, "PUT", "/api/goals/\(c)", ["target_hours": 10, "learned_before_hours": 12])
        await send(b, "POST", "/api/goals/plan", [:])
        var bc = try await blocks(b, c)
        XCTAssertTrue(bc.isEmpty)
        var o = await send(b, "GET", "/api/goals")
        XCTAssertEqual((o["modules"]?.array ?? []).first { $0["module_id"]?.int == c }?["stats"]?["status"]?.string, "erreicht")
        await send(b, "PUT", "/api/goals/\(a)", ["writing": false])
        o = await send(b, "GET", "/api/goals")
        bc = try await blocks(b, a)
        XCTAssertTrue(bc.filter { ($0["date"]?.string ?? "") > "2026-11-16" }.isEmpty)
    }

    func testDoppeltGestarteteNeuplanungPlantEinmal() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let ids = try await three(b, hours: [30, 40, 30])
        await send(b, "POST", "/api/goals/plan", [:])
        await send(b, "PUT", "/api/goals/\(ids[1])", ["target_hours": 41])
        await withTaskGroup(of: Int.self) { g in
            for _ in 0..<4 { g.addTask { await b.handle(LocalRequest(method: "GET", path: "/api/goals")).status } }
            for await s in g { XCTAssertEqual(s, 200) }
        }
        let bl = try await blocks(b)
        let keys = bl.map { "\($0["module_id"]!)|\($0["date"]!)|\($0["start_time"]!)" }
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertEqual(minutes(bl.filter { $0["module_id"]?.int == ids[1] }), 41 * 60)
    }

    /// Zwei Geraete, eines offline: beide planen denselben Plan, misst dieselbe Stunde; der Abgleich bringt die Zeilen
    /// des anderen Geraets (hier von Hand eingefuegt) -> keine doppelten Bloecke, Lernzeit einmal
    func testZweiGeraeteEinesOfflineDoppelteBloeckeUndLernzeit() async throws {
        let now = Now("2026-11-16T08:00:00")
        let ipad = try await backend(now), mac = try await backend(now)
        for dev in [ipad, mac] {
            let mid = try await module(dev, "Mathematik", exam: "2027-01-25")
            await send(dev, "PUT", "/api/goals/\(mid)", ["target_hours": 10])
            await send(dev, "POST", "/api/goals/plan", [:])
        }
        let fromMac = try await blocks(mac)
        let fromIPad = try await blocks(ipad)
        XCTAssertEqual(fromMac.map { $0["start_time"] }, fromIPad.map { $0["start_time"] }, "deterministisch auf beiden Geraeten")
        let a = BerlinClock.utcSeconds(localISO: "2026-11-16T07:00:00")!
        try await b(ipad) { c in
            for x in fromMac {
                try c.execute("""
                    INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at, start_time, end_time, source)
                    VALUES (?,1,?,?,?,'geplant',0,1,'x',?,?,'smart')
                    """, [x["date"], x["subject"], x["title"], x["planned_minutes"], x["start_time"], x["end_time"]].map { SQLiteValue(json: $0 ?? .null) ?? .null })
            }
            for u in ["geraet-a-0001", "geraet-b-0001"] {
                try c.execute("INSERT INTO study_sessions(uuid, module_id, kind, state, segments, day, created_at, updated_at) VALUES (?,1,'timer','fertig',?, '2026-11-16','x','x')",
                              [.text(u), .text("[[\(a), \(a + 3600)]]")])
            }
        }
        let o = await send(ipad, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["credited_minutes"], 60)
        let after = try await blocks(ipad)
        let keys = after.map { "\($0["date"]!)|\($0["start_time"]!)" }
        XCTAssertEqual(keys.count, Set(keys).count, "keine doppelten Bloecke")
        XCTAssertEqual(minutes(after.filter { $0["status"] == "geplant" }), 9 * 60)
    }

    private func b(_ backend: LocalBackend, _ body: @escaping @Sendable (SQLiteConnection) throws -> Void) async throws {
        try await backend.context.database.transaction(body)
    }

    func testNeueUnterlagenImBudgetUeberschussIstKonflikt() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let mid = try await module(b, "Programmieren", exam: "2026-12-07", course: "kp")
        let week1 = BerlinClock.utcSeconds(localISO: "2026-11-16T10:00:00")!
        try await sql(b, "INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES ('blatt1', 'kp', 'Blatt 1.pdf', ?, 'Übungsblätter')", [.integer(Int64(week1))])
        await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 3])
        await send(b, "PUT", "/api/goals/settings", ["utilization": 20])
        await send(b, "POST", "/api/goals/plan", [:])
        await send(b, "GET", "/api/goals")
        let tasks = try await rows(b, "SELECT t.*, p.source FROM study_tasks t JOIN study_packages p ON p.id=t.package_id")
        XCTAssertEqual(Set(tasks.compactMap { $0["file_id"]?.string }), ["blatt1"])
        XCTAssertEqual(tasks.reduce(0) { $0 + ($1["est_minutes"]?.int ?? 0) }, 60)
        for i in 2..<12 {
            try await sql(b, "INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'kp', ?, ?, 'Übungsblätter')",
                          [.text("blatt\(i)"), .text("Blatt \(i).pdf"), .integer(Int64(week1 + 3600 * i))])
        }
        let o = await send(b, "GET", "/api/goals")
        let mine = try await blocks(b, mid)
        let budget = minutes(mine)
        let used = try await rows(b, "SELECT COALESCE(SUM(est_minutes),0) n FROM study_tasks")[0]["n"]?.int ?? 0
        XCTAssertEqual(budget, 180)
        XCTAssertLessThanOrEqual(used, budget, "Budget waechst nie")
        XCTAssertTrue((o["conflicts"]?.array ?? []).contains { $0["kind"] == "material" })
    }

    func testKonfliktpruefungBeimVerschieben() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let mid = try await module(b, "Mathematik", exam: "2026-12-07")
        await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 10])
        try await sql(b, "INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, attend, created_at) VALUES (?, 'Mathe-VL', 'vorlesung', 2, '10:00', '12:00', 'weekly', 1, '2026-10-01')",
                      [.integer(Int64(mid))])
        await send(b, "POST", "/api/goals/plan", [:])
        let first = try await blocks(b, mid)
        let id = try XCTUnwrap(first.first?["id"]?.int)
        var r = await send(b, "POST", "/api/goals/blocks/\(id)/check", ["date": "2026-11-18", "start": "11:00"])
        XCTAssertTrue((r["conflicts"]?.array ?? []).contains { $0["kind"] == "termin" })
        r = await send(b, "POST", "/api/goals/blocks/\(id)/check", ["date": "2026-12-08", "start": "15:00"])
        XCTAssertTrue((r["conflicts"]?.array ?? []).contains { $0["kind"] == "klausur" })
        r = await send(b, "POST", "/api/goals/blocks/\(id)/check", ["date": "2026-11-18", "start": "07:00"])
        XCTAssertEqual(r["conflicts"]?.array?.count, 0)
    }

    func testEinstellungenUndUngueltigeEingaben() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let s = await send(b, "GET", "/api/goals/settings")
        XCTAssertEqual(s["sleep_hours"], 10)
        XCTAssertEqual(s["bedtime_hm"], "23:00")
        for bad: JSONValue in [["sleep_hours": 3], ["sleep_hours": "zehn"], ["utilization": 0], ["bedtime": "25:00"],
                               ["commitments": [["weekday": 7, "start": "10:00", "end": "11:00"]]],
                               ["commitments": [["weekday": 1, "start": "12:00", "end": "11:00"]]], ["min_block": 90, "max_block": 60]] {
            await send(b, "PUT", "/api/goals/settings", bad, status: 400)
        }
        let ok = await send(b, "PUT", "/api/goals/settings", ["sleep_hours": 8.5, "utilization": 75,
                                                            "commitments": [["weekday": 2, "start": "16:00", "end": "20:00", "kind": "arbeit"]]])
        XCTAssertEqual(ok["sleep_minutes"], 510)
        XCTAssertEqual(ok["commitments"]?.array?.first?["title"], "Arbeit")
        let mid = try await module(b, "Analysis", exam: nil)
        await send(b, "PUT", "/api/goals/99999", ["target_hours": 10], status: 404)
        for bad: JSONValue in [["target_hours": -1], ["target_hours": "viel"], ["target_hours": 5000], ["writing": "ja"],
                               ["exam_attempt": 3], ["exam_attempt": 2], ["exam_date_2": "31.02.2027"], ["priority": 9]] {
            await send(b, "PUT", "/api/goals/\(mid)", bad, status: 400)
        }
        let g = await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 200.5])
        XCTAssertEqual(g["target_minutes"], 12030, "Teilstunden")
        await send(b, "POST", "/api/goals/plan", ["accept_partial": "ja"], status: 400)
    }

    /// Klausurtermin automatisch erkannt: unbestaetigt bis zur Bestaetigung; Zweittermin waehlbar
    func testUnbestaetigterTerminUndZweittermin() async throws {
        let b = try await backend(Now("2026-11-16T08:00:00"))
        let mid = try await module(b, "Mathematik", exam: "2027-02-01")
        try await sql(b, "INSERT INTO settings(key, value) VALUES ('exam_dates_auto', ?)", [.text("{\"\(mid)\": \"2027-02-01\"}")])
        await send(b, "PUT", "/api/goals/\(mid)", ["target_hours": 10])
        var o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["exam_source"], "automatisch")
        XCTAssertEqual(o["modules"]?.array?.first?["exam_confirmed"], false)
        XCTAssertTrue((o["conflicts"]?.array ?? []).contains { $0["kind"] == "unbestaetigt" })
        await send(b, "PUT", "/api/goals/\(mid)", ["confirm_exam": true])
        o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["exam_confirmed"], true)
        await send(b, "PUT", "/api/goals/\(mid)", ["exam_attempt": 2, "exam_date_2": "2027-03-29"])
        o = await send(b, "GET", "/api/goals")
        XCTAssertEqual(o["modules"]?.array?.first?["exam_date"], "2027-03-29")
        XCTAssertEqual(o["modules"]?.array?.first?["exam_source"], "zweittermin")
    }
}
