import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Mensa auf dem iPad (05.11.2026, docs/MENSA-2026-11-05.md): Einstellungen (gemerkte Mensa, Favoriten, Preisgruppe,
/// Filter), Auswahlliste, Karte "Heute in der Mensa" (drei Hauptgerichte, nie am Wochenende oder an geschlossenen Tagen),
/// Kennzeichen, VoiceOver-Texte, Route und Menuepunkt. Daten: erfundener Plan (`MensaDemoHTTP`), nie Netz.
@MainActor
final class MensaAppTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "mensa.test.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func menu(day: String, clock: String) async throws -> JSONValue {
        let m = LocalMensa()
        let c = UniFlowClock.fixed(berlin: clock)!
        m.configure(http: MensaDemoHTTP(clock: c), folder: nil)
        return try await m.menu(canteen: "hauptmensa", day: day, days: 7, clock: c)
    }

    func testPrefsRoundTripAndChosenCanteen() {
        let d = defaults()
        var p = MensaPrefs.load(d)
        XCTAssertEqual(p, MensaPrefs())
        p.role = "guest"
        p.toggleFavorite("contine")
        p.vegan = true
        p.allergens = ["gluten"]
        p.save(d)
        let q = MensaPrefs.load(d)
        XCTAssertEqual(q, p)
        XCTAssertEqual(q.filter, Mensa.Filter(vegan: true, allergens: ["gluten"]))
        XCTAssertEqual(q.summary(names: ["gluten": "Gluten"]), "vegan · ohne Gluten")
        d.set(try? JSONEncoder().encode(MensaPrefs(role: "unsinn")), forKey: MensaPrefs.key)
        XCTAssertEqual(MensaPrefs.load(d).role, "student", "unbekannte Gruppe -> Studierende")

        let list = Mensa.canteensResponse(university: "hildesheim")
        XCTAssertEqual(MensaPrefs().chosen(in: list), "hi-uni", "Standard der Hochschule")
        XCTAssertEqual(MensaPrefs(favorites: ["contine"]).chosen(in: list), "contine", "erster Favorit")
        XCTAssertEqual(MensaPrefs(canteen: "hi-hohnsen", favorites: ["contine"]).chosen(in: list), "hi-hohnsen", "gemerkt")
        XCTAssertEqual(MensaPrefs(canteen: "weg").chosen(in: list), "hi-uni")
        XCTAssertEqual(MensaPrefs().chosen(in: Mensa.canteensResponse(university: "hsh")), "linden")
    }

    func testGroupsForPicker() {
        let g = MensaUI.groups(Mensa.canteensResponse(university: "luh"), favorites: ["hi-uni"])
        XCTAssertEqual(g.map(\.title), ["Favoriten", "Deine Hochschule", "Weitere in der Nähe", "Andere Orte"])
        XCTAssertEqual(g[0].items.compactMap { $0.s("id") }, ["hi-uni"])
        XCTAssertEqual(g[1].items.compactMap { $0.s("id") }, ["hauptmensa", "contine", "garbsen", "herrenhausen"])
        XCTAssertEqual(g[3].items.compactMap { $0.s("id") }, ["hi-buehler", "hi-hohnsen"])
    }

    func testDashboardCardRules() async throws {
        let thu = try await menu(day: "2026-11-05", clock: "2026-11-05T10:00:00")
        let top = MensaUI.dashboardMeals(menu: thu, today: "2026-11-05", prefs: MensaPrefs())
        XCTAssertEqual(top.count, 3)
        XCTAssertTrue(top.allSatisfy { $0["main"]?.bool == true }, "nur Hauptgerichte")
        let vegan = MensaUI.dashboardMeals(menu: thu, today: "2026-11-05", prefs: MensaPrefs(vegan: true))
        XCTAssertTrue(vegan.allSatisfy { Mensa.labels($0).contains("vegan") })
        let sat = try await menu(day: "2026-11-07", clock: "2026-11-07T10:00:00")
        XCTAssertTrue(MensaUI.dashboardMeals(menu: sat, today: "2026-11-07", prefs: MensaPrefs()).isEmpty, "Wochenende")
        XCTAssertEqual(sat.list("days").first?.s("status"), "closed")
        XCTAssertTrue(MensaUI.dashboardMeals(menu: nil, today: "2026-11-05", prefs: MensaPrefs()).isEmpty, "ohne Plan keine Karte")
    }

    func testTextsLabelsAndAccessibility() async throws {
        XCTAssertEqual(MensaUI.price(2.5), "2,50 €")
        XCTAssertEqual(MensaUI.price(nil), "–")
        XCTAssertEqual(MensaUI.statusText("closed"), "Geschlossen – an diesem Tag gibt es kein Essen.")
        XCTAssertEqual(MensaUI.dayLabel("2026-11-05", today: "2026-11-05"), "Heute")
        XCTAssertEqual(MensaUI.dayLabel("2026-11-06", today: "2026-11-05"), "Morgen")
        XCTAssertEqual(MensaUI.dayLabel("2026-11-09", today: "2026-11-05"), "Mo 9.11.")
        XCTAssertTrue(MensaUI.isWeekend("2026-11-08") && !MensaUI.isWeekend("2026-11-09"))
        let meals = try await menu(day: "2026-11-05", clock: "2026-11-05T10:00:00").list("days").first?.list("meals") ?? []
        let curry = try XCTUnwrap(meals.first)
        XCTAssertEqual(MensaUI.shownLabels(curry), ["vegan"], "vegetarisch neben vegan nicht doppelt")
        XCTAssertEqual(MensaUI.tone("vegan"), .ok)
        let schnitzel = try XCTUnwrap(meals.first { ($0.s("name") ?? "").hasPrefix("Schweineschnitzel") })
        XCTAssertEqual(MensaUI.shownLabels(schnitzel), ["schwein"], "Fleisch nur ohne Tierart")
        XCTAssertEqual(MensaUI.accessibility(schnitzel, role: "guest"), "Schweineschnitzel mit Pommes frites, 7,80 €, Schwein, Menülinie Evergreens")
    }

    func testRouteAndMenuEntry() {
        XCTAssertEqual(UFRoute.mensa.hash, "#/mensa")
        XCTAssertEqual(UFRoute(hash: "#/mensa"), .mensa)
        XCTAssertEqual(UFRoute.mensa.navKey, "mensa")
        let local = UFNavItem.visible(local: true, gradesOnDevice: false, community: false, flashcards: false)
        let item = try? XCTUnwrap(local.first { $0.id == "mensa" })
        XCTAssertEqual(item?.title, "Mensa")
        XCTAssertTrue(UFIconNames.all.contains("utensils"), "Symbol im Katalog")
        XCTAssertTrue(UFNavItem.active(item!, in: local, route: .mensa))
        XCTAssertEqual(UFNavGroup.groups(local).first { $0.id == "everyday" }?.label, "ALLTAG")
        XCTAssertTrue(UFNavItem.more(visible: local).contains { $0.id == "mensa" }, "in der unteren Leiste unter Mehr")
    }

    /// Wunsch des Inhabers 05.11.2026: Antippen zeigt alle Angaben, Liste sortierbar nach Preis, Kalorien, Eiweiss
    func testNutritionDetailAndSorting() async throws {
        let meals = try await menu(day: "2026-11-05", clock: "2026-11-05T10:00:00").list("days").first?.list("meals") ?? []
        XCTAssertEqual(MensaUI.sorts(for: meals), ["line", "price", "kcal", "protein"])
        let kcal = Mensa.sort(meals, by: "kcal").compactMap { $0["nutrition"]?["energy_kcal"]?.double }
        XCTAssertEqual(kcal, kcal.sorted())
        let curry = try XCTUnwrap(meals.first)
        XCTAssertEqual(MensaUI.nutritionShort(curry), "650 kcal · 18 g Eiweiß")
        XCTAssertEqual(MensaUI.nutritionRows(curry).map(\.label), ["Brennwert", "Eiweiß"])
        XCTAssertEqual(MensaUI.basisLabel(curry), "pro Portion")
        let none: JSONValue = ["name": "Suppe", "nutrition": .null, "labels": []]
        XCTAssertTrue(MensaUI.nutritionRows(none).isEmpty)
        XCTAssertEqual(MensaUI.noNutrition, "Keine Nährwertangaben vom Studentenwerk")
        XCTAssertEqual(MensaUI.sorts(for: [none]), ["line", "price"], "ohne Naehrwerte keine Sortierung nach Kalorien")
        let per100: JSONValue = ["nutrition": ["basis": "100g", "energy_kj": 388, "energy_kcal": 93, "protein": 3.3, "fat": 2.7, "saturated_fat": 0.2]]
        XCTAssertEqual(MensaUI.nutritionRows(per100).map(\.value), ["388 kJ / 93 kcal", "2,7 g", "0,2 g", "3,3 g"])
        XCTAssertEqual(MensaUI.nutritionRows(per100).map(\.sub), [false, false, true, false])
        XCTAssertEqual(MensaUI.basisLabel(per100), "pro 100 g")
        XCTAssertEqual(MensaUI.climateRows(["climate": ["co2_g": 2174, "rating": .null, "klimateller": true]]), ["KlimaTeller", "CO₂e 2.174 g pro Portion"])
        // aeltere gespeicherte Einstellungen ohne "sort" bleiben erhalten
        let d = defaults()
        d.set(Data(#"{"canteen":"contine","favorites":[],"role":"guest","vegan":false,"vegetarian":false,"noPork":true,"allergens":[]}"#.utf8), forKey: MensaPrefs.key)
        let p = MensaPrefs.load(d)
        XCTAssertEqual(p.canteen, "contine"); XCTAssertEqual(p.role, "guest"); XCTAssertTrue(p.noPork); XCTAssertEqual(p.sort, "line")
        // Detailblatt baut sich auf (alle Abschnitte)
        let host = UIHostingController(rootView: MensaMealDetail(meal: curry, canteen: "Hauptmensa", source: "Speiseplan: Test"))
        host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 900)
        host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }
}
