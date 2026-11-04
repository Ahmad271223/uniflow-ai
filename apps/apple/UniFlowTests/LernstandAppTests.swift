import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// Lernstand je Modul in der App (LernstandView.swift): die Beschriftung "Lernstand 64 %" / "noch kein Lernstand"
/// fuer die gemeinsamen Faelle aus packages/shared-contracts/fixtures/mastery/cases.json (dieselben prueft
/// tests/js/mastery.test.mjs fuer das Web), dazu der VoiceOver-Satz und der Hinweis ohne Lernstand.
@MainActor
final class LernstandAppTests: XCTestCase {
    private static let path = "packages/shared-contracts/fixtures/mastery/cases.json"

    private func fixture() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: ContainerTestBed.repoURL(Self.path)))
    }

    func testLabelsLikeFixture() throws {
        let fx = try fixture()
        let cases = fx["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for c in cases {
            let m = c["expected"]
            XCTAssertEqual(LernstandText.label(m), c["label"]?.string, c["name"]?.string ?? "")
            XCTAssertEqual(LernstandText.sub(m), m == nil || m == .null ? LernstandText.hint : m?["reason"]?.string, c["name"]?.string ?? "")
        }
        XCTAssertEqual(fx["hint"]?.string, LernstandText.hint, "Hinweis ohne Lernstand steht im Fixture")
    }

    func testVoiceOverAndMissingField() {
        XCTAssertEqual(LernstandText.accessibility(["score": 64, "reason": "3 Wochentests"]), "Lernstand 64 Prozent, 3 Wochentests")
        XCTAssertEqual(LernstandText.accessibility(nil), "noch kein Lernstand, " + LernstandText.hint)
        XCTAssertEqual(LernstandText.label(nil), "noch kein Lernstand", "alter Server ohne Feld")
        XCTAssertEqual(LernstandText.label(.null), "noch kein Lernstand")
        XCTAssertEqual(LernstandText.label(["score": "x"]), "noch kein Lernstand")
        XCTAssertEqual(LernstandText.label(["score": 120]), "Lernstand 100\u{00A0}%", "gedeckelt")
        XCTAssertNil(LernstandText.score(["score": 64.0, "reason": ""]).flatMap { $0 > 100 ? $0 : nil })
    }

    /// Die Abzeichen lassen sich in beiden Groessen bauen (keine Laufzeitfehler, z. B. bei fehlendem Feld)
    func testBadgesRender() {
        let host = UIHostingController(rootView: VStack {
            LernstandBadge(m: ["score": 77, "reason": "2 Wochentests, 42 Karten, 12 von 20 Aufgaben"], color: .blue)
            LernstandBadge(m: nil, size: .small)
        })
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 400, height: 1000)).height, 30)
    }
}
