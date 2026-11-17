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
        /// Groessenklassen; nil = wie bisher am iPad (Breite unter 700 pt kompakt, Hoehe regulaer)
        var horizontal: UIUserInterfaceSizeClass? = nil
        var vertical: UIUserInterfaceSizeClass = .regular
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

    /// iPhone-Fassung (docs/IPHONE-2026-11-04.md): iPhone 17e (390 x 844), iPhone 17 (402 x 874), iPhone 17 Pro Max
    /// (440 x 956) hoch, dazu iPhone 17 quer (874 x 402, Breite und Hoehe kompakt) als Rauchprobe
    static let iphone: [Variant] = [
        Variant(size: CGSize(width: 390, height: 844), name: "iphone-17e", sidebar: "full", horizontal: .compact),
        Variant(size: CGSize(width: 402, height: 874), name: "iphone-17", sidebar: "full", horizontal: .compact),
        Variant(size: CGSize(width: 440, height: 956), name: "iphone-17-pro-max", sidebar: "full", horizontal: .compact),
        Variant(size: CGSize(width: 874, height: 402), name: "iphone-17-quer", sidebar: "full", horizontal: .compact, vertical: .compact),
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

    /// Die Seiten des Lernkalenders gehoeren weiter zum Audit (er kommt wieder, Auftrag 17.11.2026): fuer sie gilt der
    /// Schalter an; alles andere laeuft mit dem ausgelieferten Standard (aus)
    private func withLearnCalendar<T>(_ body: () throws -> T) rethrows -> T {
        let before = LearnCalendar.enabled
        LearnCalendar.enabled = true
        defer { LearnCalendar.enabled = before }
        return try body()
    }

    private static func isPlan(_ r: UFRoute) -> Bool { if case .plan = r { return true }; return false }

    func testStudium() throws {
        let env = try host(MainView())
        var report: [String] = []
        report += audit(env, "uebersicht", route: .dashboard, marker: "Grundlagen der Informatik")
        report += audit(env, "nachrichten", route: .messages, marker: nil)
        report += withLearnCalendar { audit(env, "lernkalender", route: .plan(), marker: "Übungsblatt 1") }
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
        // Uni-Mail (05.11.2026, SOGo der LUH): nicht verbunden, Karte "Uni-Mail verbinden" (kein Netz)
        report += audit(env, "uni-mail", route: .uniMail, marker: "Uni-Mail verbinden")
        // Lehrende (06.11.2026, LUH/Stud.IP): ohne Abgleich leer mit Hinweis, Suchfeld
        report += audit(env, "lehrende", route: .lecturers, marker: "Lehrende und Tutor/innen deiner Kurse")
        // Bescheinigungen (06.11.2026): noch nicht gelesen, Hinweis "Liste aktualisieren" (kein Netz)
        report += audit(env, "bescheinigungen", route: .certificates, marker: "Liste aktualisieren")
        report += audit(env, "einstellungen-zugang", route: .settings(tab: "account"), marker: "Zugang & Darstellung")
        report += audit(env, "einstellungen-module", route: .settings(tab: "modules"), marker: "Grundlagen der Informatik")
        report += audit(env, "einstellungen-lernzeit", route: .settings(tab: "plan"), marker: "Lernzeit")
        report += audit(env, "einstellungen-erweitert", route: .settings(tab: "advanced"), marker: "Erweitert")
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    // MARK: - iPhone (docs/IPHONE-2026-11-04.md)

    /// Seiten von Teil A (Rahmen, Studium, Uni & Noten, Einstellungen) auf den drei iPhones hoch und quer
    func testIPhoneStudium() throws {
        let env = try host(MainView())
        var report: [String] = []
        let v = Self.iphone
        report += audit(env, "uebersicht", route: .dashboard, marker: "Grundlagen der Informatik", variants: v)
        report += audit(env, "nachrichten", route: .messages, marker: nil, variants: v)
        // iPhone hoch: Woche als 3 Tage ab heute, die Abgabe der Demo liegt spaeter
        report += withLearnCalendar {
            audit(env, "lernkalender", route: .plan(), marker: "Lernkalender", variants: v)
                + audit(env, "lernkalender-monat", route: .plan(view: "month"), marker: nil, variants: v)
                + audit(env, "lernkalender-liste", route: .plan(view: "list"), marker: nil, variants: v)
        }
        report += audit(env, "stundenplan", route: .timetable(), marker: "Grundlagen der Informatik", variants: v)
        report += audit(env, "module", route: .modules, marker: "Grundlagen der Informatik", variants: v)
        let api = container.api
        if let id = try pumping({ try await api.value("/api/modules").items.first?.i("id") }) {
            report += audit(env, "modul", route: .module(id), marker: "Grundlagen der Informatik", variants: v)
        } else {
            XCTFail("kein Demo-Modul")
        }
        report += audit(env, "studienverlauf", route: .studyPlan(), marker: nil, variants: v)
        report += audit(env, "uni-noten", route: .services, marker: "Mathematik für Ingenieurinnen", variants: v)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    func testIPhoneEinstellungen() throws {
        let env = try host(MainView())
        var report: [String] = []
        let v = Self.iphone
        report += audit(env, "einstellungen-zugang", route: .settings(tab: "account"), marker: "Zugang & Darstellung", variants: v)
        report += audit(env, "einstellungen-module", route: .settings(tab: "modules"), marker: "Grundlagen der Informatik", variants: v)
        report += audit(env, "einstellungen-lernzeit", route: .settings(tab: "plan"), marker: "Lernzeit", variants: v)
        report += audit(env, "einstellungen-erweitert", route: .settings(tab: "advanced"), marker: "Erweitert", variants: v)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Mensa (05.11.2026) auf den drei iPhones hoch und quer: Mensa-Wahl, Tage, Filterknopf, Gerichte in einer Spalte,
    /// Oeffnungszeiten darunter (erfundener Plan ohne Netz, `MensaDemoHTTP` unter XCTest)
    func testIPhoneMensa() throws {
        let env = try host(MainView())
        let report = audit(env, "mensa", route: .mensa, marker: "Öffnungszeiten", variants: Self.iphone)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Raumfinder und Uni-Mail (neu aus develop 05.11.2026) auf den drei iPhones hoch und quer: Suche und "Suchen" in
    /// voller Breite, Standorte mit Karten-Knoepfen untereinander; Uni-Mail nicht verbunden mit "Bei Uni-Mail anmelden"
    /// in voller Breite (kein Netz)
    func testIPhoneRaumfinderUndUniMail() throws {
        let env = try host(MainView())
        var report: [String] = []
        report += audit(env, "raumfinder", route: .rooms, marker: "Hauptgebäude (Welfengarten)", variants: Self.iphone)
        report += audit(env, "uni-mail", route: .uniMail, marker: "Uni-Mail verbinden", variants: Self.iphone)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Seiten von Teil C (Bibliothek, KI-Start, Tests, Karteikarten, Community): Befunde gehen an Teil C
    func testIPhoneLernenUndBibliothek() throws {
        let t = StoreScreenshotTests.Intercept(container.host)
        t.answer("/api/ai/tutor", StoreScreenshotTests.tutorAnswer)
        t.answer("/api/tests/18", StoreScreenshotTests.demoTest)
        let env = try host(MainView(), api: APIClient(base: APIClient.localBase, transport: t), ai: true)
        var report: [String] = []
        let v = Self.iphone
        report += audit(env, "dokumente", route: .files(), marker: nil, variants: v)
        report += audit(env, "dokumente-neu", route: .files(section: "new", path: nil, q: nil), marker: "Zahlensysteme", variants: v)
        report += audit(env, "regal", route: .files(section: "shelf", path: nil, q: nil), marker: "Mein Regal", variants: v)
        report += audit(env, "ki-start", route: .aiStart, marker: nil, variants: v)
        report += audit(env, "tests", route: .exams, marker: "Tests & Wiederholung", variants: v)
        report += audit(env, "test-ergebnis", route: .exam(18, task: nil), marker: "Hexadezimalsystem", variants: v)
        report += audit(env, "karteikarten", route: .cards, marker: "heute fällig", variants: v)
        report += audit(env, "community", route: .community, marker: "Deine Communities", variants: v)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Dokument am iPhone (Vorgabe 11.11.2026): Leseansicht ohne Editor, auf den drei iPhones ohne Ueberbreite
    func testIPhoneDokument() throws {
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        defer { UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault }
        let env = try host(MainView())
        let report = audit(env, "dokument", route: .doc("demo-skript"), marker: "Seite 1 von", variants: Self.iphone)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Am iPhone oeffnet ein Dokument die Leseansicht: kein Menue "Teilen"/"Abgeben" des Editors, keine Stiftpalette
    func testIPhoneDokumentOhneEditor() throws {
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        defer { UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault }
        let doc = try host(MainView())
        UFCompact.phoneOverride = true
        defer { UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault }
        doc.hosting.traitOverrides.horizontalSizeClass = .compact
        doc.hosting.traitOverrides.verticalSizeClass = .regular
        doc.window.frame = CGRect(origin: .zero, size: Self.iphone[1].size)
        doc.view.frame = doc.window.bounds
        doc.router.go(.doc("demo-skript"))
        XCTAssertTrue(doc.wait(timeout: 25) { Self.texts(doc.window).contains { $0.hasPrefix("Seite 1 von") } },
                      "Leseansicht fehlt: " + Self.texts(doc.window).joined(separator: " | "))
        XCTAssertFalse(Self.texts(doc.window).contains("Teilen"), "kein Editor-Menü am iPhone")
        XCTAssertTrue(Self.texts(doc.window).contains("KI-Hilfe"))
    }

    /// Einstellungen am iPhone (Vorgabe 11.11.2026): "Uni-Zugang" mit "überall gleich", Sync oben in der Kopfzeile, Tarif und
    /// StudiNow-Konto; ohne Stift- und Schreibhand-Zeilen (kein Editor)
    func testIPhoneEinstellungenUniZugangOhneStift() throws {
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        defer { UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault }
        let env = try host(MainView())
        UFCompact.phoneOverride = true
        defer { UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault }
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        env.window.frame = CGRect(origin: .zero, size: Self.iphone[1].size)
        env.view.frame = env.window.bounds
        env.router.go(.settings(tab: "account"))
        XCTAssertTrue(env.wait(timeout: 20) { Self.texts(env.window).contains(UniAutoLoginCard.title) },
                      "Uni-Zugang fehlt: " + Self.texts(env.window).joined(separator: " | "))
        // bis ans Ende scrollen, damit auch die unteren Karten gezeichnet sind
        func scrollViews(_ v: UIView) -> [UIScrollView] {
            let own: [UIScrollView] = (v as? UIScrollView).map { [$0] } ?? []
            return own + v.subviews.flatMap(scrollViews)
        }
        func all() -> [String] {
            var seen: [String] = []
            for _ in 0..<12 {
                seen += Self.texts(env.window)
                for sv in scrollViews(env.window) where sv.contentSize.height > sv.bounds.height + 1 {
                    sv.contentOffset.y = min(sv.contentOffset.y + sv.bounds.height * 0.8, sv.contentSize.height - sv.bounds.height)
                }
                env.pump(0.3)
            }
            return seen
        }
        let texts = all()
        XCTAssertTrue(texts.contains(UniAutoLoginCard.sameTitle), "Haken „überall gleich“")
        XCTAssertTrue(texts.contains("Abgleichen") || texts.contains("Abgleich läuft"), "Sync in der Kopfzeile")
        XCTAssertFalse(texts.contains("Schreibhand"), "keine Schreibhand am iPhone")
        XCTAssertFalse(texts.contains { $0.contains("Stift & Touch") || $0.contains("Nur Stift schreibt") }, "keine Stift-Zeile am iPhone")
    }

    /// Anmeldung und Hochschulwahl (vor der App-Huelle)
    func testIPhoneAnmeldung() throws {
        var report: [String] = []
        let welcome = try host(ZStack { UF.bg.ignoresSafeArea(); WelcomeView() })
        report += audit(welcome, "willkommen", route: nil, marker: nil, variants: Self.iphone)
        let picker = try host(ZStack { UF.bg.ignoresSafeArea(); UniversityPickerView { _ in } })
        report += audit(picker, "hochschule", route: nil, marker: "Hochschule wählen", variants: Self.iphone)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    func testIPhoneTarife() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        storeSession = session
        let env = try host(ZStack { UF.bg.ignoresSafeArea(); PlanPickerView(context: .settings, entitlements: Entitlements.shared) {} })
        let report = audit(env, "tarife", route: nil, marker: UFPlan.plus.name, variants: Self.iphone)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Bilder hell und dunkel der Seiten von Teil A im iPhone 17 (402 x 874), je Bildschirm und ganze Seite; nur mit
    /// UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR)
    func testIPhoneScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = try host(MainView())
        let api = container.api
        let moduleID = try pumping({ try await api.value("/api/modules").items.first?.i("id") })
        var pages: [(String, UFRoute)] = [
            ("01-uebersicht", .dashboard), ("02-nachrichten", .messages), ("03-lernkalender", .plan()),
            ("03b-lernkalender-monat", .plan(view: "month")), ("03c-lernkalender-liste", .plan(view: "list")),
            ("04-stundenplan", .timetable()), ("05-module", .modules),
            ("07-studienverlauf", .studyPlan()), ("08-uni-noten", .services),
            ("09-einstellungen-zugang", .settings(tab: "account")), ("09b-einstellungen-module", .settings(tab: "modules")),
            ("09c-einstellungen-lernzeit", .settings(tab: "plan")), ("09d-einstellungen-erweitert", .settings(tab: "advanced")),
        ]
        if let moduleID { pages.insert(("06-modul", .module(moduleID)), at: 7) }
        if !LearnCalendar.enabled { pages.removeAll { Self.isPlan($0.1) } }       // ausgeblendet: keine Bilder davon
        let size = Self.iphone[1].size
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        for (name, route) in pages {
            if case .settings = route { env.router.go(.dashboard); env.pump(0.3) }
            env.router.go(route)
            for (h, suffix) in [(size.height, ""), (1700, "-ganz")] {
                env.window.frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: h))
                env.view.frame = env.window.bounds
                env.pump(1.2)
                for (style, tone) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
                    env.window.overrideUserInterfaceStyle = style
                    env.pump(0.6)
                    write(env, to: dir.appendingPathComponent("\(name)\(suffix)-\(tone).png"))
                }
                env.window.overrideUserInterfaceStyle = .unspecified
            }
        }
        // "Mehr" (Blatt) und Suche als Vollbild: eigene Fenster, hier nur der Rahmen ohne sie
    }

    private func write(_ env: HostedEnvironment, to file: URL) {
        let view = env.view
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let data = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
    }

    /// Neu aus develop Build 10 (06.11.2026) auf den drei iPhones hoch und quer: Lehrende, Bescheinigungen (Seite und
    /// Karte unter Uni & Noten), Termin-Detail als Blatt von unten (halb/ganz). Demo-Daten, kein Netz.
    func testIPhoneBuild10() throws {
        let env = try host(MainView())
        var report: [String] = []
        let v = Self.iphone
        report += audit(env, "lehrende", route: .lecturers, marker: "Lehrende", variants: v)
        report += audit(env, "bescheinigungen", route: .certificates, marker: "Bescheinigungen", variants: v)
        report += audit(env, "uni-noten-bescheinigungen", route: .services, marker: "Bescheinigungen öffnen", variants: v)
        env.router.go(.timetable())
        env.pump(0.6)
        let api = container.api
        let ev = try pumping { try await api.value("/api/timetable/events").items.first { !($0.s("room") ?? "").isEmpty } }
        let e = try XCTUnwrap(ev, "kein Demo-Termin mit Raum")
        let id = try XCTUnwrap(e.i("id"))
        // iPhone: Blatt von unten (eigene Darstellung im Fenster, nicht in der Seite): Inhalt im Fenster pruefen
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.window.frame = CGRect(origin: .zero, size: v[1].size)
        env.view.frame = env.window.bounds
        env.pump(0.4)
        env.overlay.openDrawer(half: true) { EventDrawer(eventID: id, date: UFFmt.todayISO()) }
        XCTAssertTrue(env.wait(timeout: 15) { Self.texts(env.window).contains { $0.contains("Route zu Fuß starten") } },
                      "Termin-Detail als Blatt: \(Self.texts(env.window).prefix(30))")
        XCTAssertEqual(Set(env.hosting.presentedViewController?.sheetPresentationController?.detents.map(\.identifier) ?? []),
                       [.medium, .large], "Termin-Detail halb und ganz")
        report += audit(env, "termin-detail", route: nil, marker: nil, variants: Array(v.prefix(3)))
        env.overlay.closeDrawer()
        env.hosting.presentedViewController?.dismiss(animated: false)
        env.pump(0.4)
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Punkt 4 nach den Fotos vom 14.11.2026: jede iPhone-Seite auf 393 und 375 pt auf gequetschte Beschriftungen
    /// und leere obere Haelften durchsehen (`squeezed`). Der Breiten-Audit allein war grün, obwohl das Geraet
    /// „Math…“, „Le“, „Fr“ und eine halb leere Seite zeigte.
    func testIPhoneNichtsGequetscht() throws {
        let env = try host(MainView())
        UFCompact.phoneOverride = true
        defer { UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault }
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        var report: [String] = []
        let pages: [(String, UFRoute, String?)] = [
            ("uebersicht", .dashboard, "Grundlagen der Informatik"),
            ("lernkalender-woche", .plan(view: "week"), "Mein Fortschritt"),
            ("lernkalender-tag", .plan(view: "day"), nil),
            ("lernkalender-monat", .plan(view: "month"), nil),
            ("lernkalender-liste", .plan(view: "list"), nil),
            ("stundenplan", .timetable(), "Grundlagen der Informatik"),
            ("module", .modules, "Grundlagen der Informatik"),
            ("studienverlauf", .studyPlan(), nil),
            ("dokumente", .files(), nil),
            ("uni-noten", .services, nil),
            ("einstellungen-zugang", .settings(tab: "account"), nil),
            ("einstellungen-lernzeit", .settings(tab: "plan"), nil),
        ]
        let before = LearnCalendar.enabled
        defer { LearnCalendar.enabled = before }
        for (name, route, marker) in pages {
            LearnCalendar.enabled = Self.isPlan(route) || before                 // Lernkalender-Seiten mit Schalter an
            for width in [CGFloat(393), 375] {
                env.window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: width == 393 ? 852 : 812))
                env.view.frame = env.window.bounds
                if case .settings = route { env.router.go(.dashboard); env.pump(0.3) }
                env.router.go(route)
                if let marker {
                    _ = env.wait(timeout: 20) { Self.texts(env.view).contains { $0.contains(marker) } }
                }
                env.pump(1.0)
                let found = Self.squeezed(in: env.window)
                if !found.isEmpty {
                    report.append("\(name) @ \(Int(width)) pt: \(found.count)\n" + found.prefix(12).map { "  " + $0.text }.joined(separator: "\n"))
                }
            }
        }
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n\n"))
    }

    /// Lernkalender am iPhone (Fotos des Inhabers 14.11.2026): „Mein Fortschritt“, „Nicht erledigt“, „Schnell
    /// hinzufügen“ und der Monatskalender standen wie am iPad in zwei Spalten – „Math…“, „Le“, „Fr“, „Pe“ und
    /// „Novemb er 2026“ abgeschnitten, die Fortschrittskarte hoch und fast leer. Am iPhone gehören die Karten
    /// untereinander in voller Breite. Der Breiten-Audit war grün, weil nichts über den Rand ragte.
    func testIPhoneKalenderKartenUntereinander() throws {
        let learnCalendar = LearnCalendar.enabled                                // prueft den Lernkalender: Schalter an
        LearnCalendar.enabled = true
        defer { LearnCalendar.enabled = learnCalendar }
        let env = try host(MainView())
        UFCompact.phoneOverride = true
        defer { UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault }
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        env.hosting.traitOverrides.verticalSizeClass = .regular
        for width in [CGFloat(393), 375] {
            // hohes Fenster: alle Karten sind gezeichnet, ohne zu rollen
            env.window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 2400))
            env.view.frame = env.window.bounds
            env.router.go(.dashboard)
            env.pump(0.4)
            env.router.go(.plan())
            XCTAssertTrue(env.wait(timeout: 25) { Self.texts(env.view).contains("Mein Fortschritt") },
                          "Lernkalender @ \(Int(width)): \(Self.texts(env.view).prefix(25))")
            env.pump(1.0)
            func box(_ label: String) throws -> CGRect {
                let e = try XCTUnwrap(Self.elements(in: env.window).first { $0.accessibilityLabel == label },
                                      "„\(label)“ fehlt @ \(Int(width))")
                return e.accessibilityFrame
            }
            let cards = try ["Mein Fortschritt", "Nicht erledigt", "Schnell hinzufügen"].map { ($0, try box($0)) }
            for i in cards.indices {
                for j in cards.indices where j > i {
                    let a = cards[i].1, b = cards[j].1
                    XCTAssertFalse(a.minY < b.maxY && b.minY < a.maxY,
                                   "„\(cards[i].0)“ und „\(cards[j].0)“ stehen nebeneinander @ \(Int(width)) pt")
                }
            }
            // Knöpfe und Beschriftungen sind breit genug für ihren Text (vorher „Le“, „Fr“, „Pe“)
            for name in ["Lernpaket", "Freie Zeit", "Persönlich"] {
                XCTAssertGreaterThan(try box(name).width, 110, "„\(name)“ zu schmal @ \(Int(width)) pt")
            }
        }
    }

    /// Termin-Detail (06.11.2026): Termin aus dem Stundenplan antippen -> Panel mit Modul, Raum (Route zu Fuss) und Lehrenden
    func testTerminDetail() throws {
        let env = try host(MainView())
        env.router.go(.timetable())
        env.pump(0.6)
        let api = container.api
        let ev = try pumping { try await api.value("/api/timetable/events").items.first { !($0.s("room") ?? "").isEmpty } }
        let e = try XCTUnwrap(ev, "kein Demo-Termin mit Raum")
        let id = try XCTUnwrap(e.i("id"))
        env.overlay.openDrawer { EventDrawer(eventID: id, date: UFFmt.todayISO()) }
        // alle iPad-Groessen wie bis Build 32 (die iPhone-Fassung gibt es am iPad auch schmal nicht, 11.11.2026); auf
        // einem iPhone-Simulator laesst sich der schmale iPad-Split-View (590 pt, kompakt) nicht nachstellen - dort gilt
        // die iPhone-Fassung (Blatt von unten, `IPhoneTerminDetailTests`)
        let report = audit(env, "termin-detail", route: nil, marker: "Route zu Fuß starten",
                           variants: UFDevice.isPhone ? Self.variants.filter { $0.size.width >= 700 } : Self.variants)
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

    // MARK: - Hintergrundbild (Absturz 15.11.2026 auf iPad Air 4, iPadOS 18.7, Build 44, App im Hintergrund)

    /// Geht die App in den Hintergrund, macht iPadOS Bilder der Szene in mehreren Groessen (quer, hoch, schmal). Dabei
    /// stuerzte Build 44 am iPad Air (iPadOS 18.7.8) zweimal ab: `UINavigationBar layoutSubviews` unter
    /// `UIPanelController _updateToNewPublicState` (die geteilte Ansicht des Dokuments passt sich der neuen Groesse an).
    /// Der Test stellt den Groessenwechsel bei geoeffnetem Dokument und auf den uebrigen Seiten nach.
    ///
    /// Ursache (16.11.2026, `LibraryView.splitView`): Wurde das Fenster schmal, klappte die Teilung zu einem Stapel
    /// zusammen, dessen Navigationsleiste das Dokument ausblendet ("Oben fest"); beim naechsten breiten Fenster brach
    /// UIKit ab ("Layout requested for visible navigation bar … top item belongs to a different navigation bar").
    /// Seitdem klappt die Teilung am iPad nie zusammen.
    ///
    /// **Der Absturz tritt nur mit iPadOS 18 und 26 auf, nicht mit 27.** Mit iPadOS 27 besteht der Groessenwechsel auch
    /// ohne die Behebung; dort wacht dieser Test darueber, dass die Teilung nicht zusammenklappt, die Dokumentliste
    /// nicht ueber dem Dokument liegt und der Editor nicht neu entsteht. Der Absturz selbst ist am 16.11.2026 auf einem
    /// Simulator mit iPadOS 26.2 geprueft (vorher Absturz beim vierten Schritt, auch mit dem Stand von Version 1.0.4;
    /// nachher gruen). Bei Aenderungen an `LibraryView.splitView` dort erneut laufen lassen:
    /// `xcrun simctl create "Absturz 26" com.apple.CoreSimulator.SimDeviceType.iPad-Air-5th-generation
    /// com.apple.CoreSimulator.SimRuntime.iOS-26-2`, dann diesen Test mit `-destination "id=…"`. iPadOS 18 gibt es hier
    /// nicht als Simulator: am echten iPad von Hand pruefen (Dokument oeffnen, App mehrmals in den Hintergrund und
    /// zurueck, Split View auf ein Drittel und wieder breit).
    func testGroessenwechselWieBeimHintergrundbild() throws {
        // nur iPad: am iPhone klappt die Teilung mit Absicht zum Stapel zusammen (dort unveraendert)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "nur iPad")
        let env = try host(MainView())
        UserDefaults.standard.set("full", forKey: "sidebar")
        defer { UserDefaults.standard.removeObject(forKey: EditorToolbarPlacement.key) }
        let sizes: [(CGSize, UIUserInterfaceSizeClass)] = [
            (CGSize(width: 1180, height: 820), .regular), (CGSize(width: 820, height: 1180), .regular),
            (CGSize(width: 375, height: 820), .compact), (CGSize(width: 1180, height: 820), .regular),
            (CGSize(width: 320, height: 1180), .compact), (CGSize(width: 820, height: 1180), .regular),
            (CGSize(width: 590, height: 820), .compact), (CGSize(width: 1180, height: 820), .regular)]
        // Dokument: "Oben fest" blendet die Navigationsleiste aus (dort der Absturz); "Unten fest" zeigt sie (dort lag
        // nach schmal -> breit die Dokumentliste ueber dem Dokument)
        let documents: [(String, EditorToolbarPlacement)] = [("demo-skript", .top), ("demo-blatt", .top), ("demo-skript", .bottom)]
        for (id, placement) in documents {
            let what = "\(id), Leiste \(placement.rawValue)"
            UserDefaults.standard.set(placement.rawValue, forKey: EditorToolbarPlacement.key)
            env.router.go(.dashboard)
            env.pump(0.3)
            env.router.go(.doc(id))
            XCTAssertTrue(env.wait(timeout: 25) { !Self.editors(env).isEmpty }, "Editor fehlt (\(what))")
            env.pump(1.5)
            let before = Self.editors(env)
            for (size, h) in sizes {
                Self.resize(env, size, h)
                let step = "\(what), \(Int(size.width)) x \(Int(size.height))"
                let split = try XCTUnwrap(Self.splitController(env), "geteilte Ansicht fehlt (\(step))")
                XCTAssertFalse(split.isCollapsed, "Teilung zusammengeklappt (\(step)): danach stuerzt iPadOS 18/26 ab")
                XCTAssertEqual(split.displayMode, .secondaryOnly, "Dokumentliste liegt ueber dem Dokument (\(step))")
                XCTAssertEqual(split.viewControllers.count, 3, "Modul- und Dokumentliste gehoeren weiter zur Teilung (\(step))")
                XCTAssertTrue(split.presentsWithGesture, "Listen lassen sich weiter vom linken Rand hereinziehen (\(step))")
                XCTAssertEqual(Self.editors(env), before, "Editor beim Groessenwechsel neu aufgebaut (\(step))")
            }
        }
        UserDefaults.standard.removeObject(forKey: EditorToolbarPlacement.key)
        // uebrige Seiten (ohne geteilte Ansicht): nichts stuerzt ab
        for route in [UFRoute.dashboard, .files(), .modules, .plan(), .timetable(), .aiStart, .settings(tab: "account")] {
            env.router.go(route)
            env.pump(2)
            for (size, h) in sizes { Self.resize(env, size, h) }
        }
        env.hosting.traitOverrides.horizontalSizeClass = .regular
        XCTAssertNotNil(env.window.rootViewController)
    }

    /// Dokument in einem schmalen Fenster geoeffnet (Slide Over, Split View ein Drittel, kleines Fenster in iPadOS 26),
    /// dann breit und wieder schmal: die Teilung entsteht gleich breit und bleibt es, das Dokument steht da (nicht die
    /// Dokumentliste), der Editor bleibt derselbe. Die Dokumentliste mit Suchfeld und "PDF importieren" laesst sich
    /// weiter hereinholen und wieder schliessen.
    func testDokumentImSchmalenFensterDannBreit() throws {
        // nur iPad: am iPhone klappt die Teilung mit Absicht zum Stapel zusammen (dort unveraendert)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "nur iPad")
        let env = try host(MainView())
        Self.resize(env, CGSize(width: 375, height: 820), .compact)
        env.router.go(.doc("demo-skript"))
        XCTAssertTrue(env.wait(timeout: 25) { !Self.editors(env).isEmpty }, "Editor fehlt im schmalen Fenster")
        env.pump(1.5)
        let before = Self.editors(env)
        let sizes: [(CGSize, UIUserInterfaceSizeClass)] = [
            (CGSize(width: 375, height: 820), .compact), (CGSize(width: 1180, height: 820), .regular),
            (CGSize(width: 320, height: 1180), .compact), (CGSize(width: 1180, height: 820), .regular)]
        for (size, h) in sizes {
            Self.resize(env, size, h)
            let split = try XCTUnwrap(Self.splitController(env))
            XCTAssertFalse(split.isCollapsed, "Teilung zusammengeklappt bei \(Int(size.width)) pt")
            XCTAssertEqual(split.displayMode, .secondaryOnly, "Dokumentliste liegt ueber dem Dokument bei \(Int(size.width)) pt")
            XCTAssertEqual(Self.editors(env), before, "Editor neu aufgebaut bei \(Int(size.width)) pt")
            // nur die Teilung selbst gilt als breit: ihr Inhalt sieht weiter die echte Breitenklasse des Fensters
            let editor = Self.controllers(env.hosting).first { $0 is PDFEditorController }
            XCTAssertEqual(editor?.traitCollection.horizontalSizeClass, h, "Breitenklasse im Dokument bei \(Int(size.width)) pt")
        }
        // wie das Wischen vom linken Rand: Dokumentliste ueber dem Dokument, danach wieder weg
        let split = try XCTUnwrap(Self.splitController(env))
        split.show(.supplementary)
        XCTAssertTrue(env.wait(timeout: 10) { Self.texts(env.window).contains { $0.contains("Dokumente suchen") } },
                      "Dokumentliste mit Suchfeld fehlt: " + Self.texts(env.window).joined(separator: " | "))
        XCTAssertTrue(Self.texts(env.window).contains { $0.contains("PDF importieren") }, "Knopf „PDF importieren“ fehlt")
        XCTAssertEqual(Self.editors(env), before, "Editor neu aufgebaut, als die Dokumentliste erschien")
        split.hide(.supplementary)
        XCTAssertTrue(env.wait(timeout: 10) { split.displayMode == .secondaryOnly }, "Dokumentliste schliesst nicht")
        XCTAssertEqual(Self.editors(env), before)
        env.hosting.traitOverrides.horizontalSizeClass = .regular
    }

    /// Eingrenzung des Absturzes: Ein Stapel allein (`NavigationStack` wie in den Blaettern der App, mit Suchfeld,
    /// Knopf in der Leiste und einer zweiten Seite, die die Navigationsleiste ausblendet) uebersteht dieselben
    /// Groessenwechsel auch mit iPadOS 26. Betroffen war nur die geteilte Ansicht des Dokuments
    /// (`NavigationSplitView`, die einzige der App), weil nur sie Seiten zwischen zwei Navigationsleisten umhaengt.
    func testGroessenwechselImStapelMitSuchfeld() throws {
        // nur iPad: am iPhone klappt die Teilung mit Absicht zum Stapel zusammen (dort unveraendert)
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "nur iPad")
        struct Stapel: View {
            @State var query = ""
            @State var path: [Int]
            var body: some View {
                NavigationStack(path: $path) {
                    List(0..<20, id: \.self) { Text("Zeile \($0)") }
                        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Suchen")
                        .navigationTitle("Liste")
                        .toolbar { Button("Fertig") {} }
                        .navigationDestination(for: Int.self) { n in
                            Text("Seite \(n)").toolbar(.hidden, for: .navigationBar)
                        }
                }
            }
        }
        let sizes: [(CGSize, UIUserInterfaceSizeClass)] = [
            (CGSize(width: 1180, height: 820), .regular), (CGSize(width: 375, height: 820), .compact),
            (CGSize(width: 1180, height: 820), .regular), (CGSize(width: 320, height: 1180), .compact),
            (CGSize(width: 820, height: 1180), .regular)]
        for path in [[], [1]] {
            let env = try hostWithEnvironment(Stapel(path: path), size: sizes[0].0)
            env.pump(0.5)
            for (size, h) in sizes { Self.resize(env, size, h) }
            XCTAssertTrue(Self.texts(env.window).contains { $0.contains(path.isEmpty ? "Zeile 0" : "Seite 1") },
                          Self.texts(env.window).joined(separator: " | "))
            env.window.isHidden = true
        }
    }

    /// Fenster in neuer Groesse und Breitenklasse, sofort gelegt (wie `layoutBelowIfNeeded` im Absturz-Stapel)
    private static func resize(_ env: HostedEnvironment, _ size: CGSize, _ horizontal: UIUserInterfaceSizeClass) {
        env.hosting.traitOverrides.horizontalSizeClass = horizontal
        env.window.frame = CGRect(origin: .zero, size: size)
        env.view.frame = env.window.bounds
        env.window.layoutIfNeeded()
        env.pump(0.3)
    }

    private static func controllers(_ vc: UIViewController) -> [UIViewController] {
        [vc] + vc.children.flatMap { controllers($0) }
    }

    /// Geteilte Ansicht des Dokuments (`NavigationSplitView` in `LibraryView`)
    private static func splitController(_ env: HostedEnvironment) -> UISplitViewController? {
        controllers(env.hosting).lazy.compactMap { $0 as? UISplitViewController }.first
    }

    /// Die Editoren im Fenster (dieselben Objekte = nichts wurde neu aufgebaut: Scroll-Stelle und Striche bleiben)
    private static func editors(_ env: HostedEnvironment) -> [ObjectIdentifier] {
        controllers(env.hosting).compactMap { $0 as? PDFEditorController }.map(ObjectIdentifier.init)
    }

    // MARK: - Hosten

    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufAIEnabled, ai)
            .environment(\.qis, qis)
            .environment(\.uniMail, manager.uniMail)
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
        // Zeitueberschreitung ist ein Fehler, kein Ueberspringen (Audit P48, 08.11.2026: ein Haenger blieb sonst gruen)
        guard let result else { XCTFail("Zeitueberschreitung"); throw CancellationError() }
        return try result.get()
    }

    /// Seite in allen Groessen pruefen; Rueckgabe: Befunde je Groesse (leer = alles passt)
    private func audit(_ env: HostedEnvironment, _ page: String, route: UFRoute?, marker: String?,
                       variants: [Variant] = LayoutWidthAuditTests.variants) -> [String] {
        if let route {
            // Einstellungen lesen den Reiter nur beim Erscheinen: ueber die Uebersicht neu oeffnen
            if case .settings = route { env.router.go(.dashboard); env.pump(0.3) }
            env.router.go(route)
        }
        var report: [String] = []
        for v in variants {
            UserDefaults.standard.set(v.sidebar, forKey: "sidebar")
            env.hosting.traitOverrides.horizontalSizeClass = v.horizontal ?? (v.size.width < 700 ? .compact : .regular)
            env.hosting.traitOverrides.verticalSizeClass = v.vertical
            env.window.frame = CGRect(origin: .zero, size: v.size)
            env.view.frame = env.window.bounds
            env.pump(0.6)
            if let marker, !env.wait(timeout: 15, until: { Self.texts(env.view).contains { $0.contains(marker) } }),
               !Self.scrolledInto(env, marker) {
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

    /// Merkmal unterhalb des sichtbaren Bereichs (iPhone quer: wenig Hoehe, Listen legen Zeilen erst im Bild an): die
    /// senkrechten Rollbereiche schrittweise nach unten rollen, bis es erscheint; danach wieder nach oben
    static func scrolledInto(_ env: HostedEnvironment, _ marker: String) -> Bool {
        func scrollers(_ v: UIView) -> [UIScrollView] {
            var out: [UIScrollView] = []
            if let s = v as? UIScrollView, !v.isHidden, s.contentSize.height > s.bounds.height + 1, s.contentSize.width <= s.bounds.width + 1 { out.append(s) }
            for c in v.subviews where !c.isHidden { out += scrollers(c) }
            return out
        }
        let list = scrollers(env.view)
        defer {
            for s in list { s.setContentOffset(CGPoint(x: s.contentOffset.x, y: -s.adjustedContentInset.top), animated: false) }
            env.pump(0.3)
        }
        for _ in 0..<8 {
            for s in list {
                let maxY = s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom
                s.setContentOffset(CGPoint(x: s.contentOffset.x, y: min(maxY, s.contentOffset.y + s.bounds.height * 0.7)), animated: false)
            }
            env.pump(0.4)
            if texts(env.view).contains(where: { $0.contains(marker) }) { return true }
        }
        return false
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
        // Sichtbar ist nur, was innerhalb aller beschneidenden Vorfahren liegt (clipsToBounds/masksToBounds): PDFKit legt
        // seine Kacheln im 512er-Raster an, die letzte Spalte reicht ueber die Seite hinaus, wird aber vom Rollbereich
        // beschnitten (iPhone-Dokument, 05.11.2026)
        func clipped(_ r: CGRect, _ clip: CGRect) -> CGRect { r.intersection(clip).isNull ? .zero : r.intersection(clip) }
        func visitLayer(_ l: CALayer, owner: String, exempt: Bool, clip: CGRect) {
            guard !l.isHidden, l.opacity > 0.01 else { return }
            let full = l.convert(l.bounds, to: window.layer)
            let r = clipped(full, clip)
            if !exempt && bad(r) { note("Ebene \(type(of: l)) in \(owner)", r) }
            let inner = l.masksToBounds ? r : clip
            for s in l.sublayers ?? [] where !(s.delegate is UIView) { visitLayer(s, owner: owner, exempt: exempt, clip: inner) }
        }
        func visit(_ v: UIView, exempt: Bool, clip: CGRect = .infinite) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            // Abdunkelung hinter einem Blatt (System): reicht absichtlich ueber den Bildschirm hinaus
            if String(describing: type(of: v)) == "UIDimmingView" { return }
            // Schattenrand um ein Blatt auf dem Mac ("Designed for iPad", Systemrahmen): 54 pt breiter als das Fenster
            // (Befund 14.11.2026, alle iPhone-Blatt-Tests "1 zu breit"); am iPad und iPhone gibt es die Ansicht nicht
            if String(describing: type(of: v)) == "UIDropShadowRimPartView" { return }
            let full = v.convert(v.bounds, to: window)
            let r = clipped(full, clip)
            if !exempt && bad(r) { note("View \(name(v))", r) }
            let innerClip = v.clipsToBounds ? r : clip
            var inner = exempt
            if let s = v as? UIScrollView, s.contentSize.width > s.bounds.width + 1 || s.alwaysBounceHorizontal {
                inner = true
                // ganzer Rahmen, nicht der beschnittene: Elemente der Reihe unterhalb des sichtbaren Bereichs (senkrecht
                // weggescrollt, z. B. Stundenplan-Spalten, Modul-Reiter quer) bleiben Inhalt des waagerechten Bereichs
                if !exempt { scrollers.append(full) }
            }
            if v is UITextField || v is UITextView { inner = true }
            for s in v.layer.sublayers ?? [] where !(s.delegate is UIView) { visitLayer(s, owner: name(v), exempt: inner, clip: innerClip) }
            for s in v.subviews { visit(s, exempt: inner, clip: innerClip) }
        }
        visit(window, exempt: false)

        // Bedienungshilfen: Namen der zu breiten Elemente (ausser in waagerecht scrollenden Bereichen)
        for e in elements(in: window) {
            if String(describing: type(of: e)) == "UIDimmingView" { continue }     // "Einblendmenü schließen" hinter Blaettern
            let r = e.accessibilityFrame
            guard bad(r) else { continue }
            let mid = r.midY
            if scrollers.contains(where: { mid >= $0.minY && mid <= $0.maxY && r.minX >= $0.minX - 1 }) { continue }
            note("Element „\((e.accessibilityLabel ?? e.accessibilityValue ?? "").prefix(60))“", r)
        }
        return out
    }

    /// Zweiter Blick nach den Fotos des Inhabers vom 14.11.2026: nicht nur „ragt heraus“, sondern „ist gequetscht“.
    /// (a) Eine einzeilige Beschriftung, die in ihrer Flaeche nicht ganz Platz hat („Math…“, „Le“, „Fr“, „Pe“).
    /// (b) Eine Seite, deren erster Inhalt erst weit unten beginnt (obere Haelfte leer, Einstieg 14.11.2026).
    /// Die Schriftgroesse wird aus der Hoehe der Zeile geschaetzt; der Schwellenwert ist bewusst grosszuegig,
    /// damit nur wirklich abgeschnittene Beschriftungen auffallen.
    static func squeezed(in window: UIWindow) -> [Finding] {
        var out: [Finding] = []
        var first = CGFloat.greatestFiniteMagnitude
        for e in elements(in: window) {
            let r = e.accessibilityFrame
            guard r.width > 2, r.height > 2, !r.isNull, !r.isInfinite, r.maxY > 0, r.minY > -1 else { continue }
            first = min(first, r.minY)
            guard e.accessibilityTraits.contains(.staticText), !e.accessibilityTraits.contains(.button) else { continue }
            guard let label = e.accessibilityLabel, label.count >= 3, !label.contains("\n") else { continue }
            guard r.height >= 11, r.height <= 30 else { continue }                     // nur einzeilige Beschriftungen
            // "Bereich laut Notenspiegel: Pflichtmodule, 2,3, 35 LP": vor dem Doppelpunkt steht die Erklaerung fuer
            // VoiceOver, auf dem Bildschirm steht nur der Teil danach - nur der muss passen
            let shown = label.range(of: ": ").map { String(label[$0.upperBound...]) } ?? label
            // die Hoehe enthaelt auch den Innenabstand (Kapseln, Knoepfe): vorsichtig schaetzen, lieber einen
            // Befund zu wenig als falsche Treffer
            let size = min(17, max(9, r.height / 1.75))
            let need = (shown as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold)]).width
            if need > r.width * 1.3 + 14 {
                out.append(Finding(text: "abgeschnitten „\(shown.prefix(40))“ (\(Int(r.width)) pt breit, braucht rund \(Int(need)) pt)", rect: r))
            }
        }
        if first < .greatestFiniteMagnitude, first > window.bounds.height * 0.3 {
            out.append(Finding(text: "obere Haelfte leer: der erste Inhalt beginnt erst bei y \(Int(first)) von \(Int(window.bounds.height))",
                               rect: CGRect(x: 0, y: 0, width: window.bounds.width, height: first)))
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
