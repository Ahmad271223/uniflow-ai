import Foundation
import XCTest
@testable import UniFlowCore

/// Bildschirm fixieren im Editor (docs/FIXIEREN-ABPAUSEN-2026-11-05.md): Stufen, Bildschirm anlassen, Helligkeit
/// zurueck, Entsperren nur nach zwei Sekunden Halten.
final class EditorFreezeTests: XCTestCase {

    private final class FakeScreen: EditorFreezeScreen {
        var idleTimerDisabled = false
        var supportsBrightness = true
        var brightness = 0.4
        init(brightness: Double = 0.4, supportsBrightness: Bool = true) {
            self.brightness = brightness
            self.supportsBrightness = supportsBrightness
        }
    }

    private final class RecordingScreen: EditorFreezeScreen {
        var idleTimerDisabled = false
        let supportsBrightness = true
        var brightness = 0.3 { didSet { writes.append(brightness) } }
        var writes: [Double] = []
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 815_000_000)

    // MARK: Stufen

    func testStateMachine() {
        let screen = FakeScreen()
        let f = EditorFreeze(screen: screen)
        var seen: [EditorFreeze.Mode] = []
        f.onChange = { seen.append($0) }
        XCTAssertEqual(f.mode, .off)
        XCTAssertFalse(f.locksView)
        XCTAssertTrue(f.acceptsInput)
        XCTAssertTrue(f.showsChrome)

        XCTAssertTrue(f.fixView())
        XCTAssertEqual(f.mode, .view)
        XCTAssertTrue(f.locksView)
        XCTAssertTrue(f.acceptsInput, "Ansicht fixiert: Stift schreibt weiter")
        XCTAssertTrue(f.showsChrome)
        XCTAssertFalse(f.fixView(), "zweimal fixieren aendert nichts")
        XCTAssertFalse(screen.idleTimerDisabled, "Ansicht fixieren laesst den Ruhezustand in Ruhe")

        XCTAssertTrue(f.toggleView())
        XCTAssertEqual(f.mode, .off)
        XCTAssertTrue(f.toggleView())
        XCTAssertEqual(f.mode, .view)

        XCTAssertTrue(f.startTracing())
        XCTAssertEqual(f.mode, .trace)
        XCTAssertTrue(f.locksView)
        XCTAssertFalse(f.acceptsInput, "Abpausen: nichts reagiert")
        XCTAssertFalse(f.showsChrome)
        XCTAssertFalse(f.startTracing(), "zweimal einfrieren aendert nichts")
        XCTAssertFalse(f.toggleView(), "Cmd-L loest das Abpausen nicht")
        XCTAssertFalse(f.fixView())
        XCTAssertEqual(f.mode, .trace)

        f.unlock()
        XCTAssertEqual(f.mode, .view, "zurueck zur Stufe vor dem Abpausen")
        f.unlock()
        XCTAssertEqual(f.mode, .off)
        f.unlock()
        XCTAssertEqual(f.mode, .off)

        XCTAssertTrue(f.startTracing())
        f.unlock()
        XCTAssertEqual(f.mode, .off, "aus dem freien Zustand eingefroren: entsperrt ganz frei")
        XCTAssertEqual(seen, [.view, .off, .view, .trace, .view, .off, .trace, .off])
    }

    // MARK: Bildschirm anlassen und Helligkeit

    func testIdleTimerIsRestoredToThePreviousValue() {
        for before in [false, true] {
            let screen = FakeScreen()
            screen.idleTimerDisabled = before
            let f = EditorFreeze(screen: screen)
            f.startTracing()
            XCTAssertTrue(screen.idleTimerDisabled, "Bildschirm bleibt an")
            f.unlock()
            XCTAssertEqual(screen.idleTimerDisabled, before, "wie vorher (\(before))")
            f.startTracing()
            f.end()
            XCTAssertEqual(screen.idleTimerDisabled, before, "Schliessen stellt ebenso zurueck")
            XCTAssertEqual(f.mode, .off)
        }
    }

    func testBrightnessMaximumAndRestore() {
        let screen = FakeScreen(brightness: 0.35)
        let f = EditorFreeze(screen: screen)
        f.startTracing(.init(maxBrightness: true))
        XCTAssertEqual(screen.brightness, 1)
        XCTAssertEqual(f.options.maxBrightness, true)
        f.unlock()
        XCTAssertEqual(screen.brightness, 0.35, accuracy: 0.0001)

        // ohne Wunsch bleibt die Helligkeit
        f.startTracing(.init(maxBrightness: false, highContrast: true))
        XCTAssertEqual(screen.brightness, 0.35, accuracy: 0.0001)
        XCTAssertTrue(f.options.highContrast)
        f.unlock()
        XCTAssertEqual(screen.brightness, 0.35, accuracy: 0.0001)

        // Dokument geschlossen waehrend des Abpausens
        f.startTracing(.init(maxBrightness: true))
        f.end()
        XCTAssertEqual(screen.brightness, 0.35, accuracy: 0.0001)
        XCTAssertFalse(screen.idleTimerDisabled)
    }

    func testBrightnessNotTouchedWhereUnsupported() {
        let screen = RecordingScreen()
        let mac = FakeScreen(brightness: 0.5, supportsBrightness: false)
        let f = EditorFreeze(screen: mac)
        f.startTracing(.init(maxBrightness: true))
        XCTAssertEqual(mac.brightness, 0.5)
        f.unlock()
        XCTAssertEqual(mac.brightness, 0.5)
        // Ansicht fixieren schreibt die Helligkeit nie
        let g = EditorFreeze(screen: screen)
        g.fixView()
        g.toggleView()
        XCTAssertEqual(screen.writes, [])
    }

    func testBackgroundRestoresBrightnessAndForegroundReappliesIt() {
        let screen = RecordingScreen()
        let f = EditorFreeze(screen: screen)
        f.startTracing(.init(maxBrightness: true))
        XCTAssertEqual(screen.brightness, 1)
        f.suspend()
        XCTAssertEqual(screen.brightness, 0.3, accuracy: 0.0001, "im Hintergrund wie vorher")
        XCTAssertEqual(f.mode, .trace, "bleibt eingefroren")
        f.suspend()
        f.resume()
        XCTAssertEqual(screen.brightness, 1)
        f.resume()
        f.unlock()
        XCTAssertEqual(screen.brightness, 0.3, accuracy: 0.0001)
        XCTAssertEqual(screen.writes, [1, 0.3, 1, 0.3])
        // ohne Abpausen: Hintergrund aendert nichts
        f.suspend(); f.resume()
        XCTAssertEqual(screen.writes.count, 4)
    }

    // MARK: Entsperren durch Halten

    func testUnlockNeedsTwoSecondsHold() {
        XCTAssertEqual(EditorFreeze.unlockHoldDuration, 2.0)
        let f = EditorFreeze(screen: FakeScreen())
        // ausserhalb des Abpausens kein Halten
        f.holdBegan(at: t0)
        XCTAssertFalse(f.isHolding)
        XCTAssertFalse(f.holdEnded(at: t0.addingTimeInterval(5)))

        f.startTracing()
        f.holdBegan(at: t0)
        XCTAssertTrue(f.isHolding)
        XCTAssertEqual(f.holdProgress(at: t0.addingTimeInterval(0.5)), 0.25, accuracy: 0.0001)
        XCTAssertFalse(f.holdCheck(at: t0.addingTimeInterval(1.9)))
        XCTAssertFalse(f.holdEnded(at: t0.addingTimeInterval(1.99)), "kurz losgelassen: bleibt gesperrt")
        XCTAssertEqual(f.mode, .trace)
        XCTAssertFalse(f.isHolding)
        XCTAssertEqual(f.holdProgress(at: t0.addingTimeInterval(3)), 0, "Ring zurueck")

        // Loslassen ohne Beginn (Papier rutscht) entsperrt nie
        XCTAssertFalse(f.holdEnded(at: t0.addingTimeInterval(10)))
        XCTAssertEqual(f.mode, .trace)

        // abgebrochen
        f.holdBegan(at: t0)
        f.holdCancelled()
        XCTAssertFalse(f.holdCheck(at: t0.addingTimeInterval(4)))
        XCTAssertEqual(f.mode, .trace)

        // Zeitgeber waehrend des Haltens
        f.holdBegan(at: t0)
        XCTAssertEqual(f.holdProgress(at: t0.addingTimeInterval(9)), 1)
        XCTAssertTrue(f.holdCheck(at: t0.addingTimeInterval(2.0)))
        XCTAssertEqual(f.mode, .off)
        XCTAssertFalse(f.isHolding)

        // Loslassen nach genug Zeit
        f.startTracing()
        f.holdBegan(at: t0)
        XCTAssertTrue(f.holdEnded(at: t0.addingTimeInterval(2.4)))
        XCTAssertEqual(f.mode, .off)
    }

    func testBackgroundCancelsHold() {
        let f = EditorFreeze(screen: FakeScreen())
        f.startTracing()
        f.holdBegan(at: t0)
        f.suspend()
        f.resume()
        XCTAssertFalse(f.holdCheck(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(f.mode, .trace)
    }
}
