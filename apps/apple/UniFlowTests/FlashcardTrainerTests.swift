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
}
