import Foundation

/// Fehler einer KI-Anfrage mit stabilem Code (wie `AIUnavailable`/`AIError` am PC) und Text fuer den Nutzer.
public struct AIError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Antworten der KI auswerten wie app/ai.py (Vertrag packages/shared-contracts/ai/contract.json).
public enum AIAnswers {
    private static let fences = PyRegex(#"^```(?:json)?\s*|\s*```$"#)
    private static let firstJSON = PyRegex(#"(?s)(\{.*\}|\[.*\])"#)

    /// `ai.parse_json`: Markdown-Zaeune weg, sonst vom ersten `{`/`[` bis zum letzten `}`/`]` (gierig wie Python).
    public static func parseJSON(_ text: String) throws -> PyJSON {
        let t = fences.sub(PyText.strip(text))
        if let v = try? PyJSON.parse(t) { return v }
        guard let m = firstJSON.search(t), let found = m.group(1) else {
            throw AIError("ai_invalid_json", "KI-Antwort enthaelt kein JSON:\n\(PyText.slice(t, 0, 500))")
        }
        do {
            return try PyJSON.parse(found)
        } catch {
            throw AIError("ai_invalid_json", "KI-Antwort ist kein gueltiges JSON: \(error)\n\(PyText.slice(t, 0, 500))")
        }
    }

    /// Eine vorgeschlagene Karteikarte (Frage vorn, Antwort hinten), beide ohne Leerraum aussen
    public struct Flashcard: Equatable, Sendable {
        public let question: String
        public let answer: String
        public init(question: String, answer: String) { self.question = question; self.answer = answer }
        public var json: JSONValue { ["question": .string(question), "answer": .string(answer)] }
    }

    /// `ai.check_flashcards`: Karten aus {"cards": [...]} oder einer Liste (Tutor-Modus flashcards); nur Karten mit
    /// Frage und Antwort (`str()` wie in Python, aussen ohne Leerraum), hoechstens `flashcardsMax`; leer ohne Karten.
    /// Faellt weg (13.11.2026): Frage/Antwort zu lang (`flashcardsQuestionChars`/`flashcardsAnswerChars`), Frage gleich
    /// Antwort, Frage verraet die Antwort, Frage gleich oder fast gleich einer frueheren Karte. `pages`: Seiten des
    /// Inhalts; nennt die Karte eine davon (`page`), endet die Antwort mit " (S. N)". `quality: false` (nur fuer schon
    /// gespeicherte Stapel, `CardStackShare`): ohne diese Pruefungen wie vor dem 13.11.2026, damit aeltere Stapel ganz bleiben.
    public static func checkFlashcards(_ res: PyJSON, pages: [Int] = [], quality: Bool = true) -> [Flashcard] {
        let items: PyJSON? = { if case .object = res { return AIPrompts.get(res, "cards") }; return res }()
        guard case .array(let list)? = items else { return [] }
        let allowed = Set(pages)
        var out: [Flashcard] = []
        var seenNorm = Set<String>()
        var seenWords: [Set<String>] = []
        for c in list {
            guard case .object = c else { continue }
            let q = PyText.strip(AIPrompts.str(AIPrompts.or(AIPrompts.get(c, "question"), .string(""))))
            var a = PyText.strip(AIPrompts.str(AIPrompts.or(AIPrompts.get(c, "answer"), .string(""))))
            guard !q.isEmpty, !a.isEmpty else { continue }
            if !quality {
                out.append(Flashcard(question: q, answer: a))
                if out.count == AIPrompts.flashcardsMax { break }
                continue
            }
            guard q.unicodeScalars.count <= AIPromptTexts.flashcardsQuestionChars,
                  a.unicodeScalars.count <= AIPromptTexts.flashcardsAnswerChars else { continue }
            let n = flashcardNorm(q), w = flashcardWords(q)
            if n.isEmpty || n == flashcardNorm(a) || seenNorm.contains(n) || flashcardGivesAway(q, a)
                || seenWords.contains(where: { flashcardSimilar(w, $0) }) { continue }
            seenNorm.insert(n)
            seenWords.append(w)
            if case .int(let digits)? = AIPrompts.get(c, "page"), let page = Int(digits), allowed.contains(page) {
                a += " (S. \(page))"
            }
            out.append(Flashcard(question: q, answer: a))
            if out.count == AIPrompts.flashcardsMax { break }
        }
        return out
    }

    /// Wortzeichen wie `\w` in Pythons `re` (str): Buchstaben (Lu, Ll, Lt, Lm, Lo), Zahlzeichen jeder Art und "_"
    private static func isWord(_ u: Unicode.Scalar) -> Bool {
        if u == "_" || u.properties.numericType != nil { return true }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `ai.flashcard_norm`: klein, nur Wortzeichen, durch je ein Leerzeichen getrennt
    public static func flashcardNorm(_ text: String) -> String {
        var words: [String] = [], cur = String.UnicodeScalarView()
        for u in text.lowercased().unicodeScalars {
            if isWord(u) { cur.append(u) } else if !cur.isEmpty { words.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { words.append(String(cur)) }
        return words.joined(separator: " ")
    }

    /// `ai.flashcard_words`: alle Woerter (auch Zahlen und Kurzes), damit sich Fragen, die sich nur in einer Zahl
    /// unterscheiden, nicht gleichen
    static func flashcardWords(_ text: String) -> Set<String> {
        Set(flashcardNorm(text).split(separator: " ").map(String.init))
    }

    /// `ai.flashcard_similar`: beide mit mindestens drei Woertern und Jaccard >= `flashcardsSimilar`
    static func flashcardSimilar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.count >= 3 && b.count >= 3
            && Double(a.intersection(b).count) / Double(a.union(b).count) >= AIPromptTexts.flashcardsSimilar
    }

    /// `ai.flashcard_gives_away`: die ganze Antwort (mindestens 4 Zeichen, hoechstens 6 Woerter) steht woertlich in der Frage
    static func flashcardGivesAway(_ question: String, _ answer: String) -> Bool {
        let a = flashcardNorm(answer)
        return a.unicodeScalars.count >= 4 && a.split(separator: " ").count <= 6
            && " \(flashcardNorm(question)) ".contains(" \(a) ")
    }

    /// `ai.check_week_test`: nil = der Test hat die Form vom 29.10.2026 (15 Aufgaben, 4 leicht, 6 mittel, 5 schwer,
    /// mit Altklausur genau eine schwere im Stil der Klausur) bzw. die der gewaehlten Parameter (04.11.2026: Zahl,
    /// Verteilung, nur gewaehlte Aufgabenarten, Wahr/Falsch mit genau den Optionen Wahr und Falsch, Lueckentext mit
    /// `blank`, Erklaerung je Aufgabe), sonst der Grund
    public static func checkWeekTest(_ res: PyJSON, exam: Bool = false, options: WeekTestOptions = .standard) -> String? {
        guard case .object = res else { return "keine JSON-Objekt-Antwort" }
        let total = options.count
        guard case .array(let qs)? = AIPrompts.get(res, "questions"), qs.count == total else {
            if case .array(let qs)? = AIPrompts.get(res, "questions") { return "\(qs.count) statt \(total) Aufgaben" }
            return "0 statt \(total) Aufgaben"
        }
        var counts = Dictionary(uniqueKeysWithValues: AIPromptTexts.weekTestDifficulty.map { ($0.level, 0) })
        func text(_ q: PyJSON, _ key: String) -> String { PyText.strip(AIPrompts.str(AIPrompts.or(AIPrompts.get(q, key), .string("")))) }
        for (i, q) in qs.enumerated() {
            let n = i + 1
            guard case .object = q else { return "Aufgabe \(n) ist kein Objekt" }
            guard case .string(let d)? = AIPrompts.get(q, "difficulty"), let c = counts[d] else {
                return "Aufgabe \(n) ohne gueltige Schwierigkeit"
            }
            counts[d] = c + 1
            guard case .string(let type)? = AIPrompts.get(q, "type"), AIPromptTexts.weekTestTypes.contains(type) else {
                return "Aufgabe \(n) mit unbekanntem Typ"
            }
            if !options.types.contains(type) { return "Aufgabe \(n) mit nicht gewaehlter Aufgabenart" }
            if text(q, "question").isEmpty || text(q, "answer").isEmpty {
                return "Aufgabe \(n) ohne Text oder Musterloesung"
            }
            if type == "mc" {
                guard case .array(let options)? = AIPrompts.get(q, "options"), options.count >= 2 else {
                    return "Aufgabe \(n) (Multiple-Choice) ohne Antwortmoeglichkeiten"
                }
            }
            if type == "tf" {
                guard case .array(let opts)? = AIPrompts.get(q, "options"), opts.map({ PyText.strip(AIPrompts.str($0)) }) == WeekTestOptions.tfOptions else {
                    return "Aufgabe \(n) (Wahr/Falsch) ohne die Optionen Wahr und Falsch"
                }
                if !WeekTestOptions.tfOptions.contains(text(q, "answer")) { return "Aufgabe \(n) (Wahr/Falsch) mit Loesung ausserhalb von Wahr und Falsch" }
            }
            if type == "cloze", text(q, "blank").isEmpty { return "Aufgabe \(n) (Lueckentext) ohne Luecke" }
            if text(q, "explanation").isEmpty { return "Aufgabe \(n) ohne Erklaerung" }
            switch AIPrompts.get(q, "points") {
            case .some(.int(let digits)) where (Int(digits) ?? (digits.hasPrefix("-") ? -1 : 1)) > 0: break
            case .some(.float(let p)) where !(p <= 0): break             // NaN zaehlt wie in Python als gueltig
            default: return "Aufgabe \(n) ohne Punkte"
            }
        }
        let wanted = options.distributionByLevel
        if counts != wanted {
            func line(_ m: [String: Int]) -> String { AIPromptTexts.weekTestDifficulty.map { "\(m[$0.level] ?? 0) \($0.level)" }.joined(separator: ", ") }
            return "Verteilung " + line(counts) + " statt " + line(wanted)
        }
        let styled = qs.filter { if case .bool(true)? = AIPrompts.get($0, "exam_style") { return true }; return false }
        let exam = exam && (wanted["schwer"] ?? 0) > 0
        if exam {
            if styled.count != 1 { return "nicht genau eine schwere Aufgabe im Stil der Altklausur" }
            guard case .string("schwer")? = AIPrompts.get(styled[0], "difficulty") else {
                return "nicht genau eine schwere Aufgabe im Stil der Altklausur"
            }
        } else if !styled.isEmpty {
            return "Aufgabe im Stil einer Altklausur ohne Altklausur"
        }
        return nil
    }
}
