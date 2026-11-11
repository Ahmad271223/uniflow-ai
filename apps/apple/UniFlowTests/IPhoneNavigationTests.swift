import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// iPhone-Fassung, Teil A (docs/IPHONE-2026-11-04.md): untere Leiste und "Mehr" je Plattform und Tarif, die Regel
/// "kompakt nach Platz", Dialoge als Blatt von unten statt mittig, die kompakte Kopfzeile (Suche, Sync, Profil als
/// Symbole, keine Schublade) und der Notenspiegel als Liste. Die iPad-Fassung (regulaer) bleibt dabei unveraendert.
@MainActor
final class IPhoneNavigationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    // MARK: - Untere Leiste und "Mehr"

    func testTabBarIsStartCalendarModulesDocumentsMore() {
        XCTAssertEqual(UFNavItem.mobile.map(\.id), ["dashboard", "plan", "modules", "files", "more"])
        XCTAssertEqual(UFNavItem.mobile.map(\.title), ["Start", "Kalender", "Module", "Dokumente", "Mehr"])
    }

    /// Jeder sichtbare Bereich ist genau einmal erreichbar: in der Leiste oder in "Mehr"; Einstellungen immer zuletzt
    func testMoreListsEveryOtherVisibleAreaPerPlatformAndPlan() {
        let cases: [(name: String, visible: [UFNavItem], more: [String])] = [
            ("iPhone ohne KI", UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true),
             ["timetable", "studyplan", "cards", "services", "mensa", "rooms", "community", "settings"]),
            ("iPhone mit KI und Nachrichten", UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: true, messages: true),
             ["messages", "timetable", "studyplan", "exams", "cards", "services", "mensa", "rooms", "community", "settings"]),
            // Uni-Mail (LUH, 05.11.2026) und Raumfinder stehen in "Mehr" (nicht in der Leiste)
            ("iPhone LUH mit Uni-Mail", UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, messages: true, uniMail: true),
             ["messages", "unimail", "timetable", "studyplan", "cards", "services", "mensa", "rooms", "community", "settings"]),
            ("ohne iCloud", UFNavItem.visible(local: true, gradesOnDevice: true, community: false, flashcards: true),
             ["timetable", "studyplan", "cards", "services", "mensa", "rooms", "settings"]),
            ("eigener Server", UFNavItem.visible(local: false, gradesOnDevice: true, community: true),
             ["timetable", "studyplan", "exams", "services", "mensa", "rooms", "community", "settings"]),
        ]
        for c in cases {
            let more = UFNavItem.more(visible: c.visible)
            XCTAssertEqual(more.map(\.id), c.more, c.name)
            let reachable = Set(UFNavItem.mobile.map(\.id)).union(more.map(\.id))
            for item in c.visible { XCTAssertTrue(reachable.contains(item.id), "\(c.name): \(item.title) nicht erreichbar") }
            let bar = Set(UFNavItem.mobile.map(\.id))
            XCTAssertTrue(more.allSatisfy { !bar.contains($0.id) }, "\(c.name): doppelt in Leiste und Mehr")
            XCTAssertEqual(more.last?.id, "settings", c.name)
        }
    }

    func testMoreIsMarkedForItsAreasAndCountsTheirBadges() {
        let more = UFNavItem.more(visible: UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, messages: true))
        for r in [UFRoute.messages, .timetable(), .studyPlan(), .cards, .services, .community, .communitySpace("x"), .settings()] {
            XCTAssertTrue(UFMobileNav.moreActive(r, items: more), "\(r)")
        }
        for r in [UFRoute.dashboard, .plan(), .modules, .module(3), .files(), .doc("d")] {
            XCTAssertFalse(UFMobileNav.moreActive(r, items: more), "\(r)")
        }
        XCTAssertEqual(UFMobileNav.moreBadge(["messages": 3, "community": 2, "dashboard": 9], items: more), 5)
    }

    // MARK: - Kompakt nach Platz

    func testCompactFollowsSpaceNotDevice() {
        XCTAssertFalse(UFLayout.isCompact(horizontal: .regular, vertical: .regular), "iPad: unveraendert")
        XCTAssertTrue(UFLayout.isCompact(horizontal: .compact, vertical: .regular), "iPhone hoch, iPad schmaler Split View")
        XCTAssertTrue(UFLayout.isCompact(horizontal: .compact, vertical: .compact), "iPhone quer")
        XCTAssertTrue(UFLayout.isCompact(horizontal: .regular, vertical: .compact), "grosses iPhone quer")
        XCTAssertFalse(UFLayout.isCompact(horizontal: nil, vertical: nil))
    }

    func testDialogsAreBottomSheetsOnlyWhenCompact() {
        XCTAssertTrue(UFLayout.presentsAsSheet(horizontal: .compact, vertical: .regular))
        XCTAssertFalse(UFLayout.presentsAsSheet(horizontal: .regular, vertical: .regular))
        // Dialog in einem Blatt am iPad (das Blatt ist selbst schmal): mittig wie bisher; am iPhone als Blatt
        XCTAssertFalse(UFLayout.inlineModalAsSheet(shell: false, horizontal: .compact, vertical: .regular, phone: false))
        XCTAssertTrue(UFLayout.inlineModalAsSheet(shell: false, horizontal: .compact, vertical: .regular, phone: true))
        XCTAssertTrue(UFLayout.inlineModalAsSheet(shell: true, horizontal: .regular, vertical: .regular, phone: false), "iPad im schmalen Split View")
        XCTAssertEqual(UFLayout.detents(wide: false), [.medium, .large])
        XCTAssertEqual(UFLayout.detents(wide: true), [.large])
        XCTAssertEqual(UFLayout.pagePadding(compact: true), 16)
        XCTAssertEqual(UFLayout.pagePadding(compact: false), 25.6)
    }

    func testCalendarShowsThreeDaysInsteadOfWeekOnPhoneWidth() {
        XCTAssertEqual(PlanView.views(compact: false).map(\.value), ["day", "3days", "week", "month", "list"])
        XCTAssertEqual(PlanView.views(compact: true, weekFits: false).map(\.value), ["day", "3days", "month", "list"])
        XCTAssertEqual(PlanView.views(compact: true, weekFits: true).map(\.value), ["day", "3days", "week", "month", "list"])
        for w: CGFloat in [390, 402, 440] { XCTAssertFalse(PlanView.weekFits(width: w), "iPhone \(w) hoch") }
        for w: CGFloat in [590, 874, 1180] { XCTAssertTrue(PlanView.weekFits(width: w), "\(w): Split View, iPhone quer, iPad") }
        XCTAssertEqual(PlanView.shownView("week", weekFits: false), "3days")
        XCTAssertEqual(PlanView.shownView("week", weekFits: true), "week")
        XCTAssertEqual(PlanView.shownView("month", weekFits: false), "month")
    }

    func testDeviceNameInTexts() {
        XCTAssertEqual(UFDevice.name, UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad")
    }

    // MARK: - Gehostet

    private func shell(compact: Bool, size: CGSize) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(AppShell { _ in Text("Seiteninhalt") }, size: size)
        env.hosting.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        env.hosting.traitOverrides.verticalSizeClass = .regular
        env.pump(0.6)
        return env
    }

    /// Kennungen aller Bedienungshilfen-Elemente (auch ohne Namen)
    private func ids(_ root: UIView) -> Set<String> {
        root.layoutIfNeeded()
        var out = Set<String>()
        var seen = Set<ObjectIdentifier>()
        let sel = NSSelectorFromString("accessibilityIdentifier")
        func visit(_ e: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.responds(to: sel), let id = o.perform(sel)?.takeUnretainedValue() as? String, !id.isEmpty { out.insert(id) }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    func testCompactHeaderHasIconsAndNoDrawer() throws {
        let env = try shell(compact: true, size: CGSize(width: 402, height: 874))
        let found = ids(env.view)
        for id in ["header.home", "header.search", "header.sync", "header.profile",
                   "mobileNav.dashboard", "mobileNav.plan", "mobileNav.modules", "mobileNav.files", "mobileNav.more"] {
            XCTAssertTrue(found.contains(id), "\(id) fehlt: \(found.sorted())")
        }
        XCTAssertFalse(found.contains("header.menu"), "kompakt keine Schublade")
        XCTAssertFalse(found.contains("sidebar.profile"), "kompakt keine Seitenleiste")
        XCTAssertTrue(env.labels().contains("Suche"))
    }

    /// iPad hochkant in Split View 2/3 (780 pt, regulaer): wie bisher Menueknopf mit Schublade und Suchfeld
    func testRegularNarrowKeepsDrawerAndSearchField() throws {
        let env = try shell(compact: false, size: CGSize(width: 780, height: 1000))
        let found = ids(env.view)
        XCTAssertTrue(found.contains("header.menu"), "\(found.sorted())")
        XCTAssertFalse(found.contains("header.search"))
        XCTAssertTrue(found.contains("mobileNav.more"))
        let wide = try shell(compact: false, size: CGSize(width: 1180, height: 820))
        XCTAssertTrue(ids(wide.view).contains("sidebar.profile"), "iPad quer: Seitenleiste")
        XCTAssertFalse(ids(wide.view).contains("mobileNav.more"))
    }

    func testOverlayDialogIsSheetWhenCompactAndCenteredOtherwise() throws {
        let phone = try shell(compact: true, size: CGSize(width: 402, height: 874))
        phone.overlay.modal { UFDialog("Probedialog") { Text("Inhalt im Blatt") } foot: { EmptyView() } }
        XCTAssertTrue(phone.wait(timeout: 5) { phone.hosting.presentedViewController != nil }, "kompakt: Blatt von unten")
        XCTAssertFalse(phone.labels().contains("Inhalt im Blatt"), "nicht mittig ueber der Seite")
        phone.overlay.closeAll()
        XCTAssertTrue(phone.wait(timeout: 5) { phone.hosting.presentedViewController == nil }, "Schliessen nimmt das Blatt weg")

        let pad = try shell(compact: false, size: CGSize(width: 1180, height: 820))
        pad.overlay.modal { UFDialog("Probedialog") { Text("Inhalt mittig") } foot: { EmptyView() } }
        XCTAssertTrue(pad.wait(timeout: 5) { pad.labels().contains("Inhalt mittig") })
        XCTAssertNil(pad.hosting.presentedViewController, "iPad: mittig wie bisher")
    }

    func testGradesAreRowsWithNoteCreditsAndStatusWhenCompact() throws {
        let rows: [JSONValue] = [
            ["level": "modul", "text": "Grundlagen der Informatik", "semester": "WiSe 2025/26", "note": "1,7", "credits": "10", "status": "bestanden"],
            ["level": "modul", "text": "Grundlagen digitaler Systeme", "semester": "SoSe 2026", "note": "", "credits": "5", "status": "nicht bestanden", "versuch": "1"],
        ]
        let env = try hostWithEnvironment(ScrollView { GradesTable(rows: rows).padding(16) }.environment(\.ufCompact, true),
                                          size: CGSize(width: 390, height: 700))
        env.pump(0.6)
        let labels = env.labels()
        XCTAssertTrue(labels.contains("Grundlagen der Informatik, Note 1,7, 10 LP, bestanden, WiSe 2025/26"), "\(labels)")
        XCTAssertTrue(labels.contains("Grundlagen digitaler Systeme, Note –, 5 LP, nicht bestanden, SoSe 2026 · Versuch 1"), "\(labels)")
        XCTAssertFalse(labels.contains("SEMESTER"), "kompakt keine Tabellenkoepfe")
        XCTAssertTrue(LayoutWidthAuditTests.overflows(in: env.window).isEmpty)
    }
}
