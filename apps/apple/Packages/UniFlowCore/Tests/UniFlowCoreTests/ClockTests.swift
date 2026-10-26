import Foundation
import XCTest
@testable import UniFlowCore

/// Uhr in Ortszeit Berlin, unabhaengig von der Zeitzone des Geraets.
final class ClockTests: XCTestCase {

    private func utc(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func testNowISOLikePythonNowISO() {
        let c = UniFlowClock.fixed(utc("2026-10-25T13:30:05Z"))       // nach der Umstellung: MEZ (+1)
        XCTAssertEqual(c.nowISO, "2026-10-25T14:30:05")
        XCTAssertEqual(c.today, "2026-10-25")
        XCTAssertEqual(c.weekday, 6, "Sonntag")
        XCTAssertEqual(c.weekStart, "2026-10-19")
        XCTAssertEqual(c.minutesOfDay, 14 * 60 + 30)

        let summer = UniFlowClock.fixed(utc("2026-07-01T10:00:00Z"))   // MESZ (+2)
        XCTAssertEqual(summer.nowISO, "2026-07-01T12:00:00")
        XCTAssertEqual(summer.weekday, 2)
        XCTAssertEqual(summer.weekStart, "2026-06-29")
    }

    func testDayBoundaryFollowsBerlinNotUTC() {
        let c = UniFlowClock.fixed(utc("2026-01-15T23:30:00Z"))
        XCTAssertEqual(c.today, "2026-01-16")
        XCTAssertEqual(c.nowISO, "2026-01-16T00:30:00")
        XCTAssertEqual(c.minutesOfDay, 30)
        // Montag 00:30 Ortszeit ist noch Sonntag in UTC: die Woche beginnt trotzdem am Montag
        let monday = UniFlowClock.fixed(utc("2026-10-25T23:30:00Z"))
        XCTAssertEqual(monday.today, "2026-10-26")
        XCTAssertEqual(monday.weekStart, "2026-10-26")
        XCTAssertEqual(monday.weekday, 0)
    }

    func testFractionalSecondsAreDropped() {
        let base = utc("2026-03-01T08:00:00Z").timeIntervalSince1970
        XCTAssertEqual(UniFlowClock.fixed(Date(timeIntervalSince1970: base + 0.999)).nowISO, "2026-03-01T09:00:00")
        XCTAssertEqual(UniFlowClock.fixed(Date(timeIntervalSince1970: base - 0.001)).nowISO, "2026-03-01T08:59:59")
    }

    func testFixedBerlinLocalTime() {
        XCTAssertEqual(UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")?.now, utc("2026-10-25T13:30:05Z"))
        XCTAssertEqual(UniFlowClock.fixed(berlin: "2026-07-01 12:00")?.now, utc("2026-07-01T10:00:00Z"))
        XCTAssertEqual(UniFlowClock.fixed(berlin: "2026-10-12")?.nowISO, "2026-10-12T00:00:00")
        // doppelte Stunde im Oktober: die erste (Sommerzeit); fehlende Stunde im Maerz: nach vorn geschoben
        XCTAssertEqual(UniFlowClock.fixed(berlin: "2026-10-25T02:30")?.now, utc("2026-10-25T00:30:00Z"))
        XCTAssertEqual(UniFlowClock.fixed(utc("2026-10-25T01:30:00Z")).nowISO, "2026-10-25T02:30:00", "zweite 02:30 (MEZ)")
        XCTAssertEqual(UniFlowClock.fixed(berlin: "2026-03-29T02:30")?.nowISO, "2026-03-29T03:30:00")
        for bad in ["", "abc", "2026-13-01", "2026-02-30", "2026-10-25T24:00", "2026-10-25T1:00", "2026-10-25T10:60",
                    "2026-10-25T10:00:61", "2026-10-25T+1:00", "2026-10-25T10:00:00Z", "2026-10-25T10:00:00:00"] {
            XCTAssertNil(UniFlowClock.fixed(berlin: bad), bad)
        }
    }

    func testMatchesFoundationTimeZoneOverSeveralYears() throws {
        guard let tz = TimeZone(identifier: "Europe/Berlin") else { throw XCTSkip("keine Zeitzonendaten") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = utc("2025-01-01T00:00:00Z").timeIntervalSince1970
        // alle 7 Stunden 13 Minuten ueber gut drei Jahre: trifft jede Uhrzeit und alle Umstellungen in der Naehe
        var t = start
        while t < start + 3.2 * 365 * 86400 {
            let date = Date(timeIntervalSince1970: t)
            let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let expected = String(format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
            XCTAssertEqual(UniFlowClock.fixed(date).nowISO, expected)
            t += 7 * 3600 + 13 * 60
        }
    }

    func testSystemClockIsNow() {
        XCTAssertLessThan(abs(UniFlowClock.system.now.timeIntervalSinceNow), 5)
        let custom = UniFlowClock { Date(timeIntervalSince1970: 0) }
        XCTAssertEqual(custom.nowISO, "1970-01-01T01:00:00")
    }
}
