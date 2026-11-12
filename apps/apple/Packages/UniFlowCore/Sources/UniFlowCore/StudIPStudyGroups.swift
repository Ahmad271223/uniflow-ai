import Foundation

/// Studiengruppen aus Stud.IP (Auftrag des Inhabers 12.11.2026).
///
/// Stud.IP fuehrt Studiengruppen als eigene "Veranstaltungen" mit eigener Veranstaltungsklasse (Klasse
/// "Studiengruppen", `studygroup_mode`); die JSON:API liefert sie in `users/{id}/courses` wie jeden Kurs, nur mit der
/// Veranstaltungsart (`course-type`) der Studiengruppe. Im Stud.IP-Standard ist das die Art 99 ("Studiengruppe" in
/// Klasse 99); eine Hochschule kann die Nummer anders vergeben. Bis zum 12.11.2026 behandelte der Abgleich sie wie
/// jeden anderen Kurs: von selbst ausgewaehlt (ohne Startsemester bzw. laufend), alle Dateien geladen, Kurszeiten in
/// den Stundenplan, Modul nach dem Titel (Befund iPad 07.11.2026: "eine Studiengruppe lud alle Dateien").
///
/// Jetzt entscheidet der Nutzer je Gruppe (Vorgabe: alles aus): Dateien durchsuchen und zu "Dokumente & Notizen",
/// einem Modul zuordnen (bestehendes oder eigenes), Termine in den Stundenplan. Eine ausgeschaltete Gruppe kostet keinen
/// Abruf ausser der Kursliste. Nur lesend auf Stud.IP.
public enum StudIPStudyGroups {
    /// Veranstaltungsarten der Studiengruppen (Stud.IP-Standard: 99)
    public static let standardTypes: Set<Int> = [99]

    /// Ist der Kurs eine Studiengruppe? Nach der Veranstaltungsart; ohne Art (aeltere Kursliste) nur ein Kurs ohne
    /// Veranstaltungsnummer, dessen Titel "Studiengruppe" nennt (Lehrveranstaltungen haben an der LUH eine Nummer).
    public static func isStudyGroup(_ c: StudIPCourse, types: Set<Int> = standardTypes) -> Bool {
        if let t = c.courseType { return types.contains(t) }
        return c.number == nil && c.title.range(of: "studiengruppe", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Wahl fuer eine Gruppe; Vorgabe alles aus
    public struct Choice: Codable, Equatable, Sendable {
        /// Dateien durchsuchen und zu "Dokumente & Notizen" hinzufuegen
        public var files: Bool
        /// einem Modul zuordnen
        public var module: Bool
        /// Name des gewaehlten Moduls; nil = eigenes Modul mit dem Titel der Gruppe
        public var moduleName: String?
        /// Termine (Kurszeiten, Einzeltermine) in den Stundenplan
        public var timetable: Bool

        public init(files: Bool = false, module: Bool = false, moduleName: String? = nil, timetable: Bool = false) {
            self.files = files
            self.module = module
            self.moduleName = moduleName
            self.timetable = timetable
        }

        /// Irgendetwas an: die Gruppe kommt als Kurs in die Datenbank
        public var anyOn: Bool { files || module || timetable }
    }

    /// Gespeicherte Wahl aller Gruppen (je Container in dessen UserDefaults, wie die Kursauswahl)
    public struct Settings: Codable, Equatable, Sendable {
        /// Die Frage "Studiengruppen" wurde gezeigt und beantwortet oder mit "Später" geschlossen
        public var asked: Bool
        public var choices: [String: Choice]

        public init(asked: Bool = false, choices: [String: Choice] = [:]) {
            self.asked = asked
            self.choices = choices
        }

        public func choice(_ courseID: String) -> Choice { choices[courseID] ?? Choice() }

        public static let defaultsKey = "uniflow.studip.studyGroups"

        public static func load(_ defaults: UserDefaults) -> Settings {
            guard let d = defaults.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
            return s
        }

        public func save(_ defaults: UserDefaults) {
            if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.defaultsKey) }
        }
    }

    /// Was der Abgleich mit den Kursen tut
    public struct Plan: Equatable, Sendable {
        /// in die Datenbank: ausgewaehlte Kurse (ohne Gruppen) und Gruppen mit irgendeinem Schalter an, in der
        /// Reihenfolge der Kursliste
        public var store: [StudIPCourse]
        /// Kurse, deren Dateien gelesen und geladen werden
        public var files: Set<String>
        /// Kurse, deren Termine in den Stundenplan kommen
        public var timetable: Set<String>
        /// alle erkannten Gruppen
        public var groups: [StudIPCourse]
        /// Gruppen ohne Termine im Stundenplan (ihre Kurszeiten fallen beim Speichern weg)
        public var timetableOff: Set<String>
    }

    /// Kursauswahl mit Studiengruppen: normale Kurse wie bisher nach `selected`; Gruppen nur nach ihrer Wahl (die
    /// Kursauswahl gilt fuer sie nicht mehr, damit eine Gruppe nicht still von selbst mitkommt)
    public static func plan(courses: [StudIPCourse], selected: Set<String>, settings: Settings,
                            types: Set<Int> = standardTypes) -> Plan {
        var out = Plan(store: [], files: [], timetable: [], groups: [], timetableOff: [])
        for c in courses {
            if isStudyGroup(c, types: types) {
                out.groups.append(c)
                let ch = settings.choice(c.id)
                if ch.anyOn { out.store.append(c) }
                if ch.files { out.files.insert(c.id) }
                if ch.timetable { out.timetable.insert(c.id) } else { out.timetableOff.insert(c.id) }
            } else if selected.contains(c.id) {
                out.store.append(c)
                out.files.insert(c.id)
                out.timetable.insert(c.id)
            }
        }
        return out
    }

    // MARK: Module

    /// Modul je Gruppe nach der Wahl (nach `StudIPLibrary.storeCourses`, in derselben Transaktion). Nur Gruppen, die
    /// als Kurs gespeichert sind:
    /// - Modul aus: keinem Modul zugeordnet und ohne Fach (`ensureModules` legt dann keines an)
    /// - Modul an, gewaehltes Modul vorhanden: diesem zugeordnet
    /// - sonst eigenes Modul mit dem Titel der Gruppe (neu angelegt: im Lernkalender aus, `StudyPlanModules`)
    /// Rueckgabe: Zahl der neu angelegten Module.
    @discardableResult
    public static func applyModules(_ c: SQLiteConnection, groups: [StudIPCourse], settings: Settings, clock: UniFlowClock) throws -> Int {
        var created = 0
        for g in groups {
            guard let row = try c.queryOne("SELECT id, semester, module_id FROM courses WHERE id=?", [.text(g.id)]) else { continue }
            let ch = settings.choice(g.id)
            guard ch.module else {
                try c.execute("UPDATE courses SET module_id=NULL, subject='' WHERE id=?", [.text(g.id)])
                continue
            }
            let wanted = ch.moduleName.flatMap { n in n.isEmpty ? nil : n }
            var target = try wanted.flatMap { try c.queryOne("SELECT id, name FROM modules WHERE name=?", [.text($0)]) }
            if target == nil {
                target = try c.queryOne("SELECT id, name FROM modules WHERE name=?", [.text(g.title)])
                if target == nil {
                    let n = try c.scalar("SELECT COUNT(*) FROM modules")?.int64 ?? 0
                    try c.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                                  [.text(g.title), row["semester"] ?? .null, .text(try ModuleColors.next(c)), .integer(n), .text(clock.nowISO)])
                    target = try c.queryOne("SELECT id, name FROM modules WHERE id=?", [.integer(c.lastInsertRowID)])
                    try StudyPlanModules.setPlanned(c, name: g.title, false)
                    created += 1
                }
            }
            guard let t = target else { continue }
            try c.execute("UPDATE courses SET module_id=?, subject=? WHERE id=?", [t["id"] ?? .null, t["name"] ?? .null, .text(g.id)])
            // ein Modul, das nur noch diese Gruppe hat, war vielleicht ausgeschaltet (ohne aktiven Kurs): wieder an
            try c.execute("UPDATE modules SET active=1 WHERE id=? AND COALESCE(active_custom,0)=0", [t["id"] ?? .null])
        }
        return created
    }

    // MARK: Stundenplan

    /// Termine von Gruppen ohne "Termine in den Stundenplan" entfernen: geladene Einzeltermine und Kurszeiten und die
    /// automatisch uebernommenen, unveraenderten Serien (Quelle "studip") samt Verknuepfung. Von Hand angelegte oder
    /// bestaetigte Serien bleiben. Rueckgabe: Zahl der entfernten Serien.
    @discardableResult
    public static func removeTimetable(_ c: SQLiteConnection, courseIDs: Set<String>) throws -> Int {
        guard !courseIDs.isEmpty else { return 0 }
        var removed = 0
        let hasLinks = try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_timetable_links'") != nil
        let hasCycles = try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_cycle_dates'") != nil
        for id in courseIDs.sorted() {
            try c.execute("DELETE FROM studip_events WHERE course_id=?", [.text(id)])
            if hasCycles { try c.execute("DELETE FROM studip_cycle_dates WHERE course_id=?", [.text(id)]) }
            for e in try c.query("SELECT id FROM course_events WHERE course_id=? AND source='studip'", [.text(id)]) {
                let eid = e["id"] ?? .null
                try c.execute("DELETE FROM event_exceptions WHERE event_id=?", [eid])
                try c.execute("DELETE FROM course_events WHERE id=?", [eid])
                if hasLinks { try c.execute("DELETE FROM studip_timetable_links WHERE event_id=?", [eid]) }
                removed += 1
            }
        }
        return removed
    }
}
