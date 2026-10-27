import Foundation
import XCTest
@testable import UniFlowCore

// Demo-Inhalte fuer die App-Pruefung (DemoContent, GET/POST /api/demo) gegen die Python-Referenz app/demo.py:
// fixtures/demo/demo.json (tools/gen-demo-fixture.py) mit PDF-Bytes, Konstanten, Anfragen mit Tabellen und Dateien an
// Merkpunkten und der Datumslogik an mehreren Tagen. Dazu, was das Geraet mehr entfernt als Python, und dass die Demo in
// Bibliothek, Stundenplan, Lernkalender, Fristen, Ankuendigungen und Uebersicht erscheint.

private func demoFixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/demo/demo.json")))
}

final class DemoContentTests: XCTestCase {
    /// Datenordner wie in der App (nicht leer: Pfade in der Datenbank relativ zum Container mit diesem Anfang)
    private let dataDirectory = "Library/Application Support/UniFlow"
    private var container: URL!

    override func setUp() async throws {
        try await super.setUp()
        container = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container)
        try await super.tearDown()
    }

    private var files: LocalFiles { LocalFiles(container: container, dataDirectory: dataDirectory) }
    private var dataRoot: URL { container.appendingPathComponent(dataDirectory, isDirectory: true) }

    private func backend(_ now: String, seed: [JSONValue] = [], withFiles: Bool = true) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: now)!, files: withFiles ? files : nil)
        try await run(b, seed)
        return b
    }

    private func run(_ b: LocalBackend, _ statements: [JSONValue]) async throws {
        try await b.context.database.transaction { c in
            for s in statements { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
        }
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ raw: String? = nil) async -> LocalResponse {
        let url = URL(string: "uniflow-local://device" + path)!
        return await b.handle(LocalRequest(method: method, url: url, headers: raw == nil ? [:] : ["Content-Type": "application/json"],
                                           body: raw.map { Data($0.utf8) }))
    }

    private func value(_ b: LocalBackend, _ path: String, method: String = "GET", _ raw: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let r = await call(b, method, path, raw)
        XCTAssertEqual(r.status, 200, "\(method) \(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))", file: file, line: line)
        return try XCTUnwrap(r.json, file: file, line: line)
    }

    // MARK: Paritaet mit app/demo.py

    func testPDFBytesMatchPython() throws {
        let fx = try demoFixture()
        let pdfs = fx["pdfs"] ?? .null
        let expected = pdfs["files"]?.array ?? []
        XCTAssertEqual(expected.map { $0["id"]?.string ?? "" }, DemoContent.fileIDs)
        for (f, e) in zip(DemoContent.files, expected) {
            let data = DemoContent.pdf(f)
            XCTAssertEqual(data, Data(base64Encoded: e["base64"]?.string ?? ""), "\(f.id): Bytes wie demo.pdf_bytes")
            XCTAssertEqual(SolutionSHA256.hex(data), e["sha256"]?.string, f.id)
            XCTAssertEqual(data.count, e["size"]?.int, f.id)
            XCTAssertEqual(f.pages.count, e["page_count"]?.int, f.id)
        }
        // Grenzfaelle: Klammern, Rueckstrich, Umlaute, cp1252-Sonderzeichen, nicht darstellbare Zeichen ("?"), zerlegte Umlaute
        let cases = pdfs["cases"]?.array ?? []
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let pages = (c["pages"]?.array ?? []).map { p in
                DemoContent.Page(p.array?.first?.string ?? "", p.array?.last?.array?.compactMap(\.string) ?? [])
            }
            XCTAssertEqual(DemoContent.pdf(pages), Data(base64Encoded: c["base64"]?.string ?? ""), "\(pages.map(\.title))")
        }
        XCTAssertEqual(DemoContent.cp1252("€„“–…•"), [0x80, 0x84, 0x93, 0x96, 0x85, 0x95])
        XCTAssertEqual(DemoContent.cp1252("Ω😀\u{81}a\u{308}"), [0x3F, 0x3F, 0x3F, 0x61, 0x3F], "replace wie Python, je Zeichen")
        XCTAssertEqual(DemoContent.escape("a(b)\\c"), Array("a\\(b\\)\\\\c".utf8))
    }

    func testConstantsMatchPython() throws {
        let k = try demoFixture()["constants"] ?? .null
        XCTAssertEqual(k["module"]?.string, DemoContent.moduleName)
        XCTAssertEqual(k["subject"]?.string, DemoContent.subject)
        XCTAssertEqual(k["color"]?.string, DemoContent.color)
        XCTAssertEqual(k["courses"]?.array?.map { [$0["id"]?.string, $0["title"]?.string, $0["kind"]?.string, $0["number"]?.string] },
                       DemoContent.courses.map { [$0.id, $0.title, $0.kind, $0.number] })
        XCTAssertEqual(k["events"]?.array?.map { e -> [String?] in
            [e["course_id"]?.string, e["title"]?.string, e["kind"]?.string, e["weekday"]?.int.map(String.init), e["start_time"]?.string,
             e["end_time"]?.string, e["room"]?.string, e["lecturer"]?.string]
        }, DemoContent.events.map { [$0.courseID, $0.title, $0.kind, String($0.weekday), $0.start, $0.end, $0.room, $0.lecturer] })
        let fx = k["files"]?.array ?? []
        XCTAssertEqual(fx.map { $0["id"]?.string ?? "" }, DemoContent.files.map(\.id))
        XCTAssertEqual(fx.map { $0["course_id"]?.string ?? "" }, DemoContent.files.map(\.courseID))
        XCTAssertEqual(fx.map { $0["name"]?.string ?? "" }, DemoContent.files.map(\.name))
        for (e, f) in zip(fx, DemoContent.files) {
            let pages = (e["pages"]?.array ?? []).map { DemoContent.Page($0.array?.first?.string ?? "", $0.array?.last?.array?.compactMap(\.string) ?? []) }
            XCTAssertEqual(pages, f.pages, f.id)
        }
    }

    /// Tabellen wie TABLES im Generator; local_path relativ zum Datenordner
    private func tables(_ b: LocalBackend) async throws -> [String: JSONValue] {
        let queries: [(String, String)] = [
            ("modules", "SELECT * FROM modules ORDER BY id"), ("courses", "SELECT * FROM courses ORDER BY id"),
            ("files", "SELECT * FROM files ORDER BY id"), ("analysis", "SELECT * FROM analysis ORDER BY file_id"),
            ("annotations", "SELECT * FROM annotations ORDER BY file_id"), ("annotation_versions", "SELECT * FROM annotation_versions ORDER BY id"),
            ("flashcards", "SELECT * FROM flashcards ORDER BY id"), ("course_events", "SELECT * FROM course_events ORDER BY id"),
            ("event_exceptions", "SELECT * FROM event_exceptions ORDER BY id"), ("event_notes", "SELECT * FROM event_notes ORDER BY event_id"),
            ("study_packages", "SELECT * FROM study_packages ORDER BY id"), ("study_tasks", "SELECT * FROM study_tasks ORDER BY id"),
            ("deadlines", "SELECT * FROM deadlines ORDER BY id"), ("announcements", "SELECT * FROM announcements ORDER BY id"),
            ("page_texts", "SELECT file_id, page, text FROM page_texts ORDER BY file_id, page"), ("settings", "SELECT key, value FROM settings ORDER BY key"),
        ]
        let prefix = dataDirectory + "/"
        return try await b.context.database.withConnection { c in
            var out: [String: JSONValue] = [:]
            for (name, sql) in queries {
                out[name] = .array(try c.rows(sql).map { r in
                    var r = r
                    if let p = r["local_path"]?.string, p.hasPrefix(prefix) { r["local_path"] = .string(String(p.dropFirst(prefix.count))) }
                    return .object(r)
                })
            }
            return out
        }
    }

    /// Dateien unter <Datenordner>/files wie files_on_disk im Generator
    private func filesOnDisk() -> (files: [JSONValue], dirs: [String]) {
        let root = dataRoot.appendingPathComponent("files", isDirectory: true)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return ([], []) }
        var files: [JSONValue] = [], dirs: [String] = []
        let base = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for case let u as URL in e {
            let rel = String(u.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.count))
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                dirs.append(rel)
            } else if let d = try? Data(contentsOf: u) {
                files.append(["path": .string(rel), "size": .number(Double(d.count)), "sha256": .string(SolutionSHA256.hex(d))])
            }
        }
        return (files.sorted { ($0["path"]?.string ?? "") < ($1["path"]?.string ?? "") }, dirs.sorted())
    }

    /// Tabellen vergleichen; `deviceRemovesMore`: Zeilen zu Demo-Dateien, die das Geraet beim Entfernen mitnimmt und
    /// Python stehen laesst (Notiz-Versionen), fallen auf der Python-Seite weg
    private func compareTables(_ local: [String: JSONValue], _ python: JSONValue, deviceRemovesMore: Bool, _ label: String, _ problems: inout [String]) {
        for (name, rowsValue) in python.object ?? [:] {
            var expected = rowsValue.array ?? []
            if deviceRemovesMore, ["annotation_versions", "flashcards"].contains(name) {
                expected.removeAll { ($0["file_id"]?.string ?? "").lowercased().hasPrefix("demo-") }
            }
            let got = local[name]?.array ?? []
            if got != expected {
                let diff = zip(got, expected).first { $0 != $1 }.map { "\n  lokal  \($0.0.jsonString(sortedKeys: true))\n  Python \($0.1.jsonString(sortedKeys: true))" }
                problems.append("\(label): Tabelle \(name) \(got.count) statt \(expected.count) Zeilen\(diff ?? "")")
            }
        }
    }

    func testScenariosMatchPythonServer() async throws {
        let fx = try demoFixture()
        let scenarios = fx["scenarios"]?.array ?? []
        XCTAssertEqual(scenarios.map { $0["name"]?.string ?? "" }, ["leer", "eigene-daten"])
        var problems: [String] = []
        var checked = 0, marks = 0
        for sc in scenarios {
            let name = sc["name"]?.string ?? ""
            try? FileManager.default.removeItem(at: dataRoot)
            let b = try await backend(sc["now"]?.string ?? "", seed: sc["seed"]?.array ?? [])
            var removedOnce = false
            let steps = sc["steps"]?.array ?? []
            for (i, step) in steps.enumerated() {
                if step["sql"] != nil {
                    try await run(b, fx["touch_demo"]?.array ?? [])
                } else {
                    let method = step["method"]?.string ?? "", path = step["path"]?.string ?? "", raw = step["raw"]?.string
                    let label = "\(name) \(i): \(method) \(path) \(raw ?? "")"
                    let r = await call(b, method, path, raw)
                    let status = step["status"]?.int ?? 0
                    if r.status != status {
                        problems.append("\(label): Status \(r.status) statt \(status) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                    } else if let local = r.json {
                        checked += 1
                        let expected = step["response"] ?? .null
                        if status == 422 {
                            // Art des Fehlers wie FastAPI; die Stelle im kaputten JSON nennt nur Python
                            let a = local["detail"]?.array?.first, e = expected["detail"]?.array?.first
                            if a?["type"] != e?["type"] || (e?["type"] != "json_invalid" && (a?["loc"] != e?["loc"] || a?["input"] != e?["input"])) {
                                problems.append("\(label): 422 \(local) statt \(expected)")
                            }
                        } else if local != expected {
                            problems.append("\(label):\n  lokal  \(local.jsonString(sortedKeys: true))\n  Python \(expected.jsonString(sortedKeys: true))")
                        }
                        if method == "POST", status == 200, local["removed"] != nil, (local["removed"]?["files"]?.int ?? 0) > 0 { removedOnce = true }
                    } else {
                        problems.append("\(label): keine JSON-Antwort")
                    }
                }
                for (mark, m) in sc["marks"]?.object ?? [:] where m["after_step"]?.int == i {
                    marks += 1
                    compareTables(try await tables(b), m["tables"] ?? .null, deviceRemovesMore: removedOnce, "\(name) \(mark)", &problems)
                    let disk = filesOnDisk()
                    if disk.files != (m["files"]?.array ?? []) { problems.append("\(name) \(mark): Dateien \(disk.files) statt \(m["files"] ?? .null)") }
                    if disk.dirs != (m["dirs"]?.array?.compactMap(\.string) ?? []) { problems.append("\(name) \(mark): Ordner \(disk.dirs) statt \(m["dirs"] ?? .null)") }
                }
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(checked, 30, "alle Anfragen verglichen")
        XCTAssertEqual(marks, 10, "Merkpunkte mit Tabellen und Dateien")
    }

    /// "Diese Woche" relativ zur Uhr: Montag, Sonntag, Jahreswechsel, Schaltjahr, Zeitumstellung beim Aenderungsdatum
    func testDatesThisWeekMatchPython() async throws {
        let cases = try demoFixture()["dates"]?.array ?? []
        XCTAssertEqual(cases.count, 6)
        var problems: [String] = []
        for c in cases {
            let now = c["now"]?.string ?? ""
            try? FileManager.default.removeItem(at: dataRoot)
            let b = try await backend(now)
            _ = try await value(b, "/api/demo", method: "POST", #"{"enabled": true}"#)
            let t = try await tables(b)
            func pick(_ table: String, _ keys: [String]) -> [JSONValue] {
                (t[table]?.array ?? []).map { r in .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, r[$0] ?? .null) })) }
            }
            let got: [String: [JSONValue]] = [
                "study_packages": pick("study_packages", ["date", "title", "planned_minutes", "sort"]),
                "deadlines": pick("deadlines", ["id", "due_at"]),
                "announcements": pick("announcements", ["id", "text", "dates", "posted_at"]),
                "files": pick("files", ["id", "chdate", "first_seen"]),
            ]
            for (k, v) in got where .array(v) != (c[k] ?? .null) {
                problems.append("\(now) \(k):\n  lokal  \(JSONValue.array(v).jsonString(sortedKeys: true))\n  Python \((c[k] ?? .null).jsonString(sortedKeys: true))")
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        // Gegenprobe: die Faelle decken Sonntag (Woche ab Montag davor), Jahreswechsel und Schaltjahr wirklich ab
        let sunday = try XCTUnwrap(cases.first { $0["now"]?.string?.hasPrefix("2026-11-01") == true })
        XCTAssertEqual(sunday["study_packages"]?.array?.first?["date"], "2026-10-26")
        let year = try XCTUnwrap(cases.first { $0["now"]?.string?.hasPrefix("2026-12-31") == true })
        XCTAssertEqual(year["deadlines"]?.array?.first?["due_at"], "2027-01-06T13:45")
        let leap = try XCTUnwrap(cases.first { $0["now"]?.string?.hasPrefix("2028-02-29") == true })
        XCTAssertEqual(leap["announcements"]?.array?.first?["text"]?.string?.contains("06.03."), true)
    }

    // MARK: Was die Demo zeigt (wie tests/test_demo.py)

    func testDemoIsVisibleInPagesAndRemovesCleanly() async throws {
        let b = try await backend("2026-10-28T09:30:00")
        var d = try await value(b, "/api/demo")
        XCTAssertEqual(d["enabled"], false)
        d = try await value(b, "/api/demo", method: "POST", #"{"enabled": true}"#)
        XCTAssertEqual([d["files"], d["events"], d["packages"]], [3, 3, 3])
        // Bibliothek: drei PDFs im Demo-Modul, Inhalt vom Geraet, Fingerabdruck gesetzt
        let lib = try await value(b, "/api/library")
        let demoFiles = (lib["files"]?.array ?? []).filter { ($0["id"]?.string ?? "").hasPrefix("demo-") }
        XCTAssertEqual(demoFiles.count, 3)
        XCTAssertTrue(demoFiles.allSatisfy { $0["kind"] == "pdf" && $0["module_id"] != nil && $0["subject"] == "Demo Informatik" }, "\(demoFiles)")
        let hashes = try await b.context.database.withConnection { c in try c.query("SELECT content_sha256 FROM files WHERE id LIKE 'demo-%' ORDER BY id").compactMap { $0[0].string } }
        XCTAssertEqual(hashes, DemoContent.files.sorted { $0.id < $1.id }.map { SolutionSHA256.hex(DemoContent.pdf($0)) })
        XCTAssertTrue((lib["modules"]?.array ?? []).contains { $0["name"]?.string == DemoContent.moduleName })
        let pdf = await call(b, "GET", "/api/files/demo-skript/content")
        XCTAssertEqual(pdf.status, 200)
        XCTAssertEqual(pdf.body, DemoContent.pdf(DemoContent.files[0]))
        XCTAssertTrue(pdf.body.starts(with: Data("%PDF".utf8)))
        // Stundenplan, Lernkalender, Fristen, Ankuendigungen, Uebersicht
        let week = try await value(b, "/api/timetable/week?start=2026-10-26")
        let titles = week.jsonString()
        XCTAssertTrue(titles.contains("Grundlagen der Informatik – Vorlesung") && titles.contains("Grundlagen der Informatik – Übung"))
        let cal = try await value(b, "/api/calendar?start=2026-10-26&end=2026-11-08").jsonString()
        XCTAssertTrue(cal.contains("Übungsblatt 1") && cal.contains("Folien Woche 1"), "Lernpakete dieser Woche im Kalender")
        let dl = try await value(b, "/api/deadlines")
        XCTAssertTrue((dl["deadlines"]?.array ?? []).contains { $0["deadline_id"] == "demo-abgabe-1" && $0["kind"] == "abgabe" }, "\(dl)")
        let an = try await value(b, "/api/announcements")
        XCTAssertTrue(an.jsonString().contains("Raumwechsel"))
        let dash = try await value(b, "/api/dashboard")
        XCTAssertEqual(dash["today"]?["packages"]?.array?.first?["title"], "Übungsblatt 1", "Mittwoch: Paket des Tages")
        XCTAssertTrue((dash["announcements"]?.array ?? []).contains { $0["id"] == "demo-ankuendigung-1" })
        let modules = try await value(b, "/api/modules")
        XCTAssertTrue((modules.array ?? []).contains { $0["name"]?.string == DemoContent.moduleName })
        // entfernen: nichts bleibt, auch nicht auf der Platte
        d = try await value(b, "/api/demo", method: "POST", #"{"enabled": false}"#)
        XCTAssertEqual(d["enabled"], false)
        XCTAssertEqual(d["removed"]?["files"], 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(DemoContent.folder).path), "Ordner Demo weg")
        let after = try await value(b, "/api/library")
        XCTAssertFalse((after["files"]?.array ?? []).contains { ($0["id"]?.string ?? "").hasPrefix("demo-") })
        XCTAssertFalse((after["modules"]?.array ?? []).contains { $0["name"]?.string == DemoContent.moduleName })
        let weekAfter = try await value(b, "/api/timetable/week?start=2026-10-26")
        XCTAssertFalse(weekAfter.jsonString().contains("Grundlagen der Informatik"))
        let gone = await call(b, "GET", "/api/files/demo-skript/content")
        XCTAssertEqual(gone.status, 404)
    }

    // MARK: Entfernen auf dem Geraet: mehr als Python, eigene Daten bleiben

    func testRemoveTakesEverythingOfTheDemoAndKeepsOwnData() async throws {
        let b = try await backend("2026-10-28T09:30:00")
        // eigene Daten: Dokument auf der Platte, Modul mit eigenem Kurs, Karteikarte, Termin, Ordner, erkannte Abgabe
        let own = try files.write(Data("%PDF-1.4 eigen".utf8), to: files.ownDocumentsDirectory + "/Mein Blatt.pdf")
        let ownStored = files.stored(own) ?? ""
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Eigenes Modul', '#2563eb', 1, '2026-10-01T09:00:00')")
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, created_at, module_id) VALUES ('k-own', 'Eigener Kurs', 'Eigenes Modul', 'vorlesung', 1, '2026-10-01T09:00:00', 1)")
            try c.execute("INSERT INTO files(id, course_id, name, local_path, status, kind, first_seen) VALUES ('f-own', 'k-own', 'Mein Blatt.pdf', ?, 'neu', 'pdf', '2026-10-01T09:00:00')",
                          [.text(ownStored)])
            try c.execute("INSERT INTO flashcards(file_id, question, answer, created_at) VALUES ('f-own', 'Eigene Frage', 'Antwort', '2026-10-01T09:00:00')")
            try c.execute("INSERT INTO settings(key, value) VALUES ('user_name', 'Testperson') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        }
        _ = try await value(b, "/api/demo", method: "POST", #"{"enabled": true}"#)
        // Spuren an der Demo, die Python stehen laesst bzw. die es nur auf dem Geraet gibt
        let assets = try files.write(Data([1, 2, 3]), to: files.assetsDirectory(fileID: "demo-skript") + "/bild.png")
        try await b.context.database.transaction { c in
            let demoModule = try XCTUnwrap(try c.scalar("SELECT id FROM modules WHERE name=?", [.text(DemoContent.moduleName)])?.int64)
            try c.execute("UPDATE modules SET name='Umbenannt' WHERE id=?", [.integer(demoModule)])     // umbenannt: bleibt erkennbar
            try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES ('demo-skript', 1, '{}', '2026-10-28T10:00:00')")
            try c.execute("INSERT INTO flashcards(file_id, question, answer, created_at) VALUES ('demo-blatt', 'Demo-Frage', 'Antwort', '2026-10-28T10:00:00')")
            try c.execute("INSERT INTO recordings(file_id, page, title, url, created_at) VALUES ('demo-folien', 1, 'Aufnahme', 'x', '2026-10-28T10:00:00')")
            try c.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, at) SELECT id, package_id, 'geplant', 'erledigt', '2026-10-28T10:00:00' FROM study_tasks WHERE file_id='demo-blatt'")
            try c.execute("INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, source, created_at) VALUES (?, 'Eigene Lerngruppe', 'persoenlich', 4, '16:00', '17:00', 'manual', '2026-10-28T10:00:00')",
                          [.integer(demoModule)])
            try c.execute("INSERT INTO folders(name, module_id, created_at) VALUES ('Eigener Ordner', ?, '2026-10-28T10:00:00')", [.integer(demoModule)])
            try FileVersions.ensureTable(c)
            try c.execute("INSERT INTO file_versions(file_id, version, name) VALUES ('demo-skript', 1, 'alt.pdf')")
            try DueStore.ensureTables(c)
            try c.execute("INSERT INTO due_hits(source, file_id, course_id, date, kind, label) VALUES ('dokument', 'demo-blatt', 'demo-uebung', '2026-11-04', 'abgabe', 'Abgabe')")
            try c.execute("INSERT INTO due_hits(source, announcement_id, course_id, date, kind, label) VALUES ('ankuendigung', 'demo-ankuendigung-1', 'demo-vorlesung', '2026-11-02', 'sonstiges', 'Raum')")
            try c.execute("INSERT INTO due_hits(source, file_id, course_id, date, kind, label) VALUES ('dokument', 'f-own', 'k-own', '2026-11-05', 'abgabe', 'Eigene Abgabe')")
            try c.execute("INSERT INTO due_choices(key, hidden, updated_at) VALUES ('demo-uebung|2026-11-04|abgabe', 1, '2026-10-28T10:00:00')")
            try c.execute("INSERT INTO due_choices(key, hidden, updated_at) VALUES ('k-own|2026-11-05|abgabe', 1, '2026-10-28T10:00:00')")
        }
        let d = try await value(b, "/api/demo", method: "POST", #"{"enabled": false}"#)
        XCTAssertEqual(d["removed"], ["files": 3, "events": 3, "packages": 3], "umbenanntes Demo-Modul gefunden")
        try await b.context.database.withConnection { c in
            for sql in ["SELECT COUNT(*) FROM files WHERE id LIKE 'demo-%'", "SELECT COUNT(*) FROM courses WHERE id LIKE 'demo-%'",
                        "SELECT COUNT(*) FROM course_events WHERE source='demo'", "SELECT COUNT(*) FROM deadlines WHERE source='demo'",
                        "SELECT COUNT(*) FROM announcements WHERE source='demo'", "SELECT COUNT(*) FROM modules WHERE name='Umbenannt'",
                        "SELECT COUNT(*) FROM study_tasks WHERE file_id LIKE 'demo-%'", "SELECT COUNT(*) FROM study_packages",
                        "SELECT COUNT(*) FROM task_history", "SELECT COUNT(*) FROM annotation_versions WHERE file_id LIKE 'demo-%'",
                        "SELECT COUNT(*) FROM flashcards WHERE file_id LIKE 'demo-%'", "SELECT COUNT(*) FROM recordings",
                        "SELECT COUNT(*) FROM file_versions", "SELECT COUNT(*) FROM due_hits WHERE course_id LIKE 'demo-%'",
                        "SELECT COUNT(*) FROM due_choices WHERE key LIKE 'demo-%'", "SELECT COUNT(*) FROM event_exceptions",
                        "SELECT COUNT(*) FROM event_notes"] {
                XCTAssertEqual(try c.scalar(sql)?.int, 0, sql)
            }
            // eigene Daten unveraendert
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM files WHERE id='f-own'")?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT name FROM modules WHERE id=1")?.string, "Eigenes Modul")
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM flashcards WHERE file_id='f-own'")?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM due_hits WHERE file_id='f-own'")?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM due_choices WHERE key LIKE 'k-own|%'")?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='user_name'")?.string, "Testperson")
            // eigener Termin und Ordner im Demo-Modul: bleiben, ohne Modul
            XCTAssertEqual(try c.query("SELECT title, module_id FROM course_events").map { [$0["title"]?.string ?? "", $0["module_id"]?.isNull == true ? "-" : "?"] },
                           [["Eigene Lerngruppe", "-"]])
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM folders WHERE name='Eigener Ordner' AND module_id IS NULL")?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='demo_content'")?.string, "0")
            XCTAssertFalse(try DemoContent.isEnabled(c))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path), "eigenes Dokument auf der Platte bleibt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.deletingLastPathComponent().path), "Bilder der Notizen zur Demo-Datei weg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(DemoContent.folder).path))
    }

    /// Ein Modul mit einem eigenen Kurs des Nutzers bleibt, auch wenn es wie die Demo heisst; nur die Demo-Teile gehen
    func testModuleWithOwnCourseStays() async throws {
        let b = try await backend("2026-10-28T09:30:00")
        _ = try await value(b, "/api/demo", method: "POST", #"{"enabled": true}"#)
        try await b.context.database.transaction { c in
            let m = try XCTUnwrap(try c.scalar("SELECT id FROM modules WHERE name=?", [.text(DemoContent.moduleName)])?.int64)
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, created_at, module_id) VALUES ('k-own', 'Eigener Kurs', 'Info', 'uebung', 1, '2026-10-01T09:00:00', ?)",
                          [.integer(m)])
        }
        let d = try await value(b, "/api/demo", method: "POST", #"{"enabled": false}"#)
        XCTAssertEqual(d["removed"]?["files"], 3)
        XCTAssertEqual(d["removed"]?["packages"], 0, "Pakete des Moduls bleiben mit dem Modul")
        try await b.context.database.withConnection { c in
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM modules WHERE name=?", [.text(DemoContent.moduleName)])?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM courses WHERE id='k-own' AND module_id IS NOT NULL")?.int, 1)
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM study_tasks WHERE file_id LIKE 'demo-%'")?.int, 0, "Aufgaben zu Demo-Dateien gehen trotzdem")
            XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM files WHERE id LIKE 'demo-%'")?.int, 0)
        }
    }

    // MARK: Grenzen

    func testWithoutFileStorageInstallIs503AndRemoveWorks() async throws {
        let b = try await backend("2026-10-28T09:30:00", withFiles: false)
        let r = await call(b, "POST", "/api/demo", #"{"enabled": true}"#)
        XCTAssertEqual(r.status, 503)
        XCTAssertFalse((r.json?["detail"]?.string ?? "").isEmpty)
        let off = try await value(b, "/api/demo", method: "POST", #"{"enabled": false}"#)
        XCTAssertEqual(off["removed"], ["files": 0, "events": 0, "packages": 0])
        let route = try XCTUnwrap(b.route(method: "POST", path: "/api/demo"))
        XCTAssertFalse(route.placeholder)
        XCTAssertEqual(route.module, DemoEndpoints.name)
    }

    func testSwitchReadsOnlyTheSettingLikePython() async throws {
        let b = try await backend("2026-10-28T09:30:00")
        for (raw, on) in [("'1'", true), ("'0'", false), ("'1.0'", false), ("1", true), ("1.0", false), ("NULL", false), ("'true'", false)] {
            try await b.context.database.transaction { c in
                try c.execute("INSERT INTO settings(key, value) VALUES ('demo_content', \(raw)) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
            }
            let enabled = try await b.context.database.withConnection { try DemoContent.isEnabled($0) }
            XCTAssertEqual(enabled, on, raw)
            let status = try await value(b, "/api/demo")
            XCTAssertEqual(status["enabled"]?.bool, on, raw)
        }
        // kaputte andere Einstellung: GET /api/demo scheitert wie Python (get_settings), der Schalter selbst bleibt lesbar
        try await b.context.database.transaction { c in try c.execute("UPDATE settings SET value='abc' WHERE key='hours_per_day'") }
        let broken = await call(b, "GET", "/api/demo")
        XCTAssertEqual(broken.status, 500)
        let stillReadable = try await b.context.database.withConnection { try DemoContent.isEnabled($0) }
        XCTAssertFalse(stillReadable)
    }

    func testBackgroundSkipsWhileDemoIsActive() {
        var s = BackgroundSyncSituation(enabled: true, hasContainer: true, switching: false, syncRunning: true, usableSession: true, demo: true)
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .demo, "Demo vor allem, was einen Lauf braeuchte")
        s.switching = true
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .switching)
        s = BackgroundSyncSituation(enabled: true, hasContainer: true, switching: false, syncRunning: false, usableSession: true)
        XCTAssertNil(BackgroundSyncGate.skipReason(s), "ohne Angabe keine Demo")
        XCTAssertEqual(BackgroundSkipReason.demo.text, "Demo-Inhalte aktiv")
        XCTAssertEqual(BackgroundSyncRecord(finishedAt: Date(), kind: .refresh, outcome: .skipped(.demo)).text, "übersprungen: Demo-Inhalte aktiv")
    }
}
