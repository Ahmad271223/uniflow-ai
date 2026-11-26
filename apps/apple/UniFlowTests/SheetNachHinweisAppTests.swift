import SwiftUI
import UIKit
import XCTest
@testable import UniFlow

/// Meldung des Inhabers am Mac (26.11.2026, Store-Version 1.0.7, Build 48): "Auf meinem Mac gehen alle Buttons nicht."
/// Beim Start stand kurz der Hinweis "Bitte neu anmelden" (`askForLoginIfDue`), im selben Moment wollte die App ein Blatt
/// oeffnen. UIKit lehnte ab ("Attempt to present … which is already presenting <SwiftUI.PlatformAlertController>"),
/// SwiftUI schloss den Hinweis von selbst, hielt das Blatt fuer offen und liess danach kein weiteres mehr auf
/// ("Currently, only presenting a single sheet is supported") - bis zum Neustart der App. Ohne `UFSheetHold` laeuft das
/// im iPad-Simulator genauso ab (nachgestellt am 26.11.2026): der Hinweis verschwindet nach weniger als einer Sekunde,
/// kein Blatt erscheint, auch nicht nach Zuruecknehmen und neu Verlangen.
@MainActor
final class SheetNachHinweisAppTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var ask = false
        @Published var first = false
        @Published var second = false
    }

    nonisolated(unsafe) static var appeared: [String] = []

    struct Root: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack {
                Text("Wurzel")
                    .ufSheet(isPresented: $model.first) { Text("eins").onAppear { SheetNachHinweisAppTests.appeared.append("eins") } }
                Text("Zweite")
                    .ufSheet(isPresented: $model.second) { Text("zwei").onAppear { SheetNachHinweisAppTests.appeared.append("zwei") } }
            }
            .alert("Bitte neu anmelden", isPresented: $model.ask) {
                Button("Abbrechen", role: .cancel) {}
                Button("OK") {}
            }
        }
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func makeHost(_ model: Model) -> UIHostingController<Root> {
        Self.appeared = []
        let frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let host = UIHostingController(rootView: Root(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            host.dismiss(animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.isHidden = true
            window.rootViewController = nil
        }
        wait(0.3)
        return host
    }

    /// Blatt wirklich zu sehen: von UIKit gezeigt und im Fenster
    private func sheetOnScreen(_ host: UIViewController) -> Bool {
        guard let p = host.presentedViewController, !(p is UIAlertController) else { return false }
        return p.viewIfLoaded?.window != nil && !p.isBeingDismissed
    }

    /// Der Hinweis steht, ein Blatt wird faellig: der Hinweis bleibt, das Blatt kommt nach der Antwort, spaetere auch
    func testSheetWaitsForTheAlertAndOpensAfterwards() {
        let model = Model()
        let host = makeHost(model)
        model.ask = true
        wait(5) { host.presentedViewController is UIAlertController }
        XCTAssertTrue(host.presentedViewController is UIAlertController, "Hinweis offen")

        model.first = true
        wait(1.5)
        XCTAssertTrue(model.ask, "der Hinweis bleibt stehen, bis der Nutzer antwortet (vorher schloss SwiftUI ihn von selbst)")
        XCTAssertTrue(host.presentedViewController is UIAlertController, "Hinweis weiter zu sehen")
        XCTAssertTrue(model.first, "das Blatt bleibt verlangt")

        model.ask = false                                                   // der Nutzer antwortet
        wait(6) { self.sheetOnScreen(host) }
        XCTAssertTrue(sheetOnScreen(host), "das faellige Blatt erscheint, sobald der Hinweis weg ist")
        XCTAssertTrue(Self.appeared.contains("eins"))

        model.first = false
        wait(4) { host.presentedViewController == nil }
        XCTAssertNil(host.presentedViewController, "Blatt wieder zu")
        model.second = true
        wait(6) { self.sheetOnScreen(host) && Self.appeared.contains("zwei") }
        XCTAssertTrue(sheetOnScreen(host), "spaetere Blaetter gehen weiter auf")
        XCTAssertTrue(Self.appeared.contains("zwei"))
    }

    /// Umgekehrte Reihenfolge (im iPad-Simulator nachgestellt, 26.11.2026): ist ein Blatt offen und verlangt die Wurzel
    /// einen Hinweis, schliesst SwiftUI das Blatt, und der Hinweis erscheint nie. Die Frage "Bitte neu anmelden" wartet
    /// darum, solange etwas offen ist (`UFSheetHold.presentationOnScreen`, `askForLoginIfDue`).
    func testPresentationOnScreenSeesSheetsAndAlerts() {
        let model = Model()
        let host = makeHost(model)
        XCTAssertFalse(UFSheetHold.presentationOnScreen(), "nichts offen")
        XCTAssertFalse(UFSheetHold.alertOnScreen())

        model.first = true
        wait(6) { self.sheetOnScreen(host) }
        XCTAssertTrue(UFSheetHold.presentationOnScreen(), "Blatt offen: von selbst kommende Fragen warten")
        XCTAssertFalse(UFSheetHold.alertOnScreen(), "ein Blatt ist kein Hinweis")

        model.first = false
        wait(4) { host.presentedViewController == nil }
        XCTAssertFalse(UFSheetHold.presentationOnScreen())

        model.ask = true
        wait(5) { host.presentedViewController is UIAlertController }
        XCTAssertTrue(UFSheetHold.alertOnScreen(), "Hinweis offen: faellige Blaetter warten")
        XCTAssertTrue(UFSheetHold.presentationOnScreen())
        model.ask = false
        wait(4) { host.presentedViewController == nil }
        XCTAssertFalse(UFSheetHold.alertOnScreen())
    }

    // MARK: - UFSheetHold

    func testHoldPassesAtOnceWithoutAnAlert() {
        let hold = UFSheetHold()
        hold.alertOnScreen = { false }
        XCTAssertFalse(hold.pass(false), "nicht verlangt")
        XCTAssertTrue(hold.pass(true), "verlangt, kein Hinweis: sofort")
        XCTAssertEqual(hold.released, 0)
    }

    func testHoldKeepsTheSheetBackWhileAnAlertIsShownAndReleasesItAfterwards() {
        let hold = UFSheetHold()
        var alert = true
        hold.alertOnScreen = { alert }
        XCTAssertFalse(hold.pass(true), "Hinweis steht: zurueckhalten")
        XCTAssertFalse(hold.pass(true))
        wait(0.5)
        XCTAssertEqual(hold.released, 0, "solange der Hinweis steht, keine Freigabe")
        alert = false
        wait(2) { hold.released == 1 }
        XCTAssertEqual(hold.released, 1, "Hinweis weg: die Ansicht fragt neu")
        XCTAssertTrue(hold.pass(true))
    }

    func testHoldKeepsAnOpenSheetOpenAndStartsAgainAfterClosing() {
        let hold = UFSheetHold()
        var alert = false
        hold.alertOnScreen = { alert }
        XCTAssertTrue(hold.pass(true))
        alert = true
        XCTAssertTrue(hold.pass(true), "schon offen: bleibt offen, auch wenn ein Hinweis dazukommt")
        XCTAssertFalse(hold.pass(false), "geschlossen")
        XCTAssertFalse(hold.pass(true), "neu verlangt, Hinweis steht: zurueckhalten")
        XCTAssertFalse(hold.pass(false), "zurueckgenommen: nicht weiter warten")
        alert = false
        wait(0.5)
        XCTAssertEqual(hold.released, 0, "zurueckgenommenes Blatt wird nicht nachtraeglich freigegeben")
    }
}
