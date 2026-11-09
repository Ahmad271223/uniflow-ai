import XCTest
@testable import UniFlow

/// Befund des Inhabers 09.11.2026 (Build 27): "Rechtshänder/Linkshänder-Einstellung ist auf dem iPad vertauscht".
/// Beschreibung der Einstellung: "Seitenleiste und Skript in der geteilten Ansicht liegen auf der Seite der freien Hand".
/// Bisher lag jede Spalte daneben auf der Seite der freien Hand - auch das leere Blatt zum Mitschreiben und ein
/// Uebungsblatt neben der Folie. Ein Rechtshaender schrieb dann links, die Folie lag unter seiner Schreibhand rechts.
/// Dazu: Seiten tauschen an der Kopfzeile, je Paar gemerkt.
final class SplitSidesAppTests: XCTestCase {
    private func file(_ id: String, name: String, kind: String = "pdf", type: String? = nil) -> LibFile {
        LibFile(id: id, name: name, title: nil, kind: kind, module_id: 1, subject: nil, doc_type: type, ai_title: nil,
                sub_label: nil, downloaded_at: "x", has_notes: nil, page_count: nil, studip_folder: nil)
    }

    private lazy var script = file("s", name: "VL03 Graphen.pdf", type: "vorlesung")
    private lazy var exercise = file("u", name: "Uebung 3.pdf", type: "uebung")
    private lazy var sheet = file("n", name: "Notizen – VL03 Graphen", kind: "notebook")

    /// Lage der Spalte daneben fuer eine Einstellung: true = links
    private func left(_ hand: String, side: LibFile?, primary: LibFile, swapped: Bool = false) -> Bool {
        SplitSides.sidePaneLeft(hand: hand, role: SplitSides.role(side: side, primary: primary), swapped: swapped)
    }

    func testFreeHandSideFollowsSetting() {
        XCTAssertTrue(SplitSides.freeHandLeft(hand: "right"), "Rechtshaender: freie Hand links (Seitenleiste, KI-Hilfe, Schloss)")
        XCTAssertFalse(SplitSides.freeHandLeft(hand: "left"), "Linkshaender: freie Hand rechts")
        XCTAssertTrue(SplitSides.freeHandLeft(hand: ""), "ohne Einstellung wie Rechtshaender (Standard)")
    }

    func testScriptNextToExerciseLiesOnFreeHandSide() {
        // Uebungsblatt offen, "Passende Skriptstelle" oeffnet das Skript daneben
        XCTAssertTrue(left("right", side: script, primary: exercise), "Rechtshaender: Skript links, Uebung rechts")
        XCTAssertFalse(left("left", side: script, primary: exercise), "Linkshaender: Skript rechts, Uebung links")
    }

    func testBlankSheetNextToSlideLiesOnWritingHandSide() {
        // Folie offen, "Daneben öffnen" -> "Leeres Blatt" zum Mitschreiben
        XCTAssertEqual(SplitSides.role(side: sheet, primary: script), .writing)
        XCTAssertFalse(left("right", side: sheet, primary: script), "Rechtshaender: Blatt rechts unter der Schreibhand, Folie links")
        XCTAssertTrue(left("left", side: sheet, primary: script), "Linkshaender: Blatt links, Folie rechts")
    }

    func testExerciseNextToScriptLiesOnWritingHandSide() {
        // Skript offen, "Daneben öffnen" -> das Uebungsblatt
        XCTAssertEqual(SplitSides.role(side: exercise, primary: script), .writing)
        XCTAssertFalse(left("right", side: exercise, primary: script), "Rechtshaender: Uebung rechts, Skript links")
        XCTAssertTrue(left("left", side: exercise, primary: script), "Linkshaender: Uebung links, Skript rechts")
    }

    func testSolutionAndOtherReadingLieOnFreeHandSide() {
        XCTAssertEqual(SplitSides.role(side: nil, primary: script), .reference, "Loesung zum Ansehen")
        XCTAssertTrue(left("right", side: nil, primary: script))
        XCTAssertFalse(left("left", side: nil, primary: script))
        XCTAssertEqual(SplitSides.role(side: script, primary: sheet), .reference, "Skript neben einem Notizbuch")
        XCTAssertEqual(SplitSides.role(side: exercise, primary: exercise), .reference, "zwei Uebungen: wie bisher")
    }

    func testSolutionHintMatchesLayout() {
        XCTAssertEqual(SplitSides.solutionHint(hand: "right"), "Links die Lösung, rechts deine Folie auf derselben Seite.")
        XCTAssertEqual(SplitSides.solutionHint(hand: "left"), "Links deine Folie, rechts die Lösung auf derselben Seite.")
    }

    // MARK: Seiten tauschen

    func testSwapMirrorsPlacement() {
        XCTAssertFalse(left("right", side: script, primary: exercise, swapped: true), "getauscht: Skript rechts")
        XCTAssertTrue(left("right", side: sheet, primary: script, swapped: true), "getauscht: Blatt links")
        XCTAssertTrue(left("left", side: script, primary: exercise, swapped: true))
    }

    func testSwapIsRememberedPerPairAndTogglesBack() {
        let a = SplitSides.pairKey(primary: "u", side: "s"), b = SplitSides.pairKey(primary: "s", side: "loesung:7")
        var stored = ""
        XCTAssertFalse(SplitSides.isSwapped(stored, key: a))
        stored = SplitSides.toggling(stored, key: a)
        XCTAssertTrue(SplitSides.isSwapped(stored, key: a))
        XCTAssertFalse(SplitSides.isSwapped(stored, key: b), "nur dieses Paar")
        stored = SplitSides.toggling(stored, key: b)
        XCTAssertTrue(SplitSides.isSwapped(stored, key: a) && SplitSides.isSwapped(stored, key: b))
        stored = SplitSides.toggling(stored, key: a)
        XCTAssertFalse(SplitSides.isSwapped(stored, key: a), "zweiter Tausch: wieder wie vorgesehen")
        XCTAssertTrue(SplitSides.isSwapped(stored, key: b))
        XCTAssertFalse(SplitSides.isSwapped("u|s2", key: a), "kein Teiltreffer")
    }

    func testSwapMemoryIsBounded() {
        var stored = ""
        for i in 0..<(SplitSides.maxSwapped + 5) { stored = SplitSides.toggling(stored, key: "p\(i)|x") }
        XCTAssertEqual(stored.split(separator: "\n").count, SplitSides.maxSwapped)
        XCTAssertFalse(SplitSides.isSwapped(stored, key: "p0|x"), "aelteste fallen heraus")
        XCTAssertTrue(SplitSides.isSwapped(stored, key: "p\(SplitSides.maxSwapped + 4)|x"))
    }

    func testDropOnlySwapsOverTheOtherHalf() {
        // Spalte links: erst rechts der Mitte loslassen tauscht
        XCTAssertFalse(SplitSides.dropSwaps(sidePaneLeft: true, x: 300, width: 1000))
        XCTAssertFalse(SplitSides.dropSwaps(sidePaneLeft: true, x: 500, width: 1000), "genau auf der Mitte: nichts")
        XCTAssertTrue(SplitSides.dropSwaps(sidePaneLeft: true, x: 720, width: 1000))
        // Spalte rechts: links der Mitte
        XCTAssertTrue(SplitSides.dropSwaps(sidePaneLeft: false, x: 200, width: 1000))
        XCTAssertFalse(SplitSides.dropSwaps(sidePaneLeft: false, x: 800, width: 1000))
        XCTAssertFalse(SplitSides.dropSwaps(sidePaneLeft: true, x: 10, width: 0))
    }
}
