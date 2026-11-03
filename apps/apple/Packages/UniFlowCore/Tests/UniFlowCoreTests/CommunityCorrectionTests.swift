import Foundation
import XCTest
@testable import UniFlowCore

/// Korrekturvorschlag (03.11.2026): Pruefen, Verschluesseln mit dem Community-Geheimnis (Rundweg, falscher Schluessel,
/// Umhaengen an andere Loesung oder Korrektur), Format der Seiten wie im Loesungspaket, Liste und Entwurf.
final class CommunityCorrectionTests: XCTestCase {
    let cipher = TestHMACCipher()
    let secret = CommunityKeys.secret(university: "luh", courseID: "kurs-1")

    static func stroke(_ id: String = "s1", from x: Double = 10.04, count: Int = 20) -> JSONValue {
        var pts: [JSONValue] = []
        for i in 0..<count { pts += [.number(x + Double(i) * 1.5), .number(20.0 + Double(i) * 0.75)] }
        return .object(["id": .string(id), "type": .string("stroke"), "color": .string("#ff3b30"), "size": .number(3),
                        "tool": .string("pen"), "points": .array(pts)])
    }

    func sample(id: String = "c-1", solutionID: String = "SOL-1") -> CommunityCorrection {
        CommunityCorrection(id: id, targetSolutionID: solutionID, pseudonym: "Lea", createdAt: "2026-11-03T10:00:00Z",
                            note: "  Aufgabe 2b: Vorzeichen  ",
                            pages: [CommunityCorrection.Page(pdfIndex: 3, width: 595, height: 842, rotation: 0, strokes: [Self.stroke()],
                                                             notes: [.init(id: "n1", x: 0.25, y: 0.75, text: "hier fehlt ein Minus")]),
                                    CommunityCorrection.Page(pdfIndex: 1, width: 595, height: 842, rotation: 90, strokes: [], notes: [])])
    }

    func testValidatedTrimsDropsEmptyPagesAndSorts() throws {
        let c = try CommunityCorrections.validated(sample())
        XCTAssertEqual(c.id, "c-1")
        XCTAssertEqual(c.targetSolutionID, "sol-1")
        XCTAssertEqual(c.note, "Aufgabe 2b: Vorzeichen")
        XCTAssertEqual(c.pages.map(\.pdfIndex), [3])                       // leere Seite 1 entfaellt
        XCTAssertEqual(c.strokeCount, 1)
        XCTAssertEqual(c.noteCount, 1)
    }

    func testValidatedRejectsBadInput() {
        var empty = sample()
        empty.pages = []
        empty.note = "   "
        XCTAssertThrowsError(try CommunityCorrections.validated(empty))
        var badNote = sample()
        badNote.pages[0].notes[0].x = 1.5
        XCTAssertThrowsError(try CommunityCorrections.validated(badNote))
        var emptyNote = sample()
        emptyNote.pages[0].notes[0].text = "  "
        XCTAssertThrowsError(try CommunityCorrections.validated(emptyNote))
        var notStroke = sample()
        notStroke.pages[0].strokes = [.object(["type": .string("image"), "src": .string("x.png")])]
        XCTAssertThrowsError(try CommunityCorrections.validated(notStroke))
        var long = sample()
        long.note = String(repeating: "x", count: CommunityCorrections.maxText + 1)
        XCTAssertThrowsError(try CommunityCorrections.validated(long))
        var dup = sample()
        dup.pages[1] = dup.pages[0]
        XCTAssertThrowsError(try CommunityCorrections.validated(dup))
        // nur Text ohne Striche ist erlaubt
        var textOnly = sample()
        textOnly.pages = []
        XCTAssertNoThrow(try CommunityCorrections.validated(textOnly))
    }

    func testSealOpenRoundtripCompressedAndNoPlaintext() throws {
        let c = sample()
        let payload = try CommunityCorrections.seal(c, communitySecret: secret, cipher: cipher)
        let raw = try XCTUnwrap(Data(base64Encoded: payload))
        for plain in ["Vorzeichen", "Lea", "Minus", "stroke"] { XCTAssertNil(raw.range(of: Data(plain.utf8)), plain) }
        let opened = try CommunityCorrections.open(payload, correctionID: "C-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher)
        let expected = try CommunityCorrections.validated(c)
        XCTAssertEqual(opened.id, expected.id)
        XCTAssertEqual(opened.note, expected.note)
        XCTAssertEqual(opened.pseudonym, "Lea")
        XCTAssertEqual(opened.pages.count, 1)
        XCTAssertEqual(opened.pages[0].notes, expected.pages[0].notes)
        // Striche wie Formatversion 2: auf 0,1 Punkt gerundet, sonst gleich
        let pts = try XCTUnwrap(opened.pages[0].strokes[0]["points"]?.array?.compactMap(\.double))
        XCTAssertEqual(pts.first, 10.0)
        XCTAssertEqual(pts.count, 40)
        XCTAssertEqual(opened.pages[0].solutionPage.pdfIndex, 3)
        XCTAssertEqual(opened.pages[0].solutionPage.kind, .pdf)
        XCTAssertNotEqual(payload, try CommunityCorrections.seal(c, communitySecret: secret, cipher: cipher))
    }

    func testWrongKeyOrMovedCiphertextFails() throws {
        let payload = try CommunityCorrections.seal(sample(), communitySecret: secret, cipher: cipher)
        let other = CommunityKeys.secret(university: "luh", courseID: "kurs-2")
        XCTAssertThrowsError(try CommunityCorrections.open(payload, correctionID: "c-1", solutionID: "sol-1", communitySecret: other, cipher: cipher))
        XCTAssertThrowsError(try CommunityCorrections.open(payload, correctionID: "c-2", solutionID: "sol-1", communitySecret: secret, cipher: cipher))
        XCTAssertThrowsError(try CommunityCorrections.open(payload, correctionID: "c-1", solutionID: "sol-2", communitySecret: secret, cipher: cipher))
        var bytes = [UInt8](Data(base64Encoded: payload)!)
        bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try CommunityCorrections.open(Data(bytes).base64EncodedString(), correctionID: "c-1", solutionID: "sol-1",
                                                           communitySecret: secret, cipher: cipher))
        XCTAssertThrowsError(try CommunityCorrections.open("kein base64", correctionID: "c-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher))
        // Kommentar-Chiffrat ist keine Korrektur
        let comment = try CommunityDiscussion.seal(.init(text: "x", pseudonym: ""), commentID: "c-1", solutionID: "sol-1",
                                                   communitySecret: secret, cipher: cipher)
        XCTAssertThrowsError(try CommunityCorrections.open(comment, correctionID: "c-1", solutionID: "sol-1", communitySecret: secret, cipher: cipher))
    }

    func testTooLargeIsRejectedWithMessage() {
        var big = sample()
        // viele zufaellige Striche lassen sich kaum packen
        var rng = SystemRandomNumberGenerator()
        big.pages = (1...40).map { i in
            CommunityCorrection.Page(pdfIndex: i, width: 595, height: 842, strokes: (0..<40).map { j in
                .object(["id": .string("s\(i)-\(j)"), "type": .string("stroke"),
                         "points": .array((0..<400).map { _ in .number(Double(UInt32.random(in: 0...8000, using: &rng)) / 10) })])
            })
        }
        XCTAssertThrowsError(try CommunityCorrections.seal(big, communitySecret: secret, cipher: cipher)) {
            XCTAssertEqual($0 as? CommunityServiceError, CommunityCorrections.tooLarge)
        }
    }

    func testListFiltersBlockedSortsNewestAndMarksIgnored() {
        func c(_ id: String, _ at: String, _ author: String) -> CommunityCorrection {
            var x = CommunityCorrection(id: id, targetSolutionID: "s", pseudonym: "", createdAt: at, note: "x")
            x.author = author
            return x
        }
        let all = [c("a", "2026-11-01T10:00:00Z", "u1"), c("b", "2026-11-03T10:00:00Z", "me"), c("c", "2026-11-02T10:00:00Z", "bad")]
        let list = CommunityCorrections.list(all, me: "me", solutionOwner: "me", blocked: ["bad"], ignored: ["a"])
        XCTAssertEqual(list.map(\.id), ["b", "a"])
        XCTAssertTrue(list[0].isMine)
        XCTAssertEqual(list[1].status, .ignored)
        XCTAssertTrue(list.allSatisfy(\.isForMe))
        XCTAssertTrue(CommunityCorrections.openInbox(list).isEmpty)      // eigene und ignorierte nicht
        XCTAssertEqual(CommunityCorrections.openInbox(CommunityCorrections.list(all, me: "me", solutionOwner: "me")).map(\.id), ["c", "a"])

        // gesehen: im Posteingang, aber nicht mehr offen (zaehlt nicht am Menuepunkt); ignoriert geht vor gesehen
        let seen = CommunityCorrections.list(all, me: "me", solutionOwner: "me", ignored: ["c"], seen: ["a", "c"])
        XCTAssertEqual(seen.map { $0.id + ":" + $0.status.rawValue }, ["b:open", "c:ignored", "a:seen"])
        XCTAssertEqual(CommunityCorrections.inbox(seen).map(\.id), ["a"])
        XCTAssertEqual(CommunityCorrections.openInbox(seen), [])
        XCTAssertEqual(CommunityCorrections.seenInbox(seen).map(\.id), ["a"])
        let fresh = CommunityCorrections.list(all, me: "me", solutionOwner: "me", seen: ["a"])
        XCTAssertEqual(CommunityCorrections.inbox(fresh).map(\.id), ["c", "a"])
        XCTAssertEqual(CommunityCorrections.openInbox(fresh).map(\.id), ["c"])
    }

    func testInboxMessage() {
        XCTAssertEqual(CommunityCorrections.inboxMessage(pseudonym: "Lea"), "Deine Lösung hat einen Korrekturhinweis von Lea bekommen")
        XCTAssertEqual(CommunityCorrections.inboxMessage(pseudonym: " "), "Deine Lösung hat einen Korrekturhinweis von Anonym bekommen")
    }

    func testDraftStoreRoundtripAndRemoveWhenEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corr-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CommunityCorrectionDraftStore(directory: dir)
        XCTAssertNil(store.load(solutionID: "sol-1"))
        var draft = sample()
        try store.save(draft)
        let loaded = try XCTUnwrap(store.load(solutionID: "SOL-1"))
        XCTAssertEqual(loaded.id, "c-1")
        XCTAssertEqual(loaded.pages.count, 2)
        XCTAssertEqual(loaded.page(pdfIndex: 3)?.strokes, draft.pages[0].strokes)       // Entwurf ungerundet
        XCTAssertEqual(loaded.page(pdfIndex: 3)?.notes, draft.pages[0].notes)
        XCTAssertEqual(store.solutionIDs(), ["sol-1"])
        draft.pages = []
        draft.note = ""
        try store.save(draft)                                                       // leer: Entwurf weg
        XCTAssertNil(store.load(solutionID: "sol-1"))
    }

    func testStatusStoreIsLocal() {
        let suite = "corr-status-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)
        defer { d?.removePersistentDomain(forName: suite) }
        let s = CommunityCorrectionStatusStore(defaults: d)
        XCTAssertEqual(s.status(id: "A"), .open)
        s.set(.ignored, id: "A")
        XCTAssertEqual(s.status(id: "a"), .ignored)
        s.set(.open, id: "a")
        XCTAssertEqual(s.ignored(), [])

        // gesehen: eigene Menge, ueberlebt den Neustart (dieselben Defaults), ignoriert hat Vorrang, offen loescht beides
        s.set(.seen, id: "B")
        XCTAssertEqual(s.status(id: "b"), .seen)
        XCTAssertEqual(CommunityCorrectionStatusStore(defaults: d).seen(), ["b"])
        s.set(.ignored, id: "b")
        XCTAssertEqual(s.status(id: "b"), .ignored)
        XCTAssertEqual(s.seen(), ["b"], "Ignorieren vergisst das Gesehene nicht")
        s.set(.seen, id: "b")
        XCTAssertEqual(s.status(id: "b"), .seen, "erneut geoeffnet: nicht mehr ignoriert")
        s.set(.open, id: "b")
        XCTAssertEqual(s.status(id: "b"), .open)
        XCTAssertEqual(s.seen(), [])
        // ohne Defaults nur im Speicher
        let m = CommunityCorrectionStatusStore(defaults: nil)
        m.set(.seen, id: "x")
        m.set(.ignored, id: "y")
        XCTAssertEqual(m.seen(), ["x"])
        XCTAssertEqual(m.ignored(), ["y"])
    }
}
