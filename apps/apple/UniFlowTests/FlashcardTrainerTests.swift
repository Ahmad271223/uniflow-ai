import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Karteikarten-Trainer ohne Backend: Filter (Lernen, Fortschritt), Reihenfolge und zuerst gezeigte Seite.
/// Ablauf mit Speichern (Zaehler, Vorherige, Verstecken) steht in FlashcardsAppTests.
@MainActor
final class FlashcardTrainerTests: XCTestCase {

    /// Erfundene Karten: id, Lesezeichen, versteckt, letztes Urteil
    private func card(_ id: Int, bookmarked: Bool = false, hidden: Bool = false, result: String? = nil) -> JSONValue {
        ["id": .number(Double(id)), "question": .string("Begriff \(id)"), "answer": .string("Definition \(id)"),
         "box": 1, "bookmarked": .number(bookmarked ? 1 : 0), "hidden": .number(hidden ? 1 : 0),
         "last_result": result.map(JSONValue.string) ?? .null]
    }

    /// Wie GET /api/flashcards: neueste zuerst
    private var deck: [JSONValue] {
        [card(6, hidden: true, result: "right"), card(5, bookmarked: true, hidden: true), card(4, bookmarked: true, result: "wrong"),
         card(3, result: "right"), card(2, bookmarked: true, result: "right"), card(1)]
    }

    private func ids(_ o: FlashcardTrainerOptions) -> [Int] { o.select(deck, shuffle: { $0 }).compactMap { $0.i("id") } }

    func testProgressGroups() {
        XCTAssertEqual(deck.map(FlashcardProgress.of), [.hidden, .hidden, .wrong, .right, .right, .unlearned],
                       "versteckt geht vor dem Urteil")
        XCTAssertEqual(FlashcardProgress.of(["id": 9]), .unlearned, "ohne Spalten (alter Server): noch nicht gelernt")
        XCTAssertEqual(FlashcardProgress.of(["id": 9, "last_result": "vielleicht"]), .unlearned)
        XCTAssertEqual(FlashcardTrainer.counts(deck), [.hidden: 2, .wrong: 1, .right: 2, .unlearned: 1])
    }

    func testFilterCombinations() {
        var o = FlashcardTrainerOptions.standard
        XCTAssertEqual(ids(o), [1, 2, 3, 4], "Standard: alles ausser versteckt, Original = aelteste zuerst")
        o.scope = .bookmarked
        XCTAssertEqual(ids(o), [2, 4], "Lesezeichen ohne versteckte")
        o.progress = [.hidden]
        XCTAssertEqual(ids(o), [5], "Lesezeichen und versteckt")
        o.scope = .all
        XCTAssertEqual(ids(o), [5, 6], "nur versteckte")
        o.progress = [.right]
        XCTAssertEqual(ids(o), [2, 3])
        o.progress = [.wrong, .unlearned]
        XCTAssertEqual(ids(o), [1, 4])
        o.progress = [.right, .hidden]
        XCTAssertEqual(ids(o), [2, 3, 5, 6], "versteckte zaehlen nicht als richtig, nur ueber Versteckte Karten")
        o.progress = Set(FlashcardProgress.allCases)
        XCTAssertEqual(ids(o), [1, 2, 3, 4, 5, 6])
        o.progress = []
        XCTAssertEqual(ids(o), [], "nichts gewaehlt: keine Karte")
        o.scope = .bookmarked
        o.progress = [.unlearned]
        XCTAssertEqual(ids(o), [], "keine ungelernte Karte mit Lesezeichen")
    }

    func testOrderOriginalAndRandom() {
        var o = FlashcardTrainerOptions.standard
        o.progress = Set(FlashcardProgress.allCases)
        XCTAssertEqual(o.select(deck).compactMap { $0.i("id") }, [1, 2, 3, 4, 5, 6], "Original mischt nie")
        o.order = .random
        XCTAssertEqual(o.select(deck, shuffle: { $0.reversed() }).compactMap { $0.i("id") }, [6, 5, 4, 3, 2, 1],
                       "Zufällig mischt die gefilterte Liste")
        let shuffled = o.select(deck).compactMap { $0.i("id") }
        XCTAssertEqual(shuffled.sorted(), [1, 2, 3, 4, 5, 6], "dieselben Karten, keine doppelt")
        o.progress = [.right]
        XCTAssertEqual(Set(o.select(deck).compactMap { $0.i("id") }), [2, 3], "erst filtern, dann mischen")
    }

    func testFirstSideAndFlip() {
        let t = FlashcardTrainer()
        t.start(with: deck)
        XCTAssertEqual(t.current?.i("id"), 1)
        XCTAssertFalse(t.showsDefinition, "Standard: zuerst der Begriff")
        t.flip()
        XCTAssertTrue(t.showsDefinition)
        t.flip()
        XCTAssertFalse(t.showsDefinition)
        var o = t.options
        o.firstSide = .definition
        t.flip()
        t.apply(o)
        XCTAssertFalse(t.flipped, "Optionen anwenden beginnt vorn")
        XCTAssertTrue(t.showsDefinition, "zuerst die Definition")
        t.flip()
        XCTAssertFalse(t.showsDefinition, "umgedreht: der Begriff")
    }

    /// "Erneut fragen": Karte rueckt drei Plaetze nach hinten (oder ans Ende), ohne Urteil und ohne Zaehler
    func testAskAgainMovesCardBackWithoutJudgement() {
        let t = FlashcardTrainer()
        t.start(with: deck)
        XCTAssertEqual(t.cards.compactMap { $0.i("id") }, [1, 2, 3, 4])
        XCTAssertTrue(t.askAgain())
        XCTAssertEqual(t.cards.compactMap { $0.i("id") }, [2, 3, 4, 1], "drei Karten spaeter = ans Ende bei vier Karten")
        XCTAssertEqual(t.current?.i("id"), 2)
        XCTAssertEqual([t.known, t.unknown, t.position], [0, 0, 0], "kein Urteil, kein Zaehler")
        XCTAssertEqual(t.progressText, "1/4", "die Gesamtzahl bleibt")
        XCTAssertFalse(t.canGoBack, "Vorherige nimmt nur Antworten zurueck")
        t.flip()
        XCTAssertTrue(t.askAgain())
        XCTAssertFalse(t.flipped, "neue Karte vorn: Vorderseite")
        XCTAssertEqual(t.cards.compactMap { $0.i("id") }, [3, 4, 1, 2])
        // letzte Karte: nichts mehr danach -> nicht moeglich
        let last = FlashcardTrainer()
        last.start(with: [deck[0]])
        XCTAssertFalse(last.canAskAgain)
        XCTAssertFalse(last.askAgain())
    }

    func testStartRestartAndEmpty() {
        let t = FlashcardTrainer()
        t.shuffle = { $0.reversed() }
        t.start(with: deck)
        XCTAssertTrue(t.active)
        XCTAssertEqual(t.cards.count, 4)
        XCTAssertEqual(t.progressText, "1/4")
        XCTAssertFalse(t.canGoBack, "noch nichts beantwortet")
        var o = t.options
        o.order = .random
        t.apply(o)
        XCTAssertEqual(t.cards.compactMap { $0.i("id") }, [4, 3, 2, 1])
        o.scope = .bookmarked
        o.progress = [.unlearned]
        t.apply(o)
        XCTAssertTrue(t.empty, "Filter zu eng")
        XCTAssertNil(t.current)
        XCTAssertFalse(t.finished, "leer ist nicht geschafft")
        t.apply(.standard)
        XCTAssertEqual(t.cards.compactMap { $0.i("id") }, [1, 2, 3, 4])
        t.end()
        XCTAssertFalse(t.active)
        XCTAssertNil(t.current)
    }

    // MARK: - Neugestaltung 04.11.2026: Kacheln, Buehne, "Frag die KI"

    /// Art eines Stapels -> Farbe und Symbol der Kachel (Paare aus CommunityPalette)
    func testStackKindColourMapping() {
        XCTAssertEqual(FlashcardStackKind.of(["kind": "vorlesung"]), .lecture)
        XCTAssertEqual(FlashcardStackKind.of(["kind": "uebung", "source": "week"]), .exercise, "gemeinsamer Wochenstapel behaelt seine Art")
        XCTAssertEqual(FlashcardStackKind.of(["kind": "eigene"]), .own)
        XCTAssertEqual(FlashcardStackKind.of(["name": "ohne Art"]), .own)
        XCTAssertEqual(FlashcardStackKind.of(["kind": "vorlesung", "source": "community"]), .community, "von anderen uebernommen geht vor der Art")
        XCTAssertEqual(FlashcardStackKind.lecture.pair.solid, CommunityPalette.mint.solid, "Vorlesung gruen")
        XCTAssertEqual(FlashcardStackKind.exercise.pair.solid, CommunityPalette.sky.solid, "Übung blau")
        XCTAssertEqual(FlashcardStackKind.own.pair.solid, CommunityPalette.lavender.solid, "Eigene violett")
        XCTAssertEqual(FlashcardStackKind.community.pair.solid, CommunityPalette.butter.solid, "Von anderen bernstein")
        XCTAssertEqual(FlashcardStackKind.allCases.map(\.label), ["Vorlesung", "Übung", "Eigene", "Von anderen"])
        XCTAssertEqual(Set(FlashcardStackKind.allCases.map(\.icon)).count, 4, "jede Art ein eigenes Symbol")
    }

    /// Leitner-Faecher je Stapel: Zahl der Karten in Fach 1-5, Grenzen begrenzt, fehlendes Fach = 1
    func testBoxCountsForTheTileBar() {
        let cards: [JSONValue] = [["box": 1], ["box": 1], ["box": 2], ["box": 5], ["box": 9], ["box": 0], ["id": 7]]
        XCTAssertEqual(FlashcardDeck.boxCounts(cards), [4, 1, 0, 0, 2])
        XCTAssertEqual(FlashcardDeck.boxCounts([]), [0, 0, 0, 0, 0])
        XCTAssertEqual(FlashcardDeck.boxSummary([4, 1, 0, 0, 2]), "Fach 1: 4 · Fach 2: 1 · Fach 3: 0 · Fach 4: 0 · Fach 5: 2")
        let deck = FlashcardDeck()
        XCTAssertEqual(deck.boxCounts(stack: 1), [0, 0, 0, 0, 0], "ohne geladene Karten leer")
    }

    /// Kachel: "heute fällig" gross, Woche als Chip, "Üben" beginnt mit den faelligen Karten
    func testTileFactsDueWeekAndPractice() {
        let due: JSONValue = ["id": 1, "name": "Folgen", "cards": 12, "due": 3, "week": 4, "kind": "vorlesung"]
        let calm: JSONValue = ["id": 2, "name": "Reihen", "cards": 5, "due": 0]
        let none: JSONValue = ["id": 3, "name": "Leer", "cards": 0]
        XCTAssertEqual(FlashcardDeck.dueCount(due), 3)
        XCTAssertEqual(FlashcardDeck.dueCount(none), 0)
        XCTAssertEqual(FlashcardDeck.weekChip(due), "Woche 4")
        XCTAssertEqual(FlashcardDeck.weekChip(calm), "Allgemein")
        XCTAssertTrue(FlashcardDeck.practiceStartsReview(due))
        XCTAssertFalse(FlashcardDeck.practiceStartsReview(calm))
        XCTAssertEqual(FlashcardDeck.practiceHint(due), "Zuerst die 3 fälligen Karten")
        XCTAssertEqual(FlashcardDeck.practiceHint(["cards": 2, "due": 1]), "Zuerst die fällige Karte")
        XCTAssertEqual(FlashcardDeck.practiceHint(calm), "Frei üben, der Plan bleibt")
        XCTAssertEqual(FlashcardDeck.practiceHint(none), "Noch keine Karte im Stapel")
        // Wert der Kachel fuer VoiceOver und Tests: Etikett · Zeile wie bisher (unveraendert), dazu die Faecher
        XCTAssertEqual(FlashcardDeck.badge(due), "Vorlesung · W4")
        XCTAssertEqual(FlashcardDeck.stackLine(calm), "Ohne Modul · 5 Karten · Heute fällig (0) · noch nicht geübt")
    }

    /// Buehne: "Karte 3 von 12", nie "Karte 0" oder ueber die Zahl hinaus; Balken = erledigte Karten
    func testProgressHeaderLabelAndFraction() {
        XCTAssertEqual(FlashcardProgressHeader<EmptyView>.label(current: 3, total: 12), "Karte 3 von 12")
        XCTAssertEqual(FlashcardProgressHeader<EmptyView>.label(current: 0, total: 12), "Karte 1 von 12")
        XCTAssertEqual(FlashcardProgressHeader<EmptyView>.label(current: 13, total: 12), "Karte 12 von 12")
        XCTAssertEqual(FlashcardProgressHeader<EmptyView>.fraction(done: 3, total: 12), 0.25)
        XCTAssertEqual(FlashcardProgressHeader<EmptyView>.fraction(done: 0, total: 0), 0)
        XCTAssertEqual(FlashcardProgressHeader<EmptyView>.fraction(done: 20, total: 12), 1)
    }

    /// "Frag die KI zu Aufgabe n": Aufgabe, eigene Antwort, richtige Antwort und Erklaerung gehen als Kontext mit
    func testAskAIContextText() {
        let q: JSONValue = ["nr": 2, "type": "tf", "question": " Die Dezimalzahl 255 ist hexadezimal F0. ", "options": ["Wahr", "Falsch"],
                            "answer": "Falsch", "explanation": "255 = FF, denn 15·16 + 15 = 255."]
        let fb: JSONValue = ["nr": 2, "points": 0, "max": 20, "feedback": "Leider falsch."]
        let c = ExamAskContext.make(q, given: "Wahr ", feedback: fb)
        XCTAssertEqual(c.nr, "2")
        XCTAssertEqual(c.kind, "Wahr / Falsch")
        XCTAssertEqual(c.question, "Die Dezimalzahl 255 ist hexadezimal F0.")
        XCTAssertEqual(c.given, "Wahr")
        XCTAssertEqual(c.correct, "Falsch")
        XCTAssertEqual(c.explanation, "255 = FF, denn 15·16 + 15 = 255.")
        XCTAssertEqual(ExamAskContext.buttonTitle(nr: c.nr), "Frag die KI zu Aufgabe 2")
        XCTAssertEqual(c.title, "Warum ist meine Antwort zu Aufgabe 2 falsch?")
        XCTAssertEqual(c.prompt, """
            Ich habe in meinem Wochentest Aufgabe 2 (Wahr / Falsch) falsch beantwortet.

            Aufgabe: Die Dezimalzahl 255 ist hexadezimal F0.
            Meine Antwort: Wahr
            Richtige Antwort: Falsch
            Erklärung aus dem Test: 255 = FF, denn 15·16 + 15 = 255.

            Erkläre mir kurz und verständlich, warum meine Antwort falsch ist und wie ich auf die richtige Antwort komme.
            """)
        // ohne Antwort und ohne Erklaerung im Test: ehrlich "(keine Antwort)", die Rueckmeldung der Bewertung ersetzt
        // die fehlende Erklaerung; Lueckentext: das Wort fuer die Luecke
        let cloze: JSONValue = ["nr": 3, "type": "cloze", "question": "Die Basis des Hexadezimalsystems ist ___.", "answer": "Die Basis ist 16", "blank": "16"]
        let c2 = ExamAskContext.make(cloze, given: "", feedback: ["feedback": "Keine Antwort."])
        XCTAssertEqual(c2.correct, "16")
        XCTAssertEqual(c2.explanation, "Keine Antwort.")
        XCTAssertTrue(c2.prompt.contains("Meine Antwort: (keine Antwort)"), c2.prompt)
        XCTAssertTrue(c2.prompt.contains("Erklärung aus dem Test: Keine Antwort."), c2.prompt)
        let bare = ExamAskContext.make(["nr": 1, "type": "short", "question": "Was ist ein Bit?"], given: "Byte", feedback: nil)
        XCTAssertNil(bare.explanation)
        XCTAssertFalse(bare.prompt.contains("Erklärung aus dem Test"))
        XCTAssertTrue(bare.prompt.contains("Richtige Antwort: (nicht angegeben)"))
    }

    /// Ergebnis: Ring = Anteil der Punkte; KI-Hilfe quer als Spalte, hochkant als Dialog
    func testScoreRingAndAskPlacement() {
        XCTAssertEqual(ExamScoreRing.fraction(75), 0.75)
        XCTAssertEqual(ExamScoreRing.fraction(-5), 0)
        XCTAssertEqual(ExamScoreRing.fraction(140), 1)
        XCTAssertTrue(ExamRunPage.asksInColumn(windowWidth: 1366))
        XCTAssertTrue(ExamRunPage.asksInColumn(windowWidth: 1180))
        XCTAssertFalse(ExamRunPage.asksInColumn(windowWidth: 820), "hochkant: Dialog")
    }
}

