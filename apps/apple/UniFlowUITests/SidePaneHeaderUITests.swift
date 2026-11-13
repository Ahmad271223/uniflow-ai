import XCTest

/// Fehlerbericht des Inhabers (Build 39, 13.11.2026): Das X im Kopf einer Community-Loesung daneben reagierte nicht.
/// Echte Beruehrungen (XCUITest) auf alle Knoepfe im Kopf der Spalte daneben: Loesung (X) und Notizblatt
/// (X, "+ Seite"), fuer Stift-Palette oben, unten und schwebend, mit der Reiterleiste der Dokumente darueber.
final class SidePaneHeaderUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(panel: String, placement: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/demo-blatt", "-UFDocPanel", panel,
                               "-uniflow.toolbarPlacement", placement]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Tipp wie mit dem Apple Pencil: etwas laenger als die Schwelle der Tausch-Geste (0,35 s) und dabei 4 pt bewegt
    static func pencilLikeTap(_ e: XCUIElement) {
        let start = e.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: start.withOffset(CGVector(dx: 4, dy: 1)))
    }

    private func gone(_ e: XCUIElement, _ timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if !e.exists { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return !e.exists
    }

    /// Loesung daneben: X schliesst die Spalte
    private func solutionClose(_ placement: String) {
        let app = launch(panel: "solution", placement: placement.replacingOccurrences(of: "quer-", with: ""))
        let close = app.buttons["solution.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 25), "Loesung daneben offen (\(placement))")
        XCTAssertTrue(close.isHittable, "X antippbar (\(placement))")
        // wie beim Inhaber: Spalte nach unten gescrollt, Inhalt direkt unter der Kopfzeile
        let pane = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
        pane.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)))
        pane.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot("\(placement)-loesung-offen")
        XCTAssertTrue(close.isHittable, "X nach dem Scrollen antippbar (\(placement))")
        // Tipp mit dem Stift bzw. etwas laenger gedrueckt (ueber der Schwelle der Tausch-Geste von 0,35 s)
        Self.pencilLikeTap(close)
        XCTAssertTrue(gone(close), "X schliesst die Loesung daneben (\(placement))")
        shot("\(placement)-loesung-geschlossen")
        app.terminate()
    }

    /// Notizblatt daneben: "+ Seite" oeffnet die Papierwahl, X schliesst das Blatt
    private func sheetButtons(_ placement: String) {
        let app = launch(panel: "companion", placement: placement.replacingOccurrences(of: "quer-", with: ""))
        let own = app.buttons["companion.own.0"]
        if own.waitForExistence(timeout: 15) { own.tap() } else {
            let lined = app.buttons["companion.blank.lined"]
            XCTAssertTrue(lined.waitForExistence(timeout: 10))
            lined.tap()
        }
        let plus = app.buttons["companion.addPage"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "Blatt daneben offen (\(placement))")
        Self.pencilLikeTap(plus)
        let grid = app.buttons["companion.addPage.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "„+ Seite“ reagiert (\(placement))")
        // Papierwahl ohne Auswahl schliessen (ausserhalb tippen), dann X
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).tap()
        XCTAssertTrue(gone(grid), "Papierwahl zu (\(placement))")
        let close = app.buttons["companion.close"]
        XCTAssertTrue(close.isHittable, "X antippbar (\(placement))")
        Self.pencilLikeTap(close)
        XCTAssertTrue(gone(close), "X schliesst das Blatt daneben (\(placement))")
        app.terminate()
    }

    func testSolutionCloseLandscapeBottom() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        solutionClose("quer-bottom")
    }
    func testSheetButtonsLandscapeBottom() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        sheetButtons("quer-bottom")
    }
    func testSolutionCloseTop() { solutionClose("top") }
    func testSolutionCloseBottom() { solutionClose("bottom") }
    func testSolutionCloseFloating() { solutionClose("floating") }
    func testSheetButtonsTop() { sheetButtons("top") }
    func testSheetButtonsBottom() { sheetButtons("bottom") }
    func testSheetButtonsFloating() { sheetButtons("floating") }
    /// Seiten tauschen geht weiter: Titel der Loesung gedrueckt halten und zur anderen Haelfte ziehen
    func testSwapByDraggingTheTitle() {
        let app = launch(panel: "solution", placement: "bottom")
        let close = app.buttons["solution.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 25))
        let width = app.windows.firstMatch.frame.width
        let before = close.frame.midX
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Lösung von'")).firstMatch
        XCTAssertTrue(title.exists)
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: before < width / 2 ? 0.8 : 0.2, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: target)
        let end = Date().addingTimeInterval(5)
        while Date() < end, (close.frame.midX < width / 2) == (before < width / 2) { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertNotEqual(close.frame.midX < width / 2, before < width / 2, "Loesung liegt jetzt auf der anderen Seite")
        // zurueck tauschen (die Wahl wird gemerkt)
        let back = title.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        back.press(forDuration: 0.6, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: before < width / 2 ? 0.2 : 0.8, dy: 0.5)))
        app.terminate()
    }
}
