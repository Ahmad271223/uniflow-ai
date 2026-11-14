import XCTest

/// Video und Lernseite neben dem Dokument (Grundlage, docs/VIDEO-LERNSEITEN-2026-11-14.md): mit echten Beruehrungen
/// ueber "Daneben öffnen" oeffnen und schliessen. Braucht Netz fuer die Inhalte; geprueft wird die Spalte selbst.
final class WebSideUITests: XCTestCase {

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

    private func reveal(_ e: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !e.isHittable { app.swipeUp() }
    }

    func testOpenLearningSiteAndVideoBeside() {
        let app = launch()
        XCTAssertTrue(app.buttons["companion.blank.lined"].waitForExistence(timeout: 20), "„Daneben öffnen“")
        let wiki = app.buttons["web.site.wikipedia-de"]
        for _ in 0..<8 where !(wiki.exists && wiki.isHittable) { app.swipeUp() }
        XCTAssertTrue(wiki.waitForExistence(timeout: 5), "Lernseiten unter „Daneben öffnen“")
        shot("1-daneben-oeffnen-video-lernseite")
        wiki.tap()
        let close = app.buttons["site.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Lernseite daneben")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        shot("2-lernseite-wikipedia")
        close.tap()
        XCTAssertTrue(waitGone(close))
        app.terminate()

        let again = launch()
        XCTAssertTrue(again.buttons["companion.blank.lined"].waitForExistence(timeout: 20))
        let field = again.textFields["web.videoLink"]
        for _ in 0..<8 where !(field.exists && field.isHittable) { again.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://www.youtube.com/watch?v=aqz-KE-bpKQ")
        again.buttons["web.videoOpen"].tap()
        let vclose = again.buttons["video.close"]
        XCTAssertTrue(vclose.waitForExistence(timeout: 10), "Video daneben")
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        shot("3-video-daneben")
        vclose.tap()
        XCTAssertTrue(waitGone(vclose))
        again.terminate()
    }

    private func waitGone(_ e: XCUIElement) -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end { if !e.exists { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return !e.exists
    }
    /// Einstieg ueber "Mehr" › "Video oder Lernseite daneben …": Auswahl mit Video und Lernseiten oben (Bild fuer den
    /// Inhaber), dann ein YouTube-Video daneben
    func testEntryFromMoreMenuShowsVideoAndSitesFirst() {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/demo-blatt", "-uniflow.toolbarPlacement", "bottom"]
        app.launch()
        let more = app.buttons["Mehr"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        let entry = app.buttons["doc.webSide"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Eintrag im Menue „Mehr“")
        entry.tap()
        let field = app.textFields["web.videoLink"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Video oben in der Auswahl")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        shot("4-auswahl-video-lernseiten")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'web.site.'")).firstMatch.waitForExistence(timeout: 5),
                      "Lernseiten gleich darunter")
        let wiki = app.buttons["web.site.wikipedia-de"]
        for _ in 0..<4 where !(wiki.exists && wiki.isHittable) { app.swipeUp() }
        XCTAssertTrue(wiki.waitForExistence(timeout: 5), "Wikipedia in der Liste")
        shot("4b-auswahl-lernseiten-weiter")
        for _ in 0..<4 where !field.isHittable { app.swipeDown() }
        field.tap()
        field.typeText("https://youtu.be/aqz-KE-bpKQ?t=95")
        app.buttons["web.videoOpen"].tap()
        XCTAssertTrue(app.buttons["video.close"].waitForExistence(timeout: 10), "Video daneben")
        RunLoop.current.run(until: Date().addingTimeInterval(8))
        shot("5-video-spalte")
        app.terminate()
    }
}
