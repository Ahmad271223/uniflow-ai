import XCTest
@testable import UniFlowCore

/// Suche in einer Mitschrift (1.0.8): Treffer, Ausschnitt und die geschaetzte Stelle in der Aufnahme
final class TranscriptSearchTests: XCTestCase {
    private let sections = [
        TranscriptSection(start: 0, end: 60, text: "Guten Morgen zusammen, heute geht es um die Ableitung und um den Mittelwertsatz der Differentialrechnung."),
        TranscriptSection(start: 60, end: 120, text: "Für die Sinusfunktion erhalten wir in der Nähe von null die Näherung Sinus von x ungefähr gleich x. Diese Näherung benutzt man beim Pendel in der Hauptstraße."),
        TranscriptSection(start: 120, end: 180, text: "Zum Schluss: der Mittelwertsatz ist prüfungsrelevant. Bitte bearbeiten Sie das Übungsblatt 7."),
    ]

    func testQueryIsCleanedAndNeedsTwoCharacters() {
        XCTAssertEqual(TranscriptSearch.normalized("  Satz   von\tRolle "), "Satz von Rolle")
        XCTAssertEqual(TranscriptSearch.normalized("x"), "")
        XCTAssertEqual(TranscriptSearch.normalized("   "), "")
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "x"), [])
        XCTAssertEqual(TranscriptSearch.hits(sections, query: ""), [])
        XCTAssertEqual(TranscriptSearch.hits([], query: "Satz"), [])
    }

    func testHitsInOrderWithSnippetAndOriginalSpelling() {
        let hits = TranscriptSearch.hits(sections, query: "mittelwertsatz")
        XCTAssertEqual(hits.map(\.section), [0, 2])
        XCTAssertEqual(hits.map(\.id), [0, 1])
        XCTAssertEqual(hits.map(\.match), ["Mittelwertsatz", "Mittelwertsatz"])
        XCTAssertEqual(hits[0].before, "… heute geht es um die Ableitung und um den ")
        XCTAssertEqual(hits[0].after, " der Differentialrechnung.")
        XCTAssertEqual(hits[1].before, "Zum Schluss: der ")
        XCTAssertEqual(hits[1].after, " ist prüfungsrelevant. Bitte bearbeiten Sie das Übungsblatt 7.")
        // mehrere Treffer in einem Abschnitt
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "Näherung").map(\.section), [1, 1])
    }

    func testCaseUmlautsAndSharpSDoNotMatter() {
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "NAHERUNG").map(\.match), ["Näherung", "Näherung"])
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "hauptstrasse").map(\.match), ["Hauptstraße"])
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "Hauptstraße").map(\.match), ["Hauptstraße"])
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "ubungsblatt 7").map(\.match), ["Übungsblatt 7"])
        // Teil eines Wortes zaehlt
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "wertsatz").map(\.match), ["wertsatz", "wertsatz"])
    }

    func testTimeIsEstimatedInsideTheSectionWithLead() {
        let hits = TranscriptSearch.hits(sections, query: "Mittelwertsatz")
        // erster Treffer: weit hinten im ersten Abschnitt, mit Vorlauf, nie vor dem Abschnitt
        XCTAssertGreaterThan(hits[0].time, 25)
        XCTAssertLessThan(hits[0].time, 50)
        // zweiter Treffer: kurz nach Beginn des dritten Abschnitts -> Anfang des Abschnitts (Vorlauf reicht nicht davor)
        XCTAssertGreaterThanOrEqual(hits[1].time, 120)
        XCTAssertLessThan(hits[1].time, 135)
        // Abschnitt ohne Dauer: sein Anfang
        let flat = [TranscriptSection(start: 42, end: 42, text: "Der Satz von Rolle.")]
        XCTAssertEqual(TranscriptSearch.hits(flat, query: "Rolle").map(\.time), [42])
    }

    func testSeveralWordsFallBackToSectionsContainingAll() {
        // als Wortfolge gefunden: nur diese Stelle
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "Sinus von x").map(\.section), [1])
        // nicht als Folge, aber beide Woerter im selben Abschnitt: Treffer am ersten Wort
        let both = TranscriptSearch.hits(sections, query: "Pendel Sinusfunktion")
        XCTAssertEqual(both.map(\.section), [1])
        XCTAssertEqual(both.first?.match, "Pendel")
        // ein Wort fehlt ueberall
        XCTAssertEqual(TranscriptSearch.hits(sections, query: "Pendel Integral"), [])
    }

    func testLongSectionGetsACutSnippetAndTheLimitHolds() {
        let long = String(repeating: "Wir rechnen weiter und weiter. ", count: 40) + "Hier steht der Hauptsatz der Integralrechnung. "
            + String(repeating: "Danach kommt noch viel Text. ", count: 40)
        let hits = TranscriptSearch.hits([TranscriptSection(start: 0, end: 600, text: long)], query: "Hauptsatz")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].before.hasPrefix("… "), hits[0].before)
        XCTAssertTrue(hits[0].after.hasSuffix(" …"), hits[0].after)
        XCTAssertLessThanOrEqual(hits[0].before.count, 52)
        XCTAssertLessThanOrEqual(hits[0].after.count, 76)
        XCTAssertFalse(hits[0].before.dropFirst(2).hasPrefix("ir "), "beginnt am Wortanfang: \(hits[0].before)")
        XCTAssertEqual(TranscriptSearch.hits([TranscriptSection(start: 0, end: 600, text: long)], query: "weiter", limit: 5).count, 5)
    }

    func testSummaryLine() {
        XCTAssertEqual(TranscriptSearch.summary(0), "Keine Treffer.")
        XCTAssertEqual(TranscriptSearch.summary(1), "1 Treffer")
        XCTAssertEqual(TranscriptSearch.summary(7), "7 Treffer")
        XCTAssertEqual(TranscriptSearch.summary(200), "Mehr als 200 Treffer – die ersten 200")
    }
}
