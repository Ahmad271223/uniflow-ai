import Foundation

/// Raumfinder (05.11.2026, docs/RAUMFINDER-2026-11-05.md): Raumangaben zerlegen, Treffer des Standortfinders der LUH
/// vereinheitlichen und auswaehlen, Kartenlinks bauen. Gleiche Regeln wie app/rooms.py (Faelle:
/// packages/shared-contracts/fixtures/rooms/cases.json). Daten aus `RoomsData` (erzeugt aus
/// packages/shared-contracts/rooms.json). Abruf und Cache: `LocalRooms`.
///
/// Google Maps bekommt nie etwas von selbst: hier entstehen nur Links (`maps`), die erst beim Antippen aufgehen.
public enum Rooms {
    public static let cacheDays = 30
    public static let missDays = 1
    public static let cacheMax = 500
    public static let maxParts = 4
    public static let maxQuery = 80
    public static let userAgent = "StudiNow/1.0 (+https://studinow.app; support@studinow.app)"

    /// Datendatei (gemeinsam mit Python)
    public static let data: JSONValue = (try? JSONValue.parse(RoomsData.json)) ?? .object([:])

    static let offline = "Keine Verbindung zum Standortfinder. Du siehst den zuletzt geladenen Stand."
    static let offlineEmpty = "Der Standortfinder ist gerade nicht erreichbar. Der Link sucht stattdessen nach dem Text in Google Maps."

    public static var source: JSONValue {
        let sf = data["standortfinder"]
        return ["key": "standortfinder", "name": sf?["name"] ?? .null, "url": sf?["url"] ?? .null,
                "attribution": sf?["attribution"] ?? .null]
    }

    static func js(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }

    // MARK: Text wie Python

    /// `" ".join(s.split())`
    static func words(_ s: String) -> String {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if PyText.isSpace(u) {
                if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
            } else {
                cur.append(u)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out.joined(separator: " ")
    }

    /// `_s(v)`: Text eines Felds, Leerraum zusammengefasst; null -> ""
    static func str(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return words(s)
        case .number(let n)?: return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b)?: return b ? "True" : "False"
        default: return ""
        }
    }

    static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    static func https(_ v: JSONValue?) -> String? {
        let s = str(v)
        return s.hasPrefix("https://") ? s : nil
    }

    static func prefix(_ s: String, _ n: Int) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.unicodeScalars.prefix(n))
        return String(v)
    }

    // MARK: Links zu Karten

    /// Prozent-Kodierung aller Zeichen ausser A-Z a-z 0-9 - . _ ~
    public static func enc(_ s: String) -> String { PyText.quote(s, safe: "") }

    /// 52.38255 -> "52.38255", 52.38 -> "52.38" (hoechstens 6 Nachkommastellen)
    public static func coord(_ x: Double) -> String {
        var s = String(format: "%.6f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Links fuer Google Maps (Web und App) und Apple Karten. Mit Koordinaten: Ziel "lat,lon", sonst der Suchtext.
    public static func maps(_ query: String, label: String? = nil, lat: Double? = nil, lon: Double? = nil) -> JSONValue {
        let q: String
        let apple: String
        if let lat, let lon {
            q = "\(coord(lat)),\(coord(lon))"
            apple = "https://maps.apple.com/?q=\(enc(label ?? q))&ll=\(enc(q))"
        } else {
            q = words(query)
            apple = "https://maps.apple.com/?q=\(enc(q))"
        }
        return ["query": .string(q),
                "google": .string("https://www.google.com/maps/search/?api=1&query=\(enc(q))"),
                "google_route": .string("https://www.google.com/maps/dir/?api=1&destination=\(enc(q))&travelmode=walking"),
                "google_app": .string("comgooglemaps://?q=\(enc(q))"),
                "google_app_route": .string("comgooglemaps://?daddr=\(enc(q))&directionsmode=walking"),
                "apple": .string(apple),
                "apple_route": .string("https://maps.apple.com/?daddr=\(enc(q))&dirflg=w")]
    }

    // MARK: Treffer vereinheitlichen

    static let floorPattern = PyRegex(#"^(-?)0*(\d+)$"#)

    /// "000" -> "Erdgeschoss", "001" -> "1. Obergeschoss", "-01" -> "1. Untergeschoss", sonst "Etage X"
    public static func floorLabel(_ f: String?) -> String? {
        let s = words(f ?? "")
        guard !s.isEmpty else { return nil }
        guard let m = floorPattern.search(s), let n = Int(m.group(2) ?? "") else { return "Etage \(s)" }
        if n == 0 { return "Erdgeschoss" }
        return m.group(1) == "-" ? "\(n). Untergeschoss" : "\(n). Obergeschoss"
    }

    static func address(_ item: JSONValue) -> JSONValue {
        let street = str(item["street"]), no = str(item["house_number"]), zip = str(item["zip_code"]), city = str(item["city"])
        guard !street.isEmpty else { return .null }
        let first = PyText.strip("\(street) \(no)"), second = PyText.strip("\(zip) \(city)")
        return ["street": .string(street), "house_number": .string(no), "zip": .string(zip), "city": .string(city),
                "line": .string([first, second].filter { !$0.isEmpty }.joined(separator: ", "))]
    }

    static func bfRows(_ info: JSONValue?, _ kind: String) -> JSONValue {
        guard let info, info.object != nil else { return .array([]) }
        let table = data["accessibility"]
        var out: [JSONValue] = []
        for r in table?[kind]?.array ?? [] {
            let st: String? = r["status"]?.string.flatMap { key in table?["status"]?[str(info[key])]?.string }
            let text = nonEmpty(str(info[r["text"]?.string ?? ""]))
            if st != nil || text != nil {
                out.append(["key": r["key"] ?? .null, "title": r["title"] ?? .null, "status": js(st), "text": js(text)])
            }
        }
        return .array(out)
    }

    static func itemType(_ v: JSONValue?) -> String {
        if case .string(let s)? = v { return s == "lr01" ? "building" : "building" }
        switch v?.double {
        case 1: return "room"
        case 3: return "facility"
        default: return "building"
        }
    }

    /// Ein Treffer (Raum, Gebaeude, Einrichtung) in fester Form, mit Kartenlinks
    public static func place(_ item: JSONValue) -> JSONValue {
        let kind = itemType(item["item_type"])
        let room = nonEmpty(str(item["room_nr"])), bid = nonEmpty(str(item["building_id"]))
        let bname = nonEmpty(str(item["building_name"]))
        let rname = nonEmpty(str(item["room_name"])) ?? (kind == "room" ? nonEmpty(str(item["item_name"])) : nil)
        let floor = nonEmpty(str(item["floor_nr"]))
        let addr = address(item)
        let title: String
        var sub: [String?]
        let inBuilding: String? = bid.map { "Gebäude \($0)" + (bname.map { " (\($0))" } ?? "") }
        switch kind {
        case "room":
            title = "Raum \(room ?? "")" + (rname.map { " – \($0)" } ?? "")
            sub = [inBuilding, floorLabel(floor)]
        case "facility":
            title = nonEmpty(str(item["item_name"])) ?? "Einrichtung"
            sub = [inBuilding, room.map { "Raum \($0)" }]
        default:
            title = bid.map { "Gebäude \($0)" + (bname.map { " – \($0)" } ?? "") } ?? (bname ?? nonEmpty(str(item["item_name"])) ?? "Gebäude")
            sub = []
        }
        sub.append(addr["line"]?.string)
        let lat = item["lat"]?.double, lon = item["lon"]?.double
        let has = lat != nil && lon != nil
        let ok = (item["is_position_correct"].map(truthy) ?? false) && has
        let fallback = data["universities"]?["luh"]?["fallback"]?.string ?? "Leibniz Universität Hannover"
        let m = ok ? maps("", label: title, lat: lat, lon: lon)
            : maps(addr["line"]?.string ?? "\(title), \(fallback)", label: title)
        let extra = item["extra_info"]?.object != nil ? item["extra_info"]! : .object([:])
        let id = nonEmpty(str(item["item_id"])) ?? nonEmpty(str(item["room_id"])) ?? bid ?? title
        return ["id": .string(id), "type": .string(kind), "title": .string(title),
                "subtitle": .string(sub.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")),
                "room": js(room), "room_name": js(rname), "building": js(bid), "building_name": js(bname),
                "floor": js(floor), "floor_label": js(floorLabel(floor)), "address": addr,
                "lat": has ? .number(lat!) : .null, "lon": has ? .number(lon!) : .null, "position_ok": .bool(ok),
                "note": ok ? .null : (data["note_position"] ?? .null),
                "floorplan_url": js(https(item["room_floorplan_url"])), "room_url": js(https(item["room_url"])),
                "building_url": js(https(item["building_url"])), "website": js(https(extra["website_link"])),
                "opening_hours_url": js(https(extra["opening_hours_link"])), "description": js(nonEmpty(str(extra["description_de"]))),
                "accessibility": ["building": bfRows(item["bf_building_info"], "building"), "room": bfRows(item["bf_room_info"], "room")],
                "maps": m, "source": "standortfinder"]
    }

    /// `bool(v)` wie Python
    static func truthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// Standort einer Hochschule (Tabelle in rooms.json) in derselben Form wie ein Treffer
    public static func campusPlace(_ c: JSONValue, university: String) -> JSONValue {
        let u = data["universities"]?[university]
        let name = u?["name"]?.string ?? ""
        let line = c["address"]?.string ?? ""
        let lat = c["lat"]?.double, lon = c["lon"]?.double
        let has = lat != nil && lon != nil
        return ["id": .string("\(university):\(c["id"]?.string ?? "")"), "type": "campus", "title": c["name"] ?? .null,
                "subtitle": .string("\(name) · \(line)"), "room": .null, "room_name": .null, "building": .null,
                "building_name": .null, "floor": .null, "floor_label": .null,
                "address": ["street": "", "house_number": "", "zip": "", "city": "", "line": .string(line)],
                "lat": has ? .number(lat!) : .null, "lon": has ? .number(lon!) : .null, "position_ok": false,
                "note": data["note_campus"] ?? .null, "floorplan_url": .null, "room_url": .null, "building_url": .null,
                "website": .null, "opening_hours_url": .null, "description": .null,
                "accessibility": ["building": [], "room": []],
                "maps": maps("\(name), \(line)", label: c["name"]?.string), "source": "campus"]
    }

    // MARK: Raumangaben zerlegen

    static let roomID = PyRegex(#"(?<!\d)(\d{4})\.(\d{3})\.([A-Za-z]?\d{2,4}[A-Za-z]?)(?![\w.])"#)
    static let buildingRoom = PyRegex(#"(?<![\d.])(?!19\d\d|20\d\d)(\d{4})\s*(?:-|–|/|,)\s*(?:Raum\s+)?([A-Z]{1,2}\s?\d{2,3}[A-Z]?|\d{3})(?![\w.])"#)
    static let roomBuilding = PyRegex(#"(?<![\w.])([A-Z]{1,2}\s?\d{3}[A-Z]?)\s*\(\s*(?:Geb(?:äude|\.)?\s*)?(?!19\d\d|20\d\d)(\d{4})\s*\)"#)
    static let buildingWord = PyRegex(#"Geb(?:äude|\.)?\s*(\d{4})(?!\d)"#)
    static let roomCode = PyRegex(#"(?<![\w.])([A-Z]{1,2})\s?(\d{3})([A-Z]?)(?![\w.])"#)
    static let roomNumber = PyRegex(#"Raum\s+(\d{3})(?![\d.])"#)
    static let buildingAlone = PyRegex(#"(?<![\w.,:])(\d{4})(?![\w.,:])"#)
    static let buildingName = PyRegex(#"([A-ZÄÖÜ][\wäöüß-]*(?:gebäude|haus))(?![\wäöüß])"#)
    static let splitter = PyRegex(#"\s+·\s+|;|\s\|\s|\n"#)
    static let spaces = PyRegex(#"\s+"#)

    static func upper(_ s: String) -> String { spaces.sub(s, "").uppercased(with: Locale(identifier: "en_US_POSIX")) }

    static func containsWord(_ hay: String, _ word: String) -> Bool {
        PyRegex(#"(?<![\wäöüß])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\wäöüß])"#).found(in: hay)
    }

    static func isOnline(_ seg: String) -> Bool {
        let low = PyText.lower(seg)
        return (data["online_words"]?.array ?? []).contains { $0.string.map { containsWord(low, $0) } ?? false }
    }

    /// Teile einer Raumangabe ("A · B", "A; B", "A | B", Zeilen), hoechstens vier
    public static func segments(_ text: String?) -> [String] {
        let s = (text ?? "").replacingOccurrences(of: "\r", with: "\n")
        var parts: [String] = []
        var start = s.startIndex
        let ns = NSRange(s.startIndex..<s.endIndex, in: s)
        for m in splitter.regex.matches(in: s, options: [], range: ns) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(String(s[start..<r.lowerBound]))
            start = r.upperBound
        }
        parts.append(String(s[start...]))
        return Array(parts.map(words).filter { !$0.isEmpty }.prefix(maxParts))
    }

    static func findCampus(_ seg: String, university: String) -> String? {
        let low = PyText.lower(seg)
        for c in data["universities"]?[university]?["campuses"]?.array ?? [] {
            if (c["match"]?.array ?? []).contains(where: { $0.string.map { containsWord(low, $0) } ?? false }) { return c["id"]?.string }
            if let codes = c["codes"]?.string, PyRegex(codes).found(in: seg) { return c["id"]?.string }
        }
        return nil
    }

    /// Eine Raumangabe -> {text, room, building, building_name, floor, campus, online, query, linkable}
    public static func parseSegment(_ seg: String, university: String = "luh") -> JSONValue {
        var room: String?, building: String?, floor: String?, name: String?
        var online = isOnline(seg)
        var query: String?
        if university == "luh" {
            if let m = roomID.search(seg) {
                building = m.group(1); floor = m.group(2); room = m.group(3).map { $0.uppercased(with: Locale(identifier: "en_US_POSIX")) }
            } else if let m = buildingRoom.search(seg) {
                building = m.group(1); room = m.group(2).map(upper)
            } else if let m = roomBuilding.search(seg) {
                room = m.group(1).map(upper); building = m.group(2)
            } else {
                if let m = buildingWord.search(seg) { building = m.group(1) }
                if let m = roomCode.search(seg) {
                    room = (m.group(1) ?? "") + (m.group(2) ?? "") + (m.group(3) ?? "")
                } else if building != nil, let m = roomNumber.search(seg) {
                    room = m.group(1)
                }
                if building == nil {
                    building = buildingAlone.findAll(seg).first { !["19", "20"].contains(String($0.prefix(2))) }
                }
            }
            let low = PyText.lower(seg)
            for b in data["luh_buildings"]?.array ?? [] {
                guard let n = b["name"]?.string, containsWord(low, PyText.lower(n)) else { continue }
                name = n
                building = building ?? b["id"]?.string
                break
            }
            if name == nil, let m = buildingName.search(seg) { name = m.group(1) }
            query = room ?? building ?? name
        }
        let campus = findCampus(seg, university: university)
        var linkable = !online && (university == "luh" ? query != nil : !seg.isEmpty)
        if online && room != nil { online = false; linkable = true }
        return ["text": .string(seg), "room": js(room), "building": js(building), "building_name": js(name), "floor": js(floor),
                "campus": js(campus), "online": .bool(online), "query": js(query), "linkable": .bool(linkable)]
    }

    public static func knownUniversity(_ u: String?) -> String {
        if let u, data["universities"]?[u] != nil { return u }
        return "luh"
    }

    public static func parse(_ text: String?, university: String? = "luh") -> JSONValue {
        let uni = knownUniversity(university)
        let parts = segments(text).map { parseSegment($0, university: uni) }
        return ["text": .string(words(text ?? "")), "university": .string(uni), "parts": .array(parts),
                "linkable": .bool(parts.contains { $0["linkable"]?.bool == true })]
    }

    /// Fuer die App: lohnt ein Link? (nicht leer, nicht nur "online"); die Hochschule entscheidet der Aufloeser
    public static func mayLink(_ text: String?) -> Bool {
        segments(text).contains { !isOnline($0) || roomCode.found(in: $0) }
    }

    // MARK: Treffer auswaehlen

    /// Passende Treffer zu einer zerlegten Angabe -> (found|ambiguous|not_found, Treffer)
    public static func choose(_ part: JSONValue, _ items: [JSONValue]) -> (String, [JSONValue]) {
        let items = items.filter { $0.object != nil }
        var c: [JSONValue]
        if let room = part["room"]?.string {
            let want = upper(room)
            c = items.filter { upper(str($0["room_nr"])) == want }
            if let b = part["building"]?.string {
                c = c.filter { str($0["building_id"]) == b }
            } else if let n = part["building_name"]?.string {
                let low = PyText.lower(n)
                let f = c.filter { PyText.contains(PyText.lower(str($0["building_name"])), low) }
                c = f.isEmpty ? c : f
            }
            if let f = part["floor"]?.string {
                let x = c.filter { str($0["floor_nr"]) == f }
                c = x.isEmpty ? c : x
            }
        } else if let b = part["building"]?.string {
            c = items.filter { $0["item_type"]?.double == 2 && str($0["building_id"]) == b }
        } else if let n = part["building_name"]?.string {
            let low = PyText.lower(n)
            c = items.filter { low == PyText.lower(str($0["building_name"])) || low == PyText.lower(str($0["item_name"])) }
            if c.isEmpty {
                c = items.filter { PyText.contains(PyText.lower(str($0["building_name"]) + " " + str($0["item_name"])), low) }
            }
        } else {
            c = []
        }
        return (c.count == 1 ? "found" : c.isEmpty ? "not_found" : "ambiguous", c)
    }

    static func fallback(_ part: JSONValue, university: String) -> JSONValue {
        let f = data["universities"]?[university]?["fallback"]?.string ?? ""
        let text = part["text"]?.string ?? ""
        return maps("\(f) \(text)", label: text)
    }

    /// Antwort von GET /api/rooms/campuses: Standorte der Hochschule mit Kartenlinks
    public static func campuses(university: String?) -> JSONValue {
        let uni = knownUniversity(university)
        let u = data["universities"]?[uni]
        let finder = u?["finder"].map(truthy) ?? false
        return ["university": .string(uni), "name": u?["name"] ?? .null, "finder": .bool(finder),
                "campuses": .array((u?["campuses"]?.array ?? []).map { campusPlace($0, university: uni) }),
                "note": finder ? .null : (data["note_campus"] ?? .null), "source": source]
    }
}
