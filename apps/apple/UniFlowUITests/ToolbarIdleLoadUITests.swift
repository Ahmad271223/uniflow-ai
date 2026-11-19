import XCTest

/// Messhilfe (18.11.2026, Dauerlast der Leiste oben am iPad Air 4): oeffnet das Demo-Blatt mit Pro AI und haelt es
/// offen (Ruhe, dann Wischen), damit ein Werkzeug aussen die CPU-Zeit des App-Prozesses messen kann. Nur mit
/// UF_TOOLBAR_LOAD=1 (sonst uebersprungen): kein Teil der normalen Testlaeufe.
final class ToolbarIdleLoadUITests: XCTestCase {
    private func run(_ placement: String) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UF_TOOLBAR_LOAD"] == "1", "nur als Messhilfe")
        let app = XCUIApplication()
        app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/demo-blatt", "-UFPlan", "pro_ai", "-UFNoStudIPSync", "YES",
                               "-uniflow.toolbarPlacement", placement]
        app.launch()
        let skip = app.buttons["Anmeldung überspringen (Debug)"]
        if skip.waitForExistence(timeout: 6) {
            skip.tap()
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.otherElements["editor.toolbar"].waitForExistence(timeout: 40) || app.buttons["toolbar.undo"].waitForExistence(timeout: 5),
                      "Leiste sichtbar")
        // mehrere Reiter (wie auf dem Geraet eines Testers): weitere Demo-Dokumente nacheinander oeffnen
        if ProcessInfo.processInfo.environment["UF_TOOLBAR_TABS"] == "1" {
            for doc in ["demo-folien", "demo-skript", "demo-uebung", "demo-vorlesung", "demo-blatt"] {
                app.terminate()
                app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/\(doc)", "-UFPlan", "pro_ai", "-UFNoStudIPSync", "YES",
                                       "-uniflow.toolbarPlacement", placement]
                app.launch()
                _ = app.buttons["toolbar.undo"].waitForExistence(timeout: 30)
            }
        }
        NSLog("UFMESS ruhe-start %f", Date().timeIntervalSince1970)
        Thread.sleep(forTimeInterval: 20)
        NSLog("UFMESS ruhe-ende %f", Date().timeIntervalSince1970)
        let win = app.windows.firstMatch
        let mid = win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for i in 0..<12 {
            let to = win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: i % 4 < 2 ? 0.25 : 0.9))
            mid.press(forDuration: 0.05, thenDragTo: to)
        }
        NSLog("UFMESS wischen-ende %f", Date().timeIntervalSince1970)
        Thread.sleep(forTimeInterval: 5)
    }

    func testTop() throws { try run("top") }
    func testBottom() throws { try run("bottom") }
}
