import Foundation

/// Demo-Inhalte fuer die App-Pruefung ohne Hochschulkonto und zum Ausprobieren, wie app/demo.py (dieselben Inhalte,
/// Kennungen und Datumslogik; Vergleich mit Python: fixtures/demo/demo.json, tools/gen-demo-fixture.py).
///
/// Ein Demo-Modul "Grundlagen der Informatik" mit Vorlesung und Uebung: drei hier erzeugte PDFs (Skript, Folien,
/// Uebungsblatt; keine fremden Inhalte), Stundenplan-Termine (Mo/Mi/Do, woechentlich), drei Lernpakete dieser Woche
/// (relativ zur Uhr des Backends), fuenf Karteikarten (heute faellig, fuer "Frei üben"), eine Abgabefrist und eine
/// Ankuendigung mit Raumwechsel. Alles traegt die Kennung
/// "demo-" bzw. source = "demo".
///
/// Auf dem Geraet lebt die Demo in der Datenbank des offenen Containers (Apple-Nutzer, Hochschule), die PDFs unter
/// `<Datenordner>/files/Demo`. `remove` entfernt rueckstandslos und mehr als Python (dort bleiben Notiz-Versionen,
/// eigene Karteikarten zu Demo-Dateien und eigene Termine im Demo-Modul stehen): Dateien samt Bildern der Notizen, Notizen und ihre Versionen,
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

    /// Karteikarten (`FLASHCARDS`): Datei, Frage, Antwort
    public static let flashcards: [(file: String, question: String, answer: String)] = [
        ("demo-skript", "Wie lautet 13 im Dualsystem?", "1101"),
        ("demo-skript", "Wie rechnest du eine Dezimalzahl ins Dualsystem um?", "Fortgesetzt durch 2 teilen und die Reste von unten nach oben lesen."),
        ("demo-skript", "Wie bildest du das Zweierkomplement einer negativen Zahl?", "Den Betrag dual schreiben, alle Bits invertieren und 1 addieren."),
        ("demo-skript", "Welcher Wertebereich passt in 8 Bit im Zweierkomplement?", "-128 bis 127"),
        ("demo-folien", "Was ist ein Algorithmus?", "Eine eindeutige, endliche Handlungsvorschrift."),
    ]

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
            content += bytes("BT /F1 9 Tf 60 40 Td (StudiNow Demo-Inhalt) Tj ET\n")
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
        for t in ["annotations", "annotation_versions", "analysis", "page_texts", "flashcards", "flashcard_stacks", "recordings"] {
            try c.execute("DELETE FROM \(t) WHERE file_id LIKE 'demo-%'")
        }
        if try hasTable(c, "file_versions") { try c.execute("DELETE FROM file_versions WHERE file_id LIKE 'demo-%'") }
        if try hasTable(c, "page_ocr") { try c.execute("DELETE FROM page_ocr WHERE file_id LIKE 'demo-%'") }
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
        for card in flashcards {
            try c.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due) VALUES (?,?,?,?,?,1,?)",
                          [.text(card.file), .text(subject), .text(card.question), .text(card.answer), .text(now), .text(BerlinClock.isoDate(today))])
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

// MARK: - Nur fuer die App-Store-Bilder

/// Zusaetzliche Demo-Inhalte nur fuer die Store-Bilder (`StoreScreenshotTests`, `IPhoneStoreScreenshotTests`): ein
/// erfundener Studienverlauf (Katalog "Informatik B.Sc.", Studienbeginn WiSe 25/26, Leistungen der ersten beiden
/// Semester, daraus die Karte "Prüfungsanmeldung") und Nachrichten im Posteingang. `install` legt nichts davon an; die
/// App ruft `installStoreExtras` nie auf (keine Wirkung auf die Demo der Pruefer oder den normalen Betrieb). Alle Namen
/// sind Rollen oder erfunden, keine echte Person, kein Hochschul-Logo.
extension DemoContent {
    /// Kennung des erfundenen Katalogs (`study_catalogs.origin`)
    public static let storeOrigin = "demo-store"
    /// Studiengang und Pruefungsordnung des Katalogs
    public static let storeProgram = "Informatik"
    public static let storePO = "2024"
    /// QIS-Abschluss der Leistungen (wie im Notenspiegel)
    static let storeAbschluss = "Informatik (PO-Version 2024)"

    /// Module des Katalogs: id, Titel, Fachsemester, LP, Art, Pruefungsform
    static let storeModules: [(id: String, title: String, sem: Int, lp: Int, kind: String, exam: String)] = [
        ("programmieren-1", "Programmieren I", 1, 8, "pflicht", "Klausur 90 min"),
        ("mathe-1", "Mathematik für Informatik I", 1, 10, "pflicht", "Klausur 120 min"),
        ("logik", "Logik und diskrete Strukturen", 1, 5, "pflicht", "Klausur 90 min"),
        ("rechnerarchitektur", "Grundlagen der Rechnerarchitektur", 1, 5, "pflicht", "Klausur 90 min"),
        ("programmieren-2", "Programmieren II", 2, 8, "pflicht", "Klausur 90 min"),
        ("mathe-2", "Mathematik für Informatik II", 2, 10, "pflicht", "Klausur 120 min"),
        ("algorithmen", "Algorithmen und Datenstrukturen", 2, 8, "pflicht", "Klausur 120 min"),
        ("technische-informatik", "Technische Informatik", 2, 5, "pflicht", "Klausur 90 min"),
        ("theoretische-informatik", "Theoretische Informatik", 3, 8, "pflicht", "Klausur 120 min"),
        ("datenbanken", "Datenbanksysteme", 3, 5, "pflicht", "Klausur 90 min"),
        ("betriebssysteme", "Betriebssysteme", 3, 5, "pflicht", "Klausur 90 min"),
        ("stochastik", "Stochastik für Informatik", 3, 5, "pflicht", "Klausur 90 min"),
        ("softwaretechnik", "Softwaretechnik", 4, 8, "pflicht", "Klausur 90 min"),
        ("rechnernetze", "Rechnernetze", 4, 5, "pflicht", "Klausur 90 min"),
        ("software-projekt", "Software-Projekt", 4, 10, "pflicht", "Projektarbeit"),
        ("it-sicherheit", "IT-Sicherheit", 4, 5, "pflicht", "Klausur 90 min"),
        ("verteilte-systeme", "Verteilte Systeme", 5, 5, "pflicht", "Mündliche Prüfung"),
        ("maschinelles-lernen", "Maschinelles Lernen", 5, 5, "wahlpflicht", "Klausur 90 min"),
        ("computergrafik", "Computergrafik", 5, 5, "wahlpflicht", "Klausur 90 min"),
        ("seminar", "Seminar Informatik", 5, 5, "pflicht", "Referat"),
        ("schluesselkompetenzen", "Schlüsselkompetenzen", 5, 10, "pflicht", "keine"),
        ("bachelorarbeit", "Bachelorarbeit", 6, 15, "abschluss", "Abschlussarbeit"),
    ]

    /// Leistungen: Modul, Semester, Note, Status (bestanden, nicht bestanden, AN = angemeldet)
    static let storeGrades: [(id: String, semester: String, note: String?, status: String)] = [
        ("programmieren-1", "WiSe 25/26", "1,7", "bestanden"),
        ("mathe-1", "WiSe 25/26", "2,3", "bestanden"),
        ("logik", "WiSe 25/26", "2,0", "bestanden"),
        ("rechnerarchitektur", "WiSe 25/26", "1,3", "bestanden"),
        ("programmieren-2", "SoSe 26", "1,7", "bestanden"),
        ("mathe-2", "SoSe 26", "5,0", "nicht bestanden"),
        ("algorithmen", "SoSe 26", "2,0", "bestanden"),
        ("technische-informatik", "SoSe 26", "2,7", "bestanden"),
        ("datenbanken", "WiSe 26/27", nil, "AN"),
    ]

    /// Katalog als JSON (Form wie `packages/shared-contracts`, Fixture der Tests)
    public static var storeCatalog: JSONValue {
        let modules: [JSONValue] = storeModules.map { m in
            ["id": .string(m.id), "title": .string(m.title), "code": .null, "area": .string(m.kind == "wahlpflicht" ? "wp" : "p"),
             "kind": .string(m.kind), "lp": .number(Double(m.lp)), "semester": .number(Double(m.sem)),
             "turnus": .string(m.sem % 2 == 1 ? "WS" : "SS"), "exam": .string(m.exam), "coursework": .null, "prerequisites": [],
             "language": "deutsch", "workload_h": .number(Double(m.lp * 30)), "source_page": 1]
        }
        return ["v": 1, "university": "luh", "program": .string(storeProgram), "degree": "B.Sc.", "po": .string(storePO),
                "catalog_term": "WS 2026/27", "code": "DEMO-INF-BSC", "regular_semesters": 6, "total_lp": 180,
                "source": ["url": "", "fetched_at": "2026-10-01", "sha256": "demo"],
                "areas": [["id": "p", "name": "Pflichtbereich", "lp_required": 160, "kind": "pflicht"],
                          ["id": "wp", "name": "Wahlpflichtbereich", "lp_required": 10, "kind": "wahlpflicht"]],
                "modules": .array(modules)]
    }

    /// Nachrichten im Posteingang: Kennung, Absender (Rolle), Betreff, Text, Tage vor heute, Uhrzeit, erkannter Tag
    /// (Tage ab dem Montag dieser Woche, Uhrzeit, Art) oder nil; Frist und Raumwechsel wie die Demo (`install`)
    static let storeMessages: [(id: String, sender: String, subject: String, text: String, ago: Int, time: String,
                                date: (days: Int, time: String, kind: String)?)] = [
        ("demo-msg-1", "Tutorium", "Fragen zu Übungsblatt 1",
         "Hallo zusammen,\n\nim Tutorium am Mittwoch rechnen wir Aufgabe 2 und 3 von Übungsblatt 1 gemeinsam durch. Bringt eure Lösungsansätze mit – auch halbe.\n\nDie Abgabe bleibt nächste Woche vor der Übung.\n\nViele Grüße\nEuer Tutorium",
         0, "08:15", (9, "13:45", "frist")),
        ("demo-msg-2", "Lehrende", "Raumwechsel nächste Woche",
         "Liebe Studierende,\n\ndie Vorlesung am Montag findet ausnahmsweise im Hörsaal B statt. Bitte bearbeitet Übungsblatt 1 vorher.\n\nBeste Grüße",
         1, "16:40", (7, "10:00", "verlegt")),
        ("demo-msg-3", "Lehrende", "Folien Woche 1 hochgeladen",
         "Die Folien zur Einführung liegen im Dateibereich. Das Skript zu Kapitel 1 folgt bis Donnerstag.", 3, "12:05", nil),
        ("demo-msg-4", "Studienberatung", "Sprechstunde zur Prüfungsanmeldung",
         "Fragen zur Prüfungsanmeldung? Die offene Sprechstunde der Studienberatung ist dienstags von 10 bis 12 Uhr.", 6, "09:30", nil),
    ]

    /// `sent_at` wie von Stud.IP (Ortszeit Berlin mit Versatz), `days` relativ zu heute
    static func storeSentAt(day: Int, time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let minutes = (parts.first ?? 0) * 60 + (parts.count > 1 ? parts[1] : 0)
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(day: day, minutes: minutes))))
    }

    /// Studienverlauf (Katalog, Einstellungen, Leistungen) und Nachrichten fuer die Store-Bilder anlegen; nach `install`
    /// und in einer Transaktion aufrufen. Nur Tests.
    public static func installStoreExtras(_ c: SQLiteConnection, clock: UniFlowClock) throws {
        guard let today = BerlinClock.parseISODate(clock.today) else { throw LocalHTTPError(status: 500, message: "Ungültiges Datum") }
        let now = clock.nowISO
        let monday = today - BerlinClock.weekday(today)
        _ = try StudyCatalogStore.store(c, payload: String(decoding: storeCatalog.serialized(), as: UTF8.self), texts: nil,
                                        origin: storeOrigin, now: now)
        try LocalSettings.write(c, key: StudyPlanEngine.settingsKey,
                                value: .object([PyJSON.Member("po", .string(storePO)), PyJSON.Member("start_term", .string("WiSe 25/26")),
                                                PyJSON.Member("electives", .array([]))]))
        let titles = Dictionary(uniqueKeysWithValues: storeModules.map { ($0.id, ($0.title, $0.lp)) })
        try UniStore.storeGrades(c, storeGrades.compactMap { g in
            guard let (title, lp) = titles[g.id] else { return nil }
            return QISGrade(pruefungsnr: "demo-\(g.id)", text: title, semester: g.semester, note: g.note, status: g.status,
                            credits: g.status == "bestanden" ? String(lp) : nil, versuch: "1", abschluss: storeAbschluss)
        }, now: now)
        try c.executeScript(StudIPExtras.messagesTable)
        for m in storeMessages {
            var dates: [JSONValue] = []
            if let d = m.date { dates.append(["date": .string(BerlinClock.isoDate(monday + d.days)), "time": .string(d.time), "kind": .string(d.kind)]) }
            try c.execute("""
                INSERT OR REPLACE INTO studip_messages(id, sender, subject, preview, sent_at, url, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?)
                """, [.text(m.id), .text(m.sender), .text(m.subject), .text(m.text), .text(storeSentAt(day: today - m.ago, time: m.time)),
                      .text(""), .text(JSONValue.array(dates).jsonString()), .text(now)])
        }
    }
}
