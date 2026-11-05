import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

// Audit der iPad-App vom 03.11.2026 (docs/AUDIT-APP-2026-11-03.md), Befunde 4-13 und Feinschliff: reine Funktionen
// hinter Fortschritt, "neu", Kacheln, Stundenplan-Spalten, Titeln ohne Wortbruch, "Mehr", Dunkelmodus, Leerzustaenden.
// Alle Daten sind erfunden.
@MainActor
final class AuditApp20261103Tests: XCTestCase {

    // MARK: 4 Fortschritt: eine Zaehlweise (Woche), keine "0 / 0"

    private func day(_ date: String, tasks: [String], events: [String] = []) -> JSONValue {
        ["date": .string(date),
         "packages": .array(tasks.isEmpty ? [] : [["tasks": .array(tasks.map { ["status": .string($0)] })]]),
         "events": .array(events.map { ["status": .string($0)] })]
    }

    func testTaskProgressCountsLikeBackendAndHidesZero() {
        let p = UFTaskProgress.of(days: [day("2026-11-02", tasks: ["erledigt", "nachholen"]),
                                         day("2026-11-04", tasks: ["geplant", "uebersprungen", "in_bearbeitung"])])
        XCTAssertEqual(p.total, 5)
        XCTAssertEqual(p.done, 1)
        XCTAssertEqual(p.late, 1)
        XCTAssertEqual(p.skipped, 1)
        XCTAssertEqual(p.open, 2)
        XCTAssertEqual(p.text, "1 / 5")
        XCTAssertNil(UFTaskProgress.of(days: [day("2026-11-03", tasks: [])]).text, "ohne Aufgaben keine \"0 / 0\"")
        XCTAssertNil(UFTaskProgress.of(week: ["done": 0, "total": 0]).text)
        XCTAssertEqual(UFTaskProgress.of(week: ["done": 0, "total": 4]).text, "0 / 4", "Uebersicht: dieselbe Zahl wie \"Diese Woche\"")
    }

    func testPlanProgressUsesWeekOfShownDateInEveryView() throws {
        // Monat Nov. 2026 in ganzen Wochen (26.10.-6.12.); Aufgaben am Mo 2.11. und Fr 6.11., eine im Vormonat
        let days: [JSONValue] = [day("2026-10-27", tasks: ["geplant"]), day("2026-11-02", tasks: ["erledigt", "nachholen"]),
                                 day("2026-11-06", tasks: ["geplant"]), day("2026-11-10", tasks: ["geplant"])]
        let month: JSONValue = ["days": .array(days)]
        let date = try XCTUnwrap(Fmt.date("2026-11-03"))
        // Liste: gezeigter Zeitraum nur der Tag; Fortschritt trotzdem die Woche 2.-8.11.
        let list = PlanData(view: "list", date: date, start: date, end: date, module: "",
                            cal: ["days": [day("2026-11-03", tasks: [])]], open: [], modules: [], month: month)
        XCTAssertEqual(UFTaskProgress.of(days: list.weekDays(of: date)).text, "1 / 3")
        // Monat: gezeigter Zeitraum sechs Wochen; Fortschritt dieselbe Woche
        let monthView = PlanData(view: "month", date: date, start: date, end: date, module: "", cal: month, open: [], modules: [], month: nil)
        XCTAssertEqual(UFTaskProgress.of(days: monthView.weekDays(of: date)).text, "1 / 3")
        XCTAssertEqual(UFTaskProgress.weekLabel(monday: date, today: date), "diese Woche")
        XCTAssertEqual(UFTaskProgress.weekLabel(monday: try XCTUnwrap(Fmt.date("2026-11-10")), today: date), "Woche 9.–15. Nov.")
    }

    // MARK: 5 "neu": eine Definition

    func testNewFilesMeansNotSeenYet() {
        XCTAssertTrue(UFNewFiles.isNew(["seen_by_user": 0, "status": "gelesen"]))
        XCTAssertFalse(UFNewFiles.isNew(["seen_by_user": 1, "status": "neu"]), "geoeffnet/\"Gesehen\": nicht mehr neu")
        XCTAssertTrue(UFNewFiles.isNew(["status": "neu"]), "aelterer Server ohne seen_by_user: Lernstand")
        XCTAssertEqual(UFNewFiles.count([["seen_by_user": 0], ["seen_by_user": 1], ["seen_by_user": 0]]), 2)
        XCTAssertEqual(LocalLibrary.newFileSQL, "f.seen_by_user=0")
        XCTAssertEqual(UFSourceText.newFiles(.luh, demo: true), "Neue Dateien (Demo)")
        XCTAssertEqual(UFSourceText.newFiles(.luh, demo: false), "Neu aus Stud.IP")
    }

    // MARK: 6 Kachel "Stud.IP" nach echtem Stand

    func testServiceTileFollowsConnection() {
        XCTAssertEqual(ServicesPage.tileStatus(studip: .signedOut, hasSession: false), .open, "nicht verbunden: kein \"synchronisiert\"")
        XCTAssertEqual(ServicesPage.tileStatus(studip: .idle, hasSession: true), .badge("synchronisiert", .ok))
        XCTAssertEqual(ServicesPage.tileStatus(studip: .needsLogin, hasSession: true), .badge("Anmeldung nötig", .warn))
        XCTAssertEqual(ServicesPage.tileStatus(studip: .failed("x"), hasSession: false), .open)
        XCTAssertEqual(ServicesPage.tileStatus(learnweb: .notConnected), .open)
        XCTAssertEqual(ServicesPage.tileStatus(learnweb: .ok(Date())), .badge("synchronisiert", .ok))
    }

    // MARK: 7 Stundenplan-Woche passt hochkant

    private var week: [JSONValue] {
        (0..<7).map { ["date": .string("2026-11-0\($0 + 2)"), "weekday": .number(Double($0)), "events": []] }
    }

    func testTimetableFitsSevenDaysIn13InchPortrait() {
        // 13" hochkant: Inhalt ~784 pt, Raster 782 pt
        let r = TimetableColumns.layout(days: week, width: 782)
        XCTAssertEqual(r.shown.count, 7)
        XCTAssertTrue(r.hidden.isEmpty)
        XCTAssertEqual(r.axis, TimetableColumns.axisCompact)
        XCTAssertEqual(r.total, 782, "kein waagrechtes Scrollen")
        XCTAssertGreaterThanOrEqual(r.column, TimetableColumns.minColumn)
        // iPad mini hochkant ohne Seitenleiste
        XCTAssertEqual(TimetableColumns.layout(days: week, width: 699).shown.count, 7)
        // Querformat wie bisher: breite Achse
        XCTAssertEqual(TimetableColumns.layout(days: week, width: 1100).axis, TimetableColumns.axisWide)
    }

    func testTimetableHidesOnlyEmptyWeekendWhenTooNarrow() {
        var days = week
        days[5] = ["date": "2026-11-07", "weekday": 5, "events": [["title": "Blockseminar"]]]
        let r = TimetableColumns.layout(days: days, width: 520)
        XCTAssertEqual(r.hidden.compactMap { $0.i("weekday") }, [6], "Samstag mit Termin bleibt, Sonntag ohne geht")
        XCTAssertEqual(r.shown.count, 6)
        XCTAssertEqual(TimetableColumns.layout(days: week, width: 0).hidden.count, 0, "nicht gemessen: nichts ausblenden")
    }

    // MARK: 8 Titel ohne Umbruch mitten im Wort

    func testWordWrapTitleShrinksOrHyphenatesInsteadOfBreakingWords() {
        XCTAssertEqual(UFWordWrapText.words("Einführung in die Erziehungswissenschaft"), ["Einführung", "in", "die", "Erziehungswissenschaft"])
        XCTAssertEqual(UFWordWrapText.words("Mathe-Vorkurs Teil 1"), ["Mathe-", "Vorkurs", "Teil", "1"])
        let title = "Einführung in die Erziehungswissenschaft"
        let longest = UFTypeface.width("Erziehungswissenschaft", 17.92, 700)
        // passt: unveraendert
        XCTAssertEqual(UFWordWrapText.fit(title, base: 17.92, weight: 700, em: 0, width: longest + 10, minScale: 0.78).size, 17.92)
        // knapp zu schmal (Modulkarte 13" hochkant): etwas kleiner, Text unveraendert
        let tight = UFWordWrapText.fit(title, base: 17.92, weight: 700, em: 0, width: longest - 8, minScale: 0.78)
        XCTAssertLessThan(tight.size, 17.92)
        XCTAssertGreaterThanOrEqual(tight.size, 17.92 * 0.78)
        XCTAssertEqual(tight.text, title)
        XCTAssertLessThanOrEqual(UFTypeface.width("Erziehungswissenschaft", tight.size, 700), longest - 8)
        // viel zu schmal (grosse Schrift): Silbentrennung statt beliebiger Stelle
        let narrow = UFWordWrapText.fit(title, base: 17.92, weight: 700, em: 0, width: longest * 0.5, minScale: 0.78)
        XCTAssertTrue(narrow.text.contains("\u{00AD}"), narrow.text)
        XCTAssertEqual(narrow.text.replacingOccurrences(of: "\u{00AD}", with: ""), title)
        XCTAssertEqual(UFWordWrapText.fit(title, base: 17.92, weight: 700, em: 0, width: 0, minScale: 0.78).text, title, "nicht gemessen")
    }

    // MARK: 9 Verbinden ausserhalb der Uebersicht einzeilig

    func testCompactConnectTitle() {
        XCTAssertEqual(HildesheimSourcesBar.compactTitle([(.learnweb, .notConnected), (.lsf, .notConnected)]), "Learnweb und LSF nicht verbunden")
        XCTAssertEqual(HildesheimSourcesBar.compactTitle([(.lsf, .needsLogin)]), "LSF-Anmeldung abgelaufen")
        XCTAssertEqual(HildesheimSourcesBar.compactTitle([(.learnweb, .notConnected), (.lsf, .needsLogin)]),
                       "Learnweb nicht verbunden · LSF-Anmeldung abgelaufen")
    }

    // MARK: 10 "Mehr" in der unteren Leiste

    func testMoreListsRemainingAreasWithBadges() {
        let visible = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: false)
        let more = UFNavItem.more(visible: visible)
        XCTAssertEqual(more.map(\.title), ["Stundenplan", "Studienverlauf", "Karteikarten", "Uni & Noten", "Mensa", "Community", "Einstellungen"])
        XCTAssertEqual(UFNavItem.mobile.last?.title, "Mehr")
        XCTAssertTrue(UFMobileNav.moreActive(.timetable(), items: more))
        XCTAssertTrue(UFMobileNav.moreActive(.settings(), items: more))
        XCTAssertTrue(UFMobileNav.moreActive(.exams, items: more), "ohne KI fuehrt #/exams zu den Karteikarten")
        XCTAssertFalse(UFMobileNav.moreActive(.dashboard, items: more))
        XCTAssertEqual(UFMobileNav.moreBadge(["community": 2, "dashboard": 5], items: more), 2)
    }

    // MARK: 11 Dunkelmodus folgt dem System

    func testThemeDefaultsToSystem() {
        XCTAssertEqual(UFThemeMode.standard, .auto)
        XCTAssertNil(UFThemeMode.standard.scheme, "nil = wie das iPad")
        XCTAssertEqual(UFThemeMode.standardRaw, "auto")
        XCTAssertEqual(UFThemeMode.light.scheme, .light, "gewaehlte Einstellung bleibt")
    }

    // MARK: 12 Leerzustaende

    func testEmptyLibraryAndDayTexts() {
        XCTAssertTrue(LibraryEmptyCard.text(connected: false, source: "Learnweb").contains("Verbinde Learnweb"))
        XCTAssertTrue(LibraryEmptyCard.text(connected: true, source: "Stud.IP").contains("nach dem nächsten Abgleich"))
        XCTAssertTrue(PlanEmptyDay.text(freeMinutes: 90).contains("1 h 30 min freie Lernzeit"), PlanEmptyDay.text(freeMinutes: 90))
        XCTAssertTrue(PlanEmptyDay.text(freeMinutes: 0).contains("Verfügbarkeit"))
    }

    // MARK: 13 #/exams ohne KI

    func testExamsWithoutAIHighlightsCards() throws {
        let items = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: false)
        XCTAssertTrue(UFNavItem.active(UFNavItem.cards, in: items, route: .exams))
        let withAI = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: true)
        XCTAssertFalse(UFNavItem.active(UFNavItem.cards, in: withAI, route: .exams), "mit KI: \"Tests & Wiederholung\" markiert")
        // ChatGPT verbinden ist vorerst aus (0ad0319, "bald verfuegbar"): dann nennt der Text die StudiNow-KI in Pro AI
        XCTAssertTrue(UFNoServerContent.examsText.contains(ChatGPTLink.isEnabled ? "nur mit verbundenem ChatGPT" : "StudiNow-KI in StudiNow Pro AI"),
                      UFNoServerContent.examsText)
        XCTAssertTrue(UFNoServerContent.examsText.contains("eigenen Karteikarten"))
        // beide im Menue, Karteikarten angetippt: nur die Karteikarten leuchten (Rueckmeldung 04.11.2026)
        let exams = try XCTUnwrap(withAI.first { $0.id == "exams" })
        XCTAssertTrue(UFNavItem.active(UFNavItem.cards, in: withAI, route: .cards))
        XCTAssertFalse(UFNavItem.active(exams, in: withAI, route: .cards), "Tests & Wiederholung nicht mit markiert")
        XCTAssertTrue(UFNavItem.active(exams, in: withAI, route: .exams))
        XCTAssertFalse(UFNavItem.active(UFNavItem.cards, in: withAI, route: .exams))
        // am eigenen Server (nur "Tests & Wiederholung" im Menue) fuehrt die Karteikarten-Seite weiter darunter
        XCTAssertTrue(UFNavItem.active(exams, in: UFNavItem.main, route: .cards))
    }

    // MARK: Feinschliff: Demo-Texte

    func testDemoWordingHasNoUniversitySource() {
        XCTAssertTrue(ModuleCard.desc(courses: 2, moduleName: DemoContent.moduleName, filesSource: "Stud.IP").hasSuffix("aus den Demo-Inhalten."))
        XCTAssertEqual(ModuleCard.desc(courses: 1, moduleName: "Analysis", filesSource: "Learnweb"),
                       "Vorlesung, Übungen und Material – 1 Veranstaltung aus Learnweb.")
        XCTAssertEqual(DemoContent.flashcards.count, 5, "Frei üben in der Demo erlebbar")
    }

    // MARK: Wunsch des Inhabers: Uebersicht ausgewogen

    func testDashboardFlowBalancesColumns() {
        // Hauptspalte: Heute 300, Uni 0 (leer), Abgaben 500; Fluss: Termine 400, Neuigkeiten 450, Woche 200, Neu 200
        let heights: [CGFloat] = [300, 0, 500, 400, 450, 200, 200]
        let slots: [DashboardSlot] = [.main, .main, .main, .flow, .flow, .flow, .flow]
        let f = DashboardFlow.frames(width: 1000, slots: slots, twoColumns: true, spacing: 8, gutter: 16) { i, _ in heights[i] }
        let (lw, _) = DashboardFlow.widths(1000, gutter: 16)
        XCTAssertEqual(f[2].minX, 0, "Abgaben in der breiten Spalte")
        XCTAssertEqual(f[2].width, lw)
        XCTAssertEqual(f[2].minY, 308, "leere Karte ohne Abstand")
        XCTAssertGreaterThan(f[3].minX, 0, "Termine rechts (kuerzere Spalte)")
        let left = f.filter { $0.minX == 0 }.map(\.maxY).max() ?? 0
        let right = f.filter { $0.minX > 0 }.map(\.maxY).max() ?? 0
        XCTAssertLessThan(abs(left - right), 460, "beide Spalten enden etwa gleich")
        // schmal: eine Spalte in Reihenfolge
        let one = DashboardFlow.frames(width: 700, slots: slots, twoColumns: false, spacing: 8, gutter: 16) { i, _ in heights[i] }
        XCTAssertEqual(one.map(\.minX), Array(repeating: 0, count: 7))
        XCTAssertEqual(one[3].minY, 300 + 8 + 500 + 8)
    }
}
