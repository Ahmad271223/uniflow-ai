import XCTest

/// Wunsch des Inhabers (13.11.2026): "neben der Datei kann ich kein Blatt löschen". Im Kopf des Blatts daneben: "…"
/// mit "Diese Seite löschen" (Rueckfrage), "Papierkorb der Seiten" (Wiederherstellen) und "Ganzes Blatt löschen".
/// Echte Beruehrungen (XCUITest), Demo-Uebungsblatt.
final class CompanionPageMenuUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/demo-blatt", "-UFDocPanel", "companion",
                               "-uniflow.toolbarPlacement", "bottom"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func total(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["companion.pageLabel"]
        guard label.waitForExistence(timeout: 15) else { return nil }
        return label.label.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).last
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }

    /// vorhandene Notiz (auch aus dem Papierkorb, dann wiederhergestellt) oder neues liniertes Blatt
    private func openSheet(_ app: XCUIApplication) {
        let own = app.buttons["companion.own.0"]
        if own.waitForExistence(timeout: 15) { own.tap() } else {
            let lined = app.buttons["companion.blank.lined"]
            XCTAssertTrue(lined.waitForExistence(timeout: 10))
            lined.tap()
        }
        XCTAssertNotNil(total(app), "Blatt daneben offen")
    }

    func testDeletePageRestoreItAndTrashWholeSheet() {
        let app = launch()
        openSheet(app)
        // mindestens zwei Seiten
        app.buttons["companion.addPage"].tap()
        XCTAssertTrue(app.buttons["companion.addPage.grid"].waitForExistence(timeout: 5))
        app.buttons["companion.addPage.grid"].tap()
        XCTAssertTrue(waitFor(10) { (self.total(app) ?? 0) >= 2 })
        let before = total(app)!

        // Diese Seite loeschen, mit Rueckfrage
        let menu = app.buttons["companion.menu"]
        XCTAssertTrue(menu.isHittable, "„…“ antippbar")
        menu.tap()
        let delete = app.buttons["companion.menu.deletePage"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Menue erscheint")
        shot("1-menue")
        delete.tap()
        let confirmPage = app.buttons["Seite in den Papierkorb"].firstMatch
        XCTAssertTrue(confirmPage.waitForExistence(timeout: 5), "Rueckfrage")
        shot("2-rueckfrage-seite")
        confirmPage.tap()
        XCTAssertTrue(waitFor(10) { self.total(app) == before - 1 }, "Seite geloescht: \(String(describing: total(app)))")

        // Papierkorb der Seiten: Wiederherstellen
        menu.tap()
        let trash = app.buttons["companion.menu.trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        XCTAssertTrue(trash.label.contains("("), "Zahl der Seiten im Papierkorb: \(trash.label)")
        trash.tap()
        let restore = app.buttons["Wiederherstellen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "Papierkorb mit Wiederherstellen")
        shot("3-papierkorb-seiten")
        restore.tap()
        XCTAssertTrue(waitFor(10) { self.total(app) == before }, "Seite wieder da: \(String(describing: total(app)))")

        // Ganzes Blatt loeschen
        menu.tap()
        let sheet = app.buttons["companion.menu.deleteSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.tap()
        let confirmSheet = app.buttons["Blatt in den Papierkorb"].firstMatch
        XCTAssertTrue(confirmSheet.waitForExistence(timeout: 5))
        confirmSheet.tap()
        XCTAssertTrue(waitFor(10) { !app.buttons["companion.close"].exists }, "Blatt geschlossen, im Papierkorb")
        shot("4-blatt-im-papierkorb")
        app.terminate()

        // wiederherstellen ueber "Deine Blätter" (stellt den Demo-Stand fuer den naechsten Lauf wieder her)
        let again = launch()
        let own = again.buttons["companion.own.0"]
        XCTAssertTrue(own.waitForExistence(timeout: 15), "unter „Deine Blätter“")
        XCTAssertTrue(own.label.contains("Wiederherstellen"), own.label)
        own.tap()
        XCTAssertTrue(waitFor(10) { self.total(again) == before }, "Blatt mit allen Seiten zurueck")
        again.terminate()
    }
}
