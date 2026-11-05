import Foundation

/// Erfundener Speiseplan ohne Netz (App-Tests, Bildvergleiche): antwortet wie Studi|Futter bzw. die STW-ON-Mensa-API mit
/// vier Gerichten und zwei Beilagen an jedem Werktag ab heute (14 Tage), am Wochenende nichts. Nur Testdaten, keine
/// echten Preise.
public struct MensaDemoHTTP: MensaHTTP {
    let clock: UniFlowClock

    public init(clock: UniFlowClock = .system) { self.clock = clock }

    struct Dish { let name: String; let category: String; let student: Double; let marks: [String]; let tags: [String]; let allergens: [String] }

    static let dishes: [Dish] = [
        Dish(name: "Gemüse-Kichererbsen-Curry mit Reis", category: "VEGGIE & VEGAN", student: 2.5, marks: ["x", "q"], tags: ["VEGA"], allergens: []),
        Dish(name: "Spaghetti mit Tomatensoße und Hartkäse", category: "PASTA & FRIENDS", student: 2.9, marks: ["v", "20A", "26"], tags: ["VEGT"], allergens: ["GL1", "ML"]),
        Dish(name: "Hähnchenbrust mit Kräuterkartoffeln", category: "FLEISCH & MEER", student: 4.2, marks: ["g", "28"], tags: ["GEFL"], allergens: ["SL"]),
        Dish(name: "Schweineschnitzel mit Pommes frites", category: "EVERGREENS", student: 4.8, marks: ["s", "20A", "22"], tags: ["SCHW"], allergens: ["GL1", "EI"]),
        Dish(name: "Bunter Blattsalat", category: "QUERBEET", student: 0.9, marks: ["x"], tags: ["VEGA"], allergens: []),
        Dish(name: "Schokoladenpudding", category: "SÜSSE ECKE", student: 1.1, marks: ["v", "26"], tags: ["VEGT"], allergens: ["ML"]),
    ]

    func days() -> [String] {
        let today = clock.today
        return (0..<Mensa.windowDays).map { Mensa.addDays(today, $0) }.filter {
            let wd = BerlinClock.weekday(BerlinClock.parseISODate($0) ?? 0)
            return wd < 5
        }
    }

    public func get(_ url: String) async throws -> Data {
        var rows: [JSONValue] = []
        let stwon = url.hasPrefix(Mensa.data["sources"]?["stwon"]?["api"]?.string ?? "-")
        guard stwon || url.hasPrefix(Mensa.data["sources"]?["studifutter"]?["api"]?.string ?? "-") else { return Data("[]".utf8) }
        for (di, d) in days().enumerated() {
            for (i, x) in Self.dishes.enumerated() {
                let id = "demo-\(di)-\(i)"
                let employee = x.student < 2 ? x.student + 0.4 : x.student + 2
                let guest = x.student < 2 ? x.student + 0.6 : x.student + 3
                let kcal = [650.0, 720, 610, 980, 90, 240][i], protein = [18.0, 24, 41, 36, 2, 5][i]
                if stwon {
                    let lane = i < 4 ? "Essen \(i + 1)" : (i == 4 ? "Beilage" : "Dessert")
                    rows.append(["id": .string(id), "date": .string(d), "name": .string(x.name), "time": "noon",
                                 "lane": ["name": .string(lane)],
                                 "price": ["student": .string(String(format: "%.2f", x.student)), "employee": .string(String(format: "%.2f", employee)),
                                           "guest": .string(String(format: "%.2f", guest))],
                                 "tags": ["categories": .array(x.tags.map { ["id": .string($0), "name": .string($0)] }),
                                          "allergens": .array(x.allergens.map { ["id": .string($0), "name": .string($0)] }),
                                          "additives": [], "special": []],
                                 "nutritional_values": ["per_100_grams": ["caloric_value": .string("\(Int(kcal / 4 * 4.184)) kJ (\(Int(kcal / 4)) kcal)"),
                                                                          "fat": "4,0 g", "protein": .string(String(format: "%.1f g", protein / 4).replacingOccurrences(of: ".", with: ","))]]])
                } else {
                    rows.append(["id": .string(id), "date": .string(d), "alias": .string(x.name),
                                 "price_student": .number(x.student), "price_employee": .number(employee), "price_guest": .number(guest),
                                 "foodoffer_category": ["alias": .string(x.category), "sort": .number(Double(i))],
                                 "markings": .array(x.marks.map { ["markings_id": ["external_identifier": .string($0)]] }),
                                 "attribute_values": [["number_value": .number(kcal), "food_attribute": ["external_identifier": "calories_kcal"]],
                                                      ["number_value": .number(protein), "food_attribute": ["external_identifier": "protein_g"]]]])
                }
            }
        }
        let body: JSONValue = stwon ? ["announcements": [], "meals": .array(rows)] : ["data": .array(rows)]
        return body.serialized()
    }
}
