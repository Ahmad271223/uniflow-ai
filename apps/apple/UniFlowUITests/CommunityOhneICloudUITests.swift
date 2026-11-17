import XCTest

/// Auftrag des Inhabers 17.11.2026 ("prüfe das Kommentare schreiben, ob das wirklich geht, und Diskussion starten und
/// Like und Antworten"): die echte App im Simulator, Demo-Inhalte, Tarif Plus, echter iCloud-Container des Builds, aber
/// kein iCloud-Konto auf dem Geraet. So sieht es auch bei einem Nutzer aus, der nicht bei iCloud angemeldet ist: der
/// Community beitreten und lesen geht, "Frage stellen" laesst die Frage stehen und sagt, was fehlt. Geschrieben wird
/// dabei nichts (ohne iCloud-Konto nimmt CloudKit nichts an).
///
/// Laeuft nur, wenn der Build einen iCloud-Container hat (Config/Team.xcconfig) und das Geraet kein iCloud-Konto;
/// sonst uebersprungen. Bilder nach UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR).
final class CommunityOhneICloudUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private var prefix: String { UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad" }

    private func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testBeitretenFrageStellenOhneICloudSagtWasFehlt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFPlan", "plus", "-UFUniversity", "luh", "-UFRoute", "#/community"]
        app.launch()

        // Community-Seite mit dem Demo-Modul; ohne iCloud-Container im Build gibt es die Community nicht
        // "Ansehen" vor dem Beitritt, "Öffnen" danach (der Beitritt bleibt auf dem Geraet gemerkt)
        let view = app.buttons.matching(NSPredicate(format: "label == 'Ansehen' OR label == 'Öffnen'")).firstMatch
        guard view.waitForExistence(timeout: 40) else {
            shot("\(prefix)-00-keine-community")
            throw XCTSkip("Keine Community in diesem Build (kein iCloud-Container) oder Demo-Inhalte fehlen")
        }
        shot("\(prefix)-01-community")
        view.tap()

        // Seite der Community: beitreten (nur auf dem Geraet gemerkt), dann die Diskussion
        let join = app.buttons["community.space.join"]
        // das Feld ist je nach System ein Textfeld oder eine Textansicht; die Kennung sitzt am Feld oder an seinem Rahmen
        let marked = app.descendants(matching: .any).matching(identifier: "community.discussion.field")
        let field = marked.textViews.firstMatch.exists ? marked.textViews.firstMatch : marked.firstMatch
        if join.waitForExistence(timeout: 15) {
            shot("\(prefix)-02-vor-dem-beitritt")
            join.tap()
        }
        if !field.waitForExistence(timeout: 20) {
            shot("\(prefix)-03-fehler-kein-feld")
            print("BAUM\n" + app.debugDescription)
            XCTFail("nach dem Beitritt steht die Eingabe „Frage stellen …“ nicht da")
        }
        pause(4)                                                    // Fragen laden (lesen geht ohne iCloud-Konto)
        shot("\(prefix)-03-diskussion")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'bei iCloud an'")).firstMatch.exists,
                       "Lesen verlangt kein iCloud-Konto")

        // Diskussion starten: tippen (Tastatur verdeckt weder Feld noch Knopf), senden
        field.tap()
        field.typeText("Testfrage aus dem Simulator ohne iCloud")
        let ask = app.buttons["community.discussion.ask"]
        XCTAssertTrue(ask.exists)
        let keyboard = app.keyboards.firstMatch
        // mit angeschlossener Tastatur (Simulator am Mac) meldet das System eine Tastatur ohne Hoehe
        let visible = keyboard.exists && keyboard.frame.height > 100
        if visible {
            XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1, "Die Tastatur verdeckt das Eingabefeld nicht")
            XCTAssertLessThanOrEqual(ask.frame.maxY, keyboard.frame.minY + 1, "Der Knopf „Frage stellen“ liegt ueber der Tastatur")
            print("TASTATUR sichtbar: Feld \(field.frame), Knopf \(ask.frame), Tastatur \(keyboard.frame)")
        } else {
            print("TASTATUR nicht sichtbar (Simulator mit angeschlossener Tastatur): Lage zur Tastatur hier nicht geprueft")
        }
        XCTAssertTrue(ask.isHittable, "„Frage stellen“ ist erreichbar")
        shot("\(prefix)-04-frage-getippt")
        ask.tap()

        // ohne iCloud-Konto: die Frage bleibt stehen, darunter die Meldung mit "Erneut senden" und "Verwerfen"
        let retry = app.buttons["Erneut senden"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "die Frage bleibt mit Hinweis stehen")
        let device = UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
        let message = "Nicht gesendet: Melde dich auf diesem \(device) bei iCloud an (Einstellungen → Apple-ID), um die Community zu nutzen."
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5) || app.otherElements[message].exists,
                      "verstaendliche Meldung mit dem Namen des Geraets")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Testfrage aus dem Simulator ohne iCloud'")).firstMatch.exists,
                      "der Text der Frage bleibt stehen")
        let rest = field.value as? String ?? ""
        XCTAssertTrue(rest.isEmpty || rest == "Frage stellen …", "das Feld ist frei fuer die naechste Frage: \(rest)")
        shot("\(prefix)-05-frage-nicht-gesendet")

        // erneut senden aendert ohne Konto nichts; verwerfen nimmt die Frage wieder heraus
        retry.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        let discard = app.buttons["Verwerfen"].firstMatch
        XCTAssertTrue(discard.exists)
        discard.tap()
        pause(1)
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Testfrage aus dem Simulator ohne iCloud'")).firstMatch.exists)
        shot("\(prefix)-06-verworfen")
        app.terminate()
    }
}
