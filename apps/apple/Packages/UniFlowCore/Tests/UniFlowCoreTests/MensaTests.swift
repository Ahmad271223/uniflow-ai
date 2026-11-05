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
        XCTAssertEqual(fx["parse"]?.object?.count, 3)
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
        for (u, want) in fx["canteens"]?.object ?? [:] {
            let r = Mensa.canteensResponse(university: u)
            XCTAssertEqual(r["default"], want["default"], u)
            XCTAssertEqual(r["university"], want["university"], u)
            XCTAssertEqual(r["canteens"]?.array?.compactMap { $0["id"]?.string }, want["ids"]?.array?.compactMap(\.string), u)
            XCTAssertEqual(r["canteens"]?.array?.filter { $0["own"]?.bool == true }.compactMap { $0["id"]?.string },
                           want["own"]?.array?.compactMap(\.string), u)
        }
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
