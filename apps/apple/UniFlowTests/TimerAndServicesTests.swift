import XCTest
@testable import UniFlow

/// Zeitmesser (views-doc.js) und Formate aus viewServices (views-misc.js). Zeit kommt aus einer Testuhr mit Datum und
/// fortlaufender Systemuhr (Pruefpunkte 241–249: Suspendierung, Neustart, Zeitsprung, Benachrichtigung).
@MainActor
final class TimerAndServicesTests: XCTestCase {

    /// Beide Uhren getrennt stellbar: `advance` wie echte Zeit, `jumpWall` wie ein verstelltes Datum
    final class FakeClock {
        var wall = Date(timeIntervalSince1970: 1_800_000_000)
        var monotonic: Double = 1000
        func now() -> StudyTimerNow { StudyTimerNow(wall: wall, monotonic: monotonic) }
        func advance(_ s: Double) { wall = wall.addingTimeInterval(s); monotonic += s }
        func jumpWall(_ s: Double) { wall = wall.addingTimeInterval(s) }
        /// Neustart des Geraets: die fortlaufende Uhr beginnt neu
        func reboot(after s: Double) { wall = wall.addingTimeInterval(s); monotonic = 5 }
    }

    final class FakeNotifier: StudyTimerNotifying {
        var permissionRequests = 0
        var scheduled: [(title: String, body: String, at: Date)] = []
        /// zurzeit eingeplant (genau eine oder keine)
        private(set) var pending: (title: String, body: String, at: Date)?
        func requestPermissionIfNeeded() { permissionRequests += 1 }
        func schedule(title: String, body: String, at date: Date) { scheduled.append((title, body, date)); pending = (title, body, date) }
        func cancel() { pending = nil }
    }

    private var suite = ""
    private var defaults: UserDefaults!
    private var clock: FakeClock!
    private var notifier: FakeNotifier!

    override func setUp() {
        super.setUp()
        suite = "uniflow.tests.timer.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        clock = FakeClock()
        notifier = FakeNotifier()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func timer() -> StudyTimer { StudyTimer(defaults: defaults, notifier: notifier, clock: clock.now) }

    func testTimerFormat() {
        XCTAssertEqual(StudyTimer.fmt(0), "0:00")
        XCTAssertEqual(StudyTimer.fmt(59.5), "1:00")          // Math.round
        XCTAssertEqual(StudyTimer.fmt(-3), "0:00")
        XCTAssertEqual(StudyTimer.fmt(25 * 60), "25:00")
        XCTAssertEqual(StudyTimer.fmt(61), "1:01")
    }

    func testCountdownEndsWithToast() {
        let t = timer(), toast = UFToastCenter()
        t.toast = toast
        t.setMode(.countdown)
        t.setMinutes(5)
        XCTAssertEqual(t.left, 300)
        t.startPause()
        clock.advance(301)
        t.tick()
        XCTAssertFalse(t.running)
        XCTAssertEqual(t.left, 0)
        XCTAssertEqual(toast.message, "Zeit abgelaufen")
    }

    func testPomodoroSwitchesPhase() {
        let t = timer(), toast = UFToastCenter()
        t.toast = toast
        t.setMode(.pomodoro)
        t.startPause()
        clock.advance(25 * 60 + 1)
        t.tick()
        XCTAssertEqual(toast.message, "Pomodoro vorbei – Pause!")
        XCTAssertEqual(t.pomo.phase, "pause")
        XCTAssertEqual(t.left, 5 * 60)
        t.startPause()
        clock.advance(5 * 60 + 1)
        t.tick()
        XCTAssertEqual(t.pomo.phase, "work")
        XCTAssertEqual(t.pomo.round, 2)
    }

    func testPillOnlyWhenStarted() {
        let t = timer()
        XCTAssertFalse(t.showsPill)
        t.startPause()
        XCTAssertTrue(t.showsPill)
        t.toggle(true)
        XCTAssertFalse(t.showsPill)
    }

    // MARK: 241/248 Suspendierung: Zeit aus Zeitstempeln, nicht aus Takten

    /// Waehrend der Suspendierung kommt kein Takt; der erste danach (Wechsel in den Vordergrund) fuehrt die Zeit nach
    func testSuspensionWithoutTicksIsCaughtUp() {
        let t = timer()
        t.startPause()                                        // Stoppuhr
        clock.advance(2)
        t.tick()
        XCTAssertEqual(t.elapsed, 2, accuracy: 0.001)
        clock.advance(40 * 60)                                // iPad gesperrt, App suspendiert: keine Takte
        t.sceneBecameActive()
        XCTAssertEqual(t.elapsed, 40 * 60 + 2, accuracy: 0.001)
        XCTAssertTrue(t.running)
        t.startPause()                                        // Pause: Stand bleibt
        clock.advance(100)
        t.tick()
        XCTAssertEqual(t.elapsed, 40 * 60 + 2, accuracy: 0.001)
        t.startPause()                                        // weiter
        clock.advance(8)
        t.tick()
        XCTAssertEqual(t.elapsed, 40 * 60 + 10, accuracy: 0.001)
    }

    /// 243: Countdown endet waehrend der Sperre: beim naechsten Takt steht er auf 0:00, gemeldet wird einmal
    func testCountdownEndingWhileLockedIsFinishedOnReturn() {
        let t = timer(), toast = UFToastCenter()
        t.toast = toast
        t.setMode(.countdown)
        t.setMinutes(15)
        t.startPause()
        clock.advance(3 * 3600)
        t.sceneBecameActive()
        XCTAssertFalse(t.running)
        XCTAssertEqual(t.elapsed, 15 * 60)
        XCTAssertEqual(t.left, 0)
        XCTAssertEqual(toast.message, "Zeit abgelaufen")
        XCTAssertTrue(t.showsPill, "0:00 bleibt als Pille sichtbar")
        toast.show("anderes")
        t.sceneBecameActive()
        XCTAssertEqual(toast.message, "anderes", "nicht erneut gemeldet")
    }

    // MARK: 246 Geraetezeit

    /// Eine verstellte Geraetezeit aendert die laufende Messung nicht (fortlaufende Systemuhr)
    func testDeviceClockChangesDoNotAffectARunningTimer() {
        let t = timer()
        t.setMode(.countdown)
        t.setMinutes(25)
        t.startPause()
        clock.advance(60)
        clock.jumpWall(-7 * 86_400)                           // Datum eine Woche zurueck
        t.tick()
        XCTAssertEqual(t.elapsed, 60, accuracy: 0.001)
        XCTAssertTrue(t.running)
        clock.jumpWall(30 * 86_400)                           // Datum weit vor
        t.tick()
        XCTAssertEqual(t.elapsed, 60, accuracy: 0.001)
        XCTAssertTrue(t.running, "kein vorzeitiges Ende durch die Uhr")
    }

    // MARK: 242/249 Neustart

    /// Nach Neustart (auch Beendigung durch das System) laeuft die Stoppuhr ueber das gespeicherte Datum weiter
    func testStopwatchSurvivesRestart() {
        let t = timer()
        t.startPause()
        clock.advance(90)
        t.tick()
        XCTAssertNotNil(defaults.data(forKey: StudyTimer.stateKey), "Zustand gespeichert")
        clock.reboot(after: 600)                              // 10 Minuten ohne App, neue Systemuhr
        let again = timer()
        XCTAssertEqual(again.mode, .stopwatch)
        XCTAssertTrue(again.running)
        XCTAssertEqual(again.elapsed, 690, accuracy: 0.001)
        clock.advance(10)
        again.tick()
        XCTAssertEqual(again.elapsed, 700, accuracy: 0.001)
    }

    /// Angehaltener Countdown: Stand und Ziel kommen zurueck, nichts laeuft, keine Benachrichtigung
    func testPausedCountdownSurvivesRestartWithoutRunning() {
        let t = timer()
        t.setMode(.countdown)
        t.setMinutes(45)
        t.startPause()
        clock.advance(120)
        t.startPause()
        XCTAssertNil(notifier.pending, "Pause nimmt die Benachrichtigung zurueck")
        clock.reboot(after: 3600)
        let again = timer()
        XCTAssertEqual(again.mode, .countdown)
        XCTAssertFalse(again.running)
        XCTAssertEqual(again.left, 45 * 60 - 120, accuracy: 0.001)
        XCTAssertEqual(notifier.scheduled.count, 1, "beim Wiederherstellen nichts eingeplant")
    }

    /// 244: Pomodoro-Phase endet waehrend die App nicht lief: genau diese Phase ist vorbei, die naechste wartet auf
    /// Start (nichts laeuft falsch weiter, auch nicht nach Stunden)
    func testPomodoroAfterLongInterruptionEndsOnlyTheCurrentPhase() {
        let t = timer()
        t.setMode(.pomodoro)
        t.startPause()
        clock.advance(60)
        t.tick()
        clock.reboot(after: 5 * 3600)
        let again = timer()
        XCTAssertFalse(again.running)
        XCTAssertEqual(again.pomo.phase, "pause")
        XCTAssertEqual(again.pomo.round, 1)
        XCTAssertEqual(again.left, 5 * 60)
        XCTAssertEqual(again.elapsed, 0)
        // und nach einem weiteren Neustart bleibt es dabei
        clock.reboot(after: 3600)
        let third = timer()
        XCTAssertFalse(third.running)
        XCTAssertEqual(third.pomo.phase, "pause")
        XCTAssertEqual(third.pomo.round, 1)
    }

    /// Laufender Countdown, der nach dem Neustart noch nicht um ist: Restzeit stimmt, Benachrichtigung neu eingeplant
    func testRunningCountdownSurvivesRestart() {
        let t = timer()
        t.setMode(.countdown)
        t.setMinutes(60)
        t.startPause()
        clock.reboot(after: 20 * 60)
        let again = timer()
        XCTAssertTrue(again.running)
        XCTAssertEqual(again.left, 40 * 60, accuracy: 0.001)
        XCTAssertEqual(notifier.pending?.at, clock.wall.addingTimeInterval(40 * 60))
        XCTAssertEqual(notifier.pending?.body, "Zeit abgelaufen")
    }

    /// Nach dem Neustart eine zurueckgestellte Uhr: nichts wird abgezogen, der Countdown laeuft weiter
    func testClockSetBackBetweenRestartsSubtractsNothing() {
        let t = timer()
        t.setMode(.countdown)
        t.setMinutes(30)
        t.startPause()
        clock.advance(300)
        t.tick()
        clock.reboot(after: -3600)                            // Datum eine Stunde zurueck, dann Start
        let again = timer()
        XCTAssertTrue(again.running)
        XCTAssertEqual(again.elapsed, 300, accuracy: 0.001)
        XCTAssertEqual(again.left, 25 * 60, accuracy: 0.001)
    }

    // MARK: 245 Benachrichtigung

    /// Erlaubnis erst beim ersten Start eines Countdowns, nicht fuer die Stoppuhr; genau eine Benachrichtigung auf das
    /// Ende, zurueckgenommen bei Pause, Zuruecksetzen, Moduswechsel und Ende
    func testNotificationIsScheduledForCountdownAndPomodoroOnly() {
        let t = timer()
        t.startPause()                                        // Stoppuhr
        XCTAssertEqual(notifier.permissionRequests, 0)
        XCTAssertTrue(notifier.scheduled.isEmpty)
        t.setMode(.countdown)
        XCTAssertEqual(notifier.permissionRequests, 0, "Moduswahl allein fragt nicht")
        t.setMinutes(15)
        t.startPause()
        XCTAssertEqual(notifier.permissionRequests, 1)
        XCTAssertEqual(notifier.scheduled.count, 1)
        XCTAssertEqual(notifier.scheduled[0].title, "Countdown")
        XCTAssertEqual(notifier.scheduled[0].body, "Zeit abgelaufen")
        XCTAssertEqual(notifier.scheduled[0].at, clock.wall.addingTimeInterval(15 * 60))
        clock.advance(60)
        t.startPause()                                        // Pause
        XCTAssertNil(notifier.pending)
        t.startPause()                                        // weiter: Ende = jetzt + Rest
        XCTAssertEqual(notifier.permissionRequests, 2, "jeder Start fragt den Mitschreiber; das System fragt nur einmal")
        XCTAssertEqual(notifier.scheduled.last?.at, clock.wall.addingTimeInterval(14 * 60))
        t.reset()
        XCTAssertNil(notifier.pending)
        t.setMode(.pomodoro)
        t.startPause()
        XCTAssertEqual(notifier.scheduled.last?.title, "Pomodoro")
        XCTAssertEqual(notifier.scheduled.last?.body, "Pomodoro vorbei – Pause!")
        XCTAssertEqual(notifier.scheduled.last?.at, clock.wall.addingTimeInterval(25 * 60))
        clock.advance(25 * 60)
        t.tick()
        XCTAssertNil(notifier.pending, "am Ende zurueckgenommen")
        t.startPause()                                        // Pause-Phase
        XCTAssertEqual(notifier.scheduled.last?.body, "Pause vorbei – weiter geht's")
        t.setMode(.stopwatch)
        XCTAssertNil(notifier.pending)
    }

    /// Hintergrund sichert den Stand sofort (nicht erst nach 10 s), damit eine Beendigung durch das System nichts verliert
    func testBackgroundPersistsImmediately() throws {
        let t = timer()
        t.startPause()
        clock.advance(3)
        t.tick()
        var s = try JSONDecoder().decode(StudyTimer.Snapshot.self, from: try XCTUnwrap(defaults.data(forKey: StudyTimer.stateKey)))
        XCTAssertEqual(s.elapsed, 0, "innerhalb von 10 s nur beim Start gespeichert")
        t.sceneWillResignActive()
        s = try JSONDecoder().decode(StudyTimer.Snapshot.self, from: try XCTUnwrap(defaults.data(forKey: StudyTimer.stateKey)))
        XCTAssertEqual(s.elapsed, 3, accuracy: 0.001)
        XCTAssertEqual(s.seenAt, clock.wall)
        XCTAssertTrue(s.running)
        XCTAssertEqual(StudyTimerNotifications.identifier, "de.uniflow.timer.end")
    }

    func testServicesNumberAndDate() {
        XCTAssertEqual(ServicesPage.js(2), "2")
        XCTAssertEqual(ServicesPage.js(1.75), "1.75")
        XCTAssertEqual(ServicesPage.js(30), "30")
        XCTAssertEqual(ServicesPage.plainDate("2026-10-05T07:00:12"), "5.10.2026")
    }
}
