import XCTest
@testable import UniFlow

/// Zeitmesser (views-doc.js) und Formate aus viewServices (views-misc.js)
@MainActor
final class TimerAndServicesTests: XCTestCase {

    func testTimerFormat() {
        XCTAssertEqual(StudyTimer.fmt(0), "0:00")
        XCTAssertEqual(StudyTimer.fmt(59.5), "1:00")          // Math.round
        XCTAssertEqual(StudyTimer.fmt(-3), "0:00")
        XCTAssertEqual(StudyTimer.fmt(25 * 60), "25:00")
        XCTAssertEqual(StudyTimer.fmt(61), "1:01")
    }

    func testCountdownEndsWithToast() {
        let t = StudyTimer(), toast = UFToastCenter()
        t.toast = toast
        t.setMode(.countdown)
        t.setMinutes(5)
        XCTAssertEqual(t.left, 300)
        t.startPause()
        t.tick(now: Date().addingTimeInterval(301))
        XCTAssertFalse(t.running)
        XCTAssertEqual(t.left, 0)
        XCTAssertEqual(toast.message, "Zeit abgelaufen")
    }

    func testPomodoroSwitchesPhase() {
        let t = StudyTimer(), toast = UFToastCenter()
        t.toast = toast
        t.setMode(.pomodoro)
        t.startPause()
        t.tick(now: Date().addingTimeInterval(25 * 60 + 1))
        XCTAssertEqual(toast.message, "Pomodoro vorbei – Pause!")
        XCTAssertEqual(t.pomo.phase, "pause")
        XCTAssertEqual(t.left, 5 * 60)
        t.startPause()
        t.tick(now: Date().addingTimeInterval(5 * 60 + 1))
        XCTAssertEqual(t.pomo.phase, "work")
        XCTAssertEqual(t.pomo.round, 2)
    }

    func testPillOnlyWhenStarted() {
        let t = StudyTimer()
        XCTAssertFalse(t.showsPill)
        t.startPause()
        XCTAssertTrue(t.showsPill)
        t.toggle(true)
        XCTAssertFalse(t.showsPill)
    }

    func testServicesNumberAndDate() {
        XCTAssertEqual(ServicesPage.js(2), "2")
        XCTAssertEqual(ServicesPage.js(1.75), "1.75")
        XCTAssertEqual(ServicesPage.js(30), "30")
        XCTAssertEqual(ServicesPage.plainDate("2026-10-05T07:00:12"), "5.10.2026")
    }
}
