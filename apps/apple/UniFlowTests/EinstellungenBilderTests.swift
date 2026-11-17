import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bilder der Einstellungen fuer den Vergleich vorher/nachher (Auftrag 17.11.2026 "mach Einstellungen übersichtlicher"):
/// jede Seite der Einstellungen in der echten Huelle (`MainView`) mit den Demo-Inhalten, am iPad quer (1210 x 834) und
/// am iPhone 17 (402 x 874), je als Bildschirm und als ganze Seite, hell; die erste Seite zusaetzlich dunkel.
/// Laeuft nur mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR); UF_SETTINGS_TABS (Komma-Liste) waehlt
/// die Seiten, sonst die Bereiche der neuen Gliederung.
@MainActor
final class EinstellungenBilderTests: XCTestCase {
    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var background: BackgroundSyncController!
    private var oldSidebar: String?

    static let ipad = CGSize(width: 1210, height: 834)
    static let iphone = CGSize(width: 402, height: 874)

    override func setUp() async throws {
        try await super.setUp()
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        bed = try ContainerTestBed(name: "einstellungen-bilder", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        Rufname.write("Lea", container.defaults)
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: StoreScreenshotTests.EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        UserDefaults.standard.set("full", forKey: "sidebar")
    }

    override func tearDown() async throws {
        if bed != nil {
            UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
            CommunityRoute.shared.service = nil
            Entitlements.shared.setPlanForTesting(.free)
            manager.deactivate()
            await bed.tearDown()
        }
        try await super.tearDown()
    }

    func testEinstellungenIPad() throws {
        try shootAll(size: Self.ipad, prefix: "ipad-quer", compact: false)
    }

    /// "IPhone" im Namen: `UniFlowTestsPrincipal` schaltet die iPhone-Fassung ein
    func testEinstellungenIPhone() throws {
        UFCompact.phoneOverride = true
        defer { UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault }
        try shootAll(size: Self.iphone, prefix: "iphone", compact: true)
    }

    // MARK: - Aufnahme

    private var tabs: [String?] {
        let raw = ProcessInfo.processInfo.environment["UF_SETTINGS_TABS"] ?? "start,account,uni,look,modules,plan,community,help,advanced,dev"
        return raw.split(separator: ",").map { $0 == "start" ? nil : String($0) }
    }

    private func shootAll(size: CGSize, prefix: String, compact: Bool) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"] ?? "", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = MainView()
            .environment(\.ufDemoActive, true)
            .environment(\.ufChatGPTLink, manager.chatgpt)
            .environment(\.ufStudoraAccount, manager.account)
            .environment(\.backgroundSync, background)
            .environment(\.uniMail, manager.uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        let env = try hostWithEnvironment(root, api: container.api, size: size, studip: manager.studip)
        if compact {
            env.hosting.traitOverrides.horizontalSizeClass = .compact
            env.hosting.traitOverrides.verticalSizeClass = .regular
        }
        for (i, tab) in tabs.enumerated() {
            let name = String(format: "%@-%02d-%@", prefix, i + 1, tab ?? "start")
            env.router.go(.dashboard); env.pump(0.4)
            env.window.frame = CGRect(origin: .zero, size: size)
            env.view.frame = env.window.bounds
            env.router.go(.settings(tab: tab))
            env.pump(2.5)
            for (style, tone) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] where style == .light || i == 0 {
                env.window.overrideUserInterfaceStyle = style
                env.pump(0.6)
                write(env, to: dir.appendingPathComponent("\(name)-\(tone).png"), scale: 2)
            }
            env.window.overrideUserInterfaceStyle = .light
            // ganze Seite: das Fenster so hoch wie der Inhalt der Seite
            for _ in 0..<2 {
                let extra = Self.scrollViews(env.view).map { $0.contentSize.height - $0.bounds.height }.max() ?? 0
                guard extra > 1 else { break }
                let h = min(env.window.frame.height + extra + 8, 12_000)
                env.window.frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: h))
                env.view.frame = env.window.bounds
                env.pump(1.5)
            }
            if env.window.frame.height > size.height + 1 {
                write(env, to: dir.appendingPathComponent("\(name)-ganz-hell.png"), scale: 1)
            }
            env.window.overrideUserInterfaceStyle = .unspecified
        }
    }

    private static func scrollViews(_ v: UIView) -> [UIScrollView] {
        let own: [UIScrollView] = (v as? UIScrollView).map { $0.contentSize.height > $0.bounds.height + 1 ? [$0] : [] } ?? []
        return own + v.subviews.flatMap(scrollViews)
    }

    private func write(_ env: HostedEnvironment, to file: URL, scale: CGFloat) {
        let view = env.view
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
    }
}
