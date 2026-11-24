import XCTest

/// "Konto löschen" in der ECHTEN App durchspielen (24.11.2026, Nachstellung: auf dem iPad des Inhabers entstand beim
/// Loeschen kein Aufbewahrungsbereich). Nur im Simulator mit "Anmeldung überspringen (Debug)": kein Apple-Konto, kein
/// StudiNow-Konto, nichts beim Dienst. Der Simulator hat keinen Geraetecode, also "LÖSCHEN" eintippen. Danach prueft das
/// Werkzeug aussen den Ordner (`xcrun simctl get_app_container … data`). Nur mit UNIFLOW_KONTO_LOESCHEN=1.
final class KontoLoeschenUITests: XCTestCase {
    func testDeleteThroughTheDialogKeepsData() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFLOW_KONTO_LOESCHEN"] == "1", "nur zur Nachstellung")
        let app = XCUIApplication()
        app.launchArguments = ["-UFRoute", "#/settings?tab=account", "-UFNoStudIPSync", "YES"]
        app.launch()
        let skip = app.buttons["Anmeldung überspringen (Debug)"]
        if skip.waitForExistence(timeout: 4) {
            skip.tap()
            app.terminate()
            app.launch()
        }
        let open = app.buttons["Konto löschen"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30), "Einstellungen → Konto")
        open.tap()
        let immediately = app.switches["delete.immediately"]
        XCTAssertTrue(immediately.waitForExistence(timeout: 10), "Dialog offen")
        print("UFKONTO schalter=\(immediately.value ?? "-")")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Konto löschen")).allElementsBoundByIndex.last!
        confirm.tap()
        // Simulator: die Systemabfrage des Geraetecodes erscheint ueber SpringBoard (jede Eingabe gilt)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let code = springboard.secureTextFields.firstMatch
        if code.waitForExistence(timeout: 6) {
            print("UFKONTO systemabfrage")
            code.typeText("1234\n")
        } else {
            print("UFKONTO sb=\(springboard.debugDescription.prefix(3000))")
        }
        let typed = app.textFields["delete.typed"]
        let found = typed.waitForExistence(timeout: 4)
        print("UFKONTO feld=\(found) dialog=\(immediately.exists) meldung=\(app.staticTexts["delete.ownerProblem"].exists ? app.staticTexts["delete.ownerProblem"].label : "-")")
        if found {
            typed.tap()
            typed.typeText("LÖSCHEN")
            app.buttons.matching(NSPredicate(format: "label == %@", "Konto löschen")).allElementsBoundByIndex.last!.tap()
        }
        let welcome = skip.waitForExistence(timeout: 30)
        if !welcome { print("UFKONTO danach dialog=\(immediately.exists) sb=\(springboard.debugDescription.prefix(3000))") }
        XCTAssertTrue(welcome, "zurück zur Begrüßung")
        print("UFKONTO geloescht")
    }
}
