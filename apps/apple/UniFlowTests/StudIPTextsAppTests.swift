import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bereich "Aus Stud.IP" der Modulansicht: Abgleich des Lernstoffs (`StudIPTextsSync`, feste erfundene Antworten aus
/// packages/shared-contracts/fixtures/studip-texts, kein Netz) in die Datenbank des Containers, danach die Antworten,
/// die der Bereich liest (eine Zeile je Quelle, Leser), die Texte der Zeilen und die Fristen in "Abgaben & Prüfungen".
@MainActor
final class StudIPTextsAppTests: XCTestCase {

    private static let clock = UniFlowClock.fixed(berlin: "2026-11-02T09:00:00")!

    private final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let routes: [String: HTTPReply]
        private var log: [String] = []
        init(_ routes: [String: HTTPReply]) { self.routes = routes }
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: "https://studip.uni-hannover.de", with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.lock(); log.append(key); lock.unlock()
            return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }
    }

    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-texts/texte.json")))
    }

    private func host() throws -> LocalBackendHost {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-texts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let layout = DataContainerLayout(base: c, key: DataContainerKey(userID: "001234.erfunden.texte", university: .luh))
        try layout.prepare(clock: Self.clock)
        return LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
    }

    private func get(_ backend: LocalBackend, _ path: String, _ query: [LocalRequest.QueryItem] = []) async throws -> (Int, JSONValue) {
        let r = await backend.handle(LocalRequest(method: "GET", path: path, query: query))
        return (r.status, try JSONValue.parse(r.body))
    }

    func testSyncFillsTheSectionAndTheDeadlines() async throws {
        let fx = try fixture()
        var routes: [String: HTTPReply] = [:]
        for (k, v) in fx["routes"]?.object ?? [:] {
            routes[k] = HTTPReply(status: v["status"]?.int ?? 200, contentType: "application/vnd.api+json", body: try (v["body"] ?? .null).serialized())
        }
        let h = try host()
        let backend = try await h.backend()
        let mid = try await backend.context.database.transaction { c -> Int in
            try c.execute("INSERT INTO modules(name) VALUES ('Testanalysis')")
            let id = try c.scalar("SELECT last_insert_rowid()")?.int ?? 0
            try c.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('c-ana', 'Testanalysis I', ?, 1)", [.integer(Int64(id))])
            return id
        }
        let stud = FakeStudIP(routes)
        let client = StudIPClient(base: StudIPSync.base, transport: stud, pauseMillis: 0)
        var steps: [String] = []
        let out = await StudIPTextsSync(host: h).run(client: client, courses: [StudIPCourse(id: "c-ana", title: "Testanalysis I")]) { steps.append($0) }
        XCTAssertEqual(steps, ["Courseware, Wiki und Forum werden gelesen …"])
        XCTAssertFalse(out.sessionExpired)
        XCTAssertEqual(out.summary, ["5 Lerntexte aus Stud.IP", "3 Courseware-Fristen"])
        XCTAssertLessThanOrEqual(stud.requested.count, StudIPTexts.maxRequests)
        XCTAssertTrue(stud.requested.allSatisfy { $0.hasPrefix("/jsonapi.php/v1/") }, "nur JSON:API, nur lesend")

        // Bereich "Aus Stud.IP": eine Zeile je Quelle
        let (st, o) = try await get(backend, "/api/modules/\(mid)/studip")
        XCTAssertEqual(st, 200)
        let groups = o.list("groups")
        XCTAssertEqual(groups.compactMap { $0.s("kind") }, ["courseware", "wiki", "forum"])
        XCTAssertEqual(StudIPTextsText.summary(groups), "Courseware 2 · Wiki 2 · Forum 1")
        XCTAssertTrue(StudIPTextsText.line(groups[0]).hasPrefix("Courseware · 2 · geändert "), StudIPTextsText.line(groups[0]))
        // Leser: Text ohne Autorennamen, mit Link
        let (rs, r) = try await get(backend, "/api/studip-texts/forum-f1")
        XCTAssertEqual(rs, 200)
        XCTAssertFalse((r.s("text") ?? "").contains("Mustermann"))
        XCTAssertNotNil(r.s("url").flatMap(UFDayExtras.safeURL))

        // Fristen dort, wo Fristen stehen: "Abgaben & Prüfungen" des Moduls
        let (_, due) = try await get(backend, "/api/due", [.init("module_id", String(mid))])
        let cw = due.list("items").filter { $0.s("source") == "studip" }
        XCTAssertEqual(cw.count, 3)
        XCTAssertEqual(cw.first?.s("origin"), "aus Stud.IP Courseware")
        XCTAssertNotNil(DueOpen.route(cw[0]), "Antippen oeffnet die Aufgabe in Stud.IP")

        // der Bereich laesst sich darstellen (zugeklappt) und der Leser auch
        let suite = "uniflow-texts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let session = Session(local: .local(), defaults: defaults)
        let card = StudIPTextsCard(moduleID: mid).environmentObject(session).environmentObject(UFOverlay())
        XCTAssertNotNil(UIHostingController(rootView: card).view)
    }

    func testOutcomeWithoutResultSaysNothing() {
        XCTAssertEqual(StudIPTextsSync.Outcome().summary, [])
        XCTAssertEqual(StudIPTextsSync.Outcome(result: StudIPTexts.StoreResult(texts: 0, deadlines: 1)).summary, ["1 Courseware-Frist"])
    }
}
