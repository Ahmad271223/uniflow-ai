import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bilder der Uebersicht (Startseite) fuer den Inhaber (13.11.2026, Auftrag "Startseite entruempeln", `DashboardTidy`):
/// echte Wurzel der App (`RootView`) mit Demo-Inhalten, grosses iPad (13 Zoll quer, 1376 x 1032) und kleines iPad (mini hochkant,
/// 744 x 1133), hell und dunkel; je Groesse zusaetzlich die ganze Seite ("lang", alles untereinander).
///
/// Ohne UF_STARTSEITE_DIR (xcodebuild: TEST_RUNNER_UF_STARTSEITE_DIR) prueft der Test nur, dass die Seite erscheint.
@MainActor
final class StartseiteBilderAppTests: XCTestCase {

    static let big = CGSize(width: 1376, height: 1032)
    static let small = CGSize(width: 744, height: 1133)

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer?
    private var background: BackgroundSyncController!
    private var outDir: URL?
    private var oldSidebar: String?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        UFReleaseUniversities.shipped = UFReleaseUniversities.storeDefault
        bed = try ContainerTestBed(name: "startseite-bilder", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(),
                               observeRevocation: false)
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        Entitlements.shared.setPlanForTesting(.free)
        Entitlements.shared.useLocalTrial(startedAt: nil)
        UFGreeting.hourOverride = 12
        oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        UserDefaults.standard.set("full", forKey: "sidebar")
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_STARTSEITE_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
        UFGreeting.hourOverride = nil
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.setPlanForTesting(.free)
        UniStubProtocol.reset()
        manager.onChange = nil
        manager.deactivate()
        await bed.tearDown()
        UFReleaseUniversities.reset()
        try await super.tearDown()
    }

    private struct Root: View {
        @ObservedObject var manager: ContainerManager
        @ObservedObject var account: AccountStore
        let background: BackgroundSyncController

        var body: some View {
            RootView()
                .environment(\.qis, manager.qis)
                .environment(\.uniMail, manager.uniMail)
                .environment(\.ufChatGPTLink, manager.chatgpt)
                .environment(\.ufStudoraAccount, manager.account)
                .modifier(UFAIAccessProvider(chatgpt: manager.chatgpt, account: manager.account))
                .environment(\.backgroundSync, background)
                .environment(\.ufDemoActive, manager.demoActive)
                .environmentObject(manager.studip)
                .environmentObject(manager)
                .environmentObject(account)
        }
    }

    private func openDemo() async throws {
        account.signIn(userID: bed.user, name: "Ada Erfunden", email: nil, givenName: "Ada")
        account.markPlanShown()
        account.chooseUniversity(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        Rufname.write("Ada", container!.defaults)
    }

    private func host() throws -> HostedEnvironment {
        let env = try hostWithEnvironment(Root(manager: manager, account: account, background: background),
                                          api: container?.api ?? .local(.unavailable), size: Self.big, studip: manager.studip)
        manager.onChange = { [weak session = env.session] c in session?.useLocal(c?.api ?? .local(.unavailable)) }
        env.pump(0.5)
        return env
    }

    private func pumping<T>(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { XCTFail("Zeitueberschreitung"); throw CancellationError() }
        return try result.get()
    }

    private func resize(_ env: HostedEnvironment, _ size: CGSize) {
        env.hosting.traitOverrides.horizontalSizeClass = size.width < 700 ? .compact : .regular
        env.window.frame = CGRect(origin: .zero, size: size)
        env.view.frame = env.window.bounds
    }

    private func texts(_ env: HostedEnvironment) -> [String] {
        LayoutWidthAuditTests.elements(in: env.window).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }
    }

    /// groesste senkrechte Bildlaufflaeche (Inhalt der Seite)
    private func pageScroll(_ env: HostedEnvironment) -> UIScrollView? {
        var best: UIScrollView?
        func visit(_ v: UIView) {
            if let s = v as? UIScrollView, s.frame.width > 300, s.contentSize.height > (best?.contentSize.height ?? 0) { best = s }
            v.subviews.forEach(visit)
        }
        visit(env.window)
        return best
    }

    private func shoot(_ env: HostedEnvironment, _ name: String) {
        guard let outDir else { return }
        let window = env.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        do { try data.write(to: outDir.appendingPathComponent(name + ".png")) } catch { XCTFail("\(name): \(error)") }
    }

    /// je Groesse und Farbe ein Bild, wie es auf dem Bildschirm steht, und (hell) die ganze Seite
    private func photograph(_ env: HostedEnvironment, prefix: String) {
        for (size, label) in [(Self.big, "gross"), (Self.small, "klein")] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                env.window.overrideUserInterfaceStyle = style
                resize(env, size)
                env.pump(1.2)
                shoot(env, "\(prefix)-\(label)-\(style == .dark ? "dunkel" : "hell")")
            }
            // ganze Seite: Fenster so hoch wie der Inhalt
            env.window.overrideUserInterfaceStyle = .light
            resize(env, CGSize(width: size.width, height: 6000))
            env.pump(1.2)
            let content = pageScroll(env)?.contentSize.height ?? size.height
            resize(env, CGSize(width: size.width, height: min(6000, max(size.height, content + 80))))
            env.pump(1.0)
            shoot(env, "\(prefix)-\(label)-lang")
        }
        env.window.overrideUserInterfaceStyle = .unspecified
        resize(env, Self.big)
        env.pump(0.3)
    }

    /// Demo-Inhalte, Free, keine Probe: aufgeraeumte Uebersicht (13.11.2026, `DashboardTidy`); nichts verschwindet
    /// ersatzlos
    func test01DemoFree() throws {
        try pumping { try await self.openDemo() }
        let env = try host()
        XCTAssertTrue(env.wait(timeout: 20) { self.texts(env).contains { $0.contains("Hallo Ada") } }, "Uebersicht erscheint")
        env.pump(2)
        photograph(env, prefix: "a-demo-free")
        let t = texts(env)
        XCTAssertFalse(t.contains { $0 == "Nächste Termine" }, "Nächste Termine entfaellt")
        XCTAssertTrue(t.contains { $0.contains("Abgaben & Prüfungen") }, "Abgaben stehen in Abgaben & Prüfungen")
        XCTAssertTrue(t.contains { $0.contains("Diese Woche") }, "Aufgaben erledigt steht in Diese Woche")
        XCTAssertTrue(t.contains { $0.contains("nachzuholen") && $0.contains("geplant") }, "Minuten und Nachzuholendes in der Tageszeile:\n" + t.joined(separator: "\n"))
        XCTAssertTrue(t.contains { $0 == "Tagesansicht" }, "Tagesansicht als Link in Heute für dich geplant")
        XCTAssertTrue(t.contains { $0.contains("Heute in der Mensa") }, "Mensa bleibt (unten)")
        if let outDir {
            try? t.joined(separator: "\n").write(to: outDir.appendingPathComponent("a-demo-free-texte.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Probe und Pro AI ohne Anmeldung: beide Hinweise bleiben (Inhaber 13.11.2026: "Nur ein Hinweis oben" nicht
    /// freigegeben)
    func test02DemoMitHinweisen() throws {
        try pumping { try await self.openDemo() }
        Entitlements.shared.useLocalTrial(startedAt: Date())
        let env = try host()
        XCTAssertTrue(env.wait(timeout: 20) { self.texts(env).contains { $0.contains("Hallo Ada") } }, "Uebersicht erscheint")
        env.pump(2)
        photograph(env, prefix: "b-probe")
        let probe = texts(env)
        // ob eine Probe angezeigt wird, entscheidet `TrialBanner.content` (haengt am Probe-Stand des Geraets, den andere
        // Tests im selben Lauf veraendern); wenn ja, steht sie da - neben dem KI-Hinweis, nicht statt seiner
        if TrialBanner.content(ent: .shared, service: manager.account.planStatus) != nil {
            XCTAssertTrue(probe.contains { $0.contains("Probe") }, "Probe-Hinweis bleibt:\n" + probe.joined(separator: "\n"))
        }
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.setPlanForTesting(.proAI)
        env.pump(2)
        photograph(env, prefix: "c-proai")
        if let outDir {
            try? texts(env).joined(separator: "\n").write(to: outDir.appendingPathComponent("c-proai-texte.txt"), atomically: true, encoding: .utf8)
        }
    }
}
