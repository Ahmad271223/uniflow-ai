import Foundation

// Lehrende und Kontakte (LUH, Stud.IP), 06.11.2026, wie app/studip_lecturers.py (docs/LEHRENDE-KONTAKTE-2026-11-06.md).
// Auftrag des Inhabers: E-Mail-Adressen der Lehrenden finden, die man ueber Stud.IP sehen kann; HsH und LSF spaeter.
// Gelesen wird nur, was die eigene Sitzung ohnehin sieht, und nur lesend:
//  - courses/{id}/memberships?filter[permission]=dozent|tutor&include=user: Name, Benutzername, E-Mail (`email` des
//    Nutzers). Nur diese zwei Rollen; Eintraege anderer Rollen (Studierende) fallen weg und werden nie gespeichert.
//  - users/{id} nur ohne include (hoechstens `maxUserLookups` je Lauf)
//  - users/{id}/institute-memberships?include=institute: Sprechzeiten, Raum, Einrichtung (nur Dozent/innen)
// Alle drei live bestaetigt am 06.11.2026 (Anmeldung des Inhabers, nur GET): `include=user` liefert `email`.
// Wann: nach Stufe (a) des Abgleichs (`SyncOrder.markCurrentReady`), je Kurs hoechstens alle `refreshDays` Tage. Nur an
// Hochschulen mit Stud.IP (LUH). Alles bleibt auf diesem Geraet. Fixture tools/gen-studip-lecturers-fixture.py.

public enum StudIPLecturers {

    static let roles = ["dozent", "tutor"]
    static let roleLabels = ["dozent": "Dozent/in", "tutor": "Tutor/in"]
    public static let refreshDays = 7
    public static let maxCourses = 30
    public static let maxUserLookups = 20
    public static let maxProfiles = 40
    static let maxName = 120, maxOffice = 400, maxLocation = 120, maxLabel = 80
    public static let noEmail = "Nachricht über Stud.IP"
    public static let unknownName = "Stud.IP-Nutzer/in"
    static let hintNotLoaded = "Die Lehrenden kommen mit dem nächsten Stud.IP-Abgleich (nach dem aktuellen Semester)."
    static let hintNone = "In Stud.IP sind für diese Kurse keine Lehrenden sichtbar."
    static let hintNoMatch = "Keine Lehrenden gefunden."
    static let missingName = "course-memberships"
    static let profileMissingName = "institute-memberships"
    private static let wsRE = PyRegex(#"\s+"#)
    private static let dayRE = PyRegex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
    private static let intRE = PyRegex("^-?[0-9]{1,9}$")
    /// Zeichen, die in keiner Adresse vorkommen duerfen (neben Leerraum und "@"), wie EMAIL_RE in Python
    private static let emailForbidden = Set("<>\"',;:()[]".unicodeScalars)

    static let table = """
        CREATE TABLE IF NOT EXISTS studip_lecturers (
            course_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            role TEXT NOT NULL,                -- dozent | tutor (nie Studierende)
            position INTEGER,
            label TEXT,                        -- "Funktion" aus Stud.IP
            name TEXT,
            username TEXT,
            email TEXT,                        -- leer, wenn Stud.IP sie nicht zeigt
            office_hours TEXT,
            location TEXT,
            institute TEXT,
            fetched_at TEXT,
            PRIMARY KEY (course_id, user_id)
        )
        """
    static let coursesTable = """
        CREATE TABLE IF NOT EXISTS studip_lecturer_courses (
            course_id TEXT PRIMARY KEY,
            fetched_at TEXT NOT NULL
        )
        """

    // MARK: Hilfen

    static func str(_ v: JSONValue?) -> String { v?.string ?? "" }

    static func clip(_ s: String, _ n: Int) -> String {
        PyText.strip(PyText.slice(PyText.strip(wsRE.sub(s, " ")), 0, n))
    }

    static func rel(_ x: JSONValue?, _ name: String) -> JSONValue? {
        guard let d = x?["relationships"]?[name]?["data"], d.object != nil else { return nil }
        return d
    }

    /// `_int(v, default)`: ganze Zahl oder Ziffern-Text, sonst `default`
    static func int(_ v: JSONValue?, _ fallback: Int) -> Int {
        switch v {
        case .number(let n)? where n == n.rounded() && abs(n) < 1e15: return Int(n)
        case .string(let s)?:
            let t = PyText.strip(s)
            return intRE.match(t) != nil ? Int(t) ?? fallback : fallback
        default: return fallback
        }
    }

    // MARK: Lesen

    /// Mitglied eines Kurses mit Rolle Dozent/in oder Tutor/in
    public struct Member: Sendable, Equatable {
        public var userID, role: String
        public var position: Int
        public var label, name, username, email: String

        public var json: JSONValue {
            ["user_id": .string(userID), "role": .string(role), "position": .number(Double(position)), "label": .string(label),
             "name": .string(name), "username": .string(username), "email": .string(email)]
        }
    }

    /// Sprechzeiten, Raum und Einrichtung einer Person
    public struct Profile: Sendable, Equatable {
        public var officeHours, location, institute: String

        public var json: JSONValue { ["office_hours": .string(officeHours), "location": .string(location), "institute": .string(institute)] }
    }

    /// `display_name(a)`: `formatted-name`, sonst Titel, Vorname, Nachname, Titel
    public static func displayName(_ a: JSONValue?) -> String {
        let n = clip(str(a?["formatted-name"]), maxName)
        if !n.isEmpty { return n }
        let parts = ["name-prefix", "given-name", "family-name", "name-suffix"].map { str(a?[$0]) }.filter { !PyText.strip($0).isEmpty }
        return clip(parts.joined(separator: " "), maxName)
    }

    /// `clean_email(v)`: eine einzelne, plausible Adresse, sonst leer
    public static func cleanEmail(_ v: JSONValue?) -> String {
        let s = PyText.strip(str(v))
        guard PyText.length(s) <= 254 else { return "" }
        func allowed(_ part: Substring) -> Bool {
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0 != "@" && !PyText.isSpace($0) && !emailForbidden.contains($0) }
        }
        let at = s.split(separator: "@", omittingEmptySubsequences: false)
        guard at.count == 2, allowed(at[0]) else { return "" }
        let domain = at[1]
        guard let dot = domain.lastIndex(of: ".") else { return "" }
        let tld = domain[domain.index(after: dot)...]
        guard tld.unicodeScalars.count >= 2, tld.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }),
              allowed(domain[..<dot]) else { return "" }
        return s
    }

    static func users(_ included: JSONValue?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for u in included?.array ?? [] where u.object != nil && u["type"]?.string == "users" {
            if let id = StudIPTerms.id(u), out[id] == nil { out[id] = StudIPTerms.attrs(u) }
        }
        return out
    }

    /// `parse_members(body)`: nur `course-memberships` mit Rolle dozent oder tutor, Name und Adresse aus `included`
    public static func parseMembers(_ body: JSONValue?) -> [Member] {
        let users = users(body?["included"])
        var out: [Member] = []
        var seen = Set<String>()
        for (i, m) in (body?["data"]?.array ?? []).enumerated() {
            guard m.object != nil, m["type"]?.string == "course-memberships" else { continue }
            let a = StudIPTerms.attrs(m)
            let role = PyText.lower(PyText.strip(str(a["permission"])))
            let u = rel(m, "user")
            let uid = u?["type"]?.string == "users" ? StudIPTerms.id(u) : nil
            guard roles.contains(role), let uid, !seen.contains(uid) else { continue }
            seen.insert(uid)
            let ua = users[uid] ?? .object([:])
            out.append(Member(userID: uid, role: role, position: int(a["position"], i), label: clip(str(a["label"]), maxLabel),
                              name: displayName(ua), username: clip(str(ua["username"]), 64), email: cleanEmail(ua["email"])))
        }
        return out
    }

    /// `merge_user(m, body)`: leere Felder aus users/{id}
    public static func mergeUser(_ m: Member, _ body: JSONValue?) -> Member {
        let d = body?["data"]
        let a: JSONValue = d?.object != nil && StudIPTerms.id(d) == m.userID ? StudIPTerms.attrs(d) : .object([:])
        var out = m
        if out.name.isEmpty { out.name = displayName(a) }
        if out.username.isEmpty { out.username = clip(str(a["username"]), 64) }
        if out.email.isEmpty { out.email = cleanEmail(a["email"]) }
        return out
    }

    /// `parse_profile(body)`: Standard-Einrichtung zuerst, dann `priority`; die erste mit Sprechzeiten oder Raum
    public static func parseProfile(_ body: JSONValue?) -> Profile {
        var inst: [String: JSONValue] = [:]
        for x in body?["included"]?.array ?? [] where x.object != nil && x["type"]?.string == "institutes" {
            if let id = StudIPTerms.id(x), inst[id] == nil { inst[id] = StudIPTerms.attrs(x) }
        }
        var cands: [(key: (Int, Int, Int), p: Profile)] = []
        for (i, x) in (body?["data"]?.array ?? []).enumerated() {
            guard x.object != nil, x["type"]?.string == "institute-memberships" else { continue }
            let a = StudIPTerms.attrs(x)
            let ref = rel(x, "institute")
            let name = ref.map { clip(str(inst[StudIPTerms.id($0) ?? ""]?["name"]), maxName) } ?? ""
            let office = PyText.strip(PyText.slice(Announcements.htmlToText(str(a["office-hours"])), 0, maxOffice))
            cands.append(((a["is-default"]?.bool == true ? 0 : 1, int(a["priority"], 999), i),
                          Profile(officeHours: office, location: clip(str(a["location"]), maxLocation), institute: name)))
        }
        let sorted = cands.sorted { $0.key < $1.key }
        if let hit = sorted.first(where: { !$0.p.officeHours.isEmpty || !$0.p.location.isEmpty }) { return hit.p }
        return Profile(officeHours: "", location: "", institute: sorted.first?.p.institute ?? "")
    }

    /// `role_label(roles)`: "Dozent/in, Tutor/in"
    public static func roleLabel(_ list: [String]) -> String {
        roles.filter { list.contains($0) }.compactMap { roleLabels[$0] }.joined(separator: ", ")
    }

    /// `message_url(base, username)`: Schreibfenster von Stud.IP mit voreingetragenem Empfaenger (`rec_uname`)
    public static func messageURL(base: String, username: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        let u = PyText.strip(username)
        return "\(b)/dispatch.php/messages/write" + (u.isEmpty ? "" : "?rec_uname=\(PyText.quote(u, safe: ""))")
    }

    public static func mailto(_ email: String) -> String? { email.isEmpty ? nil : "mailto:\(email)" }

    // MARK: Speicher

    static func has(_ c: SQLiteConnection, _ t: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(t)]) != nil
    }

    static func ensure(_ c: SQLiteConnection) throws {
        try c.executeScript(table)
        try c.executeScript(coursesTable)
    }

    /// `store_course`: Lehrende eines Kurses ersetzen; Sprechzeiten bekannter Personen bleiben bis zum neuen Profil
    static func storeCourse(_ c: SQLiteConnection, courseID: String, _ members: [Member], fetchedAt: String) throws {
        try ensure(c)
        var old: [String: (String, String, String)] = [:]
        for r in try c.rows("SELECT user_id, office_hours, location, institute FROM studip_lecturers WHERE course_id=?", [.text(courseID)]) {
            old[str(r["user_id"])] = (str(r["office_hours"]), str(r["location"]), str(r["institute"]))
        }
        try c.execute("DELETE FROM studip_lecturers WHERE course_id=?", [.text(courseID)])
        for m in members {
            let (oh, loc, ins) = old[m.userID] ?? ("", "", "")
            try c.execute("""
                INSERT OR REPLACE INTO studip_lecturers(course_id, user_id, role, position, label, name, username, email,
                office_hours, location, institute, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(courseID), .text(m.userID), .text(m.role), .integer(Int64(m.position)), .text(m.label), .text(m.name),
                      .text(m.username), .text(m.email), .text(oh), .text(loc), .text(ins), .text(fetchedAt)])
        }
        try c.execute("INSERT OR REPLACE INTO studip_lecturer_courses(course_id, fetched_at) VALUES (?, ?)", [.text(courseID), .text(fetchedAt)])
    }

    static func storeProfiles(_ c: SQLiteConnection, _ profiles: [String: Profile]) throws {
        try ensure(c)
        for uid in profiles.keys.sorted(by: PyText.less) {
            let p = profiles[uid]!
            try c.execute("UPDATE studip_lecturers SET office_hours=?, location=?, institute=? WHERE user_id=?",
                          [.text(p.officeHours), .text(p.location), .text(p.institute), .text(uid)])
        }
    }

    /// `due(conn, course_ids, today)`: nie gelesen, aelter als `refreshDays` oder ohne lesbaren Stand; hoechstens `maxCourses`
    public static func due(_ c: SQLiteConnection, courseIDs: [String], today: Int) throws -> [String] {
        var known: [String: JSONValue] = [:]
        if try has(c, "studip_lecturer_courses") {
            for r in try c.rows("SELECT course_id, fetched_at FROM studip_lecturer_courses") { known[str(r["course_id"])] = r["fetched_at"] ?? .null }
        }
        let limit = BerlinClock.isoDate(today - refreshDays)
        var out: [String] = []
        for id in courseIDs where !out.contains(id) {
            let seen = known[id]?.string
            let stamp = seen.flatMap { dayRE.match($0) != nil ? PyText.slice($0, 0, 10) : nil }
            if stamp == nil || !PyText.less(limit, stamp!) { out.append(id) }
        }
        return Array(out.prefix(maxCourses))
    }

    /// `overview(...)`: GET /api/lecturers fuer einen Kurs, ein Modul oder alle aktiven Kurse, mit Suche `q`
    public static func overview(_ c: SQLiteConnection, university: String, base: String, courseID: String? = nil, moduleID: Int? = nil,
                                q: String? = nil, allowed: Bool = true) throws -> JSONValue {
        let available = university == "luh" && allowed
        var out: [String: JSONValue] = ["available": .bool(available), "university": .string(university), "people": .array([]), "count": 0,
                                        "total": 0, "loaded": false, "updated_at": .null, "hint": .null, "no_email": .string(noEmail)]
        guard available else { return .object(out) }
        var whereSQL = "c.active=1"
        var args: [SQLiteValue] = []
        if let courseID, !courseID.isEmpty {
            whereSQL = "l.course_id=?"; args = [.text(courseID)]
        } else if let moduleID {
            whereSQL = "c.module_id=?"; args = [.integer(Int64(moduleID))]
        }
        var rows: [[String: JSONValue]] = []
        if try has(c, "studip_lecturers") {
            rows = try c.rows("""
                SELECT l.course_id, l.user_id, l.role, l.position, l.label, l.name, l.username, l.email, l.office_hours, l.location,
                l.institute, c.title AS course_title, c.module_id AS module_id, m.name AS module_name
                FROM studip_lecturers l JOIN courses c ON c.id=l.course_id LEFT JOIN modules m ON m.id=c.module_id
                WHERE \(whereSQL) ORDER BY l.course_id, l.position, l.user_id
                """, args)
        }
        var stamps: [String] = []
        var loaded = false
        if try has(c, "studip_lecturer_courses") {
            let lw = whereSQL.replacingOccurrences(of: "l.course_id", with: "k.course_id")
            let r = try c.rows("SELECT k.fetched_at FROM studip_lecturer_courses k JOIN courses c ON c.id=k.course_id WHERE \(lw)", args)
            loaded = !r.isEmpty
            stamps = r.compactMap { $0["fetched_at"]?.string }
        }
        struct Person {
            var id: String
            var pos: Int
            var fields: [String: String] = [:]
            var roles: [String] = []
            var courses: [JSONValue] = []
            func f(_ k: String) -> String { fields[k] ?? "" }
        }
        var order: [String] = []
        var people: [String: Person] = [:]
        for r in rows {
            let uid = str(r["user_id"])
            if people[uid] == nil { people[uid] = Person(id: uid, pos: r["position"]?.int ?? 999); order.append(uid) }
            var p = people[uid]!
            for k in ["name", "email", "label", "office_hours", "location", "institute", "username"] where p.f(k).isEmpty {
                let v = str(r[k])
                if !v.isEmpty { p.fields[k] = v }
            }
            let role = str(r["role"])
            if !p.roles.contains(role) { p.roles.append(role) }
            if let pos = r["position"]?.int, pos < p.pos { p.pos = pos }
            p.courses.append(["course_id": r["course_id"] ?? .null, "title": .string(str(r["course_title"])), "module_id": r["module_id"] ?? .null,
                              "module_name": r["module_name"] ?? .null, "role": .string(role), "role_label": .string(roleLabels[role] ?? role)])
            people[uid] = p
        }
        let total = order.compactMap { people[$0] }
        let needle = PyText.lower(PyText.strip(q ?? ""))
        var chosen = total
        if !needle.isEmpty {
            chosen = total.filter { p in
                let texts = [p.f("name"), p.f("email")] + p.courses.map { str($0["title"]) } + p.courses.map { str($0["module_name"]) }
                return texts.contains { PyText.contains(PyText.lower($0), needle) }
            }
        }
        let scoped = (courseID.map { !$0.isEmpty } ?? false) || moduleID != nil
        if scoped {
            chosen = LocalTimetable.stableSorted(chosen) { a, b in
                let ra = a.roles.contains("dozent") ? 0 : 1, rb = b.roles.contains("dozent") ? 0 : 1
                if ra != rb { return ra < rb }
                if a.pos != b.pos { return a.pos < b.pos }
                let na = PyText.lower(a.f("name")), nb = PyText.lower(b.f("name"))
                if na != nb { return PyText.less(na, nb) }
                return PyText.less(a.id, b.id)
            }
        } else {
            chosen = LocalTimetable.stableSorted(chosen) { a, b in
                let la = PyText.lower(a.f("name")), lb = PyText.lower(b.f("name"))
                let na = la.isEmpty ? "\u{FFFF}" : la, nb = lb.isEmpty ? "\u{FFFF}" : lb
                if na != nb { return PyText.less(na, nb) }
                return PyText.less(a.id, b.id)
            }
        }
        let result: [JSONValue] = chosen.map { p in
            let rs = roles.filter { p.roles.contains($0) }
            let courses = LocalTimetable.stableSorted(p.courses) { a, b in
                let ta = PyText.lower(str(a["title"])), tb = PyText.lower(str(b["title"]))
                if ta != tb { return PyText.less(ta, tb) }
                return PyText.less(str(a["course_id"]), str(b["course_id"]))
            }
            let email = p.f("email")
            return ["id": .string(p.id), "name": .string(p.f("name").isEmpty ? unknownName : p.f("name")), "email": .string(email),
                    "has_email": .bool(!email.isEmpty), "no_email": email.isEmpty ? .string(noEmail) : .null,
                    "roles": .array(rs.map(JSONValue.string)), "role_label": .string(roleLabel(rs)), "label": .string(p.f("label")),
                    "office_hours": .string(p.f("office_hours")), "location": .string(p.f("location")), "institute": .string(p.f("institute")),
                    "username": .string(p.f("username")), "courses": .array(courses),
                    "message_url": .string(messageURL(base: base, username: p.f("username"))),
                    "mailto": mailto(email).map(JSONValue.string) ?? .null]
        }
        var hint: JSONValue = .null
        if result.isEmpty { hint = .string(!needle.isEmpty && !total.isEmpty ? hintNoMatch : loaded ? hintNone : hintNotLoaded) }
        out["people"] = .array(result)
        out["count"] = .number(Double(result.count))
        out["total"] = .number(Double(total.count))
        out["loaded"] = .bool(loaded)
        out["updated_at"] = stamps.max(by: PyText.less).map(JSONValue.string) ?? .null
        out["hint"] = hint
        return .object(out)
    }

    /// `known_person(conn, user_id)`: Lehrende/r eines eigenen Kurses (nur an sie schreibt die App ueber Stud.IP)
    public static func knownPerson(_ c: SQLiteConnection, userID: String) throws -> StudIPPerson? {
        guard try has(c, "studip_lecturers") else { return nil }
        guard let r = try c.rows("SELECT user_id, name FROM studip_lecturers WHERE user_id=? ORDER BY course_id LIMIT 1", [.text(userID)]).first
        else { return nil }
        let n = str(r["name"])
        return StudIPPerson(id: str(r["user_id"]), name: n.isEmpty ? unknownName : n)
    }

    // MARK: Abruf (Geraet)

    /// Was der Abruf geladen hat
    public struct Download: Sendable {
        /// je gelesenem Kurs die Lehrenden (leer: Stud.IP zeigt keine), in der Reihenfolge des Abrufs
        public var courses: [(id: String, members: [Member])] = []
        public var profiles: [String: Profile] = [:]
        public var missing: [String: JSONValue] = [:]
        public var requests: [String] = []
        public var sessionExpired = false
        public init() {}

        /// {courses, people, profiles, requests} wie `sync` in Python
        public var summary: JSONValue {
            ["courses": .number(Double(courses.count)), "people": .number(Double(courses.reduce(0) { $0 + $1.members.count })),
             "profiles": .number(Double(profiles.count)), "requests": .number(Double(requests.count))]
        }
    }

    /// Liest die Lehrenden der Kurse `due` (vorher `due(...)`). Wirft nie: abgelaufene Sitzung steht im Ergebnis,
    /// Netzfehler beenden den Abruf, andere Fehler betreffen nur ihren Kurs. Reihenfolge der Anfragen wie in Python.
    public static func fetch(client: StudIPClient, due: [String], missing: [String: JSONValue], today: Int) async -> Download {
        var d = Download()
        d.missing = missing
        let t = BerlinClock.isoDate(today)
        guard StudIPExtras.shouldAsk(missing, missingName, today: t), !due.isEmpty else { return d }
        var stop = false

        /// (Status, JSON); 0 bei Netz- oder Lesefehler
        func ask(_ path: String) async -> (Int, JSONValue?) {
            guard !stop else { return (0, nil) }
            d.requests.append(path)
            do {
                return (200, try await client.json("jsonapi.php/v1/" + path, retryTransient: false))
            } catch StudIPError.http(let status, _) {
                return (status, nil)
            } catch StudIPError.sessionExpired {
                d.sessionExpired = true
                stop = true
                return (0, nil)
            } catch {
                if StudIPScheduleStore.stopsFetch(error) { stop = true }
                return (0, nil)
            }
        }

        var notFound = 0, lookups = 0
        var stored: [Member] = []
        for cid in due {
            guard !stop else { break }
            var members: [Member] = []
            var ok = true
            for role in roles {
                let basePath = "courses/\(cid)/memberships?filter[permission]=\(role)&page[limit]=100"
                var (status, body) = await ask(basePath + "&include=user")
                if status == 400 { (status, body) = await ask(basePath) }
                if status == 404 { notFound += 1 }
                if status == 403 { members = []; ok = true; break }
                guard (200..<300).contains(status), let body, body.object != nil else { ok = false; break }
                let have = Set(members.map(\.userID))
                members += parseMembers(body).filter { !have.contains($0.userID) }
            }
            guard ok, !stop else { continue }
            for i in members.indices where members[i].name.isEmpty && lookups < maxUserLookups {
                lookups += 1
                let (status, body) = await ask("users/\(members[i].userID)")
                if (200..<300).contains(status) { members[i] = mergeUser(members[i], body) }
            }
            guard !stop else { break }
            d.courses.append((cid, members))
            stored += members
        }
        if d.courses.isEmpty && notFound == due.count && !stop {
            d.missing = StudIPExtras.remember(d.missing, missingName, status: 404, today: t)
        }
        if !stop, StudIPExtras.shouldAsk(d.missing, profileMissingName, today: t) {
            var seen: [String] = []
            // nur fuer Dozent/innen (Empfehlung nach dem echten Test 06.11.2026)
            for m in stored where m.role == "dozent" && !seen.contains(m.userID) { seen.append(m.userID) }
            for uid in seen.prefix(maxProfiles) {
                var (status, body) = await ask("users/\(uid)/institute-memberships?include=institute")
                if status == 400 { (status, body) = await ask("users/\(uid)/institute-memberships") }
                if stop { break }
                if status == 404 && d.profiles.isEmpty {
                    d.missing = StudIPExtras.remember(d.missing, profileMissingName, status: 404, today: t)
                    break
                }
                if (200..<300).contains(status), let body, body.object != nil { d.profiles[uid] = parseProfile(body) }
            }
        }
        return d
    }

    /// Schreibt den Abruf (in einer Transaktion aufrufen)
    public static func store(_ d: Download, in c: SQLiteConnection, fetchedAt: String) throws {
        for (id, members) in d.courses { try storeCourse(c, courseID: id, members, fetchedAt: fetchedAt) }
        if !d.courses.isEmpty || !d.profiles.isEmpty { try storeProfiles(c, d.profiles) }
        try StudIPExtras.saveMissing(c, d.missing)
    }

    /// Ein Lauf auf dem Geraet: faellige Kurse, Abruf, Speichern. Nur an Hochschulen mit Stud.IP (`university == "luh"`).
    @discardableResult
    public static func run(client: StudIPClient, database: SQLiteDatabase, courseIDs: [String], clock: UniFlowClock,
                           university: String = "luh") async -> Download {
        guard university == "luh", let today = BerlinClock.parseISODate(clock.today) else { return Download() }
        guard let (due, missing) = try? await database.withConnection({ c in
            (try Self.due(c, courseIDs: courseIDs, today: today), try StudIPExtras.loadMissing(c))
        }) else { return Download() }
        let d = await fetch(client: client, due: due, missing: missing, today: today)
        let now = clock.nowISO
        _ = try? await database.transaction { try store(d, in: $0, fetchedAt: now) }
        return d
    }
}
