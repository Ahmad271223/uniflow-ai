import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gespraeche der KI-Hilfe je Dokument (Weitermachen wie zuvor, 04.11.2026): Rundlauf ueber die Datei im Container mit
/// Antworten, Karten, Quellen, Modus (Anschlussfragen) und "Schon erklärt"; hoechstens 15, das aelteste faellt heraus.
/// Alle Inhalte sind erfunden.
@MainActor
final class TutorConversationsAppTests: XCTestCase {
    private func fileURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tutor-conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent(TutorConversations.fileName)
    }

    private var clock = 0
    private func store(_ url: URL) -> TutorConversations {
        let s = TutorConversations(fileURL: url)
        s.now = { [unowned self] in
            clock += 1
            return Date(timeIntervalSince1970: 1_793_000_000 + Double(clock) * 60)
        }
        return s
    }

    func testRoundTripKeepsEverything() throws {
        let url = try fileURL()
        let explain: JSONValue = .object(["stored": true, "source": "cloud"])
        let panel: [TutorPanel.Message] = [
            .init(fromUser: true, text: "Erklären"),
            .init(fromUser: false, text: "Ein Grenzwert ist … [1]", sources: [.object(["n": 1, "page": 3])], mode: "explain", explain: explain),
            .init(fromUser: true, text: "Karteikarten"),
            .init(fromUser: false, text: "", cards: [.object(["question": "Was ist ε?", "answer": "Toleranz"])], saved: true, mode: "flashcards"),
        ]
        store(url).save(fileID: "f1", fileName: "Analysis Skript", messages: TutorPanel.stored(panel))

        let again = TutorConversations(fileURL: url)                // wie nach einem Neustart
        let back = TutorPanel.restored(again.messages(for: "f1"))
        XCTAssertEqual(back.count, 4)
        XCTAssertEqual(back.map(\.fromUser), [true, false, true, false])
        XCTAssertEqual(back[1].text, "Ein Grenzwert ist … [1]")
        XCTAssertEqual(back[1].mode, "explain", "Anschlussfragen folgen dem Modus")
        XCTAssertEqual(back[1].sources, [.object(["n": 1, "page": 3])])
        XCTAssertEqual(TutorPanel.storedLabel(back[1].explain), "Schon erklärt · sofort da · 0 Credits")
        XCTAssertEqual(back[3].cards.first?["question"]?.string, "Was ist ε?")
        XCTAssertTrue(back[3].saved)
        XCTAssertEqual(again.recent().first?.fileName, "Analysis Skript")
        XCTAssertEqual(again.recent().first?.lastQuestion, "Karteikarten")
        XCTAssertTrue(again.messages(for: "anderes").isEmpty)
    }

    func testKeepsFifteenNewestFirst() throws {
        let url = try fileURL()
        let s = store(url)
        for i in 1...17 {
            s.save(fileID: "f\(i)", fileName: nil, messages: [.init(fromUser: true, text: "Frage \(i)"), .init(fromUser: false, text: "A")])
        }
        XCTAssertEqual(s.recent().count, TutorConversations.keep)
        XCTAssertEqual(TutorConversations.keep, 15)
        XCTAssertEqual(s.recent().first?.fileID, "f17")
        XCTAssertEqual(s.recent().last?.fileID, "f3", "f1 und f2 fallen heraus")
        // erneut benutzt: nach vorn, keine Doppelung
        s.save(fileID: "f5", fileName: nil, messages: [.init(fromUser: true, text: "Noch eine")])
        XCTAssertEqual(s.recent().first?.fileID, "f5")
        XCTAssertEqual(s.recent().count, 15)
        XCTAssertEqual(TutorConversations(fileURL: url).recent().map(\.fileID), s.recent().map(\.fileID), "auf der Platte derselbe Stand")
    }

    func testEmptyConversationRemoves() throws {
        let url = try fileURL()
        let s = store(url)
        s.save(fileID: "f1", fileName: "A", messages: [.init(fromUser: true, text: "Frage")])
        s.save(fileID: "f1", fileName: nil, messages: [])                 // "Neu"
        XCTAssertTrue(s.recent().isEmpty)
        XCTAssertTrue(TutorConversations(fileURL: url).recent().isEmpty)
        s.clear(fileID: "gibt-es-nicht")
    }

    func testBrokenFileReadsEmpty() throws {
        let url = try fileURL()
        try Data("kein json".utf8).write(to: url)
        XCTAssertTrue(TutorConversations(fileURL: url).recent().isEmpty)
    }
}
