import Foundation
import XCTest
@testable import UniFlowCore

private func repoFile(_ relative: String) throws -> Data {
    // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/LocalModulesTests.swift -> Repository-Wurzel
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent(relative))
}

/// tools/gen-local-backend-fixture.py (study_modules): Ausgaben von app/studip_sync.py und app/study.py
private func studyFixture() throws -> JSONValue {
    try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/local-backend/study-modules.json"))
}

/// Gleiche Codepunkte (Swift vergleicht Zeichenketten sonst kanonisch aequivalent, Python nicht)
private func sameScalars(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return Array(a.unicodeScalars) == Array(b.unicodeScalars)
}

/// Wert aus dem Fixture zum Binden wie Pythons sqlite3
private func sqliteValue(_ v: JSONValue) -> SQLiteValue {
    SQLiteValue(json: v) ?? .null
}

// MARK: - Einordnung ohne KI

final class StudyClassifyTests: XCTestCase {

    /// studip_sync.classify fuer alle Titel aus CLASSIFY_TITLES: gleiches Fach (Codepunkt fuer Codepunkt), gleiche Art
    func testClassifyLikePython() throws {
        let cases = try studyFixture()["classify"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 45)
        var problems: [String] = []
        for c in cases {
            let title = c["title"]?.string ?? ""
            let (subject, kind) = UniRules.classify(title)
            if !sameScalars(subject, c["subject"]?.string) || kind != c["kind"]?.string {
                problems.append("\(title.debugDescription): (\(subject.debugDescription), \(kind)) statt (\(c["subject"]?.string?.debugDescription ?? "-"), \(c["kind"]?.string ?? "-"))")
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testEffectiveTypeLikePython() throws {
        let cases = try studyFixture()["effective_type"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 60)
        var problems: [String] = []
        for c in cases {
            let name = c["name"]?.string, folder = c["folder"]?.string, ai = c["ai_type"]?.string
            let (t, label) = StudyClassify.effectiveType(name: name, folder: folder, aiType: ai)
            if t != c["type"]?.string || label != c["label"]?.string {
                problems.append("\(name.debugDescription) / \(folder.debugDescription) / \(ai.debugDescription): (\(t), \(label)) statt (\(c["type"]?.string ?? "-"), \(c["label"]?.string ?? "-"))")
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testWeekHintLikePython() throws {
        let cases = try studyFixture()["week_hint"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        var problems: [String] = []
        for c in cases {
            let name = c["name"]?.string, folder = c["folder"]?.string
            let hint = StudyClassify.weekHint(name: name, folder: folder)
            if hint != c["hint"]?.int {
                problems.append("\(name.debugDescription) / \(folder.debugDescription): \(hint.map(String.init) ?? "nil") statt \(c["hint"]?.int.map(String.init) ?? "nil")")
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    /// Bedeutung wie Pythons re, unabhaengig vom Fixture festgehalten
    func testRegexMeansWhatPythonMeans() {
        let combining = String(Unicode.Scalar(0x308)!)
        // \b: kombinierende Zeichen sind keine Wortzeichen (Python), ICU zaehlt sie sonst dazu
        XCTAssertTrue(PyRegex(#"\bkk\d"#).found(in: "a" + String(Unicode.Scalar(0x301)!) + "kk1"))
        XCTAssertFalse(PyRegex(#"\bkk\d"#).found(in: "akk1"))
        // \s mit \v und U+001C
        XCTAssertEqual(PyRegex(#"\s+"#).sub("a\u{0B}b\u{1C}c", " "), "a b c")
        // "ß" faltet nicht zu "ss", aber zu "ẞ"
        XCTAssertEqual(UniRules.classify("BEGRÜSSUNG neuer Studierender").kind, "vorlesung")
        XCTAssertEqual(UniRules.classify("Begrüßung der Erstsemester").kind, "sonstiges")
        // "." und "$": nur "\n" beendet eine Zeile
        XCTAssertEqual(PyRegex(#"x.*$"#).sub("ax\rb"), "a")
        XCTAssertEqual(PyRegex(#"\.[a-z]+$"#).sub("a.pdf\n"), "a\n")
        // zerlegter Umlaut passt nicht auf "ü" (Python normalisiert nicht)
        XCTAssertNil(StudyClassify.weekHint(name: "U" + combining + "bung 4.pdf", folder: nil))
        XCTAssertEqual(StudyClassify.weekHint(name: "Übung 4.pdf", folder: nil), 4)
        // re.match nur am Anfang, findall ohne Gruppe
        XCTAssertNil(PyRegex("b").match("ab"))
        XCTAssertEqual(PyRegex("[a-zäöü0-9]+").findAll("mathe i, gds2"), ["mathe", "i", "gds2"])
        // Ziffern anderer Schriften zaehlen wie in Python
        XCTAssertEqual(PyText.int(digits: "\u{663}"), 3)
        XCTAssertEqual(PyText.strip(" \u{3000}\u{1C}x\u{85} "), "x")
        XCTAssertEqual(PyText.strip("(Testlogik) -", chars: " -:,("), "Testlogik)")
    }

    /// `study.file_source` wie tests/test_device_sync_api.py::test_file_source_rule, dazu Codepunkt-Vergleiche
    func testFileSourceLikePython() {
        let learnweb = "https://learnweb.test/webservice/pluginfile.php/7/mod_resource/content/1/Folien.pdf"
        let studip = "https://studip.test/jsonapi.php/v1/file-refs/f1/content"
        XCTAssertEqual(StudyClassify.fileSource(["id": "u1", "course_id": "__user__", "download_url": .string(learnweb)]), "own")
        XCTAssertEqual(StudyClassify.fileSource(["id": "lw-1", "course_id": "c"]), "learnweb")
        XCTAssertEqual(StudyClassify.fileSource(["id": "abc", "course_id": "c", "download_url": .string(learnweb)]), "learnweb")
        XCTAssertEqual(StudyClassify.fileSource(["id": "abc", "course_id": "c", "download_url": .string(studip)]), "studip")
        XCTAssertEqual(StudyClassify.fileSource(["id": "abc", "course_id": "c"]), "studip")
        XCTAssertEqual(StudyClassify.fileSource(["id": "abc", "course_id": .null, "download_url": .null]), "studip")
        // startswith nach Codepunkten: ein angehaengtes Kombinationszeichen aendert in Python nichts
        XCTAssertEqual(StudyClassify.fileSource(["id": "lw-\u{301}1", "course_id": "c"]), "learnweb")
        XCTAssertEqual(StudyClassify.fileSource(["id": "LW-1", "course_id": "c"]), "studip")
        // enrich_file setzt die Herkunft mit
        XCTAssertEqual(StudyClassify.enrichFile(["id": "lw-2", "name": "Folien 1.pdf"])["source"], "learnweb")
    }

    /// str.lower fuer LOWER_CASES: volle Abbildung je Codepunkt, Sigma am Wortende
    func testLowerLikePython() throws {
        let cases = try studyFixture()["lower"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let text = c["text"]?.string ?? ""
            XCTAssertTrue(sameScalars(PyText.lower(text), c["lower"]?.string), "\(text.debugDescription): \(PyText.lower(text).debugDescription)")
        }
    }

    /// re.I: genau die Codepunkte, auf die ein Buchstabe der Muster in Python passt (ganzer Unicode-Bereich)
    func testIgnoreCaseLikePython() throws {
        let cases = try studyFixture()["ignorecase"]?.array ?? []
        XCTAssertEqual(cases.count, PyRegex.caseVariants.count)
        for c in cases {
            let letter = try XCTUnwrap(c["letter"]?.string?.unicodeScalars.first)
            let expected = Set((c["matches"]?.array ?? []).compactMap { $0.int.flatMap(Unicode.Scalar.init) })
            XCTAssertEqual(Set(PyRegex.caseVariants[letter]?.unicodeScalars ?? "".unicodeScalars), expected, "\(letter)")
            let upper = PyRegex(String(letter).uppercased() == "SS" ? "ß" : String(letter).uppercased(), ignoreCase: true)
            for u in expected { XCTAssertTrue(upper.found(in: String(u)), "\(letter) / \(u)") }
        }
        // ICU wuerde voll falten: "ss" ~ "ß", "st" ~ "ﬆ"
        XCTAssertFalse(PyRegex("ß", ignoreCase: true).found(in: "ss"))
        XCTAssertFalse(PyRegex("st", ignoreCase: true).found(in: "\u{FB06}"))
        XCTAssertTrue(PyRegex("Tutorium", ignoreCase: true).found(in: "TUTOR\u{130}UM"))
        XCTAssertTrue(PyRegex(#"\s*\((für [^)]*)\)"#, ignoreCase: true).found(in: "x (FÜR Lehramt)"))
        XCTAssertEqual(PyRegex.caseless(#"(?:a|\bB)[^)]\x{0B}"#), #"(?:[aA]|\b[bB])[^)]\x{0B}"#)
    }

    /// difflib.SequenceMatcher(None, a, b).ratio() fuer SEQUENCE_PAIRS (auch autojunk ab 200 Zeichen)
    func testSequenceMatcherLikeDifflib() throws {
        let cases = try studyFixture()["sequence_ratios"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let a = c["a"]?.string ?? "", b = c["b"]?.string ?? ""
            XCTAssertEqual(SequenceMatcher(a, b).ratio(), c["ratio"]?.double, "\(a.prefix(30)) / \(b.prefix(30))")
        }
    }
}

// MARK: - Semesterwochen

final class StudyWeeksTests: XCTestCase {

    /// semester_cut, semester_start, week_index und week_label fuer SEMESTER_TODAYS auf denselben Dateien
    func testSemesterWeeksLikePython() async throws {
        let fx = try studyFixture()
        let files = fx["semester_files"]?.array ?? []
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(berlin: "2026-01-01")!)
        try await db.transaction { c in
            for (i, f) in files.enumerated() {
                let course = f.array?[0] ?? .null, ts = f.array?[1] ?? .null
                try c.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES (?, ?, 'vorlesung', '2026-01-01T00:00:00')",
                              [sqliteValue(course), .text("Kurs \(course.string ?? "")")])
                try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?, ?, 'f.pdf', ?)", [.text("sem\(i)"), sqliteValue(course), sqliteValue(ts)])
            }
        }
        let semesters = fx["semesters"]?.array ?? []
        XCTAssertGreaterThanOrEqual(semesters.count, 8)
        var problems: [String] = []
        for s in semesters {
            let todayText = s["today"]?.string ?? ""
            let today = try XCTUnwrap(BerlinClock.parseISODate(todayText))
            let cut = BerlinClock.isoDate(StudyWeeks.semesterCut(today: today))
            if cut != s["cut"]?.string { problems.append("\(todayText): Stichtag \(cut) statt \(s["cut"]?.string ?? "-")") }
            let start = try await db.withConnection { try StudyWeeks.semesterStart($0, today: today) }
            if BerlinClock.isoDate(start) != s["start"]?.string {
                problems.append("\(todayText): Beginn \(BerlinClock.isoDate(start)) statt \(s["start"]?.string ?? "-")")
            }
            for w in s["weeks"]?.array ?? [] {
                let ch = sqliteValue(w["chdate"] ?? .null)
                let idx = try StudyWeeks.weekIndex(start: start, chdate: ch, today: today)
                let label = StudyWeeks.weekLabel(start: start, week: idx)
                if idx != w["week"]?.int || label != w["label"]?.string {
                    problems.append("\(todayText) \(ch): \(idx) \(label) statt \(w["week"]?.int ?? 99) \(w["label"]?.string ?? "-")")
                }
            }
            for (k, v) in s["labels"]?.object ?? [:] where StudyWeeks.weekLabel(start: start, week: Int(k)!) != v.string {
                problems.append("\(todayText): Bezeichnung von Woche \(k)")
            }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    /// Korrektur vom 25.10.2026 (zuerst in Python, tests/test_study_weeks.py): Stichtag nie in der Zukunft,
    /// Dateien vor dem Vorlesungsbeginn in Woche 0
    func testCutNeverInFutureAndPreStartIsWeekZero() throws {
        func day(_ s: String) -> Int { BerlinClock.parseISODate(s)! }
        XCTAssertEqual(StudyWeeks.semesterCut(today: day("2027-01-18")), day("2026-10-01"))
        XCTAssertEqual(StudyWeeks.semesterCut(today: day("2027-02-28")), day("2026-10-01"))
        XCTAssertEqual(StudyWeeks.semesterCut(today: day("2027-09-15")), day("2027-03-01"))
        XCTAssertEqual(StudyWeeks.semesterCut(today: day("2026-10-01")), day("2026-10-01"))
        let start = day("2026-10-12")
        let oct2 = SQLiteValue.integer(Int64(BerlinClock.utcSeconds(day: day("2026-10-02"), minutes: 600)))
        XCTAssertEqual(try StudyWeeks.weekIndex(start: start, chdate: oct2, today: day("2027-01-18")), 0)
        XCTAssertEqual(StudyWeeks.weekLabel(start: start, week: 0), "Vor Vorlesungsbeginn")
        XCTAssertEqual(StudyWeeks.weekLabel(start: start, week: 3), "Woche 3 · 26.10. – 01.11.")
        XCTAssertEqual(try StudyWeeks.weekIndex(start: start, chdate: .null, today: day("2026-11-20")), 0)
        XCTAssertThrowsError(try StudyWeeks.weekIndex(start: start, chdate: .text("gestern"), today: day("2026-11-20")))
        XCTAssertThrowsError(try StudyWeeks.weekIndex(start: start, chdate: .integer(Int64.max), today: day("2026-11-20")))
    }

    /// `day_week`: ein Termin und eine Datei am selben Tag liegen in derselben Woche (auch vor dem Stichtag und vor
    /// dem Vorlesungsbeginn)
    func testDayWeekMatchesWeekIndexOfFiles() throws {
        func day(_ s: String) -> Int { BerlinClock.parseISODate(s)! }
        let start = day("2026-10-12"), today = day("2026-11-20")
        for d in day("2026-09-01")...day("2027-02-28") {
            let noon = SQLiteValue.integer(Int64(BerlinClock.utcSeconds(day: d, minutes: 720)))
            XCTAssertEqual(StudyWeeks.dayWeek(start: start, day: d, today: today), try StudyWeeks.weekIndex(start: start, chdate: noon, today: today),
                           BerlinClock.isoDate(d))
        }
        XCTAssertEqual(StudyWeeks.dayWeek(start: start, day: day("2026-09-30"), today: today), -1)
        XCTAssertEqual(StudyWeeks.dayWeek(start: start, day: day("2026-10-02"), today: today), 0)
        XCTAssertEqual(StudyWeeks.dayWeek(start: start, day: day("2026-10-18"), today: today), 1)
    }
}

// MARK: - Unterlagen zum Termin

final class EventMaterialsTests: XCTestCase {

    /// timetable.materials_for_event fuer EVENT_TODAYS x Module x EVENT_DAYS auf der Seed-Datenbank nach
    /// ensure_modules: gleiche Woche des Termins, gleiche Dateien in gleicher Reihenfolge; eine Antwort Wert fuer Wert
    func testEventMaterialsLikePython() async throws {
        let fx = try studyFixture()
        let db = try await seededStudyDatabase(fx)
        try await db.transaction { try LocalModules.ensureModules($0, clock: .fixed(berlin: "2026-10-01T08:00:00")!) }
        let cases = fx["event_materials"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        var problems: [String] = []
        var checked = 0
        for m in cases {
            let todayText = m["today"]?.string ?? ""
            let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: todayText))
            let today = try XCTUnwrap(BerlinClock.parseISODate(todayText))
            let start = try await db.withConnection { try StudyWeeks.semesterStart($0, today: today) }
            let event: [String: JSONValue] = ["module_id": m["module_id"] ?? .null]
            for d in m["days"]?.array ?? [] {
                checked += 1
                let dayText = d["day"]?.string ?? ""
                let day = try XCTUnwrap(BerlinClock.parseISODate(dayText))
                let label = "\(todayText) Modul \(m["module_id"]?.jsonString() ?? "-") Termin \(dayText)"
                let w = StudyWeeks.dayWeek(start: start, day: day, today: today)
                if w != d["week"]?.int { problems.append("\(label): Woche \(w) statt \(d["week"]?.int ?? 99)") }
                let ids = try await db.withConnection { try LocalModules.eventMaterials($0, event: event, day: day, clock: clock) }.map { $0["id"] ?? .null }
                if ids != d["ids"]?.array ?? [] {
                    problems.append("\(label): \(JSONValue.array(ids).jsonString()) statt \(d["ids"]?.jsonString() ?? "-")")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 400)
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))

        // Termin 10 Tage vor dem Vorlesungsbeginn: das Skript aus Woche 0, nicht der Rueckfall auf die neuesten
        let anchor = try XCTUnwrap(cases.first { $0["today"] == "2026-11-20" && $0["module_id"] == 1 })
        XCTAssertEqual(anchor["days"]?.array?.first { $0["day"] == "2026-10-02" }?["ids"], ["f-ma-04"])

        let sample = try XCTUnwrap(fx["event_material_sample"])
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: sample["today"]?.string ?? ""))
        let day = try XCTUnwrap(BerlinClock.parseISODate(sample["day"]?.string ?? ""))
        let full = try await db.withConnection { try LocalModules.eventMaterials($0, event: ["module_id": sample["module_id"] ?? .null], day: day, clock: clock) }
        XCTAssertEqual(JSONValue.array(full), sample["response"])
        XCTAssertGreaterThanOrEqual(full.count, 2)

        // ohne Modul keine Unterlagen, auch ohne Schluessel
        let none = try await db.withConnection { try LocalModules.eventMaterials($0, event: [:], day: day, clock: clock) }
        XCTAssertEqual(none, [])
    }
}

// MARK: - Module-Endpunkte gegen app/server.py

/// Die erfundene Seed-Datenbank aus dem Fixture (`_module_seed()` im Generator)
private func seededStudyDatabase(_ fx: JSONValue) async throws -> SQLiteDatabase {
    let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
    try await db.migrate(clock: .fixed(berlin: "2026-10-01T08:00:00")!)
    let seed = fx["seed"]?.array ?? []
    XCTAssertGreaterThan(seed.count, 40)
    try await db.transaction { c in
        for s in seed {
            let parts = s.array ?? []
            try c.execute(parts.first?.string ?? "", (parts.count > 1 ? parts[1].array ?? [] : []).map(sqliteValue))
        }
    }
    return db
}

final class LocalModulesEndpointTests: XCTestCase {

    private func seededDatabase(_ fx: JSONValue) async throws -> SQLiteDatabase {
        try await seededStudyDatabase(fx)
    }

    /// Dieselbe Folge wie MODULE_SCENARIOS (Uhr je Abschnitt eingefroren) auf derselben Seed-Datenbank: gleicher
    /// Status, gleiche Antwort Wert fuer Wert, am Ende dieselben Tabellen
    func testScenariosMatchPythonServer() async throws {
        let fx = try studyFixture()
        let db = try await seededDatabase(fx)
        var problems: [String] = []
        var steps = 0
        for scenario in fx["scenarios"]?.array ?? [] {
            let now = scenario["now"]?.string ?? ""
            let backend = try LocalBackend(database: db, clock: try XCTUnwrap(UniFlowClock.fixed(berlin: now)))
            for step in scenario["steps"]?.array ?? [] {
                steps += 1
                let method = step["method"]?.string ?? "", path = step["path"]?.string ?? ""
                let body = step["raw"]?.string.map { Data($0.utf8) } ?? Data()
                let r = await backend.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                                          headers: body.isEmpty ? [:] : ["Content-Type": "application/json"], body: body))
                let label = "\(now) \(method) \(path) \(step["raw"]?.string ?? "")"
                if r.status != step["status"]?.int {
                    problems.append("\(label): Status \(r.status) statt \(step["status"]?.int ?? 0) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                    continue
                }
                let expected = step["response"] ?? .null
                if r.json != expected { problems.append("\(label): " + difference(r.json ?? .null, expected, at: "$")) }
            }
        }
        XCTAssertGreaterThanOrEqual(steps, 40)
        for (table, rows) in fx["tables"]?.object ?? [:] {
            let sql = ["modules": "SELECT * FROM modules ORDER BY id", "courses": "SELECT id, subject, kind, module_id FROM courses ORDER BY id",
                       "study_packages": "SELECT id, module_id, subject FROM study_packages ORDER BY id"][table]
            let local = try await db.rows(try XCTUnwrap(sql))
            if JSONValue.array(local.map(JSONValue.object)) != rows { problems.append("Tabelle \(table) weicht ab: " + difference(.array(local.map(JSONValue.object)), rows, at: table)) }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    /// Erste Abweichung zweier JSON-Werte (fuer verstaendliche Fehlermeldungen)
    private func difference(_ a: JSONValue, _ b: JSONValue, at path: String) -> String {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            if Set(x.keys) != Set(y.keys) { return "\(path): Schlüssel \(x.keys.sorted()) statt \(y.keys.sorted())" }
            for k in x.keys.sorted() where x[k] != y[k] { return difference(x[k]!, y[k]!, at: path + "." + k) }
        case (.array(let x), .array(let y)):
            if x.count != y.count { return "\(path): \(x.count) Einträge statt \(y.count)" }
            for (i, (p, q)) in zip(x, y).enumerated() where p != q { return difference(p, q, at: "\(path)[\(i)]") }
        default: break
        }
        return "\(path): \(a.jsonString(sortedKeys: true).prefix(200)) statt \(b.jsonString(sortedKeys: true).prefix(200))"
    }

    func testModuleEndpointsAreReal() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory)
        for (m, p) in [("GET", "/api/modules"), ("GET", "/api/modules/1"), ("POST", "/api/modules"), ("PATCH", "/api/modules/1"),
                       ("DELETE", "/api/modules/1"), ("POST", "/api/modules/auto-assign"), ("POST", "/api/courses/k1/module")] {
            let route = try XCTUnwrap(backend.route(method: m, path: p), "\(m) \(p)")
            XCTAssertFalse(route.placeholder, "\(m) \(p)")
            XCTAssertEqual(route.module, ModulesEndpoints.name)
        }
        // Kursliste und Kurs aendern gehoeren nicht zu den Modulen: Platzhalter bis S3, danach echt in den
        // Kurs-Endpunkten von S3. Darum hier nur pruefen, dass es sie gibt und S4 sie nicht belegt.
        for (m, p) in [("GET", "/api/courses"), ("PATCH", "/api/courses/k1")] {
            let route = try XCTUnwrap(backend.route(method: m, path: p), "\(m) \(p)")
            XCTAssertNotEqual(route.module, ModulesEndpoints.name, "\(m) \(p)")
        }
    }

    /// Ohne Stud.IP-Daten: leere Liste wie der PC-Server; ein angelegtes Modul erscheint mit Farbe und Sortierung
    func testEmptyDatabaseAndCreate() async throws {
        let clock = UniFlowClock.fixed(berlin: "2026-11-20T10:00:00")!
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let empty = await backend.handle(LocalRequest(method: "GET", path: "/api/modules"))
        XCTAssertEqual(empty.json, [])
        let created = await backend.handle(LocalRequest(method: "POST", path: "/api/modules", body: Data(#"{"name": "Neues Fach"}"#.utf8)))
        XCTAssertEqual(created.status, 200)
        XCTAssertEqual(created.json?["color"], "#175ee8", "erste Farbe der Palette (ModuleColors)")
        XCTAssertEqual(created.json?["color_custom"], 0)
        XCTAssertEqual(created.json?["created_at"], "2026-11-20T10:00:00")
        let list = await backend.handle(LocalRequest(method: "GET", path: "/api/modules"))
        XCTAssertEqual(list.json?.array?.first?["name"], "Neues Fach")
        XCTAssertEqual(list.json?.array?.first?["weeks"], 0)
        let detail = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/1"))
        XCTAssertEqual(detail.json?["weeks"], [])
        XCTAssertEqual(detail.json?["progress"], 0)
        let bad = await backend.handle(LocalRequest(method: "POST", path: "/api/modules", body: Data(#"{"name": ["x"]}"#.utf8)))
        XCTAssertEqual(bad.status, 422, "Python: 500 (AttributeError)")
        let badPatch = await backend.handle(LocalRequest(method: "PATCH", path: "/api/modules/1", body: Data(#"{"color": ["x"], "sort": 3}"#.utf8)))
        XCTAssertEqual(badPatch.status, 422)
        let after = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/1"))
        XCTAssertEqual(after.json?["module"]?["sort"], 0, "nichts geschrieben")
    }
}
