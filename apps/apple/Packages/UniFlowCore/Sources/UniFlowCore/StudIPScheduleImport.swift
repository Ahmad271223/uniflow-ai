import Foundation

// Uebernahme der Stud.IP-Termine in den Stundenplan auf dem Geraet: `auto_import` aus app/timetable.py, dazu die nur
// auf dem Geraet vorhandene Tabelle studip_timetable_links (bei Bedarf angelegt wie studip_cycle_dates). Sie merkt
// sich, welcher Stud.IP-Eintrag zu welcher Serie in course_events wurde und welche Ausfaelle schon uebernommen sind.
// Der Abgleich laeuft hier bei jedem Oeffnen der App (hoechstens alle 30 Minuten); was auf dem PC selten auffaellt,
// stoert dann bei jedem Lauf:
// - Ein uebernommener Eintrag wird nicht wieder angelegt, auch wenn der Nutzer die Serie geloescht oder Titel bzw.
//   Wochentag geaendert hat (auto_import vergleicht nur Titel und Wochentag und legt sie sonst neu an).
// - Ausfaelle (EXDATES), die Stud.IP erst spaeter meldet, kommen bei jedem Abgleich in die verknuepfte Serie, auch
//   in die gewaehlte Uebungsgruppe; nicht mehr gemeldete Ausfaelle laut Stud.IP entfallen. Tage mit einer anderen
//   Ausnahme und Ausfaelle, die der Nutzer schon zurueckgesetzt hat, bleiben, wie er sie gelassen hat.
// - Gruppen, aus denen schon eine Kurszeit im Stundenplan steht, zaehlen nicht mehr als offen.
// Ohne Kurszeiten (nur Einzeltermine) bleibt die Zahl offener Gruppen wie in Python.

enum StudIPScheduleImport {
    typealias Entry = [String: JSONValue]

    static let linkTable = """
        CREATE TABLE IF NOT EXISTS studip_timetable_links (
            entry_key TEXT PRIMARY KEY,        -- Stud.IP-Eintrag (key(_:))
            event_id INTEGER NOT NULL,         -- Serie in course_events; fehlt sie, hat der Nutzer sie geloescht
            exdates TEXT NOT NULL DEFAULT '[]', -- schon uebernommene Ausfaelle (JSON-Liste mit ISO-Daten)
            created_at TEXT
        )
        """

    static let note = "Ausfall laut Stud.IP"

    struct Link: Equatable {
        let eventID: Int64
        let exdates: [String]
    }

    // MARK: Abgleich

    /// `auto_import(conn)` auf dem Geraet: eindeutige Stud.IP-Eintraege, die noch nicht verknuepft sind, uebernehmen
    /// (eine schon vorhandene gleiche Serie wird verknuepft statt neu angelegt), danach die Ausfaelle aller
    /// verknuepften Serien nachziehen. Liefert die Zahl neuer Serien und die Eintraege offener Gruppen. Wie
    /// `auto_import` zuerst `ensure_modules`: der Abgleich speichert neue Kurse direkt davor, ihre Termine sollen das
    /// Modul ihres Fachs bekommen (sonst fehlen ihnen dauerhaft die Unterlagen zum Termin).
    static func autoImport(_ c: SQLiteConnection, clock: UniFlowClock) throws -> (new: Int, pendingGroups: Int, removed: Int) {
        try LocalModules.ensureModules(c, clock: clock)
        try c.executeScript(linkTable)
        let removed = try removeOutsideCalendar(c)
        let all = try LocalTimetableImport.studipEntries(c)
        var links = try readLinks(c)
        var taken = Set(links.values.map(\.eventID))
        var fresh: [Entry] = []
        for e in all where LocalModules.truthy(e["selected"]) {
            let k = key(e)
            guard links[k] == nil else { continue }
            if let id = try sameSeries(c, e, except: taken) {
                try link(c, key: k, eventID: .integer(id), exdates: [], clock: clock)
                links[k] = Link(eventID: id, exdates: [])
                taken.insert(id)
            } else {
                fresh.append(e)
            }
        }
        // Was schon im Stundenplan steht, bleibt unangetastet - aber nur echte Doppel: gleicher Kurs (oder ohne Kurs
        // derselbe ganze Titel), gleicher Tag, ueberlappende Zeit. `diffAgainstExisting` (Titel auf 30 Zeichen +
        // Wochentag, fuer ICS-Importe) hielt verschiedene Kurse mit gleichem Titelanfang fuer eine Serie: die
        // Fragestunde neben der Vorlesung am selben Tag fehlte (Befund mit echten Daten 27.10.2026)
        let entries = try LocalTimetableImport.enrich(c, fresh)
        let existing = try c.rows("SELECT title, course_id, weekday, start_time, end_time FROM course_events WHERE source != 'personal'")
        let new: [JSONValue] = entries.filter { e in !existing.contains { Self.isDouble(e, $0) } }.map(JSONValue.object)
        // vom Nutzer abgewaehlte Kurszeiten (Kurs mit vielen Serien) kommen gleich als "nicht besucht"
        let skipped = try StudIPCalendar.skippedTimes(c)
        let res = try LocalTimetableImport.applyImport(c, new, source: "studip", clock: clock) { e, id in
            try link(c, key: key(e), eventID: id, exdates: isoDates(e["exdates"]) ?? [], clock: clock)
            if let cycle = e["studip_id"]?.string, skipped.contains(cycle) { try c.execute("UPDATE course_events SET attend=0 WHERE id=?", [id]) }
        }
        try c.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES ('studip-auto', ?, 'auto', '', ?, 1)",
                      [.text(clock.nowISO), .text(JSONValue.array(new).jsonString(sortedKeys: true))])
        links = try readLinks(c)
        for e in all {
            let k = key(e)
            if let l = links[k] { try refresh(c, key: k, link: l, exdates: e["exdates"], clock: clock) }
        }
        return (res["new"]?.int ?? 0, try openGroups(c, all).count, removed)
    }

    /// Serien, deren Kurszeit laut eigenem Stud.IP-Kalender nicht (mehr) zum Nutzer gehoert (StudIPCalendar: nicht
    /// relevant, oder unentschieden in einem Kurs, der dort ganz fehlt), entfernen samt Verknuepfung. Serien mit
    /// eigener Aenderung bleiben (`untouched`), ebenso Kurszeiten, die Stud.IP gar nicht mehr liefert (wie bisher).
    /// Ohne Kalender aendert sich nichts. Liefert die Zahl entfernter Serien.
    static func removeOutsideCalendar(_ c: SQLiteConnection) throws -> Int {
        let decisions = try StudIPCalendar.decisions(c)
        guard !decisions.isEmpty else { return 0 }
        // Kurse ohne Kalendertermine, die der Nutzer uebernommen hat, bleiben
        let choices = try StudIPCalendar.choices(c)
        let allHidden = try StudIPCalendar.hiddenCourses(c)
        let included = allHidden.filter { choices[$0]?.include == true }
        let hidden = allHidden.subtracting(included)
        var cycles: [String: StudIPScheduleStore.StoredCycle] = [:]
        for cy in try StudIPScheduleStore.cycleEntries(c, relevance: false) { cycles[cy.entry.id] = cy }
        var removed = 0
        for (k, l) in try readLinks(c).sorted(by: { $0.key < $1.key }) where k.hasPrefix("cycle:") {
            guard let cy = cycles[String(k.dropFirst("cycle:".count))] else { continue }
            if let course = cy.entry.courseID, included.contains(course) { continue }
            let outside = decisions[cy.entry.id].map { $0 == 0 } ?? cy.entry.courseID.map(hidden.contains) ?? false
            guard outside, try untouched(c, eventID: l.eventID, cy.json) else { continue }
            try c.execute("DELETE FROM event_exceptions WHERE event_id=?", [.integer(l.eventID)])
            try c.execute("DELETE FROM course_events WHERE id=?", [.integer(l.eventID)])
            try c.execute("DELETE FROM studip_timetable_links WHERE entry_key=?", [.text(k)])
            removed += 1
        }
        return removed
    }

    /// Serie so, wie der Import sie angelegt hat: Quelle Stud.IP, besucht, Titel, Tag, Zeiten und Ende wie die
    /// Kurszeit, keine Notiz und keine Ausnahme ausser den Ausfaellen laut Stud.IP. Eine geloeschte Serie zaehlt nicht
    /// (ihre Verknuepfung bleibt, damit sie nicht zurueckkommt).
    static func untouched(_ c: SQLiteConnection, eventID: Int64, _ e: Entry) throws -> Bool {
        let id: SQLiteValue = .integer(eventID)
        guard let r = try c.rows("SELECT * FROM course_events WHERE id=?", [id]).first,
              (r["source"]?.string ?? "").hasPrefix("studip"), (r["attend"]?.int ?? 1) == 1,
              r["weekday"]?.int == e["weekday"]?.int else { return false }
        for f in ["title", "start_time", "end_time", "date_to"] where r[f]?.string != e[f]?.string { return false }
        if try c.queryOne("SELECT 1 FROM event_notes WHERE event_id=?", [id]) != nil { return false }
        return try c.queryOne("SELECT 1 FROM event_exceptions WHERE event_id=? AND NOT (type='cancelled' AND note IS ?)", [id, .text(note)]) == nil
    }

    /// Fuer POST /api/timetable/import/confirm: aus Stud.IP uebernommene Eintraege (Quelle "studip", z. B. die
    /// gewaehlte Uebungsgruppe) verknuepfen, damit der Abgleich ihre Ausfaelle nachzieht. Andere Quellen: nil.
    static func confirmed(_ c: SQLiteConnection, source: String, clock: UniFlowClock) -> ((Entry, SQLiteValue) throws -> Void)? {
        guard source.hasPrefix("studip") else { return nil }
        return { e, id in try link(c, key: key(e), eventID: id, exdates: isoDates(e["exdates"]) ?? [], clock: clock) }
    }

    /// Vorschau "aus Stud.IP": Kurszeiten ueber die Verknuepfung ihrer Serie zuordnen. `diff_against_existing` paart
    /// nach Titel und Wochentag; liegen zwei Serien eines Kurses am selben Tag (z. B. Vorlesung und Uebungsgruppe),
    /// traefe die Gruppenwahl sonst die Vorlesung. Je Kurszeit: die eigene Serie; sonst (nur Gruppenoptionen) die Serie
    /// einer anderen Gruppe derselben Art am selben Wochentag (Gruppe wechseln); gehoert die nach Titel und Wochentag
    /// gefundene Serie einem anderen Stud.IP-Eintrag, ist die Kurszeit neu. Alles andere bleibt wie in Python.
    static func previewDiff(_ c: SQLiteConnection, _ diff: JSONValue, entries: [Entry]) throws -> JSONValue {
        let links = try readLinks(c)
        guard !links.isEmpty, var out = diff.object else { return diff }
        var groupOf: [String: String] = [:]
        for e in entries where e["studip_id"]?.string != nil { groupOf[key(e)] = group(e) }
        let owned = Set(links.values.map(\.eventID))
        func row(_ id: Int64?) throws -> [String: JSONValue]? {
            guard let id else { return nil }
            return try c.rows("SELECT id, weekday, start_time, end_time FROM course_events WHERE id=?", [.integer(id)]).first
        }
        var lists: [String: [JSONValue]] = ["new": [], "changed": [], "same": []]
        for name in ["new", "changed", "same"] {
            for item in diff[name]?.array ?? [] {
                guard var o = item.object, o["studip_id"]?.string != nil else { lists[name, default: []].append(item); continue }
                let k = key(o)
                var target = try row(links[k]?.eventID)
                // Gruppe wechseln nur bei Optionen paralleler Gruppen (eindeutige Kurszeiten haben ihre eigene Serie)
                if target == nil, !LocalModules.truthy(o["selected"]), let g = groupOf[k] {
                    for (k2, l2) in links.sorted(by: { $0.key < $1.key }) where k2 != k && groupOf[k2] == g {
                        if let r = try row(l2.eventID), r["weekday"]?.int == o["weekday"]?.int { target = r; break }
                    }
                }
                for f in ["existing_id", "old_start", "old_end"] { o.removeValue(forKey: f) }
                if let t = target {
                    o["existing_id"] = t["id"] ?? .null
                    if t["start_time"] != o["start_time"] || t["end_time"] != o["end_time"] {
                        o["old_start"] = t["start_time"] ?? .null
                        o["old_end"] = t["end_time"] ?? .null
                        lists["changed", default: []].append(.object(o))
                    } else {
                        lists["same", default: []].append(.object(o))
                    }
                } else if name != "new", let x = item["existing_id"]?.int, owned.contains(Int64(x)) {
                    lists["new", default: []].append(.object(o))
                } else {
                    lists[name, default: []].append(item)
                }
            }
        }
        for (name, list) in lists { out[name] = .array(list) }
        return .object(out)
    }

    /// Offene Gruppenauswahl wie `pending_groups` (nicht ausgewaehlte Eintraege). Gruppen aus Kurszeiten zaehlen nicht
    /// mehr, sobald eine ihrer Kurszeiten im Stundenplan steht: verknuepft oder mit gleichem Kurs, Wochentag und
    /// Beginn (so gewaehlt, bevor es die Verknuepfung gab). Ohne Kurszeiten wie in Python.
    static func openGroups(_ c: SQLiteConnection, _ all: [Entry]) throws -> [Entry] {
        let pending = all.filter { !LocalModules.truthy($0["selected"]) }
        guard pending.contains(where: { $0["studip_id"]?.string != nil }) else { return pending }
        let links = try readLinks(c)
        var decided = Set<String>()
        for e in pending where e["studip_id"]?.string != nil && !decided.contains(group(e)) {
            if let l = links[key(e)], try c.queryOne("SELECT 1 FROM course_events WHERE id=?", [.integer(l.eventID)]) != nil {
                decided.insert(group(e))
            } else if e["course_id"]?.string != nil, try c.queryOne("SELECT 1 FROM course_events WHERE course_id=? AND weekday=? AND start_time=?",
                                                                    [try LocalTimetable.bind(e["course_id"], "course_id"),
                                                                     .integer(Int64(try LocalTimetable.int(e["weekday"], "weekday"))),
                                                                     try LocalTimetable.bind(e["start_time"], "start_time")]) != nil {
                decided.insert(group(e))
            }
        }
        return pending.filter { $0["studip_id"]?.string == nil || !decided.contains(group($0)) }
    }

    // MARK: Verknuepfung

    /// Gruppe einer Kurszeit: Kurs und Art (wie StudIPSchedule.groupKey)
    static func group(_ e: Entry) -> String { LocalTimetable.text(e["course_id"]) + "|" + LocalTimetable.text(e["art"]) }

    /// Kennung eines Eintrags aus studip_entries: Kurszeiten ueber ihre Stud.IP-ID, eigene Eintraege und aus
    /// Einzelterminen abgeleitete Serien ueber Kurs, Titel, Wochentag, Uhrzeit und Rhythmus (einmalige mit Tag)
    static func key(_ e: Entry) -> String {
        if let id = e["studip_id"]?.string { return "cycle:" + id }
        var parts = ["course_id", "title", "weekday", "start_time", "end_time", "rrule"].map { LocalTimetable.text(e[$0]) }
        if e["rrule"]?.string == "once" { parts.append(LocalTimetable.text(e["date_from"])) }
        return (LocalModules.truthy(e["personal"]) ? "personal:" : "series:") + parts.joined(separator: "|")
    }

    /// Gespeicherte Verknuepfungen; leer, solange es die Tabelle nicht gibt
    static func readLinks(_ c: SQLiteConnection) throws -> [String: Link] {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_timetable_links'") != nil else { return [:] }
        var out: [String: Link] = [:]
        for r in try c.rows("SELECT entry_key, event_id, exdates FROM studip_timetable_links") {
            guard let k = r["entry_key"]?.string, let id = r["event_id"]?.int else { continue }
            let dates = (r["exdates"]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) }
            out[k] = Link(eventID: Int64(id), exdates: isoDates(dates) ?? [])
        }
        return out
    }

    /// Eintrag mit seiner Serie verknuepfen (nur, wenn es die Serie gibt). Eine Serie gehoert zu hoechstens einem
    /// Eintrag: waehlt der Nutzer eine andere Gruppe fuer dieselbe Serie, entfaellt die alte Verknuepfung.
    static func link(_ c: SQLiteConnection, key: String, eventID: SQLiteValue, exdates: [String], clock: UniFlowClock) throws {
        guard let id = try c.queryOne("SELECT id FROM course_events WHERE id=?", [eventID])?["id"]?.int64 else { return }
        try c.executeScript(linkTable)
        try c.execute("DELETE FROM studip_timetable_links WHERE event_id=? AND entry_key != ?", [.integer(id), .text(key)])
        try c.execute("""
            INSERT INTO studip_timetable_links(entry_key, event_id, exdates, created_at) VALUES (?,?,?,?)
            ON CONFLICT(entry_key) DO UPDATE SET event_id=excluded.event_id, exdates=excluded.exdates
            """, [.text(key), .integer(id), .text(json(exdates)), .text(clock.nowISO)])
    }

    /// Ausfaelle einer verknuepften Serie an die Meldung von Stud.IP angleichen: neu gemeldete Tage werden Ausnahme
    /// "cancelled" (ausser der Tag hat schon eine Ausnahme), nicht mehr gemeldete Ausfaelle laut Stud.IP entfallen.
    /// Schon uebernommene Tage fasst der Abgleich nicht wieder an. Nur Kurszeiten melden Ausfaelle (`exdates`).
    static func refresh(_ c: SQLiteConnection, key: String, link l: Link, exdates: JSONValue?, clock: UniFlowClock) throws {
        guard let now = isoDates(exdates), now != l.exdates else { return }
        let id: SQLiteValue = .integer(l.eventID)
        guard try c.queryOne("SELECT 1 FROM course_events WHERE id=?", [id]) != nil else { return }
        let before = Set(l.exdates), current = Set(now)
        for d in l.exdates where !current.contains(d) {
            try c.execute("DELETE FROM event_exceptions WHERE event_id=? AND date=? AND type='cancelled' AND note=?", [id, .text(d), .text(note)])
        }
        try LocalTimetableImport.addCancellations(c, eventID: id, dates: .array(now.filter { !before.contains($0) }.map(JSONValue.string)),
                                                  note: note, clock: clock)
        try c.execute("UPDATE studip_timetable_links SET exdates=? WHERE entry_key=?", [.text(json(now)), .text(key)])
    }

    /// Noch nicht verknuepfte Serie, die genau diesem Eintrag entspricht (Titel, Kurs, Wochentag, Beginn)
    static func sameSeries(_ c: SQLiteConnection, _ e: Entry, except taken: Set<Int64>) throws -> Int64? {
        let rows = try c.rows("""
            SELECT id FROM course_events WHERE source != 'personal' AND title=? AND course_id IS ? AND weekday=? AND start_time=? ORDER BY id
            """, [try LocalTimetable.bind(e["title"], "title"), try LocalTimetable.bind(e["course_id"], "course_id"),
                  .integer(Int64(try LocalTimetable.int(e["weekday"], "weekday"))), try LocalTimetable.bind(e["start_time"], "start_time")])
        return rows.compactMap { $0["id"]?.int.map(Int64.init) }.first { !taken.contains($0) }
    }

    // MARK: Hilfen

    /// Steht diese Stud.IP-Serie schon im Stundenplan? Gleicher Wochentag, ueberlappende Zeit und derselbe Kurs (ohne
    /// Kurs auf beiden Seiten: derselbe Titel, Gross-/Kleinschreibung und Leerraum egal)
    static func isDouble(_ e: Entry, _ x: [String: JSONValue]) -> Bool {
        guard e["weekday"]?.int == x["weekday"]?.int,
              let es = minutes(e["start_time"]), let ee = minutes(e["end_time"]),
              let xs = minutes(x["start_time"]), let xe = minutes(x["end_time"]), es < xe, xs < ee else { return false }
        let ec = e["course_id"]?.string, xc = x["course_id"]?.string
        if let ec, let xc { return ec == xc }
        guard ec == nil, xc == nil else { return false }
        func norm(_ v: JSONValue?) -> String { (v?.string ?? "").lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return norm(e["title"]) == norm(x["title"])
    }

    /// "HH:MM" -> Minuten seit Mitternacht; nil bei anderem Format
    static func minutes(_ v: JSONValue?) -> Int? {
        let p = (v?.string ?? "").split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Gueltige ISO-Daten einer Liste (wie `_add_cancellations`), ohne Doppelte, sortiert; nil ohne Liste
    static func isoDates(_ v: JSONValue?) -> [String]? {
        guard let list = v?.array else { return nil }
        let valid = list.compactMap(\.string).filter { s in
            s.utf8.count == 10 && s.utf8.enumerated().allSatisfy { i, b in (i == 4 || i == 7) ? b == 0x2D : (0x30...0x39).contains(b) }
        }
        return Set(valid).sorted()
    }

    static func json(_ dates: [String]) -> String {
        JSONValue.array(dates.map(JSONValue.string)).jsonString(sortedKeys: true)
    }
}
