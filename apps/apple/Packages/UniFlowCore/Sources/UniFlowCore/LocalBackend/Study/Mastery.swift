import Foundation

/// Lernstand je Modul (docs/LERNSTAND-2026-11-04.md), Port von app/mastery.py: eine Zahl 0-100 aus Wochentests,
/// Karteikarten und Aufgaben des Lernplans. Keine KI, keine neue Tabelle. `compute` ist eine reine Funktion mit
/// denselben Faellen wie Python (packages/shared-contracts/fixtures/mastery/cases.json); die Reihenfolge der
/// Gleitkomma-Operationen ist bewusst dieselbe wie dort, damit beide Seiten dieselbe Zahl runden.
public enum Mastery {
    public static let weightTests = 0.5, weightCards = 0.3, weightTasks = 0.2

    /// "3 Wochentests, 42 Karten, 12 von 20 Aufgaben" - nur die vorhandenen Signale
    public static func reason(tests: Int, cards: Int, tasksDone: Int, tasksTotal: Int) -> String {
        var parts: [String] = []
        if tests > 0 { parts.append("\(tests) Wochentest\(tests == 1 ? "" : "s")") }
        if cards > 0 { parts.append("\(cards) Karte\(cards == 1 ? "" : "n")") }
        if tasksTotal > 0 { parts.append("\(tasksDone) von \(tasksTotal) Aufgabe\(tasksTotal == 1 ? "" : "n")") }
        return parts.joined(separator: ", ")
    }

    /// `tests`: Paare (Punkte, Hoechstpunkte) der abgegebenen Wochentests, aelteste zuerst. Ohne Signal `.null`.
    public static func compute(tests: [(score: Double, max: Double)], cardsRight: Int, cardsWrong: Int,
                               tasksDone: Int, tasksTotal: Int) -> JSONValue {
        var pcts: [Double] = []
        for t in tests {
            // kein Hoechstwert oder NaN: zaehlt nicht
            if t.max <= 0 || t.score.isNaN || t.max.isNaN { continue }
            pcts.append(min(100.0, max(0.0, 100.0 * t.score / t.max)))
        }
        let cards = cardsRight + cardsWrong
        var num = 0.0, den = 0.0
        if !pcts.isEmpty {
            var wsum = 0.0, psum = 0.0
            for (i, p) in pcts.enumerated() {                     // der aelteste wiegt 1, der neueste n
                let w = Double(i + 1)
                wsum += w
                psum += w * p
            }
            num += weightTests * (psum / wsum)
            den += weightTests
        }
        if cards > 0 {
            num += weightCards * (100.0 * Double(cardsRight) / Double(cards))
            den += weightCards
        }
        if tasksTotal > 0 {
            num += weightTasks * (100.0 * Double(tasksDone) / Double(tasksTotal))
            den += weightTasks
        }
        if den == 0.0 { return .null }
        let score = max(0, min(100, Int((num / den + 0.5).rounded(.down))))   // halbe Prozent aufwaerts wie math.floor(x + 0.5)
        return .object(["score": .number(Double(score)),
                        "reason": .string(reason(tests: pcts.count, cards: cards, tasksDone: tasksDone, tasksTotal: tasksTotal)),
                        "tests": .number(Double(pcts.count)), "cards": .number(Double(cards)),
                        "tasks_done": .number(Double(tasksDone)), "tasks_total": .number(Double(tasksTotal))])
    }

    /// `mastery.for_module`: Zahlen eines Moduls aus `tests`, `flashcards` und `study_tasks` (nur lesen); Zuordnung
    /// ueber module_id, sonst ueber das Fach (`subject` = Modulname, so setzen es die Module-Endpunkte)
    static func forModule(_ c: SQLiteConnection, moduleID: SQLiteValue, name: SQLiteValue) throws -> JSONValue {
        let tests = try c.query("""
            SELECT score, max_score FROM tests
            WHERE (module_id=? OR (module_id IS NULL AND subject=?)) AND submitted_at IS NOT NULL AND score IS NOT NULL
              AND COALESCE(max_score, 0) > 0 AND COALESCE(user_id, 'local')='local'
            ORDER BY submitted_at, id
            """, [moduleID, name]).compactMap { row -> (score: Double, max: Double)? in
                // Text oder Leeres in score/max_score (nur Daten von aussen): wie float() in Python scheitert -> ausgelassen
                guard let s = row["score"]?.double, let m = row["max_score"]?.double else { return nil }
                return (s, m)
            }
        let cards = try c.queryOne("""
            SELECT COALESCE(SUM(fc.last_result='right'), 0) AS r, COALESCE(SUM(fc.last_result='wrong'), 0) AS w
            FROM flashcards fc LEFT JOIN files f ON f.id=fc.file_id LEFT JOIN courses c ON c.id=f.course_id
            WHERE COALESCE(fc.hidden, 0)=0 AND (c.module_id=? OR (c.module_id IS NULL AND fc.subject=?))
            """, [moduleID, name])
        let tasks = try c.queryOne("""
            SELECT COUNT(*) AS n, COALESCE(SUM(st.status='erledigt'), 0) AS d
            FROM study_tasks st JOIN study_packages p ON p.id=st.package_id WHERE p.module_id=?
            """, [moduleID])
        return compute(tests: tests, cardsRight: cards?["r"]?.int ?? 0, cardsWrong: cards?["w"]?.int ?? 0,
                       tasksDone: tasks?["d"]?.int ?? 0, tasksTotal: tasks?["n"]?.int ?? 0)
    }
}
