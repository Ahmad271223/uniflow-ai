import Foundation
import XCTest
@testable import UniFlowCore

/// Erklaerungen von StudiNow (22.11.2026): nur Pruefsummen an den Dienst, Angebot 10 Minuten gemerkt, gekaufte PDFs im
/// Ordner „StudiNow-Erklärungen“ des Moduls, nie doppelt geladen.
final class ErklaerungShopTests: XCTestCase {

    private struct Tools: LocalDocumentTools {
        func pdfPageCount(_ data: Data) -> Int? { 3 }
        func pdfFromImage(_ data: Data) -> Data? { nil }
        func pdfPageTexts(_ url: URL) -> [String]? { nil }
    }

    private struct Yes: AIConsentGate { func ensureConsent() async -> Bool { true } }
    private struct Tokens: AccountTokenStore {
        func load() -> String? { "sitzung" }
        func save(_ token: String?) throws {}
    }

    /// Schein-Dienst: Erklaerungen zu bekannten Pruefsummen, Kaeufe des Kontos, PDFs
    private final class FakeService: ServiceHTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [AIHTTPRequest] = []
        /// sha256 -> (Titel, Art)
        var index: [String: (String, String)] = [:]
        var owned: Set<String> = []
        var enabled = true
        var creditsLeft = 100

        func body(_ r: AIHTTPRequest) -> JSONValue { (try? JSONValue.parse(r.body ?? Data())) ?? .null }

        func item(_ sha: String) -> JSONValue {
            let e = index[sha] ?? ("", "")
            return ["sha256": .string(sha), "title": .string(e.0), "kind": .string(e.1), "pages": 12, "owned": .bool(owned.contains(sha)), "stand": "2026-11-22"]
        }

        func count(_ suffix: String) -> Int { lock.withLock { requests.filter { $0.url.hasSuffix(suffix) }.count } }

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            lock.withLock { requests.append(r) }
            if r.url.hasSuffix("/api/erklaerungen/offer") {
                let shas = (body(r)["sha256"]?.array ?? []).compactMap(\.string)
                let items = enabled ? shas.filter { index[$0] != nil }.map(item) : []
                return .init(status: 200, body: JSONValue.object(["enabled": .bool(enabled), "price": 15, "items": .array(items)]).serialized())
            }
            if r.url.hasSuffix("/api/erklaerungen/buy") {
                let sha = body(r)["sha256"]?.string ?? ""
                guard index[sha] != nil else {
                    return .init(status: 404, body: Data(#"{"detail": {"detail": "Keine Erklärung", "code": "not_available"}}"#.utf8))
                }
                if owned.contains(sha) {
                    var o = item(sha).object ?? [:]; o["charged"] = 0
                    return .init(status: 200, body: JSONValue.object(o).serialized())
                }
                guard creditsLeft >= 15 else {
                    return .init(status: 429, body: Data(#"{"detail": {"detail": "Deine Credits reichen nicht.", "code": "credits_exhausted", "credits": {"balance": 3}}}"#.utf8))
                }
                creditsLeft -= 15
                owned.insert(sha)
                var o = item(sha).object ?? [:]; o["charged"] = 15
                return .init(status: 200, body: JSONValue.object(o).serialized())
            }
            if r.url.hasSuffix("/api/erklaerungen/mine") {
                return .init(status: 200, body: JSONValue.object(["items": .array(owned.sorted().map(item))]).serialized())
            }
            if r.url.hasSuffix("/pdf") {
                let sha = r.url.components(separatedBy: "/").dropLast().last ?? ""
                guard owned.contains(sha) else { return .init(status: 402, body: Data(#"{"detail": {"detail": "nicht gekauft", "code": "not_owned"}}"#.utf8)) }
                return .init(status: 200, body: Data("%PDF-1.4 Erklärung \(sha)".utf8))
            }
            return .init(status: 404, body: Data())
        }
    }

    /// verstellbare Uhr fuer den Merker
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var date = Date(timeIntervalSince1970: 1_795_000_000)
        func now() -> Date { lock.withLock { date } }
        func advance(_ s: TimeInterval) { lock.withLock { date += s } }
    }

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("erklaerung-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// zwei PDFs im Modul „Analysis“ (eine mit gemerkter Pruefsumme, eine ohne) und ein Video
    private func backend(_ service: FakeService?, clock: Clock = Clock()) async throws -> LocalBackend {
        let files = LocalFiles(container: dir, dataDirectory: "", tools: Tools())
        _ = try files.write(Data("Folgen und Reihen".utf8), to: "vl3.pdf")
        _ = try files.write(Data("Blatt 2".utf8), to: "ub2.pdf")
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock { clock.now() }, files: files)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis', '#175ee8', 0)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('c1', 'Analysis', 'Analysis', 'vorlesung', 1, 1, 't')")
            try c.execute("""
                INSERT INTO files(id, course_id, name, chdate, status, local_path, content_sha256) VALUES
                ('f-vl3', 'c1', 'VL 3 Folgen.pdf', 10, 'neu', 'vl3.pdf', ?),
                ('f-ub2', 'c1', 'Übung 2.pdf', 20, 'neu', 'ub2.pdf', NULL),
                ('f-mp4', 'c1', 'Aufzeichnung.mp4', 30, 'neu', NULL, ?)
                """, [.text(Self.shaVL.uppercased()), .text(String(repeating: "e", count: 64))])
        }
        if let service {
            b.context.ai.setService(StudiNowAI(base: "https://app.example", http: service, tokens: Tokens(), consent: Yes()))
        }
        return b
    }

    private static let shaVL = String(repeating: "a", count: 64)
    /// SHA-256 von „Blatt 2“ (die Datei ohne gemerkte Pruefsumme)
    private static let shaUB = SolutionSHA256.hex(Data("Blatt 2".utf8))

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue = .object([:]), status: Int = 200) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!, body: body.serialized()))
        XCTAssertEqual(r.status, status, "\(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    private func explanationFiles(_ b: LocalBackend) async throws -> [String] {
        try await b.context.database.withConnection { c in
            try c.query("""
                SELECT f.name, f.course_id, d.name AS folder, d.module_id, f.page_count FROM files f JOIN folders d ON d.id=f.folder_id
                WHERE f.course_id='__user__' AND f.deleted_at IS NULL ORDER BY f.name
                """).map { "\($0["name"]?.string ?? "")|\($0["course_id"]?.string ?? "")|\($0["folder"]?.string ?? "")|\($0["module_id"]?.int ?? 0)|\($0["page_count"]?.int ?? 0)" }
        }
    }

    func testOfferSendsOnlyChecksumsAndRemembersThemAndTheAnswer() async throws {
        let service = FakeService()
        service.index = [Self.shaVL: ("Erklärung VL 3", "Erklärung Seite für Seite")]
        let clock = Clock()
        let b = try await backend(service, clock: clock)

        let offer = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3", "f-ub2", "f-mp4", "gibt-es-nicht"]])
        XCTAssertEqual(offer["enabled"]?.bool, true)
        XCTAssertEqual(offer["price"]?.int, 15)
        let items = offer["items"]?.array ?? []
        XCTAssertEqual(items.count, 1, "nur die Datei mit Angebot")
        XCTAssertEqual(items.first?["file_id"]?.string, "f-vl3")
        XCTAssertEqual(items.first?["sha256"]?.string, Self.shaVL, "klein geschrieben")
        XCTAssertEqual(items.first?["kind"]?.string, "Erklärung Seite für Seite")
        XCTAssertEqual(items.first?["pages"]?.int, 12)
        XCTAssertEqual(items.first?["owned"]?.bool, false)
        XCTAssertNil(items.first?["local_file_id"])

        // an den Dienst: nur Pruefsummen der PDFs (die fehlende einmal berechnet), keine Namen, kein Video
        XCTAssertEqual(service.count("/offer"), 1)
        let sent = service.body(service.requests[0])
        XCTAssertEqual(Set((sent["sha256"]?.array ?? []).compactMap(\.string)), [Self.shaVL, Self.shaUB])
        let raw = String(decoding: service.requests[0].body ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.contains("Folgen") || raw.contains("Übung") || raw.contains("f-vl3"), "keine Dateinamen, keine Kennungen")
        let stored = try await b.context.database.withConnection { try $0.scalar("SELECT content_sha256 FROM files WHERE id='f-ub2'")?.string }
        XCTAssertEqual(stored, Self.shaUB, "Pruefsumme gemerkt")

        // gleich noch einmal (Scrollen, Neuladen): aus dem Merker, auch das „kein Angebot“ der Übung
        let again = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3", "f-ub2"]])
        XCTAssertEqual(again["items"]?.array?.count, 1)
        XCTAssertEqual(again["enabled"]?.bool, true)
        XCTAssertEqual(service.count("/offer"), 1, "kein zweites Fragen innerhalb von 10 Minuten")

        // nach 10 Minuten fragt die Liste wieder
        clock.advance(601)
        _ = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3", "f-ub2"]])
        XCTAssertEqual(service.count("/offer"), 2)
    }

    func testSwitchedOffServiceShowsNothing() async throws {
        let service = FakeService()
        service.index = [Self.shaVL: ("Erklärung VL 3", "Erklärung Seite für Seite")]
        service.enabled = false
        let b = try await backend(service)
        let offer = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3"]])
        XCTAssertEqual(offer["enabled"]?.bool, false)
        XCTAssertEqual(offer["items"]?.array?.count, 0)
    }

    func testBuyStoresThePDFNextToTheFileAndNeverDownloadsTwice() async throws {
        let service = FakeService()
        service.index = [Self.shaVL: ("Erklärung VL 3", "Erklärung Seite für Seite")]
        let b = try await backend(service)
        _ = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3"]])

        let bought = await post(b, "/api/files/f-vl3/erklaerung/buy")
        XCTAssertEqual(bought["owned"]?.bool, true)
        XCTAssertEqual(bought["charged"]?.int, 15)
        XCTAssertEqual(bought["file_id"]?.string, "f-vl3")
        XCTAssertEqual(bought["folder"]?.string, "StudiNow-Erklärungen")
        XCTAssertEqual(bought["module_id"]?.int, 1)
        let local = try XCTUnwrap(bought["local_file_id"]?.string)
        XCTAssertEqual(service.body(service.requests.first { $0.url.hasSuffix("/buy") }!)["sha256"]?.string, Self.shaVL)
        let files = try await explanationFiles(b)
        XCTAssertEqual(files, ["VL 3 Folgen – Erklärung StudiNow.pdf|__user__|StudiNow-Erklärungen|1|3"])
        let path = try await b.context.database.withConnection { try $0.scalar("SELECT local_path FROM files WHERE id=?", [.text(local)])?.string }
        let data = try Data(contentsOf: XCTUnwrap(b.context.files?.url(stored: XCTUnwrap(path))))
        XCTAssertTrue(data.starts(with: Array("%PDF".utf8)))

        // das Angebot zeigt sofort „gekauft“ mit der abgelegten Datei (ohne neu zu fragen)
        let offer = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3", .string(local)]])
        XCTAssertEqual(offer["items"]?.array?.count, 1, "die abgelegte Erklaerung selbst hat kein Angebot")
        XCTAssertEqual(offer["items"]?.array?.first?["owned"]?.bool, true)
        XCTAssertEqual(offer["items"]?.array?.first?["local_file_id"]?.string, local)
        XCTAssertEqual(service.count("/offer"), 1)

        // noch einmal antippen: kostet beim Dienst nichts, wird nicht noch einmal geladen
        let twice = await post(b, "/api/files/f-vl3/erklaerung/buy")
        XCTAssertEqual(twice["charged"]?.int, 0)
        XCTAssertEqual(twice["local_file_id"]?.string, local)
        XCTAssertEqual(service.count("/pdf"), 1)
        let count1 = try await explanationFiles(b).count
        XCTAssertEqual(count1, 1)

        // Abholen von selbst: liegt schon da, nichts Neues
        let got = await post(b, "/api/erklaerungen/collect")
        XCTAssertEqual(got["added"]?.array?.count, 0)
        XCTAssertEqual(service.count("/pdf"), 1)

        // geloescht: Antippen holt sie wieder (kostenlos), Abholen von selbst nicht
        try await b.context.database.execute("UPDATE files SET deleted_at='2026-11-22T12:00:00' WHERE id=?", [.text(local)])
        let auto = await post(b, "/api/erklaerungen/collect")
        XCTAssertEqual(auto["added"]?.array?.count, 0, "bewusst geloescht: kommt von selbst nicht wieder")
        let back = await post(b, "/api/files/f-vl3/erklaerung/buy")
        XCTAssertNotEqual(back["local_file_id"]?.string, local)
        XCTAssertEqual(service.count("/pdf"), 2)
        let count2 = try await explanationFiles(b).count
        XCTAssertEqual(count2, 1)
    }

    func testBuyErrorsPassThrough() async throws {
        let service = FakeService()
        service.index = [Self.shaVL: ("Erklärung VL 3", "Erklärung Seite für Seite")]
        service.creditsLeft = 3
        let b = try await backend(service)
        let poor = await post(b, "/api/files/f-vl3/erklaerung/buy", status: 429)
        XCTAssertEqual(poor["detail"]?["code"]?.string, "credits_exhausted")
        XCTAssertEqual(poor["detail"]?["credits"]?["balance"]?.int, 3, "Credits-Angaben fuer den Hinweis der App")
        let none = await post(b, "/api/files/f-ub2/erklaerung/buy", status: 404)
        XCTAssertEqual(none["detail"]?["code"]?.string, "not_available")
        let video = await post(b, "/api/files/f-mp4/erklaerung/buy", status: 404)
        XCTAssertEqual(video["detail"]?["code"]?.string, "not_available")
        XCTAssertEqual(service.count("/pdf"), 0)
        let count3 = try await explanationFiles(b).count
        XCTAssertEqual(count3, 0)
    }

    func testCollectStoresWhatWasBoughtOnAnotherDevice() async throws {
        let service = FakeService()
        let other = String(repeating: "c", count: 64)
        service.index = [Self.shaVL: ("Erklärung VL 3", "Erklärung Seite für Seite"), Self.shaUB: ("Lösung Blatt 2", "Lösung Schritt für Schritt"),
                         other: ("Fremde Datei", "Erklärung Seite für Seite")]
        service.owned = [Self.shaVL, other]
        let b = try await backend(service)

        let got = await post(b, "/api/erklaerungen/collect")
        let added = got["added"]?.array ?? []
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?["file_id"]?.string, "f-vl3")
        XCTAssertEqual(added.first?["module"]?.string, "Analysis")
        XCTAssertEqual(added.first?["title"]?.string, "VL 3 Folgen – Erklärung StudiNow")
        XCTAssertEqual(got["unplaced"]?.int, 1, "zur dritten gibt es hier keine Datei")
        XCTAssertFalse(service.requests.contains { $0.url.hasSuffix("/buy") }, "Abholen kauft nie")

        // danach zeigt das Angebot sie als gekauft (ohne den Dienst zu fragen, Merker aus dem Abholen)
        let offer = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3"]])
        XCTAssertEqual(offer["items"]?.array?.first?["owned"]?.bool, true)
        XCTAssertEqual(offer["items"]?.array?.first?["local_file_id"]?.string, added.first?["local_file_id"]?.string)

        // Kauf am anderen Geraet + Abholen gleichzeitig mit einem Kauf hier: genau eine Datei
        service.owned.insert(Self.shaUB)
        _ = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-ub2"]])
        async let x = post(b, "/api/erklaerungen/collect")
        async let y = post(b, "/api/files/f-ub2/erklaerung/buy")
        _ = await (x, y)
        let files = try await explanationFiles(b)
        XCTAssertEqual(files, ["VL 3 Folgen – Erklärung StudiNow.pdf|__user__|StudiNow-Erklärungen|1|3",
                               "Übung 2 – Erklärung StudiNow.pdf|__user__|StudiNow-Erklärungen|1|3"])
        XCTAssertEqual(service.count("/pdf"), 2)
    }

    func testWithoutStudiNowAINothingIsSent() async throws {
        let b = try await backend(nil)
        let d = await post(b, "/api/erklaerungen/offer", ["file_ids": ["f-vl3"]], status: 403)
        XCTAssertEqual(d["detail"]?["code"]?.string, "erklaerung_needs_service")
        _ = await post(b, "/api/erklaerungen/collect", status: 403)
        _ = await post(b, "/api/files/f-vl3/erklaerung/buy", status: 403)
    }

    func testTitleOfTheStoredFile() {
        XCTAssertEqual(ErklaerungShop.title(forFile: "VL 3 Folgen.pdf"), "VL 3 Folgen – Erklärung StudiNow")
        XCTAssertEqual(ErklaerungShop.title(forFile: "Blatt.PDF"), "Blatt – Erklärung StudiNow")
        XCTAssertEqual(ErklaerungShop.title(forFile: ".pdf"), "Datei – Erklärung StudiNow")
    }
}
