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
    /// Frage und Antwort (`str()` wie in Python, aussen ohne Leerraum), hoechstens `flashcardsMax`; leer ohne Karten
    public static func checkFlashcards(_ res: PyJSON) -> [Flashcard] {
        let items: PyJSON? = { if case .object = res { return AIPrompts.get(res, "cards") }; return res }()
        guard case .array(let list)? = items else { return [] }
        var out: [Flashcard] = []
        for c in list {
            guard case .object = c else { continue }
            let q = PyText.strip(AIPrompts.str(AIPrompts.or(AIPrompts.get(c, "question"), .string(""))))
            let a = PyText.strip(AIPrompts.str(AIPrompts.or(AIPrompts.get(c, "answer"), .string(""))))
            if !q.isEmpty, !a.isEmpty { out.append(Flashcard(question: q, answer: a)) }
        }
        return Array(out.prefix(AIPrompts.flashcardsMax))
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
