import XCTest

/// Messhilfe (21.11.2026, Speicher auf kleinen iPads, docs/SPEICHER-STAND.md): drei Demo-Dokumente als Reiter, dann
/// Wechsel reihum durch Antippen der Reiter in der ECHTEN App. An jedem "UFSPEICHER halt" bleibt die App stehen, damit
/// ein Werkzeug aussen (`heap <pid>` am Mac) zaehlen kann, wie viele Editoren und Dokumente im Speicher liegen: Es darf
/// immer nur das aktive sein. Nur mit UNIFLOW_EDITOR_MESSUNG=speicher (sonst uebersprungen): kein Teil der normalen
/// Testlaeufe.
final class SpeicherReiterUITests: XCTestCase {
    func testReiterWechsel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UNIFLOW_EDITOR_MESSUNG"] == "speicher", "nur als Messhilfe")
        let app = XCUIApplication()
        // quer: alle Reiter stehen nebeneinander in der Kopfzeile; danach wieder hoch (andere Tests erwarten das)
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        func launch(_ doc: String) {
            app.launchArguments = ["-UFDemo", "YES", "-UFRoute", "#/doc/\(doc)", "-UFNoStudIPSync", "YES"]
            app.launch()
            let skip = app.buttons["Anmeldung überspringen (Debug)"]
            if skip.waitForExistence(timeout: 4) {
                skip.tap()
                app.terminate()
                app.launch()
            }
            XCTAssertTrue(app.buttons["toolbar.undo"].waitForExistence(timeout: 40), "Editor mit \(doc) offen")
        }
        let docs = ["demo-folien", "demo-blatt", "demo-skript"]
        for doc in docs {
            app.terminate()
            launch(doc)
        }
        func halt(_ n: Int) {
            print("UFSPEICHER halt \(n)")
            NSLog("UFSPEICHER halt %d", n)
            Thread.sleep(forTimeInterval: 14)
        }
        halt(0)
        var switches = 0
        for round in 1...2 {
            for i in 0..<9 {
                let id = "doc.tab.\(docs[i % docs.count])"
                let tab = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertTrue(tab.waitForExistence(timeout: 15), "Reiter \(id)")
                tab.tap()
                XCTAssertTrue(app.buttons["toolbar.undo"].waitForExistence(timeout: 30))
                Thread.sleep(forTimeInterval: 1.5)
                switches += 1
            }
            print("UFSPEICHER wechsel \(switches)")
            halt(round)
        }
    }
}
