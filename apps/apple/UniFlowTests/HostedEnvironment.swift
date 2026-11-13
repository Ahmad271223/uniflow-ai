import Security
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gehostete Ansicht mit allen neun Umgebungsobjekten der Wurzel (Audit Robustheit 03.11.2026, P3-7): `AccountStore`,
/// `ContainerManager`, `Session`, `StudIPSync`, `UFRouter`, `ShellState`, `UFToastCenter`, `UFOverlay`, `StudyTimer`,
/// dazu Dialoge (`UFModalHost`) und Meldungen (`UFToastOverlay`) wie in `UniFlowApp`/`SceneObjects`. Eine Ansicht, die
/// eines davon liest, stuerzt im Test so nicht ab, nur weil der Test es vergessen hat (der Absturz in `UFReloadModifier`
/// am 03.11.2026 war genau das). Alles mit eigenem Temp-Ordner, eigener UserDefaults-Suite und eigenen
/// Schluesselbund-Diensten; nichts davon bleibt nach dem Test.
@MainActor
final class HostedEnvironment {
    let account: AccountStore
    let containers: ContainerManager
    let session: Session
    let studip: StudIPSync
    let router = UFRouter()
    let shell = ShellState()
    let toast = UFToastCenter()
    let overlay = UFOverlay()
    let timer: StudyTimer
    let window: UIWindow
    let hosting: UIViewController

    var view: UIView { hosting.view }

    fileprivate init(account: AccountStore, containers: ContainerManager, session: Session, studip: StudIPSync?, timer: StudyTimer,
                     size: CGSize, content: (HostedEnvironment) -> AnyView) {
        self.account = account
        self.containers = containers
        self.session = session
        self.studip = studip ?? containers.studip
        self.timer = timer
        let frame = CGRect(origin: .zero, size: size)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        hosting = UIHostingController(rootView: AnyView(EmptyView()))
        (hosting as? UIHostingController<AnyView>)?.rootView = content(self)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
    }

    /// Die Ansicht mit allen Umgebungsobjekten (wie die Wurzel der App)
    func apply<V: View>(_ view: V) -> some View {
        view
            .modifier(UFModalHost(overlay: overlay))
            .modifier(UFToastOverlay(center: toast))
            .environmentObject(account)
            .environmentObject(containers)
            .environmentObject(session)
            .environmentObject(studip)
            .environmentObject(router)
            .environmentObject(shell)
            .environmentObject(toast)
            .environmentObject(overlay)
            .environmentObject(timer)
    }

    /// Hauptschleife laufen lassen (Antworten, `.task`, Layout)
    func pump(_ seconds: Double = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        view.layoutIfNeeded()
    }

    /// Wartet hoechstens `timeout` Sekunden, bis `condition` gilt; true, wenn sie gilt
    @discardableResult
    func wait(timeout: Double = 10, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { pump(0.05) }
        return condition()
    }

    /// Beschriftungen aus dem Bedienungshilfen-Baum (ohne Doppelte, in der Reihenfolge des Baums); braucht
    /// `HostedEnvironment.accessibilityAutomation(true)`
    func labels() -> [String] {
        view.layoutIfNeeded()
        var out: [String] = []
        var seen = Set<String>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if let l = o.accessibilityLabel, !l.isEmpty, seen.insert(l).inserted { out.append(l) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    /// Erstes Element mit Knopf-Eigenschaft, auf das `match` passt (Bedienungshilfen-Baum)
    func accessibleButton(where match: (NSObject) -> Bool) -> NSObject? {
        view.layoutIfNeeded()
        var hit: NSObject?
        func visit(_ element: Any, depth: Int) {
            guard depth < 50, hit == nil else { return }
            if let o = element as? NSObject {
                if o.accessibilityTraits.contains(.button), match(o) { hit = o; return }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return hit
    }

    /// Knopf mit genau dieser Beschriftung antippen wie VoiceOver; false, wenn es ihn nicht gibt
    @discardableResult
    func activate(_ label: String) -> Bool {
        accessibleButton { $0.accessibilityLabel == label }?.accessibilityActivate() ?? false
    }

    /// Moduldetail: alle zugeklappten Wochen aufklappen (Wochen starten zugeklappt, 13.11.2026); Anzahl aufgeklappter
    @discardableResult
    func openWeeks() -> Int {
        var n = 0
        while n < 60, let e = accessibleButton(where: { $0.accessibilityValue == "zugeklappt" }), e.accessibilityActivate() {
            n += 1
            pump(0.4)
        }
        return n
    }

    /// SwiftUI baut den Bedienungshilfen-Baum nur, wenn ein Hilfsmittel aktiv ist: Automation ein- und wieder
    /// ausschalten wie bei UI-Tests (nur im Test, libAccessibility des Simulators). false, wenn es das nicht gibt.
    @discardableResult
    static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }
}

private final class HostedMemorySecrets: AccountSecretStore {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) { values[key] = value }
    func delete(_ key: String) { values[key] = nil }
}

private struct HostedAuthorized: AppleCredentialChecking {
    func state(forUserID id: String) async -> AppleCredentialState { .authorized }
}

extension XCTestCase {
    /// Hostet `view` mit allen neun Umgebungsobjekten der Wurzel in einem Fenster der Groesse `size` (Standard: iPad
    /// quer). `api`: Datenquelle der Sitzung (Standard: lokal ohne Container); `studip`: Abgleich der Ansicht (sonst der
    /// leere des Containers wie in der App ohne Hochschule). Fenster, Ordner, Einstellungen und Schluesselbund-Eintraege
    /// verschwinden mit dem Ende des Tests. Neue Ansichtstests sollen nur ueber diese Hilfe hosten.
    @MainActor
    func hostWithEnvironment<V: View>(_ view: V, api: APIClient = .local(.unavailable), size: CGSize = CGSize(width: 1180, height: 820),
                                      studip: StudIPSync? = nil) throws -> HostedEnvironment {
        let suite = "uniflow.tests.hosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)")
        let cookieService = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
        let account = AccountStore(secrets: HostedMemorySecrets(), defaults: defaults, checker: HostedAuthorized(), observeRevocation: false)
        let containers = ContainerManager(
            base: dir.appendingPathComponent("UniFlowContainers", isDirectory: true),
            legacy: LegacyDataMigration.Sources(support: dir.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: dir.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: keychain, cookieService: cookieService, defaults: defaults, publishesCurrent: false)
        let hosted = HostedEnvironment(account: account, containers: containers, session: Session(local: api, defaults: defaults),
                                       studip: studip, timer: StudyTimer(defaults: defaults), size: size) { env in AnyView(env.apply(view)) }
        addTeardownBlock { @MainActor in
            hosted.window.isHidden = true
            hosted.window.rootViewController = nil
            keychain.accounts().forEach(keychain.remove)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: cookieService] as CFDictionary)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        return hosted
    }
}
