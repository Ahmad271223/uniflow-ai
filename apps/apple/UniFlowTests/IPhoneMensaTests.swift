import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Mensa auf dem iPhone (docs/IPHONE-2026-11-04.md, docs/MENSA-2026-11-05.md): Mensa-Wahl mit Stern und Heute/Morgen/
/// Woche in voller Breite, Gerichte in einer Spalte, Filter (Kennzeichen, Allergene, Preis, Sortierung) als Blatt von
/// unten, alle Angaben eines Gerichts als Blatt von unten (halb/ganz) mit Naehrwerten, Karte "Heute in der Mensa" mit
/// "Alle Gerichte" in voller Breite, Gruppe "Alltag" in der Liste "Mehr". Gegenprobe iPad: Leiste wie bisher, kein
/// Filterknopf. Daten: erfundener Plan (`MensaDemoHTTP`) ueber einen Schein-Transport, kein Netz.
final class IPhoneMensaTests: IPhoneLearnTestCase {

    override func setUp() {
        super.setUp()
        // gemerkte Mensa-Einstellungen des Simulators nicht anfassen
        let before = UserDefaults.standard.data(forKey: MensaPrefs.key)
        UserDefaults.standard.removeObject(forKey: MensaPrefs.key)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: MensaPrefs.key) }
    }

    /// Schein-Transport mit Mensaliste der LUH und dem erfundenen Plan von heute (an jedem Tag, an dem der Test laeuft)
    private func transport() throws -> Canned {
        let today = UFFmt.todayISO()
        let menu = try awaiting { () -> JSONValue in
            let m = LocalMensa()
            let clock = UniFlowClock.fixed(berlin: "\(today)T10:00:00")!
            m.configure(http: MensaDemoHTTP(clock: clock), folder: nil)
            return try await m.menu(canteen: "hauptmensa", day: today, days: 7, clock: clock)
        }
        let t = Canned()
        t.answer("/api/mensa/canteens", Mensa.canteensResponse(university: "luh"))
        t.answer("/api/mensa/menu", menu)
        return t
    }

    private func presentedFrame(_ env: HostedEnvironment) -> CGRect {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed,
              let v = p.presentationController?.presentedView ?? p.view else { return .null }
        return v.convert(v.bounds, to: nil)
    }

    private var openDay: Bool { !MensaUI.isWeekend(UFFmt.todayISO()) }

    // MARK: Seite

    /// Mensa-Wahl und Tage in voller Breite, "Filter" statt Chips und Auswahlfeldern, Gerichte untereinander in einer
    /// Spalte; auf 390, 402 und 440 pt ragt nichts ueber den Rand
    func testPageControlsFullWidthAndOneColumn() throws {
        let env = try hostPhone(MensaPage(), api: remote(try transport()))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, id: "mensa.picker") != nil && self.element(env, label: "Öffnungszeiten") != nil },
                      dump(env))
        let width = env.window.bounds.width
        let picker = frame(element(env, id: "mensa.picker"))
        XCTAssertGreaterThan(picker.width, width * 0.65, "Mensa-Wahl breit: \(picker)")
        let star = frame(element(env, id: "mensa.favorite"))
        XCTAssertEqual(star.midY, picker.midY, accuracy: 6, "Stern neben der Mensa-Wahl")
        // Heute/Morgen/Woche: drei gleich breite Felder in einer Reihe, mindestens 40 pt hoch
        let days = ["today", "tomorrow", "week"].map { frame(element(env, id: "mensa.mode.\($0)")) }
        XCTAssertEqual(Set(days.map { Int($0.minY.rounded()) }).count, 1, "eine Reihe: \(days)")
        XCTAssertEqual(days[0].width, days[2].width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(days[0].height, 39.5)
        XCTAssertGreaterThan(days[2].maxX - days[0].minX, width * 0.8, "volle Breite")
        XCTAssertTrue(element(env, id: "mensa.mode.today")?.accessibilityTraits.contains(.selected) == true)
        // Filter als Knopf (Blatt), keine Chips und Auswahlfelder auf der Seite
        XCTAssertNotNil(element(env, id: "mensa.filters"), dump(env))
        XCTAssertNil(element(env, id: "mensa.filter.vegan"), "Chips nur am iPad")
        XCTAssertNil(element(env, id: "mensa.role"))
        XCTAssertNil(element(env, id: "mensa.sort"))
        if openDay {
            XCTAssertTrue(env.wait { self.elements(env).filter { self.identifier($0) == "mensa.meal" }.count >= 2 }, dump(env))
            let meals = elements(env).filter { identifier($0) == "mensa.meal" }.map(frame)
            guard meals.count >= 2 else { return XCTFail("keine Gerichte") }
            XCTAssertEqual(Set(meals.map { Int($0.minX.rounded()) }).count, 1, "eine Spalte: \(meals)")
            XCTAssertGreaterThan(meals[0].width, width * 0.8)
            XCTAssertGreaterThan(meals[1].minY, meals[0].maxY - 1, "untereinander")
        }
        assertFitsOnAllPhones(env, "Mensa")
        shoot(env, "iphone-mensa")

        // Tag wechseln: "Woche" waehlt und laedt sieben Tage
        XCTAssertTrue(element(env, id: "mensa.mode.week")?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait { self.element(env, id: "mensa.mode.week")?.accessibilityTraits.contains(.selected) == true })
        assertFits(env, "Mensa Woche")
    }

    /// "Filter" oeffnet ein Blatt von unten (halb/ganz) mit Kennzeichen, Preis, Sortierung und Allergenen; "Fertig"
    /// schliesst es. Ein Gericht oeffnet alle Angaben als Blatt von unten mit Naehrwerten.
    func testFilterSheetAndMealDetailAsBottomSheets() throws {
        let env = try hostPhone(MensaPage(), api: remote(try transport()))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, id: "mensa.filters") != nil }, dump(env))
        XCTAssertTrue(element(env, id: "mensa.filters")?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetOpen(env) && self.element(env, label: "vegan") != nil }, dump(env))
        let sheet = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertEqual(Set(sheet.sheetPresentationController?.detents.map(\.identifier) ?? []), [.medium, .large], "halb und ganz")
        env.pump(0.6)
        XCTAssertGreaterThan(presentedFrame(env).minY, env.window.bounds.height * 0.3, "von unten, halb hoch")
        for text in ["vegetarisch", "ohne Schwein", "Preis für", "Sortieren"] {
            XCTAssertTrue(shows(env, text), "\(text) fehlt\n" + dump(env))
        }
        XCTAssertTrue(shows(env, "Allergene meiden") || shows(env, "ALLERGENE MEIDEN"), dump(env))
        assertFits(env, "Filterblatt")
        shoot(env, "iphone-mensa-filter")
        XCTAssertTrue(element(env, id: "mensa.sheet.done")?.accessibilityActivate() == true || tap(env, "Fertig"))
        XCTAssertTrue(env.wait { !self.sheetOpen(env) })

        guard openDay else { return }
        XCTAssertTrue(env.wait { self.button(env, "Gemüse-Kichererbsen-Curry", prefix: true) != nil }, dump(env))
        XCTAssertTrue(tap(env, "Gemüse-Kichererbsen-Curry", prefix: true))
        XCTAssertTrue(env.wait(timeout: 10) { self.sheetOpen(env) && self.shows(env, "Nährwerte") }, dump(env))
        let detail = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertEqual(Set(detail.sheetPresentationController?.detents.map(\.identifier) ?? []), [.medium, .large])
        for section in ["Preise", "Nährwerte", "Allergene", "Zusatzstoffe"] { XCTAssertTrue(shows(env, section), section) }
        assertFits(env, "Gericht")
        shoot(env, "iphone-mensa-gericht")
        dismissSheet(env)
    }

    /// iPad: Leiste wie bisher (Chips, Preis, Sortieren), kein Filterknopf und keine eigenen Tagesfelder
    func testPadKeepsToolbar() throws {
        let env = try hostPad(MensaPage(), api: remote(try transport()))
        XCTAssertTrue(env.wait(timeout: 15) { self.element(env, id: "mensa.filter.vegan") != nil }, dump(env))
        XCTAssertNotNil(element(env, id: "mensa.role"))
        XCTAssertNotNil(element(env, id: "mensa.sort"))
        XCTAssertNil(element(env, id: "mensa.filters"))
        XCTAssertNil(element(env, id: "mensa.mode.today"))
    }

    // MARK: Karte und Navigation

    /// "Heute in der Mensa": "Alle Gerichte" in voller Breite unter den Gerichten (iPhone), am iPad neben dem Titel
    func testDashboardCard() throws {
        guard openDay else { throw XCTSkip("Wochenende: keine Karte") }
        let api = remote(try transport())
        let env = try hostPhone(MensaTodayCard(api: api).padding(16), api: api)
        // die Kennung der Karte gilt fuer alle Elemente darin: Knopf ueber seinen Namen
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "Alle Gerichte") != nil }, dump(env))
        let all = frame(button(env, "Alle Gerichte"))
        XCTAssertGreaterThan(all.width, env.window.bounds.width * 0.7, "volle Breite: \(all)")
        let lastMeal = frame(elements(env).last { ($0.accessibilityLabel ?? "").contains("Menülinie") })
        XCTAssertGreaterThan(all.minY, lastMeal.minY, "unter den Gerichten")
        XCTAssertEqual(elements(env).filter { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == "Alle Gerichte" }.count, 1,
                       "nur der breite Knopf, keiner im Kopf")
        assertFitsOnAllPhones(env, "Mensa-Karte")

        let pad = try hostPad(MensaTodayCard(api: api).padding(16), api: api)
        XCTAssertTrue(pad.wait(timeout: 15) { self.element(pad, id: "mensa.dashboard") != nil }, dump(pad))
        XCTAssertTrue(pad.wait { self.button(pad, "Alle Gerichte") != nil })
        XCTAssertLessThan(frame(button(pad, "Alle Gerichte")).width, 200, "iPad: kleiner Knopf im Kopf wie bisher")
    }

    /// "Mehr" (iPhone): Bereiche in den Gruppen der Seitenleiste, "Alltag" mit der Mensa, Einstellungen am Ende
    func testMoreSheetGroupsWithEveryday() {
        let visible = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true)
        let more = UFNavItem.more(visible: visible)
        let grouped = UFMoreSheet.sections(more, grouped: true)
        let labels = grouped.compactMap(\.label)
        XCTAssertTrue(labels.contains("ALLTAG"), "\(labels)")
        let order = ["STUDIUM", "LERNEN", "ALLTAG", "GEMEINSAM"]
        XCTAssertEqual(labels, order.filter(labels.contains), "Reihenfolge der Seitenleiste")
        XCTAssertEqual(grouped.first { $0.id == "everyday" }?.items.map(\.id), ["mensa", "rooms"], "Raumfinder neben der Mensa")
        XCTAssertEqual(grouped.last?.items.map(\.id), ["settings"], "Einstellungen zuletzt, ohne Gruppe")
        XCTAssertNil(grouped.last?.label)
        XCTAssertEqual(grouped.flatMap(\.items).map(\.id).sorted(), more.map(\.id).sorted(), "nichts verloren")
        XCTAssertFalse(grouped.flatMap(\.items).contains { UFNavItem.mobile.map(\.id).contains($0.id) }, "nichts aus der unteren Leiste")
        // iPad (breit): eine Liste wie bisher
        let flat = UFMoreSheet.sections(more, grouped: false)
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].items.map(\.id), more.map(\.id))
    }

    /// Liste "Mehr" gerendert auf dem iPhone: Ueberschrift "ALLTAG" ueber der Mensa, nichts ragt ueber den Rand
    func testMoreSheetRendersEverydayGroup() throws {
        let visible = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true)
        let env = try hostPhone(UFMoreSheet(items: UFNavItem.more(visible: visible)) { _ in }, api: remote(Canned()))
        XCTAssertTrue(env.wait { self.element(env, id: "more.group.everyday") != nil }, dump(env))
        let head = frame(element(env, id: "more.group.everyday"))
        let mensa = frame(element(env, id: "more.mensa"))
        XCTAssertGreaterThan(mensa.minY, head.minY, "Mensa unter ALLTAG")
        XCTAssertEqual(element(env, id: "more.group.everyday")?.accessibilityLabel, "ALLTAG")
        XCTAssertNotNil(element(env, id: "more.settings"))
        assertFitsOnAllPhones(env, "Mehr")
    }
}
