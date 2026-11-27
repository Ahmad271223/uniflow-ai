import Foundation
import XCTest
@testable import UniFlowCore

/// Auftrag des Inhabers 27.11.2026 (docs/ABRUF-ZWEIMAL-TAEGLICH-2026-11-27.md): Die Hochschul-Portale gleicht die App von
/// selbst nur noch zweimal am Tag ab (ab 8 und ab 14 Uhr, je Geraet versetzt, verpasst bis 18 Uhr nachgeholt,
/// mindestens 2 Stunden Abstand); die Uni-Mail behaelt alle 30 Minuten. Nur erfundene Zeiten, kein Netz.
final class AbrufZweimalTaeglichTests: XCTestCase {
    private let plan = AutoSyncSchedule.twiceDaily

    private func zone(_ id: String = "Europe/Berlin") throws -> TimeZone {
        guard let tz = TimeZone(identifier: id) else { throw XCTSkip("keine Zeitzonendaten fuer \(id)") }
        return tz
    }

    private func at(_ text: String, _ tz: TimeZone) throws -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(f.date(from: text), text)
    }

    private func local(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private func hhmm(_ d: Date, _ tz: TimeZone) -> String { String(local(d, tz).suffix(8).prefix(5)) }

    private func freshDefaults() -> UserDefaults {
        let name = "abruf-zweimal-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// Minute fuer Minute ueber einen Tag: wann startet ein Abgleich von selbst? (`firstOpen`: App erst ab dann offen)
    private func simulate(_ plan: AutoSyncSchedule, day: String = "2026-11-27", firstOpen: String = "00:00",
                          manual: [String] = [], tz: TimeZone) throws -> [String] {
        var now = try at("\(day) \(firstOpen)", tz)
        let end = try at(day + " 23:59", tz)
        let manualTimes = try manual.map { try at("\(day) \($0)", tz) }
        var last: Date?
        var runs: [String] = []
        while now <= end {
            if manualTimes.contains(now) { last = now }
            if plan.isDue(last: last, now: now, timeZone: tz) {
                last = now
                runs.append(hhmm(now, tz))
            }
            now = now.addingTimeInterval(60)
        }
        return runs
    }

    // MARK: Die Zahlen an einer Stelle

    func testTwiceDailyNumbers() {
        XCTAssertEqual(plan.startHour, 8)
        XCTAssertEqual(plan.endHour, 18)
        XCTAssertEqual(plan.slotHours, [8, 14])
        XCTAssertEqual(plan.interval, 2 * 3600, "Mindestabstand zweier Abgleiche von selbst")
        XCTAssertEqual(plan.runsPerDay, 2)
        XCTAssertTrue(plan.hasSlots)
        XCTAssertFalse(AutoSyncSchedule.standard.hasSlots, "die Uni-Mail bleibt im 30-Minuten-Takt")
        XCTAssertEqual(AutoSyncSchedule.standard.runsPerDay, 20)
        XCTAssertEqual(AutoSyncSchedule.slotSpread, 3600)
    }

    func testSlotHoursOutsideTheWindowAreDropped() {
        let s = AutoSyncSchedule(startHour: 8, endHour: 18, interval: 3600, slotHours: [20, 14, 7, 8, 14])
        XCTAssertEqual(s.slotHours, [8, 14])
    }

    // MARK: Ein Tag mit offener App

    func testAppOpenAllDayGivesExactlyTwoRuns() throws {
        let tz = try zone()
        XCTAssertEqual(try simulate(plan, tz: tz), ["08:00", "14:00"])
    }

    func testOffsetOfTheDeviceShiftsBothSlots() throws {
        let tz = try zone()
        XCTAssertEqual(try simulate(plan.staggered(by: 17 * 60), tz: tz), ["08:17", "14:17"])
        XCTAssertEqual(try simulate(plan.staggered(by: 59 * 60), tz: tz), ["08:59", "14:59"])
        XCTAssertEqual(plan.staggered(by: 59 * 60 + 59).offset, 3599, "hoechstens 59:59 Minuten")
    }

    func testNothingAtNightAndNothingFromEighteen() throws {
        let tz = try zone()
        XCTAssertFalse(plan.isDue(last: nil, now: try at("2026-11-27 07:59", tz), timeZone: tz))
        XCTAssertFalse(plan.isDue(last: nil, now: try at("2026-11-27 18:00", tz), timeZone: tz))
        XCTAssertFalse(plan.isDue(last: nil, now: try at("2026-11-27 23:30", tz), timeZone: tz))
        XCTAssertTrue(plan.isDue(last: nil, now: try at("2026-11-27 17:59", tz), timeZone: tz), "ohne Lauf heute: noch nachholen")
    }

    // MARK: Verpasste Fenster

    func testMissedMorningIsCaughtUpWithTwoHoursGap() throws {
        let tz = try zone()
        XCTAssertEqual(try simulate(plan, firstOpen: "11:00", tz: tz), ["11:00", "14:00"])
        XCTAssertEqual(try simulate(plan, firstOpen: "13:30", tz: tz), ["13:30", "15:30"], "nie zwei naeher als 2 Stunden")
        XCTAssertEqual(try simulate(plan, firstOpen: "17:00", tz: tz), ["17:00"], "nur noch das Nachmittagsfenster")
        XCTAssertEqual(try simulate(plan, firstOpen: "18:30", tz: tz), [], "nach 18 Uhr nur noch Sync")
    }

    // MARK: Sync von Hand

    func testManualSyncCountsForItsSlotAndNeverAddsAutomaticRuns() throws {
        let tz = try zone()
        // Sync um 9 und 10 Uhr: von selbst bleibt es bei 8 und 14 Uhr
        XCTAssertEqual(try simulate(plan, manual: ["09:00", "10:00"], tz: tz), ["08:00", "14:00"])
        // Sync um 7:30 (vor dem Fenster): der Vormittag kommt trotzdem, aber erst 2 Stunden danach
        XCTAssertEqual(try simulate(plan, manual: ["07:30"], tz: tz), ["09:30", "14:00"])
        // Sync um 14:30 bevor die App das Nachmittagsfenster erwischt (erst ab 14:20 offen): der Nachmittag ist erledigt
        XCTAssertEqual(try simulate(plan, firstOpen: "14:20", manual: ["14:20"], tz: tz), [])
        // Sync um 13:00: das Nachmittagsfenster wartet die 2 Stunden ab
        XCTAssertEqual(try simulate(plan, firstOpen: "12:00", manual: ["12:00", "13:00"], tz: tz), ["15:00"])
    }

    // MARK: Naechster Termin

    func testNextRunIsTheNextSlotOrTheEndOfTheGap() throws {
        let tz = try zone()
        let s = plan.staggered(by: 17 * 60)
        func next(_ last: String?, _ now: String) throws -> String {
            local(s.nextRun(last: try last.map { try at($0, tz) }, now: try at(now, tz), timeZone: tz), tz)
        }
        XCTAssertEqual(try next(nil, "2026-11-27 06:00"), "2026-11-27 08:17:00")
        XCTAssertEqual(try next(nil, "2026-11-27 09:00"), "2026-11-27 09:00:00", "noch kein Lauf heute: jetzt")
        XCTAssertEqual(try next("2026-11-27 08:17", "2026-11-27 09:00"), "2026-11-27 14:17:00")
        XCTAssertEqual(try next("2026-11-27 14:17", "2026-11-27 15:00"), "2026-11-28 08:17:00")
        XCTAssertEqual(try next("2026-11-27 13:30", "2026-11-27 14:20"), "2026-11-27 15:30:00", "Mindestabstand")
        XCTAssertEqual(try next("2026-11-27 16:30", "2026-11-27 17:00"), "2026-11-28 08:17:00")
        XCTAssertEqual(try next("2026-11-27 08:17", "2026-11-27 19:00"), "2026-11-28 08:17:00")
    }

    func testClockSetBackCountsAsDue() throws {
        let tz = try zone()
        let now = try at("2026-11-27 10:00", tz)
        XCTAssertTrue(plan.isDue(last: now.addingTimeInterval(3600), now: now, timeZone: tz))
    }

    func testDaylightSavingDayStillTwoRunsAtLocalTime() throws {
        let tz = try zone()
        XCTAssertEqual(try simulate(plan, day: "2026-10-25", tz: tz), ["08:00", "14:00"])
        XCTAssertEqual(try simulate(plan, day: "2026-03-29", tz: tz), ["08:00", "14:00"])
    }

    // MARK: Ledger: Uni-Mail eigener Takt, alle anderen zweimal

    func testLedgerMailEveryThirtyMinutesPortalsTwice() throws {
        let tz = try zone()
        let ledger = AutoSyncLedger(defaults: freshDefaults(), schedule: .twiceDaily, overrides: ["Uni-Mail": .standard])
        var now = try at("2026-11-27 00:00", tz)
        let end = try at("2026-11-28 00:00", tz)
        var runs: [String: [String]] = [:]
        while now < end {
            for p in ["Stud.IP", "QIS", "Uni-Mail"] where ledger.isDue(p, lastSuccess: nil, now: now, timeZone: tz) {
                ledger.recordAttempt(p, at: now, timeZone: tz)
                runs[p, default: []].append(hhmm(now, tz))
            }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(runs["Stud.IP"], ["08:00", "14:00"])
        XCTAssertEqual(runs["QIS"], ["08:00", "14:00"])
        XCTAssertEqual(runs["Uni-Mail"]?.count, 20, "Uni-Mail weiter alle 30 Minuten")
        XCTAssertEqual(runs["Uni-Mail"]?.first, "08:00")
        XCTAssertEqual(runs["Uni-Mail"]?.last, "17:30")
        XCTAssertEqual(ledger.schedule(for: "Uni-Mail"), .standard)
        XCTAssertEqual(ledger.schedule(for: "Learnweb"), .twiceDaily, "jedes neue Portal: zweimal am Tag")
    }

    func testOwnIntervalInsideARunIgnoresTheSlots() throws {
        let tz = try zone()
        let ledger = AutoSyncLedger(defaults: freshDefaults(), schedule: .twiceDaily)
        let last = try at("2026-11-27 08:00", tz)
        // Noten (4 Stunden) innerhalb des Abgleichs der Dateien, der selbst nur zweimal am Tag laeuft
        XCTAssertFalse(ledger.isDue("Noten", lastSuccess: last, now: try at("2026-11-27 11:59", tz), timeZone: tz, interval: 4 * 3600))
        XCTAssertTrue(ledger.isDue("Noten", lastSuccess: last, now: try at("2026-11-27 14:00", tz), timeZone: tz, interval: 4 * 3600))
    }

    func testPauseAfterOverloadStillHolds() throws {
        let tz = try zone()
        let ledger = AutoSyncLedger(defaults: freshDefaults(), schedule: .twiceDaily)
        let t = try at("2026-11-27 14:00", tz)
        ledger.pause("Stud.IP", from: t.addingTimeInterval(-60))
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, now: t, timeZone: tz))
        XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: nil, now: t.addingTimeInterval(AutoSyncOverload.pause), timeZone: tz))
    }

    // MARK: Wartende Arbeit

    func testPendingWorkContinuesAtMostThreeTimesPerSlot() throws {
        let tz = try zone()
        let ledger = AutoSyncLedger(defaults: freshDefaults(), schedule: .twiceDaily)
        var now = try at("2026-11-27 08:00", tz)
        var starts: [String] = []
        // Dateien bleiben den ganzen Tag "wartend" (ein Download scheitert immer wieder)
        let end = try at("2026-11-27 18:00", tz)
        while now < end {
            if ledger.isDue("Stud.IP", lastSuccess: nil, pending: true, now: now, timeZone: tz) {
                ledger.recordAttempt("Stud.IP", at: now, timeZone: tz)
                starts.append(hhmm(now, tz))
            }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(starts, ["08:00", "08:05", "08:10", "08:15", "14:00", "14:05", "14:10", "14:15"],
                       "je Fenster ein Lauf und hoechstens drei Fortsetzungen, nie den ganzen Tag alle 5 Minuten")
    }

    func testLongRunContinuesAtOnceButCountsToo() throws {
        let tz = try zone()
        let ledger = AutoSyncLedger(defaults: freshDefaults(), schedule: .twiceDaily)
        let t = try at("2026-11-27 08:30", tz)
        ledger.recordAttempt("Stud.IP", at: t, timeZone: tz)
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: t, now: t.addingTimeInterval(60), timeZone: tz), "ohne Arbeit: erst 14 Uhr")
        for i in 1...3 {
            let n = t.addingTimeInterval(Double(i) * 60)
            XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: t, pending: true, now: n, timeZone: tz, retryGap: 0))
            ledger.recordAttempt("Stud.IP", at: n, timeZone: tz)
        }
        XCTAssertEqual(ledger.continuations("Stud.IP", now: t.addingTimeInterval(240), timeZone: tz), 3)
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: t, pending: true, now: t.addingTimeInterval(240), timeZone: tz, retryGap: 0))
        XCTAssertEqual(ledger.continuations("Stud.IP", now: try at("2026-11-27 14:00", tz), timeZone: tz), 0, "neues Fenster")
    }

    // MARK: Versatz je Geraet

    func testSlotOffsetIsStableWithinAnHourAndApartFromTheMailOffset() {
        let d = freshDefaults()
        let a = AutoSyncStagger.slotOffset(defaults: d, random: { _ in 2_999 })
        XCTAssertEqual(a, 2_999)
        XCTAssertEqual(AutoSyncStagger.slotOffset(defaults: d, random: { _ in 5 }), 2_999, "einmal gewuerfelt, dann fest")
        XCTAssertEqual(d.integer(forKey: AutoSyncStagger.slotKey), 2_999)
        XCTAssertNil(d.object(forKey: AutoSyncStagger.key), "der Versatz der Uni-Mail ist eigen")
        var seen: Int?
        _ = AutoSyncStagger.slotOffset(defaults: freshDefaults(), random: { seen = $0; return 0 })
        XCTAssertEqual(seen, 3600, "0 bis 59 Minuten")
        d.set(7_200, forKey: AutoSyncStagger.slotKey)
        XCTAssertEqual(AutoSyncStagger.slotOffset(defaults: d, random: { _ in 42 }), 42, "unpassender Wert wird neu gewuerfelt")
    }
}
