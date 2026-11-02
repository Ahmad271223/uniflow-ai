import Foundation

/// Kontext aus Stud.IP fuer die KI wie app/course_context.py (Entscheidung des Inhabers 02.11.2026): Kursbeschreibung,
/// Sonstiges und die Sitzungsthemen (`studip_events.description`) eines Moduls in einem Zeitraum. Nur was zum Modul
/// und zur Woche passt; gekuerzt in `AIPrompts.studipContext`. Synchron, fuer eine offene Verbindung.
enum CourseContext {
    /// `_courses(conn, course_id, module_id)`: Kurse des Moduls (aktiv), der eigene Kurs zuerst; ohne Modul nur der Kurs
    static func courses(_ c: SQLiteConnection, courseID: String?, moduleID: JSONValue?) throws -> [String] {
        var ids = courseID.map { [$0] } ?? []
        if let moduleID, moduleID != .null, let bound = SQLiteValue(json: moduleID) {
            for r in try c.rows("SELECT id FROM courses WHERE module_id=? AND active=1 ORDER BY id", [bound]) {
                if let id = r["id"]?.string, id != courseID { ids.append(id) }
            }
        }
        return ids
    }

    /// `build(conn, course_ids, start, end)`: Kontextblock fuer die Kurse im Zeitraum (Tage seit 1970, beide
    /// einschliesslich); leer ohne Beschreibung und Sitzungsthema
    static func build(_ c: SQLiteConnection, courseIDs: [String], from start: Int, to end: Int) throws -> String {
        guard !courseIDs.isEmpty else { return "" }
        let marks = Array(repeating: "?", count: courseIDs.count).joined(separator: ",")
        let ids = courseIDs.map { SQLiteValue.text($0) }
        var rows: [String: [String: JSONValue]] = [:]
        for r in try c.rows("SELECT id, description, miscellaneous FROM courses WHERE id IN (\(marks))", ids) {
            if let id = r["id"]?.string { rows[id] = r }
        }
        func first(_ key: String) -> String {
            for id in courseIDs {
                if let t = rows[id]?[key]?.string, !PyText.strip(t).isEmpty { return t }
            }
            return ""
        }
        var sessions: [(date: String, topic: String)] = []
        var seen = Set<String>()
        for r in try c.rows("""
            SELECT start, description FROM studip_events WHERE course_id IN (\(marks)) AND COALESCE(cancelled, 0)=0
            AND start >= ? AND start < ? AND COALESCE(description, '') <> '' ORDER BY start, id
            """, ids + [.text(BerlinClock.isoDate(start)), .text(BerlinClock.isoDate(end + 1))]) {
            let t = PyText.strip(r["description"]?.string ?? "")
            guard !t.isEmpty, seen.insert(t).inserted else { continue }
            sessions.append((PyText.slice(r["start"]?.string ?? "", 0, 10), t))
        }
        return AIPrompts.studipContext(courseDescription: first("description"), miscellaneous: first("miscellaneous"), sessions: sessions)
    }

    /// `for_file(conn, file_id, today)`: Tutor, Kurs der Datei und die anderen Kurse ihres Moduls, Sitzungsthemen der
    /// laufenden Woche (Montag bis Sonntag)
    static func forFile(_ c: SQLiteConnection, fileID: String?, today: Int) throws -> String {
        guard let fileID, let r = try c.rows("""
            SELECT c.id, c.module_id FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=? AND c.id <> '__user__'
            """, [.text(fileID)]).first, let course = r["id"]?.string else { return "" }
        let monday = today - BerlinClock.weekday(today)
        return try build(c, courseIDs: try courses(c, courseID: course, moduleID: r["module_id"]), from: monday, to: monday + 6)
    }

    /// `for_module_week(conn, module_id, lecture_end)`: Wochentest, Kurse des Moduls, Sitzungsthemen der sieben Tage bis
    /// zum Ende der Lehrwoche
    static func forModuleWeek(_ c: SQLiteConnection, moduleID: JSONValue?, lectureEnd: String?) throws -> String {
        guard let end = BerlinClock.parseISODate(PyText.slice(lectureEnd ?? "", 0, 10)) else { return "" }
        return try build(c, courseIDs: try courses(c, courseID: nil, moduleID: moduleID), from: end - 6, to: end)
    }
}
