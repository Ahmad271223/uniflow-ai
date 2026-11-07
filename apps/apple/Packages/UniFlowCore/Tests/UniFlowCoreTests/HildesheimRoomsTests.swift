import Foundation
import XCTest
@testable import UniFlowCore

/// Raumfinder der Uni Hildesheim (07.11.2026, docs/RAUMFINDER-HILDESHEIM-2026-11-07.md): Leser der nachgebauten LSF-Seiten
/// (erfundene Daten, `HildesheimRoomsDemoHTTP`), Raumcodes, feste Gebaeudetabelle, Aufloesen mit und ohne Netz, Cache,
/// Belegung, Endpunkte. Nie echtes Netz.
final class HildesheimRoomsTests: XCTestCase {

    /// Zaehlt die Aufrufe; `offline` wirft
    final class Counting: HildesheimRoomsHTTP, @unchecked Sendable {
        let lock = NSLock()
        let inner = HildesheimRoomsDemoHTTP()
        var urls: [String] = []
        var offline = false
        func get(_ url: URL) async throws -> String {
            try lock.withLock {
                urls.append(url.absoluteString)
                if offline { throw URLError(.notConnectedToInternet) }
            }
            return try await inner.get(url)
        }
        var count: Int { lock.withLock { urls.count } }
    }

    private func clock(_ s: String) -> UniFlowClock { .fixed(berlin: s)! }

    private func folder() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("hi-rooms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    // MARK: Adressen und Seiten

    func testURLsAndWeek() {
        XCTAssertEqual(HildesheimRooms.searchURL("Hörsaal 1").absoluteString,
                       "https://lsf.uni-hildesheim.de/qisserver/rds?state=change&type=5&moduleParameter=raumPlanSearch&nextdir=change&next=search.vm&subdir=raum&topitem=facilities&subitem=reservations&purge=n&search_start=Suche+starten&raum.stxt=H%C3%B6rsaal+1")
        XCTAssertEqual(HildesheimRooms.roomURL(4).absoluteString,
                       "https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&status=init&vmfile=no&moduleCall=webInfo&publishConfFile=webInfoRaum&publishSubDir=raum&keep=y&raum.rgid=4")
        XCTAssertEqual(HildesheimRooms.buildingURL(5).absoluteString,
                       "https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&publishContainer=buildingContainer&k_gebaeude.gebid=5")
        XCTAssertEqual(HildesheimRooms.planURL(4, week: "45_2026").absoluteString,
                       "https://lsf.uni-hildesheim.de/qisserver/rds?state=wplan&raum.rgid=4&week=45_2026&act=Raum&pool=Raum&show=plan&P.vx=lang&fil=plu&P.subc=plan")
        XCTAssertEqual(HildesheimRooms.weekKey(clock("2026-11-07T12:00:00").now), "45_2026")
        XCTAssertEqual(HildesheimRooms.weekKey(clock("2027-01-04T00:30:00").now), "1_2027")
        XCTAssertTrue(HildesheimRooms.weekKeyPattern.found(in: "-1"))
        XCTAssertFalse(HildesheimRooms.weekKeyPattern.found(in: "45_2026&x=1"))
    }

    func testParseSearchPages() async throws {
        let demo = HildesheimRoomsDemoHTTP()
        let many = HildesheimRooms.parseSearch(try await demo.get(HildesheimRooms.searchURL("Test")))
        XCTAssertEqual(many, [HildesheimRooms.Hit(rgid: 9001, name: "TC.T.1.01 (Kleiner Testraum)"),
                              HildesheimRooms.Hit(rgid: 9002, name: "TC.T.0.02 (Großer Testsaal)")])
        let one = HildesheimRooms.parseSearch(try await demo.get(HildesheimRooms.searchURL("Testsaal")))
        XCTAssertEqual(one, [HildesheimRooms.Hit(rgid: 9002, name: "TC.T.0.02 (Großer Testsaal)")], "eindeutig: der Raum aus dem Belegungsplan")
        let none = HildesheimRooms.parseSearch(try await demo.get(HildesheimRooms.searchURL("QQQ")))
        XCTAssertEqual(none, [], "kein Treffer: Plan ohne Raum")
        // die Links "mittel"/"lang" des Plans sind keine Treffer
        let planHits = HildesheimRooms.parseSearch(try await demo.get(HildesheimRooms.planURL(9001, week: "-1")))
        XCTAssertFalse(planHits.contains { $0.name == "lang" })
    }

    func testParseRoomBuildingAndPlan() async throws {
        let demo = HildesheimRoomsDemoHTTP()
        let roomHTML = try await demo.get(HildesheimRooms.roomURL(9001))
        let room = try XCTUnwrap(HildesheimRooms.parseRoom(roomHTML, rgid: 9001))
        XCTAssertEqual(room, HildesheimRooms.RoomInfo(rgid: 9001, name: "TC.T.1.01 (Kleiner Testraum)", buildingName: "Gebäude T (Testcampus)",
                                                      gebid: 9100, short: "T 101", floor: "Ebene 1", kind: "Seminarraum"))
        let buildingHTML = try await demo.get(HildesheimRooms.buildingURL(9100))
        let b = try XCTUnwrap(HildesheimRooms.parseBuilding(buildingHTML, gebid: 9100))
        XCTAssertEqual(b, HildesheimRooms.BuildingInfo(gebid: 9100, name: "Gebäude T (Testcampus)", short: "T___", campus: "Testcampus",
                                                       street: "Teststraße 1", zip: "31141", city: "Hildesheim", lat: 52.1345, lon: 9.9762))
        let html = try await demo.get(HildesheimRooms.planURL(9001, week: "45_2026"))
        let plan = HildesheimRooms.parsePlan(html)
        XCTAssertEqual(plan.semester, "WiSe 2026/27")
        XCTAssertEqual(plan.room, "TC.T.1.01 (Kleiner Testraum)")
        XCTAssertEqual(plan.entries, [
            HildesheimRooms.PlanEntry(weekday: 0, day: "Montag", start: "10:00", end: "12:00", title: "1234 Testvorlesung Algorithmen",
                                      rhythm: "wöchentlich", kind: "Vorlesung", startDate: "2026-10-19", endDate: "2027-02-01"),
            HildesheimRooms.PlanEntry(weekday: 2, day: "Mittwoch", start: "14:00", end: "16:00", title: "Klausur Testmodul & Übung",
                                      rhythm: "Einzeltermin", kind: "Klausur", startDate: "2026-11-04", endDate: "2026-11-04"),
        ])
        let text = plan.entries.map { "\($0.title) \($0.kind ?? "")" }.joined()
        XCTAssertFalse(text.contains("Muster"), "Lehrpersonen bleiben weg")
        XCTAssertFalse(text.contains("Institut"), "Einrichtungen bleiben weg")
        // Gebaeudeseite ohne Strasse und ohne Karte
        let bare = HildesheimRoomsDemoHTTP.buildingPage(gebid: 9101, name: "Pavillon T", short: "PT", campus: "Hauptcampus", street: nil,
                                                        zip: "31141", city: "Hildesheim", lat: nil, lon: nil, rooms: [])
        let p = try XCTUnwrap(HildesheimRooms.parseBuilding(bare, gebid: 9101))
        XCTAssertNil(p.street); XCTAssertNil(p.lat)
        let hb = HildesheimRooms.building(from: p)
        XCTAssertEqual(hb.street, "Universitätsplatz 1", "ohne Strasse: Adresse des Campus")
        XCTAssertTrue(hb.addressFromCampus)
        XCTAssertNil(HildesheimRooms.parseRoom("<html><body>Fehler</body></html>", rgid: 1))
    }

    // MARK: Raumcodes und Gebaeudetabelle

    func testRoomCodes() {
        let c = try? XCTUnwrap(HildesheimRooms.code(in: "Gebäude I (Hauptcampus) - HC.I.1.Hörsaal 1"))
        XCTAssertEqual(c?.text, "HC.I.1.Hörsaal 1"); XCTAssertEqual(c?.prefix, "HC.I"); XCTAssertEqual(c?.floor, "1"); XCTAssertEqual(c?.room, "Hörsaal 1")
        XCTAssertNil(c?.description)
        let d = HildesheimRooms.code(in: "HC.N.0.08 (Hörsaal 4)")
        XCTAssertEqual(d?.room, "08"); XCTAssertEqual(d?.description, "Hörsaal 4"); XCTAssertEqual(d?.floor, "0")
        XCTAssertEqual(HildesheimRooms.code(in: "HC.I.-1.06 (Projektraum)")?.floor, "-1")
        XCTAssertEqual(HildesheimRooms.code(in: "BC.LN.0.03 (Seminarraum)")?.prefix, "BC.LN")
        XCTAssertEqual(HildesheimRooms.code(in: "KC.48.0.04 (Atelier, Fachraum Kunst)")?.prefix, "KC.48")
        XCTAssertEqual(HildesheimRooms.code(in: "HC.W2.0.07 (Konferenzraum)")?.prefix, "HC.W2")
        XCTAssertEqual(HildesheimRooms.code(in: "gesperrt-HC.E.1.02 (Seminarraum)")?.prefix, "HC.E")
        let sh = HildesheimRooms.code(in: "SH.0.23 (Seminarraum)")
        XCTAssertEqual(sh?.prefix, "SH"); XCTAssertEqual(sh?.room, "23"); XCTAssertEqual(sh?.floor, "0")
        XCTAssertEqual(HildesheimRooms.code(in: "WL.2.01 Leesterhaus 201")?.prefix, "WL")
        XCTAssertNil(HildesheimRooms.code(in: "Hörsaal 1"))
        XCTAssertNil(HildesheimRooms.code(in: "Online"))
        XCTAssertNil(HildesheimRooms.code(in: "1101 - F102"))
        // Tabelle
        XCTAssertEqual(HildesheimRooms.building(prefix: "HC.I")?.name, "Gebäude I (Hauptcampus)")
        XCTAssertEqual(HildesheimRooms.building(prefix: "hc.sp")?.name, "Gebäude SP (Sport)")
        XCTAssertEqual(HildesheimRooms.building(prefix: "BC.L")?.id, 45)
        XCTAssertEqual(HildesheimRooms.building(prefix: "SH")?.name, "Schützenallee")
        XCTAssertNil(HildesheimRooms.building(prefix: "TC.T"))
        XCTAssertEqual(HildesheimRooms.building(named: "Gebäude I (Hauptcampus)")?.id, 5)
        XCTAssertEqual(HildesheimRooms.building(named: "Vorlesung im Forum")?.name, "Forum")
        XCTAssertEqual(HildesheimRooms.building(named: "Brauhaus, Domäne")?.name, "Hs 48 / Brauhaus")
        XCTAssertEqual(HildesheimRooms.building(named: "Neue Mensa")?.name, "Neue Mensa")
        XCTAssertNil(HildesheimRooms.building(named: "Seminarraum"))
        XCTAssertNil(HildesheimRooms.building(named: "Hs 1 (Hauptcampus)"), "\"Hs 1\" allein ist kein Gebaeude")
    }

    func testBuildingTable() {
        let all = HildesheimRoomsData.buildings
        XCTAssertEqual(all.count, 45)
        XCTAssertEqual(Set(all.map(\.id)).count, 45, "Kennungen eindeutig")
        for b in all where b.campusID != "extern" {
            XCTAssertFalse(b.addressLine.isEmpty || b.city.isEmpty, "\(b.name): Adresse oder Ort fehlt")
            if b.street == nil { XCTAssertNotNil(b.lat, "\(b.name): ohne Strasse mindestens die Lage") }
        }
        var seen: [String: String] = [:]
        for b in all { for c in b.codes { XCTAssertNil(seen[c], "Praefix \(c) doppelt (\(seen[c] ?? "") / \(b.name))"); seen[c] = b.name } }
        XCTAssertEqual(HildesheimRooms.buildingPlaces().count, 44, "ohne 'Externes Gebäude'")
        XCTAssertEqual(HildesheimRooms.buildingPlaces().first?["title"], "Audimax/alte Mensa", "Hauptcampus zuerst, dann Name")
        XCTAssertEqual(HildesheimRooms.buildingPlaces().last?["campus"], "Außenstelle")
        let i = try? XCTUnwrap(HildesheimRooms.building(id: 5))
        XCTAssertEqual(i?.addressLine, "Universitätsplatz 1, 31141 Hildesheim")
        XCTAssertEqual(i?.lat, 52.13452); XCTAssertEqual(i?.lon, 9.97618)
        XCTAssertEqual(HildesheimRooms.building(id: 7)?.addressFromCampus, true, "Gebäude G: Strasse nicht im LSF")
        XCTAssertEqual(HildesheimRooms.building(id: 45)?.addressLine, "Lübecker Straße 3, 31141 Hildesheim")
    }

    func testPlaceFromCodeWithoutNetwork() {
        let b = HildesheimRooms.building(prefix: "HC.I")
        let p = HildesheimRooms.roomPlace(name: "HC.I.1.Hörsaal 1", rgid: nil, building: b)
        XCTAssertEqual(p["title"], "Raum HC.I.1.Hörsaal 1")
        XCTAssertEqual(p["subtitle"], "Gebäude I (Hauptcampus) · 1. Obergeschoss · Universitätsplatz 1, 31141 Hildesheim")
        XCTAssertEqual(p["floor_label"], "1. Obergeschoss")
        XCTAssertEqual(p["position_ok"], true)
        XCTAssertEqual(p["maps"]?["google_route"], "https://www.google.com/maps/dir/?api=1&destination=52.13452%2C9.97618&travelmode=walking")
        XCTAssertEqual(p["maps"]?["apple"], "https://maps.apple.com/?q=Raum%20HC.I.1.H%C3%B6rsaal%201&ll=52.13452%2C9.97618")
        XCTAssertEqual(p["building_url"], "https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&publishContainer=buildingContainer&k_gebaeude.gebid=5")
        XCTAssertEqual(p["note"], .null)
        XCTAssertEqual(p["source"], "lsf")
        let g = HildesheimRooms.roomPlace(name: "HC.G.0.05 (Großer Seminarraum)", rgid: 77, building: HildesheimRooms.building(prefix: "HC.G"))
        XCTAssertEqual(g["title"], "Raum HC.G.0.05 – Großer Seminarraum")
        XCTAssertEqual(g["note"]?.string, HildesheimRooms.noStreet)
        XCTAssertEqual(g["room_url"], "https://lsf.uni-hildesheim.de/qisserver/rds?state=verpublish&status=init&vmfile=no&moduleCall=webInfo&publishConfFile=webInfoRaum&publishSubDir=raum&keep=y&raum.rgid=77")
        let unknown = HildesheimRooms.roomPlace(name: "ZZ.Q.1.01", rgid: nil, building: nil)
        XCTAssertEqual(unknown["note"]?.string, HildesheimRooms.noBuilding)
        XCTAssertEqual(unknown["maps"]?["query"], "Universität Hildesheim ZZ.Q.1.01")
        let bp = HildesheimRooms.buildingPlace(HildesheimRooms.building(id: 56)!)
        XCTAssertEqual(bp["title"], "Forum"); XCTAssertEqual(bp["type"], "building")
        XCTAssertEqual(bp["subtitle"], "Hauptcampus · Universitätsplatz 1, 31141 Hildesheim")
    }

    // MARK: Aufloesen, Suche, Cache

    func testResolveViaTableThenLSF() async throws {
        let http = Counting()
        let finder = HildesheimRoomFinder(http: http, folder: try folder())
        let rooms = LocalRooms()
        rooms.configure(http: RoomFinderDemoHTTP(), folder: nil)
        rooms.configure(hildesheim: finder)
        let c = clock("2026-11-07T12:00:00")
        // Raumcode eines bekannten Gebaeudes: keine Anfrage
        let a = await rooms.resolve("Gebäude I (Hauptcampus) - HC.I.1.Hörsaal 1", university: "hildesheim", clock: c)
        let ap = try XCTUnwrap(a["parts"]?.array?.first)
        XCTAssertEqual(ap["status"], "found")
        XCTAssertEqual(ap["place"]?["title"], "Raum HC.I.1.Hörsaal 1")
        XCTAssertEqual(ap["maps"]?["google_route"], "https://www.google.com/maps/dir/?api=1&destination=52.13452%2C9.97618&travelmode=walking")
        XCTAssertEqual(a["source"]?["key"], "lsf")
        XCTAssertEqual(http.count, 0, "Tabelle genuegt")
        XCTAssertEqual(TerminDetail.route(ap, appInstalled: true), .route("comgooglemaps://?daddr=52.13452%2C9.97618&directionsmode=walking"))
        // unbekanntes Gebaeude: Suche, Raumseite, Gebaeudeseite
        let b = await rooms.resolve("Gebäude T (Testcampus) - TC.T.1.01 (Kleiner Testraum)", university: "hildesheim", clock: c)
        let bp = try XCTUnwrap(b["parts"]?.array?.first)
        XCTAssertEqual(bp["status"], "found")
        XCTAssertEqual(bp["place"]?["subtitle"], "Gebäude T (Testcampus) · 1. Obergeschoss · Teststraße 1, 31141 Hildesheim")
        XCTAssertEqual(bp["place"]?["kind"], "Seminarraum")
        XCTAssertEqual(bp["place"]?["rgid"], 9001)
        XCTAssertEqual(bp["maps"]?["query"], "52.1345,9.9762")
        XCTAssertEqual(http.count, 3)
        // Gebaeudename
        let g = await rooms.resolve("Forum", university: "hildesheim", clock: c)
        XCTAssertEqual(g["parts"]?.array?.first?["status"], "building")
        XCTAssertEqual(g["parts"]?.array?.first?["place"]?["title"], "Forum")
        // freier Text: mehrere Treffer -> Kandidaten
        let m = await rooms.resolve("Test", university: "hildesheim", clock: c)
        let mp = try XCTUnwrap(m["parts"]?.array?.first)
        XCTAssertEqual(mp["status"], "ambiguous")
        XCTAssertEqual(mp["candidates"]?.array?.count, 2)
        XCTAssertEqual(mp["candidates"]?.array?.last?["address"]?["line"], "Teststraße 1, 31141 Hildesheim", "Gebaeude aus dem Cache")
        // nichts im LSF, aber Campus im Text -> Standort; sonst Suchlink
        let cmp = await rooms.resolve("Hörsaal 9 (Bühler-Campus)", university: "hildesheim", clock: c)
        XCTAssertEqual(cmp["parts"]?.array?.first?["status"], "campus")
        XCTAssertEqual(cmp["parts"]?.array?.first?["place"]?["title"], "Bühler-Campus")
        let none = await rooms.resolve("Raum 4711", university: "hildesheim", clock: c)
        XCTAssertEqual(none["parts"]?.array?.first?["status"], "not_found")
        XCTAssertEqual(none["parts"]?.array?.first?["maps"]?["query"], "Universität Hildesheim Raum 4711")
        let online = await rooms.resolve("Online", university: "hildesheim", clock: c)
        XCTAssertEqual(online["parts"]?.array?.first?["status"], "online")
        // ohne Leser: wie bisher (Standorttabelle)
        rooms.configure(hildesheim: nil)
        let old = await rooms.resolve("Hörsaal 9 (Bühler-Campus)", university: "hildesheim", clock: c)
        XCTAssertEqual(old["parts"]?.array?.first?["status"], "campus")
        XCTAssertEqual(old["source"], .null)
    }

    func testSearchCacheAndOffline() async throws {
        let http = Counting()
        let finder = HildesheimRoomFinder(http: http, folder: try folder())
        let c = clock("2026-11-07T12:00:00")
        let r = await finder.search("Test", page: 0, clock: c)
        XCTAssertEqual(r["count"], 2)
        XCTAssertEqual(r["items"]?.array?.first?["title"], "Raum TC.T.1.01 – Kleiner Testraum")
        XCTAssertEqual(r["items"]?.array?.first?["address"]?["line"], "Teststraße 1, 31141 Hildesheim")
        XCTAssertEqual(r["items"]?.array?.first?["building_name"], "Gebäude T (Testcampus)")
        XCTAssertEqual(r["source"]?["name"]?.string, HildesheimRooms.name)
        XCTAssertEqual(http.count, 4, "Suche, zwei Raumseiten, eine Gebaeudeseite (gecacht)")
        _ = await finder.search("test", page: 0, clock: clock("2026-12-05T12:00:00"))
        XCTAssertEqual(http.count, 4, "30 Tage aus dem Cache, Gross-/Kleinschreibung egal")
        _ = await finder.search("Test", page: 0, clock: clock("2026-12-08T12:00:00"))
        XCTAssertEqual(http.count, 8, "danach neu: Suche, Raum- und Gebaeudeseiten")
        let empty = await finder.search("QQQ", page: 0, clock: c)
        XCTAssertEqual(empty["count"], 0)
        _ = await finder.search("QQQ", page: 0, clock: clock("2026-11-07T23:00:00"))
        XCTAssertEqual(http.count, 9, "nichts gefunden: einen Tag gemerkt")
        _ = await finder.search("QQQ", page: 0, clock: clock("2026-11-09T12:00:00"))
        XCTAssertEqual(http.count, 10)
        // Gebaeudename als Suche: Gebaeude vorneweg (aus der Tabelle), dazu die Raumsuche im LSF
        let forum = await finder.search("Forum", page: 0, clock: c)
        XCTAssertEqual(forum["items"]?.array?.first?["type"], "building")
        XCTAssertEqual(forum["items"]?.array?.first?["title"], "Forum")
        XCTAssertEqual(http.count, 11)
        let blank = await finder.search("", page: 0, clock: c)
        XCTAssertEqual(blank["count"], 0)
        XCTAssertEqual(http.count, 11, "leer: keine Anfrage")
        // ohne Netz: alter Stand mit Hinweis, Unbekanntes mit Suchlink
        http.offline = true
        let stale = await finder.search("Test", page: 0, clock: clock("2027-03-01T12:00:00"))
        XCTAssertEqual(stale["stale"], true)
        XCTAssertEqual(stale["count"], 2)
        XCTAssertEqual(stale["message"]?.string, HildesheimRooms.offline)
        let gone = await finder.search("Neu", page: 0, clock: c)
        XCTAssertEqual(gone["stale"], true)
        XCTAssertEqual(gone["items"]?.array?.count, 0)
        let part = Rooms.parse("TC.U.2.09", university: "hildesheim")["parts"]?.array?.first ?? .null
        let (off, s) = await finder.resolvePart(part, clock: c)
        XCTAssertTrue(s)
        XCTAssertEqual(off["status"], "offline")
        XCTAssertEqual(off["maps"]?["query"], "Universität Hildesheim TC.U.2.09")
        let known = Rooms.parse("HC.N.0.08 (Hörsaal 4)", university: "hildesheim")["parts"]?.array?.first ?? .null
        let knownOut = await finder.resolvePart(known, clock: c).0
        XCTAssertEqual(knownOut["status"], "found", "Tabelle auch ohne Netz")
    }

    func testPlaceAndPlan() async throws {
        let http = Counting()
        let finder = HildesheimRoomFinder(http: http, folder: nil)
        let c = clock("2026-11-07T12:00:00")
        let p = await finder.place(rgid: 9002, clock: c)
        XCTAssertEqual(p["place"]?["title"], "Raum TC.T.0.02 – Großer Testsaal")
        XCTAssertEqual(p["place"]?["floor_label"], "Erdgeschoss")
        XCTAssertEqual(p["place"]?["kind"], "Hörsaal")
        XCTAssertEqual(p["place"]?["gebid"], 9100)
        XCTAssertEqual(http.count, 2)
        let missing = await finder.place(rgid: 1, clock: c)
        XCTAssertEqual(missing["place"], .null)
        XCTAssertEqual(missing["message"], "Raum nicht im LSF gefunden.")
        let plan = await finder.plan(rgid: 9001, week: nil, clock: c)
        XCTAssertEqual(plan["week"], "45_2026")
        XCTAssertEqual(plan["semester"], "WiSe 2026/27")
        XCTAssertEqual(plan["entries"]?.array?.count, 2)
        XCTAssertEqual(plan["entries"]?.array?.first?["day"], "Montag")
        XCTAssertEqual(plan["entries"]?.array?.first?["start"], "10:00")
        XCTAssertEqual(plan["entries"]?.array?.last?["rhythm"], "Einzeltermin")
        XCTAssertEqual(plan["entries"]?.array?.last?["title"], "Klausur Testmodul & Übung")
        let before = http.count
        _ = await finder.plan(rgid: 9001, week: "45_2026", clock: clock("2026-11-07T15:00:00"))
        XCTAssertEqual(http.count, before, "6 Stunden aus dem Cache")
        _ = await finder.plan(rgid: 9001, week: "45_2026", clock: clock("2026-11-07T19:00:00"))
        XCTAssertEqual(http.count, before + 1)
        let bad = await finder.plan(rgid: 9001, week: "45_2026&x", clock: c)
        XCTAssertEqual(bad["message"], "Ungültige Woche.")
        let noPlan = await finder.plan(rgid: 1, week: "45_2026", clock: c)
        XCTAssertEqual(noPlan["entries"]?.array?.count, 0)
        XCTAssertEqual(noPlan["message"], "Kein Belegungsplan für diesen Raum im LSF.")
    }

    func testEndpoints() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock("2026-11-07T12:00:00"), university: "hildesheim")
        let http = Counting()
        b.context.rooms.configure(http: RoomFinderDemoHTTP(), folder: nil)
        b.context.rooms.configure(hildesheim: HildesheimRoomFinder(http: http, folder: nil))
        func get(_ p: String) async -> LocalResponse { await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + p)!)) }
        func json(_ p: String) async throws -> JSONValue {
            let v = await get(p).json
            return try XCTUnwrap(v)
        }
        let campuses = try await json("/api/rooms/campuses")
        XCTAssertEqual(campuses["finder"], true)
        XCTAssertEqual(campuses["source"]?["key"], "lsf")
        XCTAssertEqual(campuses["campuses"]?.array?.count, 4)
        XCTAssertEqual(campuses["buildings"]?.array?.count, 44)
        XCTAssertEqual(campuses["note"], .null)
        let hsh = try await json("/api/rooms/campuses?university=hsh")
        XCTAssertEqual(hsh["finder"], false)
        let search = try await json("/api/rooms/search?q=Testsaal")
        XCTAssertEqual(search["count"], 1)
        XCTAssertEqual(search["items"]?.array?.first?["id"], "lsf:9002")
        let luh = try await json("/api/rooms/search?q=Audimax&university=luh")
        XCTAssertEqual(luh["items"]?.array?.first?["title"], "Raum E415 – Audimax", "LUH-Suche unveraendert")
        let resolve = try await json("/api/rooms/resolve?text=HC.I.1.H%C3%B6rsaal%201")
        XCTAssertEqual(resolve["university"], "hildesheim")
        XCTAssertEqual(resolve["parts"]?.array?.first?["status"], "found")
        let place = try await json("/api/rooms/place?rgid=9001")
        XCTAssertEqual(place["place"]?["title"], "Raum TC.T.1.01 – Kleiner Testraum")
        let badID = await get("/api/rooms/place?rgid=x").status
        XCTAssertEqual(badID, 422)
        let plan = try await json("/api/rooms/plan?rgid=9001&week=46_2026")
        XCTAssertEqual(plan["week"], "46_2026")
        XCTAssertEqual(plan["entries"]?.array?.count, 2)
        b.context.rooms.configure(hildesheim: nil)
        let noPlan = await get("/api/rooms/plan?rgid=9001").status
        XCTAssertEqual(noPlan, 404, "ohne Leser kein Plan")
        let noFinder = try await json("/api/rooms/campuses")
        XCTAssertEqual(noFinder["finder"], false)
    }
}
