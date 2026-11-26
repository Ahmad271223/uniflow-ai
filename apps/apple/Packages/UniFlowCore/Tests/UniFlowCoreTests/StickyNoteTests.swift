import XCTest
@testable import UniFlowCore

/// Notizzettel wie echte Klebezettel (25.11.2026): Format, Auswahl, Groessen - und dass aeltere Apps und die
/// Community weiter eine Haftnotiz sehen.
final class StickyNoteTests: XCTestCase {

    func testNeuerZettelBleibtDieHaftnotizDesGemeinsamenFormats() {
        let c = StickyNote.Choice(color: "#ffd3e0", look: "tape", paper: "lined", size: "l")
        let o = StickyNote.note(id: "n", x: 300, y: 200, choice: c, page: (595, 842))
        XCTAssertEqual(o["type"], "text", "kein neuer Objekttyp")
        XCTAssertEqual(o["bg"], "#ffd3e0", "aeltere Apps zeigen das farbige Rechteck")
        XCTAssertEqual(o["note"], ["look": "tape", "paper": "lined"])
        XCTAssertEqual(o["width"], 230)
        XCTAssertEqual(o["minHeight"], 230, "etwa quadratisch, auch ohne Text")
        XCTAssertEqual(o["fontSize"], 18)
        XCTAssertEqual(o["fontFamily"], "Noteworthy")
        XCTAssertEqual(o["x"]?.double, 300 - 115, "Mitte der Oberkante am Tippunkt")
        XCTAssertEqual(o["y"]?.double, 188)
        XCTAssertEqual((o["lineHeight"]?.double ?? 0) * 18, StickyNote.lineStep, accuracy: 0.02, "liniert: Zeilenabstand fuers Web")
        XCTAssertTrue(StickyNote.isNote(o))
        XCTAssertTrue(StickyNote.isSticky(o))
        XCTAssertTrue(StickyNote.isLined(o))
        XCTAssertTrue(TextBlock.isBlock(o), "Text des Zettels ist formatierbar")
        XCTAssertFalse(TextBlock.isSnapped(o), "rastet nicht auf den Linien der Seite ein")
        XCTAssertEqual(StickyNote.choice(o), c)
        XCTAssertNoThrow(try SolutionValidator.validateObject(o), "geht mit geteilten Loesungen mit")
    }

    func testZettelBleibtAufDerSeite() {
        let right = StickyNote.note(id: "n", x: 590, y: 835, choice: StickyNote.Choice(size: "m"), page: (595, 842))
        XCTAssertEqual(right["x"]?.double, 595 - 165)
        XCTAssertEqual(right["y"]?.double, 842 - 165)
        let left = StickyNote.note(id: "n", x: 3, y: 2, page: (595, 842))
        XCTAssertEqual(left["x"]?.double, 0)
        XCTAssertEqual(left["y"]?.double, 0)
    }

    func testUnbekannteWerteFallenAufDieVorgabe() {
        let o = StickyNote.note(id: "n", x: 100, y: 100, choice: StickyNote.Choice(color: "#123456", look: "glitzer", paper: "holz", size: "xxl"))
        XCTAssertEqual(o["bg"]?.string, PageObjectEdit.stickyColor)
        XCTAssertEqual(StickyNote.look(o), "glue")
        XCTAssertEqual(StickyNote.paper(o), "plain")
        XCTAssertEqual(o["width"], 165)
        var broken = o
        broken["note"] = ["look": 7, "paper": .null]
        XCTAssertEqual(StickyNote.look(broken), "glue")
        broken["minHeight"] = 1e12
        XCTAssertEqual(StickyNote.minHeight(broken), 2_000)
        broken["minHeight"] = .number(.infinity)
        XCTAssertEqual(StickyNote.minHeight(broken), 0)
    }

    func testAlteGelbeHaftnotizWirdZumZettel() {
        let old = PageObjectEdit.sticky(id: "s", x: 100, y: 100, text: "Klausur am 12.02.")
        XCTAssertFalse(StickyNote.isNote(old))
        XCTAssertTrue(StickyNote.isSticky(old))
        XCTAssertEqual(StickyNote.minHeight(old), 0)
        let text = PageObjectEdit.text(id: "t", x: 0, y: 0, text: "kein Zettel")
        let out = StickyNote.restyling([old, text], ids: ["s", "t"]) { $0.look = "pin"; $0.color = "#cfe8ff" }
        XCTAssertEqual(out[1], text, "Text ohne Hintergrund bleibt Text")
        XCTAssertEqual(out[0]["text"], "Klausur am 12.02.")
        XCTAssertEqual(out[0]["bg"], "#cfe8ff")
        XCTAssertEqual(StickyNote.look(out[0]), "pin")
        XCTAssertEqual(out[0]["fontSize"], 13, "die Schrift bleibt, wie sie war")
        XCTAssertEqual(out[0]["width"], 165, "Breite 170 der alten Notiz: mittlere Groesse")
        // Groesse aendern: Breite und Mindesthoehe, alles andere bleibt
        let big = StickyNote.restyling(out, ids: ["s"]) { $0.size = "l" }
        XCTAssertEqual(big[0]["width"], 230)
        XCTAssertEqual(big[0]["minHeight"], 230)
        XCTAssertEqual(StickyNote.look(big[0]), "pin")
        XCTAssertEqual(big[0]["bg"], "#cfe8ff")
    }

    func testAnfasserSkalierenAuchDieHoehe() {
        let o = StickyNote.note(id: "n", x: 100, y: 100)
        let half = PageObjectEdit.scale([o], ids: ["n"], factorX: 0.5, factorY: 0.5)[0]
        XCTAssertEqual(half["width"]?.double, 82.5)
        XCTAssertEqual(half["minHeight"]?.double, 82.5, "bleibt quadratisch")
        // einfache Textfelder haben keine Mindesthoehe
        let t = PageObjectEdit.scale([PageObjectEdit.text(id: "t", x: 0, y: 0)], ids: ["t"], factorX: 0.5, factorY: 0.5)[0]
        XCTAssertNil(t["minHeight"])
    }

    func testAuswahlIstVollstaendig() {
        XCTAssertEqual(StickyNote.colors.count, 6)
        XCTAssertEqual(StickyNote.looks.count, 4)
        XCTAssertEqual(StickyNote.papers.count, 4)
        XCTAssertEqual(StickyNote.sizes.map(\.id), ["s", "m", "l"])
        XCTAssertEqual(StickyNote.colors[0].hex, PageObjectEdit.stickyColor, "erste Farbe: das Gelb der bisherigen Haftnotiz")
    }
}
