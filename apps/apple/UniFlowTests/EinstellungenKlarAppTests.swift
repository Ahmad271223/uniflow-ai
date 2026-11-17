import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Uebersichtlichere Einstellungen (Auftrag des Inhabers 17.11.2026 "mach Einstellungen übersichtlicher", dazu "ganzen
/// Änderungen auf iPhone-App auch umsetzen und macOS"): Bereiche statt eines langen Reiters, Sprungziele mit Rueckfall,
/// nichts geht verloren, Lernkalender-Einstellungen nur mit `LearnCalendar.enabled`, schmal eine Liste mit Unterseiten.
/// Echte Huelle (`MainView`) mit den Demo-Inhalten, ohne Netz.
@MainActor
final class EinstellungenKlarAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    private var background: BackgroundSyncController!
    private var oldSidebar: String?

    static let wide = CGSize(width: 1210, height: 834)
    static let phone = CGSize(width: 402, height: 874)

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "einstellungen-klar", clock: .system)
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
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: StoreScreenshotTests.EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        background = BackgroundSyncController(containers: manager, account: account, settings: BackgroundSyncSettings(defaults: bed.defaults))
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        UserDefaults.standard.set("full", forKey: "sidebar")
    }

    override func tearDown() async throws {
        LearnCalendar.enabled = false
        HostedEnvironment.accessibilityAutomation(false)
        UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Bereiche und Sprungziele (reine Regeln)

    func testBereicheInDerReihenfolgeDesAlltags() {
        XCTAssertEqual(SettingsArea.visible(hasData: true, learnCalendar: false).map(\.rawValue),
                       ["account", "uni", "look", "modules", "community", "help", "advanced"], "Häufiges oben, Erweitert zuletzt, kein Lernzeit-Bereich")
        XCTAssertEqual(SettingsArea.visible(hasData: true, learnCalendar: true).map(\.rawValue),
                       ["account", "uni", "look", "modules", "plan", "community", "help", "advanced"])
        XCTAssertEqual(SettingsArea.visible(hasData: false, learnCalendar: true).map(\.rawValue),
                       ["account", "uni", "look", "community", "help", "advanced"], "ohne geladene Daten keine Module und keine Lernzeit")
        XCTAssertFalse(LearnCalendar.enabled, "Standard: Lernkalender aus")
        XCTAssertEqual(SettingsArea.visible(hasData: true), SettingsArea.visible(hasData: true, learnCalendar: false))
        // Namen: am iPhone ohne Stift, am Mac ohne das Wort Stift
        XCTAssertEqual(SettingsArea.look.title(editor: true, mac: false), "Darstellung & Stift")
        XCTAssertEqual(SettingsArea.look.title(editor: false, mac: false), "Darstellung")
        XCTAssertEqual(SettingsArea.look.title(editor: true, mac: true), "Darstellung & Schreiben")
        XCTAssertFalse(SettingsArea.look.sub(editor: true, mac: true).contains("Stift"))
        XCTAssertEqual(SettingsArea.modules.title(editor: true, withTests: true), "Module & Wochentests")
        for area in SettingsArea.allCases {
            XCTAssertFalse(area.title(editor: true).isEmpty)
            XCTAssertTrue(area.sub(editor: true).hasSuffix("."), "\(area): ein kurzer Satz")
            XCTAssertTrue(UFIconNames.all.contains(area.icon), "\(area): Icon \(area.icon) fehlt")
        }
    }

    /// `UFRoute.settings(tab:)`: die frueheren Reiter bleiben gueltig; unbekannt oder ausgeblendet = Startseite (nil)
    func testSprungzieleUndRueckfall() {
        let off = SettingsArea.visible(hasData: true, learnCalendar: false)
        let on = SettingsArea.visible(hasData: true, learnCalendar: true)
        func r(_ tab: String?, _ visible: [SettingsArea], ownServer: Bool = true) -> SettingsArea? {
            SettingsArea.resolve(tab, visible: visible, ownServer: ownServer)
        }
        XCTAssertEqual(r("account", off), .account)
        XCTAssertEqual(r("modules", off), .modules)
        XCTAssertEqual(r("advanced", off), .advanced)
        XCTAssertEqual(r("dev", off), .advanced, "eigener Server steht unter Erweitert")
        XCTAssertNil(r("dev", off, ownServer: false), "im Release-Build gibt es ihn nicht: Startseite")
        XCTAssertEqual(r("diag", off), .advanced, "Diagnose steht unter Erweitert")
        XCTAssertEqual(r("diag", off, ownServer: false), .advanced)
        XCTAssertNil(r("plan", off), "ohne Lernkalender ausgeblendet: Startseite")
        XCTAssertEqual(r("plan", on), .plan)
        XCTAssertNil(r("gibt-es-nicht", on), "unbekannt: Startseite")
        XCTAssertNil(r("", on))
        XCTAssertNil(r(nil, on))
        XCTAssertNil(r("modules", SettingsArea.visible(hasData: false, learnCalendar: true)), "noch nicht geladen")
        for area in SettingsArea.allCases { XCTAssertEqual(r(area.rawValue, on), area) }
        // die Stellen der App, die in die Einstellungen springen (Stand 17.11.2026)
        for tab in ["account", "modules", "advanced", ChatGPTLink.settingsTab] { XCTAssertNotNil(r(tab, off, ownServer: false), tab) }
        XCTAssertEqual(UFRoute(hash: "#/settings?tab=uni"), .settings(tab: "uni"))
    }

    func testEinladungstextNenntDenLernkalenderNurMitSchalter() {
        XCTAssertFalse(InviteTexts.shareText(learnCalendar: false).contains("Lernkalender"))
        XCTAssertTrue(InviteTexts.shareText(learnCalendar: false).contains("Skripte und Stundenplan"))
        XCTAssertTrue(InviteTexts.shareText(learnCalendar: true).contains("Skripte, Stundenplan und Lernkalender"))
        XCTAssertEqual(InviteTexts.shareText, InviteTexts.shareText(learnCalendar: false), "Standard: Schalter aus")
        LearnCalendar.enabled = true
        XCTAssertEqual(InviteTexts.shareText, InviteTexts.shareText(learnCalendar: true))
        LearnCalendar.enabled = false
        XCTAssertTrue(InviteTexts.shareText.hasSuffix("Hier ist meine Einladung:"))
    }

    /// Die Kurzfassungen sind der Anfang des ganzen Textes (nichts Neues behauptet)
    func testKurzfassungenSindDerAnfangDesTextes() {
        XCTAssertTrue(BackgroundSyncCard.timingText.hasPrefix(BackgroundSyncCard.timingShort))
        XCTAssertTrue(BackgroundSyncCard.newsText.hasPrefix(BackgroundSyncCard.newsShort))
        XCTAssertTrue(BackgroundSyncCard.reloginText.hasPrefix(BackgroundSyncCard.reloginShort))
        for u in [UniversityKey.luh, .hildesheim, .hsh] {
            let short = BackgroundSyncCard.notifyShort(u)
            XCTAssertTrue(BackgroundSyncCard.notifyText(u).hasPrefix(short), short)
            XCTAssertTrue(short.hasSuffix("“)."), short)
        }
        XCTAssertTrue(StudoraAccountCard.fallback.hasPrefix(StudoraAccountCard.fallbackShort))
    }

    // MARK: - Nichts geht verloren (iPad quer / Mac breit)

    /// Jede fruehere Einstellung steht in genau dem Bereich, in den sie gehoert: Kennungen und Beschriftungen der
    /// frueheren Seiten "Zugang & Darstellung", "Module", "Erweitert" und "Entwicklung"
    func testJedeFruehereEinstellungIstErreichbar() throws {
        let env = try host(size: Self.wide)
        let pointer = EditorPointer.settingsTitle(isMac: PDFEditorController.isMac)
        var expected: [(tab: String, ids: [String], texts: [String])] = [
            ("account", ["settings.rufname", "settings.area.account"],
             ["Konto & Tarif", "Tarif", "Tarif wechseln", "Konto", "Rufname", "Konto löschen"]),
            ("uni", ["settings.unilogin.same", "luh.settings.studip", "background.enabled", "background.notify", "background.relogin",
                     "background.news.grades", "background.last",
                     // "Hochschule wechseln" bzw. der Hinweis, wenn der Build nur eine Hochschule anbietet
                     UniversitySettingsCard.offersSwitch(current: .luh) ? "settings.university.switch" : "settings.university.more"],
             // Erinnerungen: der Schalter (ab Plus) oder die Sperrkarte, beide beginnen so
             [UniAutoLoginCard.title, "Stud.IP & QIS", "Uni-Kalender", "Im Hintergrund abgleichen", "Semester", "Erinnerungen an Abgaben",
              "Hochschule", "Daten dieser Hochschule löschen"]),
            // "Glättung" gibt es nur, solange sie etwas bewirkt (seit 17.11.2026 aus: kostete Striche, `PencilTuning`)
            ("look", (PencilTuning.rebuildFromRawPointsAfterLift ? ["settings.pencilSmoothing"] : []) + ["settings.shapeSnap", "settings.toolbarPlacement"],
             ["Darstellung", "Hell", "Dunkel", pointer, "Schreibhand", EditorToolbarPlacementRow.title]),
            ("modules", [], ["Modul anlegen", "Zuordnung automatisch prüfen", "Grundlagen der Informatik"]),
            ("community", [], ["Community"]),
            ("help", [], ["Rechtliches & Support", "Support", "E-Mail schreiben", "Nutzungsbedingungen", "Datenschutzerklärung", "Impressum"]),
            ("advanced", ["docIndex.prewarmLevel"], ["Vorab einordnen"]),
        ]
        if StudoraAccountLink.available { expected[0].texts += ["StudiNow-Konto", InviteTexts.title] }
        if Session.ownServerAvailable { expected[6].ids.append("settings.fold.dev") }
        for e in expected {
            open(env, e.tab, height: 4200)
            let ids = self.ids(env)
            for id in e.ids {
                XCTAssertTrue(env.wait(timeout: 12) { self.ids(env).contains(id) }, "\(e.tab): Kennung \(id) fehlt\n\(ids.sorted())")
            }
            for t in e.texts {
                XCTAssertTrue(env.wait(timeout: 12) { self.shows(env, t) }, "\(e.tab): „\(t)“ fehlt\n" + texts(env).joined(separator: "\n"))
            }
            XCTAssertTrue(self.ids(env).contains("settings.area.\(e.tab)"), "\(e.tab): Liste der Bereiche links")
            XCTAssertFalse(self.ids(env).contains("settings.back"), "breit: keine Unterseite")
        }
        // der eigene Server (frueher Reiter "Entwicklung"): zugeklappt, Antippen zeigt die Karte
        if Session.ownServerAvailable {
            open(env, "advanced", height: 2000)
            XCTAssertFalse(shows(env, "Mit eigenem StudiNow-Server verbinden"), "zugeklappt")
            XCTAssertTrue(tap(id: "settings.fold.dev", env))
            XCTAssertTrue(env.wait { self.shows(env, "Mit eigenem StudiNow-Server verbinden") }, texts(env).joined(separator: "\n"))
            // Sprungziel "dev": gleich aufgeklappt
            open(env, "dev", height: 2000)
            XCTAssertTrue(env.wait { self.shows(env, "Mit eigenem StudiNow-Server verbinden") }, "dev klappt den eigenen Server auf")
        }
        // Alltag ohne Entwickler-Dinge: kein "Entwicklung" in der Liste der Bereiche
        open(env, "account", height: 2000)
        XCTAssertFalse(texts(env).contains("Entwicklung"), "kein eigener Reiter Entwicklung mehr")
        XCTAssertFalse(shows(env, "Zugang & Darstellung"))
    }

    /// Lange Erklaerungen stehen hinter "Mehr dazu": zu der erste Satz, offen der ganze Text mit seiner Kennung
    func testMehrDazuZeigtDenGanzenText() throws {
        let env = try host(size: Self.wide)
        open(env, "uni", height: 4200)
        XCTAssertTrue(env.wait(timeout: 12) { self.shows(env, BackgroundSyncCard.timingShort) }, texts(env).joined(separator: "\n"))
        XCTAssertFalse(texts(env).contains(BackgroundSyncCard.timingText), "zu: nur der erste Satz")
        XCTAssertFalse(ids(env).contains("background.timing"))
        let more = LockVisibilityAppTests.all(in: env.window).filter { $0.accessibilityLabel == SettingsMore.openTitle && $0.accessibilityTraits.contains(.button) }
        XCTAssertGreaterThanOrEqual(more.count, 4, "Zeiten, Benachrichtigen, Mitteilungen, neu anmelden")
        for m in more { XCTAssertTrue(m.accessibilityActivate()) }
        XCTAssertTrue(env.wait { self.texts(env).contains(BackgroundSyncCard.timingText) }, "offen: der ganze Text")
        XCTAssertTrue(texts(env).contains(BackgroundSyncCard.newsText))
        XCTAssertTrue(texts(env).contains(BackgroundSyncCard.reloginText))
        XCTAssertTrue(texts(env).contains(BackgroundSyncCard.notifyText(.luh)))
        XCTAssertTrue(ids(env).contains("background.timing"))
        XCTAssertTrue(shows(env, SettingsMore.closeTitle))
    }

    // MARK: - Sprungziele in der App

    /// Ohne Ziel und mit unbekanntem Ziel: Startseite (breit "Konto & Tarif"); ein Sprung wirkt auch, waehrend die
    /// Einstellungen schon offen sind (vorher nur beim Erscheinen)
    func testSprungzieleInDerHuelle() throws {
        let env = try host(size: Self.wide)
        env.router.go(.settings())
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Tarif wechseln") }, "ohne Ziel: Konto & Tarif\n" + texts(env).joined(separator: "\n"))
        env.router.go(.settings(tab: "help"))
        XCTAssertTrue(env.wait { self.shows(env, "Rechtliches & Support") && !self.shows(env, "Tarif wechseln") }, "Sprung bei offenen Einstellungen")
        env.router.go(.settings(tab: "gibt-es-nicht"))
        XCTAssertTrue(env.wait { self.shows(env, "Tarif wechseln") }, "unbekannt: Startseite")
        env.router.go(.settings(tab: "plan"))
        XCTAssertTrue(env.wait { self.shows(env, "Tarif wechseln") }, "ausgeblendet (Lernkalender aus): Startseite")
        XCTAssertFalse(shows(env, "Lernkombination"))
        env.router.go(.settings(tab: "modules"))
        XCTAssertTrue(env.wait { self.shows(env, "Modul anlegen") })
        env.router.go(.settings(tab: "diag"))
        XCTAssertTrue(env.wait { self.shows(env, "Vorab einordnen") }, "diag: Erweitert")
        // Antippen in der Liste links wechselt den Bereich
        XCTAssertTrue(tap(id: "settings.area.look", env))
        XCTAssertTrue(env.wait { self.shows(env, "Schreibhand") || self.shows(env, "Hell") })
    }

    /// `.settings(tab: "account")` meint an vielen Stellen die Anmeldung an der Hochschule: solange Stud.IP nicht
    /// verbunden ist, fuehrt ein Hinweis oben in einem Schritt zu "Uni-Zugang & Abgleich"; in der Demo fehlt er
    func testKontoZeigtDenWegZumUniZugang() throws {
        let demo = try host(size: Self.wide)
        open(demo, "account", height: 2000)
        XCTAssertTrue(demo.wait(timeout: 12) { self.shows(demo, "Tarif wechseln") })
        XCTAssertFalse(ids(demo).contains("settings.account.openUni"), "in der Demo kein Hinweis")
        demo.window.isHidden = true

        let env = try host(size: Self.wide, demo: false)
        open(env, "account", height: 2000)
        XCTAssertTrue(env.wait(timeout: 12) { self.ids(env).contains("settings.account.openUni") }, texts(env).joined(separator: "\n"))
        XCTAssertTrue(shows(env, SettingsUniAccessHint.title(.signedOut) ?? "?"))
        XCTAssertTrue(tap(id: "settings.account.openUni", env))
        XCTAssertTrue(env.wait { self.shows(env, UniAutoLoginCard.title) && !self.shows(env, "Tarif wechseln") }, "Uni-Zugang & Abgleich offen")
        XCTAssertNil(SettingsUniAccessHint.title(.idle), "verbunden: kein Hinweis")
        XCTAssertNotNil(SettingsUniAccessHint.title(.needsLogin))
    }

    // MARK: - Lernkalender

    /// Schalter aus: kein Bereich "Lernzeit & Verfügbarkeit", kein "Fächer im Lernkalender", kein automatisches
    /// Auffuellen; Schalter an: alles wie vorher erreichbar
    func testLernkalenderEinstellungenFolgenDemSchalter() throws {
        // nur die Seite der Einstellungen (ohne die Seitenleiste der App, die ein anderer Zweig umbaut)
        let off = try hostPage("plan")
        XCTAssertTrue(off.wait(timeout: 15) { self.shows(off, "Tarif wechseln") && self.ids(off).contains("settings.area.modules") },
                      "Rückfall auf die Startseite\n" + texts(off).joined(separator: "\n"))
        XCTAssertFalse(ids(off).contains("settings.area.plan"))
        for t in ["Lernzeit", "Lernkombination", "Verfügbarkeit & Sperrzeiten", PlanModulesText.button, "Lernkalender"] {
            XCTAssertFalse(shows(off, t), "Schalter aus: „\(t)“ steht in den Einstellungen")
        }
        off.window.isHidden = true
        for (tab, marker) in [("uni", UniAutoLoginCard.title), ("look", "Hell"), ("modules", "Modul anlegen"), ("community", "Community"),
                              ("help", "Impressum"), ("advanced", "Vorab einordnen")] {
            let page = try hostPage(tab)
            XCTAssertTrue(page.wait(timeout: 15) { self.shows(page, marker) }, "\(tab): „\(marker)“ fehlt\n" + texts(page).joined(separator: "\n"))
            page.pump(0.5)
            // Die Karte "Uni-Mail & Uni-Kalender" (Views/UniMail, nicht Teil der Einstellungen-Dateien) nennt in ihrem
            // Satz noch "Termine im Lernkalender": ausserhalb dieses Auftrags, im Bericht genannt
            let found = texts(page).filter { ($0.contains("Lernkalender") || $0.contains("Lernzeit")) && !$0.hasPrefix("Uni-Mail und Uni-Kalender") }
            XCTAssertEqual(found, [], "\(tab): Lernkalender bei Schalter aus")
            page.window.isHidden = true
        }
        let server = SettingsPage.Loaded(s: .object(["auto_plan": .bool(true)]), courses: [], mods: [], log: [], cred: .null, term: .null)
        let advancedOff = try hostWithEnvironment(ScrollView { SettingsServerAdvancedTab(d: server) }, api: container.api, size: Self.wide)
        XCTAssertTrue(advancedOff.wait { self.ids(advancedOff).contains("settings.fold.synclog") })
        XCTAssertFalse(shows(advancedOff, "Noch kein Sync."), "Sync-Protokoll zugeklappt")
        XCTAssertFalse(shows(advancedOff, "Gerät:"), "Diagnose zugeklappt")
        XCTAssertTrue(tap(id: "settings.fold.synclog", advancedOff))
        XCTAssertTrue(advancedOff.wait { self.shows(advancedOff, "Noch kein Sync.") })
        XCTAssertFalse(ids(advancedOff).contains("settings.autoPlan"), "Schalter aus: kein automatisches Auffüllen")
        XCTAssertFalse(shows(advancedOff, "Lernkalender"))
        XCTAssertTrue(tap(id: "settings.fold.diag", advancedOff))
        XCTAssertTrue(advancedOff.wait { self.shows(advancedOff, "Gerät:") }, "Diagnose aufgeklappt")
        XCTAssertTrue(ids(advancedOff).contains("settings.fold.pdftest"))
        advancedOff.window.isHidden = true

        LearnCalendar.enabled = true
        defer { LearnCalendar.enabled = false }
        let on = try hostPage("plan")
        XCTAssertTrue(on.wait(timeout: 15) { self.shows(on, "Lernkombination") }, texts(on).joined(separator: "\n"))
        XCTAssertTrue(ids(on).contains("settings.area.plan"))
        for t in ["Lernzeit & Verfügbarkeit", "Verfügbarkeit & Sperrzeiten", PlanModulesText.button, "Fächer pro Tag", "Lernfenster"] {
            XCTAssertTrue(shows(on, t), "Schalter an: „\(t)“ fehlt\n" + texts(on).joined(separator: "\n"))
        }
        on.window.isHidden = true
        let advancedOn = try hostWithEnvironment(ScrollView { SettingsServerAdvancedTab(d: server) }, api: container.api, size: Self.wide)
        XCTAssertTrue(advancedOn.wait { self.ids(advancedOn).contains("settings.fold.synclog") })
        XCTAssertTrue(tap(id: "settings.fold.synclog", advancedOn))
        XCTAssertTrue(advancedOn.wait { self.shows(advancedOn, "Lernkalender nach dem Sync automatisch auffüllen") }, texts(advancedOn).joined(separator: "\n"))
    }

    // MARK: - Schmal: iPhone, schmales Fenster, grosse Schrift

    /// iPhone hoch und quer: Startseite ist die Liste der Bereiche, Antippen oeffnet die Unterseite, "Einstellungen"
    /// und der Pfeil der Kopfzeile fuehren zurueck; ein Sprungziel oeffnet die Unterseite gleich
    func testIPhoneListeMitUnterseiten() throws {
        UFCompact.phoneOverride = true
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        defer {
            UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault
            UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault
        }
        let env = try host(size: Self.phone)
        for (size, vertical) in [(Self.phone, UIUserInterfaceSizeClass.regular), (CGSize(width: 874, height: 402), .compact)] {
            env.hosting.traitOverrides.horizontalSizeClass = .compact
            env.hosting.traitOverrides.verticalSizeClass = vertical
            env.router.go(.dashboard); env.pump(0.3)
            env.window.frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: max(size.height, 1400)))
            env.view.frame = env.window.bounds
            let step = "\(Int(size.width)) x \(Int(size.height))"
            env.router.go(.settings())
            let areas = SettingsArea.visible(hasData: true)
            XCTAssertTrue(env.wait(timeout: 15) { Set(areas.map(\.identifier)).isSubset(of: self.ids(env)) },
                          "\(step): Liste der Bereiche\n\(ids(env).sorted())")
            XCTAssertFalse(shows(env, "Tarif wechseln"), "\(step): Startseite ist die Liste, kein Inhalt")
            XCTAssertFalse(ids(env).contains("settings.back"))
            XCTAssertFalse(env.router.hasLocalBack)
            XCTAssertTrue(shows(env, "Darstellung") && !shows(env, "Darstellung & Stift"), "\(step): am iPhone ohne Stift")
            // Unterseite
            XCTAssertTrue(tap(id: "settings.area.help", env), step)
            XCTAssertTrue(env.wait { self.shows(env, "Rechtliches & Support") && self.ids(env).contains("settings.back") }, "\(step): Unterseite Hilfe")
            XCTAssertFalse(ids(env).contains("settings.area.account"), "\(step): die Liste ist weg")
            XCTAssertTrue(env.wait { env.router.hasLocalBack }, "\(step): Pfeil der Kopfzeile fuehrt zur Liste")
            env.router.goBack()
            XCTAssertTrue(env.wait { self.ids(env).contains("settings.area.account") && !self.shows(env, "Rechtliches & Support") }, "\(step): zurück zur Liste")
            XCTAssertEqual(env.router.route, .settings(), "\(step): weiter in den Einstellungen")
            // Sprungziel oeffnet die Unterseite, "Einstellungen" fuehrt zur Liste
            env.router.go(.settings(tab: "account"))
            XCTAssertTrue(env.wait(timeout: 12) { self.shows(env, "Tarif wechseln") && self.ids(env).contains("settings.back") }, "\(step): Sprung account")
            XCTAssertTrue(tap(id: "settings.back", env), step)
            XCTAssertTrue(env.wait { self.ids(env).contains("settings.area.uni") && !self.shows(env, "Tarif wechseln") }, "\(step): Einstellungen-Link")
            // am iPhone keine Stift-Zeilen
            XCTAssertTrue(tap(id: "settings.area.look", env), step)
            XCTAssertTrue(env.wait { self.shows(env, "Hell") && self.shows(env, "Dunkel") }, "\(step): Darstellung")
            XCTAssertFalse(shows(env, "Schreibhand"), "\(step): keine Schreibhand am iPhone")
            XCTAssertFalse(ids(env).contains("settings.toolbarPlacement"))
            // unbekanntes Ziel: Liste
            env.router.go(.settings(tab: "gibt-es-nicht"))
            XCTAssertTrue(env.wait { self.ids(env).contains("settings.area.account") && !self.ids(env).contains("settings.back") }, "\(step): Rückfall auf die Liste")
        }
    }

    /// iPad in Split View, schmales Mac-Fenster und Bedienungshilfen-Schrift: dieselbe Liste mit Unterseiten; breit die
    /// Liste links neben dem Inhalt
    func testSchmalesFensterUndGrosseSchrift() throws {
        let env = try host(size: Self.wide)
        open(env, nil, height: 1600)
        XCTAssertTrue(env.wait(timeout: 12) { self.shows(env, "Tarif wechseln") && self.ids(env).contains("settings.area.advanced") }, "breit: Liste und Inhalt")
        let selected = LockVisibilityAppTests.element("settings.area.account", in: env.window)
        XCTAssertEqual(selected?.accessibilityTraits.contains(.selected), true, "aktiver Bereich markiert")
        // schmal (Split View 1/2, schmales Fenster am Mac)
        env.window.frame = CGRect(origin: .zero, size: CGSize(width: 590, height: 1600))
        env.view.frame = env.window.bounds
        XCTAssertTrue(env.wait(timeout: 12) { self.ids(env).contains("settings.area.account") && !self.shows(env, "Tarif wechseln") },
                      "schmal: Startseite ist die Liste\n" + texts(env).joined(separator: "\n"))
        XCTAssertTrue(tap(id: "settings.area.uni", env))
        XCTAssertTrue(env.wait { self.shows(env, UniAutoLoginCard.title) && self.ids(env).contains("settings.back") })
        // wieder breit: der gewaehlte Bereich bleibt, die Liste steht links
        env.window.frame = CGRect(origin: .zero, size: CGSize(width: 1210, height: 1600))
        env.view.frame = env.window.bounds
        XCTAssertTrue(env.wait(timeout: 12) { self.shows(env, UniAutoLoginCard.title) && self.ids(env).contains("settings.area.help") && !self.ids(env).contains("settings.back") })
        env.window.isHidden = true

        // sehr grosse Schrift am iPad quer: Liste statt schmaler Spalte neben dem Inhalt
        let big = try host(size: Self.wide, typeSize: .accessibility3)
        open(big, nil, height: 2400)
        XCTAssertTrue(big.wait(timeout: 12) { self.ids(big).contains("settings.area.account") }, texts(big).joined(separator: "\n"))
        XCTAssertFalse(shows(big, "Tarif wechseln"), "grosse Schrift: Startseite ist die Liste")
        XCTAssertTrue(tap(id: "settings.area.account", big))
        XCTAssertTrue(big.wait { self.shows(big, "Tarif wechseln") && self.ids(big).contains("settings.back") })
        let over = LayoutWidthAuditTests.overflows(in: big.window)
        XCTAssertTrue(over.isEmpty, "grosse Schrift: nichts ragt über den Rand\n" + over.prefix(12).map(\.text).joined(separator: "\n"))
    }

    // MARK: - Hosten

    private func host(size: CGSize, demo: Bool = true, typeSize: DynamicTypeSize? = nil) throws -> HostedEnvironment {
        let root = MainView()
            .environment(\.ufDemoActive, demo)
            .environment(\.ufChatGPTLink, manager.chatgpt)
            .environment(\.ufStudoraAccount, manager.account)
            .environment(\.backgroundSync, background)
            .environment(\.uniMail, manager.uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        let env: HostedEnvironment
        if let typeSize {
            env = try hostWithEnvironment(root.environment(\.dynamicTypeSize, typeSize), api: container.api, size: size, studip: manager.studip)
        } else {
            env = try hostWithEnvironment(root, api: container.api, size: size, studip: manager.studip)
        }
        return env
    }

    /// Nur die Seite der Einstellungen (breit, hohes Fenster), ohne die Huelle der App
    private func hostPage(_ tab: String?) throws -> HostedEnvironment {
        let root = SettingsPage(initialTab: tab)
            .environment(\.ufDemoActive, true)
            .environment(\.ufChatGPTLink, manager.chatgpt)
            .environment(\.ufStudoraAccount, manager.account)
            .environment(\.backgroundSync, background)
            .environment(\.uniMail, manager.uniMail)
            .environmentObject(manager!)
            .environmentObject(account!)
        return try hostWithEnvironment(root, api: container.api, size: CGSize(width: 1180, height: 4200), studip: manager.studip)
    }

    /// Einstellungen mit diesem Sprungziel oeffnen (ueber die Uebersicht), im hohen Fenster, damit alle Karten da sind
    private func open(_ env: HostedEnvironment, _ tab: String?, height: CGFloat) {
        env.router.go(.dashboard); env.pump(0.3)
        env.window.frame = CGRect(origin: .zero, size: CGSize(width: env.window.frame.width, height: height))
        env.view.frame = env.window.bounds
        env.router.go(.settings(tab: tab))
        env.pump(1.0)
    }

    private func ids(_ env: HostedEnvironment) -> Set<String> { LockVisibilityAppTests.identifiers(in: env.window) }
    private func texts(_ env: HostedEnvironment) -> [String] { LayoutWidthAuditTests.texts(env.window) }
    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func tap(id: String, _ env: HostedEnvironment) -> Bool {
        LockVisibilityAppTests.element(id, in: env.window)?.accessibilityActivate() ?? false
    }
}
