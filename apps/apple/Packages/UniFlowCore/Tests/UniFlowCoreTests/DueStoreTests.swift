import Foundation
import XCTest
@testable import UniFlowCore

/// Erkannte Abgaben, Tests und Pruefungen in der Datenbank (`DueStore`) und ueber die Endpunkte: Lauf ueber Seitentexte,
/// Dateinamen und Ankuendigungen, Zusammenfuehren, Ausblenden (bleibt gemerkt), Bestaetigen und Uhrzeit, Anzeige in
/// Kalender, Stundenplan, Uebersicht und GET /api/deadlines, beide Hochschulen und Trennung je Container. Alle Kurse,
/// Dateien und Texte sind erfunden.
final class DueStoreTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-10-27T10:00:00")!

    private func unix(_ local: String) -> Int64 { Int64(BerlinClock.utcSeconds(localISO: local)!) }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        let url = URL(string: "uniflow-local://device" + path)!
        return await b.handle(LocalRequest(method: method, url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"],
                                           body: body?.serialized()))
    }

    private func get(_ b: LocalBackend, _ path: String, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        try await json(b, "GET", path, file: file, line: line)
    }

    private func json(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let r = await call(b, method, path, body)
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self), file: file, line: line)
        return try XCTUnwrap(r.json, file: file, line: line)
    }

    private func exec(_ b: LocalBackend, _ sql: String, _ params: [SQLiteValue] = []) async throws {
        try await b.context.database.execute(sql, params)
    }

    private func addFile(_ b: LocalBackend, id: String, name: String, course: String, chdate: String = "2026-10-20T12:00",
                         pages: [String] = [], deleted: Bool = false) async throws {
        let stamp = unix(chdate)
        try await exec(b, """
            INSERT INTO files(id, course_id, name, chdate, local_path, kind, deleted_at) VALUES (?,?,?,?,?,'pdf',?)
            """, [.text(id), .text(course), .text(name), .integer(stamp), .text("StudIP/\(id).pdf"), deleted ? .text("2026-10-26T09:00:00") : .null])
        for (i, t) in pages.enumerated() {
            try await exec(b, "INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?,?,?,?,?)",
                           [.text(id), .integer(Int64(i + 1)), .text(t), .integer(stamp), .text(ScriptSearch.searchForm(t))])
        }
    }

    /// LUH: Modul "Analysis I" mit Vorlesung und Uebung, Dateien wie in Stud.IP, eine Stud.IP-Ankuendigung
    private func luhBackend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "luh")
        try await exec(b, "INSERT INTO modules(id, name, color) VALUES (1, 'Analysis I', '#2563eb'), (2, 'Lineare Algebra', '#16a34a')")
        try await exec(b, """
            INSERT INTO courses(id, title, semester, kind, active, module_id) VALUES
              ('k-ana', 'Analysis I (Vorlesung)', 'WiSe 2026/27', 'vorlesung', 1, 1),
              ('k-ana-ue', 'Analysis I (Übung)', 'WiSe 2026/27', 'uebung', 1, 1),
              ('k-la', 'Lineare Algebra', 'WiSe 2026/27', 'vorlesung', 1, 2),
              ('k-alt', 'Altes Seminar', 'WiSe 2022/23', 'sonstiges', 0, NULL)
            """)
        try await addFile(b, id: "f-ue07", name: "Uebung07.pdf", course: "k-ana-ue",
                          pages: ["Große Übung 7\nWiSe 2026/27", "Aufgabe 1\nFür den ersten Probe-Kurztest am 09.11.2026 ist der Stoff bis Kapitel 2 wichtig."])
        try await addFile(b, id: "f-folien", name: "VL01_Organisatorisches.pdf", course: "k-ana",
                          pages: ["Analysis I", "Organisatorisches\nEs gibt 3 Kurztestate (je 20 Minuten) im Semester",
                                  "Semesterplan\n3 09.11. Grundlagen, Kurztestat 1\n5 23.11. Kapitel 3 Kurztestat 2"])
        try await addFile(b, id: "f-kk", name: "Hinweise.pdf", course: "k-ana",
                          pages: ["Kurzklausurtermin – Datum: Fr, 11.12.2026, Anmeldung über Stud.IP"])
        // alte Datei mit anderem Semester im Kopf und alte Probe-Kurzklausur mit Jahr
        try await addFile(b, id: "f-alt", name: "Probe-Kurzklausur.pdf", course: "k-ana",
                          pages: ["Wintersemester 2020/21\nProbe-Kurzklausur\nAbgabe bis 03.11.", "Alte Probe-Kurzklausur vom 14.11.2023"])
        try await addFile(b, id: "f-blatt", name: "Blatt 3 Abgabe 05.11.pdf", course: "k-la", chdate: "2026-10-28T08:00")
        try await addFile(b, id: "f-weg", name: "Blatt 4.pdf", course: "k-la", pages: ["Abgabe bis 12.11.2026"], deleted: true)
        try await addFile(b, id: "f-inaktiv", name: "Seminarplan.pdf", course: "k-alt", pages: ["Abgabe der Hausarbeit: 15.03.2027"])
        let news = Announcements.fromStudIPNews(
            ["id": "n1", "attributes": ["title": "Kurzklausur", "content": "<p>Die Kurzklausur findet am 11.12.2026 statt.</p>",
                                        "publication-start": "2026-10-25T09:00:00+01:00"]],
            courseID: "k-ana", studipBase: "https://studip.example.test", today: BerlinClock.parseISODate("2026-10-27")!)!
        try await b.context.database.transaction { c in
            _ = try Announcements.store(c, [news], source: "studip", fetchedAt: "2026-10-27T09:00:00")
        }
        return b
    }

    // MARK: Erkennen und Liste

    func testRefreshFindsMergesAndDropsOld() async throws {
        let b = try await luhBackend()
        let r = try await json(b, "POST", "/api/due/refresh")
        XCTAssertEqual(r["changed"], true)
        XCTAssertEqual(r["hits"]?.int, 6, "Übung S.2, Folien zweimal, Kurzklausur, Dateiname, Ankündigung")
        let list = try await get(b, "/api/due")
        let items = list["items"]?.array ?? []
        XCTAssertEqual(items.map { "\($0["date"]?.string ?? "") \($0["kind"]?.string ?? "") \($0["title"]?.string ?? "")" },
                       ["2026-11-05 abgabe Abgabe Blatt 3", "2026-11-09 test Kurztestat 1", "2026-11-23 test Kurztestat 2",
                        "2026-12-11 klausur Kurzklausur"])
        // Doppelte zusammengefuehrt: gleiches Modul, gleicher Tag, gleiche Art, beide Fundstellen gemerkt
        let first = items[1]
        XCTAssertEqual(first["sources"]?.array?.count, 2)
        XCTAssertEqual(first["origin"]?.string, "erkannt in Uebung07.pdf, S. 2 und an 1 weiteren Stelle")
        XCTAssertEqual(first["file_id"]?.string, "f-ue07")
        XCTAssertEqual(first["page"]?.int, 2)
        XCTAssertEqual(first["in_days"]?.string, "in 13 Tagen")
        XCTAssertEqual(first["days_left"]?.int, 13)
        XCTAssertEqual(first["color"]?.string, "#2563eb")
        XCTAssertEqual(first["detected"], true)
        // Dateiname ohne Seitentext: oeffnet Seite 1
        XCTAssertEqual(items[0]["origin"]?.string, "erkannt im Dateinamen „Blatt 3 Abgabe 05.11.pdf“")
        XCTAssertEqual(items[0]["page"]?.int, 1)
        // Kurzklausur aus Datei und Ankuendigung
        let kk = items[3]
        XCTAssertEqual(kk["sources"]?.array?.compactMap { $0["source"]?.string }, ["dokument", "ankuendigung"])
        XCTAssertEqual(kk["announcement_ids"], ["sp-news-n1"])
        XCTAssertEqual(kk["in_days"]?.string, "in 45 Tagen")
        XCTAssertEqual(list["hidden"]?.int, 0)
        // Modul-Filter
        let la = try await get(b, "/api/due?module_id=2")
        XCTAssertEqual(la["items"]?.array?.compactMap { $0["title"]?.string }, ["Abgabe Blatt 3"])
        // zweiter Lauf ohne Aenderung
        let again = try await json(b, "POST", "/api/due/refresh")
        XCTAssertEqual(again["changed"], false)
    }

    func testListComputesOnFirstReadAndOncePerDay() async throws {
        let b = try await luhBackend()
        let list = try await get(b, "/api/due")
        XCTAssertEqual(list["items"]?.array?.count, 4, "noch nie gerechnet: GET rechnet selbst")
        XCTAssertEqual(list["refreshed"], true)
        let second = try await get(b, "/api/due")
        XCTAssertEqual(second["refreshed"], false)
        let refreshed = try await b.context.database.scalar("SELECT value FROM due_meta WHERE key='refreshed_day'")?.string
        XCTAssertEqual(refreshed, "2026-10-27")
        // neue Seite ohne Abgleich: erst am naechsten Tag (oder nach dem naechsten Abgleich) dabei
        try await addFile(b, id: "f-neu", name: "Blatt 5.pdf", course: "k-la", pages: ["Abgabe: 19.11.2026"])
        let same = try await get(b, "/api/due")
        XCTAssertEqual(same["items"]?.array?.count, 4)
        try await b.context.database.execute("UPDATE due_meta SET value='2026-10-26' WHERE key='refreshed_day'")
        let next = try await get(b, "/api/due")
        XCTAssertEqual(next["items"]?.array?.count, 5)
    }

    // MARK: Ausblenden, Bestaetigen, Uhrzeit

    func testHideIsRememberedAcrossRefresh() async throws {
        let b = try await luhBackend()
        _ = try await json(b, "POST", "/api/due/refresh")
        let start = try await get(b, "/api/due")
        let id = try XCTUnwrap(start["items"]?.array?.first { $0["kind"]?.string == "test" }?["id"]?.string)
        let hidden = try await json(b, "PATCH", "/api/due/\(id)", ["hidden": true])
        XCTAssertEqual(hidden["hidden"], true)
        var list = try await get(b, "/api/due")
        XCTAssertFalse((list["items"]?.array ?? []).contains { $0["id"]?.string == id })
        XCTAssertEqual(list["hidden"]?.int, 1)
        // nach dem naechsten Abgleich weiter ausgeblendet; beide Kurse des Moduls haben die Entscheidung
        _ = try await json(b, "POST", "/api/due/refresh")
        list = try await get(b, "/api/due")
        XCTAssertFalse((list["items"]?.array ?? []).contains { $0["id"]?.string == id })
        let keys = try await b.context.database.rows("SELECT key, hidden FROM due_choices ORDER BY key")
        XCTAssertEqual(keys.map { $0["key"]?.string ?? "" }, ["k-ana-ue|2026-11-09|test", "k-ana|2026-11-09|test"])
        // ausgeblendete auf Wunsch sichtbar, wieder einblenden
        let withHidden = try await get(b, "/api/due?hidden=1")
        XCTAssertEqual(withHidden["items"]?.array?.first { $0["id"]?.string == id }?["hidden"], true)
        _ = try await json(b, "PATCH", "/api/due/\(id)", ["hidden": false])
        list = try await get(b, "/api/due")
        XCTAssertTrue((list["items"]?.array ?? []).contains { $0["id"]?.string == id })
        // ausgeblendet fehlt er auch im Kalender und in den naechsten Terminen
        _ = try await json(b, "PATCH", "/api/due/\(id)", ["hidden": true])
        let cal = try await get(b, "/api/calendar?start=2026-11-09&end=2026-11-09")
        XCTAssertEqual(cal["days"]?.array?.first?["deadlines"]?.array?.count, 0)
        let dl = try await get(b, "/api/deadlines")
        XCTAssertFalse((dl["deadlines"]?.array ?? []).contains { $0["deadline_id"]?.string == id })
    }

    func testConfirmAndChangeTime() async throws {
        let b = try await luhBackend()
        _ = try await json(b, "POST", "/api/due/refresh")
        let start = try await get(b, "/api/due")
        let kk = try XCTUnwrap(start["items"]?.array?.first { $0["kind"]?.string == "klausur" })
        let id = try XCTUnwrap(kk["id"]?.string)
        XCTAssertEqual(kk["time"], .null)
        XCTAssertEqual(kk["confirmed"], false)
        let set = try await json(b, "PATCH", "/api/due/\(id)", ["confirmed": true, "time": "09:30"])
        XCTAssertEqual(set["confirmed"], true)
        XCTAssertEqual(set["time"]?.string, "09:30")
        XCTAssertEqual(set["user_time"], true)
        _ = try await json(b, "POST", "/api/due/refresh")
        let afterList = try await get(b, "/api/due")
        let after = try XCTUnwrap(afterList["items"]?.array?.first { $0["id"]?.string == id })
        XCTAssertEqual(after["time"]?.string, "09:30", "eigene Uhrzeit bleibt nach dem Abgleich")
        XCTAssertEqual(after["due_at"]?.string, "2026-12-11T09:30")
        let cleared = try await json(b, "PATCH", "/api/due/\(id)", ["time": .null])
        XCTAssertEqual(cleared["time"], .null)
        XCTAssertEqual(cleared["confirmed"], true)
        // Fehler
        let bad = await call(b, "PATCH", "/api/due/\(id)", ["time": "25:00"])
        XCTAssertEqual(bad.status, 422)
        let flag = await call(b, "PATCH", "/api/due/\(id)", ["hidden": "ja"])
        XCTAssertEqual(flag.status, 422)
        let unknown = await call(b, "PATCH", "/api/due/due-gibtesnicht", ["hidden": true])
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(unknown.json?["detail"]?.string, "Termin nicht gefunden")
    }

    // MARK: Anzeige in Kalender, Stundenplan, Uebersicht

    func testCalendarTimetableDashboardAndDeadlines() async throws {
        let b = try await luhBackend()
        _ = try await json(b, "POST", "/api/due/refresh")
        let cal = try await get(b, "/api/calendar?start=2026-11-09&end=2026-11-15")
        let monday = try XCTUnwrap(cal["days"]?.array?.first { $0["date"]?.string == "2026-11-09" })
        let chip = try XCTUnwrap(monday["deadlines"]?.array?.first)
        XCTAssertEqual(chip["kind_label"]?.string, "Kurztestat")
        XCTAssertEqual(chip["file_id"]?.string, "f-ue07")
        XCTAssertEqual(chip["page"]?.int, 2)
        XCTAssertEqual(chip["source"]?.string, "dokument")
        XCTAssertEqual(chip["time"], .null)
        let week = try await get(b, "/api/timetable/week?start=2026-12-07")
        let friday = try XCTUnwrap(week["days"]?.array?.first { $0["date"]?.string == "2026-12-11" })
        XCTAssertEqual(friday["deadlines"]?.array?.compactMap { $0["title"]?.string }, ["Kurzklausur"])
        // dieselbe Kurzklausur aus der Ankuendigung steht nicht noch einmal als Hinweis da
        XCTAssertEqual(friday["notices"]?.array?.count, 0)
        let dash = try await get(b, "/api/dashboard")
        let up = dash["upcoming"]?.array ?? []
        XCTAssertEqual(up.prefix(3).compactMap { $0["title"]?.string }, ["Abgabe Blatt 3", "Kurztestat 1", "Kurztestat 2"])
        XCTAssertEqual(up.first?["deadline_id"]?.string?.hasPrefix("due-"), true)
        XCTAssertEqual(up[1]["origin"]?.string, "erkannt in Uebung07.pdf, S. 2 und an 1 weiteren Stelle")
        let dl = try await get(b, "/api/deadlines")
        XCTAssertEqual(dl["deadlines"]?.array?.count, 4)
    }

    func testEmptyDatabaseAndNoTablesBeforeFirstRun() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "luh")
        // Kalender und Uebersicht ohne Tabellen wie bisher (Form der Python-Referenz bleibt)
        let cal = try await get(b, "/api/calendar?start=2026-11-02&end=2026-11-02")
        XCTAssertEqual(cal["days"]?.array?.first?["deadlines"]?.array?.count, 0)
        let exists = try await b.context.database.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='due_hits'")?.int
        XCTAssertEqual(exists, 0, "Tabellen erst bei Bedarf")
        let list = try await get(b, "/api/due")
        XCTAssertEqual(Set(list.object?.keys.map { $0 } ?? []), ["hidden", "items", "refreshed", "today"])
        XCTAssertEqual(list["items"]?.array?.count, 0)
        let r = try await json(b, "POST", "/api/due/refresh")
        XCTAssertEqual(Set(r.object?.keys.map { $0 } ?? []), ["changed", "hits"])
    }

    func testNewPageTextsAreScannedWhenRead() async throws {
        let container = try tempContainer(self)
        let tools = TextTools(["f-neu.pdf": ["Übungsblatt 6", "Abgabe: Mo, 23.11.2026, 12 Uhr"]])
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                            files: LocalFiles(container: container, dataDirectory: "", tools: tools), university: "luh")
        try await exec(b, "INSERT INTO courses(id, title, active) VALUES ('k1', 'Mathe', 1)")
        try await exec(b, "INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES ('f-neu', 'k1', 'f-neu.pdf', ?, 'StudIP/f-neu.pdf', 'pdf')",
                       [.integer(unix("2026-10-26T08:00"))])
        try FileManager.default.createDirectory(at: container.appendingPathComponent("StudIP"), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: container.appendingPathComponent("StudIP/f-neu.pdf"))
        _ = try await json(b, "POST", "/api/due/refresh")
        let before = try await get(b, "/api/due")
        XCTAssertEqual(before["items"]?.array?.count, 0, "noch keine Seitentexte")
        // Oeffnen liest die Seitentexte (PDFKit) und prueft sie gleich
        _ = try await get(b, "/api/files/f-neu/pagetext?page=2")
        let items = try await get(b, "/api/due")["items"]?.array ?? []
        XCTAssertEqual(items.map { "\($0["date"]?.string ?? "") \($0["time"]?.string ?? "") \($0["title"]?.string ?? "")" },
                       ["2026-11-23 12:00 Abgabe Blatt 6"])
    }

    func testBackfillReadsMissingPageTextsOnce() async throws {
        let container = try tempContainer(self)
        let tools = TextTools(["alt.pdf": ["Übungsblatt 4", "Abgabe: 16.11.2026"]])        // kaputt.pdf: nicht lesbar
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                            files: LocalFiles(container: container, dataDirectory: "", tools: tools), university: "luh")
        try await exec(b, "INSERT INTO courses(id, title, active) VALUES ('k1', 'Mathe', 1)")
        try FileManager.default.createDirectory(at: container.appendingPathComponent("StudIP"), withIntermediateDirectories: true)
        for name in ["alt.pdf", "kaputt.pdf"] {
            try await exec(b, "INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES (?, 'k1', ?, ?, ?, 'pdf')",
                           [.text(name), .text(name), .integer(unix("2026-10-01T08:00")), .text("StudIP/\(name)")])
            try Data("%PDF".utf8).write(to: container.appendingPathComponent("StudIP/\(name)"))
        }
        // nicht auf dem Geraet: zaehlt nicht
        try await exec(b, "INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES ('weg', 'k1', 'weg.pdf', 1, NULL, 'pdf')")
        let first = try await json(b, "POST", "/api/due/backfill?limit=20")
        XCTAssertEqual(first["read"]?.int, 1)
        XCTAssertEqual(first["remaining"]?.int, 0, "nicht lesbar: nicht noch einmal")
        let list = try await get(b, "/api/due")
        XCTAssertEqual(list["items"]?.array?.compactMap { $0["title"]?.string }, ["Abgabe Blatt 4"])
        let again = try await json(b, "POST", "/api/due/backfill")
        XCTAssertEqual(again["read"]?.int, 0)
        XCTAssertEqual(tools.readCount, 2, "jede Datei einmal gelesen")
        // ohne Dateiablage: nichts
        let bare = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "luh")
        let none = try await json(bare, "POST", "/api/due/backfill")
        XCTAssertEqual(Set(none.object?.keys.map { $0 } ?? []), ["read", "remaining"])
    }

    // MARK: Uni Hildesheim

    func testHildesheimLearnwebDeadlinesFilesAndForum() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "hildesheim")
        try await exec(b, "INSERT INTO modules(id, name, color, exam_date) VALUES (5, 'Einführung in die Informatik', '#9333ea', '2027-02-10')")
        try await exec(b, "INSERT INTO courses(id, title, semester, kind, active, module_id) VALUES ('lw-35', 'Einführung in die Informatik', 'WiSe 2026/27', 'vorlesung', 1, 5)")
        // Learnweb-Frist der Aufgabe und dieselbe Abgabe im PDF: nur einmal (die Learnweb-Frist)
        let deadline = Learnweb.Deadline(id: "lw-ev-77", courseID: "lw-35", title: "Aufgabe 3 hochladen", fullTitle: "Aufgabe 3 hochladen",
                                         kind: "abgabe", module: "assign", dueAt: "2026-11-12T23:59", url: "https://learnweb.example.test/mod/assign/view.php?id=9",
                                         overdue: false)
        try await b.context.database.transaction { c in
            _ = try UniStore.storeDeadlines(c, [deadline], fetchedAt: "2026-10-27T09:00:00", windowFrom: "2026-06-29T00:00")
        }
        try await addFile(b, id: "lw-file-5", name: "Aufgabenblatt3.pdf", course: "lw-35",
                          pages: ["Aufgabenblatt 3\nAbgabe bis 12.11.2026, 23:59 Uhr im Learnweb", "Das Testat findet am 19.11.2026 statt."])
        // Klausur steht schon als Klausurtermin im Modul
        try await addFile(b, id: "lw-file-6", name: "Organisation.pdf", course: "lw-35", pages: ["Die Klausur findet am 10.02.2027 statt."])
        // Learnweb-Ankuendigungsforum
        let post = Announcements.fromMoodleDiscussion(
            ["id": 501, "discussion": 88, "created": .number(Double(unix("2026-10-26T14:00"))), "subject": "Anmeldung Testat",
             "message": "<p>Anmeldung zum Testat bis 16.11.2026 im Learnweb.</p>", "userfullname": "Erfundene Lehrkraft"],
            courseID: "lw-35", base: "https://learnweb.example.test", today: BerlinClock.parseISODate("2026-10-27")!)!
        try await b.context.database.transaction { c in _ = try Announcements.store(c, [post], source: "learnweb", fetchedAt: "2026-10-27T09:00:00") }

        _ = try await json(b, "POST", "/api/due/refresh")
        let items = try await get(b, "/api/due")["items"]?.array ?? []
        XCTAssertEqual(items.map { "\($0["date"]?.string ?? "") \($0["source"]?.string ?? "") \($0["title"]?.string ?? "")" },
                       ["2026-11-12 learnweb Aufgabe 3 hochladen", "2026-11-16 dokument Anmeldung", "2026-11-19 dokument Testat",
                        "2027-02-10 modul Klausur Einführung in die Informatik"])
        let reg = items[1]
        XCTAssertEqual(reg["origin"]?.string, "erkannt in der Ankündigung „Anmeldung Testat“")
        XCTAssertEqual(reg["url"]?.string, "https://learnweb.example.test/mod/forum/discuss.php?d=88")
        XCTAssertEqual(reg["file_id"], .null)
        // Kalender: die Learnweb-Frist einmal, nicht noch einmal erkannt
        let cal = try await get(b, "/api/calendar?start=2026-11-12&end=2026-11-12")
        XCTAssertEqual(cal["days"]?.array?.first?["deadlines"]?.array?.compactMap { $0["id"]?.string }, ["lw-ev-77"])
        // Zeitraum der Uni Hildesheim: WiSe ab 19.10. (Lauf 21 Tage davor)
        let w = try await b.context.database.withConnection { [clock] in try DueStore.window($0, clock: clock) }
        XCTAssertEqual(w.map { BerlinClock.isoDate($0.from) }, "2026-09-28")
    }

    // MARK: Laufzeit

    /// Viele Seiten (Informatik-Skripte: "Test" auf fast jeder Seite, viele Zahlen): ein ganzer Lauf bleibt kurz
    func testFullRefreshOverManyPagesIsFast() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "luh")
        try await exec(b, "INSERT INTO courses(id, title, active) VALUES ('k1', 'Softwaretechnik', 1)")
        let filler = String(repeating: "Unit-Tests prüfen Methoden, Version 2.1.3 vom Skript, Satz 4.2. und Lemma 3.11. mit 12.5 % Abdeckung. ", count: 30)
        try await b.context.database.transaction { [clock] c in
            for f in 0..<100 {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES (?, 'k1', ?, ?, ?, 'pdf')",
                              [.text("f\(f)"), .text("Skript \(f).pdf"), .integer(Int64(clock.now.timeIntervalSince1970) - 86400), .text("StudIP/f\(f).pdf")])
                for p in 1...20 {
                    let text = filler + (p == 7 ? "\nAbgabe des Projekts bis 20.11.2026, 12:00 Uhr" : "")
                    try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?,?,?,?,?)",
                                  [.text("f\(f)"), .integer(Int64(p)), .text(text), .integer(Int64(clock.now.timeIntervalSince1970) - 86400),
                                   .text(ScriptSearch.searchForm(text))])
                }
            }
        }
        let start = Date()
        let r = try await json(b, "POST", "/api/due/refresh")
        let seconds = Date().timeIntervalSince(start)
        print("Abgaben erkennen, 2000 Seiten zu 3 KB: \(String(format: "%.2f", seconds)) s")
        XCTAssertEqual(r["hits"]?.int, 100)
        let list = try await get(b, "/api/due")
        XCTAssertEqual(list["items"]?.array?.count, 1, "100 Fundstellen, ein Termin")
        XCTAssertLessThan(seconds, 30, "Debug-Build; im Release deutlich schneller")
        // naechster Abgleich ohne neue Dateien: nichts neu zu erkennen
        let again = Date()
        let r2 = try await json(b, "POST", "/api/due/refresh")
        XCTAssertEqual(r2["changed"], false)
        XCTAssertEqual(r2["hits"]?.int, 100)
        XCTAssertLessThan(Date().timeIntervalSince(again), 2)
    }

    // MARK: Trennung je Container

    func testContainersAreSeparate() async throws {
        let luh = try await luhBackend()
        let hi = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock, university: "hildesheim")
        _ = try await json(luh, "POST", "/api/due/refresh")
        _ = try await json(hi, "POST", "/api/due/refresh")
        let a = try await get(luh, "/api/due")["items"]?.array ?? []
        let h = try await get(hi, "/api/due")["items"]?.array ?? []
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(h.count, 0)
        // ausblenden in einem Container aendert den anderen nicht (eigene Datenbank)
        let id = try XCTUnwrap(a.first?["id"]?.string)
        let r = await call(hi, "PATCH", "/api/due/\(id)", ["hidden": true])
        XCTAssertEqual(r.status, 404)
        // Erinnerungen: Kennungen je Container, ein Wechsel nimmt die des anderen zurueck
        let now = Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: "2026-10-27T10:00")!))
        let planLUH = DueReminders.plan(DueReminders.items(from: try await get(luh, "/api/due")), container: "AAA", now: now)
        XCTAssertTrue(planLUH.allSatisfy { $0.identifier.hasPrefix("de.uniflow.ai.due.AAA.") })
        let planHI = DueReminders.plan(DueReminders.items(from: try await get(hi, "/api/due")), container: "BBB", now: now)
        let d = DueReminders.diff(pending: planLUH.map(\.identifier), planned: planHI)
        XCTAssertEqual(Set(d.remove), Set(planLUH.map(\.identifier)))
        XCTAssertEqual(d.add, [])
    }
}
