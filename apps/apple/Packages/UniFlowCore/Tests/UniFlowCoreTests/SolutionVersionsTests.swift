import Foundation
import XCTest
@testable import UniFlowCore

/// Loesungen fuer alle Fassungen einer PDF (23.11.2026): Datei-Familie, Seitenkennzeichen, Zuordnung der Seiten,
/// Paketformat (abwaertskompatibel) und der Dienst-Client. Alle Texte und Kennungen sind erfunden.
final class SolutionVersionsTests: XCTestCase {
    // Zwei erfundene Fassungen eines Uebungsblatts: Seite 1 gleich, Seite 2 geaendert, in Fassung 2 eine neue Seite 3
    static let v1 = ["Übungsblatt 3 Aufgabe 1: Zeigen Sie, dass die Folge konvergiert. Seite 1 von 2",
                     "Aufgabe 2: Berechnen Sie das Integral von 0 bis 1. Seite 2 von 2"]
    static let v2 = ["Übungsblatt 3 Aufgabe 1: Zeigen Sie, dass die Folge konvergiert. Seite 1 von 3",
                     "Aufgabe 2: Berechnen Sie das Integral von 0 bis 2 und skizzieren Sie den Graphen. Seite 2 von 3",
                     "Aufgabe 3 (neu): Beweisen Sie die Ungleichung. Seite 3 von 3"]
    static let fp1 = String(repeating: "1", count: 64), fp2 = String(repeating: "2", count: 64)

    // MARK: Datei-Familie

    func testFamilyKeyIsAFixedHMACWithoutPlainIDs() {
        // Erwartungswert unabhaengig mit Python hmac/hashlib gerechnet
        XCTAssertEqual(CommunityKeys.familyKey(university: "luh", courseID: "kurs-4711", fileID: "0123456789abcdef0123456789abcdef"),
                       "e87f1af46204bb29ae02aa4caea59a2ac078801f821b8a70a423ee92f27b2eb1")
        XCTAssertEqual(CommunityKeys.familyKey(university: "hildesheim", courseID: "lw-321", fileID: "lw-9876-1a2b3c4d"),
                       "0bbf04a56c9b0c3c1828de6c6aa1090ca81a8739c10dba929d9cd9d15f78e8f3")
        let k = CommunityKeys.familyKey(university: "luh", courseID: "kurs-4711", fileID: "datei-1")
        XCTAssertTrue(CommunityKeys.isHex64(k))
        XCTAssertFalse(k.contains("kurs") || k.contains("datei"))
        // andere Datei, anderer Kurs, andere Hochschule: andere Familie
        XCTAssertNotEqual(k, CommunityKeys.familyKey(university: "luh", courseID: "kurs-4711", fileID: "datei-2"))
        XCTAssertNotEqual(k, CommunityKeys.familyKey(university: "luh", courseID: "kurs-4712", fileID: "datei-1"))
        XCTAssertNotEqual(k, CommunityKeys.familyKey(university: "hildesheim", courseID: "kurs-4711", fileID: "datei-1"))
        // nicht aus dem Kurs-Schluessel, den der Dienst kennt: wer nur ihn hat, kann die Familie nicht nachrechnen
        let known = CommunityKeys.courseKey(university: "luh", courseID: "kurs-4711")
        XCTAssertNotEqual(k, SolutionSHA256.hexString(DocIndexFingerprint.hmacSHA256(
            key: Data(known.utf8), message: Data("uniflow.community.family.v1\u{0}luh\u{0}datei-1".utf8))))
    }

    // MARK: Seitenkennzeichen und Zuordnung

    func testPageKeyIgnoresNumbersAndSpacingButNotWords() {
        let a = SolutionVersions.pageKey(Self.v1[0]), b = SolutionVersions.pageKey(Self.v2[0])
        XCTAssertEqual(a, b, "nur die Seitenzahl in der Fusszeile hat sich geaendert")
        XCTAssertEqual(a.count, SolutionVersions.pageKeyLength)
        XCTAssertTrue(SolutionVersions.isPageKey(a))
        XCTAssertNotEqual(SolutionVersions.pageKey(Self.v1[1]), SolutionVersions.pageKey(Self.v2[1]))
        XCTAssertEqual(SolutionVersions.pageKey("  \n "), "")
        XCTAssertEqual(SolutionVersions.pageKey("Aufgabe   1\n\nText"), SolutionVersions.pageKey("aufgabe 2 text"))
        XCTAssertFalse(SolutionVersions.isPageKey("0123456789abcdef0123456789abcdef"), "keine Ziffern (PageMatch faltet sie)")
        XCTAssertFalse(SolutionVersions.isPageKey("abc"))
    }

    static func content(fingerprint: String, texts: [String]?, pages: [Int] = [1, 2], blank: Bool = true) -> SolutionContent {
        var list = pages.map { i in
            SolutionPage(key: "p\(i)", kind: .pdf, pdfIndex: i, width: 595, height: 842, rotation: 0,
                         objects: [.object(["type": "stroke", "id": .string("s\(i)"), "points": .array([10, 20, 30, 40].map { JSONValue.number($0) })])])
        }
        if blank {
            list.append(SolutionPage(key: "b1", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "lined",
                                     objects: [.object(["type": "text", "id": "t1", "text": "Nebenrechnung", "x": 10, "y": 10])]))
        }
        return SolutionContent(solutionID: "6f1c1c0e-0000-4000-8000-000000000001", createdAt: "2026-11-23T10:00:00Z", title: "Blatt 3",
                               displayName: "", fingerprint: fingerprint, pdfPageCount: texts?.count ?? 2, pages: list,
                               versionPages: texts.map(SolutionVersions.pageKeys))
    }

    func testSolutionToVersion1OnVersion2SamePageOwnChangedPageSentence() {
        let c = Self.content(fingerprint: Self.fp1, texts: Self.v1)
        let own = SolutionVersions.pageKeys(Self.v2)
        let p = SolutionVersions.placements(c, ownFingerprint: Self.fp2, ownKeys: own)
        XCTAssertEqual(p["p1"], .own(1), "gleicher Text: 1:1 auf der eigenen Seite")
        XCTAssertEqual(p["p2"], .changed, "geaendert, alte Fassung nicht auf dem Geraet: der Satz")
        XCTAssertNil(p["b1"], "eigenes Blatt: immer auf seinem Papier")
        XCTAssertEqual(SolutionVersions.pageChanged, "Diese Seite hat sich in deiner Fassung geändert")
        // mit aufbewahrter Fassung 1: die geaenderte Seite auf der alten Fassung
        let kept = SolutionVersions.placements(c, ownFingerprint: Self.fp2, ownKeys: own, oldVersion: SolutionVersions.pageKeys(Self.v1))
        XCTAssertEqual(kept["p1"], .own(1))
        XCTAssertEqual(kept["p2"], .oldVersion(2))
    }

    func testMovedPageFollowsItsText() {
        // Fassung 2 mit einer neuen Seite vorn: die gleiche Seite steht jetzt auf Seite 2
        let own = SolutionVersions.pageKeys(["Inhaltsverzeichnis und Hinweise zur Abgabe"] + Self.v2)
        let p = SolutionVersions.placements(Self.content(fingerprint: Self.fp1, texts: Self.v1), ownFingerprint: Self.fp2, ownKeys: own)
        XCTAssertEqual(p["p1"], .own(2))
        XCTAssertEqual(p["p2"], .changed)
    }

    func testSolutionToVersion2OnVersion1() {
        // umgekehrt: Loesung zu Fassung 2 (Seiten 1 und 3), Betrachter hat noch Fassung 1
        let c = Self.content(fingerprint: Self.fp2, texts: Self.v2, pages: [1, 3], blank: false)
        let p = SolutionVersions.placements(c, ownFingerprint: Self.fp1, ownKeys: SolutionVersions.pageKeys(Self.v1))
        XCTAssertEqual(p, ["p1": .own(1), "p3": .changed], "die neue Seite gibt es in Fassung 1 nicht")
    }

    func testSameFingerprintKeepsEveryPage() {
        let c = Self.content(fingerprint: Self.fp1, texts: nil)
        XCTAssertEqual(SolutionVersions.placements(c, ownFingerprint: Self.fp1, ownKeys: []), ["p1": .own(1), "p2": .own(2)])
    }

    func testWithoutKeysNothingCountsAsUnchanged() {
        // alter Absender (kein Kennzeichen im Paket), keine aufbewahrte Fassung: keine Seite gilt als gleich
        let c = Self.content(fingerprint: Self.fp1, texts: nil)
        let own = SolutionVersions.pageKeys(Self.v2)
        XCTAssertEqual(SolutionVersions.placements(c, ownFingerprint: Self.fp2, ownKeys: own), ["p1": .changed, "p2": .changed])
        // mit aufbewahrter Fassung: deren Text ordnet zu
        XCTAssertEqual(SolutionVersions.placements(c, ownFingerprint: Self.fp2, ownKeys: own, oldVersion: SolutionVersions.pageKeys(Self.v1)),
                       ["p1": .own(1), "p2": .oldVersion(2)])
    }

    func testPagesWithoutTextOrOtherSizeAreNeverPutOnTheOwnPage() {
        let c = Self.content(fingerprint: Self.fp1, texts: ["", Self.v1[1]])
        let p = SolutionVersions.placements(c, ownFingerprint: Self.fp2, ownKeys: SolutionVersions.pageKeys(["", Self.v1[1]]))
        XCTAssertEqual(p["p1"], .changed, "ohne Text (Scan) laesst sich nicht pruefen, ob die Seite gleich ist")
        XCTAssertEqual(p["p2"], .own(2))
        let small = SolutionVersions.placements(Self.content(fingerprint: Self.fp1, texts: Self.v1), ownFingerprint: Self.fp2,
                                                ownKeys: SolutionVersions.pageKeys(Self.v2), fits: { _, _ in false })
        XCTAssertEqual(small["p1"], .changed, "andere Seitengroesse: die Striche stuenden daneben")
    }

    // MARK: Paketformat

    func testVersionPagesTravelEncryptedAndSurviveSealing() throws {
        let c = Self.content(fingerprint: Self.fp1, texts: Self.v1)
        let secret = CommunityKeys.secret(university: "luh", moduleName: "Analysis")
        let sealed = try SolutionPackage.seal(c, communitySecret: secret, cipher: TestHMACCipher())
        let text = String(decoding: sealed.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("versionPages") || text.contains(c.versionPages![0]), "nur im verschluesselten Inhalt")
        let opened = try SolutionPackage.decode(sealed.encoded()).open(communitySecret: secret, cipher: TestHMACCipher())
        XCTAssertEqual(opened.versionPages, c.versionPages)
        XCTAssertEqual(opened.pages.map(\.key), ["p1", "p2", "b1"])
    }

    func testOldContentWithoutVersionPagesStillOpens() throws {
        let c = Self.content(fingerprint: Self.fp1, texts: nil)
        var json = c.json
        XCTAssertNil(json["versionPages"])
        XCTAssertNil(try SolutionContent(json: json).versionPages)
        // Der Leser in App 1.0.6 ist derselbe Code (SolutionPackage.swift unveraendert seit f5e21794): er liest nur die
        // Felder, die er kennt. Ein unbekanntes Feld im Inhalt (wie fuer ihn `versionPages`) wird nicht abgewiesen.
        if case .object(var o) = json { o["zukunftsfeld"] = .array(["x"]); json = .object(o) }
        XCTAssertEqual(try SolutionContent(json: json).pages.count, 3)
    }

    func testBrokenVersionPagesAreRejected() {
        let c = Self.content(fingerprint: Self.fp1, texts: Self.v1)
        for bad: JSONValue in [.array([.string("x"), .string("")]), .array([.string("")]), .string("abc"),
                               .array([.number(1), .string("")]), .array([.string(String(repeating: "q", count: 32)), .string("")])] {
            guard case .object(var o) = c.json else { return XCTFail() }
            o["versionPages"] = bad
            XCTAssertThrowsError(try SolutionContent(json: .object(o)), "\(bad)")
        }
    }

    func testMergeKeepsTheKeysOfTheNewVersion() throws {
        let previous = Self.content(fingerprint: Self.fp1, texts: nil, pages: [1], blank: false)
        let new = Self.content(fingerprint: Self.fp1, texts: Self.v1, pages: [2], blank: false)
        let merged = try SolutionBuilder.merge(previous: previous, new: new)
        XCTAssertEqual(merged.versionPages, new.versionPages, "beim Aktualisieren bekommt eine alte Loesung die Kennzeichen")
        XCTAssertEqual(merged.pages.compactMap(\.pdfIndex), [1, 2])
    }

    // MARK: Ablage auf dem Geraet

    func testLibraryKeepsOtherVersionsUnderTheirFamily() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fassungen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = SolutionLibrary(root: root)
        let secret = CommunityKeys.secret(university: "luh", moduleName: "Analysis")
        let fam = CommunityKeys.familyKey(university: "luh", courseID: "kurs-4711", fileID: "datei-1")
        let pkg = try SolutionPackage.seal(Self.content(fingerprint: Self.fp1, texts: Self.v1), communitySecret: secret, cipher: TestHMACCipher())
        let e = try lib.importPackage(pkg.encoded(), family: fam)
        XCTAssertEqual(e.family, fam)
        XCTAssertEqual(lib.entries(family: fam, except: Self.fp2).map(\.solutionID), [e.solutionID])
        XCTAssertEqual(lib.entries(family: fam, except: Self.fp1), [], "zur eigenen PDF gehoert sie ueber den Fingerabdruck")
        XCTAssertEqual(lib.entries(family: String(repeating: "f", count: 64), except: Self.fp2), [])
        // Index ueberlebt das Neuladen
        XCTAssertEqual(SolutionLibrary(root: root).entries(family: fam, except: Self.fp2).first?.family, fam)
        // ein an die PDF gebundenes Paket bekommt keine Familie (es oeffnet nur mit genau dieser PDF)
        let pdf = Data("%PDF-1.4 erfundene Fassung 1".utf8)
        var bound = Self.content(fingerprint: SolutionSHA256.hex(pdf), texts: nil)
        bound.solutionID = "6f1c1c0e-0000-4000-8000-000000000002"
        let boundPkg = try SolutionPackage.seal(bound, originalPDF: pdf, cipher: TestHMACCipher())
        XCTAssertThrowsError(try lib.importPackage(boundPkg.encoded(), family: fam))
    }

    // MARK: Dienst-Client

    private final class RecordingTransport: CommunityTransport, @unchecked Sendable {
        let lock = NSLock()
        var calls: [(String, JSONValue?)] = []
        let reply: JSONValue
        init(reply: JSONValue) { self.reply = reply }
        func community(_ method: String, _ path: String, body: JSONValue?) async throws -> JSONValue {
            lock.withLock { calls.append((method + " " + path, body)) }
            return reply
        }
    }

    private final class NoGroups: CommunityGroupStore, @unchecked Sendable {
        func groups() -> [CommunityStudyGroup] { [] }
        func add(_ group: CommunityStudyGroup) {}
        func remove(code: String) {}
    }

    func testServiceSendsAndSearchesTheFamilyAndOldCallsStayTheSame() async throws {
        let fam = CommunityKeys.familyKey(university: "luh", courseID: "kurs-4711", fileID: "datei-1")
        let row: JSONValue = .object(["solution_id": "6f1c1c0e-0000-4000-8000-000000000001", "fingerprint": .string(Self.fp1),
                                      "family": .string(fam), "page_count": 2, "title": "Blatt 3"])
        let t = RecordingTransport(reply: .object(["solutions": .array([row]), "solution_id": "6f1c1c0e-0000-4000-8000-000000000001"]))
        let s = ServiceCommunityService(transport: t, university: "luh", membership: NoGroups(), localFingerprints: { [] }, localCourses: { [] })
        let found = try await s.findMatching(fingerprint: Self.fp2, family: fam)
        XCTAssertEqual(found.first?.family, fam)
        XCTAssertEqual(found.first?.isOtherVersion(of: Self.fp2), true)
        XCTAssertEqual(found.first?.isOtherVersion(of: Self.fp1), false)
        _ = try await s.findMatching(fingerprint: Self.fp2)
        XCTAssertEqual(t.calls.map(\.0), ["GET /solutions?fingerprint=\(Self.fp2)&family=\(fam)", "GET /solutions?fingerprint=\(Self.fp2)"])

        let secret = CommunityKeys.secret(university: "luh", moduleName: "Analysis")
        let pkg = try SolutionPackage.seal(Self.content(fingerprint: Self.fp1, texts: Self.v1), communitySecret: secret, cipher: TestHMACCipher())
        _ = try await s.publish(pkg, options: CommunityPublishOptions(communityKey: String(repeating: "9", count: 64), family: fam))
        XCTAssertEqual(t.calls.last?.1?["family"]?.string, fam)
        _ = try await s.publish(pkg, options: CommunityPublishOptions(communityKey: String(repeating: "9", count: 64)))
        XCTAssertNil(t.calls.last?.1?["family"], "ohne Datei aus dem Abgleich: kein Feld")
        _ = try await s.update(solutionID: pkg.header.solutionID, package: pkg,
                               options: CommunityPublishOptions(communityKey: String(repeating: "9", count: 64), family: fam))
        XCTAssertEqual(t.calls.last?.0.hasPrefix("PUT /solutions/"), true)
        XCTAssertEqual(t.calls.last?.1?["family"]?.string, fam)
    }

    func testServicesWithoutFamilyFallBackToTheFingerprint() async throws {
        let found = try? await NotConnectedCommunityService().findMatching(fingerprint: Self.fp1, family: String(repeating: "d", count: 64))
        XCTAssertNil(found, "nicht verbunden: wirft wie findMatching(fingerprint:)")
    }
}
