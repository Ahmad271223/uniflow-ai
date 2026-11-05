import Foundation

/// Kommende Klausuren je Modul aus allen Quellen, die der Abgleich schon liest (Auftrag des Inhabers 04.11.2026), wie
/// app/exams.py: Stud.IP-Termine mit Art "Klausur" (`studip_events.category`), Klausurtermin am Modul, QIS-Anmeldungen
/// mit Datum, Fristen mit Klausur im Namen, Ankuendigungen eines Kurses, Stud.IP-Nachrichten. Auf dem Geraet kommen
/// die in Dokumenten erkannten Klausuren dazu (`DueStore`, Tabelle nur hier; ohne sie gleich wie Python). Je Modul
/// (sonst Kurs, sonst Name) und Tag ein Eintrag mit allen Quellen; leere Klausurtermine der Module werden gefuellt,
/// selbst eingetragene nie ueberschrieben (`settings.exam_dates_auto`). Fixture tools/gen-exams-fixture.py.
public enum Exams {
    static let windowDays = 400
    static let autoKey = "exam_dates_auto"

    /// `EXAM_RE`: Klausur, Nachklausur, E-Klausur, Pruefung(en), Klausurtermin, Pruefungsdatum, Exam; nicht Probeklausur,
    /// Klausureinsicht, Pruefungsanmeldung, Pruefungszeitraum, Klausurvorbereitung
    static let examRE = HText.regex(#"(?<![a-zäöüß])(?:nach|wiederholungs|abschluss|modul|end|haupt|e-?)?(?:klausur|pr(?:ü|ue)fung|examen|exam)"#
                                    + #"(?:en|s|s?termine?|s?datum)?(?![a-zäöüß])"#, [.caseInsensitive])
    /// `NOT_EXAM_RE`: Tage rund um eine Klausur, die selbst keine sind (Anmeldung, Fristen, Einsicht ...)
    static let notExamRE = HText.regex(#"meld|einsicht|r(?:ü|ue)ckgabe|ergebnis|\bnoten\b|korrektur|besprechung|fragestunde|repetitorium|"#
                                       + #"sprechstunde|probe|altklausur|zulassung|vorleistung|frist|deadline|bis\s+(?:zum|sp(?:ä|ae)testens)"#,
                                       [.caseInsensitive])
    static let movedRE = HText.regex(#"verschoben|verlegt"#, [.caseInsensitive])
    /// "vom 10.02. auf den 15.02. verschoben": der alte Tag ist keine Klausur mehr
    static let fromRE = HText.regex(#"\bvo[mn]\s+(?:[a-zäöü]{2,10}\.?,?\s+)?$"#, [.caseInsensitive])
    static let roomRE = HText.regex(#"(?<!\w)((?:H(?:ö|oe)rsaal|Seminarraum|Raum|HS)\s+[A-Za-z]{0,3}\s?-?\s?\d[\w./-]*)"#)
    static let qisRegisteredRE = HText.regex(#"^\s*an\s*$|angemeldet"#, [.caseInsensitive])
    static let qisDateRE = HText.regex(#"^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})|^\s*(\d{4})-(\d{2})-(\d{2})"#)
    /// Vorrang der Quellen; ein automatisch uebernommener Modultermin kommt nur dazu, wenn keine andere Quelle den Tag nennt
    /// Quelle der gelesenen Anmeldungen (QIS-Info-Seite bzw. "Meine POS-Anmeldungen")
    static let registrationLabel = "aus deinen angemeldeten Prüfungen"
    static let order: [String: Int] = ["studip": 0, "modul": 1, "qis": 2, "anmeldung": 2, "frist": 3, "ankuendigung": 4, "nachricht": 5, "erkannt": 6, "modul_auto": 9]
    static let deadlineSources = ["learnweb": "aus dem Learnweb-Kalender", "studip": "aus Stud.IP Courseware", "demo": "aus den Demo-Inhalten"]

    // MARK: Texte

    private static func first(_ re: NSRegularExpression, _ s: String, options: NSRegularExpression.MatchingOptions = []) -> NSTextCheckingResult? {
        re.firstMatch(in: s, options: options, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool { first(re, s) != nil }

    /// `word(found)`: Nachklausur, Klausur oder Pruefung
    static func word(_ found: String) -> String {
        let w = PyText.lower(found)
        if w.hasPrefix("nach") || w.hasPrefix("wiederholungs") { return "Nachklausur" }
        return w.contains("klausur") ? "Klausur" : "Prüfung"
    }

    /// `room(sentence)`: "Hörsaal F 303", "Raum E214", "HS 1"
    static func room(_ sentence: String) -> String? {
        guard let m = first(roomRE, sentence) else { return nil }
        var r = Array(PyText.strip((sentence as NSString).substring(with: m.range(at: 1))).unicodeScalars)
        while let last = r.last, ".-/".unicodeScalars.contains(last) { r.removeLast() }
        return String(String.UnicodeScalarView(r))
    }

    /// `is_exam_text(s)`: Bezeichnung, wenn der Text eine Klausur nennt und nichts drumherum, sonst nil
    static func examWord(_ s: String?) -> String? {
        let s = s ?? ""
        guard let m = first(examRE, s), !has(notExamRE, s) else { return nil }
        return word((s as NSString).substring(with: m.range))
    }

    /// `exam_dates(title, text, posted)`: Klausurtage in Betreff und Text: [{date, time, word, snippet, room}]
    static func examDates(title: String, text: String, posted: Int) -> [[String: JSONValue]] {
        let full = title + "\n" + text
        let fullScalars = Array(full.unicodeScalars)
        let hits = Announcements.scanDates(full, posted: posted)
        let days = Set(hits.map(\.day))
        let titleWord = examWord(title)
        var order: [(String, String?)] = []
        var found: [String: [String: JSONValue]] = [:]
        func key(_ d: String, _ t: String?) -> String { d + "|" + (t ?? "-") }
        for h in hits {
            if has(Announcements.cancelRE, h.clause) { continue }
            if has(movedRE, h.clause) {
                let before = String(String.UnicodeScalarView(fullScalars[max(0, h.start - 20)..<h.start]))
                if has(fromRE, before) { continue }
            }
            let w: String
            if let m = first(examRE, h.clause) {
                if has(notExamRE, h.clause) { continue }
                w = word((h.clause as NSString).substring(with: m.range))
            } else if let sw = examWord(h.sentence) {
                w = sw
            } else {
                guard let tw = titleWord, days.count == 1, !has(notExamRE, h.sentence) else { continue }
                w = tw
            }
            let iso = BerlinClock.isoDate(h.day)
            if found[key(iso, h.time)] == nil {
                order.append((iso, h.time))
                found[key(iso, h.time)] = ["date": .string(iso), "time": h.time.map(JSONValue.string) ?? .null, "word": .string(w),
                                           "snippet": .string(h.sentence), "room": room(h.sentence).map(JSONValue.string) ?? .null]
            }
        }
        let withTime = Set(order.filter { $0.1 != nil }.map(\.0))
        let out = order.filter { $0.1 != nil || !withTime.contains($0.0) }.compactMap { found[key($0.0, $0.1)] }
        return out.enumerated().sorted { a, b in
            let da = a.element["date"]?.string ?? "", db = b.element["date"]?.string ?? ""
            if da != db { return PyText.less(da, db) }
            let ta = a.element["time"]?.string ?? "", tb = b.element["time"]?.string ?? ""
            if ta != tb { return PyText.less(ta, tb) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// "heute", "morgen", "in 12 Tagen"
    static func inDays(_ n: Int) -> String { DueStore.inDays(n) }

    private static func dmy(_ iso: String) -> String {
        "\(PyText.slice(iso, 8, 10)).\(PyText.slice(iso, 5, 7)).\(PyText.slice(iso, 0, 4))"
    }

    private static func hasTable(_ c: SQLiteConnection, _ name: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(name)]) != nil
    }

    // MARK: Merker der automatisch uebernommenen Termine

    /// `auto_map`: {Modul-ID: Tag}
    static func autoMap(_ c: SQLiteConnection) throws -> [String: String] {
        guard let raw = try c.scalar("SELECT value FROM settings WHERE key=?", [.text(autoKey)])?.string, !raw.isEmpty,
              let v = try? JSONValue.parse(raw), let o = v.object else { return [:] }
        var out: [String: String] = [:]
        for (k, x) in o {
            guard !k.isEmpty, k.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let s = x.string, s.unicodeScalars.count == 10 else { continue }
            out[k] = s
        }
        return out
    }

    static func autoText(_ m: [String: String]) -> String {
        "{" + m.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.map { "\"\($0)\": \"\(m[$0] ?? "")\"" }.joined(separator: ", ") + "}"
    }

    // MARK: Quellen

    struct Candidate {
        var kind: String
        var label: String
        var date: String
        var time: String?
        var end: String?
        var room: String?
        var moduleID: Int?
        var courseID: String?
        var courseTitle: String?
        /// Schluessel ohne Modul und Kurs (Betreff, Pruefungsname)
        var name: String?
        /// Name im Titel ohne Modul und Kurs
        var titleName: String?
        var word = "Klausur"
        var url: String?
    }

    private static func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }

    /// `candidates(conn, today)`: alle Klausurtage ab heute, je Quelle in fester Reihenfolge
    static func candidates(_ c: SQLiteConnection, today t: Int) throws -> [Candidate] {
        let lo = BerlinClock.isoDate(t), hi = BerlinClock.isoDate(t + windowDays)
        var out: [Candidate] = []
        func inWindow(_ d: String) -> Bool { !PyText.less(d, lo) && !PyText.less(hi, d) }
        // Stud.IP-Termine: Art, Titel oder kurzes Sitzungsthema
        for r in try c.rows("""
            SELECT s.id, s.course_id, s.title, s.start, s."end", s.room, s.description, s.category, c.title AS course_title, c.module_id
            FROM studip_events s JOIN courses c ON c.id=s.course_id
            WHERE COALESCE(s.cancelled, 0)=0 AND substr(s.start, 1, 10) >= ? AND substr(s.start, 1, 10) <= ?
            ORDER BY s.start, s.id
            """, [.text(lo), .text(hi)]) {
            let desc = r["description"]?.string ?? ""
            guard let w = examWord(r["category"]?.string) ?? examWord(r["title"]?.string)
                    ?? (PyText.length(desc) <= 200 ? examWord(desc) : nil) else { continue }
            let st = r["start"]?.string ?? "", en = r["end"]?.string ?? ""
            let endTime = PyText.slice(en, 11, 16)
            out.append(Candidate(kind: "studip", label: "aus Stud.IP-Terminen", date: PyText.slice(st, 0, 10),
                                 time: nonEmpty(PyText.slice(st, 11, 16)),
                                 end: PyText.slice(en, 0, 10) == PyText.slice(st, 0, 10) && !endTime.isEmpty ? endTime : nil,
                                 room: nonEmpty(PyText.strip(r["room"]?.string ?? "")), moduleID: r["module_id"]?.int,
                                 courseID: r["course_id"]?.string, courseTitle: r["course_title"]?.string, name: r["course_title"]?.string,
                                 titleName: nil, word: w))
        }
        // Klausurtermin am Modul (selbst eingetragen oder automatisch uebernommen)
        let auto = try autoMap(c)
        for r in try c.rows("SELECT id, name, exam_date FROM modules WHERE exam_date IS NOT NULL AND exam_date <> '' ORDER BY id") {
            let day = PyText.slice(r["exam_date"]?.string ?? "", 0, 10)
            guard inWindow(day), let id = r["id"]?.int else { continue }
            let isAuto = auto[String(id)] == day
            out.append(Candidate(kind: isAuto ? "modul_auto" : "modul", label: isAuto ? "automatisch übernommen" : "selbst eingetragen",
                                 date: day, moduleID: id, name: r["name"]?.string))
        }
        // QIS: angemeldete Pruefungen mit Datum
        for r in try c.rows("SELECT id, text, status, datum FROM grades ORDER BY id") {
            guard has(qisRegisteredRE, r["status"]?.string ?? "") else { continue }
            let datum = r["datum"]?.string ?? ""
            guard let m = first(qisDateRE, datum, options: [.anchored]) else { continue }
            let ns = datum as NSString
            func g(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
            let parts: (Int, Int, Int)?
            if let d = g(1), let mo = g(2), let y = g(3) { parts = (y, mo, d) } else if let y = g(4), let mo = g(5), let d = g(6) { parts = (y, mo, d) } else { parts = nil }
            guard let (y, mo, d) = parts, y >= 1, (1...12).contains(mo), d >= 1, d <= BerlinClock.daysInMonth(year: y, month: mo) else { continue }
            let iso = BerlinClock.isoDate(BerlinClock.dayNumber(year: y, month: mo, day: d))
            guard inWindow(iso) else { continue }
            let text = r["text"]?.string
            out.append(Candidate(kind: "qis", label: "aus QIS (angemeldet)", date: iso, moduleID: try ModuleGuess.guessModule(c, title: text)?.int,
                                 name: text, titleName: text, word: "Prüfung"))
        }
        // gelesene Anmeldungen mit Termin ("Info über angemeldete Prüfungen" im QIS der LUH bzw. "Meine POS-Anmeldungen" im
        // LSF der Uni Hildesheim, `QISRegistrationsSync`), mit Uhrzeit und Raum; nur angemeldete; Vorrang wie QIS
        for r in try QISRegistrationsSync.rows(c) where r.registered {
            guard let iso = r.isoDate, inWindow(iso) else { continue }
            out.append(Candidate(kind: "anmeldung", label: registrationLabel, date: iso, time: r.clock, room: nonEmpty(r.room),
                                 moduleID: try ModuleGuess.guessModule(c, title: r.text)?.int, name: r.text, titleName: r.text, word: "Prüfung"))
        }
        // Fristen mit Klausur im Namen (Learnweb-Test "E-Klausur", Courseware)
        for r in try c.rows("""
            SELECT d.id, d.source, d.title, d.due_at, d.url, d.course_id, c.title AS course_title, c.module_id
            FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id
            WHERE substr(d.due_at, 1, 10) >= ? AND substr(d.due_at, 1, 10) <= ? ORDER BY d.due_at, d.id
            """, [.text(lo), .text(hi)]) {
            guard let w = examWord(r["title"]?.string) else { continue }
            let due = r["due_at"]?.string ?? ""
            out.append(Candidate(kind: "frist", label: deadlineSources[r["source"]?.string ?? ""] ?? "aus einer Frist", date: PyText.slice(due, 0, 10),
                                 time: nonEmpty(PyText.slice(due, 11, 16)), moduleID: r["module_id"]?.int, courseID: r["course_id"]?.string,
                                 courseTitle: r["course_title"]?.string, name: nonEmpty(r["course_title"]?.string) ?? r["title"]?.string,
                                 titleName: r["title"]?.string, word: w, url: r["url"]?.string))
        }
        // Ankuendigungen eines Kurses (Stud.IP-weite ohne Kurs nennen kein Modul)
        for r in try c.rows("""
            SELECT a.id, a.title, a.text, a.posted_at, a.url, a.course_id, c.title AS course_title, c.module_id
            FROM announcements a JOIN courses c ON c.id=a.course_id ORDER BY a.posted_at DESC, a.id
            """) {
            guard let posted = Announcements.postedDayOrNil(r["posted_at"]?.string) else { continue }
            for x in examDates(title: r["title"]?.string ?? "", text: r["text"]?.string ?? "", posted: posted) {
                guard let day = x["date"]?.string, inWindow(day) else { continue }
                out.append(Candidate(kind: "ankuendigung", label: "aus Ankündigung vom \(dmy(BerlinClock.isoDate(posted)))", date: day,
                                     time: x["time"]?.string, room: x["room"]?.string, moduleID: r["module_id"]?.int,
                                     courseID: r["course_id"]?.string, courseTitle: r["course_title"]?.string, name: r["course_title"]?.string,
                                     word: x["word"]?.string ?? "Klausur", url: r["url"]?.string))
            }
        }
        // Stud.IP-Nachrichten (nur lokal), Modul ueber den Betreff
        if try hasTable(c, "studip_messages") {
            for r in try c.rows("SELECT id, subject, preview, sent_at, url FROM studip_messages ORDER BY sent_at DESC, id") {
                guard let posted = Announcements.postedDayOrNil(r["sent_at"]?.string) else { continue }
                let subject = r["subject"]?.string ?? ""
                let found = examDates(title: subject, text: r["preview"]?.string ?? "", posted: posted).filter { inWindow($0["date"]?.string ?? "") }
                guard !found.isEmpty else { continue }
                let mid = try ModuleGuess.guessModule(c, title: subject)?.int
                for x in found {
                    out.append(Candidate(kind: "nachricht", label: "aus Nachricht vom \(dmy(BerlinClock.isoDate(posted)))", date: x["date"]?.string ?? "",
                                         time: x["time"]?.string, room: x["room"]?.string, moduleID: mid, name: r["subject"]?.string,
                                         word: x["word"]?.string ?? "Klausur", url: r["url"]?.string))
                }
            }
        }
        // nur auf dem Geraet: in Dokumenten erkannte Klausuren (ohne Kurz- und Probeklausuren, ohne ausgeblendete)
        for g in try DueStore.groups(c, from: lo, to: hi) where g.kind == "klausur" && !g.hidden {
            let x = DueStore.json(g)
            let title = x["title"]?.string ?? ""
            let lower = PyText.lower(title)
            if lower.contains("kurz") || lower.contains("probe") { continue }
            out.append(Candidate(kind: "erkannt", label: x["origin"]?.string ?? "erkannt", date: g.date, time: x["time"]?.string,
                                 moduleID: x["module_id"]?.int, courseID: x["course_id"]?.string, courseTitle: x["course_title"]?.string,
                                 name: x["course_title"]?.string ?? title, word: word(title), url: nil))
        }
        return out
    }

    static func scope(_ c: Candidate) -> String {
        if let m = c.moduleID { return "m\(m)" }
        if let course = c.courseID, !course.isEmpty { return "c\(course)" }
        let h = SolutionSHA256.hexString(SolutionSHA256.hash(Data(PyText.lower(PyText.strip(c.name ?? "")).utf8)))
        return "t" + PyText.slice(h, 0, 10)
    }

    /// `merge(cands, mods, today)`: je Modul (sonst Kurs, sonst Name) und Tag ein Eintrag mit allen Quellen
    static func merge(_ cands: [Candidate], modules: [Int: (name: String?, color: String?)], today t: Int) -> [[String: JSONValue]] {
        let sorted = cands.enumerated().sorted { a, b in
            let oa = order[a.element.kind] ?? 99, ob = order[b.element.kind] ?? 99
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)
        var keys: [String] = []
        var groups: [String: [Candidate]] = [:]
        for c in sorted {
            let k = scope(c) + "|" + c.date
            if c.kind == "modul_auto", groups[k] != nil { continue }
            if groups[k] == nil { keys.append(k) }
            groups[k, default: []].append(c)
        }
        var out: [[String: JSONValue]] = []
        for k in keys {
            guard let cs = groups[k], let first = cs.first else { continue }
            let sc = scope(first), day = first.date
            let timed = cs.first { $0.time != nil && !($0.time ?? "").isEmpty }
            // Raeume: alle der Stud.IP-Termine (je Raum ein Termin), sonst der erste genannte
            var rooms: [String] = []
            for c in cs where c.kind == "studip" {
                if let r = c.room, !r.isEmpty, !rooms.contains(r) { rooms.append(r) }
            }
            if rooms.isEmpty, let r = cs.first(where: { !($0.room ?? "").isEmpty })?.room { rooms = [r] }
            let mid = first.moduleID
            let mod = mid.flatMap { modules[$0] }
            let course = cs.first { !($0.courseID ?? "").isEmpty }
            let name = nonEmpty(mod?.name) ?? nonEmpty(course?.courseTitle) ?? cs.compactMap({ nonEmpty($0.titleName) }).first
            var sources: [JSONValue] = []
            var seen = Set<String>()
            for c in cs {
                let kind = c.kind == "modul_auto" ? "modul" : c.kind
                guard seen.insert(kind + "|" + c.label).inserted else { continue }
                sources.append(["kind": .string(kind), "label": .string(c.label), "url": c.url.map(JSONValue.string) ?? .null])
            }
            let n = (BerlinClock.parseISODate(day) ?? t) - t
            func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
            out.append([
                "id": .string("exam-\(sc)-\(day)"), "date": .string(day), "time": opt(timed?.time), "end": opt(timed?.end),
                "days_left": .number(Double(n)), "in_days": .string(inDays(n)),
                "title": .string(name.map { "\(first.word) \($0)" } ?? first.word), "kind_label": .string(first.word),
                "module_id": mid.map { .number(Double($0)) } ?? .null, "module_name": opt(mod?.name), "color": opt(mod?.color),
                "course_id": opt(course?.courseID), "course_title": opt(course?.courseTitle),
                "room": rooms.isEmpty ? .null : .string(rooms.joined(separator: " · ")), "sources": .array(sources),
                "source_label": .string(sources.compactMap { $0["label"]?.string }.joined(separator: " · ")),
                "user_set": .bool(cs.contains { $0.kind == "modul" }),
            ])
        }
        return out.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            for (p, q) in [(x["date"]?.string ?? "", y["date"]?.string ?? ""), (x["time"]?.string ?? "", y["time"]?.string ?? ""),
                           (x["title"]?.string ?? "", y["title"]?.string ?? "")] where p != q {
                return PyText.less(p, q)
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `upcoming(conn, today)`
    static func upcoming(_ c: SQLiteConnection, today t: Int) throws -> [[String: JSONValue]] {
        var mods: [Int: (name: String?, color: String?)] = [:]
        for r in try c.rows("SELECT id, name, color FROM modules") {
            if let id = r["id"]?.int { mods[id] = (r["name"]?.string, r["color"]?.string) }
        }
        return merge(try candidates(c, today: t), modules: mods, today: t)
    }

    /// `fill_exam_dates(conn, items, today)`: leerer Klausurtermin -> frueheste Klausur aus einer Quelle (nicht dem Modul
    /// selbst, nicht aus Dokumenten erkannt); automatisch uebernommen -> folgt den Quellen, wenn der Tag dort nicht mehr
    /// steht; selbst eingetragen -> bleibt; vom Nutzer geleert -> derselbe Tag kommt nicht wieder. Zahl der Aenderungen.
    static func fillExamDates(_ c: SQLiteConnection, items: [[String: JSONValue]]) throws -> Int {
        var auto = try autoMap(c)
        var firstDay: [Int: String] = [:]
        var listed: [Int: Set<String>] = [:]
        for it in items {
            guard let mid = it["module_id"]?.int, let day = it["date"]?.string else { continue }
            let kinds = it["sources"]?.array?.compactMap { $0["kind"]?.string } ?? []
            guard kinds.contains(where: { $0 != "modul" && $0 != "erkannt" }) else { continue }
            if firstDay[mid] == nil { firstDay[mid] = day }
            listed[mid, default: []].insert(day)
        }
        var changed = 0
        for r in try c.rows("SELECT id, exam_date FROM modules ORDER BY id") {
            guard let mid = r["id"]?.int, let cand = firstDay[mid] else { continue }
            let cur = PyText.slice(r["exam_date"]?.string ?? "", 0, 10), key = String(mid)
            let was = auto[key]
            if cur.isEmpty {
                if cand == was { continue }                                  // vom Nutzer geleert
            } else if was == nil || cur != was || listed[mid]?.contains(cur) == true {
                continue                                                     // selbst eingetragen oder noch gueltig
            }
            _ = try c.execute("UPDATE modules SET exam_date=? WHERE id=?", [.text(cand), .integer(Int64(mid))])
            auto[key] = cand
            changed += 1
        }
        if changed > 0 {
            _ = try c.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                              [.text(autoKey), .text(autoText(auto))])
        }
        return changed
    }

    /// `response(conn, today, module_id)`: GET /api/exams/upcoming (in einer Transaktion aufrufen)
    static func response(_ c: SQLiteConnection, today t: Int, moduleID: Int?) throws -> JSONValue {
        var items = try upcoming(c, today: t)
        let filled = try fillExamDates(c, items: items)
        if filled > 0 { items = try upcoming(c, today: t) }
        if let m = moduleID { items = items.filter { $0["module_id"]?.int == m } }
        return ["items": .array(items.map(JSONValue.object)), "today": .string(BerlinClock.isoDate(t)), "filled": .number(Double(filled))]
    }
}
