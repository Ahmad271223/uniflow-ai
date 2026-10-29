import SwiftUI
import XCTest
@testable import UniFlow

/// Bedienungshilfen (F20): Textgroesse aus den Einstellungen, ohne die Web-Masse in der Standardgroesse zu veraendern.
final class AccessibilityAppTests: XCTestCase {

    func testStandardSizeKeepsTheWebSizes() {
        for s: CGFloat in [11.84, 13.12, 14.5, 17.6, 23.2] {
            XCTAssertEqual(UFScaledFont.scaled(s, .large), s, "Standardgroesse = Masse der Web-App")
        }
    }

    func testTextSizeFollowsTheSettingAndStopsAtAccessibility3() {
        let body: CGFloat = 14.5
        let small = UFScaledFont.scaled(body, .xSmall)
        let big = UFScaledFont.scaled(body, .xxxLarge)
        let ax3 = UFScaledFont.scaled(body, .accessibility3)
        XCTAssertLessThan(small, body)
        XCTAssertGreaterThan(big, body)
        XCTAssertGreaterThan(ax3, big)
        XCTAssertEqual(UFScaledFont.scaled(body, .accessibility5), ax3, "begrenzt auf Stufe 3")
        XCTAssertEqual(big * 4, (big * 4).rounded(), "Viertelpunkte, damit der Schrift-Zwischenspeicher klein bleibt")
    }
}
