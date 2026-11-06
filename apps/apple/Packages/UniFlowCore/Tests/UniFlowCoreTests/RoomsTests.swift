import Foundation
import XCTest
@testable import UniFlowCore

/// Raumfinder (docs/RAUMFINDER-2026-11-05.md): gleiche Faelle wie app/rooms.py (packages/shared-contracts/fixtures/rooms/
/// cases.json aus gespeicherten Antworten des Standortfinders vom 05.11.2026): Zerlegen von Raumangaben, Treffer, Auswahl,
/// Aufloesen mit Cache und ohne Netz, Kartenlinks, Standorte, Endpunkte. Nie echtes Netz: der Abruf ist immer ersetzt.
final class RoomsTests: XCTestCase {

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func raw(_ name: String) throws -> JSONValue { try JSONValue.parse(repo("packages/shared-contracts/fixtures/rooms/raw/\(name)")) }
    private func cases() throws -> JSONValue { try JSONValue.parse(repo("packages/shared-contracts/fixtures/rooms/cases.json")) }
    private func clock(_ s: String) -> UniFlowClock { .fixed(berlin: s)! }

    /// Suche aus den gespeicherten Antworten (Begriff -> Datei wie im Generator), sonst keine Treffer; `offline` wirft
    final class FakeFinder: RoomFinderHTTP, @unchecked Sendable {
        let lock = NSLock()
        let answers: [String: JSONValue]
        let empty: JSONValue
        var offline = false
        var calls: [String] = []
        init(_ answers: [String: JSONValue], empty: JSONValue) { self.answers = answers; self.empty = empty }
        func search(_ term: String, page: Int) async throws -> JSONValue {
            try lock.withLock {
                calls.append(term)
                if offline { throw URLError(.notConnectedToInternet) }
                return answers[PyText.lower(Rooms.words(term))] ?? empty
            }
        }
        var count: Int { lock.withLock { calls.count } }
    }

    private func finder() throws -> FakeFinder {
        let fx = try cases()
        var answers: [String: JSONValue] = [:]
        for (k, v) in fx["raw_map"]?.object ?? [:] { answers[k] = try raw(v.string ?? "") }
        return FakeFinder(answers, empty: try raw("search-leer.json"))
    }

    private func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("rooms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testDataFileIsTheSame() throws {
        XCTAssertEqual(Rooms.data, try JSONValue.parse(repo("packages/shared-contracts/rooms.json")))
    }

    func testParseLikePython() throws {
        for c in try cases()["parse"]?.array ?? [] {
            XCTAssertEqual(Rooms.parse(c["text"]?.string, university: c["university"]?.string), c["result"], c["text"]?.string ?? "")
        }
    }

    func testRecognisedPatterns() {
        func p(_ t: String, _ u: String = "luh") -> JSONValue { Rooms.parse(t, university: u)["parts"]?.array?.first ?? .null }
        XCTAssertEqual(p("1101 - F102")["room"], "F102")
        XCTAssertEqual(p("1101 - F102")["building"], "1101")
        XCTAssertEqual(p("F102 (1101)")["building"], "1101")
        XCTAssertEqual(p("Gebäude 3403, Raum A003")["room"], "A003")
        XCTAssertEqual(p("Hauptgebäude, F142")["building"], "1101")
        XCTAssertEqual(p("1101.001.F102")["floor"], "001")
        XCTAssertEqual(p("Hörsaal E 214")["room"], "E214")
        XCTAssertEqual(p("Seminarraum")["linkable"], false)
        XCTAssertEqual(p("Online")["online"], true)
        XCTAssertEqual(p("1H.1.01", "hsh")["campus"], "linden")
        XCTAssertTrue(Rooms.mayLink("Seminarraum"))
        XCTAssertFalse(Rooms.mayLink("Online"))
        XCTAssertFalse(Rooms.mayLink("  "))
    }

    func testPlacesLikePython() throws {
        let fx = try cases()
        for (name, places) in fx["places"]?.object ?? [:] {
            XCTAssertEqual(try raw(name)["data"]?.array?.map(Rooms.place), places.array, name)
        }
        for c in fx["crafted"]?.array ?? [] {
            XCTAssertEqual(Rooms.place(c["item"] ?? .null), c["place"], c["item"]?["item_id"]?.string ?? "")
        }
        for c in fx["choose"]?.array ?? [] {
            let part = Rooms.parse(c["text"]?.string)["parts"]?.array?.first ?? .null
            let (st, hits) = Rooms.choose(part, try raw(c["fixture"]?.string ?? "")["data"]?.array ?? [])
            XCTAssertEqual(st, c["result"]?["status"]?.string, c["text"]?.string ?? "")
            let ids: [String] = hits.compactMap { $0["item_id"]?.string }
            let want: [String] = c["result"]?["ids"]?.array?.compactMap { $0.string } ?? []
            XCTAssertEqual(ids, want, c["text"]?.string ?? "")
        }
    }

    func testMapsAndHelpersLikePython() throws {
        let fx = try cases()
        let m = fx["maps"]?.array ?? []
        XCTAssertEqual(Rooms.maps("Welfengarten 1, 30167 Hannover", label: "Hauptgebäude"), m[0])
        XCTAssertEqual(Rooms.maps("", label: "Raum F102", lat: 52.38255, lon: 9.71785), m[1])
        XCTAssertEqual(Rooms.maps("", label: "Kesselhaus", lat: 52.38, lon: 9.72272), m[2])
        XCTAssertEqual(Rooms.maps("Hochschule Hannover 1H.1.01 & Co / Süd"), m[3])
        XCTAssertEqual(m[1]["google_app_route"], "comgooglemaps://?daddr=52.38255%2C9.71785&directionsmode=walking")
        for (k, v) in fx["floors"]?.object ?? [:] { XCTAssertEqual(Rooms.floorLabel(k).map(JSONValue.string) ?? .null, v, k) }
        for (k, v) in fx["coords"]?.object ?? [:] { XCTAssertEqual(Rooms.coord(Double(k)!), v.string, k) }
        for (k, v) in fx["enc"]?.object ?? [:] { XCTAssertEqual(Rooms.enc(k), v.string, k) }
        for (k, v) in fx["segments"]?.object ?? [:] { XCTAssertEqual(Rooms.segments(k), v.array?.compactMap(\.string), k) }
        for (k, v) in fx["campuses"]?.object ?? [:] { XCTAssertEqual(Rooms.campuses(university: k), v, k) }
    }

    func testResolveLikePython() async throws {
        let fx = try cases()
        for c in fx["resolve"]?.array ?? [] {
            let r = LocalRooms()
            r.configure(http: try finder(), folder: try folder())
            let got = await r.resolve(c["text"]?.string, university: c["university"]?.string, clock: clock("2026-11-05T12:00:00"))
            XCTAssertEqual(got, c["result"], c["text"]?.string ?? "")
        }
        for c in fx["search"]?.array ?? [] {
            let r = LocalRooms()
            let f = try finder()
            f.offline = c["offline"]?.bool == true
            r.configure(http: f, folder: try folder())
            let got = await r.search(c["q"]?.string, page: c["page"]?.int ?? 0, clock: clock("2026-11-05T12:00:00"))
            XCTAssertEqual(got, c["result"], c["q"]?.string ?? "")
        }
        for c in (fx["offline"]?.array ?? []).prefix(2) {
            let r = LocalRooms()
            let f = try finder()
            f.offline = true
            r.configure(http: f, folder: try folder())
            let got = await r.resolve(c["text"]?.string, university: "luh", clock: clock("2026-11-05T12:00:00"))
            XCTAssertEqual(got, c["result"], c["text"]?.string ?? "")
        }
    }

    func testCacheThirtyDaysAndOffline() async throws {
        let r = LocalRooms()
        let f = try finder()
        r.configure(http: f, folder: try folder())
        _ = await r.resolve("1101 - F102", university: "luh", clock: clock("2026-11-05T12:00:00"))
        _ = await r.resolve("F102 (1101)", university: "luh", clock: clock("2026-12-03T12:00:00"))
        XCTAssertEqual(f.calls, ["F102"], "30 Tage aus dem Cache")
        _ = await r.resolve("Z999", university: "luh", clock: clock("2026-11-05T12:00:00"))
        _ = await r.resolve("Z999", university: "luh", clock: clock("2026-11-05T23:00:00"))
        XCTAssertEqual(f.calls.filter { $0 == "Z999" }.count, 1, "nichts gefunden: einen Tag gemerkt")
        f.offline = true
        let stale = await r.resolve("F102", university: "luh", clock: clock("2027-03-01T12:00:00"))
        let expected = try cases()["offline"]?.array?[2]["result"]
        XCTAssertEqual(stale, expected, "ohne Netz: alter Stand mit Hinweis")
        let none = await r.resolve("E214", university: "luh", clock: clock("2026-11-05T12:00:00"))
        XCTAssertEqual(none["parts"]?.array?.first?["status"], "offline")
        XCTAssertEqual(none["parts"]?.array?.first?["maps"]?["query"], "Leibniz Universität Hannover E214")
        let before = f.count
        _ = await r.resolve("Seminarraum", university: "luh", clock: clock("2026-11-05T12:00:00"))
        XCTAssertEqual(f.count, before, "ohne Raumnummer keine Anfrage")
    }

    func testEndpointsAndDemo() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock("2026-11-05T12:00:00"), university: "hsh")
        b.context.rooms.configure(http: RoomFinderDemoHTTP(), folder: nil)
        func get(_ p: String) async -> JSONValue? {
            await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + p)!)).json
        }
        let hshRaw = await get("/api/rooms/resolve?text=1H.1.01")
        let hsh = try XCTUnwrap(hshRaw)
        XCTAssertEqual(hsh["university"], "hsh", "Hochschule aus den Einstellungen")
        XCTAssertEqual(hsh["parts"]?.array?.first?["status"], "campus")
        let luhRaw = await get("/api/rooms/resolve?text=1101%20-%20F102&university=luh")
        let luh = try XCTUnwrap(luhRaw)
        XCTAssertEqual(luh["parts"]?.array?.first?["place"]?["id"], "1101.001.F102")
        let sRaw = await get("/api/rooms/search?q=Audimax")
        let s = try XCTUnwrap(sRaw)
        XCTAssertEqual(s["items"]?.array?.first?["title"], "Raum E415 – Audimax")
        let cRaw = await get("/api/rooms/campuses")
        let c = try XCTUnwrap(cRaw)
        XCTAssertEqual(c["campuses"]?.array?.count, 4)
        XCTAssertEqual(c["finder"], false)
    }

    func testFormEncoding() {
        XCTAssertEqual(String(decoding: URLSessionRoomFinderHTTP.form([("search", "Hauptgebäude F 102"), ("page", "0")]), as: UTF8.self),
                       "search=Hauptgeb%C3%A4ude+F+102&page=0")
    }
}
