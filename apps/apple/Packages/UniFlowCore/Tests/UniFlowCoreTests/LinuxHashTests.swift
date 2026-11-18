import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import XCTest
@testable import UniFlowCore

/// `StudIPUserMark.hash` und `UniAccountKey.key` rechnen seit 18.11.2026 mit `SolutionSHA256` statt CryptoKit, damit der
/// Kern auch unter Linux baut (GitHub-Lauf "Apple", Schritt "UniFlowCore (Linux, swift test)" brach seit 12.11. mit
/// "no such module 'CryptoKit'" ab). Die Werte duerfen sich dabei nicht aendern: Sie liegen schon in den Datenbereichen
/// der Geraete (`settings.studip_user_hash`) und beim Dienst (Raeume des Geraete-Abgleichs). Die festen Werte unten
/// stammen aus Pythons `hashlib.sha256` (wie `app/sync_client.py`).
final class LinuxHashTests: XCTestCase {
    func testStudIPUserMarkHashIsUnchanged() {
        XCTAssertEqual(StudIPUserMark.hash(userID: "ada-123"),
                       "60fab9dfa5becd800791b629c996b414601dd13a510e4d7320424b338339900b")
        // Umlaute als UTF-8 wie in Python (`.encode()`)
        XCTAssertEqual(StudIPUserMark.hash(userID: "müller-ä"),
                       "d7eb0972d48e16a4ab78559e0ce423af35d622421579cfa9d17e96d623d51d78")
    }

    func testUniAccountKeyIsUnchanged() {
        let identity = StudIPUserMark.hash(userID: "ada-123")
        XCTAssertEqual(UniAccountKey.key(account: "konto-1", university: "luh", identity: identity),
                       "08121804954ac42166e68cc347ca2ce43306ca68c56bfee60b2672717fe92586")
    }

    #if canImport(CryptoKit)
    /// Auf Apple-Geraeten zusaetzlich gegen CryptoKit, den bisherigen Weg (unter Linux entfaellt dieser Vergleich)
    func testSameValueAsCryptoKit() {
        for text in ["studip-user:ada-123", "studip-user:müller-ä", "studinow-uni-konto|1|hildesheim|ohne-kennung", ""] {
            let old = CryptoKit.SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(SolutionSHA256.hex(Data(text.utf8)), old, text)
        }
    }
    #endif
}
