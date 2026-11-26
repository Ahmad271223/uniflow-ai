import Foundation
import XCTest
@testable import UniFlowCore

/// Mensa (docs/MENSA-2026-11-05.md): gleiche Faelle wie app/mensa.py (packages/shared-contracts/fixtures/mensa/cases.json,
/// erzeugt aus gespeicherten Antworten von Studi|Futter, STW-ON und OpenMensa), Abruf mit Cache, Ersatzquelle, ohne Netz
/// und die Endpunkte. Nie echtes Netz: der Abruf ist immer `FakeHTTP`.
final class MensaTests: XCTestCase {

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func raw(_ name: String) throws -> Data { try repo("packages/shared-contracts/fixtures/mensa/raw/\(name)") }
    private func cases() throws -> JSONValue { try JSONValue.parse(repo("packages/shared-contracts/fixtures/mensa/cases.json")) }

    final class FakeHTTP: MensaHTTP, @unchecked Sendable {
        let lock = NSLock()
        var answers: [(String, Data?)]
        var calls: [String] = []
        init(_ answers: [(String, Data?)]) { self.answers = answers }
        func get(_ url: String) async throws -> Data {
            let a: Data?? = lock.withLock {
                calls.append(url)
                return answers.first { url.hasPrefix($0.0) }.map { $0.1 }
            }
            guard let found = a, let d = found else { throw URLError(.notConnectedToInternet) }
            return d
        }
        var count: Int { lock.withLock { calls.count } }
    }

    private let sf = "https://studi-futter.rocket-meals.de/"
    private let om = "https://openmensa.org/"
    private let on = "https://sls.api.stw-on.de/"

    private func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mensa-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: Gleiche Faelle wie Python

    func testParseMatchesPython() throws {
        let fx = try cases()
        for (name, c) in fx["parse"]?.object ?? [:] {
            let got = Mensa.parse(kind: c["kind"]?.string ?? "", raw: try JSONValue.parse(raw(name)))
            let want = try XCTUnwrap(c["result"])
            XCTAssertEqual(got["closed"], want["closed"], name)
            let gd = got["days"]?.object ?? [:], wd = want["days"]?.object ?? [:]
            XCTAssertEqual(Set(gd.keys), Set(wd.keys), name)
            for (d, meals) in wd {
                let g = gd[d]?.array ?? [], w = meals.array ?? []
                XCTAssertEqual(g.count, w.count, "\(name) \(d)")
                for (a, b) in zip(g, w) { XCTAssertEqual(a, b, "\(name) \(d) \(b["name"]?.string ?? "")") }
            }
        }
        XCTAssertEqual(fx["parse"]?.object?.count, 4)
    }

    /// Foto (19.11.2026, wie tests/test_mensa.py): nur eine gueltige Bild-ID wird zur Adresse beim Studentenwerk
    func testStudifutterDishPhoto() throws {
        let api = try XCTUnwrap(Mensa.data["sources"]?["studifutter"]?["api"]?.string)
        let raw: JSONValue = ["data": [
            ["id": "a", "date": "2026-11-20", "alias": "Burger", "food": ["image": "1D2C3B4A-0000-4000-8000-00000000ABCD"]],
            ["id": "b", "date": "2026-11-20", "alias": "Suppe", "food": ["image": .null]],
            ["id": "c", "date": "2026-11-20", "alias": "Pasta", "food": ["image": "../../etc/passwd"]],
            ["id": "d", "date": "2026-11-20", "alias": "Salat"]]]
        let meals = Mensa.parseStudifutter(raw)["days"]?["2026-11-20"]?.array ?? []
        let byID = Dictionary(uniqueKeysWithValues: meals.map { ($0["id"]?.string ?? "", $0) })
        XCTAssertEqual(byID["a"]?["image"]?.string, "\(api)/assets/1d2c3b4a-0000-4000-8000-00000000abcd?width=\(Mensa.imageWidth)&quality=70")
        for id in ["b", "c", "d"] { XCTAssertEqual(byID[id]?["image"], .null, id) }
        XCTAssertTrue(Mensa.studifutterFields.contains("food.image"))
    }

    func testDaysFiltersTopPricesLikePython() throws {
        let fx = try cases()
        let parsed = { (n: String) -> JSONValue in fx["parse"]?[n]?["result"] ?? .null }
        for c in fx["days"]?.array ?? [] {
            let got = Mensa.buildDays(start: c["start"]?.string ?? "", count: c["count"]?.int ?? 1,
                                      parsed: parsed(c["fixture"]?.string ?? ""), since: c["since"]?.string)
            XCTAssertEqual(got.map { $0["status"]?.string ?? "" }, c["status"]?.array?.compactMap(\.string), c["fixture"]?.string ?? "")
        }
        let sample = (parsed("studifutter-garbsen.json")["days"]?["2026-11-05"]?.array ?? [])
            + (parsed("stwon-hi-uni.json")["days"]?["2026-11-05"]?.array ?? [])
        for c in fx["filters"]?.array ?? [] {
            let f = Mensa.Filter(json: c["filter"] ?? .null)
            XCTAssertEqual(Mensa.filter(sample, f).compactMap { $0["id"]?.string }, c["ids"]?.array?.compactMap(\.string), "\(f)")
            XCTAssertEqual(Mensa.top(sample, 3, f).compactMap { $0["id"]?.string }, c["top"]?.array?.compactMap(\.string), "\(f)")
        }
        let stwon = parsed("stwon-hi-uni.json")["days"]?["2026-11-05"]?.array ?? []
        XCTAssertEqual(Mensa.top(stwon).compactMap { $0["id"]?.string }, fx["top_stwon"]?.array?.compactMap(\.string))
        for c in fx["prices"]?.array ?? [] {
            let meal = try XCTUnwrap(sample.first { $0["id"] == c["id"] })
            XCTAssertEqual(Mensa.price(meal, role: c["role"]?.string ?? ""), c["price"]?.double)
        }
        for (k, v) in fx["pretty"]?.object ?? [:] { XCTAssertEqual(Mensa.prettyCategory(k), v.string, k) }
        for (cid, url) in fx["urls"]?.object ?? [:] {
            let kind = cid == "hauptmensa" ? "openmensa" : nil
            XCTAssertEqual(Mensa.sourceURL(try XCTUnwrap(Mensa.canteen(cid)), start: "2026-11-05", end: "2026-11-18", kind: kind), url.string, cid)
        }
        // wie Python: alle Mensen (die Auswahl je Build prueft `testCanteensOfUnshippedRegionsAreHidden`)
        for (u, want) in fx["canteens"]?.object ?? [:] {
            let r = UFReleaseUniversities.withShipped(Set(UniversityKey.allCases)) { Mensa.canteensResponse(university: u) }
            XCTAssertEqual(r["default"], want["default"], u)
            XCTAssertEqual(r["university"], want["university"], u)
            XCTAssertEqual(r["canteens"]?.array?.compactMap { $0["id"]?.string }, want["ids"]?.array?.compactMap(\.string), u)
            XCTAssertEqual(r["canteens"]?.array?.filter { $0["own"]?.bool == true }.compactMap { $0["id"]?.string },
                           want["own"]?.array?.compactMap(\.string), u)
        }
    }

    // MARK: Studierendenwerk Goettingen (26.11.2026, docs/GOETTINGEN-2026-11-26.md)

    /// Gespeicherte Bausteine der echten Speiseplan-Seite (Zentralmensa): Status je Tag, Filter, Auswahl und Adressen
    /// wie Python; nie ein Preis
    func testGoettingenCasesLikePython() throws {
        let fx = try cases()
        let want = try XCTUnwrap(fx["stwgoe"])
        let parsed = Mensa.parse(kind: "stwgoe", raw: try JSONValue.parse(raw("stwgoe-zentralmensa.json")))
        XCTAssertEqual(Mensa.buildDays(start: "2026-11-26", count: 6, parsed: parsed, since: "2026-11-26").map { $0["status"]?.string ?? "" },
                       want["status"]?.array?.compactMap(\.string))
        XCTAssertEqual(parsed["closed"]?.array?.compactMap(\.string), ["2026-11-29"], "Sonntag: „kein Angebot“ heißt geschlossen")
        let day = parsed["days"]?["2026-11-26"]?.array ?? []
        XCTAssertFalse(day.isEmpty)
        for c in want["filters"]?.array ?? [] {
            let f = Mensa.Filter(json: c["filter"] ?? .null)
            XCTAssertEqual(Mensa.filter(day, f).compactMap { $0["id"]?.string }, c["ids"]?.array?.compactMap(\.string), "\(f)")
            XCTAssertEqual(Mensa.top(day, 3, f).compactMap { $0["id"]?.string }, c["top"]?.array?.compactMap(\.string), "\(f)")
        }
        XCTAssertEqual(Mensa.sort(day, by: "price").compactMap { $0["id"]?.string }, want["price_sort"]?.array?.compactMap(\.string))
        XCTAssertEqual(day.filter { $0["pork_unknown"]?.bool == true }.compactMap { $0["id"]?.string },
                       want["pork_unknown"]?.array?.compactMap(\.string))
        // keine Preise: jede Gruppe null, `Mensa.price` nil - die Oberflaeche zeigt dann keinen Betrag
        for meals in (parsed["days"]?.object ?? [:]).values {
            for m in meals.array ?? [] {
                XCTAssertEqual(m["prices"], ["student": .null, "employee": .null, "guest": .null], m["name"]?.string ?? "")
                for role in ["student", "employee", "guest"] { XCTAssertNil(Mensa.price(m, role: role)) }
            }
        }
        XCTAssertFalse(Mensa.sourceHasPrices("stwgoe"))
        XCTAssertTrue(Mensa.sourceHasPrices("studifutter"))
        XCTAssertTrue(Mensa.sourceHasPrices("stwon"))
        let zentral = try XCTUnwrap(Mensa.canteen("goe-zentralmensa")), turm = try XCTUnwrap(Mensa.canteen("goe-turm"))
        XCTAssertEqual(Mensa.stwgoeURLs(zentral, start: "2026-11-26", end: "2026-12-09").map { [$0.day, $0.url] },
                       want["urls"]?.array?.map { $0.array?.compactMap(\.string) ?? [] })
        XCTAssertEqual(Mensa.stwgoeURLs(turm, start: "2026-11-26", end: "2026-11-27").map { [$0.day, $0.url] },
                       want["urls_short"]?.array?.map { $0.array?.compactMap(\.string) ?? [] })
        XCTAssertEqual(Mensa.stwgoeURLs(zentral, start: "2026-11-26", end: "2026-12-09").count, 6, "heute und fünf Tage")
    }

    /// Einzelheiten des Lesers an erfundenen Zeilen: Kennzeichen-Klammern, Bereiche, Symbole, Beilagen, Hinweiszeilen
    func testGoettingenRows() throws {
        func page(_ rows: String, date: String = "02.12.2026") -> JSONValue {
            ["pages": [["date": "2026-12-02", "html": .string("""
                <table class="sp_tab"><tr><th colspan="3"><strong>Testmensa</strong><div class="sp_date">\(date)</div></th></tr>\(rows)</table>
                """)]]]
        }
        let png = "/fileadmin/templates/images/mensaspeiseplan/png/"
        let html = """
            <tr class="odd"><td class="sp_typ">Men&uuml;</td><td class="sp_bez"><strong>Cr&ecirc;pe mit K&auml;se (2,g,a.1,a)</strong><br/>Reis (vom Feld), oder, Pommes frites (3)<br/><i class="smaller">(Mittagsangebot)</i></td><td class="sp_hin"><img src="\(png)vegetarisch.png" /><img src="\(png)NDS.png" /></td></tr>
            <tr class="even"><td class="sp_typ">Tasty 1</td><td class="sp_bez"><strong>Frikadelle (a.1,c,14)</strong><br/>Senf (j)<br/><i class="smaller">(Nachmittagsangebot ab 14:30 Uhr)</i></td><td class="sp_hin"><img src="\(png)fleisch.png" /></td></tr>
            <tr class="odd"><td class="sp_typ">Tasty 2</td><td class="sp_bez"><strong>Schnitzel vom Strohschwein</strong></td><td class="sp_hin"><img src="/fileadmin/templates/images/mensaspeiseplan/jpg/strohschwein.jpg" /></td></tr>
            <tr class="even"><td class="sp_typ">Green</td><td class="sp_bez"><strong>Seelachs (d)</strong></td><td class="sp_hin"><img src="\(png)fisch.png" /></td></tr>
            <tr class="odd"><td class="sp_typ">Salatbuffet</td><td class="sp_bez">Salat in Selbstbedienung!
            Kann Allergene (a-c) enthalten.</td><td class="sp_hin"></td></tr>
            <tr class="even"><td class="sp_typ">Vegan</td><td class="sp_bez"><strong>Linsensuppe</strong></td><td class="sp_hin"><img src="\(png)vegan.png" /></td></tr>
            <tr><td>ohne Menülinie: keine Zeile</td></tr>
            """
        let meals = Mensa.parseStwgoe(page(html))["days"]?["2026-12-02"]?.array ?? []
        XCTAssertEqual(meals.compactMap { $0["name"]?.string },
                       ["Crêpe mit Käse", "Frikadelle", "Schnitzel vom Strohschwein", "Seelachs", "Salat in Selbstbedienung!", "Linsensuppe"])
        XCTAssertEqual(meals.compactMap { $0["id"]?.string }, (0..<6).map { "2026-12-02-\($0)" })
        let crepe = meals[0]
        XCTAssertEqual(crepe["category"]?.string, "Menü")
        XCTAssertEqual(crepe["time"]?.string, "mittag")
        XCTAssertEqual(crepe["labels"], ["vegetarisch"])
        XCTAssertEqual(crepe["notes"], ["Niedersachsen-Menü"])
        XCTAssertEqual(crepe["components"], ["Reis (vom Feld)", "oder Pommes frites (3)"], "Text in Klammern bleibt, Bindewort zum nächsten Teil")
        XCTAssertEqual(crepe["allergens"]?.array?.compactMap { $0["code"]?.string }, ["g", "a.1"], "„a“ entfällt neben „a.1“")
        XCTAssertEqual(crepe["allergens"]?.array?.compactMap { $0["key"]?.string }, ["milch", "gluten"])
        XCTAssertEqual(crepe["additives"]?.array?.compactMap { $0["name"]?.string }, ["mit Farbstoff", "mit Antioxidationsmittel"])
        XCTAssertNil(crepe["pork_unknown"])
        let frikadelle = meals[1]
        XCTAssertEqual(frikadelle["labels"], ["fleisch"])
        XCTAssertEqual(frikadelle["pork_unknown"], true, "Fleischart steht nicht im Plan")
        XCTAssertEqual(frikadelle["time"], .null)
        XCTAssertEqual(frikadelle["notes"], ["Nachmittagsangebot ab 14:30 Uhr"])
        XCTAssertEqual(frikadelle["additives"]?.array?.last?["name"]?.string, Mensa.goeUnknownAdditive("14"), "unbekanntes Kennzeichen ehrlich benannt")
        XCTAssertEqual(meals[2]["labels"], ["fleisch", "schwein"])
        XCTAssertNil(meals[2]["pork_unknown"])
        XCTAssertEqual(meals[2]["notes"], ["Leinekrone Strohschwein"])
        XCTAssertEqual(meals[3]["labels"], ["fisch"])
        let salad = meals[4]
        XCTAssertEqual(salad["main"], false)
        XCTAssertEqual(salad["notes"], ["Kann Allergene (a-c) enthalten."])
        XCTAssertEqual(salad["allergens"]?.array?.compactMap { $0["key"]?.string }, ["gluten", "krebstiere", "ei"], "Bereich: kann enthalten")
        XCTAssertEqual(meals[5]["labels"], ["vegan", "vegetarisch"])
        // "ohne Schwein": Schwein und Fleisch unbekannter Art fallen weg
        XCTAssertEqual(Mensa.filter(meals, Mensa.Filter(noPork: true)).compactMap { $0["name"]?.string },
                       ["Crêpe mit Käse", "Seelachs", "Salat in Selbstbedienung!", "Linsensuppe"])
        // Baustein eines anderen Tages (falsche Datei im Zwischenspeicher): nichts daraus lesen
        XCTAssertEqual(Mensa.parseStwgoe(page(html, date: "03.12.2026")), ["days": [:], "closed": []])
        // Fehlerseite statt des Bausteins, leere Antwort: kein Tag, kein "geschlossen"
        for junk in ["<html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>", ""] {
            XCTAssertEqual(Mensa.parseStwgoe(["pages": [["date": "2026-12-02", "html": .string(junk)]]]), ["days": [:], "closed": []], junk)
        }
        XCTAssertEqual(Mensa.goeSplit("A (1,2), oder, B, mit, C (g), D"), ["A (1,2)", "oder B", "mit C (g)", "D"])
        XCTAssertEqual(Mensa.goeCodes("Wurst (vom Schwein) (1,3) Senf (j)").text, "Wurst (vom Schwein) Senf")
        XCTAssertEqual(Mensa.goeCodes("Wurst (vom Schwein) (1,3) Senf (j)").codes, ["1", "3", "j"])
    }

    /// Abruf: je Tag ein Baustein (hoechstens sechs), 404 ueberspringt den Tag, ohne Netz der letzte Stand
    func testGoettingenFetchPerDay() async throws {
        let api = try XCTUnwrap(Mensa.data["sources"]?["stwgoe"]?["api"]?.string)
        let fixture = try JSONValue.parse(raw("stwgoe-zentralmensa.json"))
        final class Site: MensaHTTP, @unchecked Sendable {
            let lock = NSLock()
            var pages: [String: Data] = [:]
            var calls: [String] = []
            var offline = false
            func get(_ url: String) async throws -> Data {
                let (page, off): (Data?, Bool) = lock.withLock { calls.append(url); return (pages[url], offline) }
                if off { throw URLError(.notConnectedToInternet) }
                guard let page else { throw MensaHTTPError(status: 404) }
                return page
            }
        }
        let site = Site()
        for p in fixture["pages"]?.array ?? [] {
            site.pages["\(api)/de/\(p["date"]?.string ?? "")/zentralmensa.html"] = Data((p["html"]?.string ?? "").utf8)
        }
        let m = LocalMensa()
        m.configure(http: site, folder: try folder())
        let r = try await m.menu(canteen: "goe-zentralmensa", day: "2026-11-26", days: 6, clock: clock("2026-11-26T11:00:00"))
        XCTAssertEqual(site.calls, (0..<6).map { "\(api)/de/\(Mensa.addDays("2026-11-26", $0))/zentralmensa.html" }, "sechs Tage, je ein Abruf")
        XCTAssertEqual(r["days"]?.array?.map { $0["status"]?.string ?? "" }, ["open", "closed", "closed", "closed", "open", "none"])
        XCTAssertEqual(r["source"]?["key"]?.string, "stwgoe")
        XCTAssertEqual(r["source"]?["name"]?.string, "Studierendenwerk Göttingen")
        XCTAssertEqual(r["stale"]?.bool, false)
        let first = try XCTUnwrap(r["days"]?.array?.first?["meals"]?.array?.first)
        XCTAssertEqual(first["name"]?.string, "Vegane Filetstreifen mit Chinagemüse")
        XCTAssertEqual(first["prices"], ["student": .null, "employee": .null, "guest": .null])
        _ = try await m.menu(canteen: "goe-zentralmensa", day: "2026-11-27", days: 1, clock: clock("2026-11-26T12:00:00"))
        XCTAssertEqual(site.calls.count, 6, "eine Stunde später aus dem Cache")
        // ohne Netz nach drei Stunden: der letzte Stand mit Hinweis
        site.lock.withLock { site.offline = true }
        let stale = try await m.menu(canteen: "goe-zentralmensa", day: "2026-11-26", days: 1, clock: clock("2026-11-26T15:30:00"))
        XCTAssertEqual(stale["stale"]?.bool, true)
        XCTAssertEqual(stale["days"]?.array?.first?["status"]?.string, "open")
        // nur 404 (noch kein Plan): kein Fehler, alle Tage "none"
        let empty = Site()
        let m2 = LocalMensa()
        m2.configure(http: empty, folder: try folder())
        let none = try await m2.menu(canteen: "goe-cgin", day: "2026-11-26", days: 2, clock: clock("2026-11-26T11:00:00"))
        XCTAssertEqual(none["stale"]?.bool, false)
        XCTAssertEqual(none["days"]?.array?.map { $0["status"]?.string ?? "" }, ["none", "none"])
    }

    /// Mensen einer Hochschule, die der Build nicht zur Wahl stellt, erscheinen nicht - ausser es ist die eigene
    func testCanteensOfUnshippedRegionsAreHidden() {
        func ids(_ u: String) -> [String] { Mensa.canteensResponse(university: u)["canteens"]?.array?.compactMap { $0["id"]?.string } ?? [] }
        UFReleaseUniversities.withShipped([.luh, .hildesheim]) {             // Store-Stand am 26.11.2026
            XCTAssertFalse(ids("luh").contains { $0.hasPrefix("goe-") }, "Göttingen noch nicht freigegeben")
            XCTAssertTrue(ids("luh").contains("hauptmensa"))
            XCTAssertTrue(ids("luh").contains("linden"), "Region Hannover bleibt ganz (HsH teilt sie mit der LUH)")
            XCTAssertTrue(ids("luh").contains("hi-uni"))
            XCTAssertEqual(Array(ids("goettingen").prefix(3)), ["goe-zentralmensa", "goe-cgin", "goe-turm"], "eigene Hochschule: immer")
        }
        UFReleaseUniversities.withShipped([.luh, .hildesheim, .goettingen]) {
            XCTAssertTrue(ids("luh").contains("goe-zentralmensa"))
        }
        XCTAssertEqual(Mensa.defaultCanteen(university: "goettingen"), "goe-zentralmensa")
    }

    // MARK: Abruf und Cache

    private func clock(_ s: String) -> UniFlowClock { .fixed(berlin: s)! }

    func testFetchesOnceThenCaches() async throws {
        let m = LocalMensa()
        let http = FakeHTTP([(sf, try raw("studifutter-garbsen.json"))])
        m.configure(http: http, folder: try folder())
        let r = try await m.menu(canteen: "garbsen", day: "2026-11-05", days: 7, clock: clock("2026-11-05T11:00:00"))
        XCTAssertEqual(http.count, 1)
        XCTAssertTrue(http.calls[0].contains("2026-11-18"), "ein Abruf fuer 14 Tage")
        XCTAssertEqual(r["days"]?.array?.prefix(5).map { $0["status"]?.string ?? "" }, ["open", "open", "closed", "closed", "open"])
        XCTAssertEqual(r["source"]?["key"]?.string, "studifutter")
        XCTAssertEqual(r["stale"]?.bool, false)
        XCTAssertEqual(r["canteen"]?["id"]?.string, "garbsen")
        _ = try await m.menu(canteen: "garbsen", day: "2026-11-06", days: 1, clock: clock("2026-11-05T12:00:00"))
        XCTAssertEqual(http.count, 1, "eine Stunde spaeter aus dem Cache")
        _ = try await m.menu(canteen: "garbsen", day: "2026-11-05", days: 1, clock: clock("2026-11-05T15:00:00"))
        XCTAssertEqual(http.count, 2, "nach 3 Stunden neu")
    }

    func testFallsBackToOpenMensa() async throws {
        let m = LocalMensa()
        let http = FakeHTTP([(sf, nil), (om, try raw("openmensa-hauptmensa.json"))])
        m.configure(http: http, folder: try folder())
        let r = try await m.menu(canteen: "hauptmensa", day: "2026-11-05", days: 3, clock: clock("2026-11-05T11:00:00"))
        XCTAssertEqual(http.calls.map { $0.hasPrefix(om) }, [false, true])
        XCTAssertEqual(r["source"]?["name"]?.string, "OpenMensa")
        XCTAssertEqual(r["days"]?.array?.map { $0["status"]?.string ?? "" }, ["open", "open", "closed"])
    }

    func testOfflineShowsLastState() async throws {
        let m = LocalMensa()
        let dir = try folder()
        m.configure(http: FakeHTTP([(on, try raw("stwon-hi-uni.json"))]), folder: dir)
        _ = try await m.menu(canteen: "hi-uni", day: nil, days: 1, clock: clock("2026-11-05T11:00:00"))
        let offline = FakeHTTP([])
        m.configure(http: offline, folder: dir)
        let r = try await m.menu(canteen: "hi-uni", day: "2026-11-06", days: 1, clock: clock("2026-11-06T09:00:00"))
        XCTAssertEqual(offline.count, 1)
        XCTAssertEqual(r["stale"]?.bool, true)
        XCTAssertTrue(r["message"]?.string?.contains("zuletzt geladenen Stand") == true)
        XCTAssertEqual(r["days"]?.array?.first?["status"]?.string, "open")
        let none = try await m.menu(canteen: "hi-buehler", day: "2026-11-06", days: 1, clock: clock("2026-11-06T09:00:00"))
        XCTAssertEqual(none["days"]?.array?.first?["status"]?.string, "none")
        XCTAssertTrue(none["message"]?.string?.contains("nicht erreichbar") == true)
    }

    // MARK: Endpunkte

    func testEndpoints() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock("2026-11-05T11:00:00"), university: "hildesheim")
        b.context.mensa.configure(http: FakeHTTP([(on, try raw("stwon-hi-uni.json"))]), folder: try folder())
        func get(_ p: String) async -> LocalResponse {
            await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + p)!))
        }
        let cr = await get("/api/mensa/canteens")
        let c = try XCTUnwrap(cr.json)
        XCTAssertEqual(c["default"]?.string, "hi-uni", "Hochschule aus den Einstellungen")
        XCTAssertEqual(c["canteens"]?.array?.count, 13)
        let mr = await get("/api/mensa/menu?date=2026-11-05&days=2")
        let m = try XCTUnwrap(mr.json)
        XCTAssertEqual(m["canteen"]?["id"]?.string, "hi-uni")
        XCTAssertEqual(m["days"]?.array?.map { $0["date"]?.string ?? "" }, ["2026-11-05", "2026-11-06"])
        XCTAssertTrue(m["source"]?["attribution"]?.string?.hasPrefix("Speiseplan: Studierendenwerk OstNiedersachsen") == true)
        let nf = await get("/api/mensa/menu?canteen=gibtsnicht")
        let bad = await get("/api/mensa/menu?canteen=hi-uni&date=05.11.2026")
        XCTAssertEqual(nf.status, 404)
        XCTAssertEqual(bad.status, 400)
    }

    /// Erfundener Plan fuer App-Tests: Werktage mit sechs Gerichten, Wochenende zu, beide Quellen-Formen lesbar
    func testDemoPlanWithoutNetwork() async throws {
        let m = LocalMensa()
        let c = clock("2026-11-06T10:00:00")                                    // Freitag
        m.configure(http: MensaDemoHTTP(clock: c), folder: nil)
        for cid in ["hauptmensa", "hi-uni"] {
            let r = try await m.menu(canteen: cid, day: nil, days: 4, clock: c)
            XCTAssertEqual(r["days"]?.array?.map { $0["status"]?.string ?? "" }, ["open", "closed", "closed", "open"], cid)
            let meals = r["days"]?.array?.first?["meals"]?.array ?? []
            XCTAssertEqual(meals.count, 6, cid)
            XCTAssertEqual(Mensa.top(meals).count, 3, cid)
            XCTAssertTrue(Mensa.labels(meals[0]).contains("vegan"), cid)
            XCTAssertEqual(Mensa.price(meals[0], role: "student"), 2.5, cid)
        }
    }

    /// Naehrwerte, Bestandteile, Sortierung (Wunsch des Inhabers 05.11.2026), gleiche Faelle wie Python
    func testSortsAndNumbersLikePython() throws {
        let fx = try cases()
        for c in fx["sorts"]?.array ?? [] {
            let meals = fx["parse"]?[c["fixture"]?.string ?? ""]?["result"]?["days"]?["2026-11-05"]?.array ?? []
            XCTAssertEqual(Mensa.sort(meals, by: c["by"]?.string ?? "", role: c["role"]?.string ?? "").compactMap { $0["id"]?.string },
                           c["ids"]?.array?.compactMap(\.string), "\(c["fixture"]?.string ?? "") \(c["by"]?.string ?? "")")
        }
        for (k, v) in fx["numbers"]?.object ?? [:] { XCTAssertEqual(Mensa.number(.string(k)), v.double, k) }
        let chili = try XCTUnwrap(fx["parse"]?["studifutter-garbsen.json"]?["result"]?["days"]?["2026-11-05"]?.array?
            .first { ($0["name"]?.string ?? "").hasPrefix("Chili") })
        XCTAssertEqual(chili["nutrition"]?["energy_kcal"]?.double, 811)
        XCTAssertEqual(chili["components"]?.array?.count, 3)
    }
}
