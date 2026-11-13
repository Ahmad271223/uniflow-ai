import Foundation
import XCTest
@testable import UniFlowCore

/// Auftrag 12.11.2026: "Zeig bitte immer die richtigen Module an, wenn man auf ein Fach klickt im Planer; es sollen
/// nicht alle VL-Wochen rein angezeigt werden."
///
/// Zwei Module mit je Vorlesung und Uebung, Dateien in fuenf Lehrwochen. Die Uebung zu Mathematik II lag zuerst
/// (falsch geraten) unter Mathematik I; ihr Termin wurde dabei mit Modul 1 uebernommen, danach hat der Nutzer den Kurs
/// Mathematik II zugeordnet. Vorher blieb der Termin bei Modul 1: "Zum Modul" oeffnete das falsche Fach.
final class ModuleFocusTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-12T10:00:00")!

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Mathematik I', '#175ee8', 0), (2, 'Mathematik II', '#16a34a', 1)")
            for (id, title, kind, module) in [("m1-vl", "Mathematik I", "vorlesung", 1), ("m1-ue", "Übung zu Mathematik I", "uebung", 1),
                                              ("m2-vl", "Mathematik II", "vorlesung", 2), ("m2-ue", "Übung zu Mathematik II", "uebung", 1)] {
                try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES (?,?,?,?,1,?,'t')",
                              [.text(id), .text(title), .text(module == 1 ? "Mathematik I" : "Mathematik II"), .text(kind), .integer(Int64(module))])
            }
            // je Woche (Montag 12.10. = Woche 1) eine Datei je Vorlesung
            let names = ["Einführung", "Folgen", "Reihen", "Stetigkeit", "Ableitung"]
            for (i, n) in names.enumerated() {
                let day = try XCTUnwrap(BerlinClock.parseISODate("2026-10-13")) + 7 * i
                for (course, prefix) in [("m1-vl", "M1"), ("m2-vl", "M2")] {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)",
                                  [.text("\(prefix)-\(i + 1)"), .text(course), .text("\(prefix) \(n).pdf"),
                                   .integer(Int64(BerlinClock.utcSeconds(day: day, minutes: 600)))])
                }
            }
        }
        // Termin der Uebung, beim Import mit dem damals geratenen Modul 1
        let created = await b.handle(LocalRequest(method: "POST", path: "/api/timetable/events", body: Data("""
            {"title": "Übung zu Mathematik II", "kind": "uebung", "weekday": 3, "start_time": "12:00", "end_time": "13:30",
             "rrule": "weekly", "module_id": 1, "course_id": "m2-ue"}
            """.utf8)))
        XCTAssertEqual(created.status, 200, String(decoding: created.body, as: UTF8.self))
        // Nutzer ordnet den Kurs dem richtigen Modul zu
        let moved = await b.handle(LocalRequest(method: "POST", path: "/api/courses/m2-ue/module", body: Data(#"{"module_id": 2}"#.utf8)))
        XCTAssertEqual(moved.status, 200)
        return b
    }

    private func get(_ b: LocalBackend, _ path: String) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!))
        XCTAssertEqual(r.status, 200, "\(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return try XCTUnwrap(r.json, path)
    }

    /// Termin, Vorkommen im Lernkalender und im Stundenplan, Unterlagen zum Termin: ueberall das Modul des Kurses
    func testEventFollowsCourseModule() async throws {
        let b = try await backend()
        let series = try await get(b, "/api/timetable/events").array?.first
        XCTAssertEqual(series?["module_id"], 2, "Serie: Modul des Kurses statt des beim Import geratenen")
        XCTAssertEqual(series?["module_name"], "Mathematik II")
        XCTAssertNil(series?["module_ref"], "Hilfsspalte nicht in der Antwort")
        let day = try await get(b, "/api/timetable/day?date=2026-11-05")
        let occ = day["events"]?.array?.first { $0["title"] == "Übung zu Mathematik II" }
        XCTAssertEqual(occ?["module_id"], 2)
        XCTAssertEqual(occ?["module_name"], "Mathematik II")
        XCTAssertEqual(occ?["color"], "#16a34a", "Farbe des richtigen Moduls")
        let cal = try await get(b, "/api/calendar?start=2026-11-02&end=2026-11-08")
        let calOcc = cal["days"]?.array?.flatMap { $0["events"]?.array ?? [] }.first { $0["title"] == "Übung zu Mathematik II" }
        XCTAssertEqual(calOcc?["module_id"], 2, "Lernkalender (Modulfilter, Zum Modul)")
        let id = try XCTUnwrap(series?["id"]?.int)
        let mats = try await get(b, "/api/timetable/event-materials/\(id)?date=2026-11-05").array ?? []
        XCTAssertEqual(mats.compactMap { $0["id"]?.string }, ["M2-4"], "Unterlagen aus Mathematik II, Woche des Termins")
    }

    /// Termin ohne Kurs behaelt sein eigenes Modul; Kurs ohne Modul ebenso
    func testEventWithoutCourseModuleKeepsOwn() async throws {
        let b = try await backend()
        let r = await b.handle(LocalRequest(method: "POST", path: "/api/timetable/events", body: Data("""
            {"title": "Lerngruppe", "kind": "sonstiges", "weekday": 1, "start_time": "16:00", "end_time": "17:00", "rrule": "weekly", "module_id": 1}
            """.utf8)))
        XCTAssertEqual(r.status, 200)
        let own = try await get(b, "/api/timetable/events").array?.first { $0["title"] == "Lerngruppe" }
        XCTAssertEqual(own?["module_id"], 1)
        XCTAssertEqual(own?["module_name"], "Mathematik I")
    }

    /// `?date=` und `?file=`: Lehrwoche des Termins bzw. der Datei einer Aufgabe; ohne beides kein `focus_week`
    func testFocusWeek() async throws {
        let b = try await backend()
        let plain = try await get(b, "/api/modules/2")
        XCTAssertNil(plain["focus_week"], "Antwort wie in Python")
        XCTAssertEqual(plain["weeks"]?.array?.compactMap { $0["week"]?.int }, [1, 2, 3, 4, 5])
        let byDate = try await get(b, "/api/modules/2?date=2026-11-05")
        XCTAssertEqual(byDate["focus_week"], 4, "Do 05.11. liegt in Woche 4 (02.11.–08.11.)")
        let byFile = try await get(b, "/api/modules/2?date=2026-11-12&file=M2-2")
        XCTAssertEqual(byFile["focus_week"], 2, "Aufgabe zur Datei aus Woche 2 geht vor dem Tag des Pakets")
        let foreign = try await get(b, "/api/modules/2?date=2026-11-12&file=M1-2")
        XCTAssertEqual(foreign["focus_week"], 5, "Datei eines anderen Moduls: Tag des Pakets")
    }
}
