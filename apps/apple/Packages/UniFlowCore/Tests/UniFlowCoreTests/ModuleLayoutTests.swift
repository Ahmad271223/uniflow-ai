import Foundation
import XCTest
@testable import UniFlowCore

/// Eigene Wochen und Abschnitte je Modul (Auftrag 12.11.2026, `ModuleLayout`): Wochen anlegen, umbenennen, loeschen,
/// sortieren, Dateien verschieben, Vorschlaege annehmen; die eigene Ordnung bleibt beim naechsten Abgleich.
final class ModuleLayoutTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-12T10:00:00")!

    // MARK: rein

    func testOrderWithoutLayoutMatchesWeekOrder() {
        let weeks = [3, -2, 1, -1, 0, -3, -4, 2]
        XCTAssertEqual(ModuleLayout.order(weeks, layout: .init()), weeks.sorted(by: LocalModules.weekOrder))
        XCTAssertEqual(ModuleLayout.order(weeks, layout: .init()), [-4, -3, 0, 1, 2, 3, -1, -2])
    }

    func testOrderKeepsUserSortAndPlacesNewWeeksAfterPredecessor() {
        // Nutzer hat Woche 2 hinter Woche 4 geschoben; spaeter kommen Woche 5 und Klausuren dazu (ohne Platz): Woche 5
        // direkt hinter Woche 4, Klausuren ans Ende
        let layout = ModuleLayout.Layout(sections: [
            .init(id: 1, week: 1, title: nil, sort: 0), .init(id: 2, week: 3, title: nil, sort: 1),
            .init(id: 3, week: 4, title: nil, sort: 2), .init(id: 4, week: 2, title: nil, sort: 3),
        ])
        XCTAssertEqual(ModuleLayout.order([1, 2, 3, 4, 5, -2], layout: layout), [1, 3, 4, 5, 2, -2])
        // nur Woche 5 neu und nichts mit groesserem Platz: ans Ende
        XCTAssertEqual(ModuleLayout.order([1, 2, 3, 4, 5], layout: layout), [1, 3, 4, 2, 5])
        // eigener Abschnitt hinter Woche 2 (Platz 20,5), ohne Sortierung
        let custom = ModuleLayout.Layout(sections: [.init(id: 7, week: nil, title: "Kapitel Graphen", rank: 20.5)])
        let g = ModuleLayout.customWeek(7)
        XCTAssertEqual(ModuleLayout.order([1, 2, 3, g, -4], layout: custom), [-4, 1, 2, g, 3])
    }

    func testPlanningAndDisplayWeek() {
        let layout = ModuleLayout.Layout(sections: [
            .init(id: 1, week: 5, title: nil, hidden: true),
            .init(id: 2, week: nil, title: "Graphen", rank: 30.5),
        ], places: ["a": "w:2", "b": "s:2", "c": "w:5", "d": "w:-4", "e": "s:99"])
        XCTAssertEqual(layout.planningWeek(fileID: "a", auto: 7), 2, "gelegt in Woche 2")
        XCTAssertEqual(layout.planningWeek(fileID: "b", auto: 7), 3, "eigener Abschnitt hinter Woche 3")
        XCTAssertEqual(layout.planningWeek(fileID: "c", auto: 7), 7, "geloeschte Woche: automatisch")
        XCTAssertEqual(layout.planningWeek(fileID: "d", auto: 7), 7, "Nicht zugeordnet plant wie bisher")
        XCTAssertEqual(layout.planningWeek(fileID: "e", auto: 7), 7, "unbekannter Abschnitt")
        XCTAssertEqual(layout.planningWeek(fileID: "x", auto: 7), 7)
        XCTAssertEqual(layout.displayWeek(fileID: "b", auto: 7, unsure: false), ModuleLayout.customWeek(2))
        XCTAssertEqual(layout.displayWeek(fileID: "c", auto: 7, unsure: false), 7, "Platz in geloeschter Woche zaehlt nicht")
        XCTAssertEqual(layout.displayWeek(fileID: "x", auto: 5, unsure: false), -4, "Woche geloescht: Nicht zugeordnet")
        XCTAssertEqual(layout.displayWeek(fileID: "x", auto: 3, unsure: true), -4)
        XCTAssertEqual(layout.displayWeek(fileID: "a", auto: 3, unsure: true), 2, "Nutzer schlaegt Unsicherheit")
    }

    func testKeysAndTitles() {
        XCTAssertEqual(ModuleLayout.key(week: 3), "w:3")
        XCTAssertEqual(ModuleLayout.key(week: ModuleLayout.customWeek(12)), "s:12")
        XCTAssertEqual(ModuleLayout.week(ofKey: "w:-4"), -4)
        XCTAssertEqual(ModuleLayout.week(ofKey: "s:12"), -1012)
        XCTAssertNil(ModuleLayout.week(ofKey: "w:-5"))
        XCTAssertNil(ModuleLayout.week(ofKey: "x:1"))
        XCTAssertEqual(ModuleLayout.weekNumber(inTitle: "Woche 5"), 5)
        XCTAssertEqual(ModuleLayout.weekNumber(inTitle: " 3. Woche "), 3)
        XCTAssertNil(ModuleLayout.weekNumber(inTitle: "Woche 5 – Graphen"))
        XCTAssertNil(ModuleLayout.weekNumber(inTitle: "Kapitel 2"))
    }

    func testSuggestions() {
        let start = BerlinClock.parseISODate("2026-10-12")!
        XCTAssertEqual(ModuleLayout.suggest(name: "Graphen.pdf", firstPage: "Diskrete Strukturen\nVorlesung 4: Graphen", start: start, term: nil),
                       .init(week: 4, reason: "Inhalt: Vorlesung 4"))
        XCTAssertEqual(ModuleLayout.suggest(name: "Loesung.pdf", firstPage: "Musterlösung zu Blatt 2", start: start, term: nil)?.week, 3)
        XCTAssertEqual(ModuleLayout.suggest(name: "Sitzung.pdf", firstPage: "Sitzung vom 27.10.2026", start: start, term: nil)?.week, 3)
        XCTAssertEqual(ModuleLayout.suggest(name: "02 Grundlagen.pdf", firstPage: nil, start: start, term: nil),
                       .init(week: 2, reason: "Nummer 2 am Anfang des Namens"))
        XCTAssertNil(ModuleLayout.suggest(name: "Grundlagen.pdf", firstPage: "Grundlagen der Informatik", start: start, term: nil))
    }

    func testBulkUploads() {
        var files: [(id: String, course: String, day: Int?, week: Int, docType: String?, hint: Int?)] = (1...6).map {
            ("f\($0)", "c1", 100, 1, "vorlesung", nil)
        }
        XCTAssertEqual(ModuleLayout.bulkUploads(files).count, 6)
        files[0].hint = 1
        XCTAssertEqual(ModuleLayout.bulkUploads(files), [], "nur 5 ohne Nummer")
        files[0].hint = nil
        files[1].week = 3
        XCTAssertEqual(ModuleLayout.bulkUploads(files), [], "nur zu Semesterbeginn")
    }

    // MARK: Backend

    /// Learnweb-Kurs (Hildesheim): drei Dateien mit Woche aus dem Abschnitt, zwei ohne Hinweis; LUH-Kurs mit
    /// Sammelupload am 12.10. (sieben Dateien ohne Nummer)
    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Einführung in die Informatik', '#175ee8', 0), (2, 'Lineare Algebra', '#16a34a', 1)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('lw-101', 'Einführung in die Informatik', 'Einführung in die Informatik', 'vorlesung', 'WiSe 2026/27', 1, 1, 't')")
            try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('sp-1', 'Lineare Algebra', 'Lineare Algebra', 'vorlesung', 'WiSe 2026/27', 1, 2, 't')")
            let lw: [(String, String, String?)] = [("lw-f1", "Folien.pdf", "Woche 1"), ("lw-f2", "Folien Teil B.pdf", "Woche 2"),
                                                   ("lw-f3", "aufgaben.pdf", "Woche 3"), ("lw-f4", "03 Rekursion.pdf", "Material"),
                                                   ("lw-f5", "Zusatz.pdf", "Material")]
            for (id, name, _) in lw {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, first_seen) VALUES (?,?,?,?,?)",
                              [.text(id), .text("lw-101"), .text(name), .integer(1_760_000_000), .text("2026-10-12T09:00:00")])
            }
            let inputs = lw.map { LectureWeeks.Input(id: $0.0, name: $0.1, section: $0.2) }
            try LectureWeeks.assignCourse(c, courseID: "lw-101", semester: "WiSe 2026/27", university: "hildesheim", files: inputs, now: "2026-10-12T09:00:00")
            let day = BerlinClock.parseISODate("2026-10-13")!
            for (i, n) in ["Einführung", "Vektorräume", "Basis", "Lineare Abbildungen", "Matrizen", "Determinanten", "Eigenwerte"].enumerated() {
                try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)",
                              [.text("la-\(i + 1)"), .text("sp-1"), .text("LA \(n).pdf"),
                               .integer(Int64(BerlinClock.utcSeconds(day: day, minutes: 600 + i)))])
            }
            // Text der ersten Seite einer Learnweb-Datei schon gelesen (Suche)
            try c.executeScript("CREATE TABLE IF NOT EXISTS page_texts (file_id TEXT, page INTEGER, text TEXT, chdate REAL)")
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('lw-f5', 1, 'Informatik I – Vorlesung 2: Zahlensysteme', 1760000000)")
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('la-3', 1, 'Lineare Algebra I\nVorlesung 3 – Basis und Dimension', 0)")
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('la-5', 1, 'Lineare Algebra I, 9. November 2026', 0)")
        }
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: String? = nil, status: Int = 200) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!, body: Data((body ?? "").utf8)))
        XCTAssertEqual(r.status, status, "\(method) \(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    private func blocks(_ d: JSONValue) -> [String] {
        (d["weeks"]?.array ?? []).map { w in
            "\(w["key"]?.string ?? "?")=\((["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"].flatMap { w[$0]?.array ?? [] }).compactMap { $0["id"]?.string }.sorted().joined(separator: ","))"
        }
    }

    func testLearnwebUnsureFilesWithSuggestions() async throws {
        let b = try await backend()
        let d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(d), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "w:3=lw-f3"])
        let un = d["weeks"]?.array?.first
        XCTAssertEqual(un?["label"], "Nicht zugeordnet")
        XCTAssertEqual(un?["suggestions"], 2)
        let files = Dictionary(uniqueKeysWithValues: (d["files"]?.array ?? []).compactMap { f in f["id"]?.string.map { ($0, f) } })
        XCTAssertEqual(files["lw-f4"]?["suggest_key"], "w:3")
        XCTAssertEqual(files["lw-f4"]?["suggest_reason"], "Nummer 3 am Anfang des Namens")
        XCTAssertEqual(files["lw-f5"]?["suggest_key"], "w:2")
        XCTAssertEqual(files["lw-f5"]?["suggest_reason"], "Inhalt: Vorlesung 2")
        // Ziele: alle Lehrwochen des Semesters, Allgemein, Nicht zugeordnet
        let targets = d["targets"]?.array?.compactMap { $0["key"]?.string } ?? []
        XCTAssertTrue(targets.contains("w:10") && targets.contains("w:-3") && targets.contains("w:-4"), "\(targets)")
        // annehmen (nur eine Datei), dann alle
        _ = try await call(b, "POST", "/api/modules/1/suggestions/accept", #"{"file_ids": ["lw-f5"]}"#)
        let got147 = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(got147), ["w:-4=lw-f4", "w:1=lw-f1", "w:2=lw-f2,lw-f5", "w:3=lw-f3"])
        _ = try await call(b, "POST", "/api/modules/1/suggestions/accept", "{}")
        let after = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(after), ["w:1=lw-f1", "w:2=lw-f2,lw-f5", "w:3=lw-f3,lw-f4"])
        XCTAssertEqual(after["layout_custom"], true)
    }

    func testOwnSectionsSurviveNextSync() async throws {
        let b = try await backend()
        // eigener Abschnitt hinter Woche 2, Datei hineinlegen, umbenennen
        let created = try await call(b, "POST", "/api/modules/1/sections", #"{"title": "Kapitel Graphen", "after": "w:2"}"#)
        let key = try XCTUnwrap(created["key"]?.string)
        XCTAssertTrue(key.hasPrefix("s:"))
        _ = try await call(b, "POST", "/api/modules/1/place", "{\"file_ids\": [\"lw-f3\", \"la-1\"], \"to\": \"\(key)\"}")
        _ = try await call(b, "POST", "/api/modules/1/sections/rename", "{\"key\": \"\(key)\", \"title\": \"Graphen\"}")
        _ = try await call(b, "POST", "/api/modules/1/sections/rename", #"{"key": "w:1", "title": "Einstieg"}"#)
        var d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(d), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "\(key)=lw-f3"], "fremde Datei la-1 nicht verschoben")
        XCTAssertEqual(d["weeks"]?.array?[1]["label"], "Einstieg")
        XCTAssertEqual(d["weeks"]?.array?[3]["label"], "Graphen")
        XCTAssertEqual(d["weeks"]?.array?[3]["custom"], true)
        // Lernkalender: die Datei im eigenen Abschnitt gehoert zur Woche davor (2), Sprung "Zum Modul" in den Abschnitt
        let planning = try await b.context.database.withConnection { c -> Int in
            let dates = try LocalModules.Dates(c, clock: self.clock)
            let f = try XCTUnwrap(try LocalModules.fileRows(c, moduleID: .integer(1)).first { $0.json["id"]?.string == "lw-f3" })
            return try LocalModules.week(f, dates: dates)
        }
        XCTAssertEqual(planning, 2)
        let focus = try await call(b, "GET", "/api/modules/1?file=lw-f3")
        XCTAssertEqual(focus["focus_week"]?.int, ModuleLayout.week(ofKey: key))
        // naechster Abgleich: neue Datei wird automatisch eingeordnet, die eigene Ordnung bleibt
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO files(id, course_id, name, chdate, first_seen) VALUES ('lw-f6', 'lw-101', 'Folien.pdf', 1760000000, '2026-10-26T09:00:00')")
            let inputs = [("lw-f1", "Folien.pdf", "Woche 1"), ("lw-f2", "Folien Teil B.pdf", "Woche 2"), ("lw-f3", "aufgaben.pdf", "Woche 3"),
                          ("lw-f4", "03 Rekursion.pdf", "Material"), ("lw-f5", "Zusatz.pdf", "Material"), ("lw-f6", "Folien.pdf", "Woche 3")]
                .map { LectureWeeks.Input(id: $0.0, name: $0.1, section: $0.2) }
            try LectureWeeks.assignCourse(c, courseID: "lw-101", semester: "WiSe 2026/27", university: "hildesheim", files: inputs, now: "2026-10-26T09:00:00")
        }
        d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(d), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "\(key)=lw-f3", "w:3=lw-f6"])
        // Reihenfolge selbst festlegen: Woche 3 vor den eigenen Abschnitt
        _ = try await call(b, "PUT", "/api/modules/1/sections/order", "{\"keys\": [\"w:-4\", \"w:1\", \"w:2\", \"w:3\", \"\(key)\"]}")
        d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(d), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "w:3=lw-f6", "\(key)=lw-f3"])
        let planning2 = try await b.context.database.withConnection { c -> Int in
            let dates = try LocalModules.Dates(c, clock: self.clock)
            let f = try XCTUnwrap(try LocalModules.fileRows(c, moduleID: .integer(1)).first { $0.json["id"]?.string == "lw-f3" })
            return try LocalModules.week(f, dates: dates)
        }
        XCTAssertEqual(planning2, 3, "jetzt hinter Woche 3")
        // eigenen Abschnitt loeschen: Datei wieder automatisch (Woche 3)
        _ = try await call(b, "POST", "/api/modules/1/sections/delete", "{\"key\": \"\(key)\"}")
        d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(d), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "w:3=lw-f3,lw-f6"])
        // automatische Woche loeschen: Dateien in "Nicht zugeordnet"; "Woche 2" anlegen holt sie zurueck
        _ = try await call(b, "POST", "/api/modules/1/sections/delete", #"{"key": "w:2"}"#)
        let got204 = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(got204), ["w:-4=lw-f2,lw-f4,lw-f5", "w:1=lw-f1", "w:3=lw-f3,lw-f6"])
        let again = try await call(b, "POST", "/api/modules/1/sections", #"{"title": "Woche 2"}"#)
        XCTAssertEqual(again["key"], "w:2")
        let got208 = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(got208), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "w:3=lw-f3,lw-f6"])
        // leere eigene Woche bleibt als Ziel stehen
        _ = try await call(b, "POST", "/api/modules/1/sections", #"{"title": "Woche 6"}"#)
        let got212 = try await call(b, "GET", "/api/modules/1")
        XCTAssertTrue(blocks(got212).contains("w:6="))
        // Zuruecksetzen
        _ = try await call(b, "DELETE", "/api/modules/1/layout")
        d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(blocks(d), ["w:-4=lw-f4,lw-f5", "w:1=lw-f1", "w:2=lw-f2", "w:3=lw-f3,lw-f6"])
        XCTAssertEqual(d["layout_custom"], false)
    }

    func testErrors() async throws {
        let b = try await backend()
        _ = try await call(b, "POST", "/api/modules/1/sections", #"{"title": "  "}"#, status: 400)
        _ = try await call(b, "POST", "/api/modules/1/sections/delete", #"{"key": "w:-4"}"#, status: 400)
        _ = try await call(b, "POST", "/api/modules/1/place", #"{"file_ids": ["lw-f1"], "to": "s:999"}"#, status: 400)
        _ = try await call(b, "PUT", "/api/modules/1/sections/order", #"{"keys": ["w:1", "w:1"]}"#, status: 400)
        _ = try await call(b, "POST", "/api/modules/99/sections", #"{"title": "X"}"#, status: 404)
    }

    /// LUH (Stud.IP): Sammelupload zu Semesterbeginn ohne Nummer im Namen -> "Nicht zugeordnet", Vorschlag aus der
    /// ersten Seite, wo sie gelesen ist; Lernkalender plant diese Dateien wie bisher (Woche 1)
    func testStudIPBulkUpload() async throws {
        let b = try await backend()
        let d = try await call(b, "GET", "/api/modules/2")
        XCTAssertEqual(blocks(d), ["w:-4=la-1,la-2,la-3,la-4,la-5,la-6,la-7"])
        let s = (d["files"]?.array ?? []).compactMap { $0["suggest_key"]?.string }
        XCTAssertEqual(s, ["w:3"], "Vorlesung 3 auf der ersten Seite; ein Datum ohne Zahlenform zaehlt nicht")
        let planning = try await b.context.database.withConnection { c -> [Int] in
            let dates = try LocalModules.Dates(c, clock: self.clock)
            return try LocalModules.fileRows(c, moduleID: .integer(2)).map { try LocalModules.week($0, dates: dates) }
        }
        XCTAssertEqual(Set(planning), [0], "Lernkalender unveraendert (Woche vor Vorlesungsbeginn in Hildesheim-Semester), bis der Nutzer ordnet")
        _ = try await call(b, "POST", "/api/modules/2/suggestions/accept", "{}")
        let got244 = try await call(b, "GET", "/api/modules/2")
        XCTAssertEqual(blocks(got244), ["w:-4=la-1,la-2,la-4,la-5,la-6,la-7", "w:3=la-3"])
        // Rest von Hand in Woche 1 legen: Sammelupload ist dann geordnet
        _ = try await call(b, "POST", "/api/modules/2/place", #"{"file_ids": ["la-1", "la-2", "la-4", "la-5", "la-6", "la-7"], "to": "w:1"}"#)
        let ordered = try await call(b, "GET", "/api/modules/2")
        XCTAssertEqual(blocks(ordered), ["w:1=la-1,la-2,la-4,la-5,la-6,la-7", "w:3=la-3"])
    }

    // MARK: gemeinsame Faelle mit Python (tools/gen-module-layout-fixture.py)

    private func cases() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("packages/shared-contracts").path) {
            url.deleteLastPathComponent()
        }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/module-layout/cases.json")))
    }

    private func layout(_ v: JSONValue?) -> ModuleLayout.Layout {
        let sections = (v?["sections"]?.array ?? []).map { s in
            ModuleLayout.Section(id: Int64(s["id"]?.int ?? 0), week: s["week"]?.int, title: s["title"]?.string, rank: s["rank"]?.double,
                                 sort: s["sort"]?.double, hidden: s["hidden"]?.bool ?? false)
        }
        var places: [String: String] = [:]
        for (k, v) in v?["places"]?.object ?? [:] { places[k] = v.string }
        return ModuleLayout.Layout(sections: sections, places: places)
    }

    func testSharedCasesWithPython() throws {
        let fx = try cases()
        let layouts = fx["layouts"]?.object ?? [:]
        for c in fx["order"]?.array ?? [] {
            let l = layout(layouts[c["layout"]?.string ?? ""])
            XCTAssertEqual(ModuleLayout.order((c["weeks"]?.array ?? []).compactMap(\.int), layout: l), (c["expect"]?.array ?? []).compactMap(\.int),
                           "Reihenfolge \(c)")
        }
        for c in fx["files"]?.array ?? [] {
            let l = layout(layouts[c["layout"]?.string ?? ""])
            let f = c["file"]?.string, auto = c["auto"]?.int ?? 0
            XCTAssertEqual(l.planningWeek(fileID: f, auto: auto), c["planning"]?.int, "Lernwoche \(c)")
            XCTAssertEqual(l.displayWeek(fileID: f, auto: auto, unsure: c["unsure"]?.bool ?? false), c["display"]?.int, "Block \(c)")
        }
        for c in fx["keys"]?.array ?? [] {
            XCTAssertEqual(ModuleLayout.week(ofKey: c["key"]?.string ?? ""), c["week"]?.int, "Schlüssel \(c)")
        }
        for c in fx["titles"]?.array ?? [] {
            XCTAssertEqual(ModuleLayout.weekNumber(inTitle: c["title"]?.string ?? ""), c["week"]?.int, "Titel \(c)")
        }
        for c in fx["hints"]?.array ?? [] {
            let h = LectureWeeks.nameHint(c["name"]?.string ?? "")
            XCTAssertEqual(h?.kind.rawValue, c["expect"]?["kind"]?.string, "Hinweis \(c)")
            XCTAssertEqual(h?.number, c["expect"]?["number"]?.int, "Hinweis \(c)")
        }
        for c in fx["dates"]?.array ?? [] {
            XCTAssertEqual(LectureWeeks.dateInName(c["name"]?.string ?? "").map(BerlinClock.isoDate), c["expect"]?.string, "Datum \(c)")
        }
        for c in fx["suggest"]?.array ?? [] {
            let start = try XCTUnwrap(BerlinClock.parseISODate(c["start"]?.string ?? ""))
            let s = ModuleLayout.suggest(name: c["name"]?.string ?? "", firstPage: c["first_page"]?.string, start: start, term: nil)
            XCTAssertEqual(s?.week, c["expect"]?["week"]?.int, "Vorschlag \(c)")
            XCTAssertEqual(s?.reason, c["expect"]?["reason"]?.string, "Vorschlag \(c)")
        }
        for c in fx["bulk"]?.array ?? [] {
            let files = (c["files"]?.array ?? []).map { f in
                (id: f["id"]?.string ?? "", course: f["course"]?.string ?? "", day: (f["day"]?.string).flatMap(BerlinClock.parseISODate),
                 week: f["week"]?.int ?? 0, docType: f["doc_type"]?.string, hint: f["hint"]?.int)
            }
            XCTAssertEqual(ModuleLayout.bulkUploads(files).sorted(), (c["expect"]?.array ?? []).compactMap(\.string), "Sammelupload \(c["name"] ?? .null)")
        }
    }
}
