import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Raumfinder der Universitaet Hildesheim (07.11.2026, Auftrag des Inhabers: Raumfinder wie fuer die LUH). Quelle ist der
// oeffentliche Raumplan im LSF (HIS-QIS/LSF, ohne Anmeldung; Aufbau in ~/Studora-Builds/hildesheim/RAUMPLAN-STRUKTUR-2026-11-07.md):
// - Raumsuche: GET rds?state=change&type=5&moduleParameter=raumPlanSearch&…&raum.stxt=<Text> -> "Ihre Auswahl war nicht
//   eindeutig" mit Links (raum.rgid) oder direkt der Belegungsplan eines Raums (h4-Link auf die Raum-Einzelansicht).
// - Raum-Einzelansicht (webInfoRaum): Gebaeude (k_gebaeude.gebid), Kurzbezeichnung, Stockwerk, Raumart. Die dort
//   genannten Raumadmin-Personen liest die App nie.
// - Gebaeude-Einzelansicht (buildingContainer): Campus, Adresse, OpenStreetMap-Marker (Koordinaten).
// - Belegungsplan (state=wplan, P.vx=lang) einer Woche: Termine mit Wochentag, Zeit, Rhythmus, Art; ohne Lehrpersonen.
// Adressen und Lage der 45 Gebaeude stehen fest in `HildesheimRoomsData` (aus dem LSF, Campus-Adresse von der Anfahrtsseite);
// so braucht ein Raumcode wie "HC.I.1.Hörsaal 1" keine Anfrage. Antworten in derselben Form wie der LUH-Raumfinder
// (`Rooms.place`): Ort mit Kartenlinks (`Rooms.maps`), die erst beim Antippen aufgehen. Alle Netzaufrufe laufen hier im
// Kern (`HildesheimRoomsHTTP`), Tests ersetzen sie durch nachgebaute Seiten (`HildesheimRoomsDemoHTTP`).

/// Seiten des LSF lesen (nur GET, ohne Anmeldung); Tests liefern feste Seiten
public protocol HildesheimRoomsHTTP: Sendable {
    func get(_ url: URL) async throws -> String
}

/// GET mit eigenem User-Agent, eigenen Cookies (nichts aus dem gemeinsamen Speicher) und 15 s Zeitlimit
public final class URLSessionHildesheimRoomsHTTP: HildesheimRoomsHTTP, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    public func get(_ url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Rooms.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RoomFinderHTTPError(status: status) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

public enum HildesheimRooms {
    public static let base = "https://lsf.uni-hildesheim.de/qisserver/rds"
    public static let name = "Raumplan im LSF der Universität Hildesheim"
    public static let attribution = "Lage: Raumplan (LSF) der Universität Hildesheim, Adressen laut LSF und Anfahrtsseite der Uni"
    public static let university = "hildesheim"
    public static let universityName = "Universität Hildesheim"
    /// Belegungsplaene aendern sich: nur kurz merken
    public static let planHours = 6
    public static let notFound = "Im Raumplan des LSF nicht gefunden; der Link sucht nach dem Text."
    static let offline = "Keine Verbindung zum LSF. Du siehst den zuletzt geladenen Stand."
    static let offlineEmpty = "Das LSF ist gerade nicht erreichbar. Der Link sucht stattdessen nach dem Text in Google Maps."
    static let noStreet = "Das LSF nennt für dieses Gebäude keine Straße; gezeigt wird die Adresse des Campus."
    static let noBuilding = "Gebäude nicht in der Gebäudeliste des LSF; der Link sucht nach dem Text."

    public static var source: JSONValue {
        ["key": "lsf", "name": .string(name), "url": .string(searchFormURL.absoluteString), "attribution": .string(attribution)]
    }

    // MARK: Adressen

    public static let searchFormURL = URL(string: base + "?state=change&type=5&moduleParameter=raumPlanSearch&nextdir=change&next=search.vm"
        + "&subdir=raum&clean=y&category=raumplan.search&topitem=facilities&subitem=reservations")!

    /// Raumsuche (wie das Formular per GET): Text in `raum.stxt`, Platzhalter `*` erlaubt
    public static func searchURL(_ term: String) -> URL {
        URL(string: base + "?state=change&type=5&moduleParameter=raumPlanSearch&nextdir=change&next=search.vm&subdir=raum"
            + "&topitem=facilities&subitem=reservations&purge=n&search_start=Suche+starten&raum.stxt=" + PyText.quote(term, safe: "", plus: true))!
    }

    /// Raum-Einzelansicht
    public static func roomURL(_ rgid: Int) -> URL {
        URL(string: base + "?state=verpublish&status=init&vmfile=no&moduleCall=webInfo&publishConfFile=webInfoRaum&publishSubDir=raum&keep=y&raum.rgid=\(rgid)")!
    }

    /// Gebaeude-Einzelansicht
    public static func buildingURL(_ gebid: Int) -> URL {
        URL(string: base + "?state=verpublish&publishContainer=buildingContainer&k_gebaeude.gebid=\(gebid)")!
    }

    /// Belegungsplan einer Woche ("45_2026") oder einer Ansicht ("-1" Vorlesungszeit), lange Fassung mit Zeiten
    public static func planURL(_ rgid: Int, week: String) -> URL {
        URL(string: base + "?state=wplan&raum.rgid=\(rgid)&week=\(PyText.quote(week, safe: ""))&act=Raum&pool=Raum&show=plan&P.vx=lang&fil=plu&P.subc=plan")!
    }

    /// Kalenderwoche fuer `week`: "45_2026" (ISO-Woche, Ortszeit Berlin)
    public static func weekKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let c = cal.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
        return "\(c.weekOfYear ?? 1)_\(c.yearForWeekOfYear ?? 1970)"
    }

    static let weekKeyPattern = PyRegex(#"^(?:-\d{1,3}|[1-9]\d?_\d{4})$"#)

    // MARK: Seiten lesen

    private static let tagRE = HText.regex("<[^>]+>")

    /// Sichtbarer Text eines HTML-Stuecks
    static func text(_ html: String) -> String {
        HText.collapse(QISParser.decodeEntities(HText.replace(tagRE, in: html, with: " ")).replacingOccurrences(of: "\u{A0}", with: " "))
    }

    /// Inhalt nach `<a name="lese">` (davor stehen Menue und Kopf), ohne den Abschnitt "Raumadmin" (Personen)
    static func content(_ html: String) -> String {
        var s = html
        if let r = s.range(of: "<a name=\"lese\">") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "name=\"raumverwalter\"") { s = String(s[..<r.lowerBound]) }
        return s
    }

    private static let choiceLinkRE = HText.regex(#"<a\b[^>]*\bhref="[^"]*raum\.rgid=(\d+)[^"]*idcol=raum\.rgid[^"]*"[^>]*>(.*?)</a>"#, [.dotMatchesLineSeparators])
    private static let planRoomRE = HText.regex(#"<h4>\s*<a\b[^>]*webInfoRaum[^>]*raum\.rgid=(\d+)[^>]*>(.*?)</a>"#, [.dotMatchesLineSeparators])

    public struct Hit: Equatable, Sendable {
        public let rgid: Int
        public let name: String
        public init(rgid: Int, name: String) { self.rgid = rgid; self.name = name }
    }

    /// Treffer der Raumsuche: die Auswahlliste ("nicht eindeutig"), sonst der eine Raum des Belegungsplans, sonst keiner
    public static func parseSearch(_ html: String) -> [Hit] {
        let c = content(html)
        var out: [Hit] = []
        var seen = Set<Int>()
        for m in choiceLinkRE.matches(in: c, range: NSRange(location: 0, length: (c as NSString).length)) {
            let ns = c as NSString
            guard let id = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let name = text(ns.substring(with: m.range(at: 2)))
            if !name.isEmpty, !seen.contains(id) { seen.insert(id); out.append(Hit(rgid: id, name: name)) }
        }
        if out.isEmpty, let m = HText.match(planRoomRE, c), let id = Int(m.groups[1] ?? ""), let name = m.groups[2].map(text), !name.isEmpty {
            out.append(Hit(rgid: id, name: name))
        }
        return out
    }

    private static let fieldRE = HText.regex(#"<th\b[^>]*class="mod"[^>]*>(.*?)</th>\s*<td\b[^>]*class="mod_n_basic"[^>]*>(.*?)</td>"#, [.dotMatchesLineSeparators])
    private static let gebidRE = HText.regex(#"k_gebaeude\.gebid=(\d+)"#)
    private static let markerRE = HText.regex(#"marker=(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#)
    private static let h1RE = HText.regex(#"<h1>(.*?)</h1>"#, [.dotMatchesLineSeparators])

    /// Beschriftung -> Wert der Grunddaten-Tabellen (`th.mod` / `td.mod_n_basic`), Text ohne Tags
    static func fields(_ c: String) -> [String: String] {
        var out: [String: String] = [:]
        let ns = c as NSString
        for m in fieldRE.matches(in: c, range: NSRange(location: 0, length: ns.length)) {
            let k = text(ns.substring(with: m.range(at: 1))), v = text(ns.substring(with: m.range(at: 2)))
            if !k.isEmpty, out[k] == nil { out[k] = v }
        }
        return out
    }

    public struct RoomInfo: Equatable, Sendable {
        public let rgid: Int
        public let name: String
        public let buildingName: String?
        public let gebid: Int?
        public let short: String?
        public let floor: String?
        public let kind: String?
    }

    /// Raum-Einzelansicht: Raum, Gebaeude (Name und Kennung), Kurzbezeichnung, Stockwerk, Raumart
    public static func parseRoom(_ html: String, rgid: Int) -> RoomInfo? {
        let c = content(html)
        let f = fields(c)
        guard let name = f["Raum"], !name.isEmpty else { return nil }
        let gebid = HText.match(gebidRE, c).flatMap { Int($0.groups[1] ?? "") }
        func opt(_ k: String) -> String? { f[k].flatMap { $0.isEmpty ? nil : $0 } }
        return RoomInfo(rgid: rgid, name: name, buildingName: opt("Gebäude"), gebid: gebid, short: opt("Kurzbezeichnung"),
                        floor: opt("Stockwerk"), kind: opt("Raumart"))
    }

    public struct BuildingInfo: Equatable, Sendable {
        public let gebid: Int
        public let name: String
        public let short: String?
        public let campus: String?
        public let street: String?
        public let zip: String?
        public let city: String?
        public let lat: Double?
        public let lon: Double?
    }

    /// Gebaeude-Einzelansicht: Name, Campus, Adresse und der OpenStreetMap-Marker (Lage)
    public static func parseBuilding(_ html: String, gebid: Int) -> BuildingInfo? {
        let c = content(html)
        let f = fields(c)
        guard let name = f["Gebäude"], !name.isEmpty else { return nil }
        func opt(_ k: String) -> String? { f[k].flatMap { $0.isEmpty ? nil : $0 } }
        var lat: Double?, lon: Double?
        if let m = HText.match(markerRE, html) { lat = Double(m.groups[1] ?? ""); lon = Double(m.groups[2] ?? "") }
        return BuildingInfo(gebid: gebid, name: name, short: opt("Kurzbezeichnung"), campus: opt("Campus"), street: opt("Straße"),
                            zip: opt("PLZ"), city: opt("Ort"), lat: lat, lon: lon)
    }

    public struct PlanEntry: Equatable, Sendable {
        public let weekday: Int          // 0 = Montag
        public let day: String
        public let start: String
        public let end: String
        public let title: String
        public let rhythm: String?
        public let kind: String?
        public let startDate: String?
        public let endDate: String?
    }

    public static let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    private static let cellRE = HText.regex(#"<td class="plan[567]"[^>]*>(.*?)</table>"#, [.dotMatchesLineSeparators])
    private static let titleRE = HText.regex(#"<a\b[^>]*\btitle="([^"]*)"[^>]*class="ver""#, [.dotMatchesLineSeparators])
    private static let noteRE = HText.regex(#"<td class="notiz">(.*?)</td>"#, [.dotMatchesLineSeparators])
    private static let timeRE = PyRegex(#"^(Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag)\s*,?\s*(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*(?:[cs]\.t\.)?\s*,?\s*(.*)$"#)
    private static let dateRE = PyRegex(#"^(Start|Ende)\s*:\s*(\d{1,2}\.\d{1,2}\.\d{4})$"#)
    private static let swsRE = PyRegex(#"^\d+(?:[.,]\d+)?\s*SWS$"#)

    /// "06.11.2026" -> "2026-11-06"
    static func isoDate(_ s: String) -> String? {
        let p = s.split(separator: ".").map(String.init)
        guard p.count == 3, let d = Int(p[0]), let m = Int(p[1]), let y = Int(p[2]), (1...31).contains(d), (1...12).contains(m) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Belegungsplan (lange Fassung): Termine mit Wochentag, Zeit, Rhythmus, Art, Start/Ende; Lehrpersonen und
    /// Einrichtungen bleiben weg. Sortiert nach Wochentag und Beginn.
    public static func parsePlan(_ html: String) -> (semester: String?, room: String?, entries: [PlanEntry]) {
        let c = content(html)
        let ns = c as NSString
        var semester: String?
        if let m = HText.match(h1RE, c), let t = m.groups[1].map(text), let r = t.range(of: "(") {
            semester = String(t[r.upperBound...]).replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
        }
        let room = HText.match(planRoomRE, c)?.groups[2].map(text)
        var out: [PlanEntry] = []
        for m in cellRE.matches(in: c, range: NSRange(location: 0, length: ns.length)) {
            let cell = ns.substring(with: m.range(at: 1))
            guard let t = HText.match(titleRE, cell)?.groups[1].map({ text($0) }), !t.isEmpty else { continue }
            var weekday: Int?, start = "", end = "", rhythm: String?, kind: String?, from: String?, to: String?
            for n in HText.allMatches(noteRE, cell) {
                let line = text(n)
                if let tm = timeRE.search(line) {
                    weekday = weekdays.firstIndex(of: tm.group(1) ?? "")
                    start = tm.group(2) ?? ""; end = tm.group(3) ?? ""
                    let r = PyText.strip(tm.group(4) ?? "", chars: " ,")
                    rhythm = r.isEmpty ? nil : r
                } else if let dm = dateRE.search(line) {
                    if dm.group(1) == "Start" { from = isoDate(dm.group(2) ?? "") } else { to = isoDate(dm.group(2) ?? "") }
                } else if line.hasPrefix("Zugeordnete Lehrpersonen") || line.hasPrefix("Einrichtung") || swsRE.found(in: line) || line.isEmpty {
                    continue
                } else if kind == nil {
                    kind = line
                }
            }
            guard let wd = weekday else { continue }
            out.append(PlanEntry(weekday: wd, day: weekdays[wd], start: pad(start), end: pad(end), title: t, rhythm: rhythm, kind: kind,
                                 startDate: from, endDate: to))
        }
        out.sort { ($0.weekday, $0.start, $0.title) < ($1.weekday, $1.start, $1.title) }
        return (semester, room, out)
    }

    /// "8:00" -> "08:00"
    static func pad(_ hm: String) -> String { hm.count == 4 ? "0" + hm : hm }

    public static func json(_ e: PlanEntry) -> JSONValue {
        ["weekday": .number(Double(e.weekday)), "day": .string(e.day), "start": .string(e.start), "end": .string(e.end),
         "title": .string(e.title), "rhythm": Rooms.js(e.rhythm), "kind": Rooms.js(e.kind),
         "start_date": Rooms.js(e.startDate), "end_date": Rooms.js(e.endDate)]
    }

    // MARK: Raumcodes

    public struct Code: Equatable, Sendable {
        public let text: String          // "HC.I.1.Hörsaal 1"
        public let prefix: String        // "HC.I" (Gebaeude) bzw. "SH" / "WL"
        public let floor: String?        // "1", "-1", "0"
        public let room: String?         // "Hörsaal 1", "08"
        public let description: String?  // aus den Klammern: "Hörsaal 4"
    }

    /// `<Campus>.<Gebäude>.<Etage>.<Raum>` (HC.I.1.Hörsaal 1, BC.LN.0.03, KC.48.0.04, HC.W2.0.07) und die Formen ohne
    /// Gebaeudeteil (SH.0.23, WL.2.01); der Raumteil endet vor " (", " -", Trennzeichen oder dem Ende
    private static let codeRE = PyRegex(#"(?<![A-Za-z0-9])([A-Z]{2})\.([A-Za-z]{1,2}\d?|\d{1,2}[A-Za-z]?)\.(-?\d)\.([^\s(;|·]+(?:\s(?![-(])[^\s(;|·]+)*)"#)
    private static let shortCodeRE = PyRegex(#"(?<![A-Za-z0-9])(SH|WL)\.(-?\d)\.(\d{2,3})(?![\w.])"#)
    private static let descRE = PyRegex(#"\(([^()]*)\)"#)

    public static func code(in text: String) -> Code? {
        let s = Rooms.words(text)
        if let m = codeRE.search(s) {
            let whole = m.group(0) ?? ""
            let rest = s.range(of: whole).map { String(s[$0.upperBound...]) } ?? ""
            return Code(text: whole, prefix: "\(m.group(1) ?? "").\(m.group(2) ?? "")", floor: m.group(3), room: m.group(4),
                        description: descRE.search(rest).flatMap { $0.group(1) }.map(Rooms.words).flatMap(Rooms.nonEmpty))
        }
        if let m = shortCodeRE.search(s) {
            let whole = m.group(0) ?? ""
            let rest = s.range(of: whole).map { String(s[$0.upperBound...]) } ?? ""
            return Code(text: whole, prefix: m.group(1) ?? "", floor: m.group(2), room: m.group(3),
                        description: descRE.search(rest).flatMap { $0.group(1) }.map(Rooms.words).flatMap(Rooms.nonEmpty))
        }
        return nil
    }

    public static func building(prefix: String) -> HildesheimBuilding? {
        let low = PyText.lower(prefix)
        return HildesheimRoomsData.buildings.first { b in b.codes.contains { PyText.lower($0) == low } }
    }

    public static func building(id: Int) -> HildesheimBuilding? { HildesheimRoomsData.buildings.first { $0.id == id } }

    /// Gebaeude mit diesem Namen im Text ("Gebäude I (Hauptcampus)", "Forum", "Hs 48 / Brauhaus" -> "Brauhaus")
    public static func building(named text: String) -> HildesheimBuilding? {
        let low = PyText.lower(Rooms.words(text))
        var best: (HildesheimBuilding, Int)?
        for b in HildesheimRoomsData.buildings where b.campusID != "extern" {
            let names = [b.name] + b.name.split(separator: "/").map { Rooms.words(String($0)) }.filter { !$0.hasPrefix("Hs ") }
            for n in names where PyText.length(n) >= 5 {
                let ln = PyText.lower(n)
                if Rooms.containsWord(low, ln), (best.map { PyText.length(ln) > $0.1 } ?? true) { best = (b, PyText.length(ln)) }
            }
        }
        return best?.0
    }

    // MARK: Orte

    static func addressJSON(street: String?, zip: String?, city: String?) -> JSONValue {
        let s = street ?? "", z = zip ?? "", c = city ?? ""
        guard !s.isEmpty || !c.isEmpty else { return .null }
        let second = [z, c].filter { !$0.isEmpty }.joined(separator: " ")
        return ["street": .string(s), "house_number": "", "zip": .string(z), "city": .string(c),
                "line": .string([s, second].filter { !$0.isEmpty }.joined(separator: ", "))]
    }

    static func campusID(_ campus: String?) -> String {
        switch PyText.lower(campus ?? "") {
        case "hauptcampus": return "hauptcampus"
        case "bühler-campus": return "buehler"
        case "samelson-campus": return "samelsonplatz"
        case "kulturcampus domäne marienburg": return "domaene"
        case "schützenallee-campus": return "schuetzenallee"
        case "außenstelle": return "aussenstelle"
        default: return "extern"
        }
    }

    /// Gebaeude aus der LSF-Seite in die feste Form (ohne Strasse: Adresse des Campus)
    public static func building(from info: BuildingInfo) -> HildesheimBuilding {
        if let b = building(id: info.gebid) { return b }
        let cid = campusID(info.campus)
        let campus = HildesheimRoomsData.campusAddress[cid]
        let street = info.street ?? campus?.street
        return HildesheimBuilding(id: info.gebid, name: info.name, short: info.short ?? "", campus: info.campus ?? "", campusID: cid,
                                  street: street, zip: info.zip ?? campus?.zip ?? "", city: info.city ?? campus?.city ?? "",
                                  lat: info.lat, lon: info.lon, codes: [], addressFromCampus: info.street == nil && campus != nil)
    }

    static func mapsFor(title: String, building: HildesheimBuilding?, fallbackText: String) -> JSONValue {
        if let b = building {
            if let lat = b.lat, let lon = b.lon { return Rooms.maps("", label: title, lat: lat, lon: lon) }
            if !b.addressLine.isEmpty { return Rooms.maps("\(b.addressLine)", label: title) }
        }
        return Rooms.maps("\(universityName) \(fallbackText)", label: title)
    }

    /// Ein Raum in der Form von `Rooms.place` (plus `rgid`, `gebid`, `campus`, `kind`)
    public static func roomPlace(name: String, rgid: Int?, info: RoomInfo? = nil, building: HildesheimBuilding?) -> JSONValue {
        let code = code(in: name)
        let codeText = code?.text ?? Rooms.words(name)
        let desc = code?.description ?? descRE.search(name).flatMap { $0.group(1) }.map(Rooms.words).flatMap(Rooms.nonEmpty)
        let title = "Raum \(codeText)" + (desc.map { " – \($0)" } ?? "")
        let floor = code?.floor ?? info?.floor.flatMap { PyRegex(#"-?\d+"#).search($0)?.group(0) }
        let floorLabel = Rooms.floorLabel(floor)
        let bName = building?.name ?? info?.buildingName
        let addr = building.map { addressJSON(street: $0.street, zip: $0.zip, city: $0.city) } ?? .null
        let hasPos = building?.lat != nil && building?.lon != nil
        let note: String? = building == nil ? noBuilding : (building?.addressFromCampus == true ? noStreet : nil)
        let sub = [bName, floorLabel, addr["line"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return ["id": .string(rgid.map { "lsf:\($0)" } ?? "lsf:\(codeText)"), "type": "room", "title": .string(title), "subtitle": .string(sub),
                "room": .string(codeText), "room_name": Rooms.js(desc), "building": building.map { JSONValue.string(String($0.id)) } ?? .null,
                "building_name": Rooms.js(bName), "floor": Rooms.js(floor), "floor_label": Rooms.js(floorLabel), "address": addr,
                "lat": building?.lat.map { JSONValue.number($0) } ?? .null, "lon": building?.lon.map { JSONValue.number($0) } ?? .null,
                "position_ok": .bool(hasPos), "note": Rooms.js(note), "floorplan_url": .null,
                "room_url": rgid.map { JSONValue.string(roomURL($0).absoluteString) } ?? .null,
                "building_url": building.map { JSONValue.string(buildingURL($0.id).absoluteString) } ?? .null,
                "website": .null, "opening_hours_url": .null, "description": .null,
                "accessibility": ["building": [], "room": []],
                "maps": mapsFor(title: title, building: building, fallbackText: codeText), "source": "lsf",
                "rgid": rgid.map { JSONValue.number(Double($0)) } ?? .null, "gebid": building.map { JSONValue.number(Double($0.id)) } ?? .null,
                "campus": Rooms.js(building?.campus), "kind": Rooms.js(info?.kind)]
    }

    /// Ein Gebaeude als Ort
    public static func buildingPlace(_ b: HildesheimBuilding) -> JSONValue {
        let addr = addressJSON(street: b.street, zip: b.zip, city: b.city)
        let sub = [b.campus, addr["line"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let hasPos = b.lat != nil && b.lon != nil
        return ["id": .string("lsf-building:\(b.id)"), "type": "building", "title": .string(b.name), "subtitle": .string(sub),
                "room": .null, "room_name": .null, "building": .string(String(b.id)), "building_name": .string(b.name),
                "floor": .null, "floor_label": .null, "address": addr,
                "lat": b.lat.map { JSONValue.number($0) } ?? .null, "lon": b.lon.map { JSONValue.number($0) } ?? .null, "position_ok": .bool(hasPos),
                "note": Rooms.js(b.addressFromCampus ? noStreet : nil), "floorplan_url": .null, "room_url": .null,
                "building_url": .string(buildingURL(b.id).absoluteString), "website": .null, "opening_hours_url": .null,
                "description": .null, "accessibility": ["building": [], "room": []],
                "maps": mapsFor(title: b.name, building: b, fallbackText: b.name), "source": "lsf",
                "rgid": .null, "gebid": .number(Double(b.id)), "campus": .string(b.campus), "kind": .null]
    }

    /// Reihenfolge der Standorte auf der Seite "Raumfinder": Hauptcampus zuerst, Aussenstellen zuletzt
    static let campusOrder = ["hauptcampus", "buehler", "samelsonplatz", "domaene", "schuetzenallee", "aussenstelle"]

    /// Alle Gebaeude (ohne "Externes Gebäude") fuer die Seite "Raumfinder", nach Campus (`campusOrder`) und Name
    public static func buildingPlaces() -> [JSONValue] {
        func rank(_ b: HildesheimBuilding) -> Int { campusOrder.firstIndex(of: b.campusID) ?? campusOrder.count }
        return HildesheimRoomsData.buildings.filter { $0.campusID != "extern" }
            .sorted { (rank($0), $0.name) < (rank($1), $1.name) }.map(buildingPlace)
    }
}

/// Raumfinder Hildesheim mit Cache: Suche, Raum, Gebaeude 30 Tage ("nichts gefunden" einen Tag), Belegung 6 Stunden;
/// Datei `hildesheim-cache.json` im Ordner des Raumfinders. Ohne Netz: alter Stand mit `stale` oder ein Suchlink.
public final class HildesheimRoomFinder: @unchecked Sendable {
    private let lock = NSLock()
    private let http: HildesheimRoomsHTTP
    private let folder: URL?
    private var memory: JSONValue = ["v": 1, "entries": [:]]

    public init(http: HildesheimRoomsHTTP, folder: URL?) {
        self.http = http
        self.folder = folder
    }

    // MARK: Cache (Ergebnisse als JSON, nie die Seiten)

    private var file: URL? { folder?.appendingPathComponent("hildesheim-cache.json") }

    private func readCache() -> JSONValue {
        if let f = file, let d = try? Data(contentsOf: f), let v = try? JSONValue.parse(d), v["v"]?.int == 1, v["entries"]?.object != nil {
            return v
        }
        return folder == nil ? lock.withLock { memory } : ["v": 1, "entries": [:]]
    }

    private func writeCache(_ value: JSONValue) {
        var value = value
        if let entries = value["entries"]?.object, entries.count > Rooms.cacheMax {
            let keep = entries.sorted { ($0.value["ts"]?.double ?? 0) > ($1.value["ts"]?.double ?? 0) }.prefix(Rooms.cacheMax)
            value["entries"] = .object(Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) }))
        }
        guard let folder, let f = file else { lock.withLock { memory = value }; return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? value.serialized(sortedKeys: true).write(to: f, options: .atomic)
    }

    /// Ergebnis aus dem Cache oder frisch geladen und geparst; (Wert, stale). `seconds`: Haltbarkeit eines Treffers,
    /// `missSeconds`: Haltbarkeit von "nichts" (`.null`)
    private func cached(_ key: String, url: URL, seconds: Int, missSeconds: Int, clock: UniFlowClock,
                        parse: (String) -> JSONValue) async -> (JSONValue?, Bool) {
        let nowTS = Int(clock.now.timeIntervalSince1970)
        let entry = readCache()["entries"]?[key]
        if let entry, let ts = entry["ts"]?.int, let data = entry["data"] {
            let ttl = data.isNull ? missSeconds : seconds
            if nowTS - ts < ttl { return (data, false) }
        }
        let html: String
        do { html = try await http.get(url) } catch { return (entry?["data"], true) }
        let data = parse(html)
        var cache = readCache()
        cache["entries"]?[key] = ["at": .string(clock.nowISO), "ts": .number(Double(nowTS)), "data": data]
        writeCache(cache)
        return (data, false)
    }

    private static let day = 86400

    func hits(_ term: String, clock: UniFlowClock) async -> ([HildesheimRooms.Hit]?, Bool) {
        let key = "search|\(PyText.lower(Rooms.words(term)))"
        let (v, stale) = await cached(key, url: HildesheimRooms.searchURL(term), seconds: Rooms.cacheDays * Self.day,
                                      missSeconds: Rooms.missDays * Self.day, clock: clock) { html in
            let h = HildesheimRooms.parseSearch(html)
            return h.isEmpty ? .null : .array(h.map { JSONValue.object(["rgid": .number(Double($0.rgid)), "name": .string($0.name)]) })
        }
        guard let v else { return (nil, stale) }
        let list = (v.array ?? []).compactMap { e -> HildesheimRooms.Hit? in
            guard let id = e["rgid"]?.int, let n = e["name"]?.string else { return nil }
            return HildesheimRooms.Hit(rgid: id, name: n)
        }
        return (list, stale)
    }

    func room(_ rgid: Int, clock: UniFlowClock) async -> (HildesheimRooms.RoomInfo?, Bool) {
        let (v, stale) = await cached("room|\(rgid)", url: HildesheimRooms.roomURL(rgid), seconds: Rooms.cacheDays * Self.day,
                                      missSeconds: Rooms.missDays * Self.day, clock: clock) { html in
            guard let r = HildesheimRooms.parseRoom(html, rgid: rgid) else { return .null }
            return ["name": .string(r.name), "building_name": Rooms.js(r.buildingName), "gebid": r.gebid.map { JSONValue.number(Double($0)) } ?? .null,
                    "short": Rooms.js(r.short), "floor": Rooms.js(r.floor), "kind": Rooms.js(r.kind)]
        }
        guard let v, let name = v["name"]?.string else { return (nil, stale) }
        return (HildesheimRooms.RoomInfo(rgid: rgid, name: name, buildingName: v["building_name"]?.string, gebid: v["gebid"]?.int,
                                         short: v["short"]?.string, floor: v["floor"]?.string, kind: v["kind"]?.string), stale)
    }

    func building(_ gebid: Int, clock: UniFlowClock) async -> (HildesheimBuilding?, Bool) {
        if let b = HildesheimRooms.building(id: gebid) { return (b, false) }
        let (v, stale) = await cached("building|\(gebid)", url: HildesheimRooms.buildingURL(gebid), seconds: Rooms.cacheDays * Self.day,
                                      missSeconds: Rooms.missDays * Self.day, clock: clock) { html in
            guard let b = HildesheimRooms.parseBuilding(html, gebid: gebid) else { return .null }
            return ["name": .string(b.name), "short": Rooms.js(b.short), "campus": Rooms.js(b.campus), "street": Rooms.js(b.street),
                    "zip": Rooms.js(b.zip), "city": Rooms.js(b.city), "lat": b.lat.map { JSONValue.number($0) } ?? .null, "lon": b.lon.map { JSONValue.number($0) } ?? .null]
        }
        guard let v, let name = v["name"]?.string else { return (nil, stale) }
        let info = HildesheimRooms.BuildingInfo(gebid: gebid, name: name, short: v["short"]?.string, campus: v["campus"]?.string,
                                                street: v["street"]?.string, zip: v["zip"]?.string, city: v["city"]?.string,
                                                lat: v["lat"]?.double, lon: v["lon"]?.double)
        return (HildesheimRooms.building(from: info), stale)
    }

    /// Ort eines Treffers: Gebaeude aus dem Raumcode (ohne Anfrage), sonst ueber Raum- und Gebaeudeseite
    func place(hit: HildesheimRooms.Hit, detail: Bool, clock: UniFlowClock) async -> (JSONValue, Bool) {
        var b = HildesheimRooms.code(in: hit.name).flatMap { HildesheimRooms.building(prefix: $0.prefix) }
        var info: HildesheimRooms.RoomInfo?
        var stale = false
        if detail || b == nil {
            let (r, s1) = await room(hit.rgid, clock: clock)
            info = r; stale = stale || s1
            if b == nil, let g = r?.gebid {
                let (bb, s2) = await building(g, clock: clock)
                b = bb; stale = stale || s2
            }
        }
        return (HildesheimRooms.roomPlace(name: info?.name ?? hit.name, rgid: hit.rgid, info: info, building: b), stale)
    }

    // MARK: Antworten

    /// Antwort von GET /api/rooms/search fuer Hildesheim (alle Treffer auf einer Seite)
    public func search(_ q: String?, page: Int, clock: UniFlowClock) async -> JSONValue {
        let term = Rooms.prefix(Rooms.words(q ?? ""), Rooms.maxQuery)
        var out: JSONValue = ["query": .string(term), "count": 0, "page": .number(Double(max(0, page))), "pages": 0, "items": [],
                              "stale": false, "message": .null, "source": HildesheimRooms.source]
        guard !term.isEmpty, page <= 0 else { return out }
        let (hits, stale) = await self.hits(term, clock: clock)
        guard let hits else {
            out["stale"] = true
            out["message"] = "Das LSF ist gerade nicht erreichbar. Versuche es später erneut."
            return out
        }
        var items: [JSONValue] = []
        for h in hits.prefix(100) {
            let (p, _) = await place(hit: h, detail: false, clock: clock)
            items.append(p)
        }
        // Gebaeude mit passendem Namen dazu (ohne Anfrage)
        if let b = HildesheimRooms.building(named: term) { items.insert(HildesheimRooms.buildingPlace(b), at: 0) }
        out["count"] = .number(Double(items.count))
        out["pages"] = .number(Double(items.isEmpty ? 0 : 1))
        out["items"] = .array(items)
        out["stale"] = .bool(stale)
        out["message"] = stale ? .string(HildesheimRooms.offline) : .null
        return out
    }

    /// Antwort von GET /api/rooms/place?rgid=: Raum mit Gebaeude, Etage, Raumart, Adresse (Raum- und Gebaeudeseite)
    public func place(rgid: Int, clock: UniFlowClock) async -> JSONValue {
        let (info, s1) = await room(rgid, clock: clock)
        guard let info else {
            return ["rgid": .number(Double(rgid)), "place": .null, "stale": .bool(s1),
                    "message": .string(s1 ? HildesheimRooms.offlineEmpty : "Raum nicht im LSF gefunden."), "source": HildesheimRooms.source]
        }
        var b = HildesheimRooms.code(in: info.name).flatMap { HildesheimRooms.building(prefix: $0.prefix) }
        var stale = s1
        if b == nil, let g = info.gebid {
            let (bb, s2) = await building(g, clock: clock)
            b = bb; stale = stale || s2
        }
        let p = HildesheimRooms.roomPlace(name: info.name, rgid: rgid, info: info, building: b)
        return ["rgid": .number(Double(rgid)), "place": p, "stale": .bool(stale),
                "message": stale ? .string(HildesheimRooms.offline) : .null, "source": HildesheimRooms.source]
    }

    /// Antwort von GET /api/rooms/plan?rgid=&week=: Belegung einer Woche ("45_2026", Standard: laufende Woche)
    public func plan(rgid: Int, week: String?, clock: UniFlowClock) async -> JSONValue {
        let w = (week.map(Rooms.words) ?? "").isEmpty ? HildesheimRooms.weekKey(clock.now) : Rooms.words(week ?? "")
        guard HildesheimRooms.weekKeyPattern.found(in: w) else {
            return ["rgid": .number(Double(rgid)), "week": .string(w), "semester": .null, "room": .null, "entries": [], "stale": false,
                    "message": "Ungültige Woche.", "source": HildesheimRooms.source]
        }
        let (v, stale) = await cached("plan|\(rgid)|\(w)", url: HildesheimRooms.planURL(rgid, week: w), seconds: HildesheimRooms.planHours * 3600,
                                      missSeconds: 3600, clock: clock) { html in
            let p = HildesheimRooms.parsePlan(html)
            guard p.room != nil else { return .null }
            return ["semester": Rooms.js(p.semester), "room": Rooms.js(p.room), "entries": .array(p.entries.map(HildesheimRooms.json))]
        }
        let data = (v?.isNull ?? true) ? nil : v
        return ["rgid": .number(Double(rgid)), "week": .string(w), "semester": data?["semester"] ?? .null, "room": data?["room"] ?? .null,
                "entries": data?["entries"] ?? [], "stale": .bool(stale),
                "message": stale ? .string(data == nil ? HildesheimRooms.offlineEmpty : HildesheimRooms.offline)
                    : (data == nil ? .string("Kein Belegungsplan für diesen Raum im LSF.") : .null),
                "source": HildesheimRooms.source]
    }

    /// Ein Teil einer Raumangabe (aus `Rooms.parseSegment`) aufloesen: Raumcode -> Gebaeudetabelle (ohne Anfrage), sonst
    /// Gebaeudename, sonst Suche im LSF, sonst Standort des Campus bzw. Suchlink
    public func resolvePart(_ part: JSONValue, clock: UniFlowClock) async -> (JSONValue, Bool) {
        var out = part
        out["status"] = "none"; out["place"] = .null; out["candidates"] = []; out["maps"] = .null; out["note"] = .null
        let text = part["text"]?.string ?? ""
        if part["online"]?.bool == true {
            out["status"] = "online"
            return (out, false)
        }
        func fallback() -> JSONValue { Rooms.maps("\(HildesheimRooms.universityName) \(text)", label: text) }
        func campusPlace() -> JSONValue? {
            guard let id = part["campus"]?.string,
                  let c = (Rooms.data["universities"]?["hildesheim"]?["campuses"]?.array ?? []).first(where: { $0["id"]?.string == id }) else { return nil }
            return Rooms.campusPlace(c, university: "hildesheim")
        }
        if let code = HildesheimRooms.code(in: text) {
            if let b = HildesheimRooms.building(prefix: code.prefix) {
                let p = HildesheimRooms.roomPlace(name: code.text + (code.description.map { " (\($0))" } ?? ""), rgid: nil, building: b)
                out["status"] = "found"; out["place"] = p; out["maps"] = p["maps"] ?? .null; out["note"] = p["note"] ?? .null
                return (out, false)
            }
            // unbekanntes Gebaeude: den Code im LSF suchen (Raum- und Gebaeudeseite liefern die Adresse)
            let (hits, stale) = await self.hits(code.text, clock: clock)
            if let hits, let h = hits.first(where: { PyText.lower($0.name).hasPrefix(PyText.lower(code.text)) }) ?? (hits.count == 1 ? hits.first : nil) {
                let (p, s2) = await place(hit: h, detail: true, clock: clock)
                out["status"] = "found"; out["place"] = p; out["maps"] = p["maps"] ?? .null; out["note"] = p["note"] ?? .null
                return (out, stale || s2)
            }
            if hits == nil, stale {
                out["status"] = "offline"; out["maps"] = fallback(); out["note"] = .string(HildesheimRooms.offlineEmpty)
                return (out, true)
            }
        }
        if let b = HildesheimRooms.building(named: text) {
            let p = HildesheimRooms.buildingPlace(b)
            out["status"] = "building"; out["place"] = p; out["maps"] = p["maps"] ?? .null; out["note"] = p["note"] ?? .null
            return (out, false)
        }
        let (hits, stale) = await self.hits(text, clock: clock)
        if let hits, !hits.isEmpty {
            if hits.count == 1 {
                let (p, s2) = await place(hit: hits[0], detail: false, clock: clock)
                out["status"] = "found"; out["place"] = p; out["maps"] = p["maps"] ?? .null; out["note"] = p["note"] ?? .null
                return (out, stale || s2)
            }
            var cands: [JSONValue] = []
            for h in hits.prefix(10) { cands.append(await place(hit: h, detail: false, clock: clock).0) }
            out["status"] = "ambiguous"; out["candidates"] = .array(cands); out["maps"] = fallback()
            out["note"] = .string("\(hits.count) Treffer im LSF – bitte den richtigen Raum wählen.")
            return (out, stale)
        }
        if let p = campusPlace() {
            out["status"] = "campus"; out["place"] = p; out["maps"] = p["maps"] ?? .null; out["note"] = Rooms.data["note_campus"] ?? .null
            return (out, stale)
        }
        if hits == nil, stale {
            out["status"] = "offline"; out["maps"] = fallback(); out["note"] = .string(HildesheimRooms.offlineEmpty)
            return (out, true)
        }
        out["status"] = "not_found"; out["maps"] = fallback(); out["note"] = .string(HildesheimRooms.notFound)
        return (out, false)
    }
}
