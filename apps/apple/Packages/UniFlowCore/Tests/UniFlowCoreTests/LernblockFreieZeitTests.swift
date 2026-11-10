import Foundation
import XCTest
@testable import UniFlowCore

// Fehlerbericht des Inhabers vom 10.11.2026 (iPad, Lernkalender Woche 9.–15.11.2026): ein Lernblock lag von 09:45 bis
// 17:30 bzw. von 08:00 bis 21:00 quer ueber allen Vorlesungen, weil `assignSlots` ein Paket, das in kein freies Fenster
// am Stueck passte, auf mehrere Fenster verteilte, ihm aber Beginn der ersten und Ende der letzten Aufgabe gab; zu lange
// Aufgaben wurden im zu kleinen Fenster gekappt. Regel: Lernbloecke nie waehrend besuchter Termine, nur in freien
// Luecken; ein Paket = ein Fenster, sonst geteilt. Termine wie im Bericht, Lernzeit 08:00–21:00, Fahrtzeit 30, Pause 15.

private final class Uhr: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ local: String) { date = UniFlowClock.fixed(berlin: local)!.now }
    var clock: UniFlowClock { UniFlowClock { [self] in lock.withLock { date } } }
}

final class LernblockFreieZeitTests: XCTestCase {
    private let dienstag = "2026-11-10", mittwoch = "2026-11-11", montag = "2026-11-09"
    private let mfi = "Mathematik für die Ingenieurwissenschaften I"

    // MARK: Hilfen

    private func backend(_ uhr: Uhr) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: uhr.clock)
        try await b.context.database.transaction { c in
            // Termine wie im Screenshot (Wochentag 0 = Montag), alle besucht
            let termine: [(Int, String, String, String)] = [
                (1, "Ü DSA", "08:15", "09:45"), (1, "Ü Numerik", "10:15", "11:45"), (1, "GGAW 2", "12:15", "13:45"),
                (1, "Ü Numerik (2)", "13:45", "15:15"), (1, "SigSys", "15:30", "16:15"), (1, "Ü Mathe", "18:00", "19:30"),
                (2, "EGI", "09:45", "11:15"), (2, "Ü EGI", "11:30", "13:00"), (2, "Ü Numerik", "12:15", "13:45"),
                (2, "Info", "14:15", "15:45"), (2, "Mathe I", "18:15", "19:45"),
                (0, "Ü Montag", "08:15", "09:45"),
            ]
            for (tag, titel, von, bis) in termine {
                try c.execute("""
                    INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at)
                    VALUES (NULL, NULL, ?, 'vorlesung', ?, ?, ?, '', '', 'weekly', NULL, NULL, 1, 'manual', NULL, '2026-10-01T09:00:00')
                    """, [.text(titel), .integer(Int64(tag)), .text(von), .text(bis)])
            }
        }
        await send(b, "PUT", "/api/settings", ["learn_start": "08:00", "learn_end": "21:00", "travel_minutes": 30, "break_minutes": 15, "min_slot_minutes": 30])
        return b
    }

    @discardableResult
    private func send(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      query: [LocalRequest.QueryItem] = [], file: StaticString = #filePath, line: UInt = #line) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, path: path, query: query, body: body.map { $0.serialized() } ?? Data()))
        XCTAssertEqual(r.status, 200, "\(method) \(path): \(String(data: r.body, encoding: .utf8) ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    /// Paket mit Aufgaben (Titel, Minuten) ohne Uhrzeit anlegen
    @discardableResult
    private func paket(_ b: LocalBackend, _ uhr: Uhr, _ tag: String, _ fach: String, _ titel: String, _ aufgaben: [(String, Int)]) async throws -> Int64 {
        try await b.context.database.transaction { c in
            try StudyPlan.insertPackage(c, day: BerlinClock.parseISODate(tag)!, moduleID: .null, subject: .text(fach), title: .text(titel), weekNo: .integer(4),
                                        tasks: aufgaben.map { StudyPlan.NewTask(type: "vorlesung", fileID: .null, title: .text($0.0), est: $0.1) }, clock: uhr.clock)
        }
    }

    private func slots(_ b: LocalBackend, _ tag: String) async throws {
        try await b.context.database.transaction { try StudyPlan.assignSlots($0, day: BerlinClock.parseISODate(tag)!) }
    }

    private func pakete(_ b: LocalBackend, _ tag: String) async throws -> [[String: JSONValue]] {
        try await b.context.database.withConnection { c in
            try c.rows("SELECT * FROM study_packages WHERE date=? ORDER BY start_time, id", [.text(tag)])
        }
    }

    private func aufgaben(_ b: LocalBackend, paket: JSONValue?) async throws -> [[String: JSONValue]] {
        try await b.context.database.withConnection { c in
            try c.rows("SELECT * FROM study_tasks WHERE package_id=? ORDER BY sort", [SQLiteValue(json: paket ?? .null) ?? .null])
        }
    }

    private func m(_ v: JSONValue?) -> Int { (try? LocalFreeWindows.hm(v, key: "t")) ?? -1 }

    /// Die Regel des Inhabers fuer einen Tag: kein offenes Paket ueberschneidet einen besuchten Termin, eine Sperrzeit,
    /// die Fahrtzeit oder ein anderes Lernpaket; jede offene Aufgabe hat ihre volle Dauer und liegt in ihrem Paket
    /// (ein Paket = ein zusammenhaengendes freies Fenster)
    private func pruefeTag(_ b: LocalBackend, _ tag: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let d = try XCTUnwrap(BerlinClock.parseISODate(tag))
        let belegt = try await b.context.database.withConnection { c -> [(Int, Int, String)] in
            let s = try LocalSettings.read(c)
            let bl = try LocalFreeWindows.busyBlocks(c, day: d, settings: s, includePackages: false)
            var out = bl.map { ($0.start, $0.end, "\($0.kind) \(LocalModules.truthy($0.title) ? ($0.title.string ?? "") : "")") }
            let ev = bl.filter { $0.kind == "event" }
            if let f = ev.first, let l = ev.last {
                out.append((f.start - 30, f.start, "Fahrtzeit"))
                out.append((l.end, l.end + 30, "Fahrtzeit"))
            }
            return out
        }
        let ps = try await pakete(b, tag).filter { LocalModules.truthy($0["start_time"]) && !["verschoben", "uebersprungen", "erledigt"].contains($0["status"]?.string ?? "") }
        for p in ps {
            let a = m(p["start_time"]), e = m(p["end_time"])
            let name = "Paket \(p["id"]?.int ?? 0) \(p["title"]?.string ?? "") \(LocalFreeWindows.mh(a))–\(LocalFreeWindows.mh(e))"
            for (bs, be, was) in belegt where a < be && e > bs {
                XCTFail("\(tag): \(name) liegt in \(was) \(LocalFreeWindows.mh(bs))–\(LocalFreeWindows.mh(be))", file: file, line: line)
            }
            for q in ps where q["id"] != p["id"] && a < m(q["end_time"]) && e > m(q["start_time"]) {
                XCTFail("\(tag): \(name) ueberschneidet Paket \(q["id"]?.int ?? 0)", file: file, line: line)
            }
            let ts = try await aufgaben(b, paket: p["id"]).filter { !["erledigt", "uebersprungen", "verschoben"].contains($0["status"]?.string ?? "") }
            XCTAssertFalse(ts.isEmpty, "\(name) ohne offene Aufgabe", file: file, line: line)
            for t in ts {
                let s = m(t["start_time"]), en = m(t["end_time"])
                XCTAssertEqual(en - s, t["est_minutes"]?.int, "\(name): Aufgabe \(t["title"]?.string ?? "") gekappt", file: file, line: line)
                XCTAssertTrue(a <= s && en <= e, "\(name): Aufgabe \(t["title"]?.string ?? "") \(LocalFreeWindows.mh(s))–\(LocalFreeWindows.mh(en)) ausserhalb",
                              file: file, line: line)
            }
            XCTAssertEqual(ts.map { $0["est_minutes"]?.int ?? 0 }.reduce(0, +), p["planned_minutes"]?.int, "\(name): geplante Minuten", file: file, line: line)
        }
    }

    // MARK: Faelle aus dem Bericht

    /// Di 10.11.: "Mathematik fuer die Ingenieurwissenschaften I" mit zwei 45-min-Aufgaben passt nicht am Stueck (das
    /// Fenster 16:15–18:00 ist schon angebrochen) -> zwei Pakete in zwei freien Fenstern, keine Aufgabe gekappt
    func testDienstagMathePaketWirdGeteiltStattUeberVorlesungen() async throws {
        let uhr = Uhr("2026-11-10T07:30:00")
        let b = try await backend(uhr)
        try await paket(b, uhr, dienstag, "Signale und Systeme", "Lehrwoche 4", [("Kapitel 4 lesen", 45)])     // 16:15–17:00
        let id = try await paket(b, uhr, dienstag, mfi, "Lehrwoche 4: Folien", [("Folien-MfI1_zum_drucken.pdf", 45), ("Folien-MfI1.pdf", 45)])
        try await slots(b, dienstag)
        try await pruefeTag(b, dienstag)

        let teile = try await pakete(b, dienstag).filter { $0["subject"]?.string == mfi }
        XCTAssertEqual(teile.count, 2, "Paket geteilt: \(teile)")
        XCTAssertTrue(teile.contains { $0["id"]?.int == Int(id) }, "erster Teil bleibt im Paket")
        for t in teile {
            XCTAssertEqual(t["title"], "Lehrwoche 4: Folien")
            XCTAssertEqual(t["week_no"]?.int, 4)
            XCTAssertEqual(t["generated"]?.int, 1)
            XCTAssertEqual(t["status"], "geplant")
        }
        let alle = try await aufgaben(b, paket: teile[0]["id"]) + aufgaben(b, paket: teile[1]["id"])
        XCTAssertEqual(alle.map { $0["title"]?.string ?? "" }, ["Folien-MfI1_zum_drucken.pdf", "Folien-MfI1.pdf"], "Reihenfolge bleibt")
        XCTAssertEqual(alle.map { "\($0["start_time"]?.string ?? "")–\($0["end_time"]?.string ?? "")" }, ["17:15–18:00", "20:00–20:45"])
    }

    /// Mi 11.11.: "Programmieren I · Lehrwoche 4: Uebungen" mit zwei 60-min-Aufgaben: die erste vor der ersten
    /// Vorlesung, die zweite passt in kein Fenster mehr -> hinter den letzten Termin samt Heimfahrt, volle 60 min
    func testMittwochProgrammierenNieUeberTermineUndNichtGekappt() async throws {
        let uhr = Uhr("2026-11-10T07:30:00")
        let b = try await backend(uhr)
        try await paket(b, uhr, mittwoch, "Mathematik", "Lehrwoche 4", [("Blatt 4", 90)])
        try await paket(b, uhr, mittwoch, "Programmieren I", "Lehrwoche 4: Übungen", [("Hörsaalübung 04", 60), ("WSL einrichten", 60)])
        try await slots(b, mittwoch)
        try await pruefeTag(b, mittwoch)

        let teile = try await pakete(b, mittwoch).filter { $0["subject"]?.string == "Programmieren I" }
        XCTAssertEqual(teile.map { "\($0["start_time"]?.string ?? "")–\($0["end_time"]?.string ?? "")" }, ["08:00–09:00", "20:15–21:15"])
        XCTAssertEqual(teile.map { $0["planned_minutes"]?.int ?? 0 }, [60, 60])
    }

    /// Ein Termin "nicht besucht" gibt seine Zeit frei: dort darf der Lernblock liegen (am Stueck, ungeteilt). Wird er
    /// wieder besucht, legt der Lernkalender den Block beim naechsten Oeffnen neu, ohne Ueberschneidung
    func testNichtBesuchterTerminIstFreiUndWiederBesuchtWirdNeuGelegt() async throws {
        let uhr = Uhr("2026-11-10T07:30:00")
        let b = try await backend(uhr)
        let numerik = try await b.context.database.withConnection { try $0.scalar("SELECT id FROM course_events WHERE title='Ü Numerik' AND weekday=1")?.int ?? 0 }
        await send(b, "POST", "/api/timetable/attendance", ["event_id": .number(Double(numerik)), "date": .string(dienstag), "mode": "today_skip"])
        try await paket(b, uhr, dienstag, "Signale und Systeme", "Lehrwoche 4", [("Kapitel 4 lesen", 30)])
        try await paket(b, uhr, dienstag, mfi, "Lehrwoche 4: Folien", [("Folien-MfI1_zum_drucken.pdf", 45), ("Folien-MfI1.pdf", 45)])
        try await slots(b, dienstag)
        try await pruefeTag(b, dienstag)
        var teile = try await pakete(b, dienstag).filter { $0["subject"]?.string == mfi }
        XCTAssertEqual(teile.count, 1, "passt am Stueck in die freie Zeit")
        XCTAssertEqual(teile.first.map { "\($0["start_time"]?.string ?? "")–\($0["end_time"]?.string ?? "")" }, "10:30–12:15", "in der Zeit des nicht besuchten Termins")

        // doch wieder besucht: Woche oeffnen -> neu gelegt ins naechste freie Fenster, nichts ueber einem Termin
        await send(b, "POST", "/api/timetable/attendance", ["event_id": .number(Double(numerik)), "date": .string(dienstag), "mode": "reset"])
        await send(b, "GET", "/api/calendar", query: [.init("start", "2026-11-09"), .init("end", "2026-11-15")])
        try await pruefeTag(b, dienstag)
        teile = try await pakete(b, dienstag).filter { $0["subject"]?.string == mfi }
        XCTAssertEqual(teile.map { "\($0["start_time"]?.string ?? "")–\($0["end_time"]?.string ?? "")" }, ["16:15–18:00"])
        let sig = try await pakete(b, dienstag).first { $0["subject"]?.string == "Signale und Systeme" }
        XCTAssertEqual(sig?["start_time"], "09:45", "konfliktfreier Block bleibt")
    }

    // MARK: Reparatur alter Daten

    /// Alte Pakete mit Uhrzeiten aus dem Fehler (ueber mehrere Fenster, gekappte Aufgaben) werden beim Oeffnen der Woche
    /// neu gelegt; eine von Hand gesetzte konfliktfreie Uhrzeit, erledigte Pakete und vergangene Tage bleiben. Ein
    /// zweites Oeffnen aendert nichts mehr.
    func testReparaturAlterDatenBeimOeffnenDerWoche() async throws {
        let uhr = Uhr("2026-11-10T07:30:00")
        let b = try await backend(uhr)
        let alt = try await paket(b, uhr, dienstag, mfi, "Lehrwoche 4: Folien", [("Folien-MfI1_zum_drucken.pdf", 45), ("Folien-MfI1.pdf", 45)])
        let hand = try await paket(b, uhr, dienstag, "Eigenes", "Lesen", [("Lesen", 30)])
        let gekappt = try await paket(b, uhr, dienstag, "Physik", "Kapitel 2", [("Kapitel 2", 45)])
        let prog = try await paket(b, uhr, mittwoch, "Programmieren I", "Lehrwoche 4: Übungen", [("Hörsaalübung 04", 60), ("WSL einrichten", 60)])
        let vergangen = try await paket(b, uhr, montag, "Alt", "Montag", [("Montag", 60)])
        try await b.context.database.transaction { c in
            func setze(_ p: Int64, _ a: String, _ e: String, _ aufgaben: [(String, String)]) throws {
                try c.execute("UPDATE study_packages SET start_time=?, end_time=?, generated=? WHERE id=?", [.text(a), .text(e), .integer(p == hand ? 0 : 1), .integer(p)])
                for (i, t) in try c.query("SELECT id FROM study_tasks WHERE package_id=? ORDER BY sort", [.integer(p)]).enumerated() {
                    try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?", [.text(aufgaben[i].0), .text(aufgaben[i].1), t["id"] ?? .null])
                }
            }
            try setze(alt, "09:45", "17:30", [("09:45", "10:15"), ("16:45", "17:30")])      // Screenshot Dienstag
            try setze(hand, "16:15", "16:45", [("16:15", "16:45")])                           // von Hand, frei
            try setze(gekappt, "11:45", "12:15", [("11:45", "12:15")])                        // 45 min gekappt auf 30
            try setze(prog, "08:00", "21:00", [("08:00", "09:00"), ("20:15", "21:00")])       // Screenshot Mittwoch
            try setze(vergangen, "08:00", "09:00", [("08:00", "09:00")])                      // gestern, ueber einem Termin
        }
        await send(b, "GET", "/api/calendar", query: [.init("start", "2026-11-09"), .init("end", "2026-11-15")])
        try await pruefeTag(b, dienstag)
        try await pruefeTag(b, mittwoch)

        let di = try await pakete(b, dienstag)
        let h = try XCTUnwrap(di.first { $0["id"]?.int == Int(hand) })
        XCTAssertEqual([h["start_time"], h["end_time"]], ["16:15", "16:45"], "Uhrzeit von Hand ohne Konflikt bleibt")
        XCTAssertEqual(di.filter { $0["subject"]?.string == mfi }.count, 2, "altes Paket ueber mehrere Fenster geteilt")
        let k = try XCTUnwrap(di.first { $0["id"]?.int == Int(gekappt) })
        XCTAssertEqual(m(k["end_time"]) - m(k["start_time"]), 45, "gekappte Aufgabe hat wieder ihre volle Dauer")
        let mo = try await pakete(b, montag)
        XCTAssertEqual([mo.first?["start_time"], mo.first?["end_time"]], ["08:00", "09:00"], "vergangener Tag bleibt")
        let mi = try await pakete(b, mittwoch).filter { $0["subject"]?.string == "Programmieren I" }
        XCTAssertEqual(mi.map { "\($0["start_time"]?.string ?? "")–\($0["end_time"]?.string ?? "")" }, ["15:45–18:00"], "am Stueck ins freie Fenster")

        // Aufgaben behalten ID und Status, nichts geht verloren
        let n = try await b.context.database.withConnection { try $0.scalar("SELECT COUNT(*) FROM study_tasks")?.int ?? 0 }
        XCTAssertEqual(n, 7)

        // zweites Oeffnen (auch ueber die Uebersicht): stabil
        let vorher = try await b.context.database.withConnection { try $0.rows("SELECT id, package_id, start_time, end_time FROM study_tasks ORDER BY id") }
        await send(b, "GET", "/api/calendar", query: [.init("start", "2026-11-09"), .init("end", "2026-11-15")])
        await send(b, "GET", "/api/dashboard")
        let nachher = try await b.context.database.withConnection { try $0.rows("SELECT id, package_id, start_time, end_time FROM study_tasks ORDER BY id") }
        XCTAssertEqual(vorher, nachher)
        let heute = try XCTUnwrap(BerlinClock.parseISODate(dienstag))
        let fixed = try await b.context.database.transaction { try StudyPlan.repairSlots($0, from: heute, to: heute + 6) }
        XCTAssertEqual(fixed, 0)
    }

    /// Paket mit einer Aufgabe, die laenger ist als jedes freie Fenster (neues Dokument, `insertNewFiles`): nicht
    /// gekappt in ein zu kleines Fenster, sondern hinter den letzten belegten Block
    func testZuLangeAufgabeHinterDenLetztenBlock() async throws {
        let uhr = Uhr("2026-11-10T07:30:00")
        let b = try await backend(uhr)
        try await paket(b, uhr, dienstag, "Signale und Systeme", "Lehrwoche 4", [("Kapitel 4 lesen", 90)])
        let id = try await paket(b, uhr, dienstag, mfi, "Folien", [("Folien-MfI1.pdf", 90)])
        let tag = try XCTUnwrap(BerlinClock.parseISODate(dienstag))
        try await b.context.database.transaction { try StudyPlan.assignSlots($0, day: tag, packageID: .integer(id)) }     // zuerst nur dieses
        try await slots(b, dienstag)
        try await pruefeTag(b, dienstag)
        let ps = try await pakete(b, dienstag)
        let p = try XCTUnwrap(ps.first { $0["id"]?.int == Int(id) })
        XCTAssertEqual([p["start_time"], p["end_time"]], ["16:15", "17:45"], "erstes Fenster mit genug Platz")
        let sig = try XCTUnwrap(ps.first { $0["subject"]?.string == "Signale und Systeme" })
        XCTAssertEqual([sig["start_time"], sig["end_time"]], ["20:00", "21:30"], "hinter dem letzten Termin samt Heimfahrt")
    }

    /// Heute neu gelegt: nie in schon vergangener Zeit. Ein alter Block 09:45–10:30 ueber Ue Numerik (10:15) wird um
    /// 17:00 Uhr repariert und landet nicht im schon vergangenen Fenster ab 16:15, sondern ab jetzt (17:00–17:45).
    func testReparaturHeuteNichtInVergangeneZeit() async throws {
        let uhr = Uhr("2026-11-10T17:00:00")
        let b = try await backend(uhr)
        let id = try await paket(b, uhr, dienstag, mfi, "Woche 5", [("Folien", 45)])
        try await b.context.database.transaction { c in
            try c.execute("UPDATE study_packages SET start_time='09:45', end_time='10:30' WHERE id=?", [.integer(id)])
            try c.execute("UPDATE study_tasks SET start_time='09:45', end_time='10:30' WHERE package_id=?", [.integer(id)])
        }
        await send(b, "GET", "/api/calendar", query: [.init("start", dienstag), .init("end", dienstag)])
        let p = try await pakete(b, dienstag)
        XCTAssertEqual(p.count, 1)
        XCTAssertGreaterThanOrEqual(m(p[0]["start_time"]), 17 * 60, "nicht vor jetzt: \(p[0]["start_time"] ?? .null)")
        XCTAssertEqual(m(p[0]["end_time"]) - m(p[0]["start_time"]), 45)
    }
}
