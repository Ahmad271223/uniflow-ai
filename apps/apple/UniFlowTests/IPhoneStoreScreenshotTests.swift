import PencilKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// App-Store-Bildschirmfotos fuer das iPhone 6,9" (iPhone 17 Pro Max: 440 x 956 Punkte, Massstab 3 = 1320 x 2868 Pixel,
/// hochkant): die echten Ansichten der kompakten Huelle (untere Leiste, Blaetter von unten) mit denselben Demo-Inhalten
/// wie die iPad-Bilder (`DemoContent` und `DemoContent.installStoreExtras`, erfundenes Modul "Demo: Grundlagen der
/// Informatik", Rufname "Tobi"). Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt der Test je
/// Ansicht hell und dunkel `<nn>-<name>-{light|dark}-portrait.png`; ohne prueft er nur, dass jede Ansicht erscheint.
///
/// Satz fuer 1.0.4 (13.11.2026, Build 39): Uebersicht, Lernkalender, Modul mit Erledigt-Haken, Uni-Mail mit
/// "Mit KI verbessern", KI-Hilfe, Studienverlauf mit Noten, Mensa. Reihenfolge und Bildunterschriften:
/// docs/release/SCREENSHOTS.md, Abschnitt iPhone. Tobi hat den Tarif Pro AI; die KI antwortet aus einem
/// Schein-Transport bzw. einer Schein-KI im lokalen Backend, Stud.IP und Uni-Mail aus Nachbildungen im Speicher.
/// Keine Anfrage an eine Hochschule (`UniStubProtocol` zaehlt mit), keine Hochschul-Logos, nur erfundene Daten.
@MainActor
final class IPhoneStoreScreenshotTests: XCTestCase {

    /// iPhone 17 Pro Max hochkant in Punkten (x3 = 1320 x 2868 Pixel)
    static let size = CGSize(width: 440, height: 956)

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var uniMail: UniMailConnection!
    private var outDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shots-phone", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }          // jede Anfrage an eine Hochschule zaehlt
        UniMailConnection.readsDemoForScreenshots = true
        UFGreeting.hourOverride = 14                                                 // "Hallo Tobi" unabhaengig von der Uhrzeit
        let sogo = DemoSOGoCompose()
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true,
            uniMailTransport: { _ in sogo })
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        try await StoreScreenshotTests.installStoreExtras(container.host)
        Rufname.write(StoreScreenshotTests.demoName, container.defaults)
        MessagesInbox.shared.defaultsOverride = container.defaults
        await MessagesInbox.shared.refresh(api: container.api)
        Entitlements.shared.setPlanForTesting(.proAI)
        // Schein-KI des lokalen Backends: nur "Mit KI verbessern" fragt sie (POST /api/ai/mail-rewrite)
        let backend = try await container.host.backend()
        backend.context.ai.set(MailAI())
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: StoreScreenshotTests.EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        uniMail = try XCTUnwrap(manager.uniMail, "LUH hat Uni-Mail")
        uniMail.refreshesAfterSignIn = false
        let store = uniMail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: SOGoSite.luh.host, path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "erfunden", domain: SOGoSite.luh.host, path: "/SOGo"))
        uniMail.signedIn(user: StoreScreenshotV11Tests.mailUser)
        _ = await uniMail.refreshInbox()
        UFCompact.phoneOverride = true
        UFEditorAvailability.forcedReaderOnlyForTesting = true          // iPhone: Leseansicht statt Editor (11.11.2026)
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
        UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault
        UniMailConnection.readsDemoForScreenshots = false
        UFGreeting.hourOverride = nil
        UFFmt.todayOverride = nil
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        UniStubProtocol.reset()
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Schein-Dienste nur fuer diese Bilder

    /// Vorschlag der KI fuer "Mit KI verbessern" (erfunden, nichts verlaesst den Prozess)
    private struct MailAI: AIProvider {
        func answer(system: String, prompt: String) async throws -> String {
            """
            Sehr geehrte Frau Professorin Beispiel,

            in Ihrer E-Mail zur Klausur „Grundlagen der Informatik“ ist mir eine Frage zur Probeklausur geblieben: \
            Dürfen wir bei Aufgabe 3 (Zweierkomplement) eine eigene Formelsammlung benutzen?

            Falls das in Ihrer Sprechstunde am Dienstag einfacher zu klären ist, komme ich gern vorbei.

            Vielen Dank und viele Grüße
            Tobi Muster
            """
        }
    }

    /// Posteingang wie `StoreScreenshotV11Tests.DemoSOGo`, dazu ein erfundener Entwurf fuer "Neue E-Mail"
    /// (`Mail/0/compose` und `.../edit`). Geschrieben oder gesendet wird nie.
    private final class DemoSOGoCompose: UniTransport, @unchecked Sendable {
        private let inner = StoreScreenshotV11Tests.DemoSOGo()

        static let draftText = """
            hallo frau beispiel,
            kurze frage zur probeklausur: darf man bei aufgabe 3 (zweierkomplement) eine eigene formelsammlung benutzen?
            danke schonmal
            tobi
            """

        func send(_ request: UniRequest) async throws -> UniResponse {
            let path = request.url.path
            func json(_ v: JSONValue) -> UniResponse {
                UniResponse(status: 200, headers: ["Content-Type": "application/json"], finalURL: request.url, body: v.serialized())
            }
            if path.hasSuffix("/Mail/0/compose") {
                return json(["accountId": "0", "mailboxPath": "Drafts", "draftId": "7"])
            }
            if path.hasSuffix("/edit") {
                return json(["from": .string("Tobi Muster <\(StoreScreenshotV11Tests.mailUser)>"),
                             "to": ["anna.beispiel@example.org"], "cc": [], "bcc": [],
                             "subject": "Frage zur Probeklausur Grundlagen der Informatik",
                             "text": .string(Self.draftText), "isHTML": 0, "attachmentAttrs": []])
            }
            return try await inner.send(request)
        }

        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
            UniResponse(status: 404, finalURL: request.url)
        }
    }

    // MARK: - Hosten und Fotografieren

    /// Die kompakte Huelle wie am iPhone (Groessenklasse compact, `UFCompact.phoneOverride`), ohne Demo-Leiste
    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufDemoBarHidden, true)
            .environment(\.ufAIEnabled, ai)
            .environment(\.ufStudiNowAI, ai)
            .environment(\.ufAIAccess, ai ? .ready : .planRequired)
            .environment(\.uniMail, uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        let env = try hostWithEnvironment(root, api: api ?? container.api, size: Self.size, studip: manager.studip)
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        env.pump(0.3)
        return env
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, ink: Bool = false, settle: Double = 1.0,
                       present: (() -> Void)? = nil, sheetReady: @escaping () -> Bool = { true }) {
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "\(name): Store-Bild ohne Demo-Leiste")
        for word in ["ChatGPT", "Pro AI holen", AIConsentText.title] {
            XCTAssertFalse(shows(env, word), "\(name): „\(word)“ im Bild:\n" + dump(env))
        }
        guard let outDir else { return }
        StoreScreenshotTests.shoot(env, name, folder: outDir, sizes: [(Self.size, "portrait")], scale: 3, ink: ink, settle: settle,
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

    /// Nummer des erfundenen Demo-Moduls ("Demo: Grundlagen der Informatik")
    private func demoModuleID() throws -> Int {
        var id: Int?
        let api = container.api
        Task { @MainActor in
            let v = try? await api.value("/api/modules")
            let list = v?.items ?? []
            id = list.first(where: { $0.s("name")?.hasPrefix("Demo") == true })?.i("id") ?? list.first?.i("id")
        }
        let end = Date().addingTimeInterval(20)
        while id == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(id, "Demo-Modul gefunden")
    }

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
        if let sheet = env.hosting.presentedViewController?.view { visit(sheet, depth: 0) }
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

    /// Sichtbar im Fenster (nicht hinter Kopf- oder Fussleiste)
    private func visible(_ env: HostedEnvironment, label: String) -> Bool {
        let bounds = env.window.bounds
        for e in elements(env) {
            guard let l = e.accessibilityLabel, l.hasPrefix(label) else { continue }
            let f = e.accessibilityFrame
            if f.minY > bounds.minY + 70, f.maxY < bounds.maxY - 90 { return true }
        }
        return false
    }

    /// So weit rollen, bis ein Element mit dieser Beschriftung ganz im Bild steht
    @discardableResult
    private func scrollUntil(_ env: HostedEnvironment, label: String, steps: Int = 10) -> Bool {
        func lists(_ v: UIView) -> [UIScrollView] {
            var out: [UIScrollView] = []
            if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height + 20 { out.append(s) }
            for c in v.subviews where !c.isHidden { out += lists(c) }
            return out
        }
        for _ in 0..<steps {
            if visible(env, label: label) { return true }
            guard let s = lists(env.window).max(by: { $0.bounds.height < $1.bounds.height }) else { return false }
            let maxY = max(0, s.contentSize.height - s.bounds.height)
            let next = min(maxY, s.contentOffset.y + s.bounds.height * 0.6)
            if next <= s.contentOffset.y + 1 { break }
            s.setContentOffset(CGPoint(x: s.contentOffset.x, y: next), animated: false)
            env.pump(0.5)
        }
        return visible(env, label: label)
    }

    private func waitForInk(_ env: HostedEnvironment, file: StaticString = #filePath, line: UInt = #line) {
        let ok = env.wait(timeout: 25) { StoreScreenshotTests.canvases(in: env.view).contains { !$0.drawing.strokes.isEmpty } }
        XCTAssertTrue(ok, "Leseansicht zeigt die Notizen nicht:\n" + dump(env), file: file, line: line)
        env.pump(2.0)
    }

    // MARK: - iPhone-Satz 1.0.4 (01-07)

    /// 1 Uebersicht: "Hallo Tobi", Pruefungsanmeldung mit QIS-Knopf, heutiges Lernpaket, untere Leiste
    func test01Uebersicht() throws {
        let env = try host(MainView())
        expect(env, "Grundlagen der Informatik")
        expect(env, StoreScreenshotTests.demoName)
        if outDir != nil { expect(env, "Prüfungsanmeldung") }     // nur im Meldezeitraum (Bilder: 09.-22.11.2026)
        shoot(env, "01-uebersicht")
    }

    /// 2 Lernkalender: Woche als Liste (Montag-Sonntag) mit Uni-Terminen und Lernpaketen
    func test02Lernkalender() throws {
        let env = try host(MainView())
        env.router.go(.plan(view: "week"))
        expect(env, "Lernkalender")
        env.pump(1.5)
        shoot(env, "02-lernkalender", settle: 1.5)
    }

    /// 3 Modul mit Erledigt-Haken: Lehrwochen offen, abgehakte Dateien mit gruenem Haken, Fortschritt der Woche
    func test03ModulErledigt() throws {
        let id = try demoModuleID()
        let env = try host(MainView())
        env.router.go(.module(id))
        expect(env, "Grundlagen der Informatik")
        env.pump(1.0)
        _ = env.openWeeks()
        env.pump(1.0)
        // zwei von drei Dateien abhaken (derselbe Stand wie die Lernpakete)
        for label in ["Erledigt: Folien Woche 1 – Einführung", "Erledigt: Skript Kapitel 1"] {
            _ = tap(env, label: label, prefix: true)
            env.pump(0.8)
        }
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "erledigt") }, "Fortschritt der Woche:\n" + dump(env))
        XCTAssertTrue(scrollUntil(env, label: "Erledigt: Skript Kapitel 1"), "Haken im Bild:\n" + dump(env))
        env.pump(1.0)
        shoot(env, "03-modul-erledigt", settle: 1.5)
    }

    /// 4 Uni-Mail "Mit KI verbessern": Fenster "Neue E-Mail" (am iPhone ganzseitig) mit eigenem Text und dem
    /// Vorschlag der KI. Das Fenster wird direkt gehostet, weil ein ganzseitiges Blatt ueber der Seite nur schwarz
    /// zusammengesetzt wird.
    func test04UniMailKI() throws {
        let env = try host(UniMailComposeSheet(connection: uniMail, request: UniMailComposeRequest())
            .environment(\.ufCompact, true), ai: true)
        expect(env, "Frage zur Probeklausur")
        let tapped = env.wait(timeout: 10) { self.tap(env, label: "Mit KI verbessern") || self.tap(env, id: "unimail.ai") }
        XCTAssertTrue(tapped, "„Mit KI verbessern“:\n" + dump(env))
        expect(env, "Vorschlag der KI", timeout: 20)
        expect(env, "Übernehmen")
        _ = scrollUntil(env, label: "Übernehmen")
        env.pump(1.0)
        shoot(env, "04-uni-mail-ki", settle: 1.5)
    }

    /// 5 KI-Hilfe: Skript mit Handschrift vom iPad in der Leseansicht, KI-Hilfe als Blatt von unten
    /// ("Ganzes Dokument", "Ganze Vorlesung erklären")
    func test05KIHilfe() throws {
        StoreScreenshotTests.seedNotesPumping("demo-skript", api: container.api)
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        let present = {
            XCTAssertTrue(self.tap(env, id: "phoneReader.tutor") || self.tap(env, label: "KI-Hilfe"), "KI-Hilfe öffnen:\n" + self.dump(env))
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
            shoot(env, "05-ki-hilfe", ink: true, present: present, sheetReady: { self.shows(env, "Prüfungsrelevant") || self.shows(env, "Zweierkomplement") })
        } else {
            present()
        }
        expect(env, "Zweierkomplement")
    }

    /// 6 Studienverlauf mit Noten: Leistungspunkte, bestandene Pruefungen (erfunden) und Pruefungsanmeldung
    func test06Studienverlauf() throws {
        let env = try host(MainView())
        env.router.go(.studyPlan())
        expect(env, "Prüfungsanmeldung")
        XCTAssertFalse(shows(env, StudyPlanText.noQIS), "Studienverlauf mit Katalog")
        env.pump(1.0)
        shoot(env, "06-studienverlauf")
    }

    /// 7 Mensa: Speiseplan (erfunden) an einem Werktag; am Wochenende der naechste Montag als "heute"
    func test07Mensa() throws {
        UFFmt.todayOverride = StoreScreenshotV11Tests.nextServiceDay()
        let env = try host(MainView())
        env.router.go(.mensa)
        expect(env, "Gemüse-Kichererbsen-Curry mit Reis")
        XCTAssertFalse(shows(env, "Geschlossen"), "Werktag mit Speiseplan:\n" + dump(env))
        env.pump(1.0)
        shoot(env, "07-mensa")
    }
}
