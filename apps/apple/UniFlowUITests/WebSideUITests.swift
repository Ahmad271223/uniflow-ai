import UIKit
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

    private func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// YouTube oeffnen bis zur geladenen Seite: Hinweis vor dem ersten Oeffnen (wenn er noch nicht bestaetigt ist),
    /// dann die Web-Ansicht. Fragt YouTube nach der Einwilligung, wird "Alle ablehnen" gewaehlt.
    private func openYouTube(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        let open = app.buttons["web.youtubeOpen"]
        for _ in 0..<8 where !(open.exists && open.isHittable) { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 5), "„YouTube öffnen“ in der Auswahl")
        XCTAssertTrue(app.textFields["web.videoLink"].exists, "„YouTube-Link einfügen“ bleibt als zweiter Weg")
        shot(prefix + "1-auswahl-youtube-oeffnen")
        open.tap()
        let ok = app.buttons["youtube.noticeOpen"]
        if ok.waitForExistence(timeout: 8) {
            XCTAssertFalse(app.webViews.firstMatch.exists, "vor „Öffnen“ keine Web-Ansicht")
            pause(1)
            shot(prefix + "2-hinweis-vor-dem-ersten-oeffnen")
            ok.tap()
        }
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20), "YouTube in der Spalte")
        XCTAssertTrue(web.buttons["In YouTube suchen"].firstMatch.waitForExistence(timeout: 40)
                        || web.buttons["Alle ablehnen"].firstMatch.exists, "YouTube lädt")
        let reject = web.buttons["Alle ablehnen"].firstMatch
        if reject.exists {
            shot(prefix + "2b-einwilligung-von-youtube")
            reject.tap()
            XCTAssertTrue(web.buttons["In YouTube suchen"].firstMatch.waitForExistence(timeout: 40), "nach der Einwilligung YouTube")
        }
        pause(3)
        shot(prefix + "3-youtube-geladen")
        return web
    }

    /// In YouTube suchen und das erste Ergebnis antippen; zwei Bilder im Abstand zeigen, dass das Video laeuft
    private func searchAndPlay(_ app: XCUIApplication, web: XCUIElement, prefix: String) {
        web.buttons["In YouTube suchen"].firstMatch.tap()
        let field = web.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Suchfeld von YouTube")
        field.typeText("fourier reihe\n")
        let hit = web.links.matching(NSPredicate(format: "label CONTAINS[c] 'Fourier'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "Suchergebnisse")
        pause(3)
        shot(prefix + "4-suche")
        hit.tap()
        XCTAssertTrue(web.otherElements["YouTube-Videoplayer"].firstMatch.waitForExistence(timeout: 30), "Video-Seite")
        pause(12)
        shot(prefix + "5-video-laeuft")
        pause(6)
        shot(prefix + "5b-video-sechs-sekunden-spaeter")
    }

    /// YouTube selbst in der Spalte (Auftrag 17.11.2026), mit echtem Netz: Hinweis, Laden, Suche, Video, Zurueck und
    /// Vor, Anmelden nur als Hinweis, Link nach aussen verlaesst die App, "Zuletzt hier" oeffnet das Video wieder.
    /// Haengt am Aufbau der YouTube-Seite (deutsche Beschriftungen); bei Aenderungen dort anpassen.
    func testYouTubeBesideDocument() throws {
        try XCTSkipIf(isPhone, "iPad: Spalte daneben")
        let app = launch()
        XCTAssertTrue(app.buttons["companion.blank.lined"].waitForExistence(timeout: 30), "„Daneben öffnen“")
        let web = openYouTube(app, prefix: "ipad-")
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH 'youtube.'")).firstMatch.exists, "keine Adresszeile")
        searchAndPlay(app, web: web, prefix: "ipad-")

        // Zurueck zur Suche, Vor zum Video
        let back = app.buttons["youtube.back"], forward = app.buttons["youtube.forward"]
        XCTAssertTrue(back.isEnabled, "Zurück nach der Suche")
        back.tap()
        XCTAssertTrue(web.links.matching(NSPredicate(format: "label CONTAINS[c] 'Fourier'")).firstMatch.waitForExistence(timeout: 20))
        pause(2)
        shot("ipad-6-zurueck-zur-suche")
        XCTAssertTrue(forward.isEnabled, "Vor nach Zurück")
        forward.tap()
        XCTAssertTrue(web.otherElements["YouTube-Videoplayer"].firstMatch.waitForExistence(timeout: 20), "Vor: wieder das Video")

        // Anmelden: nur der Hinweis, keine Anmeldeseite, die App bleibt vorn
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        app.buttons["youtube.home"].tap()
        let mine = web.buttons["Mein YouTube"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 30), "Startseite von YouTube")
        mine.tap()
        let signIn = web.links["Anmelden"].firstMatch
        XCTAssertTrue(signIn.waitForExistence(timeout: 20))
        signIn.tap()
        XCTAssertTrue(app.buttons["youtube.signInOK"].waitForExistence(timeout: 10), "Hinweis „Anmelden geht hier nicht“")
        XCTAssertFalse(web.secureTextFields.firstMatch.exists, "kein Passwortfeld in der Spalte")
        XCTAssertNotEqual(safari.state, .runningForeground)
        shot("ipad-7-anmelden-geht-hier-nicht")
        app.buttons["youtube.signInOK"].tap()

        // Link nach aussen (hier: "App öffnen" auf der Video-Seite fuehrt zum App Store bzw. zu einer fremden Adresse)
        back.tap()
        back.tap()
        let appLink = web.links["App öffnen"].firstMatch
        if appLink.waitForExistence(timeout: 20) {
            appLink.tap()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20) || app.wait(for: .runningBackground, timeout: 5),
                          "Link nach außen verlässt die App")
            pause(2)
            shot("ipad-8-link-nach-aussen-oeffnet-ausserhalb")
            app.activate()
            XCTAssertTrue(app.buttons["youtube.close"].waitForExistence(timeout: 15), "zurück in der App steht YouTube noch daneben")
        }
        app.buttons["youtube.close"].tap()
        XCTAssertTrue(waitGone(app.buttons["youtube.close"]))
        app.terminate()

        // "Zuletzt hier": das auf YouTube angesehene Video steht in der Auswahl und oeffnet wieder in der YouTube-Spalte
        let again = launch()
        XCTAssertTrue(again.buttons["companion.blank.lined"].waitForExistence(timeout: 30))
        let last = again.buttons["web.lastVideo"]
        for _ in 0..<8 where !(last.exists && last.isHittable) { again.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5), "„Zuletzt hier: YouTube-Video“")
        shot("ipad-9-zuletzt-hier")
        last.tap()
        XCTAssertTrue(again.buttons["youtube.close"].waitForExistence(timeout: 15), "öffnet wieder in der YouTube-Spalte")
        XCTAssertTrue(again.webViews.firstMatch.otherElements["YouTube-Videoplayer"].firstMatch.waitForExistence(timeout: 40), "das Video")
        pause(4)
        shot("ipad-10-zuletzt-hier-geoeffnet")
        again.terminate()
    }

    /// iPhone (Leseansicht ohne Spalte): "Video oder Lernseite" im Kopf, YouTube ueber dem Dokument, Teilung verschieben,
    /// schliessen. Mit echtem Netz.
    func testYouTubeAboveReaderOnPhone() throws {
        try XCTSkipUnless(isPhone, "iPhone: über dem Dokument")
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/demo-blatt"]
        app.launch()
        let entry = app.buttons["phoneReader.web"]
        XCTAssertTrue(entry.waitForExistence(timeout: 40), "Knopf „Video oder Lernseite“ in der Leseansicht")
        pause(2)
        shot("iphone-0-leseansicht")
        entry.tap()
        let web = openYouTube(app, prefix: "iphone-")
        XCTAssertTrue(app.otherElements["phoneReader.pdf"].exists || app.staticTexts["phoneReader.page"].exists
                        || app.buttons["phoneReader.page"].exists, "das Dokument bleibt darunter sichtbar")
        searchAndPlay(app, web: web, prefix: "iphone-")
        let handle = app.otherElements["web.over.handle"]
        if handle.exists {
            handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            pause(2)
            shot("iphone-6-teilung-verschoben")
        }
        app.buttons["youtube.close"].tap()
        XCTAssertTrue(waitGone(app.buttons["youtube.close"]))
        pause(1)
        shot("iphone-7-geschlossen")
        app.terminate()
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
