import Foundation
import XCTest
@testable import UniFlowCore

/// Audit P73-F3/P73-05 (09.11.2026): Erinnerungen ueber die Zeitumstellung. Die Zeitpunkte sind Berliner Wanduhr
/// (8:00 am Morgen, 2 Stunden vor der Uhrzeit), auch wenn zwischen Erinnerung und Frist die Uhr umgestellt wird; eine
/// 23:59-Abgabe rutscht nie auf den naechsten Tag. Erwartet als feste UTC-Zeitpunkte (unabhaengig von der Zeitzone des
/// Geraets: eine Reise aendert die Frist in Berlin nicht).
final class DueRemindersDSTTests: XCTestCase {
    private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testSpringForward2027WithA2359Deadline() {
        let item = DueReminders.Item(id: "a", title: "Abgabe", date: "2027-03-29", time: "23:59")
        let plan = DueReminders.plan([item], container: "C", now: utc("2027-03-01T00:00:00Z"))
        XCTAssertEqual(plan.map(\.identifier), ["C.a.d3", "C.a.d1", "C.a.d0", "C.a.h2"].map { DueReminders.prefix + $0 })
        XCTAssertEqual(plan.map(\.fireAt), [utc("2027-03-26T07:00:00Z"),      // Fr 8:00 MEZ
                                            utc("2027-03-28T06:00:00Z"),      // So 8:00 MESZ (Umstellung 2:00)
                                            utc("2027-03-29T06:00:00Z"),      // Mo 8:00 MESZ
                                            utc("2027-03-29T19:59:00Z")])     // Mo 21:59 MESZ, gleicher Tag
    }

    func testFallBack2026() {
        let item = DueReminders.Item(id: "b", title: "Klausur", date: "2026-10-26", time: "12:00")
        let plan = DueReminders.plan([item], container: "C", now: utc("2026-10-01T00:00:00Z"))
        XCTAssertEqual(plan.map(\.fireAt), [utc("2026-10-23T06:00:00Z"),      // Fr 8:00 MESZ
                                            utc("2026-10-25T07:00:00Z"),      // So 8:00 MEZ (Umstellung 3:00)
                                            utc("2026-10-26T07:00:00Z"),      // Mo 8:00 MEZ
                                            utc("2026-10-26T09:00:00Z")])     // Mo 10:00 MEZ
    }
}
