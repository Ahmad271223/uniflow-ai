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
}
