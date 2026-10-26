import Foundation

// Opencast-Aufzeichnungen in der lokalen Datenbank des Geraets (docs/IPAD-OHNE-PC.md, Abschnitt Aufzeichnungen):
// Abruf im Stud.IP-Abgleich (nur die Listen, nie die Videos), Ablage in zwei Tabellen, die es nur auf dem Geraet gibt
// und die wie studip_cycle_dates erst bei Bedarf angelegt werden. Damit liegen die Aufzeichnungen dort, wo die
// Dateien des Abgleichs liegen (eine Datenbank je Hochschule bzw. Container).
//
// Geordnet wird ueber die vorhandene Einordnung: Fach = Modul des Kurses (`courses.module_id`, `ensure_modules`),
// Lehrwoche = derselbe Block wie im Moduldetail (`LocalModules.week` mit `StudyWeeks`, `StudyClassify`), damit Blatt,
// Folien und Video einer Woche zusammenstehen. Eine passende Aufzeichnung zu einem Dokument, einer Aufgabe oder einem
// Lernpaket gibt es nur bei sicherem Treffer: gleiches Fach UND gleiche Lehrwoche oder ein eindeutiges Thema.
// Abruf und Speichern sind getrennt: erst das Netz, dann kurz schreiben (kein await in der Transaktion).

/// Gespeicherter Stand eines Kurses.
public struct OpencastCourseState: Sendable, Equatable {
    /// "available" (Reiter vorhanden) oder "none" (Kurs ohne Opencast)
    public let status: String
    /// Unix-Zeit der letzten Pruefung
    public let checkedAt: Int

    public init(status: String, checkedAt: Int) {
        self.status = status
        self.checkedAt = checkedAt
    }
}

/// Was der Abruf geladen hat. Fehlt ein Kurs in `listings`, bleibt sein gespeicherter Stand.
public struct OpencastFetch: Sendable {
    public var courses: [StudIPCourse]
    /// gelesene Kurse: Videos (auch leer) oder kein Opencast
    public var listings: [String: OpencastListing] = [:]
    /// Kurse ohne Opencast, die noch nicht wieder geprueft werden (`OpencastStore.noOpencastRecheck`)
    public var skipped: [String] = []
    /// Kurse, deren Seite nicht lesbar war oder nichts Eindeutiges sagte
    public var failed: [String] = []
    /// Anmeldung abgelaufen (der Rest wurde nicht mehr abgefragt)
    public var sessionExpired = false
    /// Netz- oder Zeitlimitfehler: der Rest wurde nicht mehr abgefragt (steht in `failed`)
    public var unreachable = false
    /// Zeitpunkt des Abrufs (Unix)
    public var checkedAt: Int

    public init(courses: [StudIPCourse], checkedAt: Int) {
        self.courses = courses
        self.checkedAt = checkedAt
    }
}

/// Ergebnis des Speicherns (fuer die Zusammenfassung des Abgleichs).
public struct OpencastStoreResult: Sendable, Equatable {
    /// Videos, die es vorher nicht gab
    public let newVideos: Int
    /// Videos der in diesem Lauf gelesenen Kurse
    public let videos: Int

    public init(newVideos: Int, videos: Int) {
        self.newVideos = newVideos
        self.videos = videos
    }
}

/// Eine Aufzeichnung mit Kurs, Modul und Block, wie die Oberflaeche sie zeigt.
public struct OpencastEntry: Sendable, Equatable, Identifiable {
    public let courseID: String
    public let courseTitle: String
    public let moduleID: Int?
    public let video: OpencastVideo
    /// Block wie im Moduldetail: Lehrwoche ab 1, 0 vor Vorlesungsbeginn, -1 aeltere Unterlagen, -2 Klausuren
    public let week: Int
    /// Art wie bei Dateien (`StudyClassify.effectiveType`): vorlesung, uebung, klausur, ...
    public let kind: String
    /// Bezeichnung der Art, z. B. "Vorlesung", "Hoersaaluebung"
    public let label: String
    /// gemerkte Stelle beim Abspielen (Sekunden)
    public let position: Double?
    /// geladene Datei relativ zum Container (nur auf Wunsch geladen)
    public let localPath: String?
    public let localQuality: String?
    /// in Opencast nicht mehr gelistet (nur noch die geladene Datei)
    public let gone: Bool

    public var id: String { courseID + "|" + video.id }

    public init(courseID: String, courseTitle: String, moduleID: Int?, video: OpencastVideo, week: Int, kind: String = "vorlesung",
                label: String = "Vorlesung", position: Double? = nil, localPath: String? = nil, localQuality: String? = nil,
                gone: Bool = false) {
        self.courseID = courseID
        self.courseTitle = courseTitle
        self.moduleID = moduleID
        self.video = video
        self.week = week
        self.kind = kind
        self.label = label
        self.position = position
        self.localPath = localPath
        self.localQuality = localQuality
        self.gone = gone
    }
}

/// Ein Wochenblock der Aufzeichnungen mit derselben Beschriftung wie im Moduldetail (`StudyWeeks.weekLabel`).
public struct OpencastWeekBlock: Sendable, Equatable, Identifiable {
    public let week: Int
    public let label: String
    public let entries: [OpencastEntry]
    public var id: Int { week }

    public init(week: Int, label: String, entries: [OpencastEntry]) {
        self.week = week
        self.label = label
        self.entries = entries
    }
}

/// Aufzeichnungen eines Kurses ohne Modul (Begruessung, Kurs ohne Fach): eigener Abschnitt unter "Meine Module".
public struct OpencastCourseGroup: Sendable, Equatable, Identifiable {
    public let courseID: String
    public let courseTitle: String
    public let blocks: [OpencastWeekBlock]
    public var id: String { courseID }
    public var count: Int { blocks.reduce(0) { $0 + $1.entries.count } }
}

/// Passende Aufzeichnung(en) zu einem Dokument.
public struct OpencastMatch: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// gleiches Fach, gleiche Lehrwoche
        case sameWeek(Int)
        /// gleiches Fach, alle Themenwoerter des Videotitels stehen im Dokument (und bei keinem anderen Video)
        case topic([String])
    }

    /// ein bis drei Aufzeichnungen, aelteste zuerst
    public let entries: [OpencastEntry]
    public let reason: Reason

    public init(entries: [OpencastEntry], reason: Reason) {
        self.entries = entries
        self.reason = reason
    }

    /// z. B. "Aufzeichnung derselben Lehrwoche (Woche 3)" oder "Thema: Fourier, Reihen"
    public var reasonText: String {
        switch reason {
        case .sameWeek(let w): return "\(entries.count == 1 ? "Aufzeichnung" : "Aufzeichnungen") derselben Lehrwoche (Woche \(w))"
        case .topic(let words): return "Gleiches Thema: " + words.map(OpencastStore.display).joined(separator: ", ")
        }
    }
}

/// Passende Aufzeichnung zu einer Aufgabe eines Lernpakets (Aufgabe mit Dokument).
public struct OpencastTaskMatch: Sendable, Equatable, Identifiable {
    public let taskID: Int
    public let taskTitle: String
    public let match: OpencastMatch
    public var id: Int { taskID }
}

public enum OpencastStore {
    /// Kurs ohne Opencast erst nach 7 Tagen erneut pruefen
    public static let noOpencastRecheck = 7 * 24 * 3600

    /// Tabellen nur auf dem Geraet (bei Bedarf angelegt wie studip_cycle_dates)
    static let tables = """
        CREATE TABLE IF NOT EXISTS opencast_courses (
            course_id TEXT PRIMARY KEY,           -- Stud.IP-Kurs
            status TEXT NOT NULL,                 -- available | none (Kurs ohne Opencast-Reiter)
            checked_at INTEGER NOT NULL           -- Unix-Zeit der letzten Pruefung
        );
        CREATE TABLE IF NOT EXISTS opencast_videos (
            course_id TEXT NOT NULL,
            id TEXT NOT NULL,                     -- Kennung der Zeile in Opencast
            title TEXT NOT NULL,
            description TEXT,
            duration INTEGER,                     -- Sekunden
            author TEXT,
            created INTEGER,                      -- Unix-Zeit ("Erstellt am")
            thumbnail_url TEXT,
            player_url TEXT,
            media TEXT NOT NULL DEFAULT '[]',     -- Videodateien als JSON [{quality, height, url}]
            first_seen TEXT,
            fetched_at TEXT,
            gone INTEGER NOT NULL DEFAULT 0,      -- in Opencast nicht mehr gelistet (bleibt nur mit geladener Datei)
            position REAL,                        -- gemerkte Stelle beim Abspielen (Sekunden)
            local_path TEXT,                      -- geladene Datei relativ zum Container (nur auf Wunsch)
            local_quality TEXT,
            PRIMARY KEY (course_id, id)
        );
        """

    static func tableExists(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='opencast_videos'") != nil
    }

    // MARK: Abruf

    /// Kurs in diesem Durchgang abrufen? Unbekannt oder mit Reiter: ja; ohne Opencast erst nach 7 Tagen.
    public static func needsCheck(_ state: OpencastCourseState?, now: Int) -> Bool {
        guard let s = state, s.status == "none" else { return true }
        return now - s.checkedAt >= noOpencastRecheck || now < s.checkedAt
    }

    /// Laedt die Aufzeichnungslisten der Kurse nacheinander (Pausen wie die JSON:API). Wirft nie: ein Fehler betrifft
    /// nur seinen Kurs (der gespeicherte Stand bleibt). Abgelaufene Sitzung, kein Netz oder Zeitlimit beenden den
    /// Abruf (`StudIPScheduleStore.stopsFetch`), weitere Anfragen waeren sinnlos.
    public static func fetch(client: StudIPClient, courses: [StudIPCourse], known: [String: OpencastCourseState],
                             now: Int) async -> OpencastFetch {
        var f = OpencastFetch(courses: courses, checkedAt: now)
        for (i, c) in courses.enumerated() {
            if !needsCheck(known[c.id], now: now) { f.skipped.append(c.id); continue }
            do {
                if let listing = try await client.opencastListing(courseID: c.id, knownAvailable: known[c.id]?.status == "available") {
                    f.listings[c.id] = listing
                } else {
                    f.failed.append(c.id)
                }
            } catch StudIPError.sessionExpired {
                f.sessionExpired = true
                break
            } catch {
                f.failed.append(c.id)
                if StudIPScheduleStore.stopsFetch(error) {
                    f.unreachable = true
                    f.failed += courses[(i + 1)...].map(\.id).filter { needsCheck(known[$0], now: now) }
                    break
                }
            }
        }
        return f
    }

    // MARK: Speichern

    /// Schreibt den Abruf (in einer Transaktion aufrufen). Je gelesenem Kurs: Videos anlegen bzw. aktualisieren
    /// (gemerkte Stelle und geladene Datei bleiben); nicht mehr gelistete Videos verschwinden, ausser es gibt eine
    /// geladene Datei (dann `gone`, sichtbar und abspielbar, bis der Nutzer sie entfernt).
    public static func store(_ f: OpencastFetch, in c: SQLiteConnection, clock: UniFlowClock) throws -> OpencastStoreResult {
        try c.executeScript(tables)
        let now = clock.nowISO
        var newVideos = 0, videos = 0
        for (courseID, listing) in f.listings.sorted(by: { $0.key < $1.key }) {
            let list: [OpencastVideo], status: String
            switch listing {
            case .videos(let v): list = v; status = "available"
            case .noOpencast: list = []; status = "none"
            case .unrecognized: continue
            }
            try c.execute("""
                INSERT INTO opencast_courses(course_id, status, checked_at) VALUES (?,?,?)
                ON CONFLICT(course_id) DO UPDATE SET status=excluded.status, checked_at=excluded.checked_at
                """, [.text(courseID), .text(status), .integer(Int64(f.checkedAt))])
            let existing = Set(try c.query("SELECT id FROM opencast_videos WHERE course_id=?", [.text(courseID)]).compactMap { $0[0].string })
            for v in list {
                if !existing.contains(v.id) { newVideos += 1 }
                videos += 1
                try c.execute("""
                    INSERT INTO opencast_videos(course_id, id, title, description, duration, author, created, thumbnail_url, player_url,
                                                media, first_seen, fetched_at, gone)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0)
                    ON CONFLICT(course_id, id) DO UPDATE SET title=excluded.title, description=excluded.description,
                        duration=excluded.duration, author=excluded.author, created=excluded.created,
                        thumbnail_url=excluded.thumbnail_url, player_url=excluded.player_url, media=excluded.media,
                        fetched_at=excluded.fetched_at, gone=0
                    """, [.text(courseID), .text(v.id), .text(v.title), SQLiteValue(v.description), SQLiteValue(v.duration),
                          SQLiteValue(v.author), SQLiteValue(v.created), SQLiteValue(v.thumbnailURL?.absoluteString),
                          SQLiteValue(v.playerURL?.absoluteString), .text(mediaJSON(v.media)), .text(now), .text(now)])
            }
            let listed = Set(list.map(\.id))
            for id in existing.subtracting(listed).sorted() {
                try c.execute("DELETE FROM opencast_videos WHERE course_id=? AND id=? AND local_path IS NULL", [.text(courseID), .text(id)])
                try c.execute("UPDATE opencast_videos SET gone=1 WHERE course_id=? AND id=?", [.text(courseID), .text(id)])
            }
        }
        return OpencastStoreResult(newVideos: newVideos, videos: videos)
    }

    /// Gespeicherter Stand je Kurs (fuer `fetch`); leer, solange es die Tabellen nicht gibt
    public static func courseStates(_ c: SQLiteConnection) throws -> [String: OpencastCourseState] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='opencast_courses'") != nil else { return [:] }
        var out: [String: OpencastCourseState] = [:]
        for r in try c.query("SELECT course_id, status, checked_at FROM opencast_courses") {
            guard let id = r[0].string, let s = r[1].string else { continue }
            out[id] = OpencastCourseState(status: s, checkedAt: r[2].int ?? 0)
        }
        return out
    }

    static func mediaJSON(_ media: [OpencastMedia]) -> String {
        JSONValue.array(media.map { ["quality": .string($0.quality), "height": .number(Double($0.height)), "url": .string($0.url.absoluteString)] })
            .jsonString(sortedKeys: true)
    }

    static func media(json text: String?) -> [OpencastMedia] {
        guard let text, let v = try? JSONValue.parse(Data(text.utf8)) else { return [] }
        return (v.array ?? []).compactMap { m in
            guard let q = m["quality"]?.string, let s = m["url"]?.string, let u = URL(string: s) else { return nil }
            return OpencastMedia(quality: q, height: m["height"]?.int ?? 0, url: u)
        }
    }

    // MARK: Geladene Dateien und gemerkte Stelle

    /// Geladene Datei eintragen (`path` relativ zum Container) bzw. austragen (nil). Ein ausgetragenes Video, das es in
    /// Opencast nicht mehr gibt, verschwindet ganz.
    public static func setLocal(_ c: SQLiteConnection, courseID: String, videoID: String, path: String?, quality: String?) throws {
        guard try tableExists(c) else { return }
        try c.execute("UPDATE opencast_videos SET local_path=?, local_quality=? WHERE course_id=? AND id=?",
                      [SQLiteValue(path), SQLiteValue(path == nil ? nil : quality), .text(courseID), .text(videoID)])
        if path == nil { try c.execute("DELETE FROM opencast_videos WHERE course_id=? AND id=? AND gone=1", [.text(courseID), .text(videoID)]) }
    }

    /// Alle geladenen Dateien austragen ("Dateien loeschen" in Stud.IP); die Listen bleiben
    public static func forgetLocalFiles(_ c: SQLiteConnection) throws {
        guard try tableExists(c) else { return }
        try c.execute("DELETE FROM opencast_videos WHERE gone=1")
        try c.execute("UPDATE opencast_videos SET local_path=NULL, local_quality=NULL")
    }

    /// Gespeicherte Pfade aller geladenen Dateien (Aufraeumen von Dateien ohne Eintrag)
    public static func localPaths(_ c: SQLiteConnection) throws -> Set<String> {
        guard try tableExists(c) else { return [] }
        return Set(try c.query("SELECT local_path FROM opencast_videos WHERE local_path IS NOT NULL").compactMap { $0[0].string })
    }

    public static func savePosition(_ c: SQLiteConnection, courseID: String, videoID: String, seconds: Double?) throws {
        guard try tableExists(c) else { return }
        let s = seconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        try c.execute("UPDATE opencast_videos SET position=? WHERE course_id=? AND id=?", [SQLiteValue(s), .text(courseID), .text(videoID)])
    }

    // MARK: Lesen

    static let entrySQL = """
        SELECT v.*, c.title AS course_title, c.module_id AS module_id
        FROM opencast_videos v JOIN courses c ON c.id=v.course_id
        WHERE c.active=1
        """

    /// Aufzeichnungen der aktiven Kurse eines Moduls (`moduleID`), der Kurse ohne Modul (`.null`) oder aller (nil)
    static func entries(_ c: SQLiteConnection, moduleID: SQLiteValue?, dates: LocalModules.Dates) throws -> [OpencastEntry] {
        guard try tableExists(c) else { return [] }
        var sql = entrySQL
        var params: [SQLiteValue] = []
        switch moduleID {
        case nil: break
        case .null?: sql += " AND c.module_id IS NULL"
        case let m?: sql += " AND c.module_id=?"; params.append(m)
        }
        return try c.query(sql + " ORDER BY v.created, v.title, v.id", params).map { try entry($0, dates: dates) }
    }

    static func entry(_ r: SQLiteRow, dates: LocalModules.Dates) throws -> OpencastEntry {
        let v = OpencastVideo(id: r["id"]?.string ?? "", title: r["title"]?.string ?? "", description: r["description"]?.string,
                              duration: r["duration"]?.int, author: r["author"]?.string, created: r["created"]?.int,
                              thumbnailURL: r["thumbnail_url"]?.string.flatMap(URL.init(string:)),
                              playerURL: r["player_url"]?.string.flatMap(URL.init(string:)), media: media(json: r["media"]?.string))
        let w = try week(v, dates: dates)
        return OpencastEntry(courseID: r["course_id"]?.string ?? "", courseTitle: r["course_title"]?.string ?? "",
                             moduleID: r["module_id"]?.int, video: v, week: w.week, kind: w.kind, label: w.label,
                             position: r["position"]?.double, localPath: r["local_path"]?.string,
                             localQuality: r["local_quality"]?.string, gone: (r["gone"]?.int ?? 0) != 0)
    }

    /// Datum und Uhrzeit im Titel sind keine Nummern: sonst laese `weekHint` aus "06.11." bzw. "vom 06.11" die Woche 6,
    /// aus "08.15 Uhr" oder "2026_11_06" eine Woche 8 bzw. 6 (bei Dateinamen kommen Datumsangaben kaum vor, in
    /// Videotiteln oft). Reihenfolge: Uhrzeiten (auch "8–10 Uhr", "08.15 – 09.45"), Datum mit Jahr (2026-11-06,
    /// 2026_11_06, 20261106, 06.11.2026, 06/11/2026, 06-11-26), Monatsnamen ("6. November"), "06.11." und "06.11".
    /// "Kapitel 3.1.4" bleibt (keine Jahreszahl, Punkt vor einer Ziffer).
    private static let datesAndTimes = PyRegex(
        #"(?:\d{1,2}(?:[.:]\d{2})?\s*(?:-|–|—|bis)\s*)?\d{1,2}(?:[.:]\d{2})?\s*uhr\b"#
        + #"|\d{1,2}[.:]\d{2}\s*(?:-|–|—|bis)\s*\d{1,2}[.:]\d{2}"#
        + #"|\d{1,2}:\d{2}(?::\d{2})?"#
        + #"|\d{4}[-_./]\d{1,2}[-_./]\d{1,2}"#
        + #"|(?<!\d)(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?!\d)"#
        + #"|\d{1,2}[-_./]\d{1,2}[-_./](?:\d{4}|\d{2})(?!\d)"#
        + #"|\d{1,2}\.\s*(?:januar|jan|februar|feb|märz|maerz|mär|mrz|april|apr|mai|juni|jun|juli|jul|august|aug"#
        + #"|september|sept|sep|oktober|okt|november|nov|dezember|dez)\b\.?(?:\s*\d{4})?"#
        + #"|\d{1,2}\.\d{1,2}\.(?!\d)"#
        + #"|(?<![\d.])\d{1,2}\.\d{2}(?!\.?\d)"#,
        ignoreCase: true)

    /// Titel ohne Datum und Uhrzeit (Grundlage fuer Art und Lehrwoche)
    static func withoutDates(_ title: String) -> String { datesAndTimes.sub(title, " ") }

    /// Block eines Videos wie eine Datei im Moduldetail: Art und Lehrwoche aus dem Titel wie aus einem Dateinamen
    /// (`StudyClassify.enrichFile`, ohne KI gilt ein Video als Vorlesung), Datum = "Erstellt am" statt der Aenderungszeit.
    static func week(_ v: OpencastVideo, dates: LocalModules.Dates) throws -> (week: Int, kind: String, label: String) {
        let f = StudyClassify.enrichFile(["name": .string(withoutDates(v.title)), "doc_type": .string("vorlesung")])
        let kind = f["doc_type"]?.string ?? "vorlesung", label = f["sub_label"]?.string ?? "Vorlesung"
        let chdate: SQLiteValue = v.created.map { .integer(Int64($0)) } ?? .null
        let w = try LocalModules.week(docType: kind, subLabel: label, weekHint: f["week_hint"]?.int, chdate: chdate,
                                      start: dates.start, today: dates.today)
        return (w, kind, label)
    }

    /// Wochenbloecke in der Reihenfolge des Moduldetails (Lehrwochen, aeltere Unterlagen, Klausuren)
    static func blocks(_ entries: [OpencastEntry], start: Int) -> [OpencastWeekBlock] {
        var by: [Int: [OpencastEntry]] = [:]
        for e in entries { by[e.week, default: []].append(e) }
        return by.keys.sorted(by: LocalModules.weekOrder).map { w in
            OpencastWeekBlock(week: w, label: StudyWeeks.weekLabel(start: start, week: w), entries: by[w] ?? [])
        }
    }

    /// Aufzeichnungen eines Moduls nach Lehrwoche (Bereich "Aufzeichnungen" im Moduldetail)
    public static func moduleBlocks(_ c: SQLiteConnection, moduleID: Int, clock: UniFlowClock) throws -> [OpencastWeekBlock] {
        guard try tableExists(c) else { return [] }
        let dates = try LocalModules.Dates(c, clock: clock)
        return blocks(try entries(c, moduleID: .integer(Int64(moduleID)), dates: dates), start: dates.start)
    }

    /// Zahl der Aufzeichnungen je Block eines Moduls (Hinweis in den Wochenbloecken der Uebersicht)
    public static func weekCounts(_ c: SQLiteConnection, moduleID: Int, clock: UniFlowClock) throws -> [Int: Int] {
        try moduleBlocks(c, moduleID: moduleID, clock: clock).reduce(into: [:]) { $0[$1.week] = $1.entries.count }
    }

    /// Kurse ohne Modul mit Aufzeichnungen (nach Kurstitel), je Kurs nach Lehrwoche
    public static func unassigned(_ c: SQLiteConnection, clock: UniFlowClock) throws -> [OpencastCourseGroup] {
        guard try tableExists(c) else { return [] }
        let dates = try LocalModules.Dates(c, clock: clock)
        let all = try entries(c, moduleID: .null, dates: dates)
        var order: [String] = []
        var by: [String: [OpencastEntry]] = [:]
        for e in all {
            if by[e.courseID] == nil { order.append(e.courseID) }
            by[e.courseID, default: []].append(e)
        }
        return order.map { id in
            let list = by[id] ?? []
            return OpencastCourseGroup(courseID: id, courseTitle: list.first?.courseTitle ?? "", blocks: blocks(list, start: dates.start))
        }
        .sorted { $0.courseTitle.localizedStandardCompare($1.courseTitle) == .orderedAscending }
    }

    /// Eine Aufzeichnung (neu gelesen, z. B. nach dem Laden)
    public static func entry(_ c: SQLiteConnection, courseID: String, videoID: String, clock: UniFlowClock) throws -> OpencastEntry? {
        guard try tableExists(c) else { return nil }
        guard let r = try c.queryOne(entrySQL + " AND v.course_id=? AND v.id=?", [.text(courseID), .text(videoID)]) else { return nil }
        return try entry(r, dates: try LocalModules.Dates(c, clock: clock))
    }

    // MARK: Passende Aufzeichnung

    /// Passende Aufzeichnung zu einem Dokument oder nil. `text`: weiterer Text des Dokuments (z. B. der Anfang der
    /// ersten Seite); Name und Titel kommen aus der Datenbank. Nur im selben Modul (Fach) und nur bei sicherem
    /// Treffer (`best`).
    public static func match(_ c: SQLiteConnection, fileID: String, text: String = "", clock: UniFlowClock) throws -> OpencastMatch? {
        guard try tableExists(c),
              let r = try c.queryOne(LocalModules.fileRowsSQL + " AND f.id=?", [.text(fileID)]) else { return nil }
        let f = LocalModules.FileRow(json: StudyClassify.enrichFile(r.json), chdate: r["chdate"] ?? .null)
        guard let module = f.json["module_id"]?.int else { return nil }
        let dates = try LocalModules.Dates(c, clock: clock)
        let week = try LocalModules.week(docType: f.docType, subLabel: f.json["sub_label"]?.string, weekHint: f.json["week_hint"]?.int,
                                         chdate: f.chdate, start: dates.start, today: dates.today)
        let entries = try entries(c, moduleID: .integer(Int64(module)), dates: dates)
        guard !entries.isEmpty else { return nil }
        let title = try c.scalar("SELECT title FROM files WHERE id=?", [.text(fileID)])?.string
        let docText = [f.json["name"]?.string, title, f.json["ai_title"]?.string, text].compactMap { $0 }.joined(separator: "\n")
        var names = try c.query("SELECT name FROM modules WHERE id=?", [.integer(Int64(module))]).compactMap { $0[0].string }
        names += try c.query("SELECT title FROM courses WHERE module_id=?", [.integer(Int64(module))]).compactMap { $0[0].string }
        return best(entries, documentWeek: week, documentKind: f.docType ?? "", documentText: docText, names: names)
    }

    /// Passende Aufzeichnungen zu den Aufgaben eines Lernpakets (Aufgaben mit Dokument); jedes Video nur einmal
    public static func packageMatches(_ c: SQLiteConnection, packageID: Int, clock: UniFlowClock) throws -> [OpencastTaskMatch] {
        guard try tableExists(c) else { return [] }
        var out: [OpencastTaskMatch] = []
        var seen = Set<String>()
        for t in try c.query("SELECT id, title, file_id FROM study_tasks WHERE package_id=? AND file_id IS NOT NULL ORDER BY id",
                             [.integer(Int64(packageID))]) {
            guard let tid = t[0].int, let file = t[2].string,
                  let m = try match(c, fileID: file, text: t[1].string ?? "", clock: clock) else { continue }
            let fresh = m.entries.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            out.append(OpencastTaskMatch(taskID: tid, taskTitle: t[1].string ?? "", match: OpencastMatch(entries: fresh, reason: m.reason)))
        }
        return out
    }

    /// Lieber kein Vorschlag als ein falscher:
    /// 0. Organisatorisches (Raumverteilung, Termine, Klausurergebnisse) gehoert zu keiner Aufzeichnung: nichts; ebenso
    ///    werden organisatorische Videos ("Organisatorisches", Woche nur aus dem Erstelldatum) nie vorgeschlagen.
    /// 1. Dokument einer Art mit Lehrwoche (`StudyClassify.lectureWeekTypes`, wie `week_hint`), Lehrwoche bekannt (ab 1)
    ///    und es gibt Videos derselben Lehrwoche im Modul: diese (bei einem Blatt oder einer Loesung die Uebungs- und
    ///    Loesungsaufzeichnungen, sonst die Vorlesungen, falls es beide gibt); passt das Thema genau eines davon, nur
    ///    dieses. Hoechstens drei. Bei anderen Arten ist die Woche nur die des Hochladens, kein sicherer Treffer.
    /// 2. Sonst nur, wenn genau ein Video des Moduls ein eindeutiges Thema hat, das vollstaendig im Dokument steht
    ///    (`topicWords`, ohne Modul- und Kursnamen, ohne Woerter einer Art wie "Vorlesung", "Exercise" und ohne
    ///    allgemeine Woerter wie "Teil", "Woche").
    /// 3. Sonst nichts.
    static func best(_ entries: [OpencastEntry], documentWeek: Int, documentKind: String, documentText: String,
                     names: [String]) -> OpencastMatch? {
        guard documentKind != "organisatorisch" else { return nil }
        let entries = entries.filter { $0.kind != "organisatorisch" }
        /// Uebungsseite: Uebung und Loesung (wie bei der Art des Dokuments), sonst Vorlesungsseite
        func exerciseSide(_ kind: String) -> Bool { ["uebung", "loesung"].contains(kind) }
        let docWords = Set(words(documentText))
        let ignored = Set(names.flatMap(words))
        func topic(_ e: OpencastEntry) -> [String]? {
            let t = topicWords(e.video.title, ignoring: ignored.union(words(e.courseTitle)))
            guard t.reduce(0, { $0 + PyText.length($1) }) >= 6,
                  t.allSatisfy({ w in docWords.contains { sameWord(w, $0) } }) else { return nil }
            return t
        }
        if documentWeek >= 1, StudyClassify.lectureWeekTypes.contains(documentKind) {
            var same = entries.filter { $0.week == documentWeek }
            if !same.isEmpty {
                let preferred = same.filter { exerciseSide($0.kind) == exerciseSide(documentKind) }
                if !preferred.isEmpty { same = preferred }
                let narrowed = same.filter { topic($0) != nil }
                return OpencastMatch(entries: Array((narrowed.count == 1 ? narrowed : same).prefix(3)), reason: .sameWeek(documentWeek))
            }
        }
        let hits = entries.compactMap { e in topic(e).map { (entry: e, words: $0) } }
        guard hits.count == 1 else { return nil }
        return OpencastMatch(entries: [hits[0].entry], reason: .topic(hits[0].words))
    }

    // MARK: Themenwoerter

    private static let letters = PyRegex("[a-zäöüß]+")

    /// Woerter (klein, nur Buchstaben) eines Texts in der Suchform der Skriptsuche (`ScriptSearch.searchForm`):
    /// zerlegte Umlaute aus PDF-Text ("a" + U+0308 und "¨ Ubertragung", "Unabh¨ angigkeit" mit abgesetztem Trema)
    /// werden vorher zusammengesetzt; mit NFC allein wurden daraus "ubertragung" bzw. "unabh" und "angigkeit"
    static func words(_ s: String) -> [String] {
        letters.findAll(ScriptSearch.searchForm(s))
    }

    /// Woerter in Videotiteln und Blattkoepfen, die nichts ueber das Thema sagen und keine Art nennen (Woerter einer Art
    /// wie "Vorlesung", "Übungsblatt", "Lösung", "Klausur", "Exercise", "Slides" erkennt `namesKind` ueber die Einordnung).
    /// Bewusst eine eigene Liste neben `ScriptSearch.stop`: jene ist die Stoppliste der Skriptsuche wie `STOP` in
    /// app/scriptsearch.py (Aufgabentexte, gleich wie am PC), diese betrifft Videotitel und gibt es am PC nicht.
    static let generic: Set<String> = Set("""
        woche wochen lehrwoche tutorien teil teile video videos aufzeichnung aufzeichnungen mitschnitt livestream stream
        ergänzung ergänzungen besprechung korrektur fortsetzung wiederholung sitzung termin aufgabe hausaufgabe
        zusammenfassung einführung überblick fragestunde fragen vorbereitung nachtrag hinweis hinweise kapitel abschnitt
        thema themen inhalt inhalte semester sommersemester wintersemester sose wise folie prof professor professorin live
        tutorial tutorials session sessions part parts chapter chapters week weeks introduction recording recordings
        und oder der die das den dem des von vom mit für fuer zur zum über ueber eine einer eines einem einen sowie auch
        nach ohne beim bei sind ist wird werden uhr heute montag dienstag mittwoch donnerstag freitag samstag sonntag januar
        februar märz april mai juni juli august september oktober november dezember seite seiten nummer beispiel
        beispiele test kurs modul abgabe punkte bitte name matrikelnummer gruppe hannover universität leibniz institut
        fakultät
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Wort, das die Einordnung der Dokumente als Art erkennt ("Großübung", "Lösungsbesprechung", "Lecture", "Exercise")
    static func namesKind(_ w: String) -> Bool {
        StudyClassify.effectiveType(name: w, folder: nil, aiType: nil).type != "sonstiges"
    }

    /// Themenwoerter eines Videotitels: ab 4 Buchstaben, ohne allgemeine Woerter, Woerter einer Art, Modul- und Kursnamen
    static func topicWords(_ title: String, ignoring: Set<String>) -> [String] {
        var out: [String] = []
        for w in words(title) where PyText.length(w) >= 4 && !generic.contains(w) && !ignoring.contains(w) && !out.contains(w)
            && !namesKind(w) {
            out.append(w)
        }
        return out
    }

    /// Gleiches Wort, auch mit kurzer Endung ("Reihe"/"Reihen", "Grenzwert"/"Grenzwerte"; ab 5 Buchstaben)
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (s, l) = PyText.length(a) <= PyText.length(b) ? (a, b) : (b, a)
        return PyText.length(s) >= 5 && PyText.length(l) - PyText.length(s) <= 2 && l.hasPrefix(s)
    }

    /// Wort fuer die Anzeige ("fourier" -> "Fourier")
    static func display(_ w: String) -> String { w.prefix(1).uppercased() + w.dropFirst() }
}

extension StudIPClient {
    /// Aufzeichnungen eines Kurses (Seite media/index; nur bei einer unklaren Antwort zusaetzlich der Kursueberblick).
    /// nil, wenn sich nichts sicher sagen laesst (alter Stand bleibt). `knownAvailable`: der Kurs hatte beim letzten
    /// Mal den Reiter; dann macht ihn nur die ausdrueckliche Meldung des Plugins zu "kein Opencast" (sonst loeschte
    /// `OpencastStore.store` seine Videos und gemerkten Stellen), nie der Ersatzweg oder ein blosses 404. Wirft
    /// `sessionExpired`, `requestLimit` und Transportfehler. Nur lesend; Videos werden hier nie geladen.
    public func opencastListing(courseID: String, knownAvailable: Bool = false) async throws -> OpencastListing? {
        let r = try await htmlPage(OpencastParser.mediaIndexPath(courseID: courseID))
        // Links gegen die Stud.IP-Adresse aufloesen (nach einer Weiterleitung auf einen anderen Host nie gegen diesen)
        let page = r.finalURL.flatMap { $0.host?.lowercased() == base.host?.lowercased() ? $0 : nil } ?? base
        let html = String(decoding: r.body, as: UTF8.self)
        switch OpencastParser.parse(html: html, status: r.status, pageURL: page) {
        case .videos(let v):
            return .videos(v)
        case .noOpencast:
            return knownAvailable && !OpencastParser.saysNavigationMissing(html) ? nil : .noOpencast
        case .unrecognized:
            guard !knownAvailable else { return nil }
            // Seite sagt nichts Eindeutiges: nur der sichere Kursueberblick ohne Navigationslink "Aufzeichnungen" heisst
            // kein Opencast; eine Zwischenseite mit 200 (Nutzungsbedingungen, Wartung) sagt nichts ueber den Kurs
            let o = try await htmlPage(OpencastParser.overviewPath(courseID: courseID))
            let overview = String(decoding: o.body, as: UTF8.self)
            guard (200..<300).contains(o.status),
                  OpencastParser.isCourseOverview(html: overview, finalURL: o.finalURL, courseID: courseID) else { return nil }
            return OpencastParser.courseHasRecordings(overviewHTML: overview) ? nil : .noOpencast
        }
    }
}
