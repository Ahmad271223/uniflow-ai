import XCTest
@testable import UniFlow

/// Breite der geteilten Ansicht (`SplitWidth`). Meldung des Inhabers 17.11.2026 am iPad (links KI-Hilfe, Mitte Skript,
/// rechts anderes Skript): "größer ging, aber kleiner ziehen nach links nicht mehr".
final class SplitWidthAppTests: XCTestCase {
    /// iPad (A16) quer
    private let total: CGFloat = 1180

    /// Der Fall vom Geraet: KI-Hilfe links (280), Spalte daneben in der Mitte am Anschlag. Anfassen aendert nichts,
    /// 100 pt nach links machen die Spalte 100 pt schmaler - vorher sprang sie beim Anfassen um die Breite der KI-Hilfe.
    func testAnfassenSpringtNichtUndLinksWirdKleiner() {
        let fixed = SplitWidth.fixedColumns(sidebar: false, tutor: true)
        let start = SplitWidth.clamp(0.65, total: total, fixed: fixed)
        XCTAssertEqual(SplitWidth.dragged(from: start, translation: 0, sideLeft: true, total: total, fixed: fixed), start, accuracy: 0.0001)
        let smaller = SplitWidth.dragged(from: start, translation: -100, sideLeft: true, total: total, fixed: fixed)
        XCTAssertEqual(Double(total) * (start - smaller), 100, accuracy: 0.5, "100 pt nach links = 100 pt schmaler")
        // Spalte rechts: nach rechts ziehen macht sie schmaler
        let right = SplitWidth.dragged(from: start, translation: 100, sideLeft: false, total: total, fixed: fixed)
        XCTAssertEqual(Double(total) * (start - right), 100, accuracy: 0.5)
    }

    /// Wie bis 17.11.: ohne weitere Spalten 20 bis 65 %
    func testGrenzenOhneWeitereSpalten() {
        XCTAssertEqual(SplitWidth.maxFraction(total: total, fixed: 0), 0.65, accuracy: 0.0001)
        XCTAssertEqual(SplitWidth.dragged(from: 0.42, translation: 5000, sideLeft: true, total: total, fixed: 0), 0.65, accuracy: 0.0001)
        XCTAssertEqual(SplitWidth.dragged(from: 0.42, translation: -5000, sideLeft: true, total: total, fixed: 0), 0.2, accuracy: 0.0001)
    }

    /// Mit KI-Hilfe behaelt das Hauptdokument seine Mindestbreite (vorher blieben am Geraet 120 pt)
    func testHauptdokumentBehaeltPlatzNebenDerKIHilfe() {
        let fixed = SplitWidth.fixedColumns(sidebar: false, tutor: true)
        let f = SplitWidth.clamp(0.65, total: total, fixed: fixed)
        let main = total - fixed - SplitWidth.handle - total * CGFloat(f)
        XCTAssertGreaterThanOrEqual(main, TutorPanelWidth.minDocument - 0.5)
        XCTAssertLessThan(f, 0.65)
        // die KI-Hilfe passt daneben in ihrer schmalsten Breite
        let tutor = TutorPanelWidth.width(stored: 280, total: total, reserved: total * CGFloat(f) + SplitWidth.handle)
        XCTAssertEqual(tutor, TutorPanelWidth.minWidth, accuracy: 0.5)
    }

    /// Sehr schmales Fenster: nie unter 20 %, nie ueber 65 %, keine Unsinnswerte
    func testSchmalesFenster() {
        for w in [0, 320, 500, 820] as [CGFloat] {
            let m = SplitWidth.maxFraction(total: w, fixed: SplitWidth.fixedColumns(sidebar: true, tutor: true))
            XCTAssertGreaterThanOrEqual(m, 0.2)
            XCTAssertLessThanOrEqual(m, 0.65)
        }
    }
}
