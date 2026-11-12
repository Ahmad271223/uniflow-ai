import Foundation

/// Stundenplan wie app/timetable.py: Vorkommen der Serien mit Ausnahmen (`occurrences`, `_matches`), Tages- und
/// Wochenansicht (`day_timeline`, `week_grid`), Ausnahmen und Teilnahme (`set_exception`, `set_attendance`),
/// Unterlagen zum Termin (`materials_for_event`) und Konflikte mit Lernslots (`study.slot_conflicts`, gehoert zu
/// /api/timetable/conflicts). Freie Fenster: `LocalFreeWindows`, Import: `LocalTimetableImport`.
///
/// Tage sind Tagesnummern wie in `BerlinClock` (Tage seit 1970-01-01), Datumsangaben in der Datenbank ISO-Texte,
/// Uhrzeiten "HH:MM". Zeilen werden als JSON-Objekte gelesen (`db.rows`), damit die Antworten Feld fuer Feld wie in
/// Python bleiben. Ergebnisgleichheit mit Python: `LocalTimetableTests` gegen timetable-logic.json.
enum LocalTimetable {

    // MARK: Python-Werte

    // Wahrheitswert wie in Python (`x or y`, `if x`): LocalModules.truthy

    /// `a or b`
    static func or(_ a: JSONValue?, _ b: JSONValue) -> JSONValue { LocalModules.truthy(a) ? a! : b }

    /// `int(v)`: Zahl (abgeschnitten), Wahrheitswert, Text mit ganzer Zahl. Was Python scheitern laesst, wird 500.
    static func int(_ v: JSONValue?, _ field: String) throws -> Int {
        switch v {
        case .number(let n)?:
            guard n.isFinite, abs(n) < 9.0e15 else { throw LocalHTTPError(status: 500, message: "\(field) ist keine ganze Zahl") }
            return Int(n)
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?:
            guard let i = PyConvert.int(s) else { throw LocalHTTPError(status: 500, message: "\(field) ist keine ganze Zahl: \(s)") }
            return i
        default:
            throw LocalHTTPError(status: 500, message: "\(field) fehlt oder ist keine Zahl")
        }
    }

    /// Wert zum Binden wie Pythons sqlite3; Listen und Objekte lassen sich dort nicht binden (500)
    static func bind(_ v: JSONValue?, _ field: String) throws -> SQLiteValue {
        guard let v else { return .null }
        guard let s = SQLiteValue(json: v) else {
            throw LocalHTTPError(status: 500, message: "\(field): Listen und Objekte lassen sich nicht speichern")
        }
        return s
    }

    /// `str(v)` in f-Texten ("None" fuer fehlende Werte)
    static func text(_ v: JSONValue?) -> String {
        switch v {
        case nil, .null?: return "None"
        case .bool(let b)?: return b ? "True" : "False"
        case .number(let n)?: return JSONValue.format(n)
        case .string(let s)?: return s
        case let x?: return x.jsonString()
        }
    }

    /// Textvergleich `a <= b` wie Python (nach Codepunkten). Andere Typen scheitern in Python (500).
    static func lessOrEqual(_ a: JSONValue, _ b: JSONValue) throws -> Bool {
        guard let x = a.string, let y = b.string else {
            throw LocalHTTPError(status: 500, message: "Datum ist kein Text")
        }
        return !y.unicodeScalars.lexicographicallyPrecedes(x.unicodeScalars)
    }

    /// Datum aus der Query wie `date.fromisoformat` (Python antwortet bei falschem Datum mit 500, hier 422)
    static func queryDay(_ req: LocalRequest, _ name: String) throws -> Int {
        let text = try req.requiredQuery(name)
        guard let d = BerlinClock.parseISODate(text) else {
            throw LocalHTTPError(status: 422, message: "Ungültiges Datum: \(text)")
        }
        return d
    }

    /// `date.fromisoformat(v)` fuer Werte aus Anfragen und der Datenbank (500 wie in Python; die Lernpfade antworten
    /// mit 422, `status`)
    static func day(_ v: JSONValue?, _ field: String, status: Int = 500) throws -> Int {
        guard let s = v?.string, let d = BerlinClock.parseISODate(s) else {
            throw LocalHTTPError(status: status, message: "Ungültiges Datum in \(field): \(text(v))")
        }
        return d
    }

    /// Laengster Zeitraum in Tagen fuer Stundenplan, Konflikte, Lernkalender und Planung (Schutz vor endlosen
    /// Schleifen; Python kennt keine Grenze)
    static let maxDays = 3660

    /// Zeitraum pruefen: hoechstens `maxDays` Tage, sonst 422
    static func span(_ n: Int) throws -> Int {
        guard n <= maxDays else { throw LocalHTTPError(status: 422, message: "Höchstens \(maxDays) Tage") }
        return n
    }

    static func iso(_ day: Int) -> String { BerlinClock.isoDate(day) }

    static func weekday(_ day: Int) -> Int { BerlinClock.weekday(day) }

    static func today(_ clock: UniFlowClock) -> Int { BerlinClock.parseISODate(clock.today) ?? 0 }

    /// Stabil sortieren (wie `sorted`/`list.sort` in Python)
    static func stableSorted<T>(_ items: [T], by less: (T, T) throws -> Bool) rethrows -> [T] {
        try items.enumerated().sorted { a, b in
            if try less(a.element, b.element) { return true }
            if try less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Semester und Sperrzeiten

    /// `term(conn)`
    static func term(_ c: SQLiteConnection) throws -> JSONValue { try LocalTerms.current(c) }

    /// Sperrzeiten eines Wochentags: `[b for b in s["blocked_times"] if int(b.get("weekday", -1)) == d.weekday()]`
    static func blocked(_ day: Int, settings s: [String: JSONValue]) throws -> [JSONValue] {
        let wd = weekday(day)
        return try (s["blocked_times"]?.array ?? []).filter { b in
            guard let o = b.object else { throw LocalHTTPError(status: 500, message: "Sperrzeit ist kein Objekt") }
            guard let w = o["weekday"] else { return -1 == wd }
            return try int(w, "Wochentag der Sperrzeit") == wd
        }
    }

    // MARK: Modul eines Termins

    /// Modul eines Termins (Auftrag 12.11.2026, "richtiges Modul"): das Modul seines Kurses, sonst das der Serie. Die
    /// Serie merkt sich das Modul beim Import (`apply_import`); wird der Kurs danach einem anderen Modul zugeordnet
    /// (`POST /api/courses/{id}/module`, z. B. "Übung zu Mathematik II" lag zuerst unter "Mathematik I"), blieb der
    /// Termin beim alten Modul: "Zum Modul" im Lernkalender und Stundenplan oeffnete das falsche Fach, der Modulfilter
    /// zeigte ihn dort und die "Passenden Unterlagen" kamen aus dem falschen Modul. Kurs ↔ Modul ist die eine
    /// Zuordnung, nach der auch die Dateien eines Moduls gehen (`LocalModules.fileRows`).
    static let eventModuleSQL = "COALESCE((SELECT ec.module_id FROM courses ec WHERE ec.id=e.course_id AND ec.module_id IS NOT NULL), e.module_id)"

    /// Zeile aus `course_events e` mit `module_ref` (`eventModuleSQL`): `module_id` ist danach das Modul des Kurses
    static func withCourseModule(_ row: [String: JSONValue]) -> [String: JSONValue] {
        var r = row
        r["module_id"] = r.removeValue(forKey: "module_ref") ?? r["module_id"] ?? .null
        return r
    }

    // MARK: Vorkommen

    /// `UNI_KINDS`: Arten, die an Feiertagen und in der vorlesungsfreien Zeit ausfallen
    static let uniKinds: Set<String> = ["vorlesung", "uebung", "hoersaaluebung", "gruppenuebung", "tutorium", "labor", "seminar"]

    /// `occurrences(conn, start, end, include_skipped)`: alle Termine im Zeitraum mit angewendeten Ausnahmen
    /// (verschoben, ausgefallen, nicht besucht), dazu hierher verschobene Termine anderer Tage und die Einzeltermine aus
    /// dem eigenen Stud.IP-Kalender (`studipDated`, `mergeDated`, PC-Stand e9a40d1/81eecf0); nach Datum und Beginn.
    /// Serien ohne eigenen Zeitraum fallen an Feiertagen und in der vorlesungsfreien Zeit aus (`exception`
    /// "vorlesungsfrei" mit `note`); eine Bemerkung der Quelle (`event_notes`, LSF) steht als `note`. Jedes Vorkommen
    /// traegt `source` (Quelle der Serie, bei Einzelterminen "studip-kalender").
    static func occurrences(_ c: SQLiteConnection, from start: Int, to end: Int, includeSkipped: Bool = true) throws -> [JSONValue] {
        let events = try c.rows("""
            SELECT e.*, \(eventModuleSQL) AS module_ref, m.name AS module_name, m.color AS module_color
            FROM course_events e LEFT JOIN modules m ON m.id=\(eventModuleSQL)
            """).map(withCourseModule)
        let dated = try studipDated(c, from: start, to: end)
        if events.isEmpty {
            // dazu eigene Sprechstunden aus Stud.IP (`studip_extras.with_consultations`)
            return try SOGoCalendar.withCalendar(c, try StudIPExtras.withConsultations(c, try Announcements.markCancellations(
                c, dated.map(JSONValue.object).filter { includeSkipped || $0["status"] != "nicht_teilnahme" }), from: start, to: end),
                from: start, to: end)                                                   // + Termine des Uni-Kalenders (SOGo)
        }
        let ids = events.compactMap { $0["id"].flatMap(SQLiteValue.init(json:)) }
        // je Termin und Datum die Ausnahme; bei mehreren gilt wie im dict von Python die letzte
        var exc: [JSONValue: [String: [String: JSONValue]]] = [:]
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        for x in try c.rows("SELECT * FROM event_exceptions WHERE event_id IN (\(marks))", ids) {
            guard let eid = x["event_id"], let d = x["date"]?.string else { continue }
            exc[eid, default: [:]][d] = x
        }
        let t = try term(c)
        // Serien ohne eigene Daten (z. B. persoenliche Stud.IP-Stundenplan-Eintraege) kennen weder Ferien noch
        // Feiertage: an Feiertagen, in Unterbrechungen und in der vorlesungsfreien Zeit fallen Uni-Veranstaltungen
        // aus (Holidays wie app/holidays.py). Serien mit Daten aus der Quelle (LSF-EXDATE, Stud.IP-Einzeltermine)
        // regeln das selbst; persoenliche Termine nie.
        let free = Holidays.dayMarks(from: start, to: end, university: try Holidays.university(c), studip: try StudIPTerms.load(c))
        var notes: [JSONValue: JSONValue] = [:]
        for r in try c.rows("SELECT event_id, note FROM event_notes") { notes[r["event_id"] ?? .null] = r["note"] ?? .null }
        var out: [JSONValue] = []
        var d = start
        while d <= end {
            let di = iso(d)
            for e in events {
                guard try matches(e, day: d, term: t) else { continue }
                let x = e["id"].flatMap { exc[$0]?[di] }
                let note = e["id"].flatMap { notes[$0] }
                var occ: [String: JSONValue] = [
                    "event_id": e["id"] ?? .null, "date": .string(di), "start": e["start_time"] ?? .null, "end": e["end_time"] ?? .null,
                    "title": e["title"] ?? .null, "kind": e["kind"] ?? .null, "module_id": e["module_id"] ?? .null,
                    "module_name": e["module_name"] ?? .null,
                    "color": or(e["color"], or(e["module_color"], "#4f5bd5")), "room": e["room"] ?? .null,
                    "lecturer": e["lecturer"] ?? .null, "course_id": e["course_id"] ?? .null,
                    "status": LocalModules.truthy(e["attend"]) ? "teilnahme" : "nicht_teilnahme", "permanent_skip": .bool(!LocalModules.truthy(e["attend"])),
                    "exception": .null, "source": e["source"] ?? .null,
                ]
                if LocalModules.truthy(note) { occ["note"] = note }          // nur mit Bemerkung (Antwortform sonst unveraendert)
                if let x {
                    let type = x["type"] ?? .null
                    occ["exception"] = type
                    switch type.string {
                    case "skip": occ["status"] = "nicht_teilnahme"
                    case "attend": occ["status"] = "teilnahme"
                    case "cancelled": occ["status"] = "ausfall"
                    case "moved", "edit":
                        occ["start"] = or(x["new_start"], occ["start"] ?? .null)
                        occ["end"] = or(x["new_end"], occ["end"] ?? .null)
                        if type.string == "moved", LocalModules.truthy(x["new_date"]), x["new_date"] != .string(di) {
                            occ["moved_to"] = x["new_date"]
                            occ["status"] = "verschoben"
                        }
                    default: break
                    }
                }
                if x == nil, LocalModules.truthy(e["attend"]), let marks = free[di], !LocalModules.truthy(e["date_from"]),
                   !LocalModules.truthy(e["date_to"]), let kind = or(e["kind"], "vorlesung").string, uniKinds.contains(kind) {
                    occ["status"] = "ausfall"
                    occ["exception"] = "vorlesungsfrei"
                    // " / ".join(dict.fromkeys(labels)) + (" · " + note)
                    var labels: [String] = []
                    for m in marks { if let l = m["label"]?.string, !labels.contains(l) { labels.append(l) } }
                    var text = labels.joined(separator: " / ")
                    if LocalModules.truthy(note) { text += " · \(LocalTimetable.text(note))" }
                    occ["note"] = .string(text)
                }
                // nicht besuchte erst nach dem Zusammenfuehren weglassen: sonst stand ihr Stud.IP-Einzeltermin wieder als
                // besucht in der Woche (Befund 10.11.2026)
                out.append(.object(occ))
            }
            // Hierher verschobene Termine anderer Tage
            for x in try c.rows("SELECT x.*, e.* , x.id AS xid FROM event_exceptions x JOIN course_events e ON e.id=x.event_id WHERE x.type='moved' AND x.new_date=? AND x.date!=?",
                                [.text(di), .text(di)]) {
                let m = LocalModules.truthy(x["module_id"]) ? try c.rows("SELECT name, color FROM modules WHERE id=?", [try bind(x["module_id"], "module_id")]).first : nil
                out.append([
                    "event_id": x["event_id"] ?? .null, "date": .string(di), "start": or(x["new_start"], x["start_time"] ?? .null),
                    "end": or(x["new_end"], x["end_time"] ?? .null), "title": x["title"] ?? .null, "kind": x["kind"] ?? .null,
                    "module_id": x["module_id"] ?? .null, "module_name": m.map { $0["name"] ?? .null } ?? .null,
                    "color": or(x["color"], or(m?["color"], "#4f5bd5")), "room": x["room"] ?? .null, "lecturer": x["lecturer"] ?? .null,
                    "course_id": x["course_id"] ?? .null, "status": "teilnahme", "permanent_skip": false, "exception": "moved_here",
                    "moved_from": x["date"] ?? .null, "source": x["source"] ?? .null,
                ])
            }
            d += 1
        }
        let merged = try applyTimeAnswers(c, try mergeDated(c, out.compactMap(\.object), dated))
        // Absagen aus Ankuendigungen als Hinweis am Termin (`announcements.mark_cancellations`)
        let marked = try Announcements.markCancellations(c, includeSkipped ? merged : merged.filter { $0["status"] != "nicht_teilnahme" })
        let consult = try StudIPExtras.withConsultations(c, marked, from: start, to: end)   // eigene Sprechstunden (nur lesend)
        return try SOGoCalendar.withCalendar(c, consult, from: start, to: end)          // Uni-Kalender (SOGo, nur lesend)
    }

    /// `studip_dated(conn, start, end)`: die Termine, die Stud.IP dem Nutzer selbst in der Woche zeigt. Alle
    /// Einzeltermine aktiver Kurse (`studip_events`, ohne Art "sonstiges") mit Beginn im Zeitraum, mit eigenem Kalender
    /// nur die eigenen (`StudIPCalendar.Coverage.shows`): im Kalender, oder fuer Zeiten, die der Kalender nicht abdeckt
    /// (vor dem ersten Abruf, am Abruftag vor dem Abruf), derselbe Zeitschlitz wie ein Kalendertermin des Kurses. Ohne
    /// Kalender alle. Abweichung vom PC (dort ab dem Tag nach dem Abruf nur der Kalender, davor alle): Befund mit echten
    /// Daten am 28.10.2026, der Abruftag und die Wochen davor zeigten jede parallele Gruppe, docs/IPAD-STUDIP-SYNC.md §10.
    /// Vorkommen ohne Serie (`event_id` null, `studip_id` gesetzt, `source` "studip-kalender").
    /// Derselbe Termin eines Kurses (Kurs, Tag, Beginn, Ende) in mehreren Raeumen ist ein Vorkommen mit allen Raeumen
    /// (" · ", Reihenfolge des ersten Auftretens, ohne Doppelte; ba02e47).
    static func studipDated(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [[String: JSONValue]] {
        let rows = try c.rows("""
            SELECT s.*, c.title AS course_title, c.module_id, c.kind AS course_kind, m.name AS module_name, m.color AS module_color
            FROM studip_events s JOIN courses c ON c.id=s.course_id LEFT JOIN modules m ON m.id=c.module_id
            WHERE c.active=1 AND c.kind != 'sonstiges' AND s.start >= ? AND s.start < ? ORDER BY s.start
            """, [.text(iso(start)), .text(iso(end + 1))])
        let cover = try StudIPCalendar.coverage(c)
        let answers = try StudIPCalendar.timeAnswers(c)
        var out: [[String: JSONValue]] = []
        var at: [JSONValue: Int] = [:]
        for r in rows {
            guard let st = LocalTimetableImport.isoDateTime(r["start"]), let en = LocalTimetableImport.isoDateTime(r["end"]) else { continue }
            let di = iso(st.day)
            // Antwort auf "Welche Termine besuchst du?" (Kurs, Wochentag, Beginn, Ende)
            let answer = answers.isEmpty ? nil : answers.answer(course: r["course_id"], module: r["module_id"], title: r["course_title"], day: st.day,
                                                                start: LocalFreeWindows.mh(st.minutes), end: LocalFreeWindows.mh(en.minutes))
            // andere Gruppe oder Kurs ohne Kalendertermin: nicht im eigenen Kalender (abgesagte nach dem Zeitschlitz).
            // Eine vom Nutzer gewaehlte Kurszeit gilt auch ohne Kalendertermin (Befund 10.11.2026: die gewaehlte Uebung
            // am Freitag fehlte, weil ihr Termin nicht im eigenen Stud.IP-Kalender stand).
            let cancelled = LocalModules.truthy(r["cancelled"])
            if let cover, answer != true {
                let id = r["id"]?.string, course = r["course_id"]?.string
                let shown = cancelled ? cover.showsCancelled(id: id, course: course, start: st, end: en)
                    : cover.shows(id: id, course: course, start: st, end: en)
                if !shown { continue }
            }
            let title = r["course_title"] ?? .null
            var o: [String: JSONValue] = [
                "event_id": .null, "studip_id": r["id"] ?? .null, "date": .string(di), "start": .string(LocalFreeWindows.mh(st.minutes)),
                "end": .string(LocalFreeWindows.mh(en.minutes)), "title": title,
                "kind": .string(r["course_kind"] == "uebung" ? "uebung" : UniRules.eventKind(title.string ?? "")),
                "module_id": r["module_id"] ?? .null, "module_name": r["module_name"] ?? .null, "color": or(r["module_color"], "#4f5bd5"),
                "room": or(r["room"], ""), "lecturer": .null, "course_id": r["course_id"] ?? .null, "status": "teilnahme",
                "permanent_skip": false, "exception": .null, "source": "studip-kalender",
            ]
            // Sitzungsthema nur, wenn vorhanden (Antwortform sonst unveraendert)
            if LocalModules.truthy(r["description"]) { o["session_topic"] = r["description"] }
            if answer == false {
                // abgewaehlte Kurszeit: grau, die Zeit ist frei fuer Lernbloecke
                o["status"] = "nicht_teilnahme"
                o["permanent_skip"] = true
            }
            if cancelled {
                // in Stud.IP abgesagt (02.11.2026): bestaetigter Ausfall, die Zeit wird frei (busy_blocks zaehlt nur Teilnahme)
                o["status"] = "ausfall"
                o["exception"] = "cancelled"
                o["cancel_hint"] = studipCancelHint(courseTitle: title, description: r["description"])
            }
            // ein abgesagter und ein stattfindender Termin desselben Zeitpunkts bleiben getrennt
            let k: JSONValue = [o["course_id"] ?? .null, o["date"] ?? .null, o["start"] ?? .null, o["end"] ?? .null, o["status"] ?? .null]
            guard let i = at[k] else {
                at[k] = out.count
                out.append(o)
                continue
            }
            // rooms = [x for x in merged[k]["room"].split(" · ") if x]; neuer Raum dazu, wenn noch nicht dabei
            let rooms = text(out[i]["room"]).components(separatedBy: " · ").filter { !$0.isEmpty }
            if let room = o["room"]?.string, !room.isEmpty, !rooms.contains(where: { $0.unicodeScalars.elementsEqual(room.unicodeScalars) }) {
                out[i]["room"] = .string((rooms + [room]).joined(separator: " · "))
            }
        }
        return out
    }

    /// Antwort auf "Welche Termine besuchst du?" an Serien, die nicht mit der Kurszeit verknuepft sind (z. B. eigene
    /// oder frueher uebernommene Serie desselben Kurses, Moduls oder Titels zur selben Zeit): eine abgewaehlte Kurszeit
    /// wird grau ("nicht_teilnahme"), ausser der Nutzer hat diesen Tag selbst auf "besucht" gesetzt. Verknuepfte Serien
    /// tragen die Antwort schon in `attend` (`StudIPCalendar.setTimes`) und bleiben, wie der Nutzer sie danach stellt.
    static func applyTimeAnswers(_ c: SQLiteConnection, _ occ: [JSONValue]) throws -> [JSONValue] {
        let answers = try StudIPCalendar.timeAnswers(c)
        guard !answers.isEmpty else { return occ }
        let linked = Set(try StudIPScheduleImport.readLinks(c).filter { $0.key.hasPrefix("cycle:") }.map { JSONValue.number(Double($0.value.eventID)) })
        return occ.map { v in
            guard var o = v.object, let eid = o["event_id"], eid != .null, !linked.contains(eid), o["status"] == "teilnahme",
                  o["exception"] != "attend", o["exception"] != "moved_here",
                  let day = (o["date"]?.string).flatMap(BerlinClock.parseISODate), let st = o["start"]?.string, let en = o["end"]?.string,
                  answers.answer(course: o["course_id"], module: o["module_id"], title: o["title"], day: day, start: st, end: en) == false
            else { return v }
            o["status"] = "nicht_teilnahme"
            o["permanent_skip"] = true
            return .object(o)
        }
    }

    /// `studip_cancel_hint(course_title, description)`: Hinweis am Termin fuer einen in Stud.IP abgesagten Einzeltermin
    /// in der Form von `Announcements.markCancellations` (Quelle "studip", Art "termin", bestaetigt, "fällt aus")
    static func studipCancelHint(courseTitle: JSONValue, description: JSONValue?) -> JSONValue {
        ["announcement_id": .null, "kind": "termin", "title": courseTitle,
         "snippet": LocalModules.truthy(description) ? (description ?? .null) : .null, "url": .null, "source": "studip",
         "course_title": courseTitle, "posted_at": .null, "confirmed": true, "label": .string(Announcements.cancelConfirmedLabel)]
    }

    /// `_same_slot(o, d)`: Serien-Vorkommen und Stud.IP-Einzeltermin meinen denselben Termin: gleicher Tag und Beginn
    /// und dazu derselbe Kurs, dasselbe Modul mit gleichem Ende (Serien haengen oft noch an der Kurs-ID eines
    /// frueheren Semesters) oder derselbe Titel (ohne Leerraum aussen, klein)
    static func sameSlot(_ o: [String: JSONValue], _ d: [String: JSONValue]) -> Bool {
        guard o["date"] == d["date"], o["start"] == d["start"] else { return false }
        if (o["course_id"] ?? .null) == (d["course_id"] ?? .null) { return true }
        if LocalModules.truthy(o["module_id"]), o["module_id"] == d["module_id"], o["end"] == d["end"] { return true }
        func norm(_ v: JSONValue?) -> String { PyText.lower(PyText.strip(LocalModules.truthy(v) ? (v?.string ?? text(v)) : "")) }
        return norm(o["title"]).unicodeScalars.elementsEqual(norm(d["title"]).unicodeScalars)
    }

    /// `_merge_dated(conn, out, dated)`: Serien-Vorkommen und Stud.IP-Einzeltermine zusammenfuehren. Derselbe Termin
    /// (`sameSlot`): die Serie bleibt (Teilnahme, Ausnahmen, Notizen) und bekommt `studip_id` und, wenn leer, den Raum;
    /// jeder Einzeltermin hoechstens einmal, in der Reihenfolge der Serien. Automatisch uebernommene Serien (Quelle
    /// genau "studip") eines Kurses, von dem Einzeltermine bekannt sind, zeigen nur, was Stud.IP kennt (ausser hierher
    /// verschoben): ab dem Tag des Kalenderabrufs (am PC erst ab dem Tag danach, siehe `studipDated`) faellt alles eines
    /// Kurses ohne eigenen Kalendertermin weg (andere Gruppe, frueherer Jahrgang); ohne passenden Einzeltermin bleibt nur
    /// eine gespeicherte Ausnahme sichtbar (z. B.
    /// "Ausfall laut Stud.IP"), sonst faellt das Vorkommen weg, auch bei "vorlesungsfrei". Von Hand bestaetigte
    /// ("studip-manual"), eigene und andere Serien bleiben immer. Danach die uebrigen Einzeltermine, alles stabil nach
    /// Datum und Beginn sortiert.
    static func mergeDated(_ c: SQLiteConnection, _ out: [[String: JSONValue]], _ dated: [[String: JSONValue]]) throws -> [JSONValue] {
        let known = Set(try c.rows("SELECT course_id, MIN(start) AS lo, MAX(start) AS hi FROM studip_events WHERE COALESCE(cancelled, 0)=0 GROUP BY course_id")
            .map { $0["course_id"] ?? .null })
        let cover = try StudIPCalendar.coverage(c)
        let since = cover.map { iso($0.fetched.day) }
        let mine = Set((cover?.courses ?? []).map(JSONValue.string))
        var res: [JSONValue] = []
        var taken = Set<Int>()
        for var o in out {
            let course = o["course_id"] ?? .null
            if let i = dated.indices.first(where: { !taken.contains($0) && sameSlot(o, dated[$0]) }) {
                taken.insert(i)
                o["studip_id"] = dated[i]["studip_id"] ?? .null
                if !LocalModules.truthy(o["room"]), LocalModules.truthy(dated[i]["room"]) { o["room"] = dated[i]["room"] }
                if LocalModules.truthy(dated[i]["session_topic"]), !LocalModules.truthy(o["session_topic"]) { o["session_topic"] = dated[i]["session_topic"] }
                if let hint = dated[i]["cancel_hint"], LocalModules.truthy(hint), o["exception"] == nil || o["exception"] == .null || o["exception"] == "cancelled" {
                    // in Stud.IP abgesagt: die Serie faellt an diesem Tag aus (eigene Ausnahmen des Nutzers bleiben)
                    o["status"] = "ausfall"
                    o["exception"] = "cancelled"
                    o["cancel_hint"] = hint
                }
                res.append(.object(o))
                continue
            }
            if o["source"] == "studip", known.contains(course), o["exception"] != "moved_here" {
                if let since, let day = o["date"]?.string, !day.unicodeScalars.lexicographicallyPrecedes(since.unicodeScalars),
                   !mine.contains(course) { continue }                 // Kurs ohne eigenen Kalendertermin
                let x = o["exception"] ?? .null
                if x == .null || x == "vorlesungsfrei" { continue }   // Stud.IP kennt an diesem Tag keinen Termin
            }
            res.append(.object(o))
        }
        res += dated.indices.filter { !taken.contains($0) }.map { .object(dated[$0]) }
        // res.sort(key=lambda o: (o["date"], o["start"])), stabil
        return try stableSorted(res) { a, b in
            let da = a["date"]?.string ?? "", db = b["date"]?.string ?? ""
            if da != db { return da.unicodeScalars.lexicographicallyPrecedes(db.unicodeScalars) }
            guard let sa = a["start"]?.string, let sb = b["start"]?.string else {
                if a["start"] == b["start"] { return false }
                throw LocalHTTPError(status: 500, message: "Termin ohne Beginn")
            }
            return sa.unicodeScalars.lexicographicallyPrecedes(sb.unicodeScalars)
        }
    }

    /// `_matches(e, d, t)`: Zeitraum (sonst Semester), einmalig, Wochentag, alle zwei Wochen ab dem ersten Tag
    static func matches(_ e: [String: JSONValue], day d: Int, term t: JSONValue) throws -> Bool {
        let df = or(e["date_from"], t["start"] ?? .null)
        let dt = or(e["date_to"], t["end"] ?? .null)
        let di: JSONValue = .string(iso(d))
        guard try lessOrEqual(df, di), try lessOrEqual(di, dt) else { return false }
        if e["rrule"] == "once" { return di == or(e["date_from"], "") }
        guard let wd = e["weekday"]?.double, wd == Double(weekday(d)) else { return false }
        if e["rrule"] == "biweekly" {
            let weeks = BerlinClock.floorDiv(d - (try day(df, "date_from")), 7)
            return ((weeks % 2) + 2) % 2 == 0
        }
        return true
    }

    // MARK: Tag und Woche

    /// `day_timeline(conn, d)`
    static func dayTimeline(_ c: SQLiteConnection, day d: Int) throws -> JSONValue {
        let s = try LocalSettings.read(c)
        let occ = try occurrences(c, from: d, to: d)
        let pk = try c.rows("SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date=? ORDER BY p.start_time, p.id",
                            [.text(iso(d))])
        return ["date": .string(iso(d)), "events": .array(occ), "packages": .array(pk.map(JSONValue.object)),
                "free": .array(try LocalFreeWindows.compute(c, day: d, settings: s)), "blocked": .array(try blocked(d, settings: s)),
                "learn_start": s["learn_start"] ?? .null, "learn_end": s["learn_end"] ?? .null]
    }

    /// `week_grid(conn, start)`
    static func weekGrid(_ c: SQLiteConnection, start: Int) throws -> JSONValue {
        let end = start + 6
        let occ = try occurrences(c, from: start, to: end)
        let pk = try c.rows("SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date BETWEEN ? AND ? ORDER BY p.date, p.start_time",
                            [.text(iso(start)), .text(iso(end))])
        let s = try LocalSettings.read(c)
        let (marks, dls) = try Holidays.calendarExtras(c, from: start, to: end)
        let notes = DueStore.withoutDuplicateNotices(try Announcements.byDay(c, from: start, to: end), deadlines: dls)
        var days: [JSONValue] = []
        for d in start...end {
            let di: JSONValue = .string(iso(d))
            days.append(["date": di, "weekday": .number(Double(weekday(d))), "events": .array(occ.filter { $0["date"] == di }),
                         "packages": .array(pk.filter { $0["date"] == di }.map(JSONValue.object)),
                         "marks": .array(marks[iso(d)] ?? []), "deadlines": .array(dls[iso(d)] ?? []), "notices": .array(notes[iso(d)] ?? []),
                         "free": .array(try LocalFreeWindows.compute(c, day: d, settings: s)), "blocked": .array(try blocked(d, settings: s))])
        }
        return ["start": .string(iso(start)), "end": .string(iso(end)), "days": .array(days),
                "learn_start": s["learn_start"] ?? .null, "learn_end": s["learn_end"] ?? .null, "term": try term(c)]
    }

    // MARK: Ausnahmen und Teilnahme

    /// `set_exception(conn, event_id, d, typ, new_date, new_start, new_end, note)`; `typ` "reset" nimmt die Ausnahme
    /// zurueck. Zuruecksetzen eines Ausfalls laut Stud.IP (Entscheidung des Inhabers, a7827c6): der Termin findet statt
    /// und bleibt sichtbar, als "attend" mit eigener Notiz. Ohne Ausnahme verschwaende der Tag ganz (`mergeDated`: Stud.IP
    /// kennt an abgesagten Tagen keinen Termin), und der naechste Abgleich truege den Ausfall wieder ein. Wer genau diese
    /// Ausnahme noch einmal zuruecksetzt, bekommt den Ausfall laut Stud.IP zurueck.
    static func setException(_ c: SQLiteConnection, eventID: SQLiteValue, date: SQLiteValue, type: SQLiteValue,
                             newDate: SQLiteValue = .null, newStart: SQLiteValue = .null, newEnd: SQLiteValue = .null,
                             note: SQLiteValue = "", clock: UniFlowClock) throws {
        let old = try c.queryOne("SELECT type, note FROM event_exceptions WHERE event_id=? AND date=? ORDER BY id DESC LIMIT 1", [eventID, date])
        try c.execute("DELETE FROM event_exceptions WHERE event_id=? AND date=?", [eventID, date])
        var type = type, note = note
        if type == .text("reset"), let old {
            if old["type"]?.string == "cancelled", old["note"]?.string == StudIPCancellations.note {
                (type, note) = (.text("attend"), .text(StudIPCancellations.resetNote))
            } else if old["type"]?.string == "attend", old["note"]?.string == StudIPCancellations.resetNote {
                (type, note) = (.text("cancelled"), .text(StudIPCancellations.note))
            }
        }
        if type != .text("reset") {
            try c.execute("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,?,?,?,?,?,?)",
                          [eventID, date, type, newDate, newStart, newEnd, note, .text(clock.nowISO)])
        }
    }

    /// `set_attendance(conn, event_id, d, mode)`: today_skip | today_attend | permanent_skip | permanent_attend |
    /// cancelled | reset; anderes aendert nichts
    static func setAttendance(_ c: SQLiteConnection, eventID: SQLiteValue, date: SQLiteValue, mode: JSONValue?, clock: UniFlowClock) throws {
        switch mode?.string {
        case "permanent_skip", "permanent_attend":
            try c.execute("UPDATE course_events SET attend=? WHERE id=?", [mode?.string == "permanent_skip" ? 0 : 1, eventID])
            try c.execute("DELETE FROM event_exceptions WHERE event_id=? AND date>=? AND type IN ('skip','attend')", [eventID, date])
        case "today_skip": try setException(c, eventID: eventID, date: date, type: "skip", clock: clock)
        case "today_attend": try setException(c, eventID: eventID, date: date, type: "attend", clock: clock)
        case "cancelled": try setException(c, eventID: eventID, date: date, type: "cancelled", clock: clock)
        case "reset": try setException(c, eventID: eventID, date: date, type: "reset", clock: clock)
        default: break
        }
    }

    /// `materials_for_event(conn, event, d)`: passende Unterlagen des Moduls aus derselben Semesterwoche, sonst die
    /// neuesten; ohne Modul keine. Eine Fassung mit den Modulen (`LocalModules.eventMaterials`, S4): Dateien mit
    /// Einordnung aus dem Stud.IP-Abgleich (S3) und die Semesterwochen aus `StudyWeeks`.
    static func materials(_ c: SQLiteConnection, event: [String: JSONValue], day: Int, clock: UniFlowClock) throws -> [JSONValue] {
        try LocalModules.eventMaterials(c, event: event, day: day, clock: clock)
    }

    // MARK: Konflikte

    /// `study.slot_conflicts(conn, start, end)`: Lernslots, die sich mit besuchten Hochschulterminen ueberschneiden
    static func slotConflicts(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var d = start
        while d <= end {
            let occ = try occurrences(c, from: d, to: d).filter { $0["status"] == "teilnahme" }
            for p in try c.rows("SELECT id, subject, title, start_time, end_time FROM study_packages WHERE date=? AND start_time IS NOT NULL AND status IN ('geplant','in_bearbeitung')",
                                [.text(iso(d))]) {
                let ps = try LocalFreeWindows.hm(p["start_time"], key: "start_time")
                let pe = try LocalFreeWindows.hm(p["end_time"], key: "end_time")
                for o in occ {
                    let os = try LocalFreeWindows.hm(o["start"], key: "start"), oe = try LocalFreeWindows.hm(o["end"], key: "end")
                    guard ps < oe && pe > os else { continue }
                    out.append(["date": .string(iso(d)), "package_id": p["id"] ?? .null, "subject": p["subject"] ?? .null,
                                "title": p["title"] ?? .null, "slot": .string("\(text(p["start_time"]))–\(text(p["end_time"]))"),
                                "event": o["title"] ?? .null, "event_time": .string("\(text(o["start"]))–\(text(o["end"]))")])
                    break
                }
            }
            d += 1
        }
        return out
    }
}
