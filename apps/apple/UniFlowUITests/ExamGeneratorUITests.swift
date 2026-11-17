import XCTest

/// Klausur-Generator, Stufe (a) (Auftrag 17.11.2026): mit Pro AI im Demo-Modul die Karte antippen, im Blatt Dateien
/// anhaken und "Weiter" erreichen. Echte Beruehrungen; Bilder nach `UF_SCREENSHOT_DIR`, wenn gesetzt.
final class ExamGeneratorUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launch(plan: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFPlan", plan, "-UFRoute", "#/modules/1"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    func testProAISelectsFilesAndReachesNext() {
        let app = launch(plan: "pro_ai")
        let open = app.buttons["examgen.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30), "Karte Klausur-Generator auf der Modulseite")
        XCTAssertEqual(open.label, "Unterlagen auswählen")
        open.tap()

        XCTAssertTrue(app.staticTexts["examgen.title"].waitForExistence(timeout: 10), "Blatt mit der Auswahl")
        let blatt = app.buttons["examgen.file.demo-blatt"], skript = app.buttons["examgen.file.demo-skript"]
        XCTAssertTrue(blatt.waitForExistence(timeout: 10), "Übungsblatt der Demo in der Liste")
        XCTAssertTrue(skript.exists && app.buttons["examgen.file.demo-folien"].exists)
        let next = app.buttons["examgen.next"]
        XCTAssertFalse(next.isEnabled, "ohne Auswahl kein Weiter")
        XCTAssertEqual(app.staticTexts["examgen.counter.exercises"].label, "0 von 10")
        shot("examgen-1-leer")

        // eine Übung anhaken: Zähler springt, Weiter geht, Hinweis ohne Altklausur
        blatt.tap()
        XCTAssertEqual(app.staticTexts["examgen.counter.exercises"].label, "1 von 10")
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(app.staticTexts["examgen.hint"].exists, "Hinweis: ohne Altklausur ungenauer")

        // "Alles auswählen" nimmt auch Skript und Folien
        app.buttons["examgen.all"].tap()
        XCTAssertTrue(skript.isSelected)
        XCTAssertFalse(app.staticTexts["examgen.counter.material"].label.hasPrefix("0 von"), "Seiten gezählt")
        shot("examgen-2-alles")

        // "Nichts auswählen" sperrt Weiter wieder
        app.buttons["examgen.none"].tap()
        XCTAssertFalse(next.isEnabled)
        app.buttons["examgen.all"].tap()
        XCTAssertTrue(next.isEnabled)
        next.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Blatt geschlossen, Modulseite wieder da")
    }

    func testWithoutProAITheCardShowsTheLock() {
        let app = launch(plan: "plus")
        let open = app.buttons["examgen.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        XCTAssertEqual(open.label, "Unterlagen auswählen (ab Pro AI)")
        shot("examgen-3-schloss")
        open.tap()
        XCTAssertFalse(app.staticTexts["examgen.title"].waitForExistence(timeout: 3), "mit Plus öffnet sich die Auswahl nicht")
    }
}
