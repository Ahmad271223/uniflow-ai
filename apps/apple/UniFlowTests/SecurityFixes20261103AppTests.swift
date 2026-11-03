import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Sicherheitspruefung vom 03.11.2026 (docs/SICHERHEITSKORREKTUREN-2026-11-03.md), App-Teile: Links aus fremdem Text
/// nur http(s) (Fund 6), Rueckfrage mit Gruppennamen vor dem Beitritt ueber einen Link (Fund 7), Import einer Loesung
/// mit unlesbarer Groesse und abseits des Hauptthreads (Fund 9).
final class SecurityFixes20261103AppTests: XCTestCase {

    func testOnlyHTTPLinksLeaveTheApp() {
        for ok in ["https://studip.uni-hannover.de/x", "http://example.org", "HTTPS://Example.org/a?b=c"] {
            XCTAssertTrue(SafeLinks.allows(URL(string: ok)!), ok)
        }
        for bad in ["uniflow://community/join/ABCDEFGH", "uniflow://#/settings", "javascript:alert(1)", "file:///etc/passwd", "tel:110",
                    "mailto:a@b.de", "sms:1", "https:///ohne-host", "data:text/html,x"] {
            if let u = URL(string: bad) { XCTAssertFalse(SafeLinks.allows(u), bad) }
        }
    }

    func testJoinLinkAsksWithTheGroupName() {
        let text = CommunityJoinLink.confirmText(name: "Lernrunde Mathe")
        XCTAssertTrue(text.contains("„Lernrunde Mathe“") && text.hasSuffix("geteilt werden."), text)
        XCTAssertNotNil(CommunityJoinLink.code(from: CommunityJoinLink.url(code: "ABCDEFGH")))
    }

    func testImportWithUnreadableSizeFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = SolutionLibrary(root: dir.appendingPathComponent("lib"))
        // gibt es nicht: keine Groesse, also kein Leseversuch und ein Fehler (nicht "0 Byte, weiter")
        let missing = dir.appendingPathComponent("weg.uniflowsolution")
        XCTAssertThrowsError(try SolutionSharing.importFile(missing, into: lib, notify: false))
        do {
            _ = try await SolutionSharing.importFileDetached(missing, into: lib, notify: false)
            XCTFail("unlesbare Datei angenommen")
        } catch {}
        XCTAssertTrue(lib.allEntries().isEmpty)
    }
}
