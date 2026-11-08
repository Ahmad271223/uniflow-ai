import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Neugestaltung der Seitenleiste und des Lernstands (04.11.2026): Gruppen "STUDIUM", "LERNEN", "ALLTAG" (Mensa, 05.11.2026), "GEMEINSAM" je
/// Plattform und Tarif (leere Gruppen entfallen, `UFNavItem.visible` bleibt massgeblich), Kapselfarben der
/// Lern-Eintraege, Profil unten mit Tarif und Knopf zum naechsthoeheren Tarif (auch waehrend der Probe), die Kachel
/// "Lernstand" und VoiceOver. Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt
/// `testScreenshots` Bilder hell/dunkel, hoch/quer, eingeklappt und schmal (Schublade) dorthin. Alle Namen erfunden.
@MainActor
final class DesignShellAppTests: XCTestCase {

    /// Bedienungshilfen-Baum auch ohne VoiceOver fuellen (wie StoreScreenshotTests), sonst sind die Namen leer
    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    // MARK: - Gruppen

    private func ids(_ groups: [UFNavGroup]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.items.map(\.id)) })
    }

    func testGroupsOwnServerShowAllThree() {
        let groups = UFNavGroup.groups(UFNavItem.visible(local: false, gradesOnDevice: false, community: false))
        XCTAssertEqual(groups.map(\.id), ["study", "learn", "everyday", "together"])
        XCTAssertEqual(groups.map(\.label), ["STUDIUM", "LERNEN", "ALLTAG", "GEMEINSAM"])
        XCTAssertEqual(ids(groups)["everyday"], ["mensa", "rooms"], "Mensa und Raumfinder unter Alltag")
        XCTAssertEqual(ids(groups)["study"], ["dashboard", "plan", "timetable", "modules", "studyplan", "files", "services"],
                       "Uni & Noten gehoert zum Studium")
        XCTAssertEqual(ids(groups)["learn"], ["exams"])
        XCTAssertEqual(ids(groups)["together"], ["community"])
    }

    func testGroupsOnIPadPerPlatformAndPlan() {
        // ohne KI, mit Karteikarten und Community (V1 mit iCloud-Container)
        var g = UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: false))
        XCTAssertEqual(ids(g)["learn"], ["cards"])
        XCTAssertEqual(ids(g)["together"], ["community"])
        // mit KI: beide Lern-Eintraege, Tests vor Karteikarten
        g = UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: true))
        XCTAssertEqual(ids(g)["learn"], ["exams", "cards"])
        // ohne iCloud-Container: keine Gruppe "Gemeinsam"
        g = UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: true, community: false, flashcards: true))
        XCTAssertEqual(g.map(\.id), ["study", "learn", "everyday"])
        // ohne Karteikarten und ohne KI: keine Gruppe "Lernen"
        g = UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: false, ai: false))
        XCTAssertEqual(g.map(\.id), ["study", "everyday", "together"])
        // ohne Notenspiegel auf dem Geraet: kein Uni & Noten
        g = UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: false, community: false, flashcards: false, ai: false))
        XCTAssertEqual(g.map(\.id), ["study", "everyday"])
        XCTAssertEqual(ids(g)["study"], ["dashboard", "plan", "timetable", "modules", "studyplan", "files"])
    }

    /// Jeder sichtbare Eintrag steht genau einmal in einer Gruppe, in allen Kombinationen
    func testEveryVisibleItemExactlyOnce() {
        for local in [true, false] {
            for grades in [true, false] {
                for community in [true, false] {
                    for cards in [true, false] {
                        for ai in [true, false] {
                            let visible = UFNavItem.visible(local: local, gradesOnDevice: grades, community: community, flashcards: cards, ai: ai)
                            let grouped = UFNavGroup.groups(visible).flatMap(\.items).map(\.id)
                            XCTAssertEqual(grouped.sorted(), visible.map(\.id).sorted(), "\(local) \(grades) \(community) \(cards) \(ai)")
                            XCTAssertFalse(UFNavGroup.groups(visible).contains { $0.items.isEmpty })
                        }
                    }
                }
            }
        }
        // unbekannter Eintrag geht nicht verloren: ans Ende von "Studium"
        let extra = UFNavItem(id: "neu", title: "Neu", icon: "star", route: .dashboard)
        XCTAssertEqual(UFNavGroup.groups([UFNavItem.main[0], extra]).first?.items.map(\.id), ["dashboard", "neu"])
        XCTAssertEqual(UFNavGroup.groups([]), [])
    }

    func testGroupVoiceOverAndPills() {
        let g = UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: true))
        XCTAssertEqual(g.map(\.accessibilityLabel), ["Gruppe Studium", "Gruppe Lernen", "Gruppe Alltag", "Gruppe Gemeinsam"])
        let exams = UFNavItem.main.first { $0.id == "exams" }
        XCTAssertEqual(exams?.pill, CommunityPalette.sky, "Tests blau wie der Wochentest im KI-Start")
        XCTAssertEqual(UFNavItem.cards.pill, CommunityPalette.peach, "Karteikarten wie im KI-Start")
        XCTAssertTrue(UFNavItem.main.filter { !["exams"].contains($0.id) }.allSatisfy { $0.pill == nil })
    }

    // MARK: - Profil und Tarif

    func testProfilePlanLabelAndUpgradePerPlan() {
        let free = UFSidebarProfile.make(plan: .free, purchased: .free, trialDaysLeft: nil)
        XCTAssertEqual(free.planLabel, "Free")
        XCTAssertEqual(free.planAccessibility, "Tarif Free")
        XCTAssertEqual(free.upgradeTitle, "Plus holen")
        let plus = UFSidebarProfile.make(plan: .plus, purchased: .plus, trialDaysLeft: nil)
        XCTAssertEqual(plus.planLabel, "Plus")
        XCTAssertEqual(plus.upgradeTitle, "Pro AI holen")
        let pro = UFSidebarProfile.make(plan: .proAI, purchased: .proAI, trialDaysLeft: nil)
        XCTAssertEqual(pro.planLabel, "Pro AI")
        XCTAssertNil(pro.upgrade, "hoechster Tarif: kein Knopf")
        XCTAssertNil(pro.upgradeTitle)
    }

    func testProfileDuringTrial() {
        let t = UFSidebarProfile.make(plan: .proAI, purchased: .free, trialDaysLeft: 5)
        XCTAssertEqual(t.planLabel, "Probe · noch 5 Tage")
        XCTAssertEqual(t.planAccessibility, "Probe, noch 5 Tage")
        XCTAssertEqual(t.upgradeTitle, "Plus holen", "die Probe endet: weiter mit Plus")
        XCTAssertEqual(UFSidebarProfile.make(plan: .proAI, purchased: .free, trialDaysLeft: 1).planLabel, "Probe · noch 1 Tag")
        // gekauft schlaegt Probe; abgelaufene Probe = Free
        XCTAssertEqual(UFSidebarProfile.make(plan: .plus, purchased: .plus, trialDaysLeft: 4).planLabel, "Plus")
        XCTAssertEqual(UFSidebarProfile.make(plan: .free, purchased: .free, trialDaysLeft: 0).planLabel, "Free")

        // aus Entitlements: laufende Probe auf dem iPad
        let ent = Entitlements(observe: false, plan: .free)
        XCTAssertEqual(UFSidebarProfile.make(ent).planLabel, "Free")
        ent.useLocalTrial(startedAt: Date().addingTimeInterval(-86_400))
        let running = UFSidebarProfile.make(ent)
        XCTAssertTrue(running.planLabel.hasPrefix("Probe · noch "), running.planLabel)
        XCTAssertEqual(running.upgrade, .plus)
        ent.useLocalTrial(startedAt: Date().addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(UFSidebarProfile.make(ent).planLabel, "Free", "Probe vorbei")
    }

    func testProfileInitialsAndName() {
        XCTAssertEqual(UFSidebarProfile.initials(server: "XY", appleName: "Ada Muster", greetingName: "Ada"), "XY")
        XCTAssertEqual(UFSidebarProfile.initials(server: "", appleName: "Ada Muster", greetingName: "Adi"), "AM")
        XCTAssertEqual(UFSidebarProfile.initials(server: "", appleName: nil, greetingName: "Lea"), "L")
        XCTAssertEqual(UFSidebarProfile.initials(server: "", appleName: nil, greetingName: nil), "")
        let a = AccountStore.Account(userID: "u", name: "Lea Muster", email: nil, givenName: "Lea")
        XCTAssertEqual(UFGreeting.name(for: a),
                       UFGreeting.pick(rufname: Rufname.current(), accountName: nil, appleGivenName: "Lea", appleFullName: "Lea Muster"),
                       "dieselbe Quelle wie die Begruessung")
    }

    // MARK: - Gerenderte Seitenleiste

    private func labels(_ view: UIView) -> [String] {
        view.layoutIfNeeded()
        var out: [String] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 50 else { return }
            if let o = element as? NSObject {
                if let l = o.accessibilityLabel, !l.isEmpty { out.append(l) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    func testSidebarRendersGroupsProfileAndUpgrade() throws {
        Entitlements.shared.setPlanForTesting(.free)
        let env = try hostWithEnvironment(UFSidebar(collapsed: false, allowCollapse: true).frame(width: UF.sidebar), size: CGSize(width: 400, height: 1000))
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Plus holen") }, labels(env.view).joined(separator: "\n"))
        let l = labels(env.view)
        XCTAssertTrue(l.contains("Gruppe Studium"), l.joined(separator: "\n"))
        XCTAssertTrue(l.contains("Lernen") || l.contains("Gruppe Lernen"), "Ueberschrift der Lern-Gruppe")
        XCTAssertTrue(l.contains { $0.hasSuffix("Tarif Free") }, "Tarif wird vorgelesen")
        XCTAssertTrue(l.contains("Übersicht"))
        XCTAssertTrue(l.contains("Karteikarten"))
        XCTAssertTrue(l.contains("Einstellungen"))
        XCTAssertTrue(l.contains("Einklappen"))
        // "Plus holen" fuehrt zu den Tarifen
        let button = try XCTUnwrap(elementsWith("Plus holen", in: env.view).first)
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertTrue(env.wait { env.router.route == .settings(tab: "plan") }, "\(env.router.route)")
    }

    func testCollapsedSidebarShowsOnlyAvatarAtBottom() throws {
        Entitlements.shared.setPlanForTesting(.free)
        let env = try hostWithEnvironment(UFSidebar(collapsed: true, allowCollapse: true).frame(width: UF.sidebarMin), size: CGSize(width: 200, height: 1000))
        XCTAssertTrue(env.wait { self.labels(env.view).contains { $0.hasSuffix("Tarif Free") } }, labels(env.view).joined(separator: "\n"))
        XCTAssertFalse(labels(env.view).contains("Plus holen"), "eingeklappt kein Tarif-Knopf")
        XCTAssertFalse(labels(env.view).contains("Lernen"), "eingeklappt keine Ueberschriften")
        XCTAssertTrue(env.wait(timeout: 3) { self.labels(env.view).contains("Übersicht") },
                      "Symbole mit Namen fuer VoiceOver: " + labels(env.view).joined(separator: " | "))
    }

    private func elementsWith(_ label: String, in view: UIView) -> [NSObject] {
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 50 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel == label { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    // MARK: - Kachel "Lernstand"

    func testLernstandTileRendersAndReadsOneSentence() throws {
        let m: JSONValue = ["score": 64, "reason": "3 Wochentests, 42 Karten, 12 von 20 Aufgaben"]
        let env = try hostWithEnvironment(VStack {
            LernstandTile(m: m, color: .blue)
            LernstandTile(m: nil, style: .inline)
        }.frame(width: 420), size: CGSize(width: 500, height: 600))
        XCTAssertTrue(env.wait { self.labels(env.view).contains("Lernstand 64 Prozent, 3 Wochentests, 42 Karten, 12 von 20 Aufgaben") },
                      labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(labels(env.view).contains(LernstandText.accessibility(nil)))
    }

    // MARK: - Bildschirmfotos

    private static let portrait = CGSize(width: 1032, height: 1376)
    private static let landscape = CGSize(width: 1376, height: 1032)

    /// Leere Wolke im Speicher: die Community gilt als verbunden (wie StoreScreenshotTests)
    private final class EmptyCloud: CommunityCloud, @unchecked Sendable {
        func accountStatus() async throws -> CommunityAccountStatus { .available }
        func userRecordName() async throws -> String { "_demo" }
        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord { record }
        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? { nil }
        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] { [] }
        func delete(name: String, type: String, in scope: CommunityScope) async throws {}
    }

    private func png(_ view: UIView) -> Data {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, to dir: URL, sizes: [(CGSize, String)]? = nil) {
        for (size, orientation) in sizes ?? [(Self.landscape, "landscape"), (Self.portrait, "portrait")] {
            env.window.frame = CGRect(origin: .zero, size: size)
            env.view.frame = env.window.bounds
            env.pump(1.0)
            for (style, tone) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
                env.window.overrideUserInterfaceStyle = style
                env.pump(0.8)
                let file = dir.appendingPathComponent("\(name)-\(tone)-\(orientation).png")
                do { try png(env.view).write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
            }
            env.window.overrideUserInterfaceStyle = .unspecified
        }
    }

    /// async-Arbeit ausfuehren und dabei die Hauptschleife laufen lassen (wie StoreScreenshotTests: aus einer
    /// async-Testmethode heraus laufen die `.task`-Ladevorgaenge der Ansichten beim Pumpen nicht an)
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

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bed = try ContainerTestBed(name: "design-shell", clock: .system)
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
        Rufname.write("Lea", container.defaults)
        Entitlements.shared.setPlanForTesting(.free)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        let oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        defer {
            CommunityRoute.shared.service = nil
            Entitlements.shared.useLocalTrial(startedAt: nil)
            Entitlements.shared.setPlanForTesting(.free)
            UserDefaults.standard.set(oldSidebar, forKey: "sidebar")
            manager.deactivate()
        }
        UserDefaults.standard.set("full", forKey: "sidebar")

        func app(ai: Bool) throws -> HostedEnvironment {
            let root = MainView()
                .environment(\.ufDemoActive, true)
                .environment(\.ufAIEnabled, ai)
                .environmentObject(manager)
                .environmentObject(account)
            return try hostWithEnvironment(root, api: container.api, size: Self.landscape, studip: manager.studip)
        }

        // Uebersicht ohne KI (Free), dann mit KI (beide Lern-Kapseln) auf der Karteikarten-Seite
        let env = try app(ai: false)
        _ = env.wait(timeout: 15) { self.labels(env.view).contains { $0.contains("Grundlagen der Informatik") } }
        shoot(env, "01-uebersicht", to: dir)
        env.router.go(.cards)
        env.pump(1.5)
        shoot(env, "02-karteikarten", to: dir, sizes: [(Self.landscape, "landscape")])
        let api = container.api
        let moduleID = try pumping { try await api.value("/api/modules").items.first?.i("id") }
        if let id = moduleID {
            env.router.go(.module(id))
            env.pump(2.0)
            shoot(env, "03-modul", to: dir)
        }
        env.router.go(.modules)
        env.pump(2.0)
        shoot(env, "04-module", to: dir, sizes: [(Self.landscape, "landscape")])

        // Probe laeuft: Tarif "Probe · noch n Tage"
        Entitlements.shared.useLocalTrial(startedAt: Date().addingTimeInterval(-2 * 86_400))
        let ai = try app(ai: true)
        ai.router.go(.exams)
        _ = ai.wait(timeout: 10) { self.labels(ai.view).contains("Tests & Wiederholung") }
        ai.pump(1.5)
        shoot(ai, "05-tests-ki-probe", to: dir, sizes: [(Self.landscape, "landscape")])
        Entitlements.shared.useLocalTrial(startedAt: nil)
        Entitlements.shared.setPlanForTesting(.plus)

        // eingeklappt
        UserDefaults.standard.set("min", forKey: "sidebar")
        env.router.go(.dashboard)
        env.pump(1.5)
        shoot(env, "06-eingeklappt", to: dir)
        UserDefaults.standard.set("full", forKey: "sidebar")

        // schmal (iPad hochkant in Split View): Schublade offen
        env.router.drawerOpen = true
        shoot(env, "07-schublade", to: dir, sizes: [(CGSize(width: 700, height: 1000), "narrow")])
        env.router.drawerOpen = false

        // Kacheln einzeln: mit und ohne Lernstand, beide Groessen
        let gallery = try hostWithEnvironment(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LernstandTile(m: ["score": 64, "reason": "3 Wochentests, 42 Karten, 12 von 20 Aufgaben"], color: Color(hex: "#7c5ce0"))
                LernstandTile(m: nil)
                LernstandTile(m: ["score": 88, "reason": "5 Wochentests, 120 Karten"], color: Color(hex: "#14a39a"), style: .inline)
                LernstandTile(m: nil, style: .inline)
                LernstandTile(m: ["score": 7, "reason": "1 von 20 Aufgaben"], color: Color(hex: "#ea7a2c"), style: .inline)
                    .environment(\.dynamicTypeSize, .accessibility2)
            }
            .padding(24)
            .frame(width: 520)
        }.background(UF.bg), size: CGSize(width: 568, height: 900))
        gallery.pump(1.0)
        shoot(gallery, "08-lernstand-kacheln", to: dir, sizes: [(CGSize(width: 568, height: 900), "tiles")])
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        try pumping { await bed.tearDown() }
    }
}
