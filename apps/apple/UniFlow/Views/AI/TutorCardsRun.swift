import Foundation
import UniFlowCore

/// Karteikarten aus dem ganzen Dokument oder einem Seitenbereich in der KI-Hilfe (07.11.2026, Fehler vom iPad: der Reiter
/// "Karteikarten" nahm immer nur die offene Seite, egal welcher Umfang gewaehlt war). Jetzt nimmt der Reiter den
/// Umfang wie "Ganze Vorlesung erklären": "Diese Seite" fragt wie bisher `POST /api/ai/tutor` (Modus flashcards),
/// "Ganzes Dokument" und "Seiten …" laufen in Teilen von hoechstens `pagesPerStep` Seiten ueber `POST /api/ai/flashcards`
/// (derselbe Weg wie "Karteikarten aus Dokument", Dienst und lokales Backend, je Anfrage hoechstens
/// `FLASHCARD_PAGES_MAX` Seiten). Die Karten aller Teile landen in einer Antwort des Gespraechs; der Nutzer sieht
/// jede Karte und speichert sie erst mit "Als Karteikarten speichern" (wie bisher). Reine Regeln, ohne Netz
/// (UniFlowTests/TutorCardsRunAppTests.swift).
enum TutorCardsRun {
    /// Seiten je Anfrage (`AIEndpoints.flashcardPagesMax`, `FLASHCARD_PAGES_MAX`)
    static let pagesPerStep = 20
    /// Wenigstens so viele Karten fuer einen Bereich, hoechstens so viele (ueber alle Teile)
    static let minCards = 8
    static let maxCards = 30
    /// Ohne bekannte Seitenzahl: so weit laufen die Teile hoechstens (wie der Lauf fuers Erklaeren); das Ende des
    /// Dokuments erkennt `continues(after:requested:)` an den gelieferten Seiten
    static let pagesMax = 150

    /// Zielzahl Karten fuer `pages` Seiten: etwa zwei je Seite, 8 bis 30 (ganzes Dokument meist 15–30)
    static func count(pages: Int) -> Int {
        min(maxCards, max(minCards, pages * 2))
    }

    /// Teile des Bereichs: Seiten `from`–`to` (vertauscht ist egal, ab 1) in Bloecke von hoechstens `pagesPerStep`
    static func steps(from: Int, to: Int) -> [ClosedRange<Int>] {
        let lo = max(1, min(from, to)), hi = max(1, max(from, to))
        var out: [ClosedRange<Int>] = []
        var start = lo
        while start <= hi {
            let end = min(hi, start + pagesPerStep - 1)
            out.append(start...end)
            start = end + 1
        }
        return out
    }

    /// Karten je Teil: `total` gleichmaessig verteilt (die ersten Teile bekommen den Rest), je Teil wenigstens 3
    static func counts(total: Int, steps: Int) -> [Int] {
        guard steps > 0 else { return [] }
        let base = max(3, total / steps), rest = max(0, total - base * steps)
        return (0..<steps).map { base + ($0 < rest ? 1 : 0) }
    }

    /// Bereich eines Laufs: "Ganzes Dokument" von 1 bis zur Seitenzahl (unbekannt: `pagesMax`, das Ende kommt aus den
    /// Antworten), "Seiten …" wie eingestellt; nil bei "Diese Seite" (kein Lauf, Modus flashcards zur Seite)
    static func range(scope: TutorDocScope, from: Int, to: Int, pageCount: Int?) -> ClosedRange<Int>? {
        switch scope {
        case .page: return nil
        case .document: return 1...max(1, pageCount ?? pagesMax)
        case .range: return max(1, min(from, to))...max(1, max(from, to))
        }
    }

    /// Antwort eines Teils brauchbar? Das Backend nimmt nur Seiten bis zum Ende des Dokuments und faellt ohne eine
    /// einzige gueltige Seite auf die ersten Seiten zurueck - solche Karten waeren doppelt. Also: die erste gelieferte
    /// Seite muss im angefragten Teil liegen.
    static func accepted(_ pages: [Int], requested: ClosedRange<Int>) -> Bool {
        guard let first = pages.first else { return false }
        return requested.contains(first)
    }

    /// Nach diesem Teil weitermachen? Nur, wenn der Teil bis zu seiner letzten Seite geliefert wurde (sonst war das
    /// Dokument schon zu Ende)
    static func continues(after pages: [Int], requested: ClosedRange<Int>) -> Bool {
        pages.last == requested.upperBound
    }

    /// Beschriftung des Knopfs im Reiter "Karteikarten" je Umfang
    static func chipLabel(scope: TutorDocScope, from: Int, to: Int) -> String {
        switch scope {
        case .page: return "Karteikarten zur Seite erstellen"
        case .document: return "Karteikarten zum ganzen Dokument erstellen"
        case .range: return "Karteikarten zu \(DocExplain.rangeWords(min(from, to), max(from, to))) erstellen"
        }
    }

    /// Was im Verlauf als Frage steht
    static func userLabel(scope: TutorDocScope, from: Int, to: Int) -> String {
        switch scope {
        case .page: return "Karteikarten · diese Seite"
        case .document: return "Karteikarten · ganzes Dokument"
        case .range: return "Karteikarten · \(DocExplain.rangeWords(min(from, to), max(from, to)))"
        }
    }

    /// Fortschritt waehrend des Laufs
    static func progress(step: Int, total: Int, pages: ClosedRange<Int>) -> String {
        "Karteikarten, Teil \(min(step + 1, total)) von \(total) · \(DocExplain.rangeWords(pages.lowerBound, pages.upperBound)) …"
    }

    /// Text der Antwort (fuer den Verlauf und `history`; die Karten stehen daneben)
    static func answerText(cards: Int, pages: [Int]) -> String {
        guard let lo = pages.min(), let hi = pages.max() else { return "\(cards) Karteikarten" }
        return "\(cards) Karteikarten zu \(DocExplain.rangeWords(lo, hi))"
    }

    /// Rumpf von POST /api/ai/flashcards fuer einen Teil
    static func body(fileID: String, pages: ClosedRange<Int>, count: Int) -> JSONValue {
        ["file_id": .string(fileID), "pages": .array(pages.map { .number(Double($0)) }), "count": .number(Double(count))]
    }

    /// Seiten aus der Antwort eines Teils (`pages`)
    static func pages(in response: JSONValue) -> [Int] {
        (response["pages"]?.array ?? []).compactMap { $0.int }
    }
}
