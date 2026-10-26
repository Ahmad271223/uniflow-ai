import Foundation

/// Stud.IP-Abgleich in die lokale Datenbank wie `run_sync` in app/studip_sync.py: dieselben Tabellen (`courses`,
/// `files`, `sync_log`), dieselben IDs (Kurs- und Datei-ID aus Stud.IP, die Datei-ID ist die FileRef-ID), dieselben
/// Felder und Standardwerte. Geschrieben wird ueber `UniStore` (`upsert_course`, `store_course_files`), dieselbe
/// Fassung wie fuer Learnweb; hier steht nur, was Stud.IP-eigen ist: Kurse und Dateien der JSON:API als Zeilen,
/// Download-Adresse, Aenderungszeit, Protokoll, Abmelden und die Uebernahme des Bestands von vor S3.
/// Neue Dateien bekommen Status "neu" und `seen_by_user = 0`; beim erneuten Abgleich aendert sich nur, was aus
/// Stud.IP kommt (Name, Groesse, Typ, Aenderungszeit, Download-Adresse, Ordner; eine neue Fassung erst mit ihrem
/// Download) – Status, gesehen, Favorit, Ordner in UniFlow, Titel und Notizen bleiben. Duplikate von Stud.IP-Dateien
/// teilen sich deren lokale Datei. In Stud.IP geloeschte Dateien bleiben wie in Python stehen (mit ihren Notizen),
/// eine umbenannte Datei behaelt ihre ID und damit ihre Notizen.
///
/// Abweichungen von Python: `author` kennt die JSON:API nicht (bleibt leer bzw. unveraendert), `download_url` ist die
/// JSON:API-Adresse, aus der die App laedt, `local_path` ist relativ zum App-Container (`LocalFiles`).
/// Fach und Art eines Kurses kommen wie in `upsert_course` aus `classify` (`UniRules.classify`) und werden nur
/// gesetzt, solange sie leer sind (der Nutzer darf sie aendern); die Module dazu legt `ensure_modules` beim naechsten
/// Lesen an (`LocalModules.ensureModules`, wie Python in `/api/library`, `/api/modules` und der Uebersicht).
///
/// Alles hier ist synchron und fuer `SQLiteDatabase.transaction` gedacht (kein Netz, kein `await` darin).
public enum StudIPLibrary {
    /// Download-Adresse einer Datei (JSON:API, wie `StudIPClient.download`)
    public static func downloadURL(base: URL, fileID: String) -> String {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return b + "/jsonapi.php/v1/file-refs/\(fileID)/content"
    }

    /// Meldung in `sync_log` wie Python
    /// `newEvents`: von auto_import uebernommene Stundenplan-Termine (S5), wie `message += ", N Stundenplan-Termine"`
    public static func summary(newFiles: Int, newEvents: Int = 0) -> String {
        "\(newFiles) neue/geaenderte Dateien" + (newEvents > 0 ? ", \(newEvents) Stundenplan-Termine" : "")
    }
    public static func failure(_ message: String) -> String { "FEHLER: \(message)" }

    // MARK: Zeilen fuer UniStore

    /// Kurs wie in `courses()` von app/studip_sync.py: Semester als Text, ohne Semester ""
    public static func courseRow(_ c: StudIPCourse) -> UniStore.CourseRow {
        UniStore.CourseRow(id: c.id, title: c.title, number: c.number, semester: c.semesterTitle ?? "")
    }

    /// Datei mit Aenderungszeit als Unix-Zeit, Download-Adresse der JSON:API und Ordnerpfad im Kurs ("" = Wurzelordner,
    /// wie `fetch_folder_paths`)
    public static func fileRow(_ f: StudIPFile, base: URL) -> UniStore.FileRow {
        UniStore.FileRow(id: f.id, name: f.name, size: f.size, mime: f.mimeType, author: nil, chdate: unixTime(f.changed) ?? 0,
                         downloadURL: downloadURL(base: base, fileID: f.id), folder: f.folderPath)
    }

    // MARK: Schreiben

    /// Kurse eines Durchgangs wie `upsert_course` (`UniStore.upsertCourse`)
    public static func storeCourses(_ c: SQLiteConnection, _ courses: [StudIPCourse], startedAt: String) throws {
        for course in courses { try UniStore.upsertCourse(c, courseRow(course), now: startedAt) }
    }

    /// Vollstaendige Dateiliste eines Kurses (`UniStore.storeFiles`). Rueckgabe: Dateien, die wie in Python geladen
    /// werden muessen (neu, in Stud.IP juenger als der gespeicherte Stand, ohne lokale Datei oder lokale Datei fehlt).
    /// Ob sie sich laden lassen (`isDownloadable`), entscheidet der Aufrufer. Die neue Fassung einer bekannten Datei
    /// gilt erst mit dem Download (`markDownloaded`).
    public static func storeFiles(_ c: SQLiteConnection, _ files: [StudIPFile], startedAt: String, base: URL,
                                  localFiles: LocalFiles?) throws -> [StudIPFile] {
        try files.filter { f in
            try !UniStore.storeFiles(c, courseID: f.courseID, [fileRow(f, base: base)], now: startedAt,
                                     fileExists: { localFiles?.exists(stored: $0) ?? false }).isEmpty
        }
    }

    /// Datei heruntergeladen (`UniStore.markDownloaded`): Ablageort relativ zum App-Container, Zeitpunkt wie
    /// `db.now_iso()`, die geladene Fassung und der Inhalts-Hash (`ContentHash.file`) in einem Schritt.
    public static func markDownloaded(_ c: SQLiteConnection, file f: StudIPFile, localPath: String, sha256: String?, at: String,
                                      base: URL) throws {
        try UniStore.markDownloaded(c, fileRow(f, base: base), localPath: localPath, sha256: sha256, now: at)
    }

    // MARK: Lesen (das eine Register der geladenen Dateien ist `files`)

    /// Geladene Stud.IP-Datei fuer die Liste in StudIPView und die Zaehler. Vorher stand jede Datei zusaetzlich in
    /// index.json, das nur nach einem Download nachgefuehrt wurde (Name und Ordner nach einer Umbenennung veraltet).
    public struct DownloadedFile: Sendable, Equatable, Identifiable {
        public let id: String
        public let courseID: String
        public let courseTitle: String
        /// Ordnerpfad im Kurs ("" = Wurzelordner)
        public let folder: String
        public let name: String
        public let size: Int
        public let mime: String?
        /// Ablageort relativ zum Container (`files.local_path`)
        public let localPath: String
    }

    /// Bedingung "Stud.IP-Datei unter `prefix`, keine Kopie": Kopien ("Duplizieren") teilen sich Ablageort und
    /// Download-Adresse des Originals, ihre ID steht aber nicht in der Adresse (`…/file-refs/<id>/content`)
    private static let originalUnderPrefix = """
        f.course_id <> '__user__' AND substr(f.local_path, 1, ?) = ? AND instr(COALESCE(f.download_url, ''), '/file-refs/' || f.id || '/') > 0
        """

    /// Geladene Stud.IP-Dateien unter `prefix` (Stud.IP-Ordner des Containers mit "/" am Ende), nach Kurs, Ordner
    /// und Name
    public static func downloadedFiles(_ c: SQLiteConnection, under prefix: String) throws -> [DownloadedFile] {
        try c.query("""
            SELECT f.id, f.course_id, COALESCE(c.title, 'Kurs') AS course_title, COALESCE(f.studip_folder, '') AS folder, f.name,
                   f.size, f.mime, f.local_path FROM files f LEFT JOIN courses c ON c.id=f.course_id
            WHERE \(originalUnderPrefix) ORDER BY course_title, folder, f.name, f.id
            """, [.integer(Int64(prefix.count)), .text(prefix)]).compactMap { r in
            guard let id = r["id"]?.string, let path = r["local_path"]?.string else { return nil }
            return DownloadedFile(id: id, courseID: r["course_id"]?.string ?? "", courseTitle: r["course_title"]?.string ?? "Kurs",
                                  folder: r["folder"]?.string ?? "", name: r["name"]?.string ?? "", size: Int(r["size"]?.double ?? 0),
                                  mime: r["mime"]?.string, localPath: path)
        }
    }

    /// Geladene Dateien vollstaendig gelesener Kurse (`checkedCourses`), die Stud.IP nicht mehr liefert. Wird nur
    /// gemeldet, nie geloescht (die Notizen bleiben).
    public static func goneRemotely(_ c: SQLiteConnection, remoteIDs: Set<String>, checkedCourses: Set<String>,
                                    under prefix: String) throws -> [String] {
        try downloadedFiles(c, under: prefix).filter { checkedCourses.contains($0.courseID) && !remoteIDs.contains($0.id) }
            .map(\.id).sorted()
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
            // ohne Inhalts-Hash (die Dateien nicht beim Start lesen); gemeinsame Wochentests lesen dann die Datei selbst
            // wie `material_fingerprint` in app/testshare.py
            try markDownloaded(c, file: f, localPath: path, sha256: nil, at: loaded, base: base)
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
