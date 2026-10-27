import Foundation

// Stundenplan aus Stud.IP in die lokale Datenbank, wie auf dem PC in app/studip_sync.py (fetch_events/store_events,
// fetch_schedule_entries/store_schedule_entries, danach timetable.auto_import). Auf dem Geraet kommen die
// Kurszeiten dazu (seminar-cycle-dates aus users/{id}/schedule, gelesen von StudIPSchedule): Tabelle
// studip_cycle_dates, die es nur auf dem Geraet gibt und die wie page_texts in app/scriptsearch.py erst bei Bedarf
// angelegt wird. LocalTimetableImport.studipEntries nutzt sie anstelle der aus Einzelterminen abgeleiteten Serien.
//
// Abruf und Speichern sind getrennt: erst alles laden (Netzwerk), dann in einer Transaktion schreiben (kein await
// in der Transaktion, siehe SQLiteDatabase). Was nicht geladen werden konnte, bleibt wie zuletzt gespeichert; ebenso
// jeder gelieferte Eintrag, der sich nicht lesen laesst (HTTP 200 ist noch kein gueltiger Datensatz). Anders als am PC
// (store_events/store_schedule_entries schreiben nur dazu) ersetzt das Geraet seine Abbilder, damit in Stud.IP
// Entferntes verschwindet; entfernt wird deshalb nur, was eine vollstaendig lesbare Antwort nicht mehr enthaelt.

/// Einzeltermin eines Kurses (course-events) wie fetch_events in app/studip_sync.py.
public struct StudIPCourseEvent: Sendable, Equatable {
    public let id: String
    public let courseID: String
    public let title: String
    /// Beginn und Ende wie geliefert, die ersten 19 Zeichen ("2026-10-26T09:00:00", Ortszeit der Hochschule)
    public let start: String
    public let end: String
    /// erster Ort bis zum ersten Komma
    public let room: String

    public init(id: String, courseID: String, title: String, start: String, end: String, room: String) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.start = start
        self.end = end
        self.room = room
    }

    /// `data` von courses/{id}/events; abgesagte Termine (`is-cancelled`) fehlen wie auf dem PC
    public static func parse(_ data: [JSONValue], courseID: String) -> [StudIPCourseEvent] {
        read(data, courseID: courseID).events
    }

    /// Gelesene Einzeltermine eines Kurses und was sich nicht lesen liess. Lesbar ist ein Termin mit Kennung und
    /// Beginn/Ende als Datum mit Uhrzeit; abgesagte zaehlen nicht (sie fehlen wie auf dem PC). Doppelte Kennungen
    /// (z. B. Ueberlappung zweier Seiten) zaehlen einmal.
    public struct Read: Sendable, Equatable {
        public var events: [StudIPCourseEvent] = []
        /// Kennungen, deren Termin sich nicht lesen liess: ihr gespeicherter Stand bleibt
        public var unreadableIDs: [String] = []
        /// Eintraege ohne Kennung: die Antwort ist unvollstaendig, gespeicherte Termine werden nicht entfernt
        public var withoutID = 0

        public var unreadable: Int { unreadableIDs.count + withoutID }
        public var complete: Bool { withoutID == 0 }
    }

    public static func read(_ data: [JSONValue], courseID: String) -> Read {
        var out = Read()
        var seen = Set<String>()
        for e in data {
            guard let id = e["id"]?.string, !id.isEmpty else { out.withoutID += 1; continue }
            guard seen.insert(id).inserted else { continue }
            let a = e["attributes"]
            if LocalModules.truthy(a?["is-cancelled"]) { continue }
            func text(_ k: String) -> String { a?[k]?.string ?? "" }
            let start = PyText.slice(text("start"), 0, 19), end = PyText.slice(text("end"), 0, 19)
            guard LocalTimetableImport.isoDateTime(.string(start)) != nil, LocalTimetableImport.isoDateTime(.string(end)) != nil else {
                out.unreadableIDs.append(id)
                continue
            }
            let room = text("location").split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            out.events.append(StudIPCourseEvent(id: id, courseID: courseID, title: text("title"), start: start, end: end, room: PyText.strip(room)))
        }
        return out
    }
}

extension StudIPClient {
    /// Einzeltermine eines Kurses (courses/{id}/events, alle Seiten). Nur lesend.
    public func courseEvents(courseID: String) async throws -> [StudIPCourseEvent] {
        try await courseEventsRead(courseID: courseID).events
    }

    /// Einzeltermine eines Kurses mit dem, was sich nicht lesen liess (`StudIPCourseEvent.read`)
    public func courseEventsRead(courseID: String) async throws -> StudIPCourseEvent.Read {
        let (data, _) = try await list("jsonapi.php/v1/courses/\(courseID)/events?page[limit]=200")
        return StudIPCourseEvent.read(data, courseID: courseID)
    }

    /// Ankuendigungen (News) eines Kurses wie `fetch_news` (courses/{id}/news, eine Seite mit 100). Nur lesend.
    /// Ohne Liste `data` (Antwort unbrauchbar) ein Fehler: der Bestand des Kurses bleibt, statt geloescht zu werden.
    public func courseNews(courseID: String) async throws -> [JSONValue] {
        let path = "jsonapi.php/v1/courses/\(courseID)/news?page[limit]=100"
        guard let list = try await json(path)["data"]?.array else { throw StudIPError.badResponse("Antwort ohne Liste (\(Self.scrub(path)))") }
        return list
    }

    /// Basis fuer Links in Ankuendigungen (STUDIP_BASE am PC, ohne "/" am Ende)
    nonisolated var baseString: String {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }
}

/// Was der Stundenplan-Abruf geladen hat. nil bzw. fehlende Kurse: nicht geladen, das Gespeicherte bleibt.
public struct StudIPScheduleDownload: Sendable {
    /// Kurse, die abgeglichen werden (wie die Kursliste in run_sync)
    public var courses: [StudIPCourse]
    /// `course-type` je Kurs aus users/{id}/courses
    public var courseTypes: [String: Int] = [:]
    /// seminar-cycle-dates aus users/{id}/schedule (Rohdaten der JSON:API)
    public var cycles: [JSONValue]?
    /// schedule-entries (eigene Eintraege) aus users/{id}/schedule
    public var personal: [JSONValue]?
    /// Einzeltermine je Kurs, nur vollstaendig geladene Kurse
    public var events: [String: [StudIPCourseEvent]] = [:]
    /// je Kurs: Kennungen geladener, aber nicht lesbarer Termine (ihr gespeicherter Stand bleibt)
    public var keptEvents: [String: Set<String>] = [:]
    /// Kurse mit Terminen ohne Kennung: Lesbares wird aktualisiert, Gespeichertes nicht entfernt
    public var incompleteCourses: Set<String> = []
    /// users/{id}/schedule enthielt Eintraege ohne Typ: weder Kurszeiten noch eigene Eintraege werden entfernt
    public var scheduleIncomplete = false
    /// Eintraege, die Stud.IP geliefert hat, die sich aber nicht lesen liessen (Termine, Kurszeiten, eigene
    /// Eintraege ohne Kennung, Uhrzeit oder Kurs). Ihr gespeicherter Stand bleibt; die Zusammenfassung nennt die Zahl.
    public var unreadable = 0
    /// Ankuendigungen (News) je Kurs, Rohdaten der JSON:API; fehlt ein Kurs, bleibt sein Bestand (wie `fetch_news` None)
    public var news: [String: [JSONValue]] = [:]
    /// Basis fuer Links in Ankuendigungen (STUDIP_BASE)
    public var studipBase = ""
    /// Kurse, deren Termine nicht geladen werden konnten
    public var failedCourses: [String] = []
    /// Anmeldung abgelaufen (der Rest wurde nicht mehr abgefragt)
    public var sessionExpired = false
    /// Netz- oder Zeitlimitfehler: der Rest wurde nicht mehr abgefragt (steht in `failedCourses`)
    public var unreachable = false
    /// users/{id}/schedule liess sich nicht laden (Meldung ohne Kennungen)
    public var scheduleError: String?
    /// Termin-IDs im eigenen Stud.IP-Kalender (users/{id}/events.ics, `StudIPCalendar`); nil = nicht geladen
    public var calendar: [String]?
    /// Der Kalender liess sich nicht laden oder enthielt keine Veranstaltungstermine: Gruppen nicht sicher bekannt
    public var calendarError: String?

    public init(courses: [StudIPCourse]) {
        self.courses = courses
    }
}

/// Ergebnis des Speicherns (fuer die Zusammenfassung des Abgleichs).
public struct StudIPScheduleResult: Sendable, Equatable {
    /// neu in den Stundenplan uebernommene Serien (auto_import)
    public let newEvents: Int
    /// Eintraege offener Gruppen, die auf die Auswahl warten (StudIPScheduleImport.openGroups)
    public let pendingGroups: Int
    public let cycles: Int
    public let events: Int
    /// Serien, die laut eigenem Stud.IP-Kalender nicht mehr dazugehoeren und entfernt wurden
    public let removedEvents: Int
    /// offene Fragen zum Stud.IP-Kalender (Kurs ohne Kalendertermine, Kurs mit vielen Serien je Woche)
    public let openQuestions: Int

    public init(newEvents: Int, pendingGroups: Int, cycles: Int, events: Int, removedEvents: Int = 0, openQuestions: Int = 0) {
        self.newEvents = newEvents
        self.pendingGroups = pendingGroups
        self.cycles = cycles
        self.events = events
        self.removedEvents = removedEvents
        self.openQuestions = openQuestions
    }
}

public enum StudIPScheduleStore {

    /// Kurszeiten nur auf dem Geraet (Rohdaten, damit StudIPSchedule sie bei jeder Abfrage gleich liest)
    static let cycleTable = """
        CREATE TABLE IF NOT EXISTS studip_cycle_dates (
            id TEXT PRIMARY KEY,               -- Stud.IP-ID der Kurszeit
            course_id TEXT NOT NULL,
            course_type INTEGER,               -- course-type des Kurses (Art, wenn Titel und Beschreibung keine nennen)
            data TEXT NOT NULL,                -- Eintrag aus users/{id}/schedule (seminar-cycle-dates, JSON)
            fetched_at TEXT
        )
        """

    // MARK: Abruf

    /// Laedt Kurszeiten, eigene Eintraege, den eigenen Kalender und die Einzeltermine der Kurse. Wirft nie: Fehler je Teil stehen im
    /// Ergebnis, damit der Datei-Abgleich davon unberuehrt bleibt. Nach einem Netz- oder Zeitlimitfehler
    /// (`stopsFetch`) fragt der Abruf nichts mehr ab: jede weitere Anfrage wuerde nur bis zum Zeitlimit warten
    /// (30 s je Kurs), waehrend der Datei-Abgleich noch nicht fertig gemeldet ist.
    public static func fetch(client: StudIPClient, userID: String, courses: [StudIPCourse]) async -> StudIPScheduleDownload {
        var d = StudIPScheduleDownload(courses: courses)
        d.studipBase = client.baseString
        do {
            let r = try await client.scheduleResources(userID: userID)
            d.cycles = r.schedule.filter { $0["type"]?.string == "seminar-cycle-dates" }
            d.personal = r.schedule.filter { $0["type"]?.string == "schedule-entries" }
            // ohne Typ laesst sich ein Eintrag keiner Tabelle zuordnen: nichts entfernen, was er sein koennte
            let untyped = r.schedule.filter { $0["type"]?.string == nil }.count
            if untyped > 0 { d.scheduleIncomplete = true }
            d.unreadable += untyped + (d.cycles ?? []).filter { readableCycle($0) == nil }.count
                + (d.personal ?? []).filter { readablePersonal($0) == nil }.count
            for c in r.courses {
                if let id = c["id"]?.string, let t = StudIPSchedule.integer(c["attributes"]?["course-type"]) { d.courseTypes[id] = t }
            }
        } catch StudIPError.sessionExpired {
            d.sessionExpired = true
            return d
        } catch {
            d.scheduleError = (error as? StudIPError)?.description ?? "Stundenplan nicht lesbar"
            if stopsFetch(error) {
                d.unreachable = true
                d.failedCourses = courses.map(\.id)
                return d
            }
        }
        // eigener Kalender: welche Termine Stud.IP dem Nutzer selbst zeigt (eigene Gruppen, Kurse mit Kalenderbindung)
        do {
            let ids = StudIPCalendar.dateIDs(ics: try await client.calendarICS(userID: userID))
            if ids.isEmpty { d.calendarError = "Stud.IP-Kalender ohne Veranstaltungstermine" } else { d.calendar = ids }
        } catch StudIPError.sessionExpired {
            d.sessionExpired = true
            return d
        } catch {
            d.calendarError = (error as? StudIPError)?.description ?? "Stud.IP-Kalender nicht lesbar"
            if stopsFetch(error) {
                d.unreachable = true
                d.failedCourses = courses.map(\.id)
                return d
            }
        }
        for (i, c) in courses.enumerated() {
            do {
                let read = try await client.courseEventsRead(courseID: c.id)
                d.events[c.id] = read.events
                if !read.unreadableIDs.isEmpty { d.keptEvents[c.id] = Set(read.unreadableIDs) }
                if !read.complete { d.incompleteCourses.insert(c.id) }
                d.unreadable += read.unreadable
            } catch StudIPError.sessionExpired {
                d.sessionExpired = true
                break
            } catch {
                d.failedCourses.append(c.id)
                if stopsFetch(error) {
                    d.unreachable = true
                    d.failedCourses += courses[(i + 1)...].map(\.id)
                    break
                }
            }
            // Ankuendigungen je Kurs wie in run_sync, unabhaengig von den Terminen: eine Ergaenzung ("Ankuendigungen
            // nicht gelesen"), ein Fehler laesst den Bestand des Kurses stehen; Abbruch und abgelaufene Sitzung
            // bemerkt der naechste Kurs
            if let news = try? await client.courseNews(courseID: c.id) { d.news[c.id] = news }
        }
        return d
    }

    /// Fehler, nach denen weitere Anfragen sinnlos sind: kein Netz, Server nicht erreichbar oder haengt (Zeitlimit),
    /// Abbruch der Aufgabe, Anfragegrenze des Durchgangs erreicht
    static func stopsFetch(_ error: Error) -> Bool {
        if error is CancellationError || (error as? StudIPError) == StudIPError.requestLimit { return true }
        guard let u = error as? URLError else { return false }
        let codes: Set<URLError.Code> = [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                                         .dnsLookupFailed, .cancelled, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed]
        return codes.contains(u.code)
    }

    // MARK: Speichern

    /// Schreibt den Abruf in die Datenbank (in einer Transaktion aufrufen) und uebernimmt danach wie auf dem PC alle
    /// eindeutigen Termine in den Stundenplan (`auto_import`, auf dem Geraet mit Verknuepfung: StudIPScheduleImport).
    /// Parallele Gruppen bleiben zur Auswahl.
    public static func store(_ d: StudIPScheduleDownload, in c: SQLiteConnection, clock: UniFlowClock) throws -> StudIPScheduleResult {
        let now: SQLiteValue = .text(clock.nowISO)
        // Kurse wie upsert_course in run_sync, derselbe Weg wie der Datei-Abgleich (`StudIPLibrary.storeCourses`):
        // anlegen bzw. Titel, Nummer, Semester aktualisieren; Fach und Art aus `UniRules.classify` nur, solange
        // sie fehlen (der Nutzer darf sie aendern). Ohne Art fiele ein Kurs aus studip_entries (kind != 'sonstiges').
        try StudIPLibrary.storeCourses(c, d.courses, startedAt: clock.nowISO)
        // Einzeltermine je vollstaendig geladenem Kurs ersetzen (store_events; dort bleiben Veraltete stehen). Was
        // Stud.IP geliefert hat, das sich aber nicht lesen liess, bleibt wie gespeichert (Kennungen in `keptEvents`);
        // mit Terminen ohne Kennung (Antwort unvollstaendig) wird nur aktualisiert, nichts entfernt. Fehlende Termine
        // sind fuer den eigenen Kalender wichtig: ihre Kurszeiten gaelten sonst als "nicht im Kalender"
        // (`StudIPCalendar.store`) und verschwaenden aus dem Stundenplan.
        var events = 0
        for (courseID, list) in d.events.sorted(by: { $0.key < $1.key }) {
            if !d.incompleteCourses.contains(courseID) {
                let keep = Set(list.map(\.id)).union(d.keptEvents[courseID] ?? [])
                for r in try c.rows("SELECT id FROM studip_events WHERE course_id=?", [.text(courseID)]) {
                    guard let id = r["id"]?.string, !keep.contains(id) else { continue }
                    try c.execute("DELETE FROM studip_events WHERE id=?", [.text(id)])
                }
            }
            for e in list {
                try c.execute("""
                    INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, start=excluded.start, end=excluded.end, room=excluded.room, fetched_at=excluded.fetched_at
                    """, [.text(e.id), .text(e.courseID), .text(e.title), .text(e.start), .text(e.end), .text(e.room), now])
                events += 1
            }
        }
        // eigene Eintraege (store_schedule_entries): Wochentag 0 = Montag, Uhrzeiten als "HH:MM". Entfernt wird nur,
        // was Stud.IP nicht mehr liefert; ein gelieferter, aber nicht lesbarer Eintrag behaelt seinen Stand (HTTP 200
        // ist noch kein gueltiger Datensatz), ein Eintrag ohne Kennung verhindert das Entfernen ganz.
        if let personal = d.personal {
            try replaceKeepingUnreadable(c, table: "studip_schedule_entries", items: personal, complete: !d.scheduleIncomplete)
            for r in personal {
                guard let p = readablePersonal(r) else { continue }
                try c.execute("""
                    INSERT INTO studip_schedule_entries(id, title, weekday, start, end, description, fetched_at) VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET title=excluded.title, weekday=excluded.weekday, start=excluded.start, end=excluded.end, description=excluded.description, fetched_at=excluded.fetched_at
                    """, [.text(p.id), .text(p.title), .integer(Int64(p.weekday)), .text(LocalFreeWindows.mh(p.start)),
                          .text(LocalFreeWindows.mh(p.end)), .text(p.description), now])
            }
        }
        // Ankuendigungen je gelesenem Kurs (announcements.store mit course_ids=[c["id"]]: Geloeschtes verschwindet)
        let today = BerlinClock.parseISODate(clock.today) ?? 0
        for (courseID, list) in d.news.sorted(by: { $0.key < $1.key }) {
            let items = list.compactMap { Announcements.fromStudIPNews($0, courseID: courseID, studipBase: d.studipBase, today: today) }
            _ = try Announcements.store(c, items, source: "studip", fetchedAt: clock.nowISO, courseIDs: [courseID])
        }
        var cycles = 0
        if let list = d.cycles {
            try c.executeScript(cycleTable)
            try replaceKeepingUnreadable(c, table: "studip_cycle_dates", items: list, complete: !d.scheduleIncomplete)
            for r in list {
                guard let (id, course) = readableCycle(r) else { continue }
                try c.execute("INSERT OR REPLACE INTO studip_cycle_dates(id, course_id, course_type, data, fetched_at) VALUES (?,?,?,?,?)",
                              [.text(id), .text(course), SQLiteValue(d.courseTypes[course]), .text(r.jsonString(sortedKeys: true)), now])
                cycles += 1
            }
        }
        // eigener Stud.IP-Kalender: Kurszeiten neu entscheiden (nach Kurszeiten und Einzelterminen)
        if let ids = d.calendar { try StudIPCalendar.store(ids: ids, in: c, clock: clock) }
        let r = try StudIPScheduleImport.autoImport(c, clock: clock)
        let q = try StudIPCalendar.questions(c)
        let open = (q["hidden"]?.array?.count ?? 0) + (q["busy"]?.array?.count ?? 0)
        return StudIPScheduleResult(newEvents: r.new, pendingGroups: r.pendingGroups, cycles: cycles, events: events,
                                    removedEvents: r.removed, openQuestions: open)
    }

    /// Vor dem Neuschreiben einer Tabelle (Kurszeiten, eigene Eintraege): Zeilen entfernen, deren Kennung Stud.IP
    /// nicht mehr liefert. Zeilen mit gelieferter Kennung bleiben (lesbare werden danach ueberschrieben, nicht
    /// lesbare behalten ihren Stand). Fehlt einem Eintrag die Kennung (`complete` false oder ein Eintrag ohne `id`),
    /// wird nichts entfernt.
    static func replaceKeepingUnreadable(_ c: SQLiteConnection, table: String, items: [JSONValue], complete: Bool) throws {
        var present = Set<String>()
        for r in items {
            guard let id = r["id"]?.string, !id.isEmpty else { return }
            present.insert(id)
        }
        guard complete else { return }
        for r in try c.rows("SELECT id FROM \(table)") {
            guard let id = r["id"]?.string, !present.contains(id) else { continue }
            try c.execute("DELETE FROM \(table) WHERE id=?", [.text(id)])
        }
    }

    /// Kurszeit, die sich lesen laesst: Kennung, Kurs als Eigentuemer, Wochentag und Uhrzeiten wie
    /// `StudIPSchedule.cycleEntry` sie braucht; sonst nil
    static func readableCycle(_ r: JSONValue) -> (id: String, course: String)? {
        let owner = r["relationships"]?["owner"]?["data"]
        guard let id = r["id"]?.string, !id.isEmpty, owner?["type"]?.string == "courses", let course = owner?["id"]?.string,
              StudIPSchedule.cycleEntry(r, courses: [:], courseTypes: [:]) != nil else { return nil }
        return (id, course)
    }

    /// Eigener Stundenplan-Eintrag, der sich lesen laesst (Kennung, Wochentag, Beginn und Ende); sonst nil
    static func readablePersonal(_ r: JSONValue) -> (id: String, title: String, weekday: Int, start: Int, end: Int, description: String)? {
        guard let id = r["id"]?.string, !id.isEmpty, let a = r["attributes"], let wd = StudIPSchedule.studipWeekday(a["weekday"] ?? 1),
              let s = StudIPSchedule.minutes(a["start"]?.string), let e = StudIPSchedule.minutes(a["end"]?.string) else { return nil }
        return (id, LocalTimetable.or(a["title"], "Termin").string ?? "Termin", wd, s, e, a["description"]?.string ?? "")
    }

    // MARK: Lesen

    /// Kurszeit mit Semester (fuer Termine ohne eigenen Zeitraum) und Eintrag in der Form von studip_entries.
    struct StoredCycle {
        var entry: StudIPScheduleEntry
        let term: StudIPTerm
        /// Modul und Art des Kurses aus der Tabelle courses
        let module: JSONValue
        let courseKind: JSONValue

        /// Eintrag in der Form von studip_entries: Modul aus dem Kurs; ist der Kurs als Uebung eingeordnet, ist es
        /// auch die Art (wie studip_entries)
        var json: [String: JSONValue] {
            var o = entry.json.object ?? [:]
            if entry.courseID != nil {
                o["module_id"] = module
                if courseKind == "uebung" { o["kind"] = "uebung" }
            }
            return o
        }
    }

    /// Gespeicherte Kurszeiten der aktiven Kurse (ohne "sonstiges"), gelesen von StudIPSchedule mit Titel und Nummer
    /// aus der Tabelle courses. Mit `relevance` nach dem eigenen Stud.IP-Kalender ausgewaehlt (`StudIPCalendar`,
    /// `relevant(_:_:)`), sonst alle. Leer, solange es die Tabelle noch nicht gibt.
    static func cycleEntries(_ c: SQLiteConnection, relevance: Bool = true) throws -> [StoredCycle] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_cycle_dates'") != nil else { return [] }
        let rows = try c.rows("""
            SELECT y.data, y.course_type, c.id AS course_id, c.title, c.number, c.module_id, c.kind
            FROM studip_cycle_dates y JOIN courses c ON c.id=y.course_id WHERE c.active=1 AND c.kind != 'sonstiges' ORDER BY y.id
            """)
        guard !rows.isEmpty else { return [] }
        var schedule: [JSONValue] = []
        var courses: [String: JSONValue] = [:]
        var info: [String: (module: JSONValue, kind: JSONValue)] = [:]
        for r in rows {
            guard let course = r["course_id"]?.string, let text = r["data"]?.string, let data = try? JSONValue.parse(text) else { continue }
            schedule.append(data)
            courses[course] = ["id": .string(course), "type": "courses",
                               "attributes": ["title": r["title"] ?? .null, "course-number": r["number"] ?? .null, "course-type": r["course_type"] ?? .null]]
            info[course] = (r["module_id"] ?? .null, r["kind"] ?? .null)
        }
        let tt = StudIPSchedule.timetable(schedule: schedule, courses: courses.keys.sorted().compactMap { courses[$0] })
        let t = try LocalTimetable.term(c)
        let term = StudIPTerm(start: t["start"]?.string ?? "", end: t["end"]?.string ?? "")
        let all = tt.entries.map { e in
            let i = e.courseID.flatMap { info[$0] }
            return StoredCycle(entry: e, term: term, module: i?.module ?? .null, courseKind: i?.kind ?? .null)
        }
        return relevance ? try relevant(c, all) : all
    }

    /// Auswahl nach dem eigenen Stud.IP-Kalender. Ohne gespeicherte Entscheidungen alle (bisherige Regel). Sonst:
    /// relevante Kurszeiten sind eindeutig und werden uebernommen (keine Gruppenwahl), nicht relevante fehlen. Gleiche
    /// Zeiten desselben Kurses (mehrere Raeume) ergeben eine Serie: die mit passendem Raum, sonst die erste.
    /// Unentschiedene Kurszeiten (ganz vergangen) bleiben, ausser ihr Kurs fehlt laut Kalender ganz oder sie waeren
    /// eine Gruppe zur Auswahl in einem Kurs, dessen eigene Gruppe der Kalender schon kennt. Kurse ohne
    /// Kalendertermine fehlen bis zur Antwort des Nutzers; uebernimmt er sie, gilt fuer sie die bisherige Regel.
    static func relevant(_ c: SQLiteConnection, _ cycles: [StoredCycle]) throws -> [StoredCycle] {
        let decisions = try StudIPCalendar.decisions(c)
        guard !decisions.isEmpty else { return cycles }
        let hidden = try StudIPCalendar.hiddenCourses(c), decided = try StudIPCalendar.decidedCourses(c)
        let choices = try StudIPCalendar.choices(c)
        var out: [StoredCycle] = [], rank: [Int] = [], seen: [String: Int] = [:]
        for var cy in cycles {
            let e = cy.entry
            if let course = e.courseID, hidden.contains(course), choices[course]?.include == true {
                out.append(cy)
                rank.append(-1)
                continue
            }
            guard let v = decisions[e.id] else {
                if let course = e.courseID, decided.contains(course), hidden.contains(course) || !e.selected { continue }
                out.append(cy)
                rank.append(-1)
                continue
            }
            guard v > 0 else { continue }
            cy.entry.selected = true
            cy.entry.uncertain = false
            cy.entry.hint = nil
            let k = StudIPCalendar.sameTime(e) + "|\(e.interval)|\(e.dateFrom ?? "")|\(e.dateTo ?? "")"
            if let i = seen[k] {
                if v > rank[i] { out[i] = cy; rank[i] = v }
                continue
            }
            seen[k] = out.count
            out.append(cy)
            rank.append(v)
        }
        return out
    }
}
