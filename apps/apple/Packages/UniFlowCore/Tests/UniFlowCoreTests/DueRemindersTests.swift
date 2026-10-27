import Foundation
import XCTest
@testable import UniFlowCore

/// Erinnerungsplan (`DueReminders`): Zeitpunkte 3 Tage, 1 Tag und am Morgen um 8:00, mit Uhrzeit 2 Stunden vorher;
/// nur kuenftige, hoechstens 60, Kennungen je Container, Ersetzen und Zuruecknehmen.
final class DueRemindersTests: XCTestCase {

    private func at(_ local: String) -> Date { Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: local)!)) }

    private func local(_ d: Date) -> String { String(BerlinClock.localISO(utc: Int(d.timeIntervalSince1970)).prefix(16)) }

    private let now = Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: "2026-10-27T10:00")!))

    func testTimesWithAndWithoutTime() {
        let items = [DueReminders.Item(id: "due-a", title: "Abgabe Blatt 3", date: "2026-11-05", time: "23:59", course: "Lineare Algebra",
                                       origin: "erkannt in Blatt3.pdf, S. 1", route: "#/doc/f-blatt"),
                     DueReminders.Item(id: "due-b", title: "Kurzklausur", date: "2026-12-11")]
        let plan = DueReminders.plan(items, container: "C1", now: now)
        XCTAssertEqual(plan.map { "\($0.identifier) \(local($0.fireAt))" }, [
            "de.uniflow.ai.due.C1.due-a.d3 2026-11-02T08:00",
            "de.uniflow.ai.due.C1.due-a.d1 2026-11-04T08:00",
            "de.uniflow.ai.due.C1.due-a.d0 2026-11-05T08:00",
            "de.uniflow.ai.due.C1.due-a.h2 2026-11-05T21:59",
            "de.uniflow.ai.due.C1.due-b.d3 2026-12-08T08:00",
            "de.uniflow.ai.due.C1.due-b.d1 2026-12-10T08:00",
            "de.uniflow.ai.due.C1.due-b.d0 2026-12-11T08:00",
        ])
        XCTAssertEqual(plan[0].title, "In 3 Tagen: Abgabe Blatt 3")
        XCTAssertEqual(plan[1].title, "Morgen: Abgabe Blatt 3")
        XCTAssertEqual(plan[2].title, "Heute: Abgabe Blatt 3")
        XCTAssertEqual(plan[3].title, "In 2 Stunden: Abgabe Blatt 3")
        XCTAssertEqual(plan[0].body, "Lineare Algebra · Do, 05.11. 23:59 · erkannt in Blatt3.pdf, S. 1")
        XCTAssertEqual(plan[0].route, "#/doc/f-blatt")
        XCTAssertEqual(plan[6].body, "Fr, 11.12.")
        // 8:00 Berlin im Winter = 7:00 UTC
        XCTAssertEqual(plan[4].fireAt.timeIntervalSince1970, TimeInterval(BerlinClock.utcSeconds(day: BerlinClock.parseISODate("2026-12-08")!, minutes: 7 * 60) + 3600))
    }

    func testEarlyTimesAndPastSlots() {
        // 09:00: "2 Stunden vorher" um 7:00 ersetzt den Morgen; 07:00: nichts am Tag selbst (Nacht)
        let early = DueReminders.plan([DueReminders.Item(id: "x", title: "Testat", date: "2026-11-10", time: "09:00"),
                                       DueReminders.Item(id: "y", title: "Testat", date: "2026-11-11", time: "07:00")], container: "C", now: now)
        XCTAssertEqual(early.map { "\($0.itemID).\($0.identifier.split(separator: ".").last!) \(local($0.fireAt))" }, [
            "x.d3 2026-11-07T08:00", "y.d3 2026-11-08T08:00", "x.d1 2026-11-09T08:00", "x.h2 2026-11-10T07:00", "y.d1 2026-11-10T08:00",
        ])
        // vergangene Zeitpunkte fallen weg
        let late = DueReminders.plan([DueReminders.Item(id: "z", title: "Abgabe", date: "2026-10-29", time: "12:00")], container: "C",
                                     now: at("2026-10-28T09:00"))
        XCTAssertEqual(late.map { local($0.fireAt) }, ["2026-10-29T08:00", "2026-10-29T10:00"])
        XCTAssertEqual(DueReminders.plan([DueReminders.Item(id: "p", title: "Alt", date: "2026-10-01")], container: "C", now: now), [])
    }

    func testLimitSixtyEarliestFirst() {
        let items = (0..<30).map { i in DueReminders.Item(id: "i\(i)", title: "Abgabe \(i)", date: BerlinClock.isoDate(BerlinClock.parseISODate("2026-11-01")! + i), time: "12:00") }
        let plan = DueReminders.plan(items, container: "C", now: now)
        XCTAssertEqual(plan.count, 60)
        XCTAssertEqual(DueReminders.limit, 60)
        XCTAssertEqual(plan.map(\.fireAt), plan.map(\.fireAt).sorted())
        XCTAssertEqual(plan.first.map { local($0.fireAt) }, "2026-10-29T08:00")
        // die spaetesten fehlen
        XCTAssertFalse(plan.contains { $0.itemID == "i29" })
        XCTAssertEqual(DueReminders.plan(items, container: "C", now: now, limit: 5).count, 5)
    }

    func testDiffReplacesAndWithdraws() {
        let a = DueReminders.Item(id: "due-a", title: "Abgabe", date: "2026-11-05", time: "12:00")
        let b = DueReminders.Item(id: "due-b", title: "Testat", date: "2026-11-06")
        let first = DueReminders.plan([a, b], container: "C1", now: now)
        // Uhrzeit geaendert: gleiche Kennung, neuer Zeitpunkt (iOS ersetzt); b ausgeblendet: zurueckgenommen
        var changed = a
        changed.time = "16:00"
        let second = DueReminders.plan([changed], container: "C1", now: now)
        let pending = first.map(\.identifier) + ["de.uniflow.ai.sync.files.C1.123", "de.uniflow.ai.due.C2.due-z.d1"]
        let d = DueReminders.diff(pending: pending, planned: second)
        XCTAssertEqual(d.remove, ["de.uniflow.ai.due.C1.due-b.d0", "de.uniflow.ai.due.C1.due-b.d1", "de.uniflow.ai.due.C1.due-b.d3",
                                  "de.uniflow.ai.due.C2.due-z.d1"],
                       "anderer Container und ausgeblendete weg, Mitteilungen des Hintergrundabgleichs bleiben")
        XCTAssertEqual(d.add, second)
        let h2 = second.first { $0.identifier.hasSuffix(".h2") }
        XCTAssertEqual(h2.map { local($0.fireAt) }, "2026-11-05T14:00")
        XCTAssertTrue(first.contains { $0.identifier == h2?.identifier })
    }

    func testItemsFromResponse() {
        let response: JSONValue = ["items": [
            ["id": "due-1", "title": "Kurztestat 1", "date": "2026-11-02", "time": .null, "file_id": "f-ue07", "page": 2,
             "course_title": "Analysis I (Übung)", "origin": "erkannt in Uebung07.pdf, S. 2", "hidden": false],
            ["id": "due-2", "title": "Kurzklausur", "date": "2026-12-11", "hidden": true],
            ["id": "lw-ev-77", "title": "Aufgabe 3 hochladen", "date": "2026-11-12", "time": "23:59", "url": "https://learnweb.example.test/a"],
            ["id": "exam-5", "title": "Klausur Informatik", "date": "2027-02-10", "module_id": 5, "module_name": "Informatik"],
            ["id": "due-3", "title": "Abgabe", "date": "2026-11-05", "file_id": "f-b", "page": 1],
        ]]
        let items = DueReminders.items(from: response)
        XCTAssertEqual(items.map(\.id), ["due-1", "lw-ev-77", "exam-5", "due-3"], "ausgeblendete fehlen")
        XCTAssertEqual(items.map { $0.route ?? "" }, ["#/doc/f-ue07?page=2", "https://learnweb.example.test/a", "#/modules/5", "#/doc/f-b"])
        XCTAssertEqual(items[0].course, "Analysis I (Übung)")
        XCTAssertEqual(items[2].course, "Informatik")
        XCTAssertNil(items[0].time)
        XCTAssertEqual(items[1].time, "23:59")
    }
}
