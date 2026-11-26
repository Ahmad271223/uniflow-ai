import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Durchsicht nach der Meldung "Auf meinem Mac gehen alle Buttons nicht" (26.11.2026): weitere Stellen, an denen etwas bis
/// zum Neustart der App haengen blieb - Rueckfragen (`UFOverlay.confirm`/`prompt`) und der Hinweis zur KI-Einwilligung.
@MainActor
final class PraesentationDurchsichtAppTests: XCTestCase {
    private func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// beantwortet die offene Rueckfrage so, wie es die Knoepfe des Hinweises tun (`UFModalHost.finish`)
    private func answer(_ overlay: UFOverlay, _ value: Bool) {
        guard case .confirm(_, let c)? = overlay.ask else { return XCTFail("keine offene Rückfrage") }
        overlay.askAnswered()
        c.resume(returning: value)
    }

    private func title(_ overlay: UFOverlay) -> String? {
        switch overlay.ask {
        case .confirm(let t, _)?: return t
        case .prompt(let t, _, _)?: return t
        case nil: return nil
        }
    }

    // MARK: - Rueckfragen der Reihe nach

    /// Vorher ueberschrieb die zweite Frage die erste: deren Aufrufer wartete fuer immer, und "OK" unter dem Text der
    /// ersten Frage beantwortete die zweite
    func testSecondQuestionWaitsUntilTheFirstIsAnswered() {
        let overlay = UFOverlay()
        var first: Bool?
        var second: Bool?
        Task { first = await overlay.confirm("Erste Frage?") }
        wait(0.2)
        Task { second = await overlay.confirm("Zweite Frage?") }
        wait(0.3)
        XCTAssertEqual(title(overlay), "Erste Frage?", "die offene Frage bleibt stehen")

        answer(overlay, true)
        wait(0.2)
        XCTAssertEqual(first, true, "die Antwort geht an die erste Frage")
        XCTAssertNil(second, "die zweite ist noch nicht gestellt")
        XCTAssertNil(overlay.ask, "kurze Pause, bis der erste Hinweis verschwunden ist")

        wait(2) { overlay.ask != nil }
        XCTAssertEqual(title(overlay), "Zweite Frage?")
        answer(overlay, false)
        wait(0.2)
        XCTAssertEqual(second, false)
        wait(0.8)
        XCTAssertNil(overlay.ask, "nichts wartet mehr")
    }

    func testSingleQuestionBehavesAsBefore() {
        let overlay = UFOverlay()
        var result: String?
        var done = false
        Task { result = await overlay.prompt("Neuer Name:", value: "alt"); done = true }
        wait(0.2)
        guard case .prompt(let t, let v, let c)? = overlay.ask else { return XCTFail("Rückfrage sofort offen") }
        XCTAssertEqual(t, "Neuer Name:")
        XCTAssertEqual(v, "alt")
        overlay.askAnswered()
        c.resume(returning: "neu")
        wait(0.3) { done }
        XCTAssertEqual(result, "neu")
        XCTAssertNil(overlay.ask)
    }

    // MARK: - Hinweis zur KI-Einwilligung

    private func makeWindow() -> (UIWindow, UIViewController) {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 700)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let root = UIHostingController(rootView: Color.white)
        window.rootViewController = root
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            root.dismiss(animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            window.isHidden = true
            window.rootViewController = nil
        }
        wait(0.3)
        return (window, root)
    }

    /// der oberste gezeigte Inhalt dieses Fensters
    private func consentHost(_ root: UIViewController) -> AIConsentHost? {
        var c: UIViewController? = root
        while let p = c?.presentedViewController { c = p }
        return c as? AIConsentHost
    }

    /// Verschwindet der Hinweis ohne Entscheidung (das Blatt darunter schliesst sich), gilt "Abbrechen" - vorher wartete
    /// die Anfrage und jede weitere KI-Anfrage bis zum Neustart
    func testConsentThatDisappearsWithoutADecisionCountsAsCancel() throws {
        let (_, root) = makeWindow()
        let under = UIHostingController(rootView: Text("Test erstellen"))
        root.present(under, animated: false)
        wait(1) { under.viewIfLoaded?.window != nil }

        var decisions: [Bool] = []
        XCTAssertTrue(AIConsentCenter.presentOverTopController { decisions.append($0) }, "Hinweis gezeigt")
        wait(2) { self.consentHost(root)?.viewIfLoaded?.window != nil }
        XCTAssertNotNil(consentHost(root), "Hinweis liegt über dem Blatt")
        XCTAssertTrue(UFSheetHold.alertOnScreen(), "fällige Blätter warten, solange der Hinweis steht")
        XCTAssertEqual(decisions, [])

        root.dismiss(animated: false)                                   // das Blatt darunter schliesst sich
        wait(3) { !decisions.isEmpty }
        XCTAssertEqual(decisions, [false], "ohne Entscheidung verschwunden: Abbrechen, genau einmal")
        wait(0.5)
        XCTAssertEqual(decisions, [false])
        XCTAssertFalse(UFSheetHold.alertOnScreen())
    }

    /// UIKit lehnt das Zeigen ab (das Blatt darunter verschwindet gerade): der Hinweis erscheint nie, die Anfrage endet
    /// trotzdem mit "Abbrechen" statt fuer immer zu warten
    func testConsentThatIsNeverShownCountsAsCancel() {
        let (_, root) = makeWindow()
        let under = UIHostingController(rootView: Text("Blatt"))
        root.present(under, animated: false)
        wait(1) { under.viewIfLoaded?.window != nil }
        wait(0.5)
        root.dismiss(animated: true)                                    // verschwindet gerade
        var decisions: [Bool] = []
        XCTAssertTrue(AIConsentCenter.presentOverTopController { decisions.append($0) })
        wait(AIConsentCenter.neverShownAfter + 2) { !decisions.isEmpty }
        if consentHost(root) == nil {
            XCTAssertEqual(decisions, [false], "nie gezeigt: Abbrechen")
        } else {
            // UIKit hat den Hinweis doch noch gezeigt (aufgeschoben): dann wartet er wie immer auf die Knoepfe
            XCTAssertEqual(decisions, [])
        }
    }

    func testConsentDecisionIsReportedOnce() throws {
        let (_, root) = makeWindow()
        var decisions: [Bool] = []
        XCTAssertTrue(AIConsentCenter.presentOverTopController { decisions.append($0) })
        wait(2) { self.consentHost(root)?.viewIfLoaded?.window != nil }
        let host = try XCTUnwrap(consentHost(root))
        host.rootView.decide(true)                                      // "Okay, los"
        wait(3) { root.presentedViewController == nil }
        wait(0.5)
        XCTAssertEqual(decisions, [true], "die Entscheidung zählt, das Verschwinden danach nicht noch einmal")
    }

    func testCenterAnswersEveryWaitingRequestWhenTheConsentDisappears() async {
        // Zentrum mit einem Hinweis, der ohne Entscheidung verschwindet
        var decide: (@MainActor (Bool) -> Void)?
        let suite = "consent-durchsicht-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = AIConsentCenter(store: AIConsentStore(defaults: defaults), present: { d in decide = d; return true })
        async let a = center.ensure(account: "konto")
        async let b = center.ensure(account: "konto")
        try? await Task.sleep(nanoseconds: 200_000_000)
        decide?(false)                                                  // wie `AIConsentHost.onGone`
        let answers = await [a, b]
        XCTAssertEqual(answers, [false, false], "beide Anfragen enden, keine wartet weiter")
        // die naechste Anfrage fragt wieder (nichts haengt)
        decide = nil
        async let c = center.ensure(account: "konto")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(decide, "neuer Hinweis")
        decide?(true)
        let granted = await c
        XCTAssertTrue(granted)
    }

    // MARK: - Teilen

    /// "Original herunterladen" am iPhone: das Menue schliesst sich, gleich danach kommt das Teilen-Menue. Es wartet,
    /// bis das Blatt weg ist (vorher: aus dem schliessenden Blatt heraus gezeigt)
    func testShareWaitsUntilAClosingSheetIsGone() throws {
        let (_, root) = makeWindow()
        let under = UIHostingController(rootView: Text("Menü"))
        root.present(under, animated: false)
        wait(1) { under.viewIfLoaded?.window != nil }
        wait(0.5)
        root.dismiss(animated: true)                                    // schliesst sich gerade
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teilen-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        UFShare.present([url])
        wait(5) { root.presentedViewController is UIActivityViewController }
        XCTAssertTrue(root.presentedViewController is UIActivityViewController, "Teilen-Menü erscheint über der Seite, nachdem das Blatt weg ist")
        XCTAssertNil(under.presentingViewController, "das Blatt ist geschlossen")
    }
}
