import StoreKitTest
import SwiftUI
import PDFKit
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Abnahme Version 1.0 im **Release-Stand** (07.11.2026, Entscheidung des Inhabers: nur die Leibniz Universitaet Hannover,
/// `UFReleaseUniversities.storeDefault`): der ganze Weg eines neuen Nutzers wie ein Tester, mit der echten Wurzel der App
/// (`RootView`: Begruessung -> Tarif -> Hochschulwahl -> Anmeldeseite -> Demo bzw. Stud.IP-Nachbau -> Oberflaeche) in einem
/// gehosteten Fenster. Je Station in zwei Groessen (1024 x 768 quer, 834 x 1194 hoch) geprueft: keine Texte mit
/// Hildesheim/HsH/Moodle/Learnweb/HISinOne/"in Vorbereitung"/"bald verfügbar", nichts ragt ueber das Fenster
/// (`LayoutWidthAuditTests.overflows`), keine leere Seite, Zurueck-Pfeil ueberall ausser auf der Uebersicht und den
/// Seiten des ersten Starts, jeder Knopf mit VoiceOver-Beschriftung. Kein Netz: Stud.IP und QIS antworten aus
/// `apps/apple/DebugStub/erststart` (Startargument -UFLoginStub, hier als Einstellung nur fuer die Dauer des Tests),
/// Mensa und Raumfinder aus den Testdaten des lokalen Backends, Tarife aus `UniFlow.storekit`.
///
/// Mit UF_ABNAHME_DIR (xcodebuild: TEST_RUNNER_UF_ABNAHME_DIR) schreibt der Test je Station und Groesse ein Bild
/// `<nn>-<station>-<breite>x<hoehe>.png` (zu breite Elemente rot umrandet) und `befunde-<test>.txt`.
@MainActor
final class AbnahmeV1LUHReleaseAppTests: XCTestCase {

    static let landscape = CGSize(width: 1024, height: 768)
    static let portrait = CGSize(width: 834, height: 1194)
    /// darf im Store-Build nirgends auf dem Bildschirm stehen (1.0 nur LUH; nichts vertroesten)
    static let forbidden = ["Hildesheim", "HsH", "Moodle", "Learnweb", "HISinOne", "in Vorbereitung", "bald verfügbar",
                            "Bald verfügbar"]
    /// nur vermerken: Namen der anderen Hochschulen, die an der LUH auch echt sein koennen ("QIS / LSF" heisst der
    /// Dienst der LUH selbst)
    static let soft = ["Campusmanagement", "LSF", "PLuS"]
    /// Debug-Reste, die im Release nicht erscheinen duerfen; im Debug-Testhost erlaubt nur, was `#if DEBUG` bzw.
    /// `Session.ownServerAvailable` zeigt (Reiter "Entwicklung", "Anmeldung überspringen (Debug)")
    static let debugWords = ["Debug", "TODO", "FIXME", "localhost", "127.0.0.1", "lorem"]
    static let debugAllowed = ["Anmeldung überspringen (Debug)", "Langen Hintergrundlauf starten (Debug)"]

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer?
    private var background: BackgroundSyncController!
    private var outDir: URL?
    private var storeSession: SKTestSession?
    private var oldSidebar: String?
    /// Befunde (Text) und Stationen (Name, bestanden) dieses Tests
    private var findings: [String] = []
    private var stations: [(name: String, ok: Bool)] = []

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        UFReleaseUniversities.shipped = UFReleaseUniversities.storeDefault              // Store-Build: nur die LUH
        bed = try ContainerTestBed(name: "abnahme-luh", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }             // jede Anfrage an eine Hochschule zaehlt
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(),
                               observeRevocation: false)
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        Entitlements.shared.setPlanForTesting(.free)                                    // neuer Nutzer: Free, keine Probe
        Entitlements.shared.useLocalTrial(startedAt: nil)
        UFGreeting.hourOverride = 12                                                    // "Hallo Ada" zu jeder Uhrzeit
        oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        UserDefaults.standard.set("full", forKey: "sidebar")
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
        UserDefaults.standard.removeObject(forKey: UFReleaseUniversities.launchArgumentKey)
        UserDefaults.standard.removeObject(forKey: "UFLoginStub")
        UFFmt.todayOverride = nil
        UFGreeting.hourOverride = nil
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

    // MARK: - Aufbau

    /// Die Wurzel der App wie in `UniFlowApp` (Umgebungswerte aus dem Container-Verwalter, beobachtet: Demo, QIS,
    /// Uni-Mail und der Weg der KI aendern sich mit dem Container)
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
        // wie UniFlowApp: die Sitzung folgt dem offenen Container (erster Start oeffnet ihn erst mit der Hochschulwahl)
        manager.onChange = { [weak session = env.session] c in session?.useLocal(c?.api ?? .local(.unavailable)) }
        env.pump(0.5)
        return env
    }

    /// Angemeldet, LUH gewaehlt, Anmeldeseiten durch, Demo-Inhalte im Container (wie nach "Ohne Hochschulkonto ansehen")
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

    /// Tarife aus `UniFlow.storekit` (nur Jahresabos seit 09.11.2026: Plus 19,99, Pro AI 39,99), ohne Kauf
    private func storeKit() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        storeSession = session
    }

    private var stubDir: URL { ContainerTestBed.stubDirectory }

    /// Stud.IP- und QIS-Nachbildung statt der Seiten der Universitaet (nur fuer die Dauer des Tests)
    private func useLoginStub() {
        UserDefaults.standard.set(stubDir.path, forKey: "UFLoginStub")
        XCTAssertTrue(DebugUniStub.isActive)
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

    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        if !ok { note("„\(text)“ fehlt", file: file, line: line) }
        return ok
    }

    /// Knoepfe "Zurück" (verschiedene Stellen)
    private func backArrows(_ env: HostedEnvironment) -> Int {
        var frames = Set<String>()
        for e in elements(in: env.window) where e.accessibilityTraits.contains(.button) && e.accessibilityLabel == UFBackButton.title {
            let f = e.accessibilityFrame
            frames.insert("\(Int(f.midX.rounded())),\(Int(f.midY.rounded()))")
        }
        return frames.count
    }

    /// Knoepfe ohne VoiceOver-Beschriftung (Name der Klasse und Stelle)
    private func unlabeledButtons(_ env: HostedEnvironment) -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60, let o = element as? NSObject, seen.insert(ObjectIdentifier(o)).inserted else { return }
            if let v = o as? UIView, v.isHidden || v.alpha < 0.01 || v is WKWebView { return }
            // UIViews zaehlen nur, wenn VoiceOver sie als Element sieht (die UIKit-Knoepfe hinter SwiftUI-`Menu`
            // sind keine Elemente; VoiceOver liest das Element der Beschriftung)
            let exposed = (o as? UIView).map(\.isAccessibilityElement) ?? true
            if exposed, o.accessibilityTraits.contains(.button),
               (o.accessibilityLabel ?? "").isEmpty, (o.accessibilityValue ?? "").isEmpty, (o.accessibilityHint ?? "").isEmpty {
                let f = o.accessibilityFrame
                if f.width > 0.5, f.height > 0.5, !f.isNull, !f.isInfinite, env.window.bounds.intersects(f) {
                    var what = String(describing: type(of: o))
                    let id = (o as? UIView)?.accessibilityIdentifier ?? (o as? UIAccessibilityElement)?.accessibilityIdentifier
                    if let id, !id.isEmpty { what += " #\(id)" }
                    out.append("\(what) bei x \(Int(f.minX)) y \(Int(f.minY)) (\(Int(f.width)) x \(Int(f.height)))")
                }
            }
            for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            if let v = o as? UIView, !(v is WKWebView) { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(env.window, depth: 0)
        return out
    }

    private func resize(_ env: HostedEnvironment, _ size: CGSize) {
        env.hosting.traitOverrides.horizontalSizeClass = size.width < 700 ? .compact : .regular
        env.window.frame = CGRect(origin: .zero, size: size)
        env.view.frame = env.window.bounds
    }

    /// Asynchrone Arbeit bei laufender Hauptschleife
    private func pumping<T>(_ timeout: Double = 30, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // Zeitueberschreitung ist ein Fehler, kein Ueberspringen (Audit P48, 08.11.2026: ein Haenger blieb sonst gruen)
        guard let result else { XCTFail("Zeitueberschreitung"); throw CancellationError() }
        return try result.get()
    }

    // MARK: - Befunde, Stationen, Bilder

    private func note(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        findings.append(text)
        XCTFail(text, file: file, line: line)
    }

    /// Nur vermerken (kein Fehler): Beobachtung fuer den Bericht
    private func remark(_ text: String) { findings.append("Hinweis: " + text) }

    private func writeFindings() {
        let title = name
        let lines = stations.map { "\($0.ok ? "✓" : "✗") \($0.name)" } + [""] + (findings.isEmpty ? ["keine Befunde"] : findings)
        print("=== Abnahme \(title) ===\n" + lines.joined(separator: "\n"))
        guard let outDir else { return }
        let safe = title.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        try? (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("befunde-\(safe).txt"), atomically: true, encoding: .utf8)
    }

    /// Station: Seite in beiden Groessen pruefen (Marker, verbotene Woerter, Debug-Reste, Breite, leere Seite,
    /// Zurueck-Pfeil, VoiceOver) und fotografieren; `back`: Zurueck-Pfeil erwartet (nein auf Uebersicht und erstem Start);
    /// `markers` muessen erscheinen
    private func station(_ env: HostedEnvironment, _ name: String, back: Bool = true, markers: [String] = [],
                         landscapeMarkers: [String] = [], settle: Double = 0.8,
                         file: StaticString = #filePath, line: UInt = #line) {
        var ok = true
        func fail(_ text: String) { ok = false; note("\(name): \(text)", file: file, line: line) }
        for (size, suffix) in [(Self.landscape, "1024x768"), (Self.portrait, "834x1194")] {
            resize(env, size)
            env.pump(settle)
            // die Seitenleiste (Tarif, Probe) gibt es nur quer
            let wanted = markers + (size.width >= 900 ? landscapeMarkers : [])
            for m in wanted where !env.wait(timeout: 12, until: { self.shows(env, m) }) { fail("@\(suffix): „\(m)“ erscheint nicht") }
            env.pump(0.4)
            let texts = self.texts(env)
            for w in Self.forbidden {
                for t in texts where t.contains(w) { fail("@\(suffix): „\(w)“ in „\(t.prefix(90))“") }
            }
            for w in Self.soft {
                for t in Set(texts) where t.contains(w) { remark("\(name) @\(suffix): „\(w)“ in „\(t.prefix(90))“") }
            }
            for w in Self.debugWords {
                for t in texts where t.contains(w) && !Self.debugAllowed.contains(t) { fail("@\(suffix): Debug-Rest „\(w)“ in „\(t.prefix(90))“") }
            }
            if texts.count < 6 { fail("@\(suffix): nur \(texts.count) Texte – leere Seite?\n" + texts.joined(separator: "\n")) }
            let over = overflows(env)
            if !over.isEmpty {
                fail("@\(suffix) (\(Int(size.width)) x \(Int(size.height))): \(over.count) zu breit\n" + over.prefix(20).map { "  " + $0.text }.joined(separator: "\n"))
            }
            let arrows = backArrows(env)
            if back && arrows == 0 { fail("@\(suffix): kein Zurück-Pfeil") }
            if !back && arrows > 0 { fail("@\(suffix): Zurück-Pfeil, wo keiner hingehört") }
            let unlabeled = unlabeledButtons(env)
            if !unlabeled.isEmpty { fail("@\(suffix): \(unlabeled.count) Knöpfe ohne VoiceOver-Beschriftung\n" + unlabeled.prefix(12).map { "  " + $0 }.joined(separator: "\n")) }
            shoot(env, "\(name)-\(suffix)", marks: over.map(\.rect))
        }
        stations.append((name, ok))
        resize(env, Self.landscape)
        env.pump(0.3)
    }

    /// Breiten-Audit (`LayoutWidthAuditTests.overflows`) ohne den Inhalt von PDFKit (Kacheln und Seiten ausserhalb
    /// des sichtbaren Bereichs liegen im zoombaren Bereich) und ohne den Rahmen von iOS um Blaetter und Dialoge
    /// (Abdunklung, Schatten) und die Bildlaufanzeige der PDF ("33 %", halb links ausserhalb), die bewusst ueber das Fenster reichen
    private func overflows(_ env: HostedEnvironment) -> [LayoutWidthAuditTests.Finding] {
        var pdfs: [UIView] = []
        func find(_ v: UIView) {
            if v is PDFView, !v.isHidden { pdfs.append(v); return }
            v.subviews.forEach(find)
        }
        find(env.window)
        pdfs.forEach { $0.isHidden = true }
        defer { pdfs.forEach { $0.isHidden = false } }
        // WKContentView: WebKit-intern, liegt in einer waagerecht nicht scrollenden WKScrollView; auf dem Mac ("Designed
        // for iPad") ist sie bei 1024 pt Fensterbreite 1 pt breiter als das Fenster (Rundung von WebKit, Befund 08.11.2026)
        let chrome = ["UIDimmingView", "_UIRoundedRectShadowView", "_UIInheritedView", "UIDropShadowView",
                      "_UICollectionViewListLayoutSectionBackgroundColorDecorationView", "WKContentView"]
        return LayoutWidthAuditTests.overflows(in: env.window).filter { f in
            !chrome.contains { f.text.contains($0) } && !(f.text.hasPrefix("Element „") && f.text.contains("%“"))
        }
    }

    /// Bild des Fensters (mit Blaettern und Dialogen), Massstab 2, zu breite Elemente rot umrandet
    private func shoot(_ env: HostedEnvironment, _ name: String, marks: [CGRect]) {
        guard let outDir else { return }
        let window = env.window
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

    private func webView(_ env: HostedEnvironment) -> WKWebView? {
        func find(_ v: UIView) -> WKWebView? {
            if let w = v as? WKWebView { return w }
            for s in v.subviews { if let w = find(s) { return w } }
            return nil
        }
        return find(env.window)
    }

    private func segmented(_ env: HostedEnvironment) -> UISegmentedControl? {
        func find(_ v: UIView) -> UISegmentedControl? {
            if let s = v as? UISegmentedControl { return s }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        var roots: [UIView] = [env.window]
        if let v = env.hosting.presentedViewController?.view { roots.append(v) }
        for r in roots { if let s = find(r) { return s } }
        return nil
    }

    private func dismissPresented(_ env: HostedEnvironment) {
        env.hosting.presentedViewController?.dismiss(animated: false)
        _ = env.wait(timeout: 5) { env.hosting.presentedViewController == nil }
        env.pump(0.3)
    }

    // MARK: - 0 Feste Texte im Store-Build (Befunde der Abnahme 07.11.2026)

    func test00TexteOhneAndereHochschulen() {
        XCTAssertEqual(UFReleaseUniversities.filePlatforms, "Stud.IP")
        XCTAssertEqual(UFReleaseUniversities.gradePlatforms, "QIS")
        let texts = [DueTexts.reminderText, DeleteAccountText.removed(ownServer: false), DeleteAccountText.removed(ownServer: true),
                     UFFeature.uniGrades.detail ?? "", CommunityTexts.visibilityModule] + AIHelpContent.without.items
        for t in texts {
            for w in Self.forbidden + ["LSF", "bzw."] { XCTAssertFalse(t.contains(w), "„\(w)“ in „\(t)“") }
        }
        XCTAssertTrue(DueTexts.reminderText.contains("erkannten Termine und eingetragene Klausurtermine"), DueTexts.reminderText)
        XCTAssertTrue(DeleteAccountText.removed(ownServer: false).contains("(Stud.IP-Sitzung, gemerkte Hochschul-Passwörter)"))
        // mit allen Hochschulen (1.0.1) wieder alle Quellen
        UFReleaseUniversities.withShipped(Set(UniversityKey.allCases)) {
            XCTAssertEqual(UFReleaseUniversities.filePlatforms, "Stud.IP, Learnweb bzw. Moodle")
            XCTAssertEqual(UFReleaseUniversities.gradePlatforms, "QIS, LSF bzw. HISinOne")
            XCTAssertTrue(DueTexts.reminderText.contains("Fristen aus dem Learnweb-Kalender"))
            XCTAssertTrue(DeleteAccountText.removed(ownServer: false).contains("Learnweb-Schlüssel"))
        }
    }

    // MARK: - 1 Erster Start: Willkommen -> Rundgang -> Hochschulwahl -> Anmeldeseite -> Demo ohne Konto -> Fragen -> Tarife -> Uebersicht

    func test01ErsterStartBisZurDemo() throws {
        try storeKit()
        useLoginStub()
        let env = try host()
        XCTAssertEqual(account.stage, .welcome)
        expect(env, IntroWelcomeText.title)
        station(env, "01-begruessung", back: false, markers: [IntroWelcomeText.title, IntroWelcomeText.accountQuestion])
        XCTAssertTrue(texts(env).contains { $0.contains("Apple") }, "Knopf „Mit Apple anmelden“:\n" + dump(env))

        // "Mit Apple anmelden" oeffnet den Dialog von iOS (im Test nicht moeglich): die Anmeldung wie nach dem Dialog
        account.signIn(userID: bed.user, name: "Ada Erfunden", email: nil, givenName: "Ada")
        // neuer Einstieg (13.11.2026): Rundgang, ueberspringbar
        XCTAssertEqual(account.stage, .tour)
        expect(env, IntroTourPage.uni.title)
        station(env, "02-rundgang", back: false, markers: [IntroTourPage.uni.title, "Weiter", "Überspringen"])
        XCTAssertTrue(tap("Überspringen", in: env), "Rundgang überspringen:\n" + dump(env))
        XCTAssertTrue(env.wait { self.account.stage == .universityPicker }, "nach dem Rundgang die Hochschulwahl")

        // Hochschulwahl: nur die LUH, der Hinweis auf weitere Hochschulen, nichts von Hildesheim/HsH
        expect(env, "Hochschule wählen")
        station(env, "03-hochschulwahl", back: false, markers: ["Hochschule wählen", UniversityKey.luh.profile.name, UniversityPickerView.moreNote, "Weiter"])
        XCTAssertFalse(shows(env, UniversityKey.hildesheim.profile.name), "Hildesheim nicht zur Wahl:\n" + dump(env))
        XCTAssertFalse(shows(env, UniversityKey.hsh.profile.name), "HsH nicht zur Wahl:\n" + dump(env))
        XCTAssertTrue(tap(UniversityKey.luh.profile.name, in: env, exact: false), "LUH antippen:\n" + dump(env))
        env.pump(0.3)
        XCTAssertTrue(tap("Weiter", in: env), "Weiter:\n" + dump(env))
        XCTAssertTrue(env.wait { self.account.stage == .universityLogin }, "nach der Hochschulwahl sofort die Anmeldeseiten")
        XCTAssertTrue(env.wait(timeout: 20) { self.manager.active != nil }, "Container der LUH geoeffnet: \(manager.problem ?? "")")
        container = manager.active

        // Anmeldeseite Stud.IP (Nachbildung), unten "Später anmelden" und der Demo-Link
        expect(env, "Schritt 1 von 2: " + FirstLoginStep.studip.title)
        XCTAssertTrue(env.wait(timeout: 20) { self.webView(env)?.url?.lastPathComponent == "studip.html" }, "Nachbildung der Anmeldeseite geladen")
        env.pump(1.0)
        station(env, "04-anmeldung-studip", back: false,
                markers: ["Schritt 1 von 2: " + FirstLoginStep.studip.title, "Später anmelden", DemoTexts.firstStart, UniversityLoginHint.more])

        // Demo ohne Konto: der kleine Textlink ganz unten
        XCTAssertTrue(tap(DemoTexts.firstStart, in: env), "Demo-Link:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 30) { self.manager.demoActive && self.account.stage == .setup }, "Demo angelegt, dann die Fragen")
        // Fragen im Gespraech: Rufname vorbelegt mit dem Vornamen aus der Apple-Anmeldung, "Später" ueberspringt alle
        expect(env, IntroSetupModel().question(.name))
        station(env, "05-fragen", back: false, markers: [IntroSetupModel().question(.name), "Weiter", "Später"])
        XCTAssertTrue(tap("Später", in: env), "Fragen überspringen:\n" + dump(env))
        // Probe und Tarife: Preise aus StoreKit, nur Jahresabos, Pflichtangaben
        XCTAssertTrue(env.wait { self.account.stage == .planPicker }, "zum Schluss Probe und Tarife")
        expect(env, UFPlan.plus.name)
        expect(env, "19,99")
        station(env, "06-tarife", back: false, markers: [UFPlan.free.name, UFPlan.plus.name, "/Jahr", PlanPickerView.LegalPage.terms.rawValue,
                                                         PlanPickerView.LegalPage.privacy.rawValue, "Käufe wiederherstellen"])
        XCTAssertFalse(shows(env, "Monatlich"), "nur Jahresabos (09.11.2026):\n" + dump(env))
        for word in ["Geld zurück", "Preis zurzeit nicht verfügbar", "Mit ChatGPT anmelden"] {
            XCTAssertFalse(shows(env, word), "Tarife: „\(word)“ im Bild")
        }
        XCTAssertTrue(tap(IntroPlanText.startTrial, in: env) || tap(IntroPlanText.startFree, in: env), "loslegen:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 30) { self.account.stage == .ready }, "Oberflaeche")
        expect(env, "Hallo Ada")
        expect(env, "Grundlagen der Informatik")
        station(env, "07-uebersicht-demo", back: false, markers: ["Hallo Ada", DemoTexts.barTitle, DemoTexts.barEnd, "Grundlagen der Informatik"])
        XCTAssertFalse(shows(env, "Stud.IP verbinden"), "Demo: keine Karte zum Verbinden:\n" + dump(env))
        XCTAssertFalse(manager.studip.hasStoredSession)
    }

    // MARK: - 2 Rundgang mit Demo-Inhalten (Free, ohne Konto beim Dienst)

    func test02DemoRundgang() throws {
        try pumping { try await self.openDemo() }
        let env = try host()
        expect(env, "Hallo Ada")
        station(env, "10-uebersicht", back: false, markers: ["Hallo Ada", DemoTexts.barTitle, "Grundlagen der Informatik"])

        env.router.go(.timetable())
        station(env, "11-stundenplan", markers: ["Stundenplan", "Grundlagen der Informatik"])

        env.router.go(.modules)
        station(env, "12-module", markers: ["Meine Module", "Grundlagen der Informatik"])

        let api = container!.api
        let modules = try pumping { try await api.value("/api/modules").items }
        let moduleID = try XCTUnwrap(modules.first?.i("id"), "Demo-Modul")
        let detail = try pumping { try await api.value("/api/modules/\(moduleID)") }
        let weeks = detail.list("weeks").compactMap { $0.i("week") }
        XCTAssertFalse(weeks.isEmpty, "Demo-Modul hat Lehrwochen: \(detail.jsonString().prefix(300))")
        env.router.go(.module(moduleID))
        station(env, "13-modul-wochen", markers: ["Grundlagen der Informatik", "Woche"])

        // Dokument (PDF) in Free: nur ansehen, Schreiben ab Plus mit Hinweis; Antippen oeffnet das Blatt zum Tarif
        env.router.go(.doc("demo-blatt"))
        let lockLabel = "Nur ansehen – Schreiben ab \(UFPlan.plus.name)"
        expect(env, lockLabel, timeout: 25)
        XCTAssertTrue(env.wait(timeout: 25) { !StoreScreenshotTests.canvases(in: env.view).isEmpty }, "PDF-Seiten im Editor:\n" + dump(env))
        env.pump(1.5)
        station(env, "14-dokument-pdf-free", markers: [lockLabel], settle: 1.2)
        XCTAssertTrue(tap(lockLabel, in: env), "Hinweis antippen:\n" + dump(env))
        // seit 12.11.2026 (Auftrag des Inhabers: Schloss antippen oeffnet die Tarifwahl mit dem noetigen Tarif) direkt die
        // Tarifwahl "Mehr mit StudiNow Plus" statt erst der Sperrkarte mit "Mit StudiNow Plus freischalten"
        XCTAssertTrue(env.wait(timeout: 10) { env.hosting.presentedViewController != nil && self.shows(env, "Mehr mit \(UFPlan.plus.name)") },
                      "Tarifwahl mit Plus:\n" + dump(env))
        station(env, "15-stift-gesperrt-blatt", markers: ["Mehr mit \(UFPlan.plus.name)", UFPlan.plus.name])
        if !tap("Schließen", in: env) { dismissPresented(env) }
        XCTAssertTrue(env.wait(timeout: 5) { env.hosting.presentedViewController == nil }, "Blatt geschlossen")

        // KI-Hilfe im Dokument ohne Konto und ohne Tarif: Hinweis mit Weg zu den Tarifen, kein Absturz
        env.router.go(.dashboard)
        env.pump(0.5)
        env.router.tutorOpenRequest = "demo-skript"
        env.router.go(.doc("demo-skript"))
        expect(env, "Die KI-Hilfe kommt mit der StudiNow-KI", timeout: 25)
        expect(env, TutorConnectState.Content.buttonTitle(.notConnected))
        env.pump(1.0)
        station(env, "16-ki-hilfe-ohne-konto", markers: ["Die KI-Hilfe kommt mit der StudiNow-KI", TutorConnectState.Content.buttonTitle(.notConnected)], settle: 1.2)

        env.router.go(.aiStart)
        station(env, "17-ki-start", markers: ["Wochentest", "Karteikarten"])

        env.router.go(.exams)
        station(env, "18-tests-ohne-ki", markers: ["Tests & Wiederholung", "Zu den Karteikarten", UFPlan.proAI.name])

        env.router.go(.cards)
        station(env, "19-karteikarten-free", markers: ["Karteikarten"])
        XCTAssertTrue(shows(env, UFFlashcardAccess.readOnlyHint) || shows(env, "Mit \(UFPlan.plus.name) freischalten"),
                      "Karteikarten in Free: Hinweis auf Plus:\n" + dump(env))

        env.router.go(.uniMail)
        station(env, "20-uni-mail", markers: ["Uni-Mail", "Uni-Mail verbinden"])

        env.router.go(.lecturers)
        station(env, "21-lehrende", markers: [LecturersText.title, LecturersText.pageSub])

        env.router.go(.rooms)
        station(env, "22-raumfinder", markers: ["Raumfinder", "Hauptgebäude (Welfengarten)"])

        // Mensa: am Wochenende der naechste Werktag als "heute" (sonst zu Recht "Geschlossen")
        UFFmt.todayOverride = StoreScreenshotV11Tests.nextServiceDay()
        env.router.go(.mensa)
        station(env, "23-mensa", markers: ["Mensa", "Öffnungszeiten"])
        UFFmt.todayOverride = nil

        env.router.go(.certificates)
        station(env, "24-bescheinigungen", markers: ["Bescheinigungen"])

        env.router.go(.plan())
        station(env, "25-lernkalender", markers: ["Lernkalender"])

        env.router.go(.files())
        station(env, "26-dokumente", markers: ["Dokumente & Notizen"])

        env.router.go(.messages)
        station(env, "27-nachrichten", markers: ["Nachrichten"])

        env.router.go(.services)
        station(env, "28-uni-noten", markers: ["Uni & Noten"])

        env.router.go(.studyPlan())
        station(env, "29-studienverlauf", markers: ["Studienverlauf"])
    }

    // MARK: - 3 Einstellungen: alle Karten, Tarif wechseln (Jahresabos), Eigenes ChatGPT, Rechtliches, Dialoge, Probe

    func test03Einstellungen() throws {
        try storeKit()
        try pumping { try await self.openDemo() }
        let env = try host()
        expect(env, "Hallo Ada")

        env.router.go(.settings(tab: "account"))
        station(env, "30-einstellungen-zugang",
                markers: ["Zugang & Darstellung", "Konto", "Tarif", "Hochschule", UniversityKey.luh.profile.name, UniversityPickerView.moreNote,
                          "Rechtliches & Support", "Support", "Nutzungsbedingungen", "Datenschutzerklärung", "Impressum", "Stud.IP & QIS",
                          "Konto löschen", "Daten dieser Hochschule löschen", "Tarif wechseln"])
        XCTAssertFalse(shows(env, "Hochschule wechseln"), "1.0: kein Wechsel-Dialog mit einer einzigen Hochschule")

        // Tarif wechseln: Blatt mit den Jahresabos (09.11.2026, kein Umschalter Monatlich/Jaehrlich)
        XCTAssertTrue(tap("Tarif wechseln", in: env), "Tarif wechseln:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 15) { env.hosting.presentedViewController != nil && self.shows(env, UFPlan.plus.name + " für 19,99") },
                      "Tarifblatt mit Preisen:\n" + dump(env))
        station(env, "31-tarif-jaehrlich", markers: [PlanPickerView.title(.settings), UFPlan.plus.name + " für 19,99", UFPlan.proAI.name + " für 39,99", "/Jahr", "Käufe wiederherstellen"])
        XCTAssertNil(segmented(env), "kein Umschalter der Zahlweise")
        XCTAssertFalse(shows(env, "Monatlich"), "nur Jahresabos:\n" + dump(env))
        if !tap("Schließen", in: env) { dismissPresented(env) }
        XCTAssertTrue(env.wait(timeout: 5) { env.hosting.presentedViewController == nil }, "Tarifblatt geschlossen")

        // Konto loeschen: Rueckfrage, abbrechen
        XCTAssertTrue(tap("Konto löschen", in: env), "Konto löschen:\n" + dump(env))
        expect(env, "Konto löschen?")
        expect(env, "Abos verwalten")
        station(env, "33-konto-loeschen-dialog", markers: ["Konto löschen?", "Abbrechen", "Abos verwalten"])
        XCTAssertTrue(tap("Abbrechen", in: env))
        XCTAssertTrue(env.wait { !self.shows(env, "Konto löschen?") }, "Dialog zu")

        // Daten dieser Hochschule loeschen: Rueckfrage ohne Namen anderer Hochschulen, abbrechen
        XCTAssertTrue(tap("Daten dieser Hochschule löschen", in: env), "Daten löschen:\n" + dump(env))
        expect(env, "Daten der \(UniversityKey.luh.profile.name) löschen?")
        station(env, "34-hochschule-loeschen-dialog", markers: ["Daten der \(UniversityKey.luh.profile.name) löschen?", "anderer Hochschulen bleiben unberührt", "Abbrechen"])
        XCTAssertTrue(tap("Abbrechen", in: env))
        XCTAssertTrue(env.wait { !self.shows(env, "löschen?") }, "Dialog zu")

        // uebrige Reiter (die Einstellungen lesen den Reiter beim Erscheinen: ueber die Uebersicht neu oeffnen)
        env.router.go(.dashboard); env.pump(0.3)
        env.router.go(.settings(tab: "modules"))
        station(env, "35-einstellungen-module", markers: ["Module", "Grundlagen der Informatik"])
        env.router.go(.dashboard); env.pump(0.3)
        env.router.go(.settings(tab: "plan"))
        station(env, "36-einstellungen-lernzeit", markers: ["Lernzeit"])
        env.router.go(.dashboard); env.pump(0.3)
        env.router.go(.settings(tab: "advanced"))
        station(env, "37-einstellungen-erweitert", markers: ["Erweitert", "Eigenes ChatGPT"])
        if shows(env, "KI über mein ChatGPT") { remark("Erweitert: Karte „KI über mein ChatGPT“ (Anmeldung bei OpenAI nicht freigegeben) mit Abzeichen „bald“ sichtbar") }

        // Probe auf dem iPad: laufend (Seitenleiste, Uebersicht, Tarif-Karte), danach vorbei mit "Bei Free bleiben"
        Entitlements.shared.useLocalTrial(startedAt: Date())
        env.router.go(.dashboard)
        expect(env, UFTrialTexts.running(7))
        station(env, "38-probe-laeuft", back: false, markers: [UFTrialTexts.running(7), UFTrialTexts.plans], landscapeMarkers: ["Probe, noch 7 Tage"])
        env.router.go(.settings(tab: "account"))
        station(env, "39-probe-tarifkarte", markers: [UFTrialTexts.running(7)])
        Entitlements.shared.useLocalTrial(startedAt: Date().addingTimeInterval(-8 * 86_400))
        env.router.go(.dashboard)
        expect(env, UFTrialTexts.overTitle)
        station(env, "40-probe-vorbei", back: false, markers: [UFTrialTexts.overTitle, UFTrialTexts.stayFree, UFTrialTexts.plans], landscapeMarkers: ["Tarif Free"])
        XCTAssertTrue(tap(UFTrialTexts.stayFree, in: env))
        XCTAssertTrue(env.wait { !self.shows(env, UFTrialTexts.overTitle) }, "Hinweis weg nach „Bei Free bleiben“")
        Entitlements.shared.useLocalTrial(startedAt: nil)
    }

    // MARK: - 4 Stud.IP-Anmeldung mit Nachbau: Verbinden, Erstabgleich mit Fortschritt, Stundenplan, Dateien, Wochen

    func test04StudIPNachbauErstabgleich() throws {
        useLoginStub()
        account.signIn(userID: bed.user, name: "Ada Erfunden", email: nil, givenName: "Ada")
        account.markPlanShown()
        account.chooseUniversity(.luh)
        container = try bed.open(manager, account)
        XCTAssertEqual(account.stage, .universityLogin)
        let qis = try XCTUnwrap(manager.qis)
        qis.syncsAfterSignIn = false
        let env = try host()

        // Schritt 1: Stud.IP – die Nachbildung zeigt nach "Anmelden" die Seite studip-angemeldet.html
        expect(env, "Schritt 1 von 2: " + FirstLoginStep.studip.title)
        let web = try XCTUnwrap(env.wait(timeout: 20) { self.webView(env)?.url?.lastPathComponent == "studip.html" } ? webView(env) : nil,
                                "Nachbildung geladen:\n" + dump(env))
        web.loadFileURL(stubDir.appendingPathComponent("studip-angemeldet.html"), allowingReadAccessTo: stubDir)
        XCTAssertTrue(env.wait(timeout: 20) { self.manager.studip.hasStoredSession }, "Stud.IP-Sitzung gespeichert")
        // wie `StudIPSync.signedIn` in der App (unter XCTest laeuft der Abgleich nicht von selbst): Nachbildung, langsam
        // genug, dass der Fortschritt zu sehen ist
        let client = StudIPClient(base: StudIPSync.base, transport: DebugStubTransport(directory: stubDir), pauseMillis: 120)
        var finished = false
        Task { @MainActor in _ = await self.manager.studip.run(client: client); finished = true }

        // Schritt 2: QIS – "Später anmelden"
        expect(env, "Schritt 2 von 2: " + FirstLoginStep.qis.title)
        env.pump(0.8)
        station(env, "50-anmeldung-qis", back: false, markers: ["Schritt 2 von 2: " + FirstLoginStep.qis.title, "Später anmelden"])
        XCTAssertFalse(shows(env, DemoTexts.firstStart), "nach der Stud.IP-Anmeldung kein Demo-Link mehr")
        XCTAssertTrue(tap("Später anmelden", in: env), "Später anmelden:\n" + dump(env))

        // Erstabgleich mit Fortschritt
        expect(env, "Kurse und Dateien aus Stud.IP")
        if !finished {
            expect(env, FirstSyncProgress.title(finished: false, anyLoaded: false), timeout: 5)
            station(env, "51-erstabgleich-laeuft", back: false, markers: ["Kurse und Dateien aus Stud.IP", "Stundenplan", "Noten aus QIS", "QIS später anmelden"], settle: 0.3)
        } else {
            remark("Erstabgleich war schon fertig, bevor die Seite stand (kein Bild „läuft“)")
        }
        XCTAssertTrue(env.wait(timeout: 60) { finished }, "Abgleich fertig")
        XCTAssertEqual(manager.studip.phase, .idle, manager.studip.lastSummary ?? "")
        expect(env, FirstSyncProgress.title(finished: true, anyLoaded: true))
        expect(env, "5 neu/geändert")
        station(env, "52-erstabgleich-fertig", back: false, markers: [FirstSyncProgress.title(finished: true, anyLoaded: true), "5 neu/geändert", "Zur Übersicht"])
        XCTAssertTrue(tap("Zur Übersicht", in: env), "Zur Übersicht:\n" + dump(env))
        XCTAssertTrue(env.wait { self.account.stage == .ready }, "Oberflaeche")

        // Uebersicht mit den Dateien aus Stud.IP, Stundenplan, Module, Modul mit Wochen
        let api = container!.api
        let lib = try pumping { try await api.value("/api/library") }
        let names = (lib["files"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
        XCTAssertEqual(names, ["01_Vorlesung_Mengen.pdf", "02_Vorlesung_Induktion.pdf", "Blatt01.pdf", "Programmieren_VL01.pdf", "Uebungsblatt_01.pdf"])
        expect(env, "Hallo Ada")
        station(env, "53-uebersicht-studip", back: false, markers: ["Hallo Ada", UFSourceText.newFiles(.luh)])
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "keine Demo-Leiste")
        XCTAssertFalse(shows(env, "Stud.IP verbinden"), "verbunden: keine Karte zum Verbinden")

        env.router.go(.timetable())
        station(env, "54-stundenplan-studip", markers: ["Stundenplan", "Mathematik"])

        env.router.go(.modules)
        station(env, "55-module-studip", markers: ["Meine Module", "Programmieren I", "Mathematik"])

        let modules = try pumping { try await api.value("/api/modules").items }
        let mathe = try XCTUnwrap(modules.first { ($0.s("name") ?? "").contains("Mathematik") }, "Modul Mathematik: \(modules.compactMap { $0.s("name") })")
        let matheID = try XCTUnwrap(mathe.i("id"))
        let detail = try pumping { try await api.value("/api/modules/\(matheID)") }
        var fileWeeks: [String: Int] = [:]
        // je Woche nach Art gruppiert (vorlesungen, uebungen, ...; `LocalModules.groupKeys`)
        for w in detail.list("weeks") {
            for (_, group) in w.object ?? [:] {
                for f in group.array ?? [] { if let n = f.s("name") { fileWeeks[n] = w.i("week") } }
            }
        }
        XCTAssertEqual(fileWeeks["01_Vorlesung_Mengen.pdf"], 1, "Lehrwoche aus dem Dateinamen: \(fileWeeks)")
        XCTAssertEqual(fileWeeks["02_Vorlesung_Induktion.pdf"], 2, "Lehrwoche aus dem Dateinamen: \(fileWeeks)")
        env.router.go(.module(matheID))
        station(env, "56-modul-wochen-studip", markers: ["Mathematik", "Woche 1", "Woche 2", "01_Vorlesung_Mengen"])

        // Einstellungen: Stud.IP verbunden, Abmelden-Dialog (abbrechen)
        env.router.go(.settings(tab: "account"))
        station(env, "57-einstellungen-studip-verbunden", markers: ["Stud.IP & QIS", "verbunden", "Öffnen"])
        XCTAssertTrue(tap("Öffnen", in: env), "Stud.IP öffnen:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 15) { env.hosting.presentedViewController != nil && self.shows(env, "Abmelden") }, "Stud.IP-Blatt:\n" + dump(env))
        station(env, "58-studip-verbindung", markers: ["Abmelden", "Jetzt abgleichen"])
        XCTAssertTrue(tap("Abmelden", in: env), "Abmelden:\n" + dump(env))
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env, "Von Stud.IP abmelden?") }, "Rueckfrage:\n" + dump(env))
        station(env, "59-abmelden-dialog", markers: ["Von Stud.IP abmelden?", "Abmelden und Dateien löschen"])
        // abbrechen: der Dialog von iOS; ohne antippbares "Abbrechen" schliessen
        if !tap("Abbrechen", in: env) {
            var vc = env.hosting.presentedViewController
            while let p = vc?.presentedViewController { vc = p }
            (vc as? UIAlertController)?.dismiss(animated: false)
        }
        XCTAssertTrue(env.wait(timeout: 5) { !self.shows(env, "Von Stud.IP abmelden?") }, "Rueckfrage zu")
        XCTAssertTrue(manager.studip.hasStoredSession, "abgebrochen: weiter angemeldet")
        dismissPresented(env)
    }
}
