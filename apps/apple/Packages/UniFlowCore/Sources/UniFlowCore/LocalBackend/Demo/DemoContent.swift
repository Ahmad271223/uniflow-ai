import Foundation

/// Demo-Inhalte fuer die App-Pruefung ohne Hochschulkonto und zum Ausprobieren, wie app/demo.py (dieselben Inhalte,
/// Kennungen und Datumslogik; Vergleich mit Python: fixtures/demo/demo.json, tools/gen-demo-fixture.py).
///
/// Ein Demo-Modul "Grundlagen der Informatik" mit Vorlesung und Uebung: drei hier erzeugte PDFs (Skript, Folien,
/// Uebungsblatt; keine fremden Inhalte), Stundenplan-Termine (Mo/Mi/Do, woechentlich), drei Lernpakete dieser Woche
/// (relativ zur Uhr des Backends), eine Abgabefrist und eine Ankuendigung mit Raumwechsel. Alles traegt die Kennung
/// "demo-" bzw. source = "demo".
///
/// Auf dem Geraet lebt die Demo in der Datenbank des offenen Containers (Apple-Nutzer, Hochschule), die PDFs unter
/// `<Datenordner>/files/Demo`. `remove` entfernt rueckstandslos und mehr als Python (dort bleiben Notiz-Versionen,
/// Karteikarten und eigene Termine im Demo-Modul stehen): Dateien samt Bildern der Notizen, Notizen und ihre Versionen,
/// Analysen, Seitentexte, Karteikarten, Aufnahmen zu Seiten, alte Fassungen, erkannte Abgaben, Lernpakete und Aufgaben
/// samt Verlauf, Termine mit Ausnahmen und Notizen, Fristen, Ankuendigungen, Kurse und das Modul. Eigene Daten des
/// Nutzers bleiben: ein Modul, in das der Nutzer eigene Kurse gelegt hat, bleibt stehen (nur die Demo-Teile gehen),
/// eigene Termine und Ordner im Demo-Modul verlieren nur die Zuordnung.
public enum DemoContent {
    public static let moduleName = "Demo: Grundlagen der Informatik"
    public static let subject = "Demo Informatik"
    public static let color = "#7c3aed"
    /// Schalter in `settings` ("1" an, "0" aus; `db.set_setting` schreibt str(1)/str(0))
    public static let settingKey = "demo_content"
    /// Kennung aller Demo-Kurse, -Dateien, -Fristen und -Ankuendigungen; `source` der Termine, Fristen, Ankuendigungen
    public static let idPrefix = "demo-"
    public static let source = "demo"
    /// Ordner der PDFs relativ zum Datenordner (`config.files_dir() / "Demo"`)
    public static let folder = "files/Demo"

    public struct Course: Sendable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public let number: String
    }

    public struct Event: Sendable, Equatable {
        public let courseID: String
        public let title: String
        public let kind: String
        /// 0 = Montag
        public let weekday: Int
        public let start: String
        public let end: String
        public let room: String
        public let lecturer: String
    }

    public struct Page: Sendable, Equatable {
        public let title: String
        public let lines: [String]
        public init(_ title: String, _ lines: [String]) {
            self.title = title
            self.lines = lines
        }
    }

    public struct File: Sendable, Equatable {
        public let id: String
        public let courseID: String
        public let name: String
        public let pages: [Page]
    }

    public static let courses: [Course] = [
        Course(id: "demo-vorlesung", title: "Demo: Grundlagen der Informatik (Vorlesung)", kind: "vorlesung", number: "DEMO-101"),
        Course(id: "demo-uebung", title: "Demo: Grundlagen der Informatik (Übung)", kind: "uebung", number: "DEMO-101Ü"),
    ]

    public static let events: [Event] = [
        Event(courseID: "demo-vorlesung", title: "Grundlagen der Informatik – Vorlesung", kind: "vorlesung", weekday: 0,
              start: "10:00", end: "12:00", room: "Hörsaal A", lecturer: "Prof. Demo"),
        Event(courseID: "demo-vorlesung", title: "Grundlagen der Informatik – Vorlesung", kind: "vorlesung", weekday: 3,
              start: "08:15", end: "09:45", room: "Hörsaal A", lecturer: "Prof. Demo"),
        Event(courseID: "demo-uebung", title: "Grundlagen der Informatik – Übung", kind: "uebung", weekday: 2,
              start: "14:00", end: "16:00", room: "Seminarraum 3", lecturer: "Tutorium"),
    ]

    public static let files: [File] = [
        File(id: "demo-skript", courseID: "demo-vorlesung", name: "Skript Kapitel 1 – Zahlensysteme.pdf", pages: [
            Page("Kapitel 1: Zahlensysteme", ["Dezimal-, Dual- und Hexadezimalsystem.", "Jede Zahl lässt sich als Summe von Potenzen der Basis schreiben.",
                                              "Beispiel: 13 = 1101 (dual) = D (hexadezimal)."]),
            Page("1.1 Umrechnung", ["Dezimal nach Dual: fortgesetzte Division durch 2, Reste von unten lesen.",
                                    "Dual nach Dezimal: Stellenwerte 1, 2, 4, 8, ... addieren.", "Übung: Rechne 42 ins Dualsystem um."]),
            Page("1.2 Zweierkomplement", ["Negative Zahlen: Bits invertieren und 1 addieren.", "Mit 8 Bit reicht der Bereich von -128 bis 127.",
                                          "Überlauf erkennen: Vorzeichen des Ergebnisses prüfen."]),
        ]),
        File(id: "demo-folien", courseID: "demo-vorlesung", name: "Folien Woche 1 – Einführung.pdf", pages: [
            Page("Grundlagen der Informatik", ["Willkommen zur Demo-Vorlesung.", "Organisatorisches, Literatur, Prüfung."]),
            Page("Was ist Informatik?", ["Wissenschaft der systematischen Verarbeitung von Information.", "Algorithmus, Daten, Programm."]),
            Page("Algorithmus", ["Eindeutige, endliche Handlungsvorschrift.", "Beispiel: Zähneputzen, Wegbeschreibung, Sortieren."]),
            Page("Nächste Woche", ["Zahlensysteme und Zweierkomplement.", "Bitte Übungsblatt 1 bearbeiten."]),
        ]),
        File(id: "demo-blatt", courseID: "demo-uebung", name: "Übungsblatt 1 – Zahlensysteme.pdf", pages: [
            Page("Übungsblatt 1", ["Aufgabe 1: Rechne 42, 100 und 255 ins Dualsystem um.", "Aufgabe 2: Welche Dezimalzahl ist 1011 0110 (dual)?",
                                   "Aufgabe 3: Bilde das Zweierkomplement von -37 mit 8 Bit."]),
            Page("Aufgabe 4 (Bonus)", ["Warum reicht ein Byte für Werte von 0 bis 255?", "Abgabe: nächste Woche vor der Übung."]),
        ]),
    ]

    /// Kennungen der Demo-Dateien (Kopien auf dem Geraet: PDF-Zwischenspeicher, Journal, Vorschaubilder)
    public static var fileIDs: [String] { files.map(\.id) }

    public static let deadlineID = "demo-abgabe-1"
    public static let announcementID = "demo-ankuendigung-1"

    // MARK: - PDF

    /// `pdf_bytes`: kleines gueltiges PDF (A4, Helvetica, WinAnsi) mit Ueberschrift und Zeilen je Seite; Byte fuer Byte
    /// wie Python (PDFKit und pypdf lesen den Text).
    public static func pdf(_ pages: [Page]) -> Data {
        var objs: [[UInt8]] = [[], []]                                 // 1 Katalog, 2 Seitenbaum (spaeter)
        let fontNo = 3
        objs.append(bytes("<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>"))
        var pageNos: [Int] = []
        for p in pages {
            var content = bytes("BT /F1 20 Tf 60 770 Td (") + escape(p.title) + bytes(") Tj ET\n")
            var y = 730
            for line in p.lines {
                content += bytes("BT /F1 12 Tf 60 \(y) Td (") + escape(line) + bytes(") Tj ET\n")
                y -= 22
            }
            content += bytes("BT /F1 9 Tf 60 40 Td (Studora Demo-Inhalt) Tj ET\n")
            objs.append(bytes("<</Length \(content.count)>>stream\n") + content + bytes("\nendstream"))
            let streamNo = objs.count
            objs.append(bytes("<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents \(streamNo) 0 R/Resources<</Font<</F1 \(fontNo) 0 R>>>>>>"))
            pageNos.append(objs.count)
        }
        objs[0] = bytes("<</Type/Catalog/Pages 2 0 R>>")
        objs[1] = bytes("<</Type/Pages/Kids[" + pageNos.map { "\($0) 0 R" }.joined(separator: " ") + "]/Count \(pageNos.count)>>")
        var out: [UInt8] = bytes("%PDF-1.4\n") + [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        var offsets: [Int] = []
        for (i, o) in objs.enumerated() {
            offsets.append(out.count)
            out += bytes("\(i + 1) 0 obj\n") + o + bytes("\nendobj\n")
        }
        let xref = out.count
        out += bytes("xref\n0 \(objs.count + 1)\n0000000000 65535 f \n")
        for off in offsets { out += bytes(BerlinClock.pad(off, 10) + " 00000 n \n") }
        out += bytes("trailer\n<</Size \(objs.count + 1)/Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n")
        return Data(out)
    }

    /// PDF einer Demo-Datei
    public static func pdf(_ file: File) -> Data { pdf(file.pages) }

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// `_esc`: Text in cp1252 ("replace": "?" fuer jedes nicht darstellbare Zeichen), dann Rueckstrich und Klammern
    /// maskiert
    static func escape(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for b in cp1252(s) {
            if b == 0x5C || b == 0x28 || b == 0x29 { out.append(0x5C) }
            out.append(b)
        }
        return out
    }

    /// `s.encode("cp1252", "replace")` je Unicode-Zeichen (ein zerlegter Umlaut sind zwei)
    static func cp1252(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { u in
            let v = u.value
            if v < 0x80 || (0xA0...0xFF).contains(v) { return UInt8(v) }
            return cp1252Extra[v] ?? 0x3F
        }
    }

    /// Zeichen auf 0x80...0x9F in cp1252 (0x81, 0x8D, 0x8F, 0x90, 0x9D sind dort nicht belegt)
    private static let cp1252Extra: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88,
        0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93,
        0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B,
        0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    // MARK: - Stand

    /// Demo an? Nur der Schalter in `settings` (`str(value) == "1"`), ohne die uebrigen Einstellungen zu lesen; fuer die
    /// App (Abgleich mit der Hochschule ruht, solange die Demo an ist)
    public static func isEnabled(_ c: SQLiteConnection) throws -> Bool {
        switch try c.scalar("SELECT value FROM settings WHERE key=?", [.text(settingKey)]) {
        case .text(let s)?: return s == "1"
        case .integer(let i)?: return i == 1
        default: return false                              // str(1.0) ist "1.0", NULL "None"
        }
    }

    /// `status(conn)`: an/aus und was da ist. Liest wie Python die Einstellungen (`get_settings`; kaputte Werte -> 500).
    public static func status(_ c: SQLiteConnection) throws -> [String: JSONValue] {
        _ = try LocalSettings.read(c)
        func count(_ sql: String, _ p: [SQLiteValue] = []) throws -> JSONValue { .number(Double(try c.scalar(sql, p)?.int ?? 0)) }
        return [
            "enabled": .bool(try isEnabled(c)),
            "files": try count("SELECT COUNT(*) FROM files WHERE id LIKE 'demo-%'"),
            "events": try count("SELECT COUNT(*) FROM course_events WHERE source='demo'"),
            "packages": try count("SELECT COUNT(*) FROM study_packages WHERE module_id IN (SELECT id FROM modules WHERE name=?)", [.text(moduleName)]),
            "module": .string(moduleName),
        ]
    }

    // MARK: - Entfernen

    /// Was `remove` entfernt hat (`{"files", "events", "packages"}` wie Python)
    public struct Removed: Sendable, Equatable {
        public var files = 0
        public var events = 0
        public var packages = 0

        public var json: JSONValue {
            ["files": .number(Double(files)), "events": .number(Double(events)), "packages": .number(Double(packages))]
        }
    }

    /// Module der Demo: das mit dem Namen der Demo oder eines der Demo-Kurse (auch umbenannt), solange kein eigener
    /// Kurs des Nutzers darin liegt
    static func moduleIDs(_ c: SQLiteConnection) throws -> [Int64] {
        try c.query("""
            SELECT m.id FROM modules m
            WHERE (m.name=? OR m.id IN (SELECT module_id FROM courses WHERE id LIKE 'demo-%' AND module_id IS NOT NULL))
              AND NOT EXISTS (SELECT 1 FROM courses k WHERE k.module_id=m.id AND k.id NOT LIKE 'demo-%')
            ORDER BY m.id
            """, [.text(moduleName)]).compactMap { $0[0].int64 }
    }

    private static func hasTable(_ c: SQLiteConnection, _ name: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(name)]) != nil
    }

    private static func list(_ ids: [Int64]) -> String { ids.isEmpty ? "NULL" : ids.map(String.init).joined(separator: ",") }

    /// `remove(conn)`: alle Demo-Daten entfernen (in einer Transaktion aufrufen). `files`: Dateiablage (nil: nur die
    /// Datenbank, Dateien bleiben liegen). Setzt den Schalter auf "0".
    @discardableResult
    public static func remove(_ c: SQLiteConnection, files: LocalFiles?) throws -> Removed {
        var n = Removed()
        // Dateien auf der Platte (samt Bildern der Notizen), dann alles, was an ihnen haengt
        let rows = try c.query("SELECT id, local_path FROM files WHERE id LIKE 'demo-%'")
        for r in rows {
            if let files, let id = r["id"]?.string {
                if let p = r["local_path"]?.string, !p.isEmpty { files.remove(stored: p) }
                files.remove(stored: files.assetsDirectory(fileID: id))
            }
            n.files += 1
        }
        for t in ["annotations", "annotation_versions", "analysis", "page_texts", "flashcards", "recordings"] {
            try c.execute("DELETE FROM \(t) WHERE file_id LIKE 'demo-%'")
        }
        if try hasTable(c, "file_versions") { try c.execute("DELETE FROM file_versions WHERE file_id LIKE 'demo-%'") }
        if try DueStore.hasTables(c) {
            try c.execute("DELETE FROM due_hits WHERE file_id LIKE 'demo-%' OR announcement_id LIKE 'demo-%' OR course_id LIKE 'demo-%'")
            try c.execute("DELETE FROM due_choices WHERE key LIKE 'demo-%'")
            try c.execute("DELETE FROM due_meta WHERE key LIKE 'unreadable:demo-%' OR key='input'")   // naechste Erkennung rechnet neu
        }
        // Lernpakete des Demo-Moduls mit Aufgaben und Verlauf, Aufgaben zu Demo-Dateien auch in eigenen Paketen
        let modules = try moduleIDs(c)
        let packages = try c.query("SELECT id FROM study_packages WHERE module_id IN (\(list(modules)))").compactMap { $0[0].int64 }
        n.packages = packages.count
        let tasks = try c.query("SELECT id FROM study_tasks WHERE package_id IN (\(list(packages))) OR file_id LIKE 'demo-%'").compactMap { $0[0].int64 }
        try c.execute("DELETE FROM task_history WHERE package_id IN (\(list(packages))) OR task_id IN (\(list(tasks)))")
        try c.execute("DELETE FROM study_tasks WHERE id IN (\(list(tasks)))")
        try c.execute("DELETE FROM study_packages WHERE id IN (\(list(packages)))")
        try c.execute("DELETE FROM files WHERE id LIKE 'demo-%'")
        // Termine (Ausnahmen und Notizen gehen ueber den Fremdschluessel mit)
        n.events = try c.scalar("SELECT COUNT(*) FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%'")?.int ?? 0
        try c.execute("DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%')")
        try c.execute("DELETE FROM event_notes WHERE event_id IN (SELECT id FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%')")
        try c.execute("DELETE FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%'")
        try c.execute("DELETE FROM deadlines WHERE source='demo'")
        try c.execute("DELETE FROM announcements WHERE source='demo'")
        try c.execute("DELETE FROM courses WHERE id LIKE 'demo-%'")
        // eigene Termine und Ordner im Demo-Modul bleiben, nur ohne Modul
        try c.execute("UPDATE course_events SET module_id=NULL WHERE module_id IN (\(list(modules)))")
        try c.execute("UPDATE folders SET module_id=NULL WHERE module_id IN (\(list(modules)))")
        try c.execute("DELETE FROM dismissed_tests WHERE module_id IN (\(list(modules)))")
        try c.execute("DELETE FROM modules WHERE id IN (\(list(modules)))")
        try LocalSettings.write(c, key: settingKey, value: .int("0"))
        if let files { removeFolderIfEmpty(files) }
        return n
    }

    /// Ordner der PDFs: bekannte Demo-Dateien (auch ohne Eintrag, z. B. nach einem abgebrochenen Anlegen) und der leere
    /// Ordner gehen
    static func removeFolderIfEmpty(_ files: LocalFiles) {
        for f in Self.files { files.remove(stored: files.demoDirectory + "/" + f.name) }
        guard let dir = files.url(stored: files.demoDirectory) else { return }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path), items.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Anlegen

    /// `install(conn)`: vorhandene Demo-Daten entfernen (frischer Stand), dann Modul, Kurse, PDFs (geschrieben), Termine,
    /// Lernpakete dieser Woche, Frist und Ankuendigung anlegen; Schalter "1". In einer Transaktion aufrufen.
    @discardableResult
    public static func install(_ c: SQLiteConnection, files: LocalFiles, clock: UniFlowClock) throws -> [String: JSONValue] {
        try remove(c, files: files)
        guard let today = BerlinClock.parseISODate(clock.today) else { throw LocalHTTPError(status: 500, message: "Ungültiges Datum") }
        let now = clock.nowISO
        try c.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                      [.text(moduleName), .null, .text(color), .integer(99), .text(now)])
        let moduleID = c.lastInsertRowID
        for k in courses {
            try c.execute("""
                INSERT INTO courses(id, title, number, semester, subject, kind, active, test_minutes, created_at, module_id)
                VALUES (?,?,?,?,?,?,1,60,?,?)
                """, [.text(k.id), .text(k.title), .text(k.number), .null, .text(subject), .text(k.kind), .text(now), .integer(moduleID)])
        }
        // Aenderungsdatum: Mitternacht drei Tage vor heute in Berlin
        let chdate = BerlinClock.utcSeconds(day: today - 3, minutes: 0)
        for f in Self.files {
            let data = pdf(f)
            let stored = files.demoDirectory + "/" + f.name
            _ = try files.write(data, to: stored)
            let stem = LocalFileResponse.suffix(f.name).map { String(f.name.dropLast($0.count)) } ?? f.name
            try c.execute("""
                INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status,
                                  seen_by_user, kind, title, page_count, content_sha256)
                VALUES (?,?,?,?,'application/pdf','Prof. Demo',?,'',?,?,?,'neu',0,'pdf',?,?,?)
                """, [.text(f.id), .text(f.courseID), .text(f.name), .integer(Int64(data.count)), .integer(Int64(chdate)), .text(stored),
                      .text(now), .text(now), .text(stem), .integer(Int64(f.pages.count)), .text(SolutionSHA256.hex(data))])
        }
        for e in events {
            try c.execute("""
                INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, attend, source, color, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,'weekly',1,'demo',?,?)
                """, [.integer(moduleID), .text(e.courseID), .text(e.title), .text(e.kind), .integer(Int64(e.weekday)), .text(e.start), .text(e.end),
                      .text(e.room), .text(e.lecturer), .text(color), .text(now)])
        }
        // Lernpakete dieser Woche: Montag, Mittwoch, Freitag
        let monday = today - BerlinClock.weekday(today)
        let plan: [(day: Int, title: String, tasks: [(type: String, file: String, title: String, minutes: Int)])] = [
            (monday, "Vorlesung nacharbeiten", [("vorlesung", "demo-folien", "Folien Woche 1 durchgehen", 30), ("vorlesung", "demo-skript", "Skript Kapitel 1 lesen", 45)]),
            (monday + 2, "Übungsblatt 1", [("uebung", "demo-blatt", "Aufgaben 1–3 rechnen", 60)]),
            (monday + 4, "Wiederholung", [("wiederholung", "demo-skript", "Zweierkomplement wiederholen", 25)]),
        ]
        for (i, p) in plan.enumerated() {
            try c.execute("""
                INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at)
                VALUES (?,?,?,?,1,?,'geplant',?,0,?)
                """, [.text(BerlinClock.isoDate(p.day)), .integer(moduleID), .text(subject), .text(p.title),
                      .integer(Int64(p.tasks.reduce(0) { $0 + $1.minutes })), .integer(Int64(i)), .text(now)])
            let packageID = c.lastInsertRowID
            for (j, t) in p.tasks.enumerated() {
                try c.execute("INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,'geplant',?)",
                              [.integer(packageID), .text(t.type), .text(t.file), .text(t.title), .integer(Int64(j)), .integer(Int64(t.minutes)), .text(now)])
            }
        }
        // Abgabe am Mittwoch der naechsten Woche, 13:45
        try c.execute("""
            INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,0,?)
            """, [.text(deadlineID), .text(source), .text("demo-uebung"), .text("Übungsblatt 1 abgeben"), .text("Übungsblatt 1 abgeben (Demo)"),
                  .text("abgabe"), .text("assign"), .text(BerlinClock.isoDate(monday + 9) + "T13:45"), .text(""), .text(now)])
        // Raumwechsel am Montag der naechsten Woche
        let annDay = monday + 7
        let annISO = BerlinClock.isoDate(annDay)
        let dm = String(annISO.suffix(2)) + "." + String(annISO.dropFirst(5).prefix(2)) + "."
        try c.execute("""
            INSERT INTO announcements(id, source, course_id, title, text, author, posted_at, url, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(announcementID), .text(source), .text("demo-vorlesung"), .text("Raumwechsel nächste Woche"),
                  .text("Die Vorlesung am \(dm) findet im Hörsaal B statt. Bitte Übungsblatt 1 vorher bearbeiten."), .text("Prof. Demo"),
                  .text(now), .text(""),
                  .text("[{\"date\": \"\(annISO)\", \"time\": \"10:00\", \"kind\": \"raumwechsel\", \"snippet\": \"Vorlesung im Hörsaal B\"}]"), .text(now)])
        try LocalSettings.write(c, key: settingKey, value: .int("1"))
        if try DueStore.hasTables(c) { try c.execute("DELETE FROM due_meta WHERE key='input'") }     // naechste Erkennung sieht die Demo
        return try status(c)
    }
}
