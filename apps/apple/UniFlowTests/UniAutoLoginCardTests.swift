import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Karte "Uni-Zugang" in den Einstellungen (Vorgabe des Inhabers 10.11.2026): Schalter "Benutzername und Passwort sind
/// überall gleich" (Vorgabe an) -> ein Formular; aus -> Stud.IP, QIS und Uni-Mail (SOGo) untereinander, jedes mit
/// Benutzername, Passwort, "Speichern", Status und "Entfernen". Texte kurz, Passwort nie in Bedienungshilfen-Werten.
@MainActor
final class UniAutoLoginCardTests: XCTestCase {
    private let user = "testnutzer-erfunden"
    private let password = "Pw-Test-erfunden-123"
    private var services: [String] = []
    private var suite = ""

    override func setUp() async throws {
        suite = "uniflow.tests.unilogin.card.\(UUID().uuidString)"
        UniAutoLogin.settingsDefaultsOverride = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        UniAutoLogin.settingsDefaultsOverride = nil
        UserDefaults().removePersistentDomain(forName: suite)
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
    }

    // MARK: Logik der Karte

    func testSwitchDefaultsOnAndChoosesOneOrThreeForms() {
        XCTAssertTrue(UniAutoLogin.sameEverywhere, "Vorgabe an")
        XCTAssertEqual(UniAutoLoginCard.slots(sameEverywhere: true, university: .luh), [nil])
        XCTAssertEqual(UniAutoLoginCard.slots(sameEverywhere: false, university: .luh), [.studip, .qis, .sogo])
        XCTAssertEqual(UniAutoLoginCard.slots(sameEverywhere: false, university: .hildesheim), [nil], "getrennt nur an der LUH")
        XCTAssertEqual(UniAutoLogin.Portal.allCases.map(\.title), ["Stud.IP", "QIS", "Uni-Mail (SOGo)"])
        UniAutoLogin.sameEverywhere = false
        XCTAssertEqual(UserDefaults(suiteName: suite)?.object(forKey: UniAutoLogin.sameEverywhereKey) as? Bool, false)
        XCTAssertFalse(UniAutoLogin.sameEverywhere)
        UniAutoLogin.sameEverywhere = true
        XCTAssertTrue(UniAutoLogin.sameEverywhere)
        XCTAssertEqual(UniAutoLoginCard.sameTitle, "Benutzername und Passwort sind überall gleich")
    }

    func testTextsAreShortAndHonest() {
        XCTAssertTrue(UniAutoLoginCard.text(.luh).contains("nur auf diesem iPad"))
        XCTAssertTrue(UniAutoLoginCard.text(.luh).contains("Stud.IP, QIS und Uni-Mail"))
        XCTAssertTrue(UniAutoLoginCard.note.contains("nur im Schlüsselbund dieses iPads") && UniAutoLoginCard.note.contains("nie auf unseren Servern"))
        XCTAssertEqual(UniAutoLoginCard.statusText(.saved(user), portal: true), "Gespeichert für: \(user)")
        XCTAssertEqual(UniAutoLoginCard.statusText(.missing, portal: true, shared: user), "Kein eigenes Passwort – es gilt das gemeinsame (\(user)).")
        XCTAssertEqual(UniAutoLoginCard.statusText(.rejected, portal: false), UniAutoLoginCard.rejectedText)
        XCTAssertEqual(UniAutoLoginCard.badge(.saved(user)).text, "gespeichert")
        XCTAssertEqual(UniAutoLoginCard.badge(.missing).text, "fehlt")
        XCTAssertEqual(UniAutoLoginCard.badge(.rejected).text, "abgelehnt")
        XCTAssertNil(UniAutoLoginCard.saveMessage(.saved))
        XCTAssertNotNil(UniAutoLoginCard.saveMessage(.badUsername))
        // Ergebnis nach "Speichern": verbunden / Anmeldung nötig / Passwort abgelehnt
        XCTAssertEqual(UniAutoLoginCard.resultText(StoredLoginReport(connected: ["Stud.IP", "QIS", "Uni-Mail"])),
                       "Verbunden: Stud.IP, QIS, Uni-Mail.")
        XCTAssertEqual(UniAutoLoginCard.resultText(StoredLoginReport(connected: ["Stud.IP"], needsLogin: ["QIS"])),
                       "Verbunden: Stud.IP. Anmeldung nötig: QIS.")
        XCTAssertEqual(UniAutoLoginCard.resultText(StoredLoginReport(connected: ["Stud.IP"], needsLogin: ["QIS"], rejected: true, rejectedPortals: ["QIS"])),
                       "Verbunden: Stud.IP. Passwort abgelehnt (QIS). Bitte prüfe es und speichere es neu.")
        XCTAssertEqual(UniAutoLoginCard.resultText(StoredLoginReport(noCredential: true)), "Noch kein Passwort gespeichert.")
    }

    // MARK: Karte im Fenster (beide Schalterstellungen)

    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        addTeardownBlock { _ = Self.accessibilityAutomation(false) }
        let frame = CGRect(x: 0, y: 0, width: 800, height: 1600)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: ScrollView { view.padding(16) })
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func texts(_ view: UIView) -> [String] {
        view.layoutIfNeeded()
        var out: [String] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                out += [o.accessibilityLabel, o.accessibilityValue, (o as? UIAccessibilityIdentification)?.accessibilityIdentifier].compactMap { $0 }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out.filter { !$0.isEmpty }
    }

    private func shown(_ view: UIView, containing id: String) async throws -> [String] {
        let end = Date().addingTimeInterval(10)
        var t: [String] = []
        while Date() < end {
            t = texts(view)
            if t.contains(id) { return t }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("nicht gezeigt: \(id) in \(t)")
        return t
    }

    private func card(_ m: ContainerManager) -> some View {
        UniAutoLoginCard().environmentObject(m).environmentObject(UFToastCenter())
    }

    func testCardShowsOneFormWhenSameEverywhereAndThreeWhenNot() async throws {
        let bed = try ContainerTestBed(name: "unilogin-karte", clock: .fixed(berlin: "2026-11-10T09:00:00")!)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        services.append(m.credentialService)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: m.studip.websiteDataStore), .saved)

        // an: ein Formular fuer alle (der Bedienungshilfen-Baum nennt Beschriftungen, die Kennungen nur am Schalter)
        let one = host(card(m))
        let a = try await shown(one, containing: "Für alle Dienste")
        XCTAssertTrue(a.contains("settings.unilogin.same"))
        XCTAssertTrue(a.contains(UniAutoLoginCard.sameTitle))
        XCTAssertEqual(a.filter { $0 == "Speichern" }.count, 1, "ein Formular")
        XCTAssertTrue(a.contains("Benutzername") && a.contains("Passwort"))
        XCTAssertTrue(a.contains("Entfernen"), "gespeichert: Entfernen")
        XCTAssertTrue(a.contains("Gespeichert für: \(user)"))
        XCTAssertTrue(a.contains(UniAutoLoginCard.note))
        for p in UniAutoLogin.Portal.allCases where p != .studip && p != .qis { XCTAssertFalse(a.contains(p.title), p.rawValue) }
        XCTAssertFalse(a.contains { $0.contains(password) }, "das Passwort steht nie in Bedienungshilfen-Werten")

        // aus: Stud.IP, QIS und Uni-Mail (SOGo) je mit eigenem Formular
        UniAutoLogin.sameEverywhere = false
        let three = host(card(m))
        let b = try await shown(three, containing: "Uni-Mail (SOGo)")
        for p in UniAutoLogin.Portal.allCases { XCTAssertTrue(b.contains(p.title), p.rawValue) }
        XCTAssertFalse(b.contains("Für alle Dienste"))
        XCTAssertEqual(b.filter { $0 == "Speichern" }.count, 3, "drei Formulare")
        XCTAssertGreaterThanOrEqual(b.filter { $0 == "Benutzername" }.count, 3)
        XCTAssertGreaterThanOrEqual(b.filter { $0 == "Passwort" }.count, 3)
        XCTAssertEqual(b.filter { $0 == "Kein eigenes Passwort – es gilt das gemeinsame (\(user))." }.count, 3, "Status je Portal")
        XCTAssertEqual(b.filter { $0 == "fehlt" }.count, 3)
        XCTAssertFalse(b.contains("Entfernen"), "ohne eigenen Eintrag kein Entfernen")
        XCTAssertFalse(b.contains { $0.contains(password) })
        await bed.tearDown()
    }
}
