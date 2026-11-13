import Foundation

/// Haken "erledigt" je Datei im Moduldetail (Auftrag des Inhabers 13.11.2026). Ein Stand fuer alles:
/// `files.status = 'erledigt'` (das setzt auch `StudyPlan.setTaskStatus`, der Lernplan plant erledigte Dateien nicht
/// mehr ein, Lernfortschritt und Lernziele zaehlen ihn). Fuer den Geraete-Abgleich spiegeln Trigger im Schema
/// (`app/db.py`, `trg_file_done_*`) ihn in die Einstellung `file_done:<ID>` = "1"/"0"; der Abgleich der Einstellungen
/// bringt ihn auf die anderen Geraete, der neuere Stand gewinnt.
///
/// Lernaufgaben zur selben Datei (ausser Tests): Abhaken schliesst die offenen ("Heute für dich geplant"
/// durchgestrichen), Haken entfernen oeffnet die erledigten wieder, ausser bei Faechern, die der Lernkalender nicht
/// plant (`plan_modules_off`: Haken ja, Planung nein). Ein auf einem anderen Geraet gesetzter Haken schliesst nach dem
/// Abgleich die offenen Aufgaben hier (`closeTasksOfDoneFiles`). Gleiche Regeln am PC (`study.set_files_done`).
enum ModuleDone {
    /// Einstellung je Datei fuer den Geraete-Abgleich
    static let markPrefix = "file_done:"
    /// Aufgaben, die mit dem Haken erledigt werden (nicht uebersprungene oder verschobene)
    static let openTasks = ["geplant", "in_bearbeitung", "nachholen"]
    /// Aufgabenarten, die der Haken nicht beruehrt (Wochentests haben ein eigenes Ergebnis)
    static let ownResult = ["test"]

    /// Setzt den Haken fuer `fileIDs` (nur Dateien, die es gibt). `reopen`: erledigte Aufgaben beim Entfernen wieder
    /// oeffnen (false fuer Faecher, die der Lernkalender nicht plant). Ergebnis: geaenderte Dateien, geaenderte Aufgaben.
    static func set(_ c: SQLiteConnection, fileIDs: [String], done: Bool, reopen: Bool = true,
                    clock: UniFlowClock) throws -> (files: [String], tasks: Int) {
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
        let all = Array(Set(fileIDs)).sorted()
        guard !all.isEmpty, done || reopen else { return (ids, 0) }
        let note: SQLiteValue = done ? "Im Modul abgehakt" : "Haken im Modul entfernt"
        let n = try changeTasks(c, fileIDs: all, from: done ? openTasks : ["erledigt"], to: done ? "erledigt" : "geplant",
                                note: note, clock: clock)
        return (ids, n)
    }

    /// Nach dem Geraete-Abgleich: offene Aufgaben zu Dateien, die (auf einem anderen Geraet) erledigt wurden,
    /// ebenfalls erledigen. Ergebnis: Anzahl Aufgaben.
    @discardableResult
    static func closeTasksOfDoneFiles(_ c: SQLiteConnection, clock: UniFlowClock) throws -> Int {
        let st = openTasks.map { _ in "?" }.joined(separator: ",")
        let skip = ownResult.map { _ in "?" }.joined(separator: ",")
        let rows = try c.query("""
            SELECT t.id FROM study_tasks t JOIN files f ON f.id = t.file_id
            WHERE f.status = 'erledigt' AND t.status IN (\(st)) AND t.type NOT IN (\(skip)) ORDER BY t.id
            """, openTasks.map { .text($0) } + ownResult.map { .text($0) })
        var n = 0
        for r in rows where try StudyPlan.setTaskStatus(c, taskID: r["id"] ?? .null, status: "erledigt",
                                                         note: "Auf einem anderen Gerät abgehakt", clock: clock) != nil {
            n += 1
        }
        return n
    }

    /// Aufgaben zu `fileIDs` im Stand `from` auf `to` setzen (ohne Tests), mit Verlauf
    private static func changeTasks(_ c: SQLiteConnection, fileIDs: [String], from: [String], to: String, note: SQLiteValue,
                                    clock: UniFlowClock) throws -> Int {
        let marks = fileIDs.map { _ in "?" }.joined(separator: ",")
        let st = from.map { _ in "?" }.joined(separator: ",")
        let skip = ownResult.map { _ in "?" }.joined(separator: ",")
        let rows = try c.query("SELECT id FROM study_tasks WHERE file_id IN (\(marks)) AND status IN (\(st)) AND type NOT IN (\(skip)) ORDER BY id",
                               fileIDs.map { .text($0) } + from.map { .text($0) } + ownResult.map { .text($0) })
        var n = 0
        for r in rows where try StudyPlan.setTaskStatus(c, taskID: r["id"] ?? .null, status: to, note: note, clock: clock) != nil {
            n += 1
        }
        return n
    }

    /// Plant der Lernkalender das Modul dieser Datei (ueber ihren Kurs; ohne Modul: ja)?
    static func filePlanned(_ c: SQLiteConnection, fileID: String) throws -> Bool {
        guard let m = try c.queryOne("SELECT c.module_id FROM files f JOIN courses c ON c.id = f.course_id WHERE f.id=?", [.text(fileID)])?["module_id"]?.int64
        else { return true }
        return try planned(c, moduleID: m)
    }

    /// Plant der Lernkalender dieses Modul (`plan_modules_off`)?
    static func planned(_ c: SQLiteConnection, moduleID: Int64) throws -> Bool {
        guard let name = try c.queryOne("SELECT name FROM modules WHERE id=?", [.integer(moduleID)])?["name"]?.string else { return true }
        return !(try StudyPlanModules.off(c)).contains(name)
    }
}
