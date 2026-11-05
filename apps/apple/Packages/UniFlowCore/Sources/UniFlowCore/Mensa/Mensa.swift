import Foundation

/// Mensa (05.11.2026, docs/MENSA-2026-11-05.md): Speiseplaene der Mensen an LUH, Hochschule Hannover und Uni Hildesheim,
/// gleiche Regeln wie app/mensa.py. Quellen und Tabellen aus `MensaData` (erzeugt aus packages/shared-contracts/mensa.json).
/// Das iPad holt die oeffentlichen Plaene selbst (`LocalMensa`), ohne PC und ohne Konto.
public enum Mensa {
    public static let windowDays = 14
    public static let freshSeconds = 3 * 3600
    public static let keepPastDays = 7
    /// 2: mit Naehrwerten, Bestandteilen, Klima (aeltere Caches werden neu geholt)
    public static let cacheVersion = 2
    public static let userAgent = "StudiNow/1.0 (+https://studinow.app; support@studinow.app)"
    public static let roles: JSONValue = [["key": "student", "name": "Studierende"], ["key": "employee", "name": "Bedienstete"],
                                          ["key": "guest", "name": "Gäste"]]
    static let studifutterFields = "id,date,alias,price_student,price_employee,price_guest,foodoffer_category.alias,"
        + "foodoffer_category.sort,markings.markings_id.external_identifier,attribute_values.number_value,"
        + "attribute_values.string_value,attribute_values.food_attribute.external_identifier,"
        + "foodoffer_components.component_foodoffers_id.alias"
    public static let nutritionKeys = ["energy_kj", "energy_kcal", "fat", "saturated_fat", "carbohydrates", "sugar", "fiber", "protein", "salt"]

    /// Datendatei (gemeinsam mit Python)
    public static let data: JSONValue = (try? JSONValue.parse(MensaData.json)) ?? .object([:])

    // MARK: Mensen

    public static func canteen(_ id: String?) -> JSONValue? {
        data["canteens"]?.array?.first { $0["id"]?.string == id }
    }

    public static func publicCanteen(_ c: JSONValue, university: String? = nil) -> JSONValue {
        let kind = c["source"]?["kind"]?.string ?? ""
        let unis = c["universities"]?.array?.compactMap(\.string) ?? []
        return ["id": c["id"] ?? .null, "name": c["name"] ?? .null, "region": c["region"] ?? .null,
                "universities": .array(unis.map(JSONValue.string)), "own": .bool(university.map { unis.contains($0) } ?? false),
                "address": c["address"] ?? .null, "url": c["url"] ?? .null, "hours": c["hours"] ?? .array([]),
                "source": .string(kind), "source_name": data["sources"]?[kind]?["name"] ?? .null]
    }

    public static func defaultCanteen(university: String?) -> String {
        let u = data["universities"]?[university ?? ""] ?? data["universities"]?["luh"]
        return u?["default"]?.string ?? "hauptmensa"
    }

    /// Alle Mensen, zuerst die Region der eigenen Hochschule (eigene Mensen vorn), dann die uebrigen
    public static func canteensResponse(university: String?) -> JSONValue {
        let uni = (university.flatMap { data["universities"]?[$0] } != nil) ? university! : "luh"
        let region = data["universities"]?[uni]?["region"]?.string ?? "hannover"
        let all = data["canteens"]?.array ?? []
        let sorted = all.enumerated().sorted { a, b in
            func key(_ c: JSONValue, _ i: Int) -> (Int, Int, Int) {
                let unis = c["universities"]?.array?.compactMap(\.string) ?? []
                return (c["region"]?.string == region ? 0 : 1, unis.contains(uni) ? 0 : 1, i)
            }
            return key(a.element, a.offset) < key(b.element, b.offset)
        }.map(\.element)
        return ["university": .string(uni), "region": .string(region), "default": .string(defaultCanteen(university: uni)),
                "canteens": .array(sorted.map { publicCanteen($0, university: uni) }), "roles": roles,
                "labels": data["labels"] ?? .array([]), "allergens": data["allergens"] ?? .array([])]
    }

    // MARK: Abruf-Adressen

    static func quote(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Wie `source_url` in Python (gleiche Zeichenkette, MensaTests)
    public static func sourceURL(_ c: JSONValue, start: String, end: String, kind: String? = nil) -> String {
        let kind = kind ?? c["source"]?["kind"]?.string ?? ""
        let api = data["sources"]?[kind]?["api"]?.string ?? ""
        switch kind {
        case "studifutter":
            let id = c["source"]?["id"]?.string ?? ""
            let filter = #"{"_and":[{"canteen":{"_eq":"\#(id)"}},{"date":{"_between":["\#(start)","\#(end)"]}}]}"#
            let q = [("fields", studifutterFields), ("limit", "-1"), ("filter", filter)].map { "\($0.0)=\(quote($0.1))" }
            return api + "/items/foodoffers?" + q.joined(separator: "&")
        case "stwon":
            return api + "/locations/\(c["source"]?["id"]?.int ?? 0)/menu/\(start)/\(end)"
        default:
            return api + "/canteens/\(c["openmensa"]?.int ?? 0)/meals"
        }
    }

    // MARK: Vereinheitlichen

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
    }

    static func clean(_ v: JSONValue?) -> String {
        let s: String
        switch v {
        case .string(let x)?: s = x
        case .number(let n)?: s = n == n.rounded() ? String(Int(n)) : String(n)
        default: s = ""
        }
        return words(s).joined(separator: " ")
    }

    /// "VEGGIE & VEGAN" -> "Veggie & Vegan", "SÜSSE ECKE" -> "Süße Ecke"; gemischte Schreibung bleibt
    public static func prettyCategory(_ raw: String?) -> String {
        let s = words(raw ?? "").joined(separator: " ")
        guard !s.isEmpty, s == s.uppercased() else { return s }
        return s.split(separator: " ").map { w in String(w.prefix(1)).uppercased() + w.dropFirst().lowercased() }
            .joined(separator: " ").replacingOccurrences(of: "Süsse", with: "Süße")
    }

    static func price(_ v: JSONValue?) -> JSONValue {
        let d: Double?
        switch v {
        case .number(let n)?: d = n
        case .string(let s)?: d = Double(s.trimmingCharacters(in: .whitespaces))
        default: d = nil
        }
        guard let x = d else { return .null }
        let r = (x * 100).rounded() / 100
        return r > 0 ? .number(r) : .null
    }

    static func idString(_ v: JSONValue?, fallback: String) -> String {
        switch v {
        case .string(let s)? where !s.isEmpty: return s
        case .number(let n)? where n != 0: return n == n.rounded() ? String(Int(n)) : String(n)
        default: return fallback
        }
    }

    /// Zahl aus 2.7, "2,7 g" oder "13,2" (erste Zahl, Komma als Dezimalzeichen); sonst nil. Wie `_number` in Python.
    public static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)?: return (n * 100).rounded() / 100
        case .string(let s)?:
            guard let r = s.range(of: #"-?\d+(?:[.,]\d+)?"#, options: .regularExpression),
                  let d = Double(s[r].replacingOccurrences(of: ",", with: ".")) else { return nil }
            return (d * 100).rounded() / 100
        default: return nil
        }
    }

    /// Naehrwerte in fester Form; ohne einen einzigen Wert nil ("Keine Nährwertangaben vom Studentenwerk")
    static func nutrition(_ values: [String: Double], basis: String) -> JSONValue {
        guard nutritionKeys.contains(where: { values[$0] != nil }) else { return .null }
        var o: [String: JSONValue] = ["basis": .string(basis)]
        for k in nutritionKeys { o[k] = values[k].map(JSONValue.number) ?? .null }
        return .object(o)
    }

    static func finish(_ meal: inout [String: JSONValue], labels: Set<String>, nutrition: JSONValue = .null,
                       components: [String] = [], climate: JSONValue = .null) {
        meal["nutrition"] = nutrition
        meal["components"] = .array(components.map(JSONValue.string))
        meal["climate"] = climate
        var labels = labels
        if labels.contains("vegetarisch") { labels.remove("fisch") }
        let order = data["labels"]?.array?.compactMap { $0["key"]?.string } ?? []
        meal["labels"] = .array(order.filter(labels.contains).map(JSONValue.string))
        let side = Set(data["side_categories"]?.array?.compactMap(\.string) ?? [])
        meal["main"] = .bool(!side.contains((meal["category"]?.string ?? "").lowercased()))
    }

    static func addAllergen(_ out: inout [JSONValue], code: String, key: String, name: String) {
        if !out.contains(where: { $0["code"]?.string == code && $0["key"]?.string == key }) {
            out.append(["code": .string(code), "key": .string(key), "name": .string(name)])
        }
    }

    static func meal(id: String, name: String, category: String, time: String?, prices: JSONValue, allergens: [JSONValue],
                     additives: [JSONValue], notes: [String], labels: Set<String>, nutrition: JSONValue = .null,
                     components: [String] = [], climate: JSONValue = .null) -> JSONValue {
        var m: [String: JSONValue] = ["id": .string(id), "name": .string(name), "category": .string(category),
                                      "time": time.map(JSONValue.string) ?? .null, "prices": prices,
                                      "allergens": .array(allergens), "additives": .array(additives),
                                      "notes": .array(notes.map(JSONValue.string))]
        finish(&m, labels: labels, nutrition: nutrition, components: components, climate: climate)
        return .object(m)
    }

    static func result(_ days: [String: [JSONValue]], closed: [String] = []) -> JSONValue {
        ["days": .object(days.mapValues { .array($0) }), "closed": .array(closed.sorted().map(JSONValue.string))]
    }

    public static func parseStudifutter(_ raw: JSONValue) -> JSONValue {
        let table = data["studifutter_markings"]?.object ?? [:]
        let rows = raw["data"]?.array ?? raw.array ?? []
        var days: [String: [(Double, Int, JSONValue)]] = [:]
        for (i, o) in rows.enumerated() {
            let d = String((o["date"]?.string ?? "").prefix(10))
            let name = clean(o["alias"])
            if d.isEmpty || name.isEmpty { continue }
            let cat = o["foodoffer_category"]
            var labels = Set<String>(), allergens: [JSONValue] = [], additives: [JSONValue] = [], notes: [String] = []
            var klimateller = false
            for m in o["markings"]?.array ?? [] {
                let code = clean(m["markings_id"]?["external_identifier"])
                guard let t = table[code] else { continue }
                switch t["type"]?.string {
                case "label": labels.formUnion(t["keys"]?.array?.compactMap(\.string) ?? [])
                case "allergen":
                    addAllergen(&allergens, code: code, key: t["key"]?.string ?? "", name: t["name"]?.string ?? "")
                    if let l = t["label"]?.string { labels.insert(l) }
                case "additive": additives.append(["code": .string(code), "name": t["name"] ?? .null])
                case "climate": klimateller = true
                default:
                    let n = t["name"]?.string ?? ""
                    if !notes.contains(n) { notes.append(n) }
                }
            }
            let prices: JSONValue = ["student": price(o["price_student"]), "employee": price(o["price_employee"]),
                                     "guest": price(o["price_guest"])]
            let nmap = data["studifutter_nutrition"]?.object ?? [:]
            var values: [String: Double] = [:]
            var co2: Double?, rating: String?
            for a in o["attribute_values"]?.array ?? [] {
                let ext = a["food_attribute"]?["external_identifier"]?.string ?? ""
                let num = a["number_value"]?.double.flatMap { number(.number($0)) }
                if let key = nmap[ext]?.string, let num { values[key] = num }
                else if ext == "co2_g", let num, num > 0 { co2 = num }
                else if ext == "co2_rating", let sv = a["string_value"]?.string?.trimmingCharacters(in: .whitespaces), !sv.isEmpty { rating = sv }
            }
            let components = (o["foodoffer_components"]?.array ?? []).map { clean($0["component_foodoffers_id"]?["alias"]) }.filter { !$0.isEmpty }
            let climate: JSONValue = (co2 != nil || rating != nil || klimateller)
                ? ["co2_g": co2.map(JSONValue.number) ?? .null, "rating": rating.map(JSONValue.string) ?? .null, "klimateller": .bool(klimateller)]
                : .null
            let sort = cat?["sort"]?.double ?? 99
            days[d, default: []].append((sort, i, meal(id: idString(o["id"], fallback: "\(d)-\(i)"), name: name,
                                                        category: prettyCategory(cat?["alias"]?.string), time: nil, prices: prices,
                                                        allergens: allergens, additives: additives, notes: notes, labels: labels,
                                                        nutrition: nutrition(values, basis: "portion"), components: components,
                                                        climate: climate)))
        }
        return result(days.mapValues { $0.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2) })
    }

    static let times = ["morning": "frueh", "noon": "mittag", "evening": "abend"]

    static func stripDigits(_ s: String) -> String {
        var t = s
        while let last = t.last, last.isASCII, last.isNumber { t.removeLast() }
        return t
    }

    public static func parseStwon(_ raw: JSONValue) -> JSONValue {
        let cats = data["stwon_categories"]?.object ?? [:]
        let alls = data["stwon_allergens"]?.object ?? [:]
        let rank = ["frueh": 0, "mittag": 1, "abend": 2]
        var days: [String: [(Int, Int, JSONValue)]] = [:]
        for (i, o) in (raw["meals"]?.array ?? []).enumerated() {
            let d = String((o["date"]?.string ?? "").prefix(10))
            let name = clean(o["name"])
            if d.isEmpty || name.isEmpty { continue }
            let tags = o["tags"]
            var labels = Set<String>(), notes: [String] = []
            var klimateller = false
            let climateIDs = Set(data["stwon_climate"]?.array?.compactMap(\.string) ?? [])
            for c in tags?["categories"]?.array ?? [] {
                if climateIDs.contains((c["id"]?.string ?? "").uppercased()) {
                    klimateller = true
                } else if let id = c["id"]?.string, let keys = cats[id]?.array {
                    labels.formUnion(keys.compactMap(\.string))
                } else if let n = c["name"]?.string, !n.isEmpty, !notes.contains(n) {
                    notes.append(n)
                }
            }
            let rawAll = (tags?["allergens"]?.array ?? []).map { (clean($0["id"]), $0["name"]?.string ?? "") }
            let codes = Set(rawAll.map(\.0))
            var allergens: [JSONValue] = []
            for (code, aname) in rawAll {
                let base = stripDigits(code)
                guard let key = alls[base]?.string else { continue }
                if code == base && codes.contains(where: { $0 != code && stripDigits($0) == base }) { continue }
                let n = aname.hasPrefix(base + " ") ? String(aname.dropFirst(base.count + 1)) : aname
                addAllergen(&allergens, code: code, key: key, name: n.isEmpty ? code : n)
            }
            let additives: [JSONValue] = (tags?["additives"]?.array ?? []).map {
                ["code": .string(clean($0["id"])), "name": .string($0["name"]?.string ?? "")]
            }
            for s in tags?["special"]?.array ?? [] {
                let n = s["name"]?.string ?? ""
                if n.lowercased().contains("alkohol") { labels.insert("alkohol") }
                if !n.isEmpty && !notes.contains(n) { notes.append(n) }
            }
            if allergens.contains(where: { $0["key"]?.string == "fisch" }) { labels.insert("fisch") }
            let p = o["price"]
            let prices: JSONValue = ["student": price(p?["student"]), "employee": price(p?["employee"]), "guest": price(p?["guest"])]
            let time = times[o["time"]?.string ?? ""]
            let per100 = o["nutritional_values"]?["per_100_grams"]
            var values: [String: Double] = [:]
            for (k, v) in data["stwon_nutrition"]?.object ?? [:] { if let key = v.string, let n = number(per100?[k]) { values[key] = n } }
            let cal = per100?["caloric_value"]?.string ?? ""
            func energy(_ unit: String) -> Double? {
                guard let r = cal.range(of: #"(\d+(?:[.,]\d+)?)\s*"# + unit, options: .regularExpression) else { return nil }
                return number(.string(String(cal[r])))
            }
            values["energy_kj"] = energy("kJ")
            values["energy_kcal"] = energy("kcal")
            let parts = name.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let climate: JSONValue = klimateller ? ["co2_g": .null, "rating": .null, "klimateller": true] : .null
            days[d, default: []].append((rank[time ?? ""] ?? 1, i,
                                         meal(id: idString(o["id"], fallback: "\(d)-\(i)"), name: name,
                                              category: prettyCategory(o["lane"]?["name"]?.string), time: time, prices: prices,
                                              allergens: allergens, additives: additives, notes: notes, labels: labels,
                                              nutrition: nutrition(values, basis: "100g"), components: parts.count > 1 ? parts : [],
                                              climate: climate)))
        }
        return result(days.mapValues { $0.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2) })
    }

    public static func parseOpenMensa(_ raw: JSONValue) -> JSONValue {
        let rules = data["openmensa_notes"]?.array ?? []
        var names: [String: String] = [:]
        for a in data["allergens"]?.array ?? [] { if let k = a["key"]?.string { names[k] = a["name"]?.string ?? k } }
        var days: [String: [JSONValue]] = [:], closed: [String] = []
        for day in raw.array ?? [] {
            let d = String((day["date"]?.string ?? "").prefix(10))
            if d.isEmpty { continue }
            if day["closed"]?.bool == true { closed.append(d); continue }
            for (i, o) in (day["meals"]?.array ?? []).enumerated() {
                let name = clean(o["name"])
                if name.isEmpty { continue }
                var labels = Set<String>(), allergens: [JSONValue] = [], additives: [JSONValue] = [], notes: [String] = []
                for nv in o["notes"]?.array ?? [] {
                    let n = nv.string ?? clean(nv)
                    let low = n.lowercased()
                    var hit = false
                    for r in rules where low.contains(r["match"]?.string ?? "\u{0}") {
                        hit = true
                        labels.formUnion(r["label"]?.array?.compactMap(\.string) ?? [])
                        if let a = r["allergen"]?.string { addAllergen(&allergens, code: "", key: a, name: names[a] ?? a) }
                    }
                    if hit { continue }
                    if ["mit ", "geschw", "gewachst", "enthält eine phenylalaninquelle"].contains(where: { low.hasPrefix($0) }) {
                        additives.append(["code": "", "name": .string(n)])
                    } else if !notes.contains(n) {
                        notes.append(n)
                    }
                }
                let p = o["prices"]
                let prices: JSONValue = ["student": price(p?["students"]), "employee": price(p?["employees"]), "guest": price(p?["others"])]
                days[d, default: []].append(meal(id: idString(o["id"], fallback: "\(d)-\(i)"), name: name,
                                                 category: prettyCategory(o["category"]?.string), time: nil, prices: prices,
                                                 allergens: allergens, additives: additives, notes: notes, labels: labels))
            }
        }
        return result(days, closed: closed)
    }

    public static func parse(kind: String, raw: JSONValue) -> JSONValue {
        switch kind {
        case "studifutter": return parseStudifutter(raw)
        case "stwon": return parseStwon(raw)
        default: return parseOpenMensa(raw)
        }
    }

    // MARK: Tage

    /// open: Speisen da; closed: ausdruecklich zu oder Luecke vor spaeteren Tagen mit Plan (nur ab `since`); none: kein Plan
    public static func dayStatus(_ d: String, days: [String: JSONValue], closed: [String], since: String? = nil) -> String {
        if let m = days[d]?.array, !m.isEmpty { return "open" }
        if closed.contains(d) { return "closed" }
        if since.map({ d >= $0 }) ?? true, days.contains(where: { $0.key > d && !($0.value.array ?? []).isEmpty }) { return "closed" }
        return "none"
    }

    public static func addDays(_ iso: String, _ n: Int) -> String {
        BerlinClock.isoDate((BerlinClock.parseISODate(iso) ?? 0) + n)
    }

    public static func buildDays(start: String, count: Int, parsed: JSONValue, since: String? = nil) -> [JSONValue] {
        let days = parsed["days"]?.object ?? [:]
        let closed = parsed["closed"]?.array?.compactMap(\.string) ?? []
        return (0..<max(1, count)).map { i in
            let d = addDays(start, i)
            let st = dayStatus(d, days: days, closed: closed, since: since)
            return ["date": .string(d), "status": .string(st), "meals": st == "open" ? (days[d] ?? .array([])) : .array([])]
        }
    }

    // MARK: Filter und Auswahl (gleiche Regeln in app/mensa.py und mensa-logic.js)

    public struct Filter: Equatable, Sendable {
        public var vegan = false
        public var vegetarian = false
        public var noPork = false
        public var allergens: Set<String> = []
        public init(vegan: Bool = false, vegetarian: Bool = false, noPork: Bool = false, allergens: Set<String> = []) {
            self.vegan = vegan; self.vegetarian = vegetarian; self.noPork = noPork; self.allergens = allergens
        }
        public init(json: JSONValue) {
            vegan = json["vegan"]?.bool ?? false
            vegetarian = json["vegetarisch"]?.bool ?? false
            noPork = json["ohne_schwein"]?.bool ?? false
            allergens = Set(json["allergens"]?.array?.compactMap(\.string) ?? [])
        }
        public var isEmpty: Bool { !vegan && !vegetarian && !noPork && allergens.isEmpty }
    }

    public static func labels(_ meal: JSONValue) -> Set<String> { Set(meal["labels"]?.array?.compactMap(\.string) ?? []) }

    public static func matches(_ meal: JSONValue, _ f: Filter) -> Bool {
        let l = labels(meal)
        if f.vegan && !l.contains("vegan") { return false }
        if f.vegetarian && !l.contains("vegetarisch") { return false }
        if f.noPork && l.contains("schwein") { return false }
        if f.allergens.isEmpty { return true }
        return !(meal["allergens"]?.array ?? []).contains { f.allergens.contains($0["key"]?.string ?? "") }
    }

    public static func filter(_ meals: [JSONValue], _ f: Filter) -> [JSONValue] { meals.filter { matches($0, f) } }

    /// Karte "Heute in der Mensa": Hauptgerichte passend zum Filter, mittags vor abends
    public static func top(_ meals: [JSONValue], _ n: Int = 3, _ f: Filter = Filter()) -> [JSONValue] {
        let rank = ["frueh": 1, "mittag": 0, "abend": 2]
        let main = filter(meals, f).filter { $0["main"]?.bool == true }.enumerated()
        return main.sorted { a, b in
            let ra = rank[a.element["time"]?.string ?? ""] ?? 0, rb = rank[b.element["time"]?.string ?? ""] ?? 0
            return (ra, a.offset) < (rb, b.offset)
        }.prefix(n).map(\.element)
    }

    public static func price(_ meal: JSONValue, role: String) -> Double? {
        let r = ["student", "employee", "guest"].contains(role) ? role : "student"
        return meal["prices"]?[r]?.double
    }

    public static let sorts = ["line", "price", "kcal", "protein"]

    /// Reihenfolge der Liste: line (wie die Mensa), price (guenstig zuerst), kcal (wenig zuerst), protein (viel Eiweiss
    /// zuerst); ohne Angabe ans Ende, sonst stabil. Wie `sort_meals` in Python.
    public static func sort(_ meals: [JSONValue], by: String, role: String = "student") -> [JSONValue] {
        func val(_ m: JSONValue) -> Double? {
            switch by {
            case "price": return price(m, role: role)
            case "kcal": return m["nutrition"]?["energy_kcal"]?.double
            case "protein": return m["nutrition"]?["protein"]?.double.map { -$0 }
            default: return 0
            }
        }
        return meals.enumerated().map { (val($0.element), $0.offset, $0.element) }.sorted { a, b in
            if (a.0 == nil) != (b.0 == nil) { return b.0 == nil }
            if let x = a.0, let y = b.0, x != y { return x < y }
            return a.1 < b.1
        }.map(\.2)
    }

    // MARK: Cache

    public static func mergeCache(_ old: JSONValue?, parsed: JSONValue, start: String, end: String, source: String,
                                  today: String, nowISO: String, nowTS: Int) -> JSONValue {
        let keepFrom = addDays(today, -keepPastDays)
        var days: [String: JSONValue] = [:]
        for (d, v) in old?["days"]?.object ?? [:] where d >= keepFrom && !(start <= d && d <= end) { days[d] = v }
        var closed = (old?["closed"]?.array?.compactMap(\.string) ?? []).filter { $0 >= keepFrom && !(start <= $0 && $0 <= end) }
        for (d, v) in parsed["days"]?.object ?? [:] where start <= d && d <= end { days[d] = v }
        closed += (parsed["closed"]?.array?.compactMap(\.string) ?? []).filter { start <= $0 && $0 <= end }
        return ["v": .number(Double(cacheVersion)), "fetched_at": .string(nowISO), "fetched_ts": .number(Double(nowTS)), "window": [.string(start), .string(end)],
                "source": .string(source), "days": .object(days), "closed": .array(Set(closed).sorted().map(JSONValue.string))]
    }

    public static func isFresh(_ cache: JSONValue?, wantedStart: String, wantedEnd: String, today: String, nowTS: Int) -> Bool {
        guard let c = cache, c["v"]?.int == cacheVersion, let ts = c["fetched_ts"]?.int, let at = c["fetched_at"]?.string,
              let w = c["window"]?.array, w.count == 2, let ws = w[0].string, let we = w[1].string else { return false }
        return at.hasPrefix(today) && nowTS - ts < freshSeconds && ws <= wantedStart && wantedEnd <= we
    }
}
