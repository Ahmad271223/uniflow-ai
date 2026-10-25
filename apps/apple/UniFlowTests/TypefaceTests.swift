import UIKit
import XCTest
@testable import UniFlow

/// Schrift wie im Browser: Inter aus der App, Gewichte nach CSS-Schriftabgleich, optische Groesse = Schriftgroesse.
final class TypefaceTests: XCTestCase {

    func testInterIsBundledAndUsed() {
        XCTAssertTrue(UFTypeface.hasInter, "Inter-Variable.ttf muss ueber UIAppFonts angemeldet sein")
        XCTAssertEqual(UFTypeface.font(14.5, 400).familyName, "Inter")
    }

    func testWeightsSnapLikeTheBrowser() {
        // Google Fonts meldet die variable Datei mit 400/500/600/700 an
        XCTAssertEqual(UFTypeface.snapped(400), 400)
        XCTAssertEqual(UFTypeface.snapped(450), 500)
        XCTAssertEqual(UFTypeface.snapped(550), 600)
        XCTAssertEqual(UFTypeface.snapped(650), 700)
        XCTAssertEqual(UFTypeface.snapped(800), 700)
        XCTAssertEqual(UFTypeface.snapped(300), 400)
    }

    func testTextWidthMatchesSafari() {
        // Safari im iPad-Simulator: 900 px bei 2360/1180 = 1,695 px/pt -> 531,0 pt (Untertitel des Lernkalenders)
        let s = "Dein Wochenplan – perfekt auf Vorlesungen, Übungen und Tests abgestimmt." as NSString
        let w = s.size(withAttributes: [.font: UFTypeface.font(14.5, 400)]).width
        XCTAssertEqual(w, 531.0, accuracy: 2.0)
        let bold = s.size(withAttributes: [.font: UFTypeface.font(14.5, 600)]).width
        XCTAssertGreaterThan(bold, w + 5, "Gewicht ueber die Achse wght gesetzt")
    }
}
