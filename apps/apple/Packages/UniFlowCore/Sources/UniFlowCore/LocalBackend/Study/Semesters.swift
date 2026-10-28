import Foundation

/// Nur aktuelle Kurse werden eingeplant, wie app/semesters.py (PC-Stand c0721da/81eecf0, 28.10.2026).
///
/// Befund am PC mit echten Daten: Stud.IP liefert alle Veranstaltungen, die der Nutzer je belegt hat (208 Kurse von
/// WiSe 2022/23 bis WiSe 2026/27); alle galten als aktiv, mit Modulen, Dateien, Terminen und Lernplaenen alter
/// Semester. Regel: ein Kurs ist aktuell, wenn sein Ende (Stud.IP `end-semester`, Ende des Semesters als Datum) heute
/// oder spaeter liegt oder er unbegrenzt laeuft; ohne Datum entscheidet der Semestertitel ("WiSe 2026/27", "SoSe 2026",
/// "WS 26/27", "Wintersemester 2026/2027") gegen das heutige Semester (April bis September SoSe, sonst WiSe). Kurse ohne
/// erkennbares Semester bleiben, wie sie sind. Eigene Entscheidungen (`courses.active_custom`, `modules.active_custom`)
/// ueberschreibt der Abgleich nicht. Module ohne aktiven Kurs gehen aus, ihre Unterlagen bleiben.
/// Vertrag: packages/shared-contracts/fixtures/studip-schedule/woche.json (`StudIPWeekTests`).
public enum Semesters {
    /// Halbjahr eines Semesters: 1 = Sommer, 2 = Winter (Reihenfolge wie das Tupel in Python)
    public struct Key: Comparable, Equatable, Sendable {
        public let year: Int
        public let half: Int
        public static func < (a: Key, b: Key) -> Bool { (a.year, a.half) < (b.year, b.half) }
        var json: JSONValue { [.number(Double(year)), .number(Double(half))] }
    }

    private static let pattern = HText.regex("\\b(WiSe|SoSe|WS|SS|Wintersemester|Sommersemester)\\s*'?(\\d{2,4})", [.caseInsensitive])

    /// `key(title)`: "WiSe 2026/27" -> (2026, 2), "SoSe 2026" -> (2026, 1), "WS 26/27" -> (2026, 2); nil ohne Semester.
    /// Zweistellige Jahre zaehlen ab 2000; Winter, wenn das Wort mit "wi" oder "ws" beginnt.
    public static func key(_ title: String?) -> Key? {
        guard let title, let g = HText.match(pattern, title)?.groups, let word = g[1], let digits = g[2] else { return nil }
        // int() wie Python: jede Dezimalziffer (\d ist auch dort nicht nur ASCII)
        var y = 0
        for u in digits.unicodeScalars {
            guard let v = u.properties.numericValue, u.properties.numericType == .decimal else { return nil }
            y = y * 10 + Int(v)
        }
        if y < 100 { y += 2000 }
        let lower = PyText.lower(word)
        return Key(year: y, half: lower.hasPrefix("wi") || lower.hasPrefix("ws") ? 2 : 1)
    }

    /// `current(today)`: April bis September das Sommersemester des Jahres, Oktober bis Dezember das Wintersemester
    /// des Jahres, Januar bis Maerz das des Vorjahres
    public static func current(_ today: String) -> Key {
        let (y, m) = yearMonth(today)
        if (4...9).contains(m) { return Key(year: y, half: 1) }
        return Key(year: m >= 10 ? y : y - 1, half: 2)
    }

    /// `label(k)`: "SoSe 2027" bzw. "WiSe 2026/27"
    public static func label(_ k: Key) -> String {
        k.half == 1 ? "SoSe \(k.year)" : "WiSe \(k.year)/\(String(String(k.year + 1).suffix(2)))"
    }

    /// `is_current(semester, semester_end, ends_at, today)`: true/false, nil, wenn sich das nicht entscheiden laesst
    /// (kein Datum, kein Semester im Titel). Reihenfolge: unbegrenzt, Ende als Datum (`ends_at[:10] >= heute`, Text),
    /// sonst Semester aus `semester_end`, sonst aus `semester` gegen das heutige.
    public static func isCurrent(semester: String?, semesterEnd: String? = nil, endsAt: String? = nil, today: String) -> Bool? {
        if semesterEnd == "unbegrenzt" { return true }
        if let endsAt, !endsAt.isEmpty {
            return !PyText.slice(endsAt, 0, 10).unicodeScalars.lexicographicallyPrecedes(today.unicodeScalars)
        }
        guard let k = key(semesterEnd) ?? key(semester) else { return nil }
        return k >= current(today)
    }

    /// `apply_to_course`: `courses.active` nach der Regel, ausser der Nutzer hat selbst entschieden (`active_custom`)
    @discardableResult
    static func applyToCourse(_ c: SQLiteConnection, courseID: String, semester: String?, semesterEnd: String?, endsAt: String?,
                              today: String) throws -> Bool? {
        let cur = isCurrent(semester: semester, semesterEnd: semesterEnd, endsAt: endsAt, today: today)
        if let cur {
            try c.execute("UPDATE courses SET active=? WHERE id=? AND COALESCE(active_custom, 0)=0", [.integer(cur ? 1 : 0), .text(courseID)])
        }
        return cur
    }

    /// `deactivate_stale_modules`: Module, deren Kurse alle aus sind, ausschalten; Module ohne Kurse (selbst angelegt)
    /// und von Hand geschaltete Module (`active_custom`) bleiben. Liefert die Zahl der ausgeschalteten Module.
    @discardableResult
    static func deactivateStaleModules(_ c: SQLiteConnection) throws -> Int {
        let rows = try c.rows("""
            SELECT id FROM modules WHERE COALESCE(active, 1)=1 AND COALESCE(active_custom, 0)=0
            AND EXISTS (SELECT 1 FROM courses c WHERE c.module_id=modules.id)
            AND NOT EXISTS (SELECT 1 FROM courses c WHERE c.module_id=modules.id AND c.active=1)
            """)
        for r in rows { try c.execute("UPDATE modules SET active=0 WHERE id=?", [try LocalTimetable.bind(r["id"], "id")]) }
        return rows.count
    }

    /// `migrate`: einmalig je Datenbank alle Kurse (ausser `__user__`) nach der Regel schalten, Module ohne aktiven
    /// Kurs aus, dann der Merker `semester_rule_applied = "1"` (spaetere Entscheidungen des Nutzers bleiben)
    static func migrate(_ c: SQLiteConnection, today: String) throws {
        if try c.queryOne("SELECT value FROM settings WHERE key='semester_rule_applied'")?[0].string == "1" { return }
        for r in try c.rows("SELECT id, semester, semester_end, semester_ends_at FROM courses WHERE id != '__user__'") {
            guard let id = r["id"]?.string else { continue }
            try applyToCourse(c, courseID: id, semester: r["semester"]?.string, semesterEnd: r["semester_end"]?.string,
                              endsAt: r["semester_ends_at"]?.string, today: today)
        }
        try deactivateStaleModules(c)
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('semester_rule_applied', '1')")
    }

    /// Jahr und Monat eines ISO-Datums ("2026-10-28")
    private static func yearMonth(_ iso: String) -> (Int, Int) {
        guard let d = BerlinClock.parseISODate(PyText.slice(iso, 0, 10)) else { return (0, 0) }
        let s = BerlinClock.isoDate(d)
        return (Int(PyText.slice(s, 0, 4)) ?? 0, Int(PyText.slice(s, 5, 7)) ?? 0)
    }
}
