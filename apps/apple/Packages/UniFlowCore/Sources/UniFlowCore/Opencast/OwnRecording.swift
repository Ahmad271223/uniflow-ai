import Foundation

// Eigene Vorlesungsaufnahmen (04.11.2026, docs/VORLESUNG-AUFNEHMEN.md): das iPad nimmt die Vorlesung auf, erkennt die
// Sprache auf dem Geraet und legt beides neben die Opencast-Aufzeichnungen des Moduls. Hier der plattformunabhaengige
// Teil: Abschnittsbildung aus Erkennungsergebnissen, Textform des Transkripts, Vorschlag des laufenden Termins,
// Ablage in der lokalen Datenbank des Containers (Tabelle nur auf dem Geraet, bei Bedarf angelegt wie
// opencast_videos). Aufnahme (m4a) und Transkript (txt) liegen unter `recordings/eigene/` im Container; an die KI geht
// nur Text und nur nach dem Antippen, nie Audio.

/// Ein Abschnitt des Transkripts mit Zeitmarken (Sekunden ab Aufnahmebeginn).
public struct TranscriptSection: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var json: JSONValue { ["start": .number(start), "end": .number(end), "text": .string(text)] }

    /// aus `{start, end, text}`; nil, wenn Zahlen oder Text fehlen
    public init?(json: JSONValue) {
        guard let s = json["start"]?.double, let e = json["end"]?.double, let t = json["text"]?.string,
              s.isFinite, e.isFinite, s >= 0 else { return nil }
        self.init(start: s, end: max(s, e), text: t)
    }
}

/// Ein erkanntes Stueck (Wort oder Satz) wie `SFTranscriptionSegment`: Beginn und Dauer in Sekunden, Text.
public struct TranscriptSegment: Equatable, Sendable {
    public let start: Double
    public let duration: Double
    public let text: String

    public init(start: Double, duration: Double, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }

    public var end: Double { start + max(0, duration) }
}

/// Abschnitte aus Erkennungsergebnissen und ihre Textform.
public enum TranscriptSections {
    /// Ziel-Laenge eines Abschnitts: nach 60 s schliesst der Abschnitt an der naechsten Segmentgrenze
    public static let targetSeconds = 60.0
    /// ab dieser Laenge schliesst eine Sprechpause den Abschnitt
    public static let minSeconds = 20.0
    /// Sprechpause (Luecke zwischen zwei Segmenten) in Sekunden
    public static let pauseGap = 1.5

    /// Abschnitte aus Segmenten (Reihenfolge nach Beginn; leere Segmente zaehlen nicht). `offset` wird auf alle
    /// Zeiten addiert (Erkennung in mehreren Anlaeufen: jeder Anlauf zaehlt ab seinem Start).
    public static func build(_ segments: [TranscriptSegment], offset: Double = 0, target: Double = targetSeconds,
                             minimum: Double = minSeconds, pause: Double = pauseGap) -> [TranscriptSection] {
        let segs = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.start.isFinite && $0.start >= 0 }
            .sorted { $0.start < $1.start }
        var out: [TranscriptSection] = []
        var words: [String] = []
        var sectionStart = 0.0, sectionEnd = 0.0
        func close() {
            let text = words.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !text.isEmpty { out.append(TranscriptSection(start: sectionStart + offset, end: sectionEnd + offset, text: text)) }
            words = []
        }
        for s in segs {
            if !words.isEmpty {
                let elapsed = s.start - sectionStart
                let gap = s.start - sectionEnd
                if elapsed >= target || (gap >= pause && elapsed >= minimum) { close() }
            }
            if words.isEmpty { sectionStart = s.start; sectionEnd = s.end }
            words.append(s.text)
            sectionEnd = max(sectionEnd, s.end)
        }
        close()
        return out
    }

    /// "03:05", ab einer Stunde "1:03:05"
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Textdatei neben der Aufnahme: je Abschnitt eine Zeile `[mm:ss] Text`, Leerzeile dazwischen
    public static func format(_ sections: [TranscriptSection]) -> String {
        sections.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n\n") + (sections.isEmpty ? "" : "\n")
    }

    /// Textform zurueck in Abschnitte (Ende = Beginn des naechsten; der letzte endet bei `duration`, sonst an seinem Beginn)
    public static func parse(_ text: String, duration: Double? = nil) -> [TranscriptSection] {
        var starts: [(Double, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = line[line.index(after: line.startIndex)..<close]
            let parts = stamp.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 || parts.count == 3, parts.count == stamp.split(separator: ":").count else { continue }
            let secs = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1]
            starts.append((Double(secs), line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)))
        }
        return starts.enumerated().map { i, s in
            let end = i + 1 < starts.count ? starts[i + 1].0 : max(s.0, duration ?? s.0)
            return TranscriptSection(start: s.0, end: end, text: s.1)
        }
    }

    /// Abschnitte als JSON-Liste (Spalte `transcript`)
    public static func json(_ sections: [TranscriptSection]) -> JSONValue { .array(sections.map(\.json)) }

    /// JSON-Liste zurueck; nil, wenn ein Eintrag keine Form hat (422 im Endpunkt)
    public static func sections(_ value: JSONValue?) -> [TranscriptSection]? {
        guard let list = value?.array else { return nil }
        var out: [TranscriptSection] = []
        for v in list {
            guard let s = TranscriptSection(json: v) else { return nil }
            out.append(s)
        }
        return out
    }

    /// Ganzer Text fuer Suche und KI (Abschnitte mit Zeitmarke, ohne Leerzeilen)
    public static func plainText(_ sections: [TranscriptSection]) -> String {
        sections.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    /// Zeichen, die der Tutor-Prompt vom Seiteninhalt hoechstens mitnimmt (`AIPrompts.tutor`, head 9000)
    public static let promptChars = 9000

    /// Teile fuer die KI: aufeinanderfolgende Abschnitte, deren Text zusammen in den Prompt passt (ein zu langer
    /// Abschnitt bildet allein einen Teil und wird dort gekuerzt). Leer ohne Abschnitte.
    public static func chunks(_ sections: [TranscriptSection], maxChars: Int = promptChars) -> [[TranscriptSection]] {
        var out: [[TranscriptSection]] = []
        var current: [TranscriptSection] = []
        var length = 0
        for s in sections {
            let n = s.text.count + 10
            if !current.isEmpty, length + n > maxChars {
                out.append(current)
                current = []
                length = 0
            }
            current.append(s)
            length += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Vorschlag des Termins zu einer Aufnahme aus den Terminen des Tages (`LocalTimetable.occurrences`).
public enum RecordingEventSuggestion {
    /// Minuten vor Beginn und nach Ende, in denen ein Termin noch als "laufend" gilt
    public static let toleranceMinutes = 15

    /// "HH:MM" -> Minuten seit Mitternacht
    static func minutes(_ v: JSONValue?) -> Int? {
        guard let s = v?.string else { return nil }
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    /// Der Termin, der um `minutesOfDay` laeuft (mit Toleranz): bei mehreren der mit dem naechsten Beginn. Abgewaehlte
    /// (nicht_teilnahme), ausgefallene und verschobene Termine zaehlen nicht. nil ohne laufenden Termin.
    public static func current(_ occurrences: [JSONValue], minutesOfDay: Int, tolerance: Int = toleranceMinutes) -> JSONValue? {
        candidates(occurrences).filter { o in
            guard let s = minutes(o["start"]), let e = minutes(o["end"]) else { return false }
            return s - tolerance <= minutesOfDay && minutesOfDay <= e + tolerance
        }
        .min { abs((minutes($0["start"]) ?? 0) - minutesOfDay) < abs((minutes($1["start"]) ?? 0) - minutesOfDay) }
    }

    /// Termine des Tages, die als Zuordnung in Frage kommen (Auswahl, wenn keiner laeuft), nach Beginn
    public static func candidates(_ occurrences: [JSONValue]) -> [JSONValue] {
        occurrences.filter { o in
            let status = o["status"]?.string ?? "teilnahme"
            return status != "nicht_teilnahme" && status != "ausfall" && status != "verschoben" && minutes(o["start"]) != nil
        }
        .sorted { (minutes($0["start"]) ?? 0) < (minutes($1["start"]) ?? 0) }
    }
}

/// Ordner und Dateinamen eigener Aufnahmen, relativ zum Container
public enum OwnRecordingFiles {
    public static let folder = "recordings/eigene"

    /// Kennung aus `LocalContext.newHex` (32 Hex-Zeichen); andere Kennungen werden auf sichere Zeichen reduziert
    static func safe(_ id: String) -> String { StudIPImport.safeFileName(id) }

    public static func audioPath(_ id: String) -> String { folder + "/" + safe(id) + ".m4a" }
    public static func transcriptPath(_ id: String) -> String { folder + "/" + safe(id) + ".txt" }
}

/// Ablage eigener Aufnahmen in der lokalen Datenbank (Tabelle nur auf dem Geraet).
public enum OwnRecordingStore {
    public static let statuses: Set<String> = ["none", "running", "partial", "done", "failed", "unavailable"]

    static let tables = """
        CREATE TABLE IF NOT EXISTS own_recordings (
            id TEXT PRIMARY KEY,                     -- 32 Hex-Zeichen (LocalContext.newHex)
            module_id INTEGER,
            course_id TEXT,
            title TEXT NOT NULL,
            event_title TEXT,                        -- Termin aus dem Stundenplan (Titel), zu dem aufgenommen wurde
            event_id INTEGER,
            recorded_at TEXT NOT NULL,               -- Ortszeit YYYY-MM-DDTHH:MM:SS (Beginn)
            duration REAL,                           -- Sekunden
            audio_path TEXT,                         -- m4a relativ zum Container
            transcript_path TEXT,                    -- txt relativ zum Container
            transcript TEXT,                         -- JSON-Liste der Abschnitte [{start, end, text}]
            transcript_status TEXT NOT NULL DEFAULT 'none',  -- none | running | partial | done | failed | unavailable
            language TEXT,                           -- de-DE | en-US
            created_at TEXT,
            updated_at TEXT
        );
        """

    public static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(tables) }

    static func tableExists(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='own_recordings'") != nil
    }

    static let select = "SELECT r.*, m.name AS module_name, m.color AS module_color FROM own_recordings r LEFT JOIN modules m ON m.id=r.module_id"

    /// Zeile in Antwortform: Abschnitte als Liste, `sections` gezaehlt
    static func row(_ r: [String: JSONValue]) -> JSONValue {
        var o = r
        let sections = r["transcript"]?.string.flatMap { try? JSONValue.parse($0) }.flatMap(TranscriptSections.sections) ?? []
        o["transcript"] = TranscriptSections.json(sections)
        o["sections"] = .number(Double(sections.count))
        return .object(o)
    }

    public static func list(_ c: SQLiteConnection, moduleID: Int? = nil) throws -> [JSONValue] {
        guard try tableExists(c) else { return [] }
        if let moduleID {
            return try c.rows(select + " WHERE r.module_id=? ORDER BY r.recorded_at DESC, r.id", [.integer(Int64(moduleID))]).map(row)
        }
        return try c.rows(select + " ORDER BY r.recorded_at DESC, r.id").map(row)
    }

    public static func get(_ c: SQLiteConnection, id: String) throws -> JSONValue? {
        guard try tableExists(c) else { return nil }
        return try c.rows(select + " WHERE r.id=?", [.text(id)]).first.map(row)
    }

    /// Spalten, die PATCH aendern darf (Werte schon geprueft)
    public static let patchable: Set<String> = ["module_id", "course_id", "title", "event_title", "event_id", "duration",
                                                "transcript", "transcript_status", "transcript_path", "language"]

    public static func insert(_ c: SQLiteConnection, id: String, values: [String: SQLiteValue], now: String) throws {
        try ensureTables(c)
        var cols = ["id", "created_at", "updated_at"], params: [SQLiteValue] = [.text(id), .text(now), .text(now)]
        for (k, v) in values.sorted(by: { $0.key < $1.key }) where k != "id" {
            cols.append(k)
            params.append(v)
        }
        let marks = Array(repeating: "?", count: cols.count).joined(separator: ",")
        try c.execute("INSERT INTO own_recordings(\(cols.joined(separator: ","))) VALUES (\(marks))", params)
    }

    /// Felder aendern; false, wenn es die Aufnahme nicht gibt
    public static func update(_ c: SQLiteConnection, id: String, values: [String: SQLiteValue], now: String) throws -> Bool {
        guard try tableExists(c) else { return false }
        var sets = ["updated_at=?"], params: [SQLiteValue] = [.text(now)]
        for (k, v) in values.sorted(by: { $0.key < $1.key }) where patchable.contains(k) {
            sets.append("\(k)=?")
            params.append(v)
        }
        params.append(.text(id))
        try c.execute("UPDATE own_recordings SET \(sets.joined(separator: ", ")) WHERE id=?", params)
        return c.changes > 0
    }

    /// Zeile loeschen; Rueckgabe: Pfade der Dateien, die dazu gehoerten (nil ohne Zeile)
    public static func delete(_ c: SQLiteConnection, id: String) throws -> [String]? {
        guard try tableExists(c), let r = try c.queryOne("SELECT audio_path, transcript_path FROM own_recordings WHERE id=?", [.text(id)]) else { return nil }
        try c.execute("DELETE FROM own_recordings WHERE id=?", [.text(id)])
        return [r["audio_path"]?.string, r["transcript_path"]?.string].compactMap { $0 }
    }

    /// Treffer in Transkripten fuer `/api/search` (Suchform wie bei den Seitentexten): je Aufnahme hoechstens ein Treffer
    /// mit dem ersten passenden Abschnitt und Ausschnitt; `q` schon klein geschrieben
    public static func search(_ c: SQLiteConnection, _ q: String, limit: Int = 10) throws -> [JSONValue] {
        guard try tableExists(c), !q.isEmpty else { return [] }
        let form = ScriptSearch.searchForm(q)
        var out: [JSONValue] = []
        for r in try c.rows(select + " WHERE r.transcript IS NOT NULL ORDER BY r.recorded_at DESC") {
            let sections = r["transcript"]?.string.flatMap { try? JSONValue.parse($0) }.flatMap(TranscriptSections.sections) ?? []
            let titleHit = ScriptSearch.contains(q, r["title"]?.string, r["event_title"]?.string)
            let hit = sections.first { ScriptSearch.searchForm($0.text).contains(form) }
            guard titleHit || hit != nil else { continue }
            let text = hit?.text ?? sections.first?.text ?? ""
            out.append(["id": r["id"] ?? .null, "title": r["title"] ?? .null, "module_id": r["module_id"] ?? .null,
                        "module_name": r["module_name"] ?? .null, "recorded_at": r["recorded_at"] ?? .null,
                        "start": .number(hit?.start ?? 0),
                        "snippet": .string(ScriptSearch.snippet(ScriptSearch.normalize(text), terms: [q]))])
            if out.count >= limit { break }
        }
        return out
    }
}
