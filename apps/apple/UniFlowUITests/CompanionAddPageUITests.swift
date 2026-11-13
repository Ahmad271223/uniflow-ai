import XCTest

/// Fehlerbericht des Inhabers (Build 37, 13.11.2026): "+ Seite" im Blatt daneben fuegte keine Seite ein. Dieser Test
/// tippt mit echten Beruehrungen (XCUITest), nicht ueber die Bedienungshilfen: Demo-Uebungsblatt oeffnen, leeres Blatt
/// daneben, "+ Seite", Papier waehlen, neue Seite sichtbar; nach Neustart noch da. Fuer alle drei Lagen der
/// Stift-Palette (oben fest, unten fest, schwebend).
final class CompanionAddPageUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// Bildschirmfoto nach UF_SCREENSHOT_DIR (nur wenn gesetzt)
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func launch(placement: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/demo-blatt", "-UFDocPanel", "companion",
                               "-uniflow.toolbarPlacement", placement]
        app.launch()
        return app
    }

    /// "S. 2 / 3" -> (2, 3)
    private func pages(_ app: XCUIApplication) -> (Int, Int)? {
        let label = app.staticTexts["companion.pageLabel"]
        guard label.waitForExistence(timeout: 15) else { return nil }
        let nums = label.label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        if nums.count == 2 { return (nums[0], nums[1]) }
        return nums.count == 1 ? (nums[0], 1) : nil
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func openSheet(_ app: XCUIApplication) {
        // "Daneben öffnen": vorhandene Notiz ("Deine Blätter") oder leeres Blatt
        let own = app.buttons["companion.own.0"]
        if own.waitForExistence(timeout: 15) { own.tap(); return }
        let lined = app.buttons["companion.blank.lined"]
        XCTAssertTrue(lined.waitForExistence(timeout: 10), "„Daneben öffnen“ erscheint")
        lined.tap()
    }

    private func addPageWithRealTouch(_ app: XCUIApplication, placement: String) {
        openSheet(app)
        let before = pages(app)
        XCTAssertNotNil(before, "Blatt daneben offen (\(placement))")
        guard let before else { return }
        let plus = app.buttons["companion.addPage"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        XCTAssertTrue(plus.isHittable, "„+ Seite“ antippbar (\(placement))")
        shot("\(placement)-1-blatt-daneben")
        plus.tap()
        // Papier waehlen (Wunsch des Inhabers: erst fragen, dann einfuegen)
        let grid = app.buttons["companion.addPage.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "Auswahl des Papiers erscheint (\(placement))")
        shot("\(placement)-2-papier-waehlen")
        grid.tap()
        XCTAssertTrue(waitFor(10) { self.pages(app).map { $0.1 == before.1 + 1 && $0.0 == before.0 + 1 } ?? false },
                      "neue Seite darunter und hingesprungen: vorher \(before), jetzt \(String(describing: pages(app))) (\(placement))")
        let after = pages(app)!
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        shot("\(placement)-3-neue-seite")
        // gespeichert: Neustart, dieselbe Notiz hat die Seite noch
        app.terminate()
        let again = launch(placement: placement)
        openSheet(again)
        XCTAssertTrue(waitFor(10) { self.pages(again).map { $0.1 == after.1 } ?? false },
                      "nach Neustart noch \(after.1) Seiten, jetzt \(String(describing: pages(again))) (\(placement))")
        again.terminate()
    }

    func testAddPageTopPalette() { addPageWithRealTouch(launch(placement: "top"), placement: "top") }
    func testAddPageBottomPalette() { addPageWithRealTouch(launch(placement: "bottom"), placement: "bottom") }
    func testAddPageFloatingPalette() { addPageWithRealTouch(launch(placement: "floating"), placement: "floating") }
}
