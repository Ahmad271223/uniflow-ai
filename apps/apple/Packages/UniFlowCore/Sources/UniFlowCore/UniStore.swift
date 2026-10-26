import Foundation

/// Kurse und Dateien einer Hochschul-Quelle in der lokalen Datenbank, wie `upsert_course` und `store_course_files` in
/// app/studip_sync.py. Eine Fassung fuer alle Abgleiche: Stud.IP (`StudIPLibrary` -> StudIPSync in der App) und
/// Learnweb (`HildesheimSync`), dieselben Tabellen, Felder und Regeln wie am PC (Fach und Art aus `UniRules.classify`,
/// Dateiart aus `UniRules.fileKind`). LSF-Stundenplan und Noten stehen in HildesheimSync.swift (`importPlan`,
/// `storeGrades`).
///
/// Ablauf je Kurs wie `store_course_files`, aufgeteilt, weil im Kern kein Netz in einer Transaktion laeuft:
/// 1. `storeFiles` (Transaktion): Dateizeilen schreiben, Rueckgabe der Dateien, die geladen werden muessen
/// 2. Download ausserhalb der Transaktion (`UniDownloads.load`: Quelle laedt, Ablage im Container, Inhalts-Hash mit
///    `TestShare.contentHash(file:)`)
/// 3. `markDownloaded` (Transaktion, ebenfalls aus `UniDownloads.load`): Ablageort, Ladezeitpunkt, die geladene
///    Fassung und `content_sha256`
/// Scheitert der Download, bleibt die alte Fassung stehen und die Datei gilt beim naechsten Abgleich weiter als
/// geaendert. Nichts wird geloescht: in der Quelle verschwundene Dateien bleiben mit ihren Notizen stehen.
/// Alles hier ist synchron und fuer `SQLiteDatabase.transaction` gedacht (kein `await` darin).
public enum UniStore {

    public struct CourseRow: Sendable, Equatable {
        public let id: String
        public let title: String
        public let number: String?
        public let semester: String?
        public init(id: String, title: String, number: String?, semester: String?) {
            self.id = id; self.title = title; self.number = number; self.semester = semester
        }
    }

    /// Eine Datei der Quelle im Format von `store_course_files`. `chdate`: Aenderungszeit (Stud.IP, Learnweb mit
    /// Schluessel) bzw. Revision (Learnweb mit Sitzung); hoeher = neue Fassung. `folder`: Ordnerpfad im Kurs; nil
    /// laesst `studip_folder` unveraendert (wie `folder_paths` ohne Eintrag), "" ist der Wurzelordner.
    public struct FileRow: Sendable, Equatable {
        public let id: String
        public let name: String
        public let size: Int
        public let mime: String?
        public let author: String?
        public let chdate: Int
        public let downloadURL: String
        public let folder: String?
        public init(id: String, name: String, size: Int, mime: String?, author: String? = nil, chdate: Int, downloadURL: String,
                    folder: String?) {
            self.id = id; self.name = name; self.size = size; self.mime = mime; self.author = author; self.chdate = chdate
            self.downloadURL = downloadURL; self.folder = folder
        }
    }

    /// `upsert_course`: Kurs anlegen/aktualisieren; Fach und Art nur setzen, wenn noch leer (der Nutzer darf sie aendern).
    public static func upsertCourse(_ conn: SQLiteConnection, _ c: CourseRow, now: String) throws {
        let (subject, kind) = UniRules.classify(c.title)
        try conn.execute("""
            INSERT INTO courses(id, title, number, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, number=excluded.number, semester=excluded.semester
            """, [.text(c.id), .text(c.title), SQLiteValue(c.number), SQLiteValue(c.semester), .text(subject), .text(kind), .text(now)])
        try conn.execute("UPDATE courses SET subject=COALESCE(subject, ?), kind=COALESCE(kind, ?) WHERE id=?",
                         [.text(subject), .text(kind), .text(c.id)])
    }

    /// Erster Teil von `store_course_files`: Dateizeilen eines Kurses schreiben. Rueckgabe in Reihenfolge der Liste:
    /// Dateien, die (neu) geladen werden muessen, weil sie neu sind, in der Quelle juenger als der gespeicherte Stand,
    /// ohne Ablageort oder lokal verschwunden (`fileExists(local_path)`). Ob sich eine Datei laden laesst, entscheidet
    /// der Aufrufer.
    ///
    /// Die neue Fassung einer bekannten Datei (Groesse, Typ, Aenderungszeit) gilt erst mit dem Download
    /// (`markDownloaded`); Name, Autor, Download-Adresse und Ordner kommen sofort. Status, gesehen, Favorit, Ordner in
    /// UniFlow, Titel und Notizen bleiben.
    public static func storeFiles(_ conn: SQLiteConnection, courseID: String, _ files: [FileRow], now: String,
                                  fileExists: (String) -> Bool) throws -> [FileRow] {
        var download: [FileRow] = []
        for f in files {
            let id = SQLiteValue.text(f.id)
            var changed = true
            if let e = try conn.queryOne("SELECT chdate, local_path FROM files WHERE id=?", [id]) {
                let path = e["local_path"]?.string ?? ""
                changed = (e["chdate"]?.double ?? 0) < Double(f.chdate) || path.isEmpty || !fileExists(path)
                if changed {
                    // neue Fassung erst mit dem Download: scheitert er, gilt die Datei beim naechsten Abgleich weiter
                    // als geaendert und wird erneut geladen
                    try conn.execute("UPDATE files SET name=?, author=?, download_url=? WHERE id=?",
                                     [.text(f.name), SQLiteValue(f.author), .text(f.downloadURL), id])
                } else {
                    try conn.execute("UPDATE files SET name=?, size=?, mime=?, author=?, chdate=?, download_url=? WHERE id=?",
                                     [.text(f.name), .integer(Int64(f.size)), SQLiteValue(f.mime), SQLiteValue(f.author),
                                      .integer(Int64(f.chdate)), .text(f.downloadURL), id])
                }
            } else {
                try conn.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, first_seen, status, kind)
                    VALUES (?,?,?,?,?,?,?,?,?, 'neu', ?)
                    """, [id, .text(courseID), .text(f.name), .integer(Int64(f.size)), SQLiteValue(f.mime), SQLiteValue(f.author),
                          .integer(Int64(f.chdate)), .text(f.downloadURL), .text(now), .text(UniRules.fileKind(name: f.name, mime: f.mime))])
            }
            if let folder = f.folder {
                try conn.execute("UPDATE files SET studip_folder=? WHERE id=?", [.text(folder), id])
            }
            if changed { download.append(f) }
        }
        return download
    }

    /// Zweiter Teil von `store_course_files`, nach erfolgreichem Download: Ablageort (relativ, siehe Quelle),
    /// Ladezeitpunkt, die geladene Fassung (Groesse, Typ, Aenderungszeit, siehe `storeFiles`) und der Inhalts-Hash fuer
    /// gemeinsame Wochentests (`content_sha256`, `TestShare.contentHash(file:)`) in einem Schritt.
    /// Kopien ("Duplizieren") teilen sich die Datei des Originals; wer seinen Ablageort verloren hat (z. B. nach
    /// "Abmelden und Dateien löschen", `StudIPLibrary.forgetDownloads`), bekommt ihn hier mit zurueck, sonst oeffnete
    /// sich die Kopie samt Notizen nicht mehr. Ihren Inhalts-Hash setzt wie am PC niemand (Kopien haben keinen).
    public static func markDownloaded(_ conn: SQLiteConnection, _ f: FileRow, localPath: String, sha256: String?, now: String) throws {
        try conn.execute("UPDATE files SET local_path=?, downloaded_at=?, size=?, mime=?, chdate=?, content_sha256=? WHERE id=?",
                         [.text(localPath), .text(now), .integer(Int64(f.size)), SQLiteValue(f.mime), .integer(Int64(f.chdate)),
                          SQLiteValue(sha256), .text(f.id)])
        try conn.execute("""
            UPDATE files SET local_path=?, downloaded_at=?
            WHERE id<>? AND course_id<>'__user__' AND COALESCE(local_path, '')=''
              AND download_url=(SELECT download_url FROM files WHERE id=?)
            """, [.text(localPath), .text(now), .text(f.id), .text(f.id)])
    }

    /// Kam statt der Datei eine Webseite (meist eine abgelaufene Anmeldung)? Wie `stream_download` in
    /// app/studip_sync.py: Anfang ohne Leerraum beginnt mit "<!doctype html" oder "<html" und der Dateiname endet
    /// nicht auf .html/.htm. Dann wird nichts gespeichert.
    public static func isWebPage(file url: URL, name: String) -> Bool {
        let n = name.lowercased()
        if n.hasSuffix(".html") || n.hasSuffix(".htm") { return false }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return startsLikeWebPage((try? h.read(upToCount: 65536)) ?? Data())
    }

    /// Anfang (nach `bytes.lstrip()`: Leerzeichen, \t, \n, \r, \v, \f; zusaetzlich zu Python ohne UTF-8-BOM)
    /// beginnt mit "<!doctype html" oder "<html". Auch fuer Antworten, die JSON sein sollten (Learnweb-AJAX).
    static func startsLikeWebPage(_ data: Data) -> Bool {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let start = bytes.drop { [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C].contains($0) }.prefix(15)
        let head = String(decoding: start, as: UTF8.self).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }
}
