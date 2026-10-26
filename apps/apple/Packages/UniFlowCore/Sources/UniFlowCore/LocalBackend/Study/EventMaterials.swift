import Foundation

/// Unterlagen zu einem Termin des Stundenplans wie app/timetable.py `materials_for_event`: Dateien des Moduls aus
/// derselben Semesterwoche, sonst die neuesten. Gehoert zum Stundenplan (S5, `LocalTimetable.materials`), braucht
/// aber nur die Dateien eines Moduls mit Einordnung (`fileRows`) und die Semesterwochen (`StudyWeeks`), darum hier.
/// Die Woche des Termins folgt derselben Regel wie die der Dateien (`StudyWeeks.dayWeek`): vor dem Vorlesungsbeginn
/// Woche 0, vor dem Stichtag -1 (Korrektur vom 25.10.2026, zuerst in Python, tests/test_study_weeks.py).
extension LocalModules {
    /// Arten fuer den Rueckfall auf die neuesten Unterlagen
    static let latestMaterialTypes: Set<String> = ["vorlesung", "uebung"]

    /// `materials_for_event(conn, event, d)`: `event` ist eine Zeile aus `course_events`, `day` der Tag des Termins
    /// (`BerlinClock`-Tag). Ohne Modul keine Unterlagen; sonst die Vorlesungen, Uebungen, Skripte und Loesungen der
    /// Semesterwoche des Termins, ohne solche die letzten vier Vorlesungen/Uebungen des Moduls, hoechstens 8.
    public static func eventMaterials(_ c: SQLiteConnection, event: [String: JSONValue], day: Int, clock: UniFlowClock) throws -> [JSONValue] {
        guard truthy(event["module_id"]) else { return [] }
        guard let moduleID = SQLiteValue(json: event["module_id"] ?? .null) else {
            throw LocalHTTPError(status: 500, message: "module_id des Termins ist kein einfacher Wert")   // sqlite3: nicht bindbar
        }
        let dates = try Dates(c, clock: clock)
        let files = try fileRows(c, moduleID: moduleID)
        let w = StudyWeeks.dayWeek(start: dates.start, day: day, today: dates.today)
        // Lehrwoche der Datei zuerst wie in Python (`file_week(...) == w and doc_type in ...`): ein ungueltiges Datum
        // scheitert ausser bei Klausuren immer; die Datei steht in ihrer Lehrwoche wie im Moduldetail ("Blatt 3" in Woche 3)
        var same = try files.filter {
            try week($0, dates: dates) == w && StudyClassify.lectureWeekTypes.contains($0.docType ?? "")
        }
        if same.isEmpty {
            same = Array(files.filter { latestMaterialTypes.contains($0.docType ?? "") }.suffix(4))
        }
        return same.prefix(8).map { .object($0.json) }
    }
}
