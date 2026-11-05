import StoreKitTest
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Breiten-Audit (04.11.2026, Fotos des Inhabers vom iPad (A16), 1180 x 820 quer): nach der neuen Seitenleiste ragten
/// Einstellungen und Uni & Noten rechts ueber den Bildschirm ("…(Plus oder", "Noten abrufen" und "Abmelden"
/// abgeschnitten). Getestet war nur auf dem iPad Pro 11" (1210 x 834). Dieser Test zeigt jede Seite der App in der
/// echten Huelle (`MainView`: Seitenleiste, Kopfzeile, Seite) mit den Demo-Inhalten in den Groessen des iPad (A16)
/// quer und hoch, in Split View (2/3 und 1/2) und im iPad Pro 13" hoch, mit ausgeklappter und eingeklappter
/// Seitenleiste, und prueft: kein UIView, keine Ebene und kein Bedienungshilfen-Element reicht rechts (oder links)
/// ueber das Fenster hinaus. Ausgenommen ist nur der Inhalt waagerecht scrollender Bereiche (Reiterzeilen, Chips),
/// die das so wollen; der Bereich selbst muss passen.
///
/// Mit UF_LAYOUT_DIR (xcodebuild: TEST_RUNNER_UF_LAYOUT_DIR) schreibt der Test je Seite und Groesse ein Bild, zu
/// breite Elemente rot umrandet.
@MainActor
final class LayoutWidthAuditTests: XCTestCase {

    struct Variant {
        let size: CGSize
        let name: String
        /// "full" oder "min" (`@AppStorage("sidebar")`); unter 900 pt gibt es keine Seitenleiste
        let sidebar: String
    }

    /// iPad (A16) = iPad 10,9": 1180 x 820 quer, 820 x 1180 hoch; Split View quer 2/3 = 780, 1/2 = 590; iPad Pro 13"
    /// hoch 1032 (Seitenleiste neben nur 784 pt Inhalt)
    static let variants: [Variant] = [
        Variant(size: CGSize(width: 1180, height: 820), name: "a16-quer", sidebar: "full"),
        Variant(size: CGSize(width: 1180, height: 820), name: "a16-quer-eingeklappt", sidebar: "min"),
        Variant(size: CGSize(width: 820, height: 1180), name: "a16-hoch", sidebar: "full"),
        Variant(size: CGSize(width: 780, height: 820), name: "split-2-3", sidebar: "full"),
        Variant(size: CGSize(width: 590, height: 820), name: "split-1-2", sidebar: "full"),
        Variant(size: CGSize(width: 1032, height: 1376), name: "pro13-hoch", sidebar: "full"),
    ]

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var qis: QISConnection!
    private var outDir: URL?
    private var oldSidebar: String?
    private var storeSession: SKTestSession?
    private var background: BackgroundSyncController!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "layout", clock: .system)
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

        // Uni & Noten wie auf dem Foto: QIS verbunden (Noten abrufen, Abmelden) und ein Notenspiegel mit langen Namen
        container.defaults.set(true, forKey: QISConnection.Keys.connected)
        container.defaults.set(Date(), forKey: QISConnection.Keys.lastRun)
        qis = QISConnection(container: container, websiteDataStore: manager.websiteDataStore(for: container))
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        let db = try await container.host.backend().context.database
        let rows: [[String]] = [
            ["", "Pflichtmodule Informatik", "", "2,3", "", "35", ""],
            ["4711", "Grundlagen der Informatik und Programmierung", "WiSe 2025/26", "1,7", "bestanden", "10", ""],
            ["4712", "Mathematik für Ingenieurinnen und Ingenieure I", "WiSe 2025/26", "2,7", "bestanden", "8", ""],
            ["4713", "Grundlagen digitaler Systeme", "SoSe 2026", "", "nicht bestanden", "5", ""],
            ["47131", "Grundlagen digitaler Systeme (Klausur)", "SoSe 2026", "5,0", "nicht bestanden", "", "1"],
        ]
        for r in rows {
            try await db.execute("INSERT INTO grades (pruefungsnr, text, semester, note, status, credits, versuch) VALUES (?,?,?,?,?,?,?)",
                                 r.map { $0.isEmpty ? .null : .text($0) })
        }
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.execute("INSERT INTO qis_runs (started_at, finished_at, ok, message, grades) VALUES (?,?,1,'4 Leistungen',4)", [.text(now), .text(now)])

        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        if let dir = ProcessInfo.processInfo.environment["UF_LAYOUT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Seiten

    func testStudium() throws {
        let env = try host(MainView())
        var report: [String] = []
        report += audit(env, "uebersicht", route: .dashboard, marker: "Grundlagen der Informatik")
        report += audit(env, "nachrichten", route: .messages, marker: nil)
        report += audit(env, "lernkalender", route: .plan(), marker: "Übungsblatt 1")
        report += audit(env, "stundenplan", route: .timetable(), marker: "Grundlagen der Informatik")
        report += audit(env, "module", route: .modules, marker: "Grundlagen der Informatik")
        let api = container.api
        if let id = try pumping({ try await api.value("/api/modules").items.first?.i("id") }) {
            report += audit(env, "modul", route: .module(id), marker: "Grundlagen der Informatik")
        } else {
            XCTFail("kein Demo-Modul")
        }
        report += audit(env, "dokumente", route: .files(), marker: nil)
        report += audit(env, "dokumente-neu", route: .files(section: "new", path: nil, q: nil), marker: "Zahlensysteme")
        report += audit(env, "regal", route: .files(section: "shelf", path: nil, q: nil), marker: "Mein Regal")
        report += audit(env, "uni-noten", route: .services, marker: "Mathematik für Ingenieurinnen")
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    func testLernen() throws {
        let t = StoreScreenshotTests.Intercept(container.host)
        t.answer("/api/ai/tutor", StoreScreenshotTests.tutorAnswer)
        t.answer("/api/tests/18", StoreScreenshotTests.demoTest)
        let env = try host(MainView(), api: APIClient(base: APIClient.localBase, transport: t), ai: true)
        var report: [String] = []
        report += audit(env, "ki-start", route: .aiStart, marker: nil)
        report += audit(env, "tests", route: .exams, marker: "Tests & Wiederholung")
        report += audit(env, "test-ergebnis", route: .exam(18, task: nil), marker: "Hexadezimalsystem")
        report += audit(env, "karteikarten", route: .cards, marker: "heute fällig")
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    func testGemeinsamUndEinstellungen() throws {
        let env = try host(MainView())
        var report: [String] = []
        report += audit(env, "community", route: .community, marker: "Deine Communities")
        // Mensa (05.11.2026): erfundener Plan ohne Netz (`MensaDemoHTTP` unter XCTest), Oeffnungszeiten immer da
        report += audit(env, "mensa", route: .mensa, marker: "Öffnungszeiten")
        // Raumfinder (05.11.2026): Suche und Standorte der LUH (Demo-Treffer unter XCTest, kein Netz)
        report += audit(env, "raumfinder", route: .rooms, marker: "Hauptgebäude (Welfengarten)")
        report += audit(env, "einstellungen-zugang", route: .settings(tab: "account"), marker: "Zugang & Darstellung")
        report += audit(env, "einstellungen-module", route: .settings(tab: "modules"), marker: "Grundlagen der Informatik")
        report += audit(env, "einstellungen-lernzeit", route: .settings(tab: "plan"), marker: "Lernzeit")
        report += audit(env, "einstellungen-erweitert", route: .settings(tab: "advanced"), marker: "Erweitert")
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Tarifseite (Blatt "Tarif wechseln" aus den Einstellungen und der Seitenleiste) mit allen drei Tarifen
    func testTarife() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        storeSession = session
        let env = try host(ZStack { UF.bg.ignoresSafeArea(); PlanPickerView(context: .settings, entitlements: Entitlements.shared) {} })
        let report = audit(env, "tarife", route: nil, marker: UFPlan.plus.name)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    // MARK: - Hosten

    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufAIEnabled, ai)
            .environment(\.qis, qis)
            // wie UniFlowApp: ChatGPT (Erweitert), StudiNow-Konto (Zugang), Abgleich im Hintergrund
            .environment(\.ufChatGPTLink, manager.chatgpt)
            .environment(\.ufStudoraAccount, manager.account)
            .environment(\.backgroundSync, background)
            .environmentObject(manager!)
            .environmentObject(account!)
        return try hostWithEnvironment(root, api: api ?? container.api, size: Self.variants[0].size, studip: manager.studip)
    }

    /// async-Arbeit ausfuehren und dabei die Hauptschleife laufen lassen (wie DesignShellAppTests)
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

    /// Seite in allen Groessen pruefen; Rueckgabe: Befunde je Groesse (leer = alles passt)
    private func audit(_ env: HostedEnvironment, _ page: String, route: UFRoute?, marker: String?) -> [String] {
        if let route {
            // Einstellungen lesen den Reiter nur beim Erscheinen: ueber die Uebersicht neu oeffnen
            if case .settings = route { env.router.go(.dashboard); env.pump(0.3) }
            env.router.go(route)
        }
        var report: [String] = []
        for v in Self.variants {
            UserDefaults.standard.set(v.sidebar, forKey: "sidebar")
            env.hosting.traitOverrides.horizontalSizeClass = v.size.width < 700 ? .compact : .regular
            env.window.frame = CGRect(origin: .zero, size: v.size)
            env.view.frame = env.window.bounds
            env.pump(0.6)
            if let marker, !env.wait(timeout: 15, until: { Self.texts(env.view).contains { $0.contains(marker) } }) {
                report.append("\(page) @ \(v.name): „\(marker)“ erscheint nicht")
            }
            env.pump(0.6)
            let found = Self.overflows(in: env.window)
            shoot(env, "\(page)-\(v.name)", marks: found.map(\.rect))
            if !found.isEmpty {
                report.append("\(page) @ \(v.name) (\(Int(v.size.width)) x \(Int(v.size.height))): \(found.count) zu breit\n"
                              + found.prefix(30).map { "  " + $0.text }.joined(separator: "\n"))
            }
            // zum Ansehen auch die ganze Seite: dieselbe Breite, sehr hoch (die Breite bestimmt das Layout)
            if outDir != nil {
                env.window.frame = CGRect(origin: .zero, size: CGSize(width: v.size.width, height: 2800))
                env.view.frame = env.window.bounds
                env.pump(0.6)
                let tall = Self.overflows(in: env.window)
                shoot(env, "\(page)-\(v.name)-ganz", marks: tall.map(\.rect))
                if !tall.isEmpty {
                    report.append("\(page) @ \(v.name) ganz: \(tall.count) zu breit\n" + tall.prefix(30).map { "  " + $0.text }.joined(separator: "\n"))
                }
            }
        }
        UserDefaults.standard.set("full", forKey: "sidebar")
        return report
    }

    // MARK: - Pruefung

    struct Finding {
        let text: String
        let rect: CGRect
    }

    /// Alles Sichtbare, das rechts oder links ueber das Fenster ragt: UIViews, ihre Ebenen (SwiftUI zeichnet Text und
    /// Formen in Ebenen) und Bedienungshilfen-Elemente (mit Namen fuer den Bericht). Inhalt waagerecht scrollender
    /// Bereiche zaehlt nicht, Textfelder intern auch nicht (ihr Inhalt scrollt im Feld).
    static func overflows(in window: UIWindow) -> [Finding] {
        let width = window.bounds.width
        var out: [Finding] = []
        var seen = Set<String>()
        var scrollers: [CGRect] = []
        func bad(_ r: CGRect) -> Bool {
            r.width > 0.5 && r.height > 0.5 && !r.isInfinite && !r.isNull && (r.maxX > width + 1 || r.minX < -1)
        }
        func note(_ what: String, _ r: CGRect) {
            let key = "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
            guard seen.insert(key).inserted else { return }
            out.append(Finding(text: "\(what) x \(Int(r.minX))…\(Int(r.maxX)) y \(Int(r.minY)) h \(Int(r.height))", rect: r))
        }
        func name(_ v: UIView) -> String {
            var s = String(describing: type(of: v))
            if let id = v.accessibilityIdentifier, !id.isEmpty { s += " #\(id)" }
            return s
        }
        func visitLayer(_ l: CALayer, owner: String, exempt: Bool) {
            guard !l.isHidden, l.opacity > 0.01 else { return }
            let r = l.convert(l.bounds, to: window.layer)
            if !exempt && bad(r) { note("Ebene \(type(of: l)) in \(owner)", r) }
            for s in l.sublayers ?? [] where !(s.delegate is UIView) { visitLayer(s, owner: owner, exempt: exempt) }
        }
        func visit(_ v: UIView, exempt: Bool) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            let r = v.convert(v.bounds, to: window)
            if !exempt && bad(r) { note("View \(name(v))", r) }
            var inner = exempt
            if let s = v as? UIScrollView, s.contentSize.width > s.bounds.width + 1 || s.alwaysBounceHorizontal {
                inner = true
                if !exempt { scrollers.append(r) }
            }
            if v is UITextField || v is UITextView { inner = true }
            for s in v.layer.sublayers ?? [] where !(s.delegate is UIView) { visitLayer(s, owner: name(v), exempt: inner) }
            for s in v.subviews { visit(s, exempt: inner) }
        }
        visit(window, exempt: false)

        // Bedienungshilfen: Namen der zu breiten Elemente (ausser in waagerecht scrollenden Bereichen)
        for e in elements(in: window) {
            let r = e.accessibilityFrame
            guard bad(r) else { continue }
            let mid = r.midY
            if scrollers.contains(where: { mid >= $0.minY && mid <= $0.maxY && r.minX >= $0.minX - 1 }) { continue }
            note("Element „\((e.accessibilityLabel ?? e.accessibilityValue ?? "").prefix(60))“", r)
        }
        return out
    }

    static func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    static func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    // MARK: - Bilder

    /// Bild der Seite (hell, Massstab 2), zu breite Elemente rot umrandet und rechts ein roter Rand ueber dem Fenster
    private func shoot(_ env: HostedEnvironment, _ name: String, marks: [CGRect]) {
        guard let outDir else { return }
        let view = env.view
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { ctx in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            guard !marks.isEmpty else { return }
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.systemRed.cgColor)
            cg.setLineWidth(2)
            for r in marks { cg.stroke(r.intersection(view.bounds.insetBy(dx: 1, dy: 1))) }
            cg.setFillColor(UIColor.systemRed.withAlphaComponent(0.8).cgColor)
            cg.fill(CGRect(x: view.bounds.width - 4, y: 0, width: 4, height: view.bounds.height))
        }
        let file = outDir.appendingPathComponent(name + (marks.isEmpty ? "" : "-ZU-BREIT") + ".png")
        do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
    }
}
