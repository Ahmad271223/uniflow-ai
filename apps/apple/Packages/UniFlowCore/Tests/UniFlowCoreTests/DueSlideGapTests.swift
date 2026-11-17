import Foundation
import XCTest
@testable import UniFlowCore

/// "Eine Klausur stand nur in einer Folie" (Meldung des Inhabers 17.11.2026): die Luecken der Kette je mit einem Test.
/// Folien als PowerPoint und als Bild werden gelesen, ohne dass sie jemand oeffnet; Vorbehalte stehen am Termin; ein neu
/// erkannter Klausurtermin wird einmal gemeldet; die neue Erkennung rechnet bei allen neu und behaelt Entscheidungen.
/// Alle Kurse, Dateien und Texte sind erfunden.
final class DueSlideGapTests: XCTestCase {

    /// Dienstag, 10.11.2026; die Klausur ist am Dienstag, 17.11.2026
    private let clock = UniFlowClock.fixed(berlin: "2026-11-10T10:00:00")!

    private func unix(_ local: String) -> Int64 { Int64(BerlinClock.utcSeconds(localISO: local)!) }

    private func json(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let url = URL(string: "uniflow-local://device" + path)!
        let r = await b.handle(LocalRequest(method: method, url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"],
                                            body: body?.serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self), file: file, line: line)
        return try XCTUnwrap(r.json, file: file, line: line)
    }

    private func exec(_ b: LocalBackend, _ sql: String, _ params: [SQLiteValue] = []) async throws {
        try await b.context.database.execute(sql, params)
    }

    private func backend(container: URL? = nil, tools: LocalDocumentTools? = nil) async throws -> LocalBackend {
        let b: LocalBackend
        if let container {
            b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                            files: LocalFiles(container: container, dataDirectory: "", tools: tools ?? TextTools()), university: "luh")
            try FileManager.default.createDirectory(at: container.appendingPathComponent("StudIP"), withIntermediateDirectories: true)
        } else {
            b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "luh")
        }
        try await exec(b, "INSERT INTO modules(id, name, color) VALUES (1, 'Statistik I', '#2563eb')")
        try await exec(b, "INSERT INTO courses(id, title, semester, kind, active, module_id) VALUES ('k1', 'Statistik I (Vorlesung)', 'WiSe 2026/27', 'vorlesung', 1, 1)")
        return b
    }

    private func addFile(_ b: LocalBackend, container: URL?, id: String, name: String, data: Data = Data("%PDF".utf8),
                         chdate: String = "2026-11-09T12:00") async throws {
        try await exec(b, "INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES (?, 'k1', ?, ?, ?, 'pdf')",
                       [.text(id), .text(name), .integer(unix(chdate)), .text("StudIP/\(name)")])
        if let container { try data.write(to: container.appendingPathComponent("StudIP/\(name)")) }
    }

    private func addPages(_ b: LocalBackend, id: String, _ pages: [String], chdate: String = "2026-11-09T12:00") async throws {
        for (i, t) in pages.enumerated() {
            try await exec(b, "INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?,?,?,?,?)",
                           [.text(id), .integer(Int64(i + 1)), .text(t), .integer(unix(chdate)), .text(ScriptSearch.searchForm(t))])
        }
    }

    private func titles(_ list: JSONValue) -> [String] {
        (list["items"]?.array ?? []).map { "\($0["date"]?.string ?? "") \($0["kind"]?.string ?? "") \($0["title"]?.string ?? "")" }
    }

    // MARK: ZIP fuer eine kleine PowerPoint-Datei (ohne Kompression)

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    private static func zip(_ entries: [(name: String, data: Data)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        var out = Data(), central = Data()
        for e in entries {
            let name = Array(e.name.utf8), crc = crc32(e.data), size = UInt32(e.data.count), offset = UInt32(out.count)
            out.append(contentsOf: [0x50, 0x4b, 0x03, 0x04] + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(size) + le32(size)
                       + le16(name.count) + le16(0) + name)
            out.append(e.data)
            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02] + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(size)
                           + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name)
        }
        let start = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                   + le32(UInt32(central.count)) + le32(start) + le16(0))
        return out
    }

    /// PowerPoint mit einer Folie je Text
    static func pptx(_ slides: [String]) -> Data {
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main", a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        var entries: [(name: String, data: Data)] = [("ppt/presentation.xml", Data("<p:presentation xmlns:p=\"\(p)\"/>".utf8))]
        for (i, text) in slides.enumerated() {
            let paras = text.components(separatedBy: "\n").map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
            entries.append(("ppt/slides/slide\(i + 1).xml",
                            Data("<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree><p:sp><p:txBody>\(paras)</p:txBody></p:sp></p:spTree></p:cSld></p:sld>".utf8)))
        }
        return zip(entries)
    }

    // MARK: 1. Kommt der Text der Folie an?

    /// Folien als PowerPoint, nie geoeffnet: das Nachlesen liest sie (vorher nur PDFs: die Klausur blieb unerkannt)
    func testPowerPointSlidesAreReadWithoutOpening() async throws {
        let container = try tempContainer(self)
        let b = try await backend(container: container)
        try await addFile(b, container: container, id: "f-pptx", name: "VL05_Schaetzer.pptx",
                          data: Self.pptx(["Statistik I\nSchätzer", "Organisatorisches\nKlausur\n17.11.2026, 10:00 Uhr\nAudimax"]))
        _ = try await json(b, "POST", "/api/due/refresh")
        let none = try await json(b, "GET", "/api/due")
        XCTAssertEqual(titles(none), [], "ohne Seitentexte nichts erkannt")
        let r = try await json(b, "POST", "/api/due/backfill?limit=20")
        XCTAssertEqual(r["read"]?.int, 1, "PowerPoint wird nachgelesen")
        XCTAssertEqual(r["remaining"]?.int, 0)
        let list = try await json(b, "GET", "/api/due")
        XCTAssertEqual(titles(list), ["2026-11-17 klausur Klausur"])
        let item = try XCTUnwrap(list["items"]?.array?.first)
        XCTAssertEqual(item["origin"]?.string, "erkannt in VL05_Schaetzer.pptx, S. 2")
        XCTAssertEqual(item["file_id"]?.string, "f-pptx")
        XCTAssertEqual(item["page"]?.int, 2)
        XCTAssertEqual(item["time"]?.string, "10:00")
    }

    /// Folien als Bild (keine Textebene): die Texterkennung liest sie in Portionen, jede Seite einmal
    func testImageOnlySlidesAreReadByOCRInPortions() async throws {
        let container = try tempContainer(self)
        let tools = TextTools(["bild.pdf": ["", "", "3", "", ""], "text.pdf": ["Eine Seite mit genug Text, die keine Texterkennung braucht."]])
        let b = try await backend(container: container, tools: tools)
        try await addFile(b, container: container, id: "f-bild", name: "bild.pdf")
        try await addFile(b, container: container, id: "f-text", name: "text.pdf", chdate: "2026-11-01T12:00")
        let ocr = FakeOCR([1: "Statistik I – Vorlesung 5", 4: "Kurzklausur am 17.11.2026 in der Vorlesung", 5: ""])
        b.context.ocr.set(ocr)
        let read = try await json(b, "POST", "/api/due/backfill")
        XCTAssertEqual(read["read"]?.int, 2)
        let before = try await json(b, "GET", "/api/due")
        XCTAssertEqual(titles(before), [], "Textebene leer: nichts erkannt")
        // erste Portion: drei Seiten
        let first = try await json(b, "POST", "/api/due/ocr?pages=3")
        XCTAssertEqual(first["pages"]?.int, 3)
        XCTAssertEqual(first["remaining"]?.int, 2)
        XCTAssertEqual(ocr.pagesRecognized, [1, 2, 3])
        let second = try await json(b, "POST", "/api/due/ocr?pages=3")
        XCTAssertEqual(second["pages"]?.int, 2)
        XCTAssertEqual(second["remaining"]?.int, 0)
        XCTAssertEqual(ocr.pagesRecognized, [1, 2, 3, 4, 5], "die Seite mit Text und schon erkannte Seiten nicht noch einmal")
        let list = try await json(b, "GET", "/api/due")
        XCTAssertEqual(titles(list), ["2026-11-17 klausur Kurzklausur"])
        XCTAssertEqual(list["items"]?.array?.first?["origin"]?.string, "erkannt in bild.pdf, S. 4")
        // nichts doppelt
        let third = try await json(b, "POST", "/api/due/ocr")
        XCTAssertEqual(third["pages"]?.int, 0)
        XCTAssertEqual(ocr.pagesRecognized.count, 5)
    }

    /// Ohne Texterkennung (Kern allein) und bei einer Datei, die sich nicht erkennen laesst: kein endloser Versuch
    func testOCRWithoutProviderAndFailureIsNotRetried() async throws {
        let container = try tempContainer(self)
        let tools = TextTools(["bild.pdf": ["", ""]])
        let b = try await backend(container: container, tools: tools)
        try await addFile(b, container: container, id: "f-bild", name: "bild.pdf")
        _ = try await json(b, "POST", "/api/due/backfill")
        let bare = try await json(b, "POST", "/api/due/ocr")
        XCTAssertEqual(bare["pages"]?.int, 0)
        XCTAssertEqual(bare["remaining"]?.int, 0, "ohne Erkennung wird nichts versprochen")
        let ocr = FakeOCR([:])
        ocr.failure = CocoaError(.fileReadCorruptFile)
        b.context.ocr.set(ocr)
        let failed = try await json(b, "POST", "/api/due/ocr")
        XCTAssertEqual(failed["pages"]?.int, 0)
        XCTAssertEqual(failed["remaining"]?.int, 0, "gescheitert: nicht bei jedem Lauf erneut")
        _ = try await json(b, "POST", "/api/due/ocr")
        XCTAssertEqual(ocr.calls.count, 1)
    }

    /// Sehr lange Bild-Dateien: je Datei nur die ersten Seiten (ein eingescanntes Buch haelt die Reihe nicht auf)
    func testOCRIsCappedPerFile() async throws {
        let b = try await backend()
        try await addFile(b, container: nil, id: "f-buch", name: "buch.pdf")
        try await addPages(b, id: "f-buch", Array(repeating: "", count: 200))
        let todo = try await b.context.database.transaction { c -> [(fileID: String, pages: [Int])] in
            try DueStore.ensureTables(c)
            return try DueStore.ocrCandidates(c, limit: 10_000)
        }
        XCTAssertEqual(todo.first?.pages.count, DueStore.ocrPagesPerFile)
    }

    // MARK: 2. Vorbehalte

    func testNoteIsShownWithTheDate() async throws {
        let b = try await backend()
        try await addFile(b, container: nil, id: "f1", name: "VL05.pdf")
        try await addPages(b, id: "f1", ["Klausur am Mittwoch, 17.11.2026", "Teilklausur in KW 49"])
        let list = try await json(b, "GET", "/api/due")
        XCTAssertEqual(titles(list), ["2026-11-17 klausur Klausur", "2026-11-30 klausur Teilklausur (KW 49, Tag offen)"])
        let items = list["items"]?.array ?? []
        XCTAssertEqual(items[0]["note"]?.string, "Im Text steht Mittwoch, der 17.11. ist aber ein Dienstag.")
        XCTAssertEqual(items[1]["note"]?.string, "Im Text steht nur die Woche (KW 49, 30.11.–06.12.), kein Tag. Eingetragen ist der Montag.")
        // eine zweite Fundstelle ohne Vorbehalt bestaetigt den Tag
        try await addFile(b, container: nil, id: "f2", name: "VL06.pdf")
        try await addPages(b, id: "f2", ["Klausur: Di, 17.11.2026"])
        let again = try await json(b, "GET", "/api/due?x=1")
        XCTAssertEqual(again["refreshed"], false, "am selben Tag nicht von selbst neu")
        _ = try await json(b, "POST", "/api/due/refresh")
        let merged = try await json(b, "GET", "/api/due")
        XCTAssertEqual(merged["items"]?.array?.first?["note"], .null)
        XCTAssertEqual(merged["items"]?.array?.first?["sources"]?.array?.count, 2)
    }

    // MARK: 5. Neu erkannt

    func testNewExamIsFlaggedOnceUntilSeen() async throws {
        let b = try await backend()
        try await addFile(b, container: nil, id: "f1", name: "VL01.pdf")
        try await addPages(b, id: "f1", ["Abgabe Blatt 2: 12.11.2026", "Kurztestat 1 am 24.11.2026"])
        let first = try await json(b, "GET", "/api/due")
        XCTAssertEqual(first["items"]?.array?.map { $0["is_new"]?.bool }, [nil, true], "Abgaben werden nicht gemeldet")
        XCTAssertEqual(first["items"]?.array?.last?["notified"], false)
        let id = try XCTUnwrap(first["items"]?.array?.last?["id"]?.string)
        // gemeldet: bleibt als neu sichtbar, wird aber nicht noch einmal gemeldet
        _ = try await json(b, "POST", "/api/due/seen", ["ids": [.string(id)], "notified": true])
        let told = try await json(b, "GET", "/api/due")
        XCTAssertEqual(told["items"]?.array?.last?["is_new"], true)
        XCTAssertEqual(told["items"]?.array?.last?["notified"], true)
        // neue Folie mit einer Klausur: nur die ist neu zu melden; ein weiterer Abgleich meldet nichts erneut
        try await addFile(b, container: nil, id: "f2", name: "VL05.pdf")
        try await addPages(b, id: "f2", ["Klausur\n17.11.2026, 10:00 Uhr\nAudimax"])
        _ = try await json(b, "POST", "/api/due/refresh")
        let more = try await json(b, "GET", "/api/due")
        let fresh = DueReminders.newItems(DueReminders.items(from: more))
        XCTAssertEqual(fresh.map(\.title), ["Klausur"])
        _ = try await json(b, "POST", "/api/due/seen", ["ids": .array(fresh.map { .string($0.id) }), "notified": true])
        _ = try await json(b, "POST", "/api/due/refresh")
        let after = try await json(b, "GET", "/api/due")
        XCTAssertEqual(DueReminders.newItems(DueReminders.items(from: after)), [])
        // Hinweis geschlossen: nicht mehr neu
        _ = try await json(b, "POST", "/api/due/seen", ["seen": true])
        let seen = try await json(b, "GET", "/api/due")
        XCTAssertEqual(seen["items"]?.array?.compactMap { $0["is_new"]?.bool }, [false, false])
    }

    func testConfirmOrHideEndsNew() async throws {
        let b = try await backend()
        try await addFile(b, container: nil, id: "f1", name: "VL05.pdf")
        try await addPages(b, id: "f1", ["Klausur: 17.11.2026", "Probeklausur am 12.11.2026"])
        let list = try await json(b, "GET", "/api/due")
        let ids = (list["items"]?.array ?? []).compactMap { $0["id"]?.string }
        XCTAssertEqual(ids.count, 2)
        _ = try await json(b, "PATCH", "/api/due/\(ids[0])", ["confirmed": true])
        _ = try await json(b, "PATCH", "/api/due/\(ids[1])", ["hidden": true])
        let after = try await json(b, "GET", "/api/due?hidden=1")
        XCTAssertEqual(DueReminders.newItems(DueReminders.items(from: after)), [])
        XCTAssertEqual(after["items"]?.array?.compactMap { $0["is_new"]?.bool }, [])
    }

    // MARK: Bestehende Daten

    /// Datenbank eines aelteren Builds (Erkennung "2", Tabelle ohne `note`): es wird neu gerechnet, was schon gezeigt
    /// wurde, gilt nicht als neu, die Entscheidungen bleiben
    func testOlderDatabaseIsRecomputedAndKeepsChoices() async throws {
        let b = try await backend()
        try await addFile(b, container: nil, id: "f1", name: "VL01.pdf")
        try await addPages(b, id: "f1", ["Kurzklausur am 11.12.2026", "Zwischenklausur am 17.11.2026 in der Vorlesung", "Testat 2 am 01.12.2026"])
        // Stand des alten Builds: Tabellen ohne `note` und ohne `due_seen`, zwei Termine erkannt, einer ausgeblendet
        try await b.context.database.transaction { c in
            try c.executeScript("""
                CREATE TABLE due_hits (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, file_id TEXT, page INTEGER, announcement_id TEXT,
                    course_id TEXT, date TEXT NOT NULL, time TEXT, kind TEXT NOT NULL, label TEXT NOT NULL, snippet TEXT, name TEXT, url TEXT, detected_at TEXT);
                CREATE TABLE due_choices (key TEXT PRIMARY KEY, hidden INTEGER NOT NULL DEFAULT 0, confirmed INTEGER NOT NULL DEFAULT 0, time TEXT, updated_at TEXT);
                CREATE TABLE due_meta (key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO due_hits(source, file_id, page, course_id, date, kind, label, snippet, name) VALUES
                    ('dokument', 'f1', 1, 'k1', '2026-12-11', 'klausur', 'Kurzklausur', 'Kurzklausur am 11.12.2026', 'VL01.pdf'),
                    ('dokument', 'f1', 3, 'k1', '2026-12-01', 'test', 'Testat 2', 'Testat 2 am 01.12.2026', 'VL01.pdf');
                INSERT INTO due_choices(key, hidden, confirmed) VALUES ('k1|2026-12-01|test', 1, 0);
                INSERT INTO due_meta(key, value) VALUES ('version', '2'), ('refreshed_day', '2026-11-10');
                """)
        }
        let list = try await json(b, "GET", "/api/due?hidden=1")
        XCTAssertEqual(list["refreshed"], true, "andere Erkennung: neu gerechnet")
        XCTAssertEqual(titles(list), ["2026-11-17 klausur Zwischenklausur", "2026-12-01 test Testat 2", "2026-12-11 klausur Kurzklausur"])
        let items = list["items"]?.array ?? []
        XCTAssertEqual(items[0]["is_new"], true, "erst die neue Erkennung findet die Zwischenklausur")
        XCTAssertEqual(items[1]["hidden"], true, "Entscheidung bleibt")
        XCTAssertNil(items[1]["is_new"]?.bool)
        XCTAssertEqual(items[2]["is_new"], false, "schon vom alten Build gezeigt")
        XCTAssertEqual(DueReminders.newItems(DueReminders.items(from: list)).map(\.title), ["Zwischenklausur"])
        XCTAssertEqual(DueStore.detectorVersion, "3")
    }

    // MARK: 4. Erinnerungen

    func testExamGetsSevenDayReminderAndNewNotice() throws {
        let now = Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: "2026-11-09T12:00")!))
        let exam = DueReminders.Item(id: "due-1", title: "Klausur", date: "2026-11-17", time: "10:00", course: "Statistik I",
                                     origin: "erkannt in VL05.pdf, S. 12", route: "#/doc/f1?page=12", kind: "klausur", isNew: true)
        let sheet = DueReminders.Item(id: "due-2", title: "Abgabe Blatt 3", date: "2026-11-17", kind: "abgabe", isNew: true)
        let plan = DueReminders.plan([exam, sheet], container: "C", now: now)
        XCTAssertEqual(plan.filter { $0.itemID == "due-1" }.map(\.title),
                       ["In 7 Tagen: Klausur", "In 3 Tagen: Klausur", "Morgen: Klausur", "In 2 Stunden: Klausur"])
        XCTAssertEqual(plan.filter { $0.itemID == "due-2" }.map(\.title), ["In 3 Tagen: Abgabe Blatt 3", "Morgen: Abgabe Blatt 3", "Heute: Abgabe Blatt 3"])
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count, "nichts doppelt")
        // neu erkannt: eine Mitteilung sofort, nur fuer Klausuren und Tests, nie zweimal
        let notices = DueReminders.newNotices([exam, sheet], container: "C", now: now)
        XCTAssertEqual(notices.map(\.title), ["Neuer Klausurtermin erkannt: Klausur am Di, 17.11. 10:00"])
        XCTAssertEqual(notices.first?.body, "Statistik I · erkannt in VL05.pdf, S. 12 · Bitte prüfen.")
        XCTAssertEqual(notices.first?.route, "#/doc/f1?page=12")
        XCTAssertEqual(notices.first?.identifier, "de.uniflow.ai.due.C.new.due-1")
        var told = exam
        told.notified = true
        XCTAssertEqual(DueReminders.newNotices([told], container: "C", now: now), [])
        // erst am Tag selbst erkannt (alle Zeitpunkte vorbei): die Mitteilung "neu erkannt" ist die einzige
        let late = Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: "2026-11-17T09:10")!))
        var today = exam
        today.time = nil
        XCTAssertEqual(DueReminders.plan([today], container: "C", now: late), [])
        XCTAssertEqual(DueReminders.newNotices([today], container: "C", now: late).map(\.title),
                       ["Neuer Klausurtermin erkannt: Klausur heute (Di, 17.11.)"])
        // viele auf einmal (erster Abgleich): eine Zusammenfassung
        let many = (1...5).map { DueReminders.Item(id: "d\($0)", title: "Testat \($0)", date: "2026-11-\(17 + $0)", kind: "test", isNew: true) }
        let summary = DueReminders.newNotices(many, container: "C", now: now)
        XCTAssertEqual(summary.map(\.title), ["5 neue Klausur- und Testtermine erkannt"])
        XCTAssertEqual(summary.first?.body, "Der nächste: Testat 1 am Mi, 18.11.. Bitte prüfen.")
    }

    // MARK: 3. Anzeige: Naechste Klausuren

    func testDetectedExamCarriesItsSourceInUpcomingExams() async throws {
        let b = try await backend()
        try await addFile(b, container: nil, id: "f1", name: "VL05.pdf")
        try await addPages(b, id: "f1", ["Titel", "Klausur\n17.11.2026, 10:00 Uhr\nAudimax"])
        _ = try await json(b, "GET", "/api/due")
        let exams = try await json(b, "GET", "/api/exams/upcoming")
        let e = try XCTUnwrap(exams["items"]?.array?.first)
        XCTAssertEqual(e["title"]?.string, "Klausur Statistik I")
        XCTAssertEqual(e["date"]?.string, "2026-11-17")
        XCTAssertEqual(e["source_label"]?.string, "erkannt in VL05.pdf, S. 2")
        XCTAssertEqual(e["detected_only"], true)
        XCTAssertEqual(e["file_id"]?.string, "f1")
        XCTAssertEqual(e["page"]?.int, 2)
        XCTAssertNotNil(e["due_id"]?.string)
    }
}
