import Foundation
import XCTest
@testable import UniFlowCore

// Stundenplan gegen die Python-Referenz: timetable-logic.json (tools/gen-timetable-fixture.py) mit eingefrorener Uhr
// (Sonntag, 25.10.2026, 14:30:05 Europe/Berlin, Tag der Zeitumstellung) und erfundenen Daten.

private func fixture() throws -> JSONValue {
    // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/LocalTimetableTests.swift -> Repository-Wurzel
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/timetable-logic.json")))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

/// Erste Abweichung zweier JSON-Werte mit Pfad (fuer lesbare Fehlermeldungen)
func jsonDiff(_ a: JSONValue?, _ b: JSONValue?, _ path: String = "$") -> String? {
    switch (a, b) {
    case (.object(let x)?, .object(let y)?):
        for k in Set(x.keys).union(y.keys).sorted() {
            if let d = jsonDiff(x[k], y[k], "\(path).\(k)") { return d }
        }
        return nil
    case (.array(let x)?, .array(let y)?):
        if x.count != y.count { return "\(path): \(x.count) statt \(y.count) Einträge" }
        for (i, (p, q)) in zip(x, y).enumerated() {
            if let d = jsonDiff(p, q, "\(path)[\(i)]") { return d }
        }
        return nil
    default:
        return a == b ? nil : "\(path): \(a?.jsonString() ?? "fehlt") statt \(b?.jsonString() ?? "fehlt")"
    }
}

final class LocalTimetableTests: XCTestCase {

    /// Lokales Backend mit denselben Seed-Daten wie der Generator
    private func seeded(_ fx: JSONValue) async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let seed = fx["seed"]?.array ?? []
        try await backend.context.database.transaction { c in
            for s in seed {
                try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
        }
        return backend
    }

    /// Anfrage wie im Generator: JSON-Rumpf, Formularfelder (sortiert) und eine Datei
    private func request(_ s: JSONValue) -> LocalRequest {
        let method = s["method"]?.string ?? "GET"
        let url = URL(string: "uniflow-local://device" + (s["path"]?.string ?? ""))!
        if s["form"] != nil || s["file"] != nil {
            let b = "uniflow-fixture"
            var body = ""
            let form = s["form"]?.object ?? [:]
            for k in form.keys.sorted() { body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(form[k]?.string ?? "")\r\n" }
            if let f = s["file"] {
                body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(f["field"]?.string ?? "")\"; filename=\"\(f["filename"]?.string ?? "")\"\r\n"
                body += "Content-Type: \(f["content_type"]?.string ?? "")\r\n\r\n\(f["text"]?.string ?? "")\r\n"
            }
            body += "--\(b)--\r\n"
            return LocalRequest(method: method, url: url, headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8))
        }
        let body = s["body"].map { $0.serialized() }
        return LocalRequest(method: method, url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
    }

    private func tables(_ backend: LocalBackend) async throws -> JSONValue {
        try await backend.context.database.withConnection { c -> JSONValue in
            var out: [String: JSONValue] = [:]
            for t in ["course_events", "event_exceptions", "schedule_imports"] {
                out[t] = .array(try c.rows("SELECT * FROM \(t) ORDER BY id").map { r -> JSONValue in
                    var r = r
                    if t == "schedule_imports", let p = r["parsed"]?.string, !p.isEmpty { r["parsed"] = try JSONValue.parse(p) }
                    return .object(r)
                })
            }
            return .object(out)
        }
    }

    /// Dieselben Anfragen in derselben Reihenfolge wie gegen app/server.py: Status und Antwort exakt gleich, danach
    /// dieselben Zeilen in course_events, event_exceptions und schedule_imports
    func testStepsMatchPythonServer() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let steps = fx["steps"]?.array ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 40)
        var problems: [String] = []
        for (i, s) in steps.enumerated() {
            let label = "\(i) \(s["method"]?.string ?? "") \(s["path"]?.string ?? "")"
            let r = await backend.handle(request(s))
            if r.status != s["status"]?.int {
                problems.append("\(label): Status \(r.status) statt \(s["status"]?.int ?? 0) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                continue
            }
            if let d = jsonDiff(r.json, s["response"]) { problems.append("\(label): \(d)") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, fx["tables_after"]), jsonDiff(t, fx["tables_after"]) ?? "")
    }

    /// Uebersicht: Termine und freie Fenster von heute wie study.dashboard
    func testDashboardTodayMatchesPython() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/dashboard"))
        let today = try XCTUnwrap(r.json?["today"])
        XCTAssertNil(jsonDiff(today["events"], fx["dashboard_today"]?["events"]), jsonDiff(today["events"], fx["dashboard_today"]?["events"]) ?? "")
        XCTAssertNil(jsonDiff(today["free"], fx["dashboard_today"]?["free"]), jsonDiff(today["free"], fx["dashboard_today"]?["free"]) ?? "")
        XCTAssertEqual(today["events"]?.array?.count, 1, "Sonntagstermin am Tag der Zeitumstellung")
    }

    /// Kalenderdateien: UTC, TZID (Berlin, UTC, Windows-Name, New York, unbekannt), RRULE mit UNTIL/INTERVAL,
    /// EXDATE, ganztags, gefaltete Zeilen, kaputte Termine
    func testICSMatchesPython() throws {
        let cases = try fixture()["ics"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let name = c["name"]?.string ?? ""
            if name == "tzid-newyork" || name == "exdate", TimeZone(identifier: "America/New_York") == nil { continue }  // Linux ohne Zonen
            let got: JSONValue = .array(LocalTimetableImport.parseICS(c["text"]?.string ?? "").map(JSONValue.object))
            XCTAssertNil(jsonDiff(got, c["entries"]), "\(name): \(jsonDiff(got, c["entries"]) ?? "")")
        }
    }

    // Der difflib-Port (`SequenceMatcher`) hat einen Test mit einer Fallliste: LocalModulesTests
    // (sequence_ratios in study-modules.json). Der LSF-Export der Uni Hildesheim steht in HildesheimFixtureTests
    // (parse_ics und lsf.split_summary bzw. `LSFCalendar.splitSummary`).

    /// Dieselben Erwartungen wie tests/test_hildesheim.py an den LSF-Export (fixtures/hildesheim, expected.json), hier
    /// im Stundenplan des lokalen Backends: die Serien wie mit dem ICS-Import der App uebernommen (apply_import mit den
    /// Ausfaellen), dann liegt jede Serie ab date_from an ihrem Wochentag und jeder Ausfall (EXDATE) ist "ausfall".
    /// Ausdruecklich: der Donnerstags-Kurs (DTSTART Montag 26.10.) liegt am Donnerstag 29.10. und faellt an
    /// Heiligabend aus; die Serie mit zwei Wochentagen hat ihre Ausfaelle je Tag. Den Abgleich mit app/server.py auf
    /// erfundenen LSF-Daten macht testStepsMatchPythonServer (letzte Schritte von timetable-logic.json).
    func testHildesheimLSFExportInTimetable() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("packages/shared-contracts/fixtures/hildesheim")
        let expected = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("expected.json")))
        let names = ["lsf-course.ics", "lsf-plan.ics"]
        var parsed: [String: [LocalTimetableImport.Entry]] = [:]
        for name in names {
            parsed[name] = LocalTimetableImport.parseICS(try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))
            XCTAssertEqual(parsed[name]?.count, expected[name]?.array?.count, name)
        }

        // parse_ics: Wochentag aus BYDAY, nicht aus DTSTART (test_parse_ics_uses_byday_and_exdate)
        let thursday = try XCTUnwrap(parsed["lsf-course.ics"]?.first)
        XCTAssertEqual(thursday["weekday"], 3)
        XCTAssertEqual(thursday["date_from"], "2026-10-29")
        XCTAssertEqual(BerlinClock.parseISODate("2026-10-29").map(BerlinClock.weekday), 3, "29.10.2026 ist ein Donnerstag")
        XCTAssertEqual(BerlinClock.parseISODate("2026-10-26").map(BerlinClock.weekday), 0, "DTSTART 26.10.2026 ist ein Montag")
        XCTAssertEqual(thursday["exdates"], ["2026-12-24", "2026-12-31"], "Heiligabend und Silvester")
        // mehrere BYDAY: je Tag eine Serie mit den Ausfaellen an diesem Tag (test_parse_ics_multiple_bydays_split_exdates)
        let split = (parsed["lsf-plan.ics"] ?? []).filter { ($0["title"]?.string ?? "").contains("Testpädagogik") }
        XCTAssertEqual(split.map { [$0["weekday"] ?? .null, $0["date_from"] ?? .null, $0["exdates"] ?? .null] as JSONValue },
                       [[1, "2026-10-27", ["2026-12-22"]], [3, "2026-10-29", ["2026-12-24"]]])

        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let all = names.flatMap { parsed[$0] ?? [] }.map(JSONValue.object)
        let body: JSONValue = ["entries": .array(all), "source": "ics", "remove_ids": []]
        let confirm = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/import/confirm",
                                                        headers: ["Content-Type": "application/json"], body: body.serialized()))
        XCTAssertEqual(confirm.status, 200, String(decoding: confirm.body, as: UTF8.self))
        XCTAssertEqual(confirm.json?["new"]?.int, all.count)

        func day(_ date: String, start: String) async -> [String?] {
            let r = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/day", query: [.init("date", date)]))
            return (r.json?["events"]?.array ?? []).filter { $0["start"]?.string == start }.map { $0["status"]?.string }
        }
        for name in names {
            for e in expected[name]?.array ?? [] {
                let start = e["start_time"]?.string ?? "", first = e["date_from"]?.string ?? ""
                let atFirst = await day(first, start: start)
                XCTAssertEqual(atFirst, ["teilnahme"], "\(name): erster Termin \(first) \(start)")
                for x in e["exdates"]?.array?.compactMap(\.string) ?? [] {
                    let cancelled = await day(x, start: start)
                    XCTAssertEqual(cancelled, ["ausfall"], "\(name): Ausfall \(x) \(start)")
                }
            }
        }
        let monday = await day("2026-10-26", start: "16:00")
        XCTAssertEqual(monday, [], "Donnerstags-Kurs nicht am Montag aus DTSTART")
        let christmasEve = await day("2026-12-24", start: "16:00")
        XCTAssertEqual(christmasEve, ["ausfall"], "Donnerstags-Kurs faellt an Heiligabend aus")
        let newYearsEve = await day("2026-12-31", start: "10:00")
        XCTAssertEqual(newYearsEve, ["teilnahme"], "Testpaedagogik am Donnerstag 31.12. ohne EXDATE")
        let notes = try await backend.context.database.withConnection {
            try $0.rows("SELECT date, note FROM event_exceptions ORDER BY date, event_id").map { "\($0["date"]?.string ?? "") \($0["note"]?.string ?? "")" }
        }
        XCTAssertEqual(notes, ["2026-12-22 Ausfall laut Kalender", "2026-12-24 Ausfall laut Kalender", "2026-12-24 Ausfall laut Kalender",
                               "2026-12-31 Ausfall laut Kalender"], "jeder Ausfall genau einmal")
    }

    func testGuessModuleMatchesPython() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        for c in fx["guess_module"]?.array ?? [] {
            let title = c["title"]?.string ?? ""
            let got = try await backend.context.database.withConnection { try LocalTimetableImport.guessModule($0, title: title) }
            XCTAssertEqual(got, c["module_id"], title)
        }
    }

    func testMergeWeeklyMatchesPython() throws {
        for c in try fixture()["merge_weekly"]?.array ?? [] {
            let entries = (c["entries"]?.array ?? []).compactMap(\.object)
            let got: JSONValue = .array(try LocalTimetableImport.mergeWeekly(entries).map(JSONValue.object))
            XCTAssertNil(jsonDiff(got, c["merged"]), jsonDiff(got, c["merged"]) ?? "")
        }
    }

    /// auto_import wie nach dem Stud.IP-Abgleich: eindeutige Termine uebernehmen, parallele Gruppen bleiben offen;
    /// ein zweiter Lauf legt nichts doppelt an. Ein eben gespeicherter Kurs mit Fach (extra_seed) bekommt vorher sein
    /// Modul (ensure_modules), seine Termine damit auch.
    func testAutoImportMatchesPython() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let expect = fx["auto_import"] ?? .null
        let extra = expect["extra_seed"]?.array ?? []
        XCTAssertFalse(extra.isEmpty)
        let (first, second, modules) = try await backend.context.database.transaction { c -> (JSONValue, JSONValue, JSONValue) in
            try c.execute("DELETE FROM course_events")
            for s in extra {
                try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
            let a = try LocalTimetableImport.autoImport(c, clock: clock), b = try LocalTimetableImport.autoImport(c, clock: clock)
            return (a, b, .array(try c.rows("SELECT * FROM modules ORDER BY id").map(JSONValue.object)))
        }
        XCTAssertEqual(first, expect["first"])
        XCTAssertEqual(second, expect["second"])
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, expect["tables"]), jsonDiff(t, expect["tables"]) ?? "")
        XCTAssertNil(jsonDiff(modules, expect["modules"]), jsonDiff(modules, expect["modules"]) ?? "")
        let neu = t["course_events"]?.array?.filter { $0["course_id"] == "k-neu" } ?? []
        XCTAssertEqual(neu.count, 1)
        XCTAssertEqual(neu.first?["module_id"], 4, "Modul des neuen Fachs")
    }

    // MARK: nur auf dem Geraet

    /// Import aus Text, PDF und Bild braucht KI: Antwort wie die anderen KI-Pfade, nichts wird gespeichert
    func testAIImportSourcesAnswerLikeDroppedAI() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        func form(_ fields: [String: String], file: (String, String)? = nil) -> LocalRequest {
            let b = "x-test"
            var body = ""
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) { body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n" }
            if let (name, content) = file {
                body += "--\(b)\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n\(content)\r\n"
            }
            body += "--\(b)--\r\n"
            return LocalRequest(method: "POST", path: "/api/timetable/import/preview", headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8))
        }
        let cases: [(LocalRequest, Int, String)] = [
            (form(["source": "text", "text": "Montag 08:00 Mathe"]), 404, DroppedEndpoints.noAI),
            (form(["source": "pdf"]), 400, "PDF fehlt"),
            (form(["source": "pdf"], file: ("plan.pdf", "%PDF-1.4")), 404, DroppedEndpoints.noAI),
            (form(["source": "image"]), 400, "Bild fehlt"),
            (form(["source": "image"], file: ("plan.exe", "MZ")), 400, "Nur Bilddateien"),
            (form(["source": "image"], file: ("Plan.JPG", "x")), 404, DroppedEndpoints.noAI),
            (form(["source": "image"], file: ("plan", "x")), 404, DroppedEndpoints.noAI),
        ]
        for (req, status, message) in cases {
            let r = await backend.handle(req)
            XCTAssertEqual(r.status, status, message)
            XCTAssertEqual(r.json?["detail"]?.string, message)
        }
        let n = try await backend.context.database.scalar("SELECT COUNT(*) FROM schedule_imports")
        XCTAssertEqual(n, .integer(0))
    }

    func testConflictsValidateDays() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let bad = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts", query: [.init("days", "x")]))
        XCTAssertEqual(bad.status, 422)
        let huge = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts", query: [.init("days", "1000000")]))
        XCTAssertEqual(huge.status, 422)
        let none = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts", query: [.init("days", "-3")]))
        XCTAssertEqual(none.json, [])
    }

    /// Sperrzeiten gibt es nur noch in einer Fassung (`LocalTimetable.blocked`, auch fuer die freien Fenster), mit
    /// `int(b.get("weekday", -1))` wie Python: 2.5 und " 2 " zaehlen fuer Mittwoch, ohne Wochentag nie, "x" wird 500
    func testBlockedTimesConvertWeekdayLikePython() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        func setBlocked(_ list: JSONValue) async throws {
            try await backend.context.database.transaction { c in
                try c.execute("UPDATE settings SET value=? WHERE key='blocked_times'", [.text(String(decoding: list.serialized(), as: UTF8.self))])
            }
        }
        try await setBlocked([["weekday": 2.5, "start": "12:00", "end": "13:00", "title": "Halb"],
                              ["weekday": "2", "start": "15:00", "end": "16:00", "title": "Text"],
                              ["weekday": " 2 ", "start": "17:00", "end": "18:00", "title": "Leerraum"],
                              ["start": "08:00", "end": "09:00", "title": "Ohne Tag"],
                              ["weekday": 1, "start": "10:00", "end": "11:00", "title": "Dienstag"]])
        let day = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/day", query: [.init("date", "2026-10-28")]))
        XCTAssertEqual(day.status, 200)
        XCTAssertEqual(day.json?["blocked"]?.array?.compactMap { $0["title"]?.string }, ["Halb", "Text", "Leerraum"])
        let free = day.json?["free"]?.array ?? []
        XCTAssertFalse(free.isEmpty)
        XCTAssertFalse(free.contains { ($0["start"]?.int ?? 0) < 13 * 60 && ($0["end"]?.int ?? 0) > 12 * 60 }, "Sperrzeit 2.5 blockiert: \(free)")

        try await setBlocked([["weekday": "x", "start": "12:00", "end": "13:00"]])
        let bad = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/day", query: [.init("date", "2026-10-28")]))
        XCTAssertEqual(bad.status, 500)
    }

    /// Seit S6 ist auch `/api/timetable/reslot` echt (Lernlogik, StudyEndpoints): kein Platzhalter mehr im Stundenplan
    func testNoTimetablePlaceholderLeft() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let timetable = backend.router.allRoutes.filter { $0.pattern.template.hasPrefix("/api/timetable/") }
        XCTAssertEqual(timetable.filter(\.placeholder).map(\.pattern.template), [])
        XCTAssertGreaterThanOrEqual(timetable.count, 15)
    }
}
