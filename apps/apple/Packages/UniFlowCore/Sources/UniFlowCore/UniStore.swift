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
///    `ContentHash.file`)
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
        /// Titel des letzten Semesters laut Stud.IP (`end-semester`), "unbegrenzt" oder nil (unbekannt, z. B. Learnweb)
        public let semesterEnd: String?
        /// Ende dieses Semesters (ISO mit Versatz) oder nil
        public let semesterEndsAt: String?
        public init(id: String, title: String, number: String?, semester: String?, semesterEnd: String? = nil, semesterEndsAt: String? = nil) {
            self.id = id; self.title = title; self.number = number; self.semester = semester
            self.semesterEnd = semesterEnd; self.semesterEndsAt = semesterEndsAt
        }
    }

    /// Eine Datei der Quelle im Format von `store_course_files`. `chdate`: Aenderungszeit (Stud.IP, Learnweb mit
    /// Schluessel), hoeher = neue Fassung; nil beim Learnweb ueber die Sitzung, dort entscheidet `revision`
    /// (Pluginfile-Revision, `versionStamp`). `size` nil: die Quelle kennt sie nicht (Sitzung), dann bleibt die
    /// gespeicherte und nach dem Download gilt die der geladenen Datei. `folder`: Ordnerpfad im Kurs; nil laesst
    /// `studip_folder` unveraendert (wie `folder_paths` ohne Eintrag), "" ist der Wurzelordner.
    public struct FileRow: Sendable, Equatable {
        public let id: String
        public let name: String
        public var size: Int?
        public let mime: String?
        public let author: String?
        public var chdate: Int?
        public let revision: Int?
        public let downloadURL: String
        public let folder: String?
        public init(id: String, name: String, size: Int?, mime: String?, author: String? = nil, chdate: Int?, revision: Int? = nil,
                    downloadURL: String, folder: String?) {
            self.id = id; self.name = name; self.size = size; self.mime = mime; self.author = author; self.chdate = chdate
            self.revision = revision; self.downloadURL = downloadURL; self.folder = folder
        }
    }

    /// chdate darunter ist keine Unix-Zeit (vor 2001), sondern eine Learnweb-Revision der Sitzung, die vor der Spalte
    /// `files.revision` in chdate stand (`LEGACY_REVISION_MAX`)
    static let legacyRevisionMax = 1_000_000_000

    /// `version_stamp(existing, f, now)`: (chdate, neuere Fassung?) einer Datei der Quelle gegen den gespeicherten
    /// Stand; chdate ist immer eine Unix-Zeit (Lehrwoche, Lernplan, Semesterbeginn lesen sie so).
    /// - Mit Aenderungszeit (Stud.IP, Learnweb mit Schluessel): sie gilt, neuer = hoeher als gespeichert.
    /// - Ohne (Learnweb ueber die Sitzung) entscheidet die Revision: eine neue Datei bekommt den Zeitpunkt des
    ///   Abgleichs `now`, eine hoehere Revision ebenso (mindestens eine Sekunde nach dem gespeicherten), sonst bleibt
    ///   der gespeicherte. Zeilen von vor `files.revision` (Revision in chdate) werden repariert: Zeitpunkt first_seen.
    ///   Ohne gespeicherte Revision (Zeile des Schluessel-Abgleichs von vorher) gilt die Datei als unveraendert.
    static func versionStamp(_ existing: SQLiteRow?, _ f: FileRow, now: Int) -> (chdate: Int, newer: Bool) {
        if let t = f.chdate { return (t, existing.map { ($0["chdate"]?.double ?? 0) < Double(t) } ?? false) }
        guard let e = existing else { return (now, false) }
        var old = Int(e["chdate"]?.double ?? 0)
        var rev = e["revision"]?.int
        if rev == nil, old > 0, old < legacyRevisionMax {
            rev = old
            old = (e["first_seen"]?.string).flatMap(BerlinClock.utcSeconds(localISO:)) ?? now
        }
        if let rev, (f.revision ?? 0) > rev { return (max(now, old + 1), true) }
        return (old != 0 ? old : now, false)
    }

    /// Eintrag in `sync_log` wie im `finally` von run_sync bzw. hildesheim.run_sync: die eine Fassung fuer den
    /// Stud.IP- und den Learnweb-Abgleich
    public static func logSync(_ c: SQLiteConnection, startedAt: String, finishedAt: String, ok: Bool, newFiles: Int, message: String) throws {
        try c.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,?,?)",
                      [.text(startedAt), .text(finishedAt), .integer(ok ? 1 : 0), .integer(Int64(newFiles)), .text(message)])
    }

    /// `upsert_course`: Kurs anlegen/aktualisieren; Fach und Art nur setzen, wenn noch leer (der Nutzer darf sie aendern).
    /// Ende des Semesters nur ueberschreiben, wenn die Quelle eines kennt (Learnweb kennt keines). Danach `active` nach
    /// der Semesterregel (`Semesters`, app/semesters.py), ausser der Nutzer hat selbst entschieden (`active_custom`).
    /// `today`: heutiger Tag (ISO, Ortszeit wie `study.today()`), ohne Angabe der Tag von `now`.
    public static func upsertCourse(_ conn: SQLiteConnection, _ c: CourseRow, now: String, today: String? = nil) throws {
        let (subject, kind) = UniRules.classify(c.title)
        try conn.execute("""
            INSERT INTO courses(id, title, number, semester, semester_end, semester_ends_at, subject, kind, created_at) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, number=excluded.number, semester=excluded.semester,
                semester_end=COALESCE(excluded.semester_end, courses.semester_end),
                semester_ends_at=COALESCE(excluded.semester_ends_at, courses.semester_ends_at)
            """, [.text(c.id), .text(c.title), SQLiteValue(c.number), SQLiteValue(c.semester), SQLiteValue(c.semesterEnd),
                  SQLiteValue(c.semesterEndsAt), .text(subject), .text(kind), .text(now)])
        try conn.execute("UPDATE courses SET subject=COALESCE(subject, ?), kind=COALESCE(kind, ?) WHERE id=?",
                         [.text(subject), .text(kind), .text(c.id)])
        // Nur aktuelle Kurse sind aktiv; eigene Entscheidungen des Nutzers bleiben
        try Semesters.applyToCourse(conn, courseID: c.id, semester: c.semester, semesterEnd: c.semesterEnd, endsAt: c.semesterEndsAt,
                                    today: today ?? PyText.slice(now, 0, 10))
    }

    /// Erster Teil von `store_course_files`: Dateizeilen eines Kurses schreiben. Rueckgabe in Reihenfolge der Liste:
    /// Dateien, die (neu) geladen werden muessen, weil sie neu sind, eine neuere Fassung haben (`versionStamp`:
    /// Aenderungszeit, beim Learnweb ueber die Sitzung die Revision), ohne Ablageort oder lokal verschwunden
    /// (`fileExists(local_path)`); mit ihrem Zeitpunkt in `chdate`. Ob sich eine Datei laden laesst, entscheidet der
    /// Aufrufer. `now`: Ortszeit des Abgleichs wie `db.now_iso()`, zugleich der Zeitpunkt neuer Sitzungsdateien.
    ///
    /// Die neue Fassung einer bekannten Datei (Groesse, Typ, Aenderungszeit, Revision) gilt erst mit dem Download
    /// (`markDownloaded`); Name, Autor, Download-Adresse und Ordner kommen sofort. Status, gesehen, Favorit, Ordner in
    /// UniFlow, Titel und Notizen bleiben; eine unbekannte Groesse (nil) aendert die gespeicherte nicht.
    public static func storeFiles(_ conn: SQLiteConnection, courseID: String, _ files: [FileRow], now: String,
                                  fileExists: (String) -> Bool) throws -> [FileRow] {
        var download: [FileRow] = []
        let nowUnix = BerlinClock.utcSeconds(localISO: now) ?? 0
        for var f in files {
            let id = SQLiteValue.text(f.id)
            var changed = true
            let e = try conn.queryOne("SELECT chdate, local_path, revision, first_seen FROM files WHERE id=?", [id])
            let stamp = versionStamp(e, f, now: nowUnix)
            f.chdate = stamp.chdate
            let chdate = SQLiteValue.integer(Int64(stamp.chdate)), revision = SQLiteValue(f.revision.map(Int64.init))
            if let e {
                let path = e["local_path"]?.string ?? ""
                changed = stamp.newer || path.isEmpty || !fileExists(path)
                if changed {
                    // neue Fassung erst mit dem Download: scheitert er, gilt die Datei beim naechsten Abgleich weiter
                    // als geaendert und wird erneut geladen
                    try conn.execute("UPDATE files SET name=?, author=?, download_url=? WHERE id=?",
                                     [.text(f.name), SQLiteValue(f.author), .text(f.downloadURL), id])
                } else {
                    try conn.execute("""
                        UPDATE files SET name=?, size=COALESCE(?, size), mime=?, author=?, chdate=?, download_url=?, revision=?
                        WHERE id=?
                        """, [.text(f.name), SQLiteValue(f.size.map(Int64.init)), SQLiteValue(f.mime), SQLiteValue(f.author),
                              chdate, .text(f.downloadURL), revision, id])
                }
            } else {
                try conn.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, first_seen, status, kind, revision)
                    VALUES (?,?,?,?,?,?,?,?,?, 'neu', ?, ?)
                    """, [id, .text(courseID), .text(f.name), .integer(Int64(f.size ?? 0)), SQLiteValue(f.mime), SQLiteValue(f.author),
                          chdate, .text(f.downloadURL), .text(now), .text(UniRules.fileKind(name: f.name, mime: f.mime)), revision])
            }
            if let folder = f.folder {
                try conn.execute("UPDATE files SET studip_folder=? WHERE id=?", [.text(folder), id])
            }
            if changed { download.append(f) }
        }
        return download
    }

    /// Zweiter Teil von `store_course_files`, nach erfolgreichem Download: Ablageort (relativ, siehe Quelle),
    /// Ladezeitpunkt, die geladene Fassung (Groesse, Typ, Aenderungszeit, siehe `storeFiles`) und der Inhalts-Hash
    /// (`content_sha256`, `ContentHash.file`; erkennt eine neue Fassung mit gleichem Inhalt, S7) in einem Schritt.
    /// Kopien ("Duplizieren", `sharingCopies`) teilen sich die Datei des Originals und ziehen mit: an den neuen
    /// Ablageort (auch wenn er sich mit dem Namen aendert, sonst zeigte die Kopie weiter die alte Datei) und mit dem
    /// Ladezeitpunkt (der Editor erneuert dann seinen Zwischenspeicher); wer seinen Ablageort verloren hat (z. B. nach
    /// "Abmelden und Dateien löschen", `StudIPLibrary.forgetDownloads`), bekommt ihn hier mit zurueck, sonst oeffnete
    /// sich die Kopie samt Notizen nicht mehr. Ihren Inhalts-Hash setzt wie am PC niemand (Kopien haben keinen).
    public static func markDownloaded(_ conn: SQLiteConnection, _ f: FileRow, localPath: String, sha256: String?, now: String) throws {
        let copies = try sharingCopies(conn, fileID: f.id)                  // vor dem Umhaengen: alter Ablageort
        try conn.execute("UPDATE files SET local_path=?, downloaded_at=?, size=?, mime=?, chdate=?, revision=?, content_sha256=? WHERE id=?",
                         [.text(localPath), .text(now), .integer(Int64(f.size ?? 0)), SQLiteValue(f.mime), .integer(Int64(f.chdate ?? 0)),
                          SQLiteValue(f.revision.map(Int64.init)), SQLiteValue(sha256), .text(f.id)])
        for id in copies {
            try conn.execute("UPDATE files SET local_path=?, downloaded_at=? WHERE id=?", [.text(localPath), .text(now), .text(id)])
        }
    }

    /// Kopien ("Duplizieren") einer Datei, die sich ihre Datei teilen: derselbe Ablageort wie die Datei, oder keiner
    /// mehr (nach "Dateien löschen") bei gleicher Download-Adresse; ohne eigene Dokumente. Eine Kopie verweist sonst
    /// nirgends auf ihr Original (wie am PC).
    public static func sharingCopies(_ conn: SQLiteConnection, fileID: String) throws -> [String] {
        try conn.query("""
            SELECT c.id FROM files c JOIN files f ON f.id=?
            WHERE c.id<>f.id AND c.course_id<>'__user__'
              AND ((COALESCE(f.local_path, '')<>'' AND c.local_path=f.local_path)
                   OR (COALESCE(c.local_path, '')='' AND COALESCE(c.download_url, '')<>'' AND c.download_url=f.download_url))
            ORDER BY c.id
            """, [.text(fileID)]).compactMap { $0["id"]?.string }
    }

    /// Kam statt der Datei eine Webseite (meist eine abgelaufene Anmeldung)? Wie `stream_download` in
    /// app/studip_sync.py: Anfang ohne Leerraum beginnt mit "<!doctype html" oder "<html" und der Dateiname endet
    /// nicht auf .html/.htm. Dann wird nichts gespeichert.
    public static func isWebPage(file url: URL, name: String) -> Bool {
        if StudIPClient.isHTMLFileName(name) { return false }
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
