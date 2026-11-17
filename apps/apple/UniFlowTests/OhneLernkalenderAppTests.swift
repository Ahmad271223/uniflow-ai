import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Auftrag des Inhabers 17.11.2026: "bitte erstmal komplett Lernkalender rausnehmen, will nur Stundenplan mit den
/// Ansagen da oben haben ... und das auch rausnehmen: den Punkt 'Heute für dich geplant' und den Punkt 'Diese Woche'
/// ... das kommt alles nach." Mit `LearnCalendar.enabled == false` (ausgelieferter Standard) ist der Lernkalender
/// nirgends zu sehen oder erreichbar: Menue (iPad-Leiste, iPhone-Leiste, "Mehr"), Route `.plan`, Uebersicht, Fragen,
/// Tarifkarten, Einstieg, Suche; die App plant nichts von selbst. Mit `true` ist alles wie vorher (Gegenproben).
/// Dazu die beiden weiteren Auftraege vom selben Tag: Logo fuehrt zur Übersicht, die Profilkarte oeffnet die
/// Einstellungen. Alle Namen erfunden, kein Netz.
@MainActor
final class OhneLernkalenderAppTests: XCTestCase {
    private var before = false

    override func setUp() async throws {
        try await super.setUp()
        before = LearnCalendar.enabled
        LearnCalendar.enabled = false
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        LearnCalendar.enabled = before
        try await super.tearDown()
    }

    func testShippedDefaultIsOff() {
        XCTAssertFalse(before, "ausgeliefert wird ohne Lernkalender")
    }

    // MARK: - Menue

    func testSidebarDrawerAndLogoMenuHaveNoLearnCalendar() {
        XCTAssertFalse(UFNavItem.main.contains { $0.id == "plan" || $0.title == "Lernkalender" })
        let local = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: true, messages: true, uniMail: true)
        XCTAssertFalse(local.contains { $0.id == "plan" }, "iPad/iPhone/Mac ohne PC")
        XCTAssertEqual(Array(local.map(\.id).prefix(5)), ["dashboard", "messages", "unimail", "timetable", "modules"], "Stundenplan rueckt auf")
        XCTAssertFalse(UFNavItem.visible(local: false, gradesOnDevice: true, community: true).contains { $0.id == "plan" }, "eigener Server")
        let study = UFNavGroup.groups(local).first { $0.id == "study" }?.items.map(\.id)
        XCTAssertEqual(study, ["dashboard", "messages", "unimail", "timetable", "modules", "studyplan", "files", "services"])
        XCTAssertFalse(local.map(\.menuTitle).contains("Lernkalender"), "Logo-Menue des Editors")

        LearnCalendar.enabled = true
        XCTAssertEqual(UFNavItem.main.map(\.id).prefix(3), ["dashboard", "plan", "timetable"], "mit Schalter an wie vorher")
        XCTAssertEqual(UFNavItem.main.first { $0.id == "plan" }?.title, "Lernkalender")
    }

    func testPhoneBarShowsTimetableInsteadOfCalendar() {
        XCTAssertEqual(UFNavItem.mobile.map(\.id), ["dashboard", "timetable", "modules", "files", "more"])
        XCTAssertEqual(UFNavItem.mobile.map(\.title), ["Start", "Stundenplan", "Module", "Dokumente", "Mehr"])
        XCTAssertEqual(UFNavItem.mobile[1].route, .timetable())
        let visible = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true)
        let more = UFNavItem.more(visible: visible)
        XCTAssertEqual(more.map(\.id), ["studyplan", "cards", "services", "mensa", "rooms", "community", "settings"],
                       "„Mehr“ ohne Lernkalender; der Stundenplan steht in der Leiste, die Einstellungen bleiben")
        let reachable = Set(UFNavItem.mobile.map(\.id)).union(more.map(\.id))
        for item in visible { XCTAssertTrue(reachable.contains(item.id), "\(item.title) nicht erreichbar") }
        // der Stundenplan ist am iPhone jetzt eine Wurzel wie Start, Module, Dokumente: ohne Pfeil, "Mehr" nicht markiert
        XCTAssertFalse(UFRouter.showsCompactBackArrow(on: .timetable(), local: false))
        XCTAssertFalse(UFRouter.showsCompactBackArrow(on: .timetable(date: "2026-11-23"), local: false))
        XCTAssertFalse(UFMobileNav.moreActive(.timetable(), items: more))

        LearnCalendar.enabled = true
        XCTAssertEqual(UFNavItem.mobile.map(\.title), ["Start", "Kalender", "Module", "Dokumente", "Mehr"], "mit Schalter an wie vorher")
        XCTAssertTrue(UFRouter.showsCompactBackArrow(on: .timetable(), local: false))
    }

    // MARK: - Route

    func testPlanRouteLeadsToTimetable() {
        XCTAssertEqual(LearnCalendar.route(.plan()), .timetable())
        XCTAssertEqual(LearnCalendar.route(.plan(view: "day", date: "2026-11-20", module: "3")), .timetable(date: "2026-11-20"))
        XCTAssertEqual(LearnCalendar.route(.modules), .modules)

        let r = UFRouter()
        r.go(.plan(view: "day", date: "2026-11-20"))
        XCTAssertEqual(r.route, .timetable(date: "2026-11-20"), "Menue, Suchtreffer, Karten")
        r.go(hash: "#/plan?view=week")
        XCTAssertEqual(r.route, .timetable(), "Link #/plan")
        r.go(.modules)
        r.go(hash: "#/tasks?date=2026-11-21")
        XCTAssertEqual(r.route, .timetable(date: "2026-11-21"), "Link #/tasks")
        r.replace(.plan(view: "month"))
        XCTAssertEqual(r.route, .timetable(), "ersetzen (nach dem Einstieg)")
        XCTAssertEqual(UFRouter(start: .plan(view: "week", date: "2026-11-05")).route, .timetable(date: "2026-11-05"), "erste Seite")
        // wiederhergestellte letzte Seite (Weitermachen wie zuvor): die Entscheidung nennt den Lernkalender, gezeigt wird der Stundenplan
        if case .route(let last) = ResumeDecision.decide(ResumeState.forRoute(.plan(view: "day")), documentExists: nil) {
            let resumed = UFRouter()
            resumed.go(last)
            XCTAssertEqual(resumed.route, .timetable())
        } else { XCTFail("letzte Seite") }
        // Zurueck fuehrt nie auf den Lernkalender
        r.go(.modules)
        r.goBack()
        XCTAssertEqual(r.route.navKey, "timetable")

        LearnCalendar.enabled = true
        let on = UFRouter()
        on.go(.plan(view: "day", date: "2026-11-20"))
        XCTAssertEqual(on.route, .plan(view: "day", date: "2026-11-20"), "mit Schalter an wie vorher")
    }

    /// Die Seite hinter der Route: auch wenn `.plan` doch ankaeme, steht dort der Stundenplan
    func testMainViewNeverShowsLearnCalendarPage() throws {
        let env = try hostWithEnvironment(MainView(), size: CGSize(width: 1180, height: 820))
        env.router.go(.plan())
        XCTAssertTrue(env.wait { env.router.route == .timetable() })
        env.pump(1)
        let l = env.labels()
        XCTAssertFalse(l.contains { $0.contains("Lernkalender") }, l.joined(separator: "\n"))
        XCTAssertTrue(l.contains { $0.contains("Stundenplan") }, l.joined(separator: "\n"))
    }

    // MARK: - Übersicht

    func testDashboardLineNamesNoLearningPackages() {
        XCTAssertEqual(String(DashboardTidy.summary(date: "Dienstag, 17. November", events: 0).characters), "Dienstag, 17. November")
        XCTAssertEqual(String(DashboardTidy.summary(date: "Dienstag, 17. November", events: 1).characters), "Dienstag, 17. November · heute 1 Uni-Termin")
        let two = String(DashboardTidy.summary(date: "Dienstag, 17. November", events: 2).characters)
        XCTAssertEqual(two, "Dienstag, 17. November · heute 2 Uni-Termine")
        for word in ["Lernpaket", "geplant", "nachzuholen", "neu planen"] { XCTAssertFalse(two.contains(word), word) }
    }

    func testDashboardModuleLineWithoutOpenTasks() {
        let exam: JSONValue = ["open_tasks": 4, "exam_date": "2027-02-08"]
        XCTAssertFalse(DashboardView.moduleSub(exam).contains("offen"))
        XCTAssertTrue(DashboardView.moduleSub(exam).hasPrefix("Klausur "))
        XCTAssertEqual(DashboardView.moduleSub(["open_tasks": 4]), "kein Termin in Sicht")
        XCTAssertTrue(DashboardView.moduleSub(exam, planner: true).hasPrefix("4 offen · Klausur "), "mit Schalter an wie vorher")
        XCTAssertEqual(DashboardView.moduleSub(["open_tasks": 0], planner: true), "nichts offen")
    }

    // MARK: - Fragen, Suche, Texte

    func testSubjectsQuestionNeverAppears() {
        let overview: JSONValue = ["asked": false, "modules": [["name": "Analysis I", "planned": true]]]
        XCTAssertFalse(StudIPQuestionsHost.shouldAskPlan(overview), "„Was soll in den Lernkalender?“ erscheint nicht")
        XCTAssertTrue(StudIPQuestionsHost.shouldAskPlan(overview, planner: true), "mit Schalter an wie vorher")
    }

    func testSearchHasNoTaskHits() {
        let r: JSONValue = ["tasks": [["id": 7, "title": "Übungsblatt 3", "date": "2026-11-20", "subject": "Analysis I"]],
                            "pages": [["file_id": "f1", "page": 4, "name": "Skript"]]]
        let hits = ShellState.taskAndPageHits(r)
        XCTAssertEqual(hits.map(\.id), ["pf1-4"], "nur der Seitentreffer, keine Aufgabe des Lernplans")
        LearnCalendar.enabled = true
        XCTAssertEqual(ShellState.taskAndPageHits(r).map(\.id), ["t7", "pf1-4"], "mit Schalter an wie vorher")
    }

    func testTextsNameNoLearnCalendar() {
        let texts = [TimetableView.footHint, DemoTexts.confirmEnd, PlanPickerView.subtitle(proAI: true),
                     DatedEventDialog.text("2026-11-20", source: SOGo.source, cancelled: true),
                     DatedEventDialog.text("2026-11-20", source: SOGo.source),
                     DatedEventDialog.text("2026-11-20", source: "studip-sprechstunde"),
                     DatedEventDialog.text("2026-11-20", cancelled: true), DatedEventDialog.text("2026-11-20")]
            + IntroWelcomeText.words + IntroTourPage.shown.flatMap { [$0.title, $0.text] }
        for t in texts {
            for word in ["Lernkalender", "Lernplan", "Lernpaket", "Lernblock", "Lernblöcke", "Lernslot", "Smart Planner", "belegte Zeit", "planst du dein Lernen"] {
                XCTAssertFalse(t.contains(word), "\(word) in: \(t)")
            }
        }
        XCTAssertTrue(TimetableView.footHint.contains("Hinweise oben am Tag"))
    }

    // MARK: - Tarifkarten

    func testPlanCardsDoNotAdvertiseLearnCalendar() {
        for plan in UFPlan.allCases {
            XCTAssertFalse(UFFeatureMatrix.added(in: plan).contains(where: \.isLearnCalendar), "\(plan)")
            for row in UFPlanCard.included(plan) {
                for word in ["Lernkalender", "Lernplan", "Lernblöcke", "Lernslots"] {
                    XCTAssertFalse(row.title.contains(word) || (row.detail ?? "").contains(word), "\(plan): \(row.title)")
                }
            }
        }
        XCTAssertFalse(UFPlanCard.included(.free).isEmpty, "Free nennt weiter Stud.IP, Dokumente, Module und Stundenplan")
        XCTAssertTrue(UFPlanCard.included(.free).contains { $0.title == UFFeature.modulesTimetable.title })
        // Tarife selbst unveraendert: Rechte und Mindesttarife bleiben
        XCTAssertEqual(UFFeature.autoPlan.minimumPlan, .plus)
        XCTAssertEqual(UFFeature.studyCalendar.minimumPlan, .free)

        LearnCalendar.enabled = true
        XCTAssertTrue(UFFeatureMatrix.added(in: .free).contains(.studyCalendar), "mit Schalter an wie vorher")
        XCTAssertTrue(UFFeatureMatrix.added(in: .plus).contains(.autoPlan))
    }

    // MARK: - Einstieg

    func testIntroSkipsPlanPageAndSubjectsQuestion() {
        XCTAssertEqual(IntroTourPage.shown, [.uni, .exams, .notes], "Rundgang ohne „Ein Lernplan, der mitdenkt“")
        var m = IntroSetupModel()
        XCTAssertFalse(m.planSubjects)
        m.modules = [IntroSetupModule(moduleID: 1, name: "Analysis I", color: nil, planned: true)]
        XCTAssertEqual(m.shownSteps, [.name, .exams], "keine Frage nach Fächern für den Lernkalender")
        XCTAssertEqual(m.next(after: .name), .exams)
        XCTAssertEqual(m.next(after: .program), .exams)
        XCTAssertNil(m.answer(.modules))
        XCTAssertFalse(m.question(.ready).contains("Lernplan"), m.question(.ready))
        m.modules = []
        XCTAssertEqual(m.next(after: .name), .ready, "ohne Fächer gleich fertig")

        LearnCalendar.enabled = true
        XCTAssertEqual(IntroTourPage.shown, IntroTourPage.allCases, "mit Schalter an wie vorher")
        let on = IntroSetupModel()
        XCTAssertEqual(on.shownSteps, [.name, .modules, .exams])
        XCTAssertEqual(on.next(after: .name), .modules)
    }

    // MARK: - Kein automatisches Planen

    /// Die App haengt ihre Pruefung an den Kern (`UniFlowApp.init`): ohne Lernkalender plant weder der Abgleich noch das
    /// Oeffnen der App noch die Lernziele von selbst - auch nicht in Plus und Pro AI
    func testNothingIsPlannedAutomatically() {
        XCTAssertFalse(LearnCalendar.autoPlans(tariff: true))
        XCTAssertFalse(LearnCalendar.autoPlans(tariff: false))
        let plan = Entitlements.shared.plan
        defer { Entitlements.shared.setPlanForTesting(plan) }
        Entitlements.shared.setPlanForTesting(.proAI)
        XCTAssertFalse(StudyAutoPlan.allowed(), "nach dem Abgleich und beim Oeffnen wird nichts eingeordnet")
        XCTAssertFalse(SmartGoalsEndpoints.autoAllowed(), "Lernziele planen nicht von selbst um")

        LearnCalendar.enabled = true
        XCTAssertTrue(LearnCalendar.autoPlans(tariff: true))
        XCTAssertTrue(StudyAutoPlan.allowed(), "mit Schalter an wie vorher (ab Plus)")
        XCTAssertTrue(SmartGoalsEndpoints.autoAllowed())
        Entitlements.shared.setPlanForTesting(.free)
        XCTAssertFalse(StudyAutoPlan.allowed(), "Free plant auch mit Lernkalender von Hand")
    }

    // MARK: - Seitenleiste: Logo und Profilkarte

    private func button(_ env: HostedEnvironment, _ match: @escaping (NSObject) -> Bool) -> NSObject? { env.accessibleButton(where: match) }

    func testSidebarHasNoLearnCalendarAndNoSettingsRow() throws {
        Entitlements.shared.setPlanForTesting(.free)
        let env = try hostWithEnvironment(UFSidebar(collapsed: false, allowCollapse: true).frame(width: UF.sidebar), size: CGSize(width: 400, height: 1000))
        XCTAssertTrue(env.wait { env.labels().contains("Plus holen") }, env.labels().joined(separator: "\n"))
        let l = env.labels()
        XCTAssertFalse(l.contains("Lernkalender"), l.joined(separator: "\n"))
        XCTAssertTrue(l.contains("Stundenplan"))
        XCTAssertFalse(l.contains("Einstellungen"), "keine eigene Zeile „Einstellungen“ mehr: \(l)")
        XCTAssertTrue(l.contains("Einklappen"))
    }

    /// Antippen der Profilkarte (Männchen bzw. Initialen, Name, Tarif) oeffnet die Einstellungen; "Plus holen" bleibt
    /// ein eigener Knopf
    func testProfileCardOpensSettings() throws {
        Entitlements.shared.setPlanForTesting(.free)
        XCTAssertEqual(UFSidebarProfile.target, .settings(), "Startseite der Einstellungen")
        XCTAssertEqual(UFSidebarProfile.accessibilityHint, "Öffnet die Einstellungen")
        for collapsed in [false, true] {
            let env = try hostWithEnvironment(UFSidebar(collapsed: collapsed, allowCollapse: true).frame(width: collapsed ? UF.sidebarMin : UF.sidebar),
                                              size: CGSize(width: 400, height: 1000))
            XCTAssertTrue(env.wait { self.button(env) { ($0.accessibilityLabel ?? "").hasSuffix("Tarif Free") } != nil }, env.labels().joined(separator: "\n"))
            let profile = try XCTUnwrap(button(env) { ($0.accessibilityLabel ?? "").hasSuffix("Tarif Free") })
            XCTAssertEqual(profile.accessibilityHint, "Öffnet die Einstellungen", "eingeklappt: \(collapsed)")
            XCTAssertEqual(env.router.route, .dashboard)
            XCTAssertTrue(profile.accessibilityActivate())
            XCTAssertTrue(env.wait { env.router.route == .settings() }, "eingeklappt \(collapsed): \(env.router.route)")
            if !collapsed {
                // "Plus holen" oeffnet weiter die Tarife, nicht die Einstellungen der Karte
                env.router.go(.dashboard)
                XCTAssertTrue(env.activate("Plus holen"))
                XCTAssertTrue(env.wait { env.router.route == .settings(tab: "plan") }, "\(env.router.route)")
            }
        }
    }

    /// Logo und "StudiNow" oben in der Seitenleiste fuehren immer zur Übersicht, auch eingeklappt
    func testSidebarLogoLeadsToDashboard() throws {
        for collapsed in [false, true] {
            let env = try hostWithEnvironment(UFSidebar(collapsed: collapsed, allowCollapse: true).frame(width: collapsed ? UF.sidebarMin : UF.sidebar),
                                              size: CGSize(width: 400, height: 1000))
            env.router.go(.modules)
            XCTAssertTrue(env.wait { self.button(env) { $0.accessibilityLabel == "StudiNow, zur Übersicht" } != nil }, env.labels().joined(separator: "\n"))
            XCTAssertTrue(env.activate("StudiNow, zur Übersicht"))
            XCTAssertTrue(env.wait { env.router.route == .dashboard }, "eingeklappt \(collapsed): \(env.router.route)")
        }
    }

    /// Logo in der Werkzeugleiste des Editors: Tippen fuehrt zur Übersicht (derselbe Weg wie der fruehere Menueeintrag
    /// "Übersicht": `UFLogoMenuTargets.go`), die Bereiche bleiben ueber langes Druecken erreichbar - ohne Lernkalender
    func testEditorLogoLeadsToDashboard() throws {
        var went: [UFRoute] = []
        let items = UFNavItem.visible(local: true, gradesOnDevice: true, community: false).map { ($0.menuTitle, $0.route) }
        XCTAssertFalse(items.contains { $0.0 == "Lernkalender" })
        let targets = UFLogoMenuTargets(items: items.map { (title: $0.0, route: $0.1) }, go: { went.append($0) })
        let env = try hostWithEnvironment(UFLogoMenu().environment(\.ufLogoMenu, targets), size: CGSize(width: 300, height: 200))
        XCTAssertTrue(env.wait { self.button(env) { $0.accessibilityLabel == "Zur Übersicht" } != nil }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.activate("Zur Übersicht"))
        XCTAssertEqual(went, [.dashboard])
    }
}
