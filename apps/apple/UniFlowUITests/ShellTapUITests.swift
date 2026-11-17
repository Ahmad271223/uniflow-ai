import XCTest

/// Auftrag des Inhabers 17.11.2026: "wenn man auf das Männchen klickt unten links, das soll irgendeine Funktion haben
/// ... wenn man draufklickt kommt Einstellung" und "wenn man auf das StudiNow-Logo klickt, soll man immer zur
/// Hauptseite zurückgehen". Echte Berührungen (XCUITest), weil der Inhaber am iPad erlebt hat, dass das Antippen des
/// Profils nichts tut: Profilkarte der Seitenleiste (ausgeklappt und eingeklappt, ohne Namen = Männchen-Symbol) öffnet
/// die Einstellungen, das Logo der Seitenleiste führt zur Übersicht; am iPhone Logo und Profil der Kopfzeile.
final class ShellTapUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func launch(route: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", route, "-UFNoStudIPSync", "YES"] + extra
        if !isPhone { XCUIDevice.shared.orientation = .landscapeLeft }       // iPad quer: Seitenleiste sichtbar
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Einstellungen offen: Seitenkopf "Einstellungen" und der Zurück-Pfeil (die Übersicht hat keinen)
    private func settingsOpen(_ app: XCUIApplication) -> Bool {
        app.buttons["nav.back"].waitForExistence(timeout: 8) && app.staticTexts["Einstellungen"].waitForExistence(timeout: 8)
    }

    /// Übersicht offen: Begrüßung und kein Zurück-Pfeil
    private func dashboardOpen(_ app: XCUIApplication) -> Bool {
        let greeting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hallo'")).firstMatch
        return greeting.waitForExistence(timeout: 8) && !app.buttons["nav.back"].exists
    }

    // MARK: iPad

    func testSidebarProfileOpensSettings() throws {
        try XCTSkipIf(isPhone, "Seitenleiste nur am iPad")
        let app = launch(route: "#/dashboard")
        let profile = app.buttons["sidebar.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 25), "Profilkarte unten in der Seitenleiste")
        XCTAssertTrue(profile.isHittable, "Profilkarte antippbar")
        shot("ipad-seitenleiste-vor-tipp")
        profile.tap()
        XCTAssertTrue(settingsOpen(app), "Antippen der Profilkarte öffnet die Einstellungen")
        shot("ipad-nach-tipp-auf-profil")
        XCTAssertFalse(app.buttons["nav.Einstellungen"].exists, "keine eigene Zeile „Einstellungen“ mehr im Fuß der Seitenleiste")
    }

    /// Mitten auf das Männchen (Avatar) getippt, nicht auf den Namen
    func testSidebarAvatarOpensSettings() throws {
        try XCTSkipIf(isPhone, "Seitenleiste nur am iPad")
        let app = launch(route: "#/dashboard")
        let profile = app.buttons["sidebar.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 25))
        // der Avatar steht links in der Karte: 17 pt vom linken Rand, mittig
        profile.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 17, dy: 0)).tap()
        XCTAssertTrue(settingsOpen(app), "Antippen des Männchens öffnet die Einstellungen")
    }

    func testCollapsedSidebarAvatarOpensSettings() throws {
        try XCTSkipIf(isPhone, "Seitenleiste nur am iPad")
        let app = launch(route: "#/dashboard", extra: ["-sidebar", "min"])
        let profile = app.buttons["sidebar.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 25), "eingeklappt: Avatar unten")
        XCTAssertTrue(profile.isHittable)
        profile.tap()
        XCTAssertTrue(settingsOpen(app), "eingeklappt: Avatar öffnet die Einstellungen")
        shot("ipad-eingeklappt-nach-tipp-auf-profil")
    }

    /// Tipp wie mit dem Apple Pencil: etwas laenger gedrueckt und dabei 4 pt bewegt
    func testSidebarProfilePencilLikeTap() throws {
        try XCTSkipIf(isPhone, "Seitenleiste nur am iPad")
        let app = launch(route: "#/dashboard")
        let profile = app.buttons["sidebar.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 25))
        let start = profile.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: start.withOffset(CGVector(dx: 4, dy: 1)))
        XCTAssertTrue(settingsOpen(app), "Stift-Tipp auf die Profilkarte öffnet die Einstellungen")
    }

    /// Schon in den Einstellungen: die Karte bleibt antippbar und ist markiert (vorher sah man dann keine Reaktion)
    func testProfileCardIsMarkedWhileSettingsAreOpen() throws {
        try XCTSkipIf(isPhone, "Seitenleiste nur am iPad")
        let app = launch(route: "#/settings")
        let profile = app.buttons["sidebar.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 25))
        XCTAssertTrue(profile.isSelected, "Profilkarte markiert, solange die Einstellungen offen sind")
        XCTAssertTrue(profile.isHittable)
        shot("ipad-einstellungen-offen-profil-markiert")
    }

    /// iPad hochkant (keine feste Seitenleiste): Menue-Knopf oeffnet die Schublade, dort oeffnet die Profilkarte die
    /// Einstellungen und das Logo fuehrt zur Übersicht
    func testDrawerProfileAndLogoInPortrait() throws {
        try XCTSkipIf(isPhone, "Schublade nur am iPad")
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/modules", "-UFNoStudIPSync", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        let menu = app.buttons["header.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25), "hochkant: Menü-Knopf")
        menu.tap()
        let profile = app.buttons["sidebar.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 8), "Schublade mit Profilkarte")
        profile.tap()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 8), "Profilkarte der Schublade öffnet die Einstellungen")
        XCTAssertFalse(profile.exists, "Schublade schließt")
        menu.tap()
        let logo = app.buttons["sidebar.home"]
        XCTAssertTrue(logo.waitForExistence(timeout: 8))
        logo.tap()
        XCTAssertTrue(dashboardOpen(app), "Logo der Schublade führt zur Übersicht")
    }

    // MARK: Stundenplan mit Hinweisen (iPad und iPhone)

    /// Der Stundenplan ist ohne Lernkalender der Kalender: die Hinweise oben am Tag (Termin aus Ankündigung, Frist,
    /// Test, Klausur) stehen da und öffnen beim Antippen das Detail
    func testTimetableHintsOpenDetail() throws {
        let app = launch(route: "#/timetable", extra: ["-UFCalendarSample", "YES"])
        let chips = app.buttons.matching(identifier: "day-hint")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 30), "Hinweise im Stundenplan")
        XCTAssertGreaterThanOrEqual(chips.count, 3, "Raumänderung, Ausfall, Klausur, Abgabe")
        let labels = (0..<chips.count).map { chips.element(boundBy: $0).label }
        XCTAssertTrue(labels.contains { $0.contains("Klausur") }, "\(labels)")
        shot(isPhone ? "iphone-stundenplan-hinweise" : "ipad-stundenplan-hinweise")
        chips.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hint.kind"].waitForExistence(timeout: 8), "Detail des Hinweises öffnet")
        shot(isPhone ? "iphone-stundenplan-hinweis-detail" : "ipad-stundenplan-hinweis-detail")
        XCTAssertFalse(app.buttons["nav.plan"].exists, "kein Lernkalender im Menü")
    }

    func testSidebarLogoLeadsToDashboard() throws {
        try XCTSkipIf(isPhone, "Seitenleiste nur am iPad")
        for extra in [[], ["-sidebar", "min"]] {
            let app = launch(route: "#/modules", extra: extra)
            let logo = app.buttons["sidebar.home"]
            XCTAssertTrue(logo.waitForExistence(timeout: 25), "Logo oben in der Seitenleiste ist ein Knopf \(extra)")
            XCTAssertTrue(app.buttons["nav.back"].waitForExistence(timeout: 8), "Start auf „Meine Module“")
            logo.tap()
            XCTAssertTrue(dashboardOpen(app), "Logo führt zur Übersicht \(extra)")
            app.terminate()
        }
    }

    // MARK: iPhone

    func testPhoneHeaderLogoAndProfile() throws {
        try XCTSkipIf(!isPhone, "kompakte Kopfzeile nur am iPhone")
        let app = launch(route: "#/modules")
        let profile = app.buttons["header.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 25))
        profile.tap()
        XCTAssertTrue(app.staticTexts["Einstellungen"].waitForExistence(timeout: 8), "Profil der Kopfzeile öffnet die Einstellungen")
        shot("iphone-nach-tipp-auf-profil")
        let home = app.buttons["header.home"]
        XCTAssertTrue(home.isHittable)
        home.tap()
        let greeting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hallo'")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 8), "Logo der Kopfzeile führt zur Übersicht")
    }

    /// Untere Leiste ohne Lernkalender: "Stundenplan" statt "Kalender", Tippen zeigt den Stundenplan
    func testPhoneBarShowsTimetable() throws {
        try XCTSkipIf(!isPhone, "untere Leiste des iPhone")
        let app = launch(route: "#/dashboard")
        let tab = app.buttons["mobileNav.timetable"]
        XCTAssertTrue(tab.waitForExistence(timeout: 25), "„Stundenplan“ in der unteren Leiste")
        XCTAssertFalse(app.buttons["mobileNav.plan"].exists, "kein „Kalender“ (Lernkalender) mehr")
        tab.tap()
        XCTAssertTrue(app.staticTexts["Stundenplan"].waitForExistence(timeout: 8))
        shot("iphone-stundenplan-aus-leiste")
    }
}
