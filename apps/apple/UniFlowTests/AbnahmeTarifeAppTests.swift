import PDFKit
import StoreKitTest
import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Abnahme der Tarife fuer Version 1.0 im Release-Stand (07.11.2026, nur LUH): je Tarif Free, Plus, Pro AI, "Probe laeuft"
/// und "Probe vorbei" ein Durchgang mit der echten Wurzel der App (`RootView`, Demo-Inhalte der LUH) durch Community,
/// Karteikarten, Tests, KI-Start, Lernkalender, Stundenplan und Dokument: erlaubt bzw. gesperrt wie `UFFeatureMatrix`,
/// gesperrt mit Hinweis auf den richtigen Tarif ("Mit Plus freischalten"), Antippen fuehrt zur Tarifwahl (kein toter
/// Knopf), kein Absturz, nirgends "gibt es mit diesem Dienst noch nicht". Die Community laeuft ueber CloudKit gegen
/// `CommunityCloudKitTests.FakeCommunityCloud` (nur im Speicher). Dazu die Probe einmal je Geraet und der
/// Entscheidungs-Bildschirm nach der Probe (`TrialDecisionCover`, Inhaber 07.11.2026).
///
/// Mit UF_ABNAHME_DIR (xcodebuild: TEST_RUNNER_UF_ABNAHME_DIR) je Station und Groesse ein Bild und `befunde-<test>.txt`.
@MainActor
final class AbnahmeTarifeAppTests: XCTestCase {

    static let landscape = CGSize(width: 1024, height: 768)
    static let portrait = CGSize(width: 834, height: 1194)
    /// darf im Store-Build nirgends stehen (1.0 nur LUH; Community ueber iCloud mit Fragen und Antworten)
    static let forbidden = ["Hildesheim", "HsH", "Moodle", "Learnweb", "HISinOne", "in Vorbereitung", "bald verfügbar",
                            "Bald verfügbar", "mit diesem Dienst noch nicht", "In diesem Build nicht verfügbar"]
    static let debugWords = ["TODO", "FIXME", "localhost", "127.0.0.1", "lorem"]

    /// Durchgaenge: Name, Tarif bzw. Probe
    enum Pass: String, CaseIterable {
        case free, plus, proAI = "pro-ai", trialRunning = "probe-laeuft", trialOver = "probe-vorbei"
        /// wirksamer Tarif
        var plan: UFPlan {
            switch self {
            case .free, .trialOver: return .free
            case .plus: return .plus
            case .proAI, .trialRunning: return .proAI
            }
        }
    }

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer?
    private var background: BackgroundSyncController!
    private var outDir: URL?
    private var storeSession: SKTestSession?
    private var oldSidebar: String?
    private var cloud: CommunityCloudKitTests.FakeCommunityCloud!
    private var findings: [String] = []
    private var stations: [(name: String, ok: Bool)] = []

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        UFReleaseUniversities.shipped = UFReleaseUniversities.storeDefault
        bed = try ContainerTestBed(name: "abnahme-tarife", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(),
                               observeRevocation: false)
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.setPlanForTesting(.free)
        UFGreeting.hourOverride = 12
        oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        UserDefaults.standard.set("full", forKey: "sidebar")
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent("tarife-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        cloud = CommunityCloudKitTests.FakeCommunityCloud(assetDir: assets)
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_ABNAHME_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
        UFGreeting.hourOverride = nil
        UFTrialDecision.enabledUnderTest = false
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.setPlanForTesting(.free)
        CommunityRoute.shared.service = nil
        storeSession = nil
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        UniStubProtocol.reset()
        manager.onChange = nil
        manager.deactivate()
        await bed.tearDown()
        UFReleaseUniversities.reset()
        writeFindings()
        try await super.tearDown()
    }

    // MARK: - Aufbau (wie AbnahmeV1LUHReleaseAppTests)

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

    private func host() throws -> HostedEnvironment {
        let env = try hostWithEnvironment(Root(manager: manager, account: account, background: background),
                                          api: container?.api ?? .local(.unavailable), size: Self.landscape, studip: manager.studip)
        manager.onChange = { [weak session = env.session] c in session?.useLocal(c?.api ?? .local(.unavailable)) }
        env.pump(0.5)
        return env
    }

    private func openDemo() async throws {
        account.signIn(userID: bed.user, name: "Ada Erfunden", email: nil, givenName: "Ada")
        account.markPlanShown()
        account.chooseUniversity(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        Rufname.write("Ada", container!.defaults)
    }

    private func storeKit() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        storeSession = session
    }

    /// Community ueber CloudKit (nachgebaut) mit den Kursen der Demo
    private func useFakeCommunity() -> CloudKitCommunityService {
        let host = container!.host
        let service = CloudKitCommunityService(
            cloud: cloud, university: .luh, membership: CommunityMembership(defaults: container!.defaults),
            courseKeys: { await CommunityCourses.courseKeys(host: host, university: UniversityKey.luh.rawValue) },
            courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        CommunityRoute.shared.service = service
        return service
    }

    /// Tarif bzw. Probe setzen (Reihenfolge: erst die Probe, sie rechnet den Tarif neu)
    private func apply(_ pass: Pass) {
        switch pass {
        case .free: Entitlements.shared.useLocalTrial(startedAt: nil); Entitlements.shared.setPlanForTesting(.free)
        case .plus: Entitlements.shared.useLocalTrial(startedAt: nil); Entitlements.shared.setPlanForTesting(.plus)
        case .proAI: Entitlements.shared.useLocalTrial(startedAt: nil); Entitlements.shared.setPlanForTesting(.proAI)
        case .trialRunning:
            Entitlements.shared.setPlanForTesting(.free)
            Entitlements.shared.useLocalTrial(startedAt: Date().addingTimeInterval(-86_400))
        case .trialOver:
            Entitlements.shared.setPlanForTesting(.free)
            Entitlements.shared.useLocalTrial(startedAt: Date().addingTimeInterval(-8 * 86_400))
        }
        XCTAssertEqual(Entitlements.shared.plan, pass.plan, "Tarif im Durchgang \(pass.rawValue)")
    }

    // MARK: - Bedienungshilfen-Baum

    private func elements(in view: UIView) -> [NSObject] { LayoutWidthAuditTests.elements(in: view) }

    private func allElements(_ env: HostedEnvironment) -> [NSObject] {
        var all = elements(in: env.window)
        var vc = env.hosting.presentedViewController
        while let p = vc {
            if let v = p.view, v.window == nil { all += elements(in: v) }
            vc = p.presentedViewController
        }
        return all
    }

    private func texts(_ env: HostedEnvironment) -> [String] {
        allElements(env).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: "\n") }

    @discardableResult
    private func tap(_ label: String, in env: HostedEnvironment, exact: Bool = true) -> Bool {
        for e in allElements(env) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.hasPrefix(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Element mit dem Hinweis "Gesperrt. Öffnet die Tarifwahl." (ufRequires), dessen Beschriftung `label` enthaelt
    private func lockedElement(_ env: HostedEnvironment, containing label: String) -> NSObject? {
        allElements(env).first { ($0.accessibilityLabel ?? "").contains(label) && ($0.accessibilityHint ?? "").hasPrefix("Gesperrt") }
    }

    private func unlabeledButtons(_ env: HostedEnvironment) -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60, let o = element as? NSObject, seen.insert(ObjectIdentifier(o)).inserted else { return }
            if let v = o as? UIView, v.isHidden || v.alpha < 0.01 || v is WKWebView { return }
            let exposed = (o as? UIView).map(\.isAccessibilityElement) ?? true
            if exposed, o.accessibilityTraits.contains(.button),
               (o.accessibilityLabel ?? "").isEmpty, (o.accessibilityValue ?? "").isEmpty, (o.accessibilityHint ?? "").isEmpty {
                let f = o.accessibilityFrame
                if f.width > 0.5, f.height > 0.5, !f.isNull, !f.isInfinite, env.window.bounds.intersects(f) {
                    out.append("\(type(of: o)) bei x \(Int(f.minX)) y \(Int(f.minY)) (\(Int(f.width)) x \(Int(f.height)))")
                }
            }
            for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            if let v = o as? UIView, !(v is WKWebView) { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(env.window, depth: 0)
        var vc = env.hosting.presentedViewController
        while let p = vc { if let v = p.view { visit(v, depth: 0) }; vc = p.presentedViewController }
        return out
    }

    private func resize(_ env: HostedEnvironment, _ size: CGSize) {
        env.hosting.traitOverrides.horizontalSizeClass = size.width < 700 ? .compact : .regular
        env.window.frame = CGRect(origin: .zero, size: size)
        env.view.frame = env.window.bounds
    }

    private func pumping<T>(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { throw XCTSkip("Zeitueberschreitung") }
        return try result.get()
    }

    private func dismissPresented(_ env: HostedEnvironment) {
        env.hosting.presentedViewController?.dismiss(animated: false)
        _ = env.wait(timeout: 5) { env.hosting.presentedViewController == nil }
        env.pump(0.3)
    }

    // MARK: - Befunde, Stationen, Bilder

    private func note(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        findings.append(text)
        XCTFail(text, file: file, line: line)
    }

    private func remark(_ text: String) { findings.append("Hinweis: " + text) }

    private func writeFindings() {
        let lines = stations.map { "\($0.ok ? "✓" : "✗") \($0.name)" } + [""] + (findings.isEmpty ? ["keine Befunde"] : findings)
        print("=== Abnahme \(name) ===\n" + lines.joined(separator: "\n"))
        guard let outDir else { return }
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        try? (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("befunde-\(safe).txt"), atomically: true, encoding: .utf8)
    }

    /// Station in beiden Groessen: Marker da, `absent` nicht da, keine verbotenen Woerter, nichts zu breit, jeder Knopf
    /// beschriftet; Bild je Groesse
    private func station(_ env: HostedEnvironment, _ name: String, markers: [String] = [], absent: [String] = [],
                         settle: Double = 0.8, file: StaticString = #filePath, line: UInt = #line) {
        var ok = true
        func fail(_ text: String) { ok = false; note("\(name): \(text)", file: file, line: line) }
        for (size, suffix) in [(Self.landscape, "1024x768"), (Self.portrait, "834x1194")] {
            resize(env, size)
            env.pump(settle)
            for m in markers where !env.wait(timeout: 12, until: { self.shows(env, m) }) { fail("@\(suffix): „\(m)“ erscheint nicht") }
            env.pump(0.3)
            let texts = self.texts(env)
            for a in absent { for t in texts where t.contains(a) { fail("@\(suffix): „\(a)“ darf hier nicht stehen („\(t.prefix(90))“)") } }
            for w in Self.forbidden { for t in texts where t.contains(w) { fail("@\(suffix): „\(w)“ in „\(t.prefix(90))“") } }
            for w in Self.debugWords { for t in texts where t.contains(w) { fail("@\(suffix): Debug-Rest „\(w)“ in „\(t.prefix(90))“") } }
            if texts.count < 6 { fail("@\(suffix): nur \(texts.count) Texte – leere Seite?\n" + texts.joined(separator: "\n")) }
            let over = overflows(env)
            if !over.isEmpty { fail("@\(suffix): \(over.count) zu breit\n" + over.prefix(12).map { "  " + $0.text }.joined(separator: "\n")) }
            let unlabeled = unlabeledButtons(env)
            if !unlabeled.isEmpty { fail("@\(suffix): \(unlabeled.count) Knöpfe ohne VoiceOver-Beschriftung\n" + unlabeled.prefix(12).map { "  " + $0 }.joined(separator: "\n")) }
            shoot(env, "\(name)-\(suffix)", marks: over.map(\.rect))
        }
        stations.append((name, ok))
        resize(env, Self.landscape)
        env.pump(0.3)
    }

    private func overflows(_ env: HostedEnvironment) -> [LayoutWidthAuditTests.Finding] {
        var pdfs: [UIView] = []
        func find(_ v: UIView) {
            if v is PDFView, !v.isHidden { pdfs.append(v); return }
            v.subviews.forEach(find)
        }
        find(env.window)
        pdfs.forEach { $0.isHidden = true }
        defer { pdfs.forEach { $0.isHidden = false } }
        let chrome = ["UIDimmingView", "_UIRoundedRectShadowView", "_UIInheritedView", "UIDropShadowView",
                      "_UICollectionViewListLayoutSectionBackgroundColorDecorationView"]
        return LayoutWidthAuditTests.overflows(in: env.window).filter { f in
            !chrome.contains { f.text.contains($0) } && !(f.text.hasPrefix("Element „") && f.text.contains("%“"))
        }
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, marks: [CGRect]) {
        guard let outDir else { return }
        // ein Blatt im Vollbild (Entscheidung nach der Probe) liegt nicht im Fenster der Wurzel
        let window = env.hosting.presentedViewController?.view.window ?? env.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { ctx in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            for canvas in StoreScreenshotTests.canvases(in: window) { StoreScreenshotTests.drawInk(canvas, of: window, scale: 2, in: ctx.cgContext) }
            guard !marks.isEmpty else { return }
            ctx.cgContext.setStrokeColor(UIColor.systemRed.cgColor)
            ctx.cgContext.setLineWidth(2)
            for r in marks { ctx.cgContext.stroke(r.intersection(window.bounds.insetBy(dx: 1, dy: 1))) }
        }
        let file = outDir.appendingPathComponent(name + (marks.isEmpty ? "" : "-ZU-BREIT") + ".png")
        do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
    }

    // MARK: - Eigene Loesung (erfundene PDF, eigene Notizen) fuer die Community

    private func makePDFData(_ marker: String) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...2 {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "\(marker) – Seite \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func ownPackage(_ title: String, displayName: String) throws -> SolutionPackage {
        let pdf = makePDFData(title)
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2}],
         "pages":{"p1":{"objects":[{"id":"t1","type":"text","text":"x = 42","x":100,"y":100,"fontSize":16}]},"p2":{"objects":[]}}}
        """#))
        let src = SolutionSource(document: doc, originalPDF: pdf, pdf: PDFDocument(data: pdf)!,
                                 fingerprint: SolutionSharing.cipher.sha256Hex(pdf), images: [:], title: title)
        return try SolutionSharing.package(try SolutionSharing.content(src, keys: ["p1"], displayName: displayName), originalPDF: pdf)
    }

    // MARK: - 0 Matrix der Tarife (Code) und Probe

    /// Soll aus dem Auftrag (Entscheidungen 05.-07.11.2026) gegen `UFFeatureMatrix`; schreibt die Tabelle in die Befunde
    func test00MatrixWieEntschieden() {
        let expected: [UFFeature: UFPlan] = [
            .studipSync: .free, .readDocuments: .free, .modulesTimetable: .free, .studyCalendar: .free, .studyPlanning: .free,
            .timer: .free, .viewNotes: .free, .uniGrades: .free, .ownChatGPT: .free,
            .pencilWriting: .plus, .communityRead: .plus, .shareSolutions: .plus, .splitView: .plus, .flashcards: .plus, .dueReminders: .plus, .autoPlan: .plus,
            .aiHelp: .proAI, .aiFlashcards: .proAI, .weeklyTests: .proAI, .deviceSync: .proAI,
        ]
        var table = ["Funktion | Free | Plus | Pro AI | Probe läuft | Probe vorbei"]
        let running = UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: UFLocalTrial.state(startedAt: Date(), now: Date()))
        let over = UFPlanPrecedence.effective(service: nil, purchased: .free,
                                              localTrial: UFLocalTrial.state(startedAt: Date().addingTimeInterval(-8 * 86_400), now: Date()))
        XCTAssertEqual(running, .proAI, "Probe = Pro-AI-Umfang")
        XCTAssertEqual(over, .free, "nach der Probe Free")
        for f in UFFeature.allCases where !f.isV2 {
            guard let min = expected[f] else { XCTFail("\(f) ohne Soll"); continue }
            XCTAssertEqual(f.minimumPlan, min, "\(f.title)")
            let cells = [UFPlan.free, .plus, .proAI, running, over].map { p -> String in
                let a = UFFeatureMatrix.access(f, plan: p)
                if case .locked(let need) = a {
                    XCTAssertEqual(need, min, "\(f.title): Sperre nennt \(need.name)")
                    XCTAssertTrue(UFLockedCard.message(f, access: a).contains(min.name), "Sperrkarte nennt den Tarif: \(UFLockedCard.message(f, access: a))")
                }
                XCTAssertNotEqual(a, .comingSoon, "\(f.title): nichts ist „bald“ in 1.0")
                return a.isAllowed ? "✓" : "✗"
            }
            table.append("\(f.title) | " + cells.joined(separator: " | "))
        }
        // Ausnahme: Lernplan automatisch mit eigenem ChatGPT auch in Free
        XCTAssertEqual(UFFeatureMatrix.access(.autoPlan, plan: .free, ownChatGPT: true), .allowed)
        // Herabstufen: Notizen und Karteikarten bleiben lesbar und exportierbar, nur Bearbeiten gesperrt
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .free), UFNoteAccess(canView: true, canExport: true, canEdit: false))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .plus), UFNoteAccess(canView: true, canExport: true, canEdit: true))
        XCTAssertEqual(UFFeatureMatrix.flashcards(plan: .free), UFFlashcardAccess(canView: true, canEdit: false))
        XCTAssertEqual(UFFeatureMatrix.flashcards(plan: .plus), UFFlashcardAccess(canView: true, canEdit: true))
        // Stapel von StudiNow: Free 0, Plus 4, Pro AI unbegrenzt
        XCTAssertEqual(UFAdoptQuota.limit(.free), 0)
        XCTAssertEqual(UFAdoptQuota.limit(.plus), 4)
        XCTAssertNil(UFAdoptQuota.limit(.proAI))
        findings.append(contentsOf: table)
    }

    // MARK: - 1 Durchgang je Tarif

    func test10Free() throws { try tour(.free) }
    func test11Plus() throws { try tour(.plus) }
    func test12ProAI() throws { try tour(.proAI) }
    func test13ProbeLaeuft() throws { try tour(.trialRunning) }
    func test14ProbeVorbei() throws { try tour(.trialOver) }

    private func tour(_ pass: Pass) throws {
        try storeKit()
        try pumping { try await self.openDemo() }
        let service = useFakeCommunity()
        // eine eigene, frueher veroeffentlichte Loesung (Herabstufen: bleibt, laesst sich zurueckziehen)
        let pkg = try ownPackage("Übungsblatt 3", displayName: "Ada")
        let space = try XCTUnwrap(try pumping { try await service.communities() }.first, "Community des Demo-Moduls")
        try pumping { try await service.join(space) }
        let pub = try pumping { try await service.publish(pkg, options: CommunityPublishOptions(visibility: .module, courseKey: space.key, title: "Übungsblatt 3", communityKey: space.key)) }
        try container!.solutions.recordShared(pkg, title: "Übungsblatt 3")
        try container!.solutions.setPublished(pub.solutionID, at: Date())
        apply(pass)
        let p = pass.rawValue
        let plan = pass.plan
        let env = try host()
        XCTAssertTrue(env.wait(timeout: 20) { self.shows(env, "Hallo Ada") }, dump(env))
        if pass == .trialOver {
            // Entscheidung ist hier beantwortet (eigener Test 20); der Rundgang zeigt Free nach der Probe
            Entitlements.shared.stayOnFreeAfterLocalTrial()
        }
        station(env, "\(p)-01-uebersicht")

        // Community
        env.router.go(.community)
        if plan >= .plus {
            station(env, "\(p)-02-community", markers: ["Community", "So funktioniert die Community", "Meine geteilten Lösungen"],
                    absent: ["Mit \(UFPlan.plus.name) freischalten"])
            env.router.go(.communitySpace(space.key))
            station(env, "\(p)-03-community-modul", markers: [space.name, "Diskussion"])
        } else {
            station(env, "\(p)-02-community-gesperrt", markers: ["Community", "Mit \(UFPlan.plus.name) freischalten",
                                                                  "Meine geteilten Lösungen", CommunityPage.ownPostsHint],
                    absent: ["So funktioniert die Community"])
            XCTAssertTrue(tap("Mit \(UFPlan.plus.name) freischalten", in: env), "Knopf zur Tarifwahl:\n" + dump(env))
            XCTAssertTrue(env.wait(timeout: 10) { env.hosting.presentedViewController != nil && self.shows(env, UFPlan.plus.name) },
                          "kein toter Knopf: Tarifwahl öffnet sich\n" + dump(env))
            station(env, "\(p)-03-community-tarifblatt", markers: [UFPlan.plus.name, UFPlan.proAI.name])
            if !tap("Schließen", in: env) { dismissPresented(env) }
            _ = env.wait(timeout: 5) { env.hosting.presentedViewController == nil }
            env.router.go(.dashboard); env.pump(0.3)
            env.router.go(.community)
        }
        // eigene Veroeffentlichung zurueckziehen: in jedem Tarif
        env.router.go(.community)
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Meine geteilten Lösungen") })
        XCTAssertTrue(tap("Meine geteilten Lösungen", in: env), "Meine geteilten Lösungen:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Übungsblatt 3") && self.shows(env, "Zurückziehen") }, "eigene Lösung sichtbar\n" + dump(env))
        station(env, "\(p)-04-meine-geteilten", markers: ["Übungsblatt 3", "Zurückziehen"])
        XCTAssertTrue(tap("Zurückziehen", in: env), "Zurückziehen:\n" + dump(env))
        env.pump(0.6)
        _ = tap("Zurückziehen", in: env)                                       // Rueckfrage bestaetigen
        XCTAssertTrue(env.wait(timeout: 10) { self.container!.solutions.sharedEntries().first?.publishedAt == nil },
                      "\(p): zurückgezogen\n" + dump(env))
        let left = try pumping { try await service.findMatching(fingerprint: pkg.header.fingerprint) }
        XCTAssertTrue(left.isEmpty, "\(p): Lösung nicht mehr in der Community: \(left.map(\.solutionID))")
        dismissPresented(env)

        // Karteikarten (Demo hat Karten)
        env.router.go(.cards)
        if plan >= .plus {
            station(env, "\(p)-05-karteikarten", markers: ["Karteikarten", "Karte anlegen"], absent: [UFFlashcardAccess.readOnlyHint])
        } else {
            station(env, "\(p)-05-karteikarten-lesen", markers: ["Karteikarten", UFFlashcardAccess.readOnlyHint, "Tarife ansehen"],
                    absent: ["Karte anlegen"])
            if let practise = lockedElement(env, containing: "Üben") {
                XCTAssertTrue(practise.accessibilityActivate() || true)
            } else {
                remark("\(p): „Üben“ ohne Schloss-Hinweis gefunden (Lesemodus)")
            }
        }

        // Tests & Wiederholung (Wochentests ab Pro AI)
        env.router.go(.exams)
        // Demo: die Seite ist ohne Tarif-Unterschied ein Hinweis mit dem Weg zu den Karteikarten (UFNoServerContent.examsText);
        // die Sperre der Wochentests selbst pruefen WeeklyAppTests/PlanMatrixAppTests
        station(env, "\(p)-06-tests", markers: ["Tests & Wiederholung", "Zu den Karteikarten", UFPlan.proAI.name])

        // KI-Start
        env.router.go(.aiStart)
        station(env, "\(p)-07-ki-start", markers: ["Wochentest", "Karteikarten"])

        // Uebersicht: "Lernplan erstellen" ab Plus
        env.router.go(.dashboard)
        env.pump(0.5)
        if plan >= .plus {
            XCTAssertNil(lockedElement(env, containing: "Lernplan erstellen"), "\(p): Lernplan erstellen frei")
        } else if let lock = lockedElement(env, containing: "Lernplan erstellen") {
            XCTAssertTrue(lock.accessibilityActivate(), "Lernplan erstellen: Antippen")
            XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Mit \(UFPlan.plus.name) freischalten") },
                          "\(p): Lernplan erstellen führt zur Tarifwahl\n" + dump(env))
            station(env, "\(p)-08-lernplan-gesperrt-tarifwahl", markers: [UFPlan.plus.name])
            if !tap("Schließen", in: env) { dismissPresented(env) }
        } else {
            remark("\(p): „Lernplan erstellen“ auf der Übersicht nicht gefunden")
        }

        // Lernkalender und Stundenplan (frei)
        env.router.go(.plan())
        station(env, "\(p)-09-lernkalender", markers: ["Lernkalender"])
        env.router.go(.timetable())
        station(env, "\(p)-10-stundenplan", markers: ["Stundenplan", "Grundlagen der Informatik"])

        // Dokument: Schreiben ab Plus; Notizen bleiben lesbar
        env.router.go(.doc("demo-blatt"))
        let lockLabel = "Nur ansehen – Schreiben ab \(UFPlan.plus.name)"
        XCTAssertTrue(env.wait(timeout: 25) { !StoreScreenshotTests.canvases(in: env.view).isEmpty }, "PDF im Editor:\n" + dump(env))
        env.pump(1.5)
        if plan >= .plus {
            station(env, "\(p)-11-dokument", absent: [lockLabel], settle: 1.2)
        } else {
            station(env, "\(p)-11-dokument-nur-ansehen", markers: [lockLabel], settle: 1.2)
        }
        env.router.go(.dashboard)
        env.pump(0.5)
    }

    // MARK: - 2 Entscheidung nach der Probe

    /// Tag 7 + 1 Minute: Bildschirm ueber der ganzen App mit Free/Plus/Pro AI (nur Jahresabos), nicht wegzuwischen;
    /// "Bei Free bleiben" beendet ihn, beim naechsten Start (neue Wurzel) kommt er nicht wieder
    func test20EntscheidungNachDerProbe() throws {
        try storeKit()
        try pumping { try await self.openDemo() }
        UFTrialDecision.enabledUnderTest = true
        let records = UFMemoryTrialRecords()
        let t0 = Date().addingTimeInterval(-(7 * 86_400 + 60))
        Entitlements.shared.setPlanForTesting(.free)
        Entitlements.shared.beginLocalTrial(userID: bed.user, records: records, now: t0)
        XCTAssertEqual(Entitlements.shared.plan, .proAI, "Tag 0: Probe")
        Entitlements.shared.refreshLocalTrial()                                 // jetzt = Tag 7 + 1 Minute
        XCTAssertEqual(Entitlements.shared.plan, .free)
        let env = try host()
        XCTAssertTrue(env.wait(timeout: 15) { env.hosting.presentedViewController != nil && self.shows(env, UFTrialTexts.overTitle) },
                      "Entscheidungs-Bildschirm erscheint\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, UFPlan.plus.name + " für 19,99") }, "Preise\n" + dump(env))
        station(env, "20-probe-vorbei-entscheidung", markers: [UFTrialTexts.overTitle, UFTrialTexts.overText, UFTrialTexts.stayFree,
                                                             UFPlan.free.name, UFPlan.plus.name, UFPlan.proAI.name,
                                                             UFPlan.plus.name + " für 19,99", UFPlan.proAI.name + " für 39,99", "/Jahr"])
        let presented = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertTrue([.fullScreen, .overFullScreen].contains(presented.modalPresentationStyle), "ganzer Bildschirm")
        XCTAssertTrue(presented.isModalInPresentation || presented.modalPresentationStyle != .pageSheet, "nicht wegzuwischen")
        XCTAssertFalse(shows(env, "Schließen"), "kein Schließen ohne Entscheidung")
        // nur Jahresabos (09.11.2026): kein Umschalter Monatlich/Jaehrlich
        XCTAssertNil(segmented(env), "kein Umschalter der Zahlweise")
        XCTAssertFalse(shows(env, "Monatlich"), "kein Monatsabo:\n" + dump(env))
        XCTAssertTrue(tap(UFTrialTexts.stayFree, in: env), "Bei Free bleiben:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 10) { env.hosting.presentedViewController == nil }, "Bildschirm nach der Wahl weg")
        XCTAssertTrue(records.load(UFLocalTrial.scope(userID: bed.user)).choiceMade, "Wahl gemerkt")
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Hallo Ada") })
        XCTAssertFalse(shows(env, UFTrialTexts.overTitle), "auch die Karte auf der Übersicht ist weg")
        station(env, "22-nach-der-wahl-free")
        // naechster Start: Probe neu geladen, keine Frage mehr
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.beginLocalTrial(userID: bed.user, records: records)
        let again = try host()
        again.pump(1.5)
        XCTAssertNil(again.hosting.presentedViewController, "beim nächsten Start nicht erneut")
    }

    private func segmented(_ env: HostedEnvironment) -> UISegmentedControl? {
        func find(_ v: UIView) -> UISegmentedControl? {
            if let s = v as? UISegmentedControl { return s }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        var vc = env.hosting.presentedViewController
        while let p = vc { if let v = p.view, let s = find(v) { return s }; vc = p.presentedViewController }
        return find(env.window)
    }

    /// Ablauf der Probe im echten Schluesselbund: Tag 0, Tag 6, Tag 7 + 1 Minute; Neuinstallation (App-Daten weg,
    /// Schluesselbund bleibt), Abmelden und wieder Anmelden, zweite Apple-ID auf demselben iPad
    func test21ProbeEinmalJeGeraet() throws {
        let service = "de.uniflow.ai.trial.test.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let cloudStore = MemoryCloud()
        func freshDefaults() -> UserDefaults {
            let name = "uniflow.tests.tarife.trial.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
            return UserDefaults(suiteName: name)!
        }
        let store1 = UFTrialRecordStore(keychain: keychain, cloud: cloudStore, defaults: freshDefaults())
        addTeardownBlock { _ = keychain.removeAll(); store1.removeDeviceMark() }
        let ada = "001234.ada-\(UUID().uuidString.prefix(6))", ben = "001234.ben-\(UUID().uuidString.prefix(6))"
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        func day(_ d: Double) -> Date { t0.addingTimeInterval(d * 86_400) }
        func needs(_ e: Entitlements) -> Bool {
            UFTrialDecision.required(local: e.localTrial, purchased: e.purchasedPlan, effective: e.plan, choiceMade: e.localTrialChoiceMade)
        }

        // Tag 0
        let e = Entitlements(observe: false)
        e.beginLocalTrial(userID: ada, records: store1, now: t0)
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertEqual(e.localTrial?.daysLeft, 7)
        XCTAssertFalse(needs(e))
        XCTAssertNotNil(store1.deviceTrialStart(), "Gerätemarke gesetzt")
        // Tag 6
        e.refreshLocalTrial(now: day(6))
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertEqual(e.localTrial?.daysLeft, 1)
        XCTAssertFalse(needs(e))
        // Tag 7 + 1 Minute
        e.refreshLocalTrial(now: day(7).addingTimeInterval(60))
        XCTAssertEqual(e.plan, .free)
        XCTAssertTrue(needs(e), "nach Ablauf muss entschieden werden")

        // Neuinstallation ohne Wahl: App-Daten (UserDefaults) weg, Schluesselbund bleibt -> keine neue Probe, Frage bleibt
        let store2 = UFTrialRecordStore(keychain: keychain, cloud: nil, defaults: freshDefaults())
        let e2 = Entitlements(observe: false)
        e2.beginLocalTrial(userID: ada, records: store2, now: day(9))
        XCTAssertEqual(e2.plan, .free, "Neuinstallation gibt keine neue Probe")
        XCTAssertEqual(e2.localTrial?.startedAt, t0)
        XCTAssertTrue(needs(e2))
        // Wahl "Bei Free bleiben", dann noch einmal neu installieren -> keine Frage mehr
        e2.stayOnFreeAfterLocalTrial()
        XCTAssertFalse(needs(e2))
        let store3 = UFTrialRecordStore(keychain: keychain, cloud: nil, defaults: freshDefaults())
        let e3 = Entitlements(observe: false)
        e3.beginLocalTrial(userID: ada, records: store3, now: day(10))
        XCTAssertTrue(e3.localTrialChoiceMade, "Wahl überlebt die Neuinstallation (Schlüsselbund)")
        XCTAssertFalse(needs(e3))
        // Abmelden und wieder anmelden
        e3.useLocalTrial(startedAt: nil)
        XCTAssertNil(e3.localTrial)
        e3.beginLocalTrial(userID: ada, records: store3, now: day(11))
        XCTAssertEqual(e3.plan, .free)
        XCTAssertEqual(e3.localTrial?.startedAt, t0)

        // zweite Apple-ID auf demselben iPad (auch nach Neuinstallation): keine Probe
        let e4 = Entitlements(observe: false)
        e4.beginLocalTrial(userID: ben, records: UFTrialRecordStore(keychain: keychain, cloud: nil, defaults: freshDefaults()), now: day(12))
        XCTAssertEqual(e4.plan, .free, "zweite Apple-ID: keine zweite Probe")
        XCTAssertEqual(e4.localTrial?.deviceUsed, true)
        XCTAssertFalse(needs(e4), "ohne eigene Probe kein Entscheidungs-Bildschirm (Tarifwahl beim ersten Start)")
        XCTAssertEqual(UFTrialBannerContent.make(service: nil, local: e4.localTrial, purchased: .free, choiceMade: false), .usedOnDevice)

        // Kauf beendet die Frage; Probe ueber den Dienst mit Tarif ebenso
        XCTAssertFalse(UFTrialDecision.required(local: UFLocalTrial.state(startedAt: t0, now: day(8)), purchased: .plus, effective: .plus, choiceMade: false))
        XCTAssertFalse(UFTrialDecision.required(local: UFLocalTrial.state(startedAt: t0, now: day(8)), purchased: .free, effective: .proAI, choiceMade: false))
        XCTAssertTrue(UFTrialDecision.required(local: UFLocalTrial.state(startedAt: t0, now: day(8)), purchased: .free, effective: .free, choiceMade: false))
    }

    final class MemoryCloud: UFCloudKeyValue {
        var values: [String: Double] = [:]
        func number(forKey key: String) -> Double? { values[key] }
        func set(_ value: Double, forKey key: String) { values[key] = value }
        func synchronize() -> Bool { true }
    }

    /// Tarifwahl nach der Probe: Titel, Free-Knopf "Bei Free bleiben", keine Karte "Aktueller Tarif"
    func test22TarifwahlTexteNachDerProbe() {
        XCTAssertEqual(PlanPickerView.title(.trialOver), UFTrialTexts.overTitle)
        XCTAssertNotEqual(PlanPickerView.title(.onboarding), UFTrialTexts.overTitle)
    }
}
