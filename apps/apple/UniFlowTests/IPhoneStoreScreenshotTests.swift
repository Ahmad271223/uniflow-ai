import PencilKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// App-Store-Bildschirmfotos fuer das iPhone 6,9" (iPhone 17 Pro Max: 440 x 956 Punkte, Massstab 3 = 1320 x 2868 Pixel,
/// hochkant): die echten Ansichten der kompakten Huelle (untere Leiste, Blaetter von unten) mit denselben Demo-Inhalten
/// wie die iPad-Bilder (`DemoContent` und `DemoContent.installStoreExtras`, erfundenes Modul "Demo: Grundlagen der
/// Informatik", Rufname "Mia"). Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt der Test je
/// Ansicht hell und dunkel `<nn>-<name>-{light|dark}-portrait.png`; ohne prueft er nur, dass jede Ansicht erscheint.
/// Reihenfolge und Bildunterschriften: docs/release/SCREENSHOTS.md, Abschnitt iPhone. Schein-Dienste (KI, Stud.IP,
/// Community) und das Zusammensetzen von Seite und Blatt wie in `StoreScreenshotTests`; keine Anfrage an eine Hochschule.
@MainActor
final class IPhoneStoreScreenshotTests: XCTestCase {

    /// iPhone 17 Pro Max hochkant in Punkten (x3 = 1320 x 2868 Pixel)
    static let size = CGSize(width: 440, height: 956)

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var outDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shots-phone", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }          // jede Anfrage an eine Hochschule zaehlt
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        try await StoreScreenshotTests.installStoreExtras(container.host)
        Rufname.write(StoreScreenshotTests.demoName, container.defaults)
        MessagesInbox.shared.defaultsOverride = container.defaults
        await MessagesInbox.shared.refresh(api: container.api)
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: StoreScreenshotTests.EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        UFCompact.phoneOverride = true
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Hosten und Fotografieren

    /// Die kompakte Huelle wie am iPhone (Groessenklasse compact, `UFCompact.phoneOverride`), ohne Demo-Leiste
    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufDemoBarHidden, true)
            .environment(\.ufAIEnabled, ai)
            .environmentObject(manager!)
            .environmentObject(account!)
        let env = try hostWithEnvironment(root, api: api ?? container.api, size: Self.size, studip: manager.studip)
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        env.pump(0.3)
        return env
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, ink: Bool = false, present: (() -> Void)? = nil,
                       sheetReady: @escaping () -> Bool = { true }) {
        guard let outDir else { return }
        StoreScreenshotTests.shoot(env, name, folder: outDir, sizes: [(Self.size, "portrait")], scale: 3, ink: ink, settle: 1.0,
                                   present: present, sheetReady: sheetReady, cornerRadius: 36, statusBar: true)
    }

    /// Blatt ganz hoch: halb hoch ist es aus Glas, das `drawHierarchy` nur schwarz zeichnet
    private func presentLarge(_ env: HostedEnvironment, _ open: @escaping () -> Void) -> () -> Void {
        {
            open()
            _ = env.wait(timeout: 10) { env.hosting.presentedViewController?.sheetPresentationController != nil }
            if let sheet = env.hosting.presentedViewController?.sheetPresentationController {
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            }
            env.pump(1.0)
        }
    }

    private func aiTransport() -> StoreScreenshotTests.Intercept {
        let t = StoreScreenshotTests.Intercept(container.host)
        t.answer("/api/ai/tutor", StoreScreenshotTests.tutorAnswer)
        t.answer("/api/tests/18", StoreScreenshotTests.demoTest)
        t.answer("/api/ai/document/plan", StoreScreenshotTests.docPlan)
        t.answer("/api/ai/document/step", StoreScreenshotTests.docSteps[0], StoreScreenshotTests.docSteps[1])
        return t
    }

    private func aiAPI(_ t: StoreScreenshotTests.Intercept) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    // MARK: - Bedienungshilfen (ganzes Fenster: Blaetter liegen ausserhalb der gehosteten Ansicht)

    private func elements(_ env: HostedEnvironment) -> [NSObject] {
        env.window.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 80 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false || !id.isEmpty { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 600) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(env.window, depth: 0)
        return out
    }

    private func texts(_ env: HostedEnvironment) -> [String] {
        elements(env).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: " | ") }

    private func element(_ env: HostedEnvironment, id: String) -> NSObject? {
        elements(env).first { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == id }
    }

    @discardableResult
    private func tap(_ env: HostedEnvironment, id: String) -> Bool { element(env, id: id)?.accessibilityActivate() ?? false }

    @discardableResult
    private func tap(_ env: HostedEnvironment, label: String, prefix: Bool = false) -> Bool {
        for e in elements(env) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, prefix ? l.hasPrefix(label) : l == label else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        XCTAssertTrue(ok, "„\(text)“ fehlt:\n" + dump(env), file: file, line: line)
        return ok
    }

    /// Knopf mit dieser Beschriftung unter `root` (Blatt) ausloesen
    private func activate(in root: UIView?, label: String) -> Bool {
        guard let root else { return false }
        var found: NSObject?
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: Any, depth: Int) {
            guard found == nil, depth < 80 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel == label { found = o; return }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return found?.accessibilityActivate() ?? false
    }

    /// Segment des Umfangs waehlen ("Diese Seite | Ganzes Dokument | Seiten …")
    private func selectScope(_ env: HostedEnvironment, _ title: String) -> Bool {
        func find(_ v: UIView) -> UISegmentedControl? {
            if let s = v as? UISegmentedControl, (0..<s.numberOfSegments).contains(where: { s.titleForSegment(at: $0) == title }) { return s }
            for c in v.subviews where !c.isHidden { if let s = find(c) { return s } }
            return nil
        }
        guard let control = find(env.window),
              let i = (0..<control.numberOfSegments).first(where: { control.titleForSegment(at: $0) == title }) else { return false }
        control.selectedSegmentIndex = i
        control.sendActions(for: .valueChanged)
        env.pump(0.3)
        return true
    }

    private func waitForInk(_ env: HostedEnvironment, file: StaticString = #filePath, line: UInt = #line) {
        let ok = env.wait(timeout: 25) { StoreScreenshotTests.canvases(in: env.view).contains { !$0.drawing.strokes.isEmpty } }
        XCTAssertTrue(ok, "Editor zeigt die Notizen nicht:\n" + dump(env), file: file, line: line)
        env.pump(2.0)
    }

    // MARK: - iPhone-Satz (01-08)

    func test01Start() throws {
        let env = try host(MainView())
        expect(env, "Grundlagen der Informatik")
        expect(env, StoreScreenshotTests.demoName)
        expect(env, "Prüfungsanmeldung")
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "Store-Bild ohne Demo-Leiste")
        shoot(env, "01-start")
    }

    /// Skript mit Handschrift, KI-Hilfe als Blatt von unten: "Ganzes Dokument", "Ganze Vorlesung erklären"
    func test02KIDokument() throws {
        StoreScreenshotTests.seedNotesPumping("demo-skript", api: container.api)
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        let present = {
            XCTAssertTrue(self.tap(env, id: "doc.tutor") || self.tap(env, label: "KI-Hilfe"), "KI-Hilfe öffnen:\n" + self.dump(env))
            XCTAssertTrue(env.wait { self.selectScope(env, "Ganzes Dokument") }, "Umfang „Ganzes Dokument“:\n" + self.dump(env))
            let started = env.wait {
                self.tap(env, id: "tutor.doc.lecture") || self.tap(env, label: "Ganze Vorlesung erklären")
                    || self.activate(in: env.hosting.presentedViewController?.view, label: "Ganze Vorlesung erklären")
            }
            XCTAssertTrue(started, self.dump(env))
            XCTAssertTrue(env.wait(timeout: 15) { t.count("/api/ai/document/step") == 2 }, "zwei Teile geholt")
            if let sheet = env.hosting.presentedViewController?.sheetPresentationController {
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            }
            env.pump(1.0)
        }
        if outDir != nil {
            shoot(env, "02-ki-dokument", ink: true, present: present, sheetReady: { self.shows(env, "Prüfungsrelevant") || self.shows(env, "Zweierkomplement") })
        } else {
            present()
        }
        expect(env, "Zweierkomplement")
    }

    func test03Karteikarten() throws {
        let env = try host(MainView())
        env.router.go(.cards)
        expect(env, "heute fällig")
        shoot(env, "03-karteikarten")
    }

    func test04Wochentest() throws {
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.exam(18, task: nil))
        expect(env, "Punkte")
        expect(env, "Hexadezimalsystem")
        shoot(env, "04-wochentest")
    }

    func test05Studienverlauf() throws {
        let env = try host(MainView())
        env.router.go(.studyPlan())
        expect(env, "Prüfungsanmeldung")
        XCTAssertFalse(shows(env, StudyPlanText.noQIS), "Studienverlauf mit Katalog")
        shoot(env, "05-studienverlauf")
    }

    /// Nachricht des Tutoriums im Leser, darueber das Antwortfenster (Blatt von unten) mit Text
    func test06Nachrichten() throws {
        let toggle = StoreScreenshotTests.SheetSwitch()
        let model = StoreScreenshotTests.replyModel(defaults: container.defaults)
        let env = try host(StoreScreenshotTests.WithSheet(base: MainView(), toggle: toggle) {
            MessageReplySheet(model: model).environment(\.ufCompact, true)
        })
        env.router.go(.messages)
        expect(env, "Fragen zu Übungsblatt 1")
        if !shows(env, "Bringt eure Lösungsansätze mit") {
            XCTAssertTrue(tap(env, label: "Neu, Fragen zu Übungsblatt 1", prefix: true) || tap(env, label: "Fragen zu Übungsblatt 1", prefix: true), dump(env))
        }
        expect(env, "Bringt eure Lösungsansätze mit")
        let ready = { () -> Bool in
            guard model.phase == .ready else { return false }
            if model.text != StoreScreenshotTests.replyText { model.text = StoreScreenshotTests.replyText }
            return true
        }
        env.pump(1.0)
        shoot(env, "06-nachrichten", present: presentLarge(env) { toggle.shown = true }, sheetReady: ready)
        toggle.shown = true
        XCTAssertTrue(env.wait(timeout: 10) { ready() }, "Antwortfenster bereit: \(model.phase)")
        expect(env, "Tutorium Grundlagen der Informatik")
    }

    /// Uebungsblatt mit Handschrift, darueber "In Stud.IP abgeben" (Blatt von unten wie am iPhone)
    func test07Abgeben() throws {
        StoreScreenshotTests.seedNotesPumping("demo-blatt", api: container.api)
        let toggle = StoreScreenshotTests.SheetSwitch()
        let model = StoreScreenshotTests.submitModel(defaults: container.defaults)
        let env = try host(StoreScreenshotTests.WithSheet(base: MainView(), toggle: toggle) {
            StudIPSubmitSheet(model: model).ufHalfSheet(when: true).environment(\.ufCompact, true)
        })
        env.router.go(.doc("demo-blatt"))
        waitForInk(env)
        let ready = { model.phase == .ready && model.folderState == .loaded && model.prepared != nil }
        env.pump(1.0)
        shoot(env, "07-abgeben", ink: true, present: presentLarge(env) { toggle.shown = true }, sheetReady: ready)
        toggle.shown = true
        XCTAssertTrue(env.wait(timeout: 10) { ready() }, "Abgabe bereit: \(model.phase) \(model.folderState)")
        expect(env, "Abgabe Übungsblatt 1")
    }

    func test08Community() throws {
        let env = try host(MainView())
        env.router.go(.community)
        expect(env, "Deine Communities")
        shoot(env, "08-community")
    }
}
