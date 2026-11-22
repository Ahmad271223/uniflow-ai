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
        /// Antwort auf `GET /api/exam-shop/mine` (Abholen ohne Auswahl)
        var mine: [JSONValue] = []

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
            if r.url.hasSuffix("/api/exam-shop/mine") {
                return .init(status: 200, body: JSONValue.object(["items": .array(lock.withLock { mine })]).serialized())
            }
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
        let all = await post(b, "/api/exam-generator/collect", .object([:]), status: 403)
        XCTAssertEqual(all["code"]?.string ?? all["detail"]?["code"]?.string, "exam_generator_needs_service")
    }

    // MARK: Abholen ohne Auswahl (22.11.2026: fertig und bezahlt, aber nie auf dem iPad angekommen)

    private func mineItem(_ n: Int, set: Character = "2", status: String = "ready", paid: Bool = true, files: [String]) -> JSONValue {
        let sk = String(repeating: set, count: 40)
        let item: [String: JSONValue] = ["key": .string("pk-\(sk)-" + String(format: "%02d", n)), "set_key": .string(sk),
                                         "variant": .number(Double(n)), "status": .string(status), "owned": true, "paid": .bool(paid),
                                         "files": .array(files.map(JSONValue.string))]
        return .object(item)
    }

    private func userFiles(_ b: LocalBackend) async throws -> [String] {
        try await b.context.database.withConnection { c in
            try c.query("""
                SELECT f.title, d.name AS folder, d.module_id, f.deleted_at IS NOT NULL AS gone FROM files f JOIN folders d ON d.id=f.folder_id
                WHERE f.course_id='__user__' ORDER BY d.module_id, f.title
                """).map { "\($0["title"]?.string ?? "")|\($0["folder"]?.string ?? "")|\($0["module_id"]?.int ?? 0)|\($0["gone"]?.int ?? 0)" }
        }
    }

    func testCollectAllPutsBoughtExamsIntoTheModuleOfTheirFilesWithoutASelection() async throws {
        let shop = FakeShop()
        let b = try await backend(shop)
        let shaVL = String(repeating: "a", count: 64), shaUB = String(repeating: "b", count: 64), shaOther = String(repeating: "c", count: 64)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (2, 'Digitale Systeme', '#175ee8', 1)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('c2', 'GDS', 'GDS', 'vorlesung', 1, 2, 't')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, content_sha256) VALUES ('g1', 'c2', 'Kap 2.pdf', 10, 'neu', ?), ('g2', 'c2', 'Kap 3.pdf', 20, 'neu', ?)",
                          [.text(shaVL), .text(shaUB.uppercased())])
            try c.execute("UPDATE files SET content_sha256=? WHERE id='f-vl'", [.text(shaOther)])
        }
        // Probeklausur 1: fertig und bezahlt (2 von 3 Unterlagen in Modul 2, eine in Modul 1); Nummer 2 wird noch erstellt;
        // eine dritte passt zu keiner Datei dieses Geraets
        shop.mine = [mineItem(1, files: [shaVL, shaUB, shaOther]),
                     mineItem(2, status: "running", paid: false, files: [shaVL, shaUB, shaOther]),
                     mineItem(1, set: "3", files: [String(repeating: "d", count: 64)])]

        let got = await post(b, "/api/exam-generator/collect", .object([:]))
        XCTAssertEqual(got["added"]?.array?.count, 2, "Aufgaben und Lösungen von Probeklausur 1")
        XCTAssertEqual(got["added"]?.array?.first?["module"]?.string, "Digitale Systeme")
        XCTAssertEqual(got["added"]?.array?.first?["module_id"]?.int, 2)
        XCTAssertEqual(got["pending"]?.int, 1)
        XCTAssertEqual(got["unplaced"]?.int, 1)
        XCTAssertEqual(shop.requests.filter { $0.url.contains("/pdf/") }.count, 2, "nur die zwei PDFs der fertigen, bezahlten")
        XCTAssertFalse(shop.requests.contains { $0.url.hasSuffix("/offer") || $0.url.hasSuffix("/buy") }, "ohne Auswahl, ohne Kauf")
        let files = try await userFiles(b)
        XCTAssertEqual(files, ["Probeklausur 1 – Aufgaben|Probeklausuren|2|0", "Probeklausur 1 – Lösungen|Probeklausuren|2|0"])

        // zweiter Lauf: nichts doppelt
        let again = await post(b, "/api/exam-generator/collect", .object([:]))
        XCTAssertEqual(again["added"]?.array?.count, 0)
        XCTAssertEqual(shop.requests.filter { $0.url.contains("/pdf/") }.count, 2)

        // Nummer 2 wird fertig: kommt beim naechsten Lauf dazu
        shop.mine[1] = mineItem(2, files: [shaVL, shaUB, shaOther])
        let later = await post(b, "/api/exam-generator/collect", .object([:]))
        XCTAssertEqual((later["added"]?.array ?? []).compactMap { $0["title"]?.string }, ["Probeklausur 2 – Aufgaben", "Probeklausur 2 – Lösungen"])
        XCTAssertEqual(later["pending"]?.int, 0)

        // Karte auf der Modulseite: beide Probeklausuren mit ihren Dokumenten, nur im eigenen Modul
        let r2 = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules/2/exam-generator/saved")!, body: Data()))
        let saved = r2.json?["items"]?.array ?? []
        XCTAssertEqual(saved.compactMap { $0["variant"]?.int }, [1, 2])
        XCTAssertNotNil(saved.first?["aufgaben"]?.string)
        XCTAssertNotNil(saved.first?["loesungen"]?.string)
        let r1 = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules/1/exam-generator/saved")!, body: Data()))
        XCTAssertEqual(r1.json?["items"]?.array?.count, 0)

        // bewusst geloescht: kommt von selbst nicht wieder
        try await b.context.database.execute("UPDATE files SET deleted_at='2026-11-22T12:00:00' WHERE course_id='__user__' AND title LIKE 'Probeklausur 1%'")
        let afterDelete = await post(b, "/api/exam-generator/collect", .object([:]))
        XCTAssertEqual(afterDelete["added"]?.array?.count, 0)
        let r3 = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules/2/exam-generator/saved")!, body: Data()))
        XCTAssertEqual((r3.json?["items"]?.array ?? []).compactMap { $0["variant"]?.int }, [2], "geloeschte stehen nicht auf der Karte")
        XCTAssertEqual(shop.requests.filter { $0.url.contains("/pdf/") }.count, 4)
    }

    func testCollectAllAndTheSheetNeverStoreTheSamePDFTwice() async throws {
        let shop = FakeShop()
        let b = try await backend(shop)
        let sel: JSONValue = ["file_ids": ["f-vl", "f-ub"], "count": 1]
        _ = await post(b, "/api/modules/1/exam-generator/buy", sel)
        let shas = try await b.context.database.withConnection { c in
            try c.query("SELECT content_sha256 FROM files WHERE id IN ('f-vl','f-ub')").compactMap { $0["content_sha256"]?.string }
        }
        XCTAssertEqual(shas.count, 2, "der Kauf hat die Fingerabdruecke nachgeholt")
        shop.mine = [mineItem(1, set: "1", files: shas)]

        // Kauf-Blatt und Abholen von selbst gleichzeitig
        async let a = post(b, "/api/modules/1/exam-generator/collect", sel)
        async let c = post(b, "/api/exam-generator/collect", .object([:]))
        let (ra, rc) = await (a, c)
        XCTAssertEqual((ra["added"]?.array?.count ?? 0) + (rc["added"]?.array?.count ?? 0), 2, "zusammen genau Aufgaben und Lösungen")
        let files = try await userFiles(b)
        XCTAssertEqual(files, ["Probeklausur 1 – Aufgaben|Probeklausuren|1|0", "Probeklausur 1 – Lösungen|Probeklausuren|1|0"])
    }
}
