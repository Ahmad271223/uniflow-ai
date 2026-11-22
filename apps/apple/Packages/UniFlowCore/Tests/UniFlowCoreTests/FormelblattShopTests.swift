import Foundation
import XCTest
@testable import UniFlowCore

/// Formelblaetter (22.11.2026): das Geraet nennt nur den Modulnamen, kauft beim Dienst und legt das PDF in den Ordner
/// „Formelblätter“ des Moduls; ohne StudiNow-KI oder ohne Pro AI bleibt die Liste leer.
final class FormelblattShopTests: XCTestCase {
    private struct Tools: LocalDocumentTools {
        func pdfPageCount(_ data: Data) -> Int? { 2 }
        func pdfFromImage(_ data: Data) -> Data? { nil }
        func pdfPageTexts(_ url: URL) -> [String]? { nil }
    }
    private struct Yes: AIConsentGate { func ensureConsent() async -> Bool { true } }
    private struct Tokens: AccountTokenStore {
        func load() -> String? { "sitzung" }
        func save(_ token: String?) throws {}
    }

    private final class FakeService: ServiceHTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [AIHTTPRequest] = []
        var owned = false
        var version = "2026-11-22"
        var offerStatus = 200

        func body(_ r: AIHTTPRequest) -> JSONValue { (try? JSONValue.parse(r.body ?? Data())) ?? .null }
        func item() -> JSONValue {
            ["id": "luh-gds-kurzklausur", "title": "Formelblatt Kurzklausur", "module": "Grundlagen digitaler Systeme",
             "credits": 3, "pages": 2, "version": .string(version), "description": "Regeln", "owned": .bool(owned)]
        }
        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            lock.withLock { requests.append(r) }
            if r.url.hasSuffix("/api/formelblatt/offer") {
                if offerStatus != 200 { return .init(status: offerStatus, body: Data(#"{"detail": {"detail": "Pro AI", "code": "plan_required"}}"#.utf8)) }
                let mods = body(r)["modules"]?.array?.compactMap(\.string) ?? []
                let items: [JSONValue] = mods.contains("Grundlagen digitaler Systeme") ? [item()] : []
                return .init(status: 200, body: JSONValue.object(["items": .array(items)]).serialized())
            }
            if r.url.hasSuffix("/buy") {
                let charged = owned ? 0 : 3
                owned = true
                return .init(status: 200, body: JSONValue.object(["item": item(), "credits_charged": .number(Double(charged))]).serialized())
            }
            if r.url.hasSuffix("/pdf") { return .init(status: owned ? 200 : 404, body: Data("%PDF-1.4 Blatt".utf8)) }
            return .init(status: 404, body: Data())
        }
    }

    private var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("formelblatt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func backend(_ svc: FakeService?) async throws -> LocalBackend {
        let files = LocalFiles(container: dir, dataDirectory: "", tools: Tools())
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-22T10:00:00")!, files: files)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (3, 'Grundlagen digitaler Systeme', '#175ee8', 0), (4, 'Analysis', '#175ee8', 1)")
        }
        if let svc { b.context.ai.setService(StudiNowAI(base: "https://app.example", http: svc, tokens: Tokens(), consent: Yes())) }
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, status: Int = 200) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!, body: method == "POST" ? Data("{}".utf8) : Data()))
        XCTAssertEqual(r.status, status, "\(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    func testOfferBuyAndStoreInModuleFolder() async throws {
        let svc = FakeService()
        let b = try await backend(svc)
        let offer = await call(b, "GET", "/api/modules/3/formelblatt")
        XCTAssertEqual(offer["items"]?.array?.first?["credits"]?.int, 3)
        XCTAssertNil(offer["items"]?.array?.first?["file_id"])
        XCTAssertEqual(svc.body(svc.requests[0]), ["modules": ["Grundlagen digitaler Systeme"]], "nur der Name des offenen Moduls")

        let got = await call(b, "POST", "/api/modules/3/formelblatt/luh-gds-kurzklausur/get")
        XCTAssertEqual(got["credits_charged"]?.int, 3)
        let fid = try XCTUnwrap(got["file_id"]?.string)
        let row = try await b.context.database.withConnection { c in
            try c.queryOne("SELECT f.title, f.course_id, d.name AS folder, d.module_id FROM files f JOIN folders d ON d.id=f.folder_id WHERE f.id=?", [.text(fid)])
        }
        XCTAssertEqual(row?["title"]?.string, "Formelblatt Kurzklausur")
        XCTAssertEqual(row?["course_id"]?.string, "__user__")
        XCTAssertEqual(row?["folder"]?.string, "Formelblätter")
        XCTAssertEqual(row?["module_id"]?.int, 3)

        let again = await call(b, "GET", "/api/modules/3/formelblatt")
        XCTAssertEqual(again["items"]?.array?.first?["file_id"]?.string, fid)
        XCTAssertEqual(again["items"]?.array?.first?["current"]?.bool, true)

        // neue Fassung beim Dienst: Karte zeigt "nicht aktuell", Laden kostet nichts
        svc.version = "2026-12-01"
        let newer = await call(b, "GET", "/api/modules/3/formelblatt")
        XCTAssertEqual(newer["items"]?.array?.first?["current"]?.bool, false)
        let reload = await call(b, "POST", "/api/modules/3/formelblatt/luh-gds-kurzklausur/get")
        XCTAssertEqual(reload["credits_charged"]?.int, 0)
        XCTAssertNotEqual(reload["file_id"]?.string, fid)
    }

    func testOtherModuleWithoutServiceOrPlanShowsNothing() async throws {
        let svc = FakeService()
        let b = try await backend(svc)
        let other = await call(b, "GET", "/api/modules/4/formelblatt")
        XCTAssertEqual(other["items"]?.array?.count, 0)

        svc.offerStatus = 403
        let plus = await call(b, "GET", "/api/modules/3/formelblatt")
        XCTAssertEqual(plus["items"]?.array?.count, 0, "ohne Pro AI keine Karte, kein Fehler")

        let none = try await backend(nil)
        let local = await call(none, "GET", "/api/modules/3/formelblatt")
        XCTAssertEqual(local["items"]?.array?.count, 0)
        _ = await call(none, "POST", "/api/modules/3/formelblatt/luh-gds-kurzklausur/get", status: 403)
        _ = await call(none, "POST", "/api/modules/3/formelblatt/..%2Fx/get", status: 404)
    }
}
