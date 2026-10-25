import Foundation
import XCTest
@testable import UniFlowCore

private func repoFile(_ relative: String) throws -> Data {
    // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/LocalBackendTests.swift -> Repository-Wurzel
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent(relative))
}

private func fixture(_ name: String) throws -> JSONValue {
    try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/local-backend/\(name)"))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

/// Anfrage wie in den Fixtures: Pfad mit Query, JSON-Rumpf oder Formularfelder
private func request(_ method: String, _ r: JSONValue) -> LocalRequest {
    let url = URL(string: "uniflow-local://device" + (r["path"]?.string ?? ""))!
    if let form = r["form"]?.object {
        let b = "uniflow-fixture"
        var body = ""
        for k in form.keys.sorted() { body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(form[k]?.string ?? "")\r\n" }
        body += "--\(b)--\r\n"
        return LocalRequest(method: method, url: url, headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8))
    }
    // "raw": die Bytes, die Python gesendet hat (ganze und gebrochene Zahlen unterschieden)
    let body = r["raw"]?.string.map { Data($0.utf8) } ?? r["body"].flatMap { $0.isNull ? nil : $0 }?.serialized()
    return LocalRequest(method: method, url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
}

// MARK: - Python-Werte

final class PyJSONTests: XCTestCase {

    func testDumpsLikePython() throws {
        // Erwartungen: json.dumps(json.loads(text)) mit Python 3
        let cases: [(String, String)] = [
            (#"[5,6]"#, "[5, 6]"),
            (#"{"weekday":0,"start":"12:00","title":"Mittag ü 😀"}"#, #"{"weekday": 0, "start": "12:00", "title": "Mittag \u00fc \ud83d\ude00"}"#),
            (#"{"b":1,"a":[true,null,2.5,"\n\t\"\\"]}"#, #"{"b": 1, "a": [true, null, 2.5, "\n\t\"\\"]}"#),
            (#"[1.0, -0, -0.0, 1e2, 1E-7, 12345678901234567890]"#, "[1.0, 0, -0.0, 100.0, 1e-07, 12345678901234567890]"),
            (#"{"a": 1, "a": 2, "b": {}}"#, #"{"a": 2, "b": {}}"#),
            (#"["\u0001\u001f\u007f/"]"#, #"["\u0001\u001f\u007f/"]"#),
            (#"[NaN, Infinity, -Infinity]"#, "[NaN, Infinity, -Infinity]"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try PyJSON.parse(input).dumps, expected, input)
        }
    }

    func testReprOfFloatsLikePython() {
        let cases: [(Double, String)] = [(4.5, "4.5"), (100, "100.0"), (1e16, "1e+16"), (1e15, "1000000000000000.0"), (1e-7, "1e-07"),
                                         (0.0001, "0.0001"), (0.1, "0.1"), (1.2345678901234568e17, "1.2345678901234568e+17"),
                                         (5e-324, "5e-324"), (-2.5, "-2.5"), (.infinity, "inf"), (.nan, "nan")]
        for (d, expected) in cases { XCTAssertEqual(PyJSON.repr(d), expected) }
    }

    func testSettingTextLikeSetSetting() throws {
        func text(_ json: String) throws -> String { LocalSettings.text(of: try PyJSON.parse(json)) }
        XCTAssertEqual(try text("4"), "4")
        XCTAssertEqual(try text("4.0"), "4.0")
        XCTAssertEqual(try text("true"), "1")
        XCTAssertEqual(try text("false"), "0")
        XCTAssertEqual(try text("null"), "None")
        XCTAssertEqual(try text(#""Ä b""#), "Ä b")
        XCTAssertEqual(try text("[true]"), "[true]")
    }

    func testRejectsWhatPythonRejects() {
        for bad in ["", "01", "[1,]", "{\"a\" 1}", "tru", "\"a", "1 2", "[1.]", "-", "\"\u{01}\""] {
            XCTAssertThrowsError(try PyJSON.parse(bad), bad)
        }
    }

    func testPythonNumberConversions() {
        XCTAssertEqual(PyConvert.int(" 25 "), 25)
        XCTAssertEqual(PyConvert.int("+7"), 7)
        XCTAssertEqual(PyConvert.int("-1_000"), -1000)
        for bad in ["30.0", "x", "", "1__0", "_1", "1_", "0x10", "٣"] { XCTAssertNil(PyConvert.int(bad), bad) }
        XCTAssertEqual(PyConvert.float("1_0"), 10)
        XCTAssertEqual(PyConvert.float(" 4.5\n"), 4.5)
        XCTAssertEqual(PyConvert.float("1e3"), 1000)
        XCTAssertEqual(PyConvert.float(".5"), 0.5)
        XCTAssertEqual(PyConvert.float("-Infinity"), -.infinity)
        XCTAssertTrue(PyConvert.float("nan")?.isNaN == true)
        for bad in ["abc", "", "0x1p3", "1__0", "e5", "4,5"] { XCTAssertNil(PyConvert.float(bad), bad) }
    }
}

// MARK: - Einstellungen und Semester gegen app/server.py

final class LocalSettingsTermsTests: XCTestCase {

    /// Dieselbe Folge wie tools/gen-local-backend-fixture.py (SETTINGS_STEPS) auf einer neuen Datenbank
    func testStepsMatchPythonServer() async throws {
        let fx = try fixture("settings-terms.json")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        for (i, step) in (fx["steps"]?.array ?? []).enumerated() {
            let method = step["method"]?.string ?? ""
            let r = await backend.handle(request(method, step))
            let label = "Schritt \(i): \(method) \(step["path"]?.string ?? "") \(step["body"]?.jsonString() ?? "")"
            let expected = step["status"]?.int ?? 0
            XCTAssertEqual(r.status, expected, label + " -> " + String(decoding: r.body, as: UTF8.self))
            if expected == 200 {
                XCTAssertEqual(r.json, step["response"], label)
            } else if expected == 422 {
                // gleicher Fehlertyp wie FastAPI
                XCTAssertEqual(r.json?["detail"]?.array?.first?["type"], step["response"]?["detail"]?.array?.first?["type"], label)
            } else {
                XCTAssertNotNil(r.json?["detail"]?.string, label)
            }
        }
        // in der Tabelle steht exakt derselbe Text wie auf dem PC (str(value), json.dumps, "None")
        let rows = try await backend.context.database.query("SELECT key, value FROM settings ORDER BY key")
            .map { JSONValue.array([$0[0].json ?? .null, $0[1].json ?? .null]) }
        XCTAssertEqual(JSONValue.array(rows), fx["settings_rows"])
    }

    func testDerivedFieldsAndPublicView() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let sResponse = await backend.handle(LocalRequest(method: "GET", path: "/api/settings"))
        let s = try XCTUnwrap(sResponse.json)
        XCTAssertEqual(s["hours_per_day"], 4)
        XCTAssertEqual(s["minutes_per_day"], 240)
        XCTAssertEqual(s["learn_days"], [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(s["auto_plan"], true)
        XCTAssertEqual(s["blocked_times"], [])
        XCTAssertNil(s["lan_pin"], "PIN des PC-Servers nie in der Antwort")
        XCTAssertEqual(s["hand"], "right", "nicht abgeleitete Schluessel kommen als Text")
    }

    func testBrokenValuesFailLikePythonAndRollBack() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        func put(_ body: String) async -> LocalResponse {
            await backend.handle(LocalRequest(method: "PUT", path: "/api/settings", body: Data(body.utf8)))
        }
        for body in [#"{"hours_per_day": "abc"}"#, #"{"hours_per_day": "nan"}"#, #"{"test_default_minutes": "x"}"#,
                     #"{"free_days": "[kaputt"}"#, #"{"free_days": "\"6\""}"#] {
            let r = await put(body)
            XCTAssertEqual(r.status, 500, body)
            XCTAssertNotNil(r.json?["detail"]?.string, body)
        }
        // nichts davon wurde gespeichert (Python: kein commit nach der Ausnahme)
        let sResponse = await backend.handle(LocalRequest(method: "GET", path: "/api/settings"))
        let s = try XCTUnwrap(sResponse.json)
        XCTAssertEqual(s["hours_per_day"], 4)
        XCTAssertEqual(s["free_days"], [6])
        // kaputte Sperrzeiten fallen wie in Python auf [] zurueck
        let blocked = await put(#"{"blocked_times": "kein json"}"#)
        XCTAssertEqual(blocked.json?["blocked_times"], [])
    }

    func testTermsDefaultsAndValidation() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.execute("UPDATE terms SET active=0")
        let none = await backend.handle(LocalRequest(method: "GET", path: "/api/terms"))
        XCTAssertEqual(none.json, LocalTerms.fallback, "ohne aktives Semester feste Werte wie timetable.term")
        let missing = await backend.handle(LocalRequest(method: "PUT", path: "/api/terms", body: Data(#"{"start": "2027-04-01"}"#.utf8)))
        XCTAssertEqual(missing.status, 422)
        let list = await backend.handle(LocalRequest(method: "PUT", path: "/api/terms", body: Data(#"{"start": [1], "end": "x"}"#.utf8)))
        XCTAssertEqual(list.status, 422)
        let ok = await backend.handle(LocalRequest(method: "PUT", path: "/api/terms", body: Data(#"{"name": 0, "start": "2027-04-01", "end": "2027-09-30"}"#.utf8)))
        XCTAssertEqual(ok.json?["name"], "Semester", "falscher Name wie Python: `or \"Semester\"`")
        XCTAssertEqual(ok.json?["active"], 1)
        let count = try await backend.context.database.scalar("SELECT COUNT(*) FROM terms WHERE active=1")?.int
        XCTAssertEqual(count, 1)
    }
}

// MARK: - Alle Pfade der App

final class LocalBackendCoverageTests: XCTestCase {

    /// Form wie shape() in tools/gen-local-backend-fixture.py
    private func shape(_ v: JSONValue) -> JSONValue {
        switch v {
        case .null: return ["type": "null"]
        case .bool: return ["type": "bool"]
        case .number: return ["type": "number"]
        case .string: return ["type": "string"]
        case .array(let a): return ["type": "array", "item": a.first.map(shape) ?? .null]
        case .object(let o): return ["type": "object", "keys": .object(o.mapValues(shape))]
        }
    }

    /// Gleiche Form: gleicher Typ, gleiche Schluessel; Listen nur, wenn beide Eintraege haben.
    private func compare(_ local: JSONValue, _ python: JSONValue, _ path: String, _ problems: inout [String]) {
        let lt = local["type"]?.string ?? "", pt = python["type"]?.string ?? ""
        guard lt == pt else { problems.append("\(path): \(lt) statt \(pt)"); return }
        if lt == "object" {
            let lk = local["keys"]?.object ?? [:], pk = python["keys"]?.object ?? [:]
            if Set(lk.keys) != Set(pk.keys) {
                problems.append("\(path): Schlüssel \(lk.keys.sorted()) statt \(pk.keys.sorted())")
                return
            }
            for k in lk.keys.sorted() { compare(lk[k]!, pk[k]!, path + "." + k, &problems) }
        }
        if lt == "array", let li = local["item"], let pi = python["item"], !li.isNull, !pi.isNull {
            compare(li, pi, path + "[0]", &problems)
        }
    }

    func testEveryAppPathGetsAValidAnswer() async throws {
        let fx = try fixture("app-paths.json")
        let paths = fx["paths"]?.array ?? []
        XCTAssertEqual(paths.count, fx["count"]?.int)
        XCTAssertGreaterThanOrEqual(paths.count, 70, "Liste aus dem grep ueber apps/apple/UniFlow")
        var problems: [String] = []
        var placeholders = 0
        for p in paths {
            let method = p["method"]?.string ?? ""
            let req = request(method, p["request"] ?? .null)
            let label = "\(method) \(p["shape"]?.string ?? "")"
            // jede Anfrage auf einer neuen, leeren Datenbank (wie der Generator)
            let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
            // ein Endpunkt fuer genau diese Form ist registriert (kein 404 mangels Pfad)
            guard let route = backend.route(method: method, path: req.path) else {
                problems.append("\(label): kein Endpunkt"); continue
            }
            if route.pattern.shape != p["shape"]?.string { problems.append("\(label): beantwortet von \(route.pattern)") }
            if route.placeholder { placeholders += 1 }
            let r = await backend.handle(req)
            let expect = p["expect"] ?? .null
            let status = expect["status"]?.int ?? 0
            guard let body = r.json else { problems.append("\(label): keine JSON-Antwort"); continue }
            if r.status != status {
                problems.append("\(label): Status \(r.status) statt \(status) – \(String(decoding: r.body.prefix(200), as: UTF8.self))")
                continue
            }
            XCTAssertNotEqual(r.status, 501, label)
            if r.isSuccess {
                if let py = p["python"], (py["status"]?.int).map({ (200..<300).contains($0) }) == true, let pyShape = py["shape"] {
                    compare(shape(body), pyShape, label, &problems)
                }
                if let type = expect["type"]?.string, shape(body)["type"]?.string != type { problems.append("\(label): Typ statt \(type)") }
                if let keys = expect["keys"]?.array?.compactMap(\.string), Set(body.object?.keys.map { $0 } ?? []) != Set(keys) {
                    problems.append("\(label): Schlüssel \(body.object?.keys.sorted() ?? [])")
                }
            } else {
                // Fehler wie FastAPI: {"detail": ...} mit verstaendlichem Text
                if body["detail"]?.string?.isEmpty != false { problems.append("\(label): Fehler ohne Meldung") }
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        XCTAssertGreaterThan(placeholders, 40, "die meisten Pfade sind bis zur Portierung Platzhalter")
    }

    func testSettingsAndTermsAreRealEndpoints() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        for (m, p) in [("GET", "/api/settings"), ("PUT", "/api/settings"), ("GET", "/api/terms"), ("PUT", "/api/terms")] {
            let route = try XCTUnwrap(backend.route(method: m, path: p))
            XCTAssertFalse(route.placeholder, "\(m) \(p)")
        }
    }

    func testPlaceholdersUseClockAndSettings() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        _ = await backend.handle(LocalRequest(method: "PUT", path: "/api/settings",
                                              body: Data(#"{"free_days": [5, 6], "blocked_times": [{"weekday": 0, "start": "12:00", "end": "13:00"}]}"#.utf8)))
        // Sonntag, 25.10.2026: Woche ab Montag, 19.10.
        let dResponse = await backend.handle(LocalRequest(method: "GET", path: "/api/dashboard"))
        let d = try XCTUnwrap(dResponse.json)
        XCTAssertEqual(d["today"]?["date"], "2026-10-25")
        XCTAssertEqual(d["today"]?["weekday"], 6)
        XCTAssertEqual(d["today"]?["status"], "frei")
        XCTAssertEqual(d["week"]?["start"], "2026-10-19")
        XCTAssertEqual(d["week"]?["days"]?.array?.map { $0["status"]?.string ?? "" }, ["leer", "leer", "leer", "leer", "leer", "frei", "frei"])
        XCTAssertNil(d["settings"]?["lan_pin"])
        let calResponse = await backend.handle(LocalRequest(method: "GET", path: "/api/calendar",
                                                                  query: [.init("start", "2026-10-30"), .init("end", "2026-11-02")]))
        let cal = try XCTUnwrap(calResponse.json)
        XCTAssertEqual(cal["days"]?.array?.map { $0["date"]?.string ?? "" }, ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(cal["days"]?.array?.map { $0["weekday"]?.int ?? -1 }, [4, 5, 6, 0])
        let bad = await backend.handle(LocalRequest(method: "GET", path: "/api/calendar", query: [.init("start", "morgen"), .init("end", "x")]))
        XCTAssertEqual(bad.status, 422)
        let weekResponse = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/week", query: [.init("start", "2026-10-26")]))
        let week = try XCTUnwrap(weekResponse.json)
        XCTAssertEqual(week["days"]?.array?.first?["blocked"]?.array?.count, 1, "Sperrzeit am Montag")
        XCTAssertEqual(week["days"]?.array?[1]["blocked"], [])
        XCTAssertEqual(week["term"]?["name"], "WiSe 2026/27")
        // Machbarkeit wie study.feasibility ohne Module: 4 Wochen x 5 Lerntage x 240 min
        let fResponse = await backend.handle(LocalRequest(method: "GET", path: "/api/calendar/feasibility"))
        let f = try XCTUnwrap(fResponse.json)
        XCTAssertEqual(f["available_minutes_4w"], 4800)
        XCTAssertEqual(f["per_day_need"], 300)
        XCTAssertEqual(f["open_minutes"], 0)
        XCTAssertNotNil(f["hint"]?.string, "300 > 240 Minuten")
    }
}
