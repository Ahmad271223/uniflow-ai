import Foundation

/// Parameter des Dialogs "Wochentest erstellen" (04.11.2026) wie `ai.week_test_options` am PC: Zahl der Aufgaben
/// (5/10/15/20), Schwierigkeit (beliebig oder eine feste Stufe), Aufgabenarten (mindestens eine) und ein Thema oder
/// Hinweis. Nur die Standardeinstellung (`standard`: 15 Aufgaben, beliebig, alle Arten, kein Thema) ergibt einen
/// GEMEINSAMEN Test mit Varianten (`TestShare`); jede andere Einstellung ist ein eigener Test des Nutzers mit seiner
/// KI (Vorgabe des Inhabers: nichts gibt sich als geteilt aus, was es nicht ist). Pruefung, Fehlertexte und die
/// Verteilung der Schwierigkeiten sind byte-gleich mit Python (Vertrag packages/shared-contracts/ai/contract.json,
/// Abschnitt `week_test_options`).
public struct WeekTestOptions: Equatable, Sendable {
    public var count: Int
    public var difficulty: String
    /// in der Reihenfolge von `AIPromptTexts.weekTestTypes`, ohne Doppelte
    public var types: [String]
    public var topic: String

    public init(count: Int, difficulty: String, types: [String], topic: String) {
        self.count = count
        self.difficulty = difficulty
        self.types = types
        self.topic = topic
    }

    /// `ai.WEEK_TEST_STANDARD`: die einzige Einstellung, die geteilt wird
    public static let standard = WeekTestOptions(count: AIPromptTexts.weekTestTotal, difficulty: "beliebig", types: AIPromptTexts.weekTestTypes, topic: "")
    /// `ai.WEEK_TEST_COUNTS`, `ai.WEEK_TEST_LEVELS`, `ai.WEEK_TEST_TYPES`, `ai.WEEK_TEST_TOPIC_CHARS`
    public static var counts: [Int] { AIPromptTexts.weekTestCounts }
    public static var levels: [String] { AIPromptTexts.weekTestLevels }
    public static var allTypes: [String] { AIPromptTexts.weekTestTypes }
    public static var topicChars: Int { AIPromptTexts.weekTestTopicChars }
    /// `ai.TF_OPTIONS`: die beiden Antworten einer Wahr/Falsch-Aufgabe
    public static var tfOptions: [String] { AIPromptTexts.tfOptions }

    /// `ai.week_test_is_standard`: nur die Standardeinstellung wird ueber den Schluessel geteilt
    public var isStandard: Bool { self == Self.standard }

    /// `ai.week_test_options(body)`: fehlende Felder sind die Standardeinstellung; Unbrauchbares wirft
    /// `AIError("week_test_options", <Text wie der ValueError am PC>)`. `body` ist das Objekt der Anfrage (oder nil).
    public static func parse(_ body: PyJSON?) throws -> WeekTestOptions {
        func field(_ k: String) -> PyJSON? { AIPrompts.get(body, k) }
        func fail(_ m: String) -> AIError { AIError("week_test_options", m) }
        // count: int(str(x).strip()), bool scheitert; None und "" sind die Vorgabe
        var count = AIPromptTexts.weekTestTotal
        switch field("count") {
        case .none, .some(.null), .some(.string("")): break
        case .some(.bool): throw fail("count muss 5, 10, 15 oder 20 sein")
        case .some(let v):
            guard let n = PyConvert.int(PyText.str(v)) else { throw fail("count muss 5, 10, 15 oder 20 sein") }
            count = n
        }
        guard counts.contains(count) else { throw fail("count muss 5, 10, 15 oder 20 sein") }
        var difficulty = "beliebig"
        switch field("difficulty") {
        case .none, .some(.null), .some(.string("")): break
        case .some(.string(let d)) where levels.contains(d): difficulty = d
        default: throw fail("difficulty muss beliebig, leicht, mittel oder schwer sein")
        }
        var types = allTypes
        switch field("types") {
        case .none, .some(.null): break
        case .some(.array(let list)):
            var chosen: [String] = []
            for t in list {
                guard case .string(let s) = t, allTypes.contains(s) else { throw fail("types: unbekannte Aufgabenart \(repr(t))") }
                chosen.append(s)
            }
            types = allTypes.filter { chosen.contains($0) }
            if types.isEmpty { throw fail("types: mindestens eine Aufgabenart") }
        default: throw fail("types muss eine Liste sein")
        }
        var topic = ""
        switch field("topic") {
        case .none, .some(.null): break
        case .some(let v): topic = PyText.slice(PyText.strip(PyText.str(v)), 0, topicChars)
        }
        return WeekTestOptions(count: count, difficulty: difficulty, types: types, topic: topic)
    }

    /// `repr(x)` fuer die Fehlermeldung: Texte in einfachen Anfuehrungszeichen, Zahlen wie `str`
    private static func repr(_ v: PyJSON) -> String {
        if case .string(let s) = v {
            let q = s.contains("'") && !s.contains("\"") ? "\"" : "'"
            let body = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: q, with: "\\" + q)
            return q + body + q
        }
        return PyText.str(v)
    }

    /// Fuer die Anfrage an das Backend (`POST /api/tests/generate`): count, difficulty, types, topic
    public var json: [String: JSONValue] {
        ["count": .number(Double(count)), "difficulty": .string(difficulty), "types": .array(types.map { .string($0) }), "topic": .string(topic)]
    }

    /// `ai.week_test_distribution`: eine feste Stufe bekommt alle Aufgaben, "beliebig" verteilt 4/6/5 nach Hare-Niemeyer
    /// (groesster Rest, bei Gleichstand die Reihenfolge leicht, mittel, schwer): 5 -> 1/2/2, 10 -> 3/4/3, 20 -> 5/8/7
    public static func distribution(count: Int, difficulty: String) -> [(level: String, count: Int)] {
        let rule = AIPromptTexts.weekTestDifficulty, total = AIPromptTexts.weekTestTotal
        if difficulty != "beliebig" { return rule.map { ($0.level, $0.level == difficulty ? count : 0) } }
        var base = rule.map { ($0.level, count * $0.count / total) }
        let rest = count - base.reduce(0) { $0 + $1.1 }
        let order = rule.indices.sorted { a, b in
            let ra = count * rule[a].count % total, rb = count * rule[b].count % total
            return ra != rb ? ra > rb : a < b
        }
        for i in order.prefix(max(0, rest)) { base[i].1 += 1 }
        return base
    }

    public var distribution: [(level: String, count: Int)] { Self.distribution(count: count, difficulty: difficulty) }

    /// Verteilung als Woerterbuch (fuer Pruefungen)
    public var distributionByLevel: [String: Int] { Dictionary(uniqueKeysWithValues: distribution.map { ($0.level, $0.count) }) }
}
