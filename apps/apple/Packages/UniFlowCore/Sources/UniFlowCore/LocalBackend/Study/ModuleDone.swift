import Foundation

/// Haken "erledigt" je Datei im Moduldetail (Auftrag des Inhabers 13.11.2026). Derselbe Stand wie bei den Lernpaketen:
/// `files.status = 'erledigt'` (das setzt auch `StudyPlan.setTaskStatus`, und der Lernplan plant erledigte Dateien nicht
/// mehr ein). Abhaken schliesst offene Lernaufgaben zu derselben Datei ("Heute für dich geplant" durchgestrichen),
/// Haken entfernen oeffnet erledigte Aufgaben wieder. Gleiche Regel am PC-Server (`study.set_files_done`).
enum ModuleDone {
    /// Aufgaben, die mit dem Haken erledigt werden (nicht uebersprungene oder verschobene)
    static let openTasks = ["geplant", "in_bearbeitung", "nachholen"]

    /// Setzt den Haken fuer `fileIDs` (nur Dateien, die es gibt). Ergebnis: geaenderte Dateien, geaenderte Aufgaben.
    static func set(_ c: SQLiteConnection, fileIDs: [String], done: Bool, clock: UniFlowClock) throws -> (files: [String], tasks: Int) {
        var ids: [String] = []
        for id in fileIDs where !ids.contains(id) {
            guard let f = try c.queryOne("SELECT status FROM files WHERE id=?", [.text(id)]) else { continue }
            let isDone = f["status"]?.string == "erledigt"
            if isDone != done { ids.append(id) }
            if done {
                try c.execute("UPDATE files SET status='erledigt', seen_by_user=1 WHERE id=?", [.text(id)])
            } else if isDone {
                // vorher gesehen (erledigt setzt seen_by_user): zurueck auf "gelesen", nicht auf "neu"
                try c.execute("UPDATE files SET status='gelesen', seen_by_user=1 WHERE id=?", [.text(id)])
            }
        }
        var tasks = 0
        let all = Array(Set(fileIDs))
        if !all.isEmpty {
            let marks = all.map { _ in "?" }.joined(separator: ",")
            let from = done ? openTasks : ["erledigt"]
            let st = from.map { _ in "?" }.joined(separator: ",")
            let rows = try c.query("SELECT id FROM study_tasks WHERE file_id IN (\(marks)) AND status IN (\(st)) ORDER BY id",
                                   all.map { .text($0) } + from.map { .text($0) })
            for r in rows {
                let note: SQLiteValue = done ? "Im Modul abgehakt" : "Haken im Modul entfernt"
                if try StudyPlan.setTaskStatus(c, taskID: r["id"] ?? .null, status: done ? "erledigt" : "geplant", note: note, clock: clock) != nil {
                    tasks += 1
                }
            }
        }
        return (ids, tasks)
    }
}
