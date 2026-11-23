import UniFlowCore
import XCTest
@testable import UniFlow

/// Stundenplan am iPhone, Ansicht "Woche" (`PhoneTimetableWeek`, Auftrag des Inhabers 23.11.2026): Bloecke je Tag,
/// Fachnamen, Kurzformen der Art und Silbentrennung - reine Funktionen, ohne Bildschirm.
final class IPhoneTimetableWeekTests: XCTestCase {
    private func ev(_ title: String, _ start: String, _ end: String, kind: String = "vorlesung", status: String = "teilnahme") -> JSONValue {
        ["title": .string(title), "start": .string(start), "end": .string(end), "kind": .string(kind), "status": .string(status)]
    }

    func testOverlappingEventsShareOneBlock() {
        let day: JSONValue = ["date": "2026-11-25", "weekday": 2, "events": .array([
            ev("Englische Sprachwissenschaft – Seminar", "10:00", "12:00", kind: "seminar"),
            ev("Biologie für das Lehramt – Vorlesung", "10:15", "11:45"),
            ev("Grundlagen der Informatik – Übung", "14:00", "16:00", kind: "uebung"),
            ev("Verschoben", "16:00", "17:00", status: "verschoben"),
            ev("Danach", "12:00", "13:00"),
        ])]
        let b = PhoneTimetableWeek.blocks(day)
        XCTAssertEqual(b.map(\.events.count), [2, 1, 1], "10–12 Uhr zusammen, 12 Uhr beginnt neu, 14 Uhr allein, verschoben fehlt")
        XCTAssertEqual(b.first?.start, 10 * 60)
        XCTAssertEqual(b.first?.end, 12 * 60)
    }

    func testSubjectDropsKindSuffix() {
        XCTAssertEqual(PhoneTimetableWeek.subject(ev("Grundlagen der Informatik – Vorlesung", "10:00", "12:00")), "Grundlagen der Informatik")
        XCTAssertEqual(PhoneTimetableWeek.subject(ev("Einführung in die Erziehungswissenschaft – Tutorium", "10:00", "12:00")),
                       "Einführung in die Erziehungswissenschaft")
        XCTAssertEqual(PhoneTimetableWeek.subject(ev("Mensch – Maschine", "10:00", "12:00")), "Mensch – Maschine", "kein Art-Wort: bleibt")
        XCTAssertEqual(PhoneTimetableWeek.kindShort("vorlesung"), "VL")
        XCTAssertEqual(PhoneTimetableWeek.kindShort("uebung"), "Ü")
        XCTAssertNil(PhoneTimetableWeek.kindShort("sonstiges"))
    }

    func testHyphenationBreaksAtSyllablesOnly() {
        let soft = "\u{00AD}"
        let h = PhoneTimetableWeek.hyphenateWord("Bildungsforschung")
        XCTAssertEqual(h.replacingOccurrences(of: soft, with: ""), "Bildungsforschung", "nur unsichtbare Trennstellen")
        XCTAssertTrue(h.contains("Bil\(soft)dungs") || h.contains("Bildungs\(soft)for"), h.replacingOccurrences(of: soft, with: "|"))
        XCTAssertFalse(h.contains("s\(soft)ch"), "sch bleibt zusammen")
        XCTAssertEqual(PhoneTimetableWeek.hyphenateWord("Kurz"), "Kurz", "kurze Woerter bleiben")
        // passt ein Wort, bleibt es ganz (gemessen)
        let wide = PhoneTimetableWeek.fitted("Grundlagen der Informatik", width: 200, maxSize: 10.5, minSize: 9.5, weight: 650)
        XCTAssertEqual(wide.text, "Grundlagen der Informatik")
        XCTAssertEqual(wide.size, 10.5)
        let narrow = PhoneTimetableWeek.fitted("Bildungsforschung", width: 40, maxSize: 10.5, minSize: 9.5, weight: 650)
        XCTAssertEqual(narrow.size, 9.5)
        XCTAssertTrue(narrow.text.contains(soft), "zu breit: Trennstellen")
    }
}
