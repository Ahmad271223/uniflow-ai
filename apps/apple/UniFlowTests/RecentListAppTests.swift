import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Zuletzt benutzt" auf der Uebersicht und auf KI-Start (04.11.2026, docs/WEITERMACHEN-2026-11-04.md): Dokumente und
/// Wochentests aus `GET /api/recent`, KI-Gespraeche aus der App, eine Liste nach Zeit, neuestes zuerst, mit Grenze;
/// Antippen fuehrt an dieselbe Stelle. Alle Daten sind erfunden.
@MainActor
final class RecentListAppTests: XCTestCase {
    private func backend(_ items: [JSONValue]) -> JSONValue { .object(["items": .array(items)]) }

    private func doc(_ id: String, _ at: String, page: Int? = nil, title: String = "Skript") -> JSONValue {
        var o: [String: JSONValue] = ["kind": "document", "id": .string(id), "title": .string(title), "sub": "Analysis", "at": .string(at)]
        if let page { o["page"] = .number(Double(page)) }
        return .object(o)
    }

    private func conv(_ id: String, _ at: String, q: String = "Was ist ein Grenzwert?") -> TutorConversations.Conversation {
        .init(fileID: id, fileName: "Skript \(id)", messages: [.init(fromUser: true, text: q), .init(fromUser: false, text: "Antwort")], updatedAt: at)
    }

    func testOrderingNewestFirstAcrossKinds() {
        let b = backend([
            doc("f1", "2026-11-01T09:00:00", page: 3),
            .object(["kind": "test", "id": "7", "title": "Woche 3", "at": "2026-11-03T12:00:00"]),
            doc("f2", "2026-11-04T08:00:00"),
        ])
        let items = RecentItem.merge(backend: b, conversations: [conv("f1", "2026-11-02T10:00:00")], limit: 15)
        XCTAssertEqual(items.map(\.id), ["document:f2", "test:7", "conversation:f1", "document:f1"])
        XCTAssertEqual(items.map(\.icon), ["file", "exam", "sparkles", "file"])
        XCTAssertEqual(items[2].title, "Was ist ein Grenzwert?")
        XCTAssertEqual(items[2].sub, "Skript f1")
        XCTAssertEqual(items[3].page, 3)
        XCTAssertEqual(items[1].testID, 7)
        XCTAssertNil(items[1].fileID)
    }

    func testLimitAndUnreadableTimes() {
        var docs: [JSONValue] = (1...20).map { doc("f\($0)", String(format: "2026-11-%02dT10:00:00", $0 % 28 + 1)) }
        docs.append(.object(["kind": "document", "id": "kaputt", "at": "irgendwann"]))
        docs.append(.object(["kind": "unbekannt", "id": "x", "at": "2026-11-04T10:00:00"]))   // unbekannte Art: weg
        docs.append(.object(["kind": "document", "at": "2026-11-04T10:00:00"]))                 // ohne ID: weg
        let items = RecentItem.merge(backend: backend(docs), conversations: [], limit: 15)
        XCTAssertEqual(items.count, 15)
        XCTAssertEqual(items.first?.key, "f20")
        XCTAssertFalse(items.contains { $0.key == "kaputt" }, "unlesbare Zeit ganz hinten, faellt bei 15 heraus")
        let all = RecentItem.merge(backend: backend(docs), conversations: [], limit: 50)
        XCTAssertEqual(all.last?.key, "kaputt")
        XCTAssertEqual(all.count, 21)
        XCTAssertEqual(RecentItem.merge(backend: backend(docs), conversations: [], limit: 0), [])
        XCTAssertEqual(RecentItem.merge(backend: nil, conversations: [conv("f1", "2026-11-02T10:00:00")], limit: 15).count, 1,
                       "ohne Backend (PC-Server ohne Endpunkt) bleiben die Gespraeche")
    }

    /// KI-Start-Fragen mit Dokument zaehlen als Gespraech zu diesem Dokument; je Dokument nur das neueste
    func testAIRecentsMergeAndDedupeKeepsNewest() {
        let e1 = AIRecents.Entry(id: "a", question: "Zusammenfassen", answer: "…", fileID: "f1", fileName: "Skript", at: "2026-11-04T09:00:00Z")
        let e2 = AIRecents.Entry(id: "b", question: "Frage ohne Dokument", answer: "…", fileID: nil, fileName: nil, at: "2026-11-04T11:00:00Z")
        let items = RecentItem.merge(backend: nil, conversations: [conv("f1", "2026-11-02T10:00:00")], aiRecents: [e1, e2], limit: 15)
        XCTAssertEqual(items.map(\.id), ["conversation:f1"])
        XCTAssertEqual(items.first?.title, "Zusammenfassen", "der neuere Eintrag gewinnt")
    }

    func testRouteAndSubtitle() {
        let d = RecentItem(kind: .document, key: "f1", title: "Skript", sub: "Analysis", at: "2026-11-03T10:00:00", page: 4)
        XCTAssertEqual(RecentCard.route(for: d), .doc("f1", page: 4))
        XCTAssertTrue(d.subtitle.hasPrefix("Dokument · Analysis · Seite 4 · "))
        let first = RecentItem(kind: .document, key: "f1", title: "Skript", sub: nil, at: "2026-11-03T10:00:00", page: 1)
        XCTAssertEqual(RecentCard.route(for: first), .doc("f1"))
        let c = RecentItem(kind: .conversation, key: "f2", title: "Frage", sub: nil, at: "2026-11-03T10:00:00", page: nil)
        XCTAssertEqual(RecentCard.route(for: c), .doc("f2"))
        XCTAssertTrue(c.subtitle.hasPrefix("KI-Gespräch"))
        let t = RecentItem(kind: .test, key: "9", title: "Woche 2", sub: nil, at: "2026-11-03T10:00:00", page: nil)
        XCTAssertEqual(RecentCard.route(for: t), .exam(9))
        XCTAssertEqual(t.kindLabel, "Wochentest")
    }

    /// Ende zu Ende mit dem lokalen Backend: geoeffnete Datei mit Seite und ein Gespraech in einer Liste
    func testLoadFromLocalBackend() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, subject, kind, created_at) VALUES ('k1', 'Analysis I', 'Analysis', 'vorlesung', '2026-10-01')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, last_opened, last_page) VALUES ('f1', 'k1', 'vl01.pdf', 5, 'pdf', '2026-11-03T09:00:00', 6)")
        }
        let store = TutorConversations(fileURL: dir.appendingPathComponent(TutorConversations.fileName))
        store.now = { Fmt.isoDateTimeF.date(from: "2026-11-04T09:30:00")! }
        store.save(fileID: "f1", fileName: "vl01.pdf", messages: [.init(fromUser: true, text: "Was steht auf Seite 6?"), .init(fromUser: false, text: "…")])
        let items = await RecentItem.load(api: APIClient.local(host), conversations: store, aiRecents: [], limit: 15)
        XCTAssertEqual(items.map(\.id).prefix(2), ["conversation:f1", "document:f1"])
        XCTAssertEqual(items.first { $0.kind == .document }?.page, 6)
    }
}
