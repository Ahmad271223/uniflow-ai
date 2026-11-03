import Foundation
import XCTest
@testable import UniFlowCore

/// Kommentare ohne Server (CloudKit, 03.11.2026): Pruefungen wie app/community.py, Verschluesselung mit dem
/// Community-Geheimnis (Rundweg, falscher Schluessel, Umhaengen) und Reihenfolge des Verlaufs. Verschluesselt wird mit
/// `TestHMACCipher` (die App: AES-256-GCM, UniFlowTests/CommunityCloudKitTests).
final class CommunityDiscussionTests: XCTestCase {
    let cipher = TestHMACCipher()
    let secret = CommunityKeys.secret(university: "luh", courseID: "kurs-1")

    func testTextRulesMatchService() throws {
        XCTAssertEqual(try CommunityDiscussion.cleanText("  Danke!  \n"), "Danke!")
        XCTAssertThrowsError(try CommunityDiscussion.cleanText("   \n")) {
            XCTAssertEqual($0 as? CommunityServiceError, .service("Der Kommentar ist leer."))
        }
        XCTAssertNoThrow(try CommunityDiscussion.cleanText(String(repeating: "ä", count: CommunityDiscussion.maxComment)))
        XCTAssertThrowsError(try CommunityDiscussion.cleanText(String(repeating: "a", count: CommunityDiscussion.maxComment + 1)))
    }

    func testAnchorRulesMatchService() throws {
        let (pk, a) = try CommunityDiscussion.cleanAnchor(pageKey: String(repeating: "p", count: 60), anchor: .init(x: 0.5, y: 1))
        XCTAssertEqual(pk?.count, CommunityDiscussion.maxPageKey)
        XCTAssertEqual(a, .init(x: 0.5, y: 1))
        XCTAssertEqual(try CommunityDiscussion.cleanAnchor(pageKey: "", anchor: nil).0, nil)
        XCTAssertThrowsError(try CommunityDiscussion.cleanAnchor(pageKey: nil, anchor: .init(x: 0.5, y: 0.5)))      // Stelle ohne Seite
        XCTAssertThrowsError(try CommunityDiscussion.cleanAnchor(pageKey: "p1", anchor: .init(x: 1.2, y: 0.5)))
        XCTAssertThrowsError(try CommunityDiscussion.cleanAnchor(pageKey: "p1", anchor: .init(x: .nan, y: 0.5)))
    }

    func testSealOpenRoundtripAndNoPlaintext() throws {
        let body = CommunityDiscussion.Body(text: "Aufgabe 2b: Vorzeichen prüfen", pseudonym: "Lea", pageKey: "p3", anchor: .init(x: 0.25, y: 0.75))
        let payload = try CommunityDiscussion.seal(body, commentID: "c-1", solutionID: "SOL-1", communitySecret: secret, cipher: cipher)
        let raw = try XCTUnwrap(Data(base64Encoded: payload))
        for plain in ["Vorzeichen", "Lea", "p3"] { XCTAssertNil(raw.range(of: Data(plain.utf8)), plain) }
        // Loesungs-ID ohne Ruecksicht auf Gross- und Kleinschreibung (der Dienst speichert sie klein)
        XCTAssertEqual(try CommunityDiscussion.open(payload, commentID: "c-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher), body)
        // jedes Mal neues Salz und neue Nonce
        XCTAssertNotEqual(payload, try CommunityDiscussion.seal(body, commentID: "c-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher))
    }

    func testWrongKeyOrMovedCiphertextFails() throws {
        let body = CommunityDiscussion.Body(text: "Hallo", pseudonym: "")
        let payload = try CommunityDiscussion.seal(body, commentID: "c-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher)
        let other = CommunityKeys.secret(university: "luh", courseID: "kurs-2")
        XCTAssertThrowsError(try CommunityDiscussion.open(payload, commentID: "c-1", solutionID: "sol-1", communitySecret: other, cipher: cipher))
        XCTAssertThrowsError(try CommunityDiscussion.open(payload, commentID: "c-2", solutionID: "sol-1", communitySecret: secret, cipher: cipher))
        XCTAssertThrowsError(try CommunityDiscussion.open(payload, commentID: "c-1", solutionID: "sol-2", communitySecret: secret, cipher: cipher))
        var bytes = [UInt8](Data(base64Encoded: payload)!)
        bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try CommunityDiscussion.open(Data(bytes).base64EncodedString(), commentID: "c-1", solutionID: "sol-1",
                                                          communitySecret: secret, cipher: cipher))
        XCTAssertThrowsError(try CommunityDiscussion.open("kein base64", commentID: "c-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher))
    }

    /// Fremder Datensatz mit gueltigem Chiffrat, aber zu langem Text: wird wie beim Dienst abgewiesen
    func testOpenRejectsWhatCouldNotBeWritten() throws {
        let long = CommunityDiscussion.Body(text: String(repeating: "x", count: CommunityDiscussion.maxComment + 1), pseudonym: "Lea")
        let payload = try CommunityDiscussion.seal(long, commentID: "c", solutionID: "s", communitySecret: secret, cipher: cipher)
        XCTAssertThrowsError(try CommunityDiscussion.open(payload, commentID: "c", solutionID: "s", communitySecret: secret, cipher: cipher))
    }

    func testThreadOrderLikeService() {
        func body(_ t: String, _ name: String = "Lea") -> CommunityDiscussion.Body { .init(text: t, pseudonym: name) }
        let entries: [CommunityDiscussion.Entry] = [
            .init(id: "b", author: "u2", createdAt: "2026-11-03T10:02:00Z", body: body("zweiter", "")),
            .init(id: "a", author: "u1", createdAt: "2026-11-03T10:00:00Z", body: body("erster")),
            .init(id: "a1", parentID: "a", author: "author", createdAt: "2026-11-03T10:05:00Z", editedAt: "2026-11-03T10:06:00Z", body: body("Antwort")),
            .init(id: "c", author: "u3", status: .deleted, createdAt: "2026-11-03T10:03:00Z"),            // geloescht, mit Antwort
            .init(id: "c1", parentID: "c", author: "me", createdAt: "2026-11-03T10:04:00Z", body: body("noch da")),
            .init(id: "d", author: "u4", status: .deleted, createdAt: "2026-11-03T10:07:00Z"),            // geloescht, ohne Antwort
            .init(id: "e", author: "u5", status: .hidden, createdAt: "2026-11-03T10:08:00Z", body: body("ausgeblendet")),
            .init(id: "f", author: "blocked", createdAt: "2026-11-03T10:09:00Z", body: body("gesperrt")),
            .init(id: "g", author: "u6", createdAt: "2026-11-03T10:10:00Z"),                              // nicht lesbar
            .init(id: "a2", parentID: "a", author: "u7", status: .deleted, createdAt: "2026-11-03T10:11:00Z"), // geloeschte Antwort
        ]
        let out = CommunityDiscussion.thread(entries, me: "me", solutionAuthor: "author", blocked: ["blocked"])
        XCTAssertEqual(out.map(\.id), ["a", "a1", "b", "c", "c1"])
        XCTAssertEqual(out[1].edited, true)
        XCTAssertEqual(out[1].byAuthor, true)
        XCTAssertEqual(out[2].pseudonym, CommunityDiscussion.anonymousName)
        XCTAssertEqual(out[3].deleted, true)
        XCTAssertEqual(out[3].text, "")
        XCTAssertEqual(out[4].isMine, true)
        XCTAssertEqual(CommunityDiscussion.activeCount(entries, blocked: ["blocked"]), 5)        // a, b, a1, c1, g
    }

    func testLikeCountOnePerUserNeverAuthor() {
        XCTAssertEqual(CommunityDiscussion.likeCount(likers: ["u1", "u1", "u2", "author", ""], solutionAuthor: "author"), 2)
        XCTAssertEqual(CommunityDiscussion.likeCount(likers: ["u1", "u2"], solutionAuthor: "author", blocked: ["u2"]), 1)
    }
}
