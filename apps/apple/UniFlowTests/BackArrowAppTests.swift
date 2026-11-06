import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Zurueck-Pfeil auf jeder Seite ausser der Startseite (Wunsch des Inhabers 06.11.2026): Verlauf im Rahmen
/// (A -> B -> Zurück = A), ohne Verlauf zur Startseite, Zurueck innerhalb einer Seite zuerst, auf der Startseite kein
/// Pfeil, sonst genau einer (Kopfzeile; im Dokument ohne Kopfzeile der Pfeil der Werkzeugleiste). Mit
/// UF_BACK_SHOT (xcodebuild: TEST_RUNNER_UF_BACK_SHOT) schreibt `testScreenshot` ein Bild einer Seite mit Pfeil.
@MainActor
final class BackArrowAppTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    // MARK: - Verlauf

    func testBackReturnsToPreviousPage() {
        let r = UFRouter()
        r.go(.modules)                                   // A
        r.go(.mensa)                                     // B
        r.goBack()
        XCTAssertEqual(r.route, .modules, "A -> B -> Zurück = A")
        r.goBack()
        XCTAssertEqual(r.route, .dashboard, "dann die Seite davor (Start)")
        XCTAssertFalse(r.canGoBack)
    }

    func testBackKeepsParametersOfPreviousPage() {
        let r = UFRouter()
        r.go(.plan(view: "day", date: "2026-11-06"))
        r.go(.doc("d1", page: 3))
        r.goBack()
        XCTAssertEqual(r.route, .plan(view: "day", date: "2026-11-06"), "Dokument schliesst dorthin, wo es geoeffnet wurde")
    }

    func testNoHistoryGoesHome() {
        let r = UFRouter(start: .rooms)
        XCTAssertFalse(r.canGoBack)
        r.goBack()
        XCTAssertEqual(r.route, .dashboard, "ohne Verlauf zur Startseite")
        r.goBack()
        XCTAssertEqual(r.route, .dashboard, "auf der Startseite bleibt es dabei")
    }

    func testBackResetsDrawerAndFullscreen() {
        let r = UFRouter()
        r.go(.files())
        r.go(.doc("d1"))
        r.fullscreenDoc = true
        r.drawerOpen = true
        r.goBack()
        XCTAssertEqual(r.route, .files())
        XCTAssertFalse(r.fullscreenDoc)
        XCTAssertFalse(r.drawerOpen)
    }

    func testLocalBackComesFirstAndEndsWithPageChange() {
        let r = UFRouter()
        r.go(.messages)
        var closed = 0
        r.setLocalBack(id: "reader") { closed += 1 }
        r.goBack()
        XCTAssertEqual(closed, 1, "erst das Offene in der Seite schliessen")
        XCTAssertEqual(r.route, .messages, "die Seite bleibt")
        r.goBack()
        XCTAssertEqual(r.route, .dashboard)
        XCTAssertEqual(closed, 1)
        // ein Seitenwechsel loescht es; ein fremdes Loeschen nicht
        r.go(.messages)
        r.setLocalBack(id: "reader") { closed += 1 }
        r.setLocalBack(id: "anderes", nil)
        r.go(.modules)
        r.goBack()
        XCTAssertEqual(r.route, .messages)
        XCTAssertEqual(closed, 1)
    }

    func testOnlyHomeHasNoArrow() {
        XCTAssertFalse(UFRouter.showsBackArrow(on: .dashboard))
        let others: [UFRoute] = [.messages, .plan(), .timetable(), .modules, .module(1), .studyPlan(), .files(), .doc("x"), .exams,
                                 .exam(1), .cards, .aiStart, .services, .community, .communitySpace("k"), .settings(), .mensa,
                                 .rooms, .uniMail]
        for r in others { XCTAssertTrue(UFRouter.showsBackArrow(on: r), "\(r)") }
    }

    // MARK: - Gerendert

    /// Knoepfe mit diesem Namen auf dem Bildschirm; derselbe Knopf, im Baum ueber zwei Wege erreichbar, zaehlt einmal
    /// (gleiche Stelle)
    private func count(_ label: String, in env: HostedEnvironment) -> Int {
        var frames = Set<String>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 50 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel == label, o.accessibilityTraits.contains(.button) {
                    let f = o.accessibilityFrame
                    frames.insert("\(Int(f.midX.rounded())),\(Int(f.midY.rounded()))")
                }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let c = o.accessibilityElementCount()
                if c != NSNotFound, c > 0 { for i in 0..<min(c, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        env.view.layoutIfNeeded()
        visit(env.view, depth: 0)
        return frames.count
    }

    private func activate(_ label: String, in env: HostedEnvironment) -> Bool {
        var hit: NSObject?
        func visit(_ element: Any, depth: Int) {
            guard depth < 50, hit == nil else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel == label, o.accessibilityTraits.contains(.button) { hit = o; return }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let c = o.accessibilityElementCount()
                if c != NSNotFound, c > 0 { for i in 0..<min(c, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        env.view.layoutIfNeeded()
        visit(env.view, depth: 0)
        return hit?.accessibilityActivate() ?? false
    }

    /// Rahmen mit einfacher Seite je Route; im Dokument (ohne Kopfzeile) traegt die Seite den Pfeil der Werkzeugleiste
    private func shell(size: CGSize) throws -> HostedEnvironment {
        try hostWithEnvironment(AppShell { route in
            if case .doc = route {
                VStack { HStack { UFBackButton(style: .header); Spacer() }; Text("Dokument"); Spacer() }
            } else {
                Text("Seite \(route.navKey)")
            }
        }, size: size)
    }

    func testHomeHasNoArrowOtherPagesExactlyOne() throws {
        for size in [CGSize(width: 1180, height: 820), CGSize(width: 590, height: 820)] {
            let env = try shell(size: size)
            XCTAssertTrue(env.wait { env.labels().contains("Seite dashboard") }, env.labels().joined(separator: "\n"))
            XCTAssertEqual(count("Zurück", in: env), 0, "Startseite ohne Pfeil (\(size.width))")
            env.router.go(.modules)
            env.router.go(.mensa)
            XCTAssertTrue(env.wait { self.count("Zurück", in: env) == 1 }, "genau ein Pfeil (\(size.width)): " + env.labels().joined(separator: " | "))
            XCTAssertTrue(activate("Zurück", in: env))
            XCTAssertTrue(env.wait { env.router.route == .modules }, "\(env.router.route)")
            if size.width < 700 {
                // schmal (iPhone-Fassung, docs/IPHONE-2026-11-04.md): "Module" ist eine Wurzel der unteren Leiste, ohne
                // Pfeil; zur Startseite geht es ueber die Leiste (IPhoneBackArrowTests)
                XCTAssertTrue(env.wait { self.count("Zurück", in: env) == 0 }, "Wurzel der Leiste ohne Pfeil (\(size.width))")
                continue
            }
            XCTAssertTrue(activate("Zurück", in: env))
            XCTAssertTrue(env.wait { env.router.route == .dashboard }, "\(env.router.route)")
            XCTAssertTrue(env.wait { self.count("Zurück", in: env) == 0 }, "wieder auf der Startseite ohne Pfeil")
        }
    }

    func testDocumentArrowClosesToWhereItWasOpened() throws {
        let env = try shell(size: CGSize(width: 1180, height: 820))
        env.router.go(.module(7))
        env.router.go(.doc("d1"))
        XCTAssertTrue(env.wait { env.labels().contains("Dokument") }, env.labels().joined(separator: "\n"))
        XCTAssertEqual(count("Zurück", in: env), 1, "im Dokument nur der Pfeil der Werkzeugleiste (Kopfzeile aus)")
        XCTAssertTrue(activate("Zurück", in: env))
        XCTAssertTrue(env.wait { env.router.route == .module(7) }, "\(env.router.route)")
    }

    func testArrowOutsideShellShowsNothing() throws {
        // ohne Rahmen (Editor in Tests, Vorschau) kein Pfeil ohne Ziel
        let env = try hostWithEnvironment(VStack { UFBackButton(style: .header); Text("ohne Rahmen") }, size: CGSize(width: 400, height: 300))
        XCTAssertTrue(env.wait { env.labels().contains("ohne Rahmen") })
        XCTAssertEqual(count("Zurück", in: env), 0)
        // mit eigener Aufgabe (Vollbild-Leser) schon
        var tapped = false
        let own = try hostWithEnvironment(UFBackButton(style: .header) { tapped = true }, size: CGSize(width: 400, height: 300))
        XCTAssertTrue(own.wait { self.count("Zurück", in: own) == 1 })
        XCTAssertTrue(activate("Zurück", in: own))
        XCTAssertTrue(own.wait { tapped })
    }

    // MARK: - Bild

    /// Leere Wolke im Speicher: die Community gilt als verbunden (wie DesignShellAppTests)
    private final class EmptyCloud: CommunityCloud, @unchecked Sendable {
        func accountStatus() async throws -> CommunityAccountStatus { .available }
        func userRecordName() async throws -> String { "_demo" }
        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord { record }
        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? { nil }
        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] { [] }
        func delete(name: String, type: String, in scope: CommunityScope) async throws {}
    }

    private func pumping<T>(_ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(30)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { throw XCTSkip("Zeitueberschreitung") }
        return try result.get()
    }

    /// Seite "Meine Module" mit Demo-Inhalten und Pfeil oben links als PNG nach UF_BACK_SHOT
    func testScreenshot() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_BACK_SHOT"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_BACK_SHOT")
        }
        let bed = try ContainerTestBed(name: "back-arrow", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }
        let manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        let account = bed.account(.luh)
        let container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try pumping { try await manager.setDemo(true) }
        Rufname.write("Tobi", container.defaults)
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        let oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        defer {
            CommunityRoute.shared.service = nil
            Entitlements.shared.setPlanForTesting(.free)
            UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
            manager.deactivate()
        }
        UserDefaults.standard.set("full", forKey: "sidebar")
        let size = CGSize(width: 1376, height: 1032)
        let env = try hostWithEnvironment(MainView().environment(\.ufDemoActive, true).environment(\.ufDemoBarHidden, true)
            .environmentObject(manager).environmentObject(account), api: container.api, size: size, studip: manager.studip)
        env.window.overrideUserInterfaceStyle = .light
        env.pump(1.0)
        env.router.go(.modules)
        _ = env.wait(timeout: 15) { env.labels().contains { $0.contains("Grundlagen der Informatik") } }
        env.pump(1.5)
        XCTAssertEqual(count("Zurück", in: env), 1, env.labels().joined(separator: " | "))
        env.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let png = UIGraphicsImageRenderer(bounds: env.view.bounds, format: format).pngData { _ in
            _ = env.view.drawHierarchy(in: env.view.bounds, afterScreenUpdates: true)
        }
        try png.write(to: URL(fileURLWithPath: path))
        try pumping { await bed.tearDown() }
    }
}
