import XCTest
import UniFlowCore
@testable import UniFlow

/// Zeitgeber des Abgleichs von selbst bei offener App (Auftrag des Inhabers 17.11.2026, AutoSync.swift): wartet bis zum
/// naechsten faelligen Zeitpunkt, fragt dann nur die Regel; ein offenes Dokument schiebt hoechstens 10 Minuten auf.
@MainActor
final class AutoSyncAppTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_387_600)

    func testDelayIsBoundedAndNeverBusy() {
        XCTAssertEqual(AutoSyncTicker.delay(next: t0, now: t0), AutoSyncTicker.minSleep, "faellig: kurz warten, kein Dauerfeuer")
        XCTAssertEqual(AutoSyncTicker.delay(next: t0.addingTimeInterval(-600), now: t0), AutoSyncTicker.minSleep)
        XCTAssertEqual(AutoSyncTicker.delay(next: t0.addingTimeInterval(120), now: t0), 120)
        XCTAssertEqual(AutoSyncTicker.delay(next: t0.addingTimeInterval(14 * 3600), now: t0), AutoSyncTicker.maxSleep,
                       "nie laenger als 5 Minuten am Stueck (Uhr verstellt, neue Zeitzone, neues Portal)")
    }

    func testHoldOnlyWhileEditingAndAtMostTenMinutes() {
        XCTAssertFalse(AutoSyncTicker.holds(editing: false, heldSince: nil, now: t0))
        XCTAssertTrue(AutoSyncTicker.holds(editing: true, heldSince: nil, now: t0))
        XCTAssertTrue(AutoSyncTicker.holds(editing: true, heldSince: t0, now: t0.addingTimeInterval(9 * 60)))
        XCTAssertFalse(AutoSyncTicker.holds(editing: true, heldSince: t0, now: t0.addingTimeInterval(10 * 60)))
        XCTAssertFalse(AutoSyncTicker.holds(editing: true, heldSince: t0, now: t0.addingTimeInterval(-60)), "Uhr zurueck: nicht festhalten")
    }

    func testFireTicksOnlyWhenDueAndDefersWhileADocumentIsOpen() async {
        var now = t0
        var due = t0.addingTimeInterval(60)
        var ticks: [Date] = []
        let ticker = AutoSyncTicker(next: { _ in due }, tick: { ticks.append($0) })
        ticker.now = { now }
        var editing = false
        ticker.editing = { editing }
        await ticker.fire()
        XCTAssertEqual(ticks, [], "noch nicht faellig")
        now = t0.addingTimeInterval(60)
        await ticker.fire()
        XCTAssertEqual(ticks, [now])
        // Dokument offen: aufschieben ...
        due = now.addingTimeInterval(30 * 60)
        now = due
        editing = true
        await ticker.fire()
        XCTAssertEqual(ticks.count, 1)
        XCTAssertEqual(ticker.heldSince, now)
        now = due.addingTimeInterval(5 * 60)
        await ticker.fire()
        XCTAssertEqual(ticks.count, 1, "5 Minuten spaeter weiter aufgeschoben")
        // ... aber hoechstens 10 Minuten
        now = due.addingTimeInterval(10 * 60)
        await ticker.fire()
        XCTAssertEqual(ticks.count, 2, "nach 10 Minuten trotzdem")
        XCTAssertNil(ticker.heldSince)
        // Dokument zu: sofort
        due = now.addingTimeInterval(30 * 60)
        now = due
        editing = true
        await ticker.fire()
        editing = false
        now = due.addingTimeInterval(60)
        await ticker.fire()
        XCTAssertEqual(ticks.count, 3)
    }

    func testStartStopUsesTheRuleAndStopsCleanly() async throws {
        var now = t0
        var ticks = 0
        var waits: [TimeInterval] = []
        let ticker = AutoSyncTicker(next: { n in n }, tick: { _ in ticks += 1 })
        ticker.now = { now }
        ticker.sleep = { s in
            waits.append(s)
            now = now.addingTimeInterval(s)
            await Task.yield()
            return true
        }
        ticker.start()
        XCTAssertTrue(ticker.isActive)
        for _ in 0..<200 where ticks < 3 { await Task.yield() }
        ticker.stop()
        XCTAssertFalse(ticker.isActive)
        XCTAssertGreaterThanOrEqual(ticks, 3)
        XCTAssertTrue(waits.allSatisfy { $0 == AutoSyncTicker.minSleep })
        let stopped = ticks
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThanOrEqual(ticks, stopped + 1, "nach dem Anhalten kein weiterer Takt")
    }

    func testTheThreeNumbersStandAtOnePlace() {
        XCTAssertEqual(AutoSyncSchedule.standard.startHour, 8)
        XCTAssertEqual(AutoSyncSchedule.standard.endHour, 18)
        XCTAssertEqual(AutoSyncSchedule.standard.interval, 30 * 60)
    }

    /// 27.11.2026 (Auftrag des Inhabers): alle Portale ausser der Uni-Mail von selbst zweimal am Tag (ab 8 und ab 14 Uhr),
    /// die Uni-Mail weiter alle 30 Minuten. Noten der Uni Hildesheim und der HsH innerhalb des Datei-Abgleichs hoechstens
    /// alle 4 Stunden. Unter XCTest ohne Versatz, in der App mit dem festen Versatz des Geraets.
    func testPortalsTwiceADayMailEveryThirtyMinutesAndNoOffsetUnderTest() {
        XCTAssertEqual(AutoSync.schedule, .twiceDaily)
        XCTAssertEqual(AutoSync.schedule.slotHours, [8, 14])
        XCTAssertEqual(AutoSync.schedule.runsPerDay, 2)
        XCTAssertEqual(AutoSync.mailSchedule, .standard)
        XCTAssertEqual(AutoSync.mailSchedule.interval, 30 * 60)
        XCTAssertEqual(AutoSync.gradesInterval, 4 * 3600)
        XCTAssertEqual(AutoSync.schedule.offset, 0, "Tests rechnen mit 8:00 und 14:00")
        XCTAssertEqual(AutoSync.mailSchedule.offset, 0, "Tests rechnen mit 8:00, 8:30 …")
    }

    /// Entscheidung des Inhabers 27.11.2026 („Ja, auch abends“): bei offener App setzt ein unterbrochener Abgleich auch
    /// ausserhalb der Fenster fort - sofort bzw. 5 Minuten nach dem letzten Versuch, nie in einer Pause, nie fuer die
    /// Uni-Mail, nie ohne wartende Arbeit. Im Fenster entscheidet weiter die Regel des Kerns.
    func testInterruptedRunContinuesInTheEveningWhileTheAppIsOpen() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: h, minute: m))! }
        let saved = AutoSync.schedule
        defer { AutoSync.schedule = saved }
        AutoSync.schedule = .twiceDaily
        let suite = "abends-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = AutoSyncLedger(defaults: defaults, schedule: .twiceDaily)
        let waiting = AutoSyncPortalState(name: OpenSync.studIP, lastSuccess: nil, pending: true)

        XCTAssertEqual(ContainerManager.eveningContinuation(waiting, ledger: ledger, now: at(20), timeZone: tz), at(20), "ohne Versuch: sofort")
        ledger.recordAttempt(OpenSync.studIP, at: at(19, 58), timeZone: tz)
        XCTAssertEqual(ContainerManager.eveningContinuation(waiting, ledger: ledger, now: at(20), timeZone: tz), at(20, 3), "5 Minuten nach dem Versuch")
        XCTAssertEqual(ContainerManager.eveningContinuation(waiting, ledger: ledger, now: at(21), timeZone: tz), at(21))
        XCTAssertEqual(ContainerManager.eveningContinuation(waiting, ledger: ledger, now: at(6, 30), timeZone: tz), at(6, 30), "auch frueh morgens")
        XCTAssertNil(ContainerManager.eveningContinuation(waiting, ledger: ledger, now: at(10), timeZone: tz), "im Fenster: Regel des Kerns")
        XCTAssertNil(ContainerManager.eveningContinuation(AutoSyncPortalState(name: OpenSync.studIP, lastSuccess: nil), ledger: ledger,
                                                          now: at(20), timeZone: tz), "nichts wartet: kein neuer Abruf am Abend")
        XCTAssertNil(ContainerManager.eveningContinuation(AutoSyncPortalState(name: OpenSync.uniMail, lastSuccess: nil, pending: true),
                                                          ledger: ledger, now: at(20), timeZone: tz), "Uni-Mail: eigener Takt")
        ledger.pause(OpenSync.studIP, from: at(19, 30))
        XCTAssertNil(ContainerManager.eveningContinuation(waiting, ledger: ledger, now: at(20), timeZone: tz), "Pause nach ueberlastet")
    }
}
