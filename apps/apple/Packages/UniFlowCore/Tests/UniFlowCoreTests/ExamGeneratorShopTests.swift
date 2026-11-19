import Foundation
import XCTest
@testable import UniFlowCore

/// Klausur-Generator, Kauf auf dem Geraet (18.11.2026): nur Fingerabdruecke an den Dienst, Seitentexte nur bei
/// `needs_texts`, fertige PDFs im Ordner „Probeklausuren“ des Moduls.
final class ExamGeneratorShopTests: XCTestCase {

    private struct TextTools: LocalDocumentTools {
        func pdfPageCount(_ data: Data) -> Int? { 2 }
        func pdfFromImage(_ data: Data) -> Data? { nil }
        func pdfPageTexts(_ url: URL) -> [String]? { (try? String(contentsOf: url, encoding: .utf8)).map { [$0, "Seite zwei"] } }
    }

    private struct Yes: AIConsentGate { func ensureConsent() async -> Bool { true } }
    private struct Tokens: AccountTokenStore {
        func load() -> String? { "sitzung" }
        func save(_ token: String?) throws {}
    }

    /// Schein-Dienst: beim ersten Kauf 409 needs_texts, danach fertig; PDFs zum Herunterladen
    private final class FakeShop: ServiceHTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [AIHTTPRequest] = []
        var hasTexts = false
        var paid = false

        func body(_ r: AIHTTPRequest) -> JSONValue { (try? JSONValue.parse(r.body ?? Data())) ?? .null }

        func state() -> JSONValue {
            var v: [JSONValue] = []
            for n in 1...10 {
                let key = "pk-" + String(repeating: "1", count: 40) + "-" + String(format: "%02d", n)
                let ready = n == 1 && (paid || hasTexts)
                let mine = n == 1 && paid
                let item: [String: JSONValue] = ["variant": .number(Double(n)), "key": .string(key),
                                                 "status": .string(ready ? "ready" : "none"), "owned": .bool(mine), "paid": .bool(mine)]
                v.append(.object(item))
            }
            let out: [String: JSONValue] = ["set_key": .string(String(repeating: "1", count: 40)), "price": .number(15),
                                            "variants": .array(v), "ready": .number(paid ? 1 : 0)]
            return .object(out)
        }

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            lock.withLock { requests.append(r) }
            if r.url.hasSuffix("/api/exam-shop/offer") { return .init(status: 200, body: state().serialized()) }
            if r.url.hasSuffix("/api/exam-shop/buy") {
                if body(r)["texts"] == nil && !hasTexts {
                    return .init(status: 409, body: Data(#"{"detail": {"detail": "Seitentexte", "code": "needs_texts"}}"#.utf8))
                }
                hasTexts = true
                paid = true
                return .init(status: 200, body: state().serialized())
            }
            if r.url.contains("/pdf/") { return .init(status: 200, body: Data("%PDF-1.4 \(r.url)".utf8)) }
            return .init(status: 404, body: Data())
        }
    }

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("examshop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func backend(_ shop: FakeShop?) async throws -> LocalBackend {
        let files = LocalFiles(container: dir, dataDirectory: "", tools: TextTools())
        _ = try files.write(Data("Folgen und Reihen".utf8), to: "vl1.pdf")
        _ = try files.write(Data("Aufgabe 1".utf8), to: "blatt1.pdf")
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-18T10:00:00")!, files: files)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis', '#175ee8', 0)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('c1', 'Analysis', 'Analysis', 'vorlesung', 1, 1, 't')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, local_path) VALUES ('f-vl', 'c1', 'VL01 Folgen.pdf', 10, 'neu', 'vl1.pdf'), ('f-ub', 'c1', 'Blatt 1.pdf', 20, 'neu', 'blatt1.pdf')")
        }
        if let shop {
            b.context.ai.setService(StudiNowAI(base: "https://app.example", http: shop, tokens: Tokens(), consent: Yes()))
        }
        return b
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue, status: Int = 200) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!, body: body.serialized()))
        XCTAssertEqual(r.status, status, "\(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    func testBuySendsTextsOnlyWhenNeededAndCollectsPDFsIntoTheModule() async throws {
        let shop = FakeShop()
        let b = try await backend(shop)
        let sel: JSONValue = ["file_ids": ["f-vl", "f-ub"], "count": 1]

        let offer = await post(b, "/api/modules/1/exam-generator/offer", sel)
        XCTAssertEqual(offer["price"]?.int, 15)
        let sent = shop.body(shop.requests[0])
        XCTAssertEqual(Set((sent["files"]?.array ?? []).compactMap { $0["doc_type"]?.string }), ["vorlesung", "uebung"])
        XCTAssertNil(sent["texts"], "zum Anschauen gehen keine Seitentexte mit")
        XCTAssertFalse(String(decoding: shop.requests[0].body ?? Data(), as: UTF8.self).contains("Folgen"), "keine Dateinamen, keine Texte")

        let bought = await post(b, "/api/modules/1/exam-generator/buy", sel)
        XCTAssertEqual(bought["variants"]?.array?.first?["paid"]?.bool, true)
        let buys = shop.requests.filter { $0.url.hasSuffix("/buy") }
        XCTAssertEqual(buys.count, 2, "erst ohne, nach needs_texts mit Seitentexten")
        XCTAssertNil(shop.body(buys[0])["texts"])
        let texts = shop.body(buys[1])["texts"]?.array ?? []
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.first { $0["title"]?.string == "VL01 Folgen.pdf" }?["pages"]?.array?.first?.string, "Folgen und Reihen")

        let got = await post(b, "/api/modules/1/exam-generator/collect", sel)
        XCTAssertEqual(got["added"]?.array?.count, 2, "Aufgaben und Lösungen")
        XCTAssertEqual(got["pending"]?.int, 0)
        let rows = try await b.context.database.withConnection { c in
            try c.query("SELECT f.title, f.course_id, d.name AS folder, d.module_id FROM files f JOIN folders d ON d.id=f.folder_id WHERE f.course_id='__user__' ORDER BY f.title")
                .map { "\($0["title"]?.string ?? "")|\($0["course_id"]?.string ?? "")|\($0["folder"]?.string ?? "")|\($0["module_id"]?.int ?? 0)" }
        }
        XCTAssertEqual(rows, ["Probeklausur 1 – Aufgaben|__user__|Probeklausuren|1", "Probeklausur 1 – Lösungen|__user__|Probeklausuren|1"])

        // zweites Abholen legt nichts doppelt ab; die Dateien stehen am Eintrag
        let again = await post(b, "/api/modules/1/exam-generator/collect", sel)
        XCTAssertEqual(again["added"]?.array?.count, 0)
        XCTAssertEqual(again["variants"]?.array?.first?["files"]?.object?.count, 2)

        // die eigenen Probeklausuren tauchen in der Auswahl des Moduls nicht auf
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules/1/exam-generator/files")!, body: Data()))
        XCTAssertEqual((r.json?["files"]?.array ?? []).compactMap { $0["id"]?.string }.sorted(), ["f-ub", "f-vl"])
    }

    func testWithoutStudiNowAINothingIsSent() async throws {
        let b = try await backend(nil)
        let d = await post(b, "/api/modules/1/exam-generator/offer", ["file_ids": ["f-vl"]], status: 403)
        XCTAssertEqual(d["code"]?.string ?? d["detail"]?["code"]?.string, "exam_generator_needs_service")
    }
}
