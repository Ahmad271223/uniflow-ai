import Foundation

/// Stud.IP-Abgleich in die lokale Datenbank wie `run_sync` in app/studip_sync.py: dieselben Tabellen (`courses`,
/// `files`, `sync_log`), dieselben IDs (Kurs- und Datei-ID aus Stud.IP, die Datei-ID ist die FileRef-ID), dieselben
/// Felder und Standardwerte. Neue Dateien bekommen Status "neu" und `seen_by_user = 0`; beim erneuten Abgleich
/// aendert sich nur, was aus Stud.IP kommt (Name, Groesse, Typ, Aenderungszeit, Download-Adresse, Ordner; eine neue
/// Fassung erst mit ihrem Download) – Status, gesehen, Favorit, Ordner in UniFlow, Titel und Notizen bleiben.
/// Duplikate von Stud.IP-Dateien teilen sich deren lokale Datei. In Stud.IP geloeschte Dateien bleiben wie
/// in Python stehen (mit ihren Notizen), eine umbenannte Datei behaelt ihre ID und damit ihre Notizen.
///
/// Abweichungen von Python: `author` kennt die JSON:API nicht (bleibt leer bzw. unveraendert), `download_url` ist die
/// JSON:API-Adresse, aus der die App laedt, `local_path` ist relativ zum App-Container (`LocalFiles`).
/// Fach und Art der Kurse (`classify`) kommen mit S4: bis dahin bleiben sie leer und werden dann wie in Python nur
/// gesetzt, solange sie leer sind (der Nutzer darf sie aendern).
///
/// Alles hier ist synchron und fuer `SQLiteDatabase.transaction` gedacht (kein Netz, kein `await` darin).
public enum StudIPLibrary {
    /// `classify(title) -> (subject, kind)` aus app/studip_sync.py (Port mit S4)
    public typealias Classifier = @Sendable (_ courseTitle: String) -> (subject: String?, kind: String?)

    /// `file_kind(name, mime)`: nur echte PDFs gehen in den PDF-Editor
    public static func fileKind(name: String, mime: String?) -> String {
        let n = name.lowercased(), m = (mime ?? "").lowercased()
        if n.hasSuffix(".pdf") || m == "application/pdf" { return "pdf" }
        if [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains(where: { n.hasSuffix($0) }) || m.hasPrefix("image/") { return "image" }
        return "file"
    }

    /// Download-Adresse einer Datei (JSON:API, wie `StudIPClient.download`)
    public static func downloadURL(base: URL, fileID: String) -> String {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return b + "/jsonapi.php/v1/file-refs/\(fileID)/content"
    }

    /// Meldung in `sync_log` wie Python
    public static func summary(newFiles: Int) -> String { "\(newFiles) neue/geaenderte Dateien" }
    public static func failure(_ message: String) -> String { "FEHLER: \(message)" }

    // MARK: Schreiben

    /// Kurse eines Durchgangs: neu anlegen oder Titel, Nummer und Semester aktualisieren
    public static func storeCourses(_ c: SQLiteConnection, _ courses: [StudIPCourse], startedAt: String,
                                    classify: Classifier? = nil) throws {
        for course in courses {
            let (subject, kind) = classify?(course.title) ?? (nil, nil)
            try c.execute("""
                INSERT INTO courses(id, title, number, semester, subject, kind, created_at)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, number=excluded.number,
                    semester=excluded.semester
                """, [.text(course.id), .text(course.title), SQLiteValue(course.number), .text(course.semesterTitle ?? ""),
                      SQLiteValue(subject), SQLiteValue(kind), .text(startedAt)])
            // Fach/Art nur setzen, wenn noch leer (Nutzer darf es aendern)
            try c.execute("UPDATE courses SET subject=COALESCE(subject, ?), kind=COALESCE(kind, ?) WHERE id=?",
                          [SQLiteValue(subject), SQLiteValue(kind), .text(course.id)])
        }
    }

    /// Vollstaendige Dateiliste eines Kurses. Rueckgabe: Dateien, die wie in Python geladen werden muessen (neu, in
    /// Stud.IP juenger als der gespeicherte Stand, ohne lokale Datei oder lokale Datei fehlt). Ob sie sich laden
    /// lassen (`isDownloadable`), entscheidet der Aufrufer.
    ///
    /// Die neue Fassung einer bekannten Datei (Groesse, Typ, Aenderungszeit) gilt erst mit dem Download
    /// (`markDownloaded`): Bricht der Lauf vorher ab oder scheitert der Download, bleibt die Datei beim naechsten
    /// Abgleich "geaendert" und wird erneut geladen. Name, Download-Adresse und Ordner kommen sofort.
    public static func storeFiles(_ c: SQLiteConnection, _ files: [StudIPFile], startedAt: String, base: URL,
                                  localFiles: LocalFiles?) throws -> [StudIPFile] {
        var download: [StudIPFile] = []
        for f in files {
            let id = SQLiteValue.text(f.id)
            let chdate = Int64(unixTime(f.changed) ?? 0)
            let existing = try c.queryOne("SELECT chdate, local_path FROM files WHERE id=?", [id])
            var changed = true
            if let e = existing {
                let old = e["chdate"]?.double ?? 0
                let path = e["local_path"]?.string
                changed = old < Double(chdate) || (path ?? "").isEmpty || !(localFiles?.exists(stored: path) ?? false)
                if changed {
                    try c.execute("UPDATE files SET name=?, download_url=? WHERE id=?",
                                  [.text(f.name), .text(downloadURL(base: base, fileID: f.id)), id])
                } else {
                    try c.execute("UPDATE files SET name=?, size=?, mime=?, chdate=?, download_url=? WHERE id=?",
                                  [.text(f.name), .integer(Int64(f.size)), SQLiteValue(f.mimeType), .integer(chdate),
                                   .text(downloadURL(base: base, fileID: f.id)), id])
                }
            } else {
                try c.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, first_seen, status, kind)
                    VALUES (?,?,?,?,?,?,?,?,?, 'neu', ?)
                    """, [id, .text(f.courseID), .text(f.name), .integer(Int64(f.size)), SQLiteValue(f.mimeType), .null, .integer(chdate),
                          .text(downloadURL(base: base, fileID: f.id)), .text(startedAt), .text(fileKind(name: f.name, mime: f.mimeType))])
            }
            // Ordnerpfad im Kurs ("" = Wurzelordner), wie fetch_folder_paths
            try c.execute("UPDATE files SET studip_folder=? WHERE id=?", [.text(f.folderPath), id])
            if changed { download.append(f) }
        }
        return download
    }

    /// Datei heruntergeladen: Ablageort relativ zum App-Container, Zeitpunkt wie `db.now_iso()`, dazu die geladene
    /// Fassung (Groesse, Typ, Aenderungszeit, siehe `storeFiles`) in einem Schritt.
    /// Kopien ("Duplizieren") teilen sich die Datei des Originals; wer seinen Ablageort verloren hat (z. B. nach
    /// "Abmelden und Dateien löschen", `forgetDownloads`), bekommt ihn hier mit zurueck, sonst oeffnete sich die
    /// Kopie samt Notizen nicht mehr.
    public static func markDownloaded(_ c: SQLiteConnection, file f: StudIPFile, localPath: String, at: String) throws {
        let chdate = Int64(unixTime(f.changed) ?? 0)
        try c.execute("UPDATE files SET local_path=?, downloaded_at=?, size=?, mime=?, chdate=? WHERE id=?",
                      [.text(localPath), .text(at), .integer(Int64(f.size)), SQLiteValue(f.mimeType), .integer(chdate), .text(f.id)])
        try c.execute("""
            UPDATE files SET local_path=?, downloaded_at=?
            WHERE id<>? AND course_id<>'__user__' AND COALESCE(local_path, '')=''
              AND download_url=(SELECT download_url FROM files WHERE id=?)
            """, [.text(localPath), .text(at), .text(f.id), .text(f.id)])
    }

    /// Eintrag in `sync_log` wie im `finally` von run_sync
    public static func log(_ c: SQLiteConnection, startedAt: String, finishedAt: String, ok: Bool, newFiles: Int, message: String) throws {
        try c.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,?,?)",
                      [.text(startedAt), .text(finishedAt), .integer(ok ? 1 : 0), .integer(Int64(newFiles)), .text(message)])
    }

    /// Lokale Datei entfernt (z. B. "Abmelden und Dateien löschen"): Eintrag und Notizen bleiben, nur der Ablageort
    /// faellt weg; der naechste Abgleich laedt die Datei neu (Duplikate bekommen ihn dabei mit, `markDownloaded`).
    /// Rueckgabe: IDs der betroffenen Dateien samt Duplikaten (der Aufrufer entfernt damit Kopien, z. B. im
    /// PDF-Zwischenspeicher des Editors).
    @discardableResult
    public static func forgetDownloads(_ c: SQLiteConnection, under prefix: String) throws -> [String] {
        let match = "course_id <> '__user__' AND substr(local_path, 1, ?) = ?"
        let args: [SQLiteValue] = [.integer(Int64(prefix.count)), .text(prefix)]
        let ids = try c.query("SELECT id FROM files WHERE \(match) ORDER BY id", args).compactMap { $0["id"]?.string }
        try c.execute("UPDATE files SET local_path=NULL, downloaded_at=NULL WHERE \(match)", args)
        return ids
    }

    /// Bestand aus dem Index der App von vor S3 (`index.json`) uebernehmen, ohne neu zu laden: fehlende Kurse und
    /// Dateien werden wie bei einem Abgleich angelegt, mit Ablageort und Ladezeitpunkt der vorhandenen Datei. Dateien,
    /// die die Datenbank schon kennt, bleiben unberuehrt. Rueckgabe: Zahl der uebernommenen Dateien.
    public static func adopt(_ c: SQLiteConnection, entries: [StudIPLocalEntry], courses: [StudIPCourse], at: String, base: URL,
                             localPath: (StudIPLocalEntry) -> String?) throws -> Int {
        let known = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var missingCourses: [StudIPCourse] = []
        var seen = Set<String>()
        for e in entries where !seen.contains(e.courseID) {
            seen.insert(e.courseID)
            if try c.queryOne("SELECT 1 FROM courses WHERE id=?", [.text(e.courseID)]) == nil {
                missingCourses.append(known[e.courseID] ?? StudIPCourse(id: e.courseID, title: e.courseTitle))
            }
        }
        try storeCourses(c, missingCourses, startedAt: at)
        var adopted = 0
        for e in entries.sorted(by: { $0.id < $1.id }) {
            guard try c.queryOne("SELECT 1 FROM files WHERE id=?", [.text(e.id)]) == nil, let path = localPath(e) else { continue }
            let f = StudIPFile(id: e.id, courseID: e.courseID, name: e.name, size: e.size, mimeType: e.mimeType, changed: e.changed,
                               folderPath: e.folderPath)
            _ = try storeFiles(c, [f], startedAt: at, base: base, localFiles: nil)
            let loaded = unixTime(e.downloadedAt).map { BerlinClock.localISO(utc: $0) } ?? at
            try markDownloaded(c, file: f, localPath: path, at: loaded)
            adopted += 1
        }
        return adopted
    }

    // MARK: Zeit

    /// Unix-Zeit aus der Aenderungszeit: JSON:API liefert ISO 8601 mit Zone ("2026-10-20T10:00:00+02:00", "...Z",
    /// Sekundenbruchteile erlaubt), die Dateiliste der Weboberflaeche eine Zahl. Ohne Zone gilt Berliner Ortszeit.
    public static func unixTime(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let i = Int(s) { return i }
        if let d = Double(s), d.isFinite, s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) { return Int(d) }
        let u = Array(s.utf8)
        guard u.count >= 10, let day = BerlinClock.parseISODate(String(decoding: u[0..<10], as: UTF8.self)) else { return nil }
        guard u.count > 10 else { return BerlinClock.utcSeconds(day: day, minutes: 0) }
        guard u[10] == 0x54 || u[10] == 0x20 else { return nil }                     // "T" oder Leerzeichen
        var i = 11
        func number(_ n: Int) -> Int? {
            guard i + n <= u.count, u[i..<i + n].allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            defer { i += n }
            return Int(String(decoding: u[i..<i + n], as: UTF8.self))
        }
        guard let h = number(2), h < 24, i < u.count, u[i] == 0x3A else { return nil }
        i += 1
        guard let m = number(2), m < 60 else { return nil }
        var sec = 0
        if i < u.count, u[i] == 0x3A {
            i += 1
            guard let v = number(2), v < 61 else { return nil }
            sec = min(v, 59)
        }
        if i < u.count, u[i] == 0x2E || u[i] == 0x2C {                               // Sekundenbruchteile
            i += 1
            while i < u.count, (0x30...0x39).contains(u[i]) { i += 1 }
        }
        guard i < u.count else { return BerlinClock.utcSeconds(day: day, minutes: h * 60 + m) + sec }
        var offset = 0
        if u[i] == 0x5A || u[i] == 0x7A {                                            // Z
            i += 1
        } else if u[i] == 0x2B || u[i] == 0x2D {
            let sign = u[i] == 0x2D ? -1 : 1
            i += 1
            guard let oh = number(2) else { return nil }
            var om = 0
            if i < u.count, u[i] == 0x3A { i += 1 }
            if i < u.count { guard let v = number(2) else { return nil }; om = v }
            offset = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == u.count else { return nil }
        return day * 86400 + h * 3600 + m * 60 + sec - offset
    }
}
