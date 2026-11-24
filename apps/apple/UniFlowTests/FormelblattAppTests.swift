import XCTest
@testable import UniFlow

/// Formelblatt-Karte (22.11.2026): Texte für Preis, Kauf und Hinweis aufs Abschreiben
final class FormelblattAppTests: XCTestCase {
    // In 1.0.7 aus (Entscheidung des Inhabers 24.11.2026); die Tests pruefen die Funktion weiter mit Schalter an
    override func setUp() { super.setUp(); FormelblattCard.isEnabled = true }
    override func tearDown() { FormelblattCard.isEnabled = false; super.tearDown() }

    func testTexts() {
        XCTAssertEqual(Formelblatt.buyButton(3), "Für 3 Credits kaufen")
        XCTAssertEqual(Formelblatt.facts(pages: 2, credits: 3), "2 Seiten · einmalig 3 Credits")
        XCTAssertEqual(Formelblatt.facts(pages: nil, credits: 3), "einmalig 3 Credits")
        XCTAssertEqual(Formelblatt.confirmTitle(3), "Formelblatt für 3 Credits kaufen?")
        XCTAssertEqual(Formelblatt.bought(3), "Gekauft für 3 Credits. Das Formelblatt liegt jetzt im Modul.")
        XCTAssertEqual(Formelblatt.bought(0), "Das Formelblatt liegt jetzt im Modul.", "schon gekauft: nichts abgebucht")
        XCTAssertTrue(Formelblatt.note.contains("handbeschriebenes Blatt"))
    }
}
