import Foundation

/// Reihenfolge des Abgleichs: zuerst das aktuelle Semester (Wunsch des Inhabers 05.11.2026, wie app/sync_order.py,
/// docs/SYNC-REIHENFOLGE-2026-11-05.md).
///
/// Befund: Wer im 7. Semester ist, wartete beim ersten Abgleich, bis Dateien der Semester 1 bis 6 geladen waren, bevor
/// er sein Semester und seinen Stundenplan sah. Regel fuer jedes Portal (Stud.IP, Moodle/Learnweb, HISinOne/LSF/QIS),
/// beim ersten und jedem vollen Abgleich:
///
/// - (a) `current`: Stundenplan, Kurse/Module des aktuellen Semesters mit Dateien, Ankuendigungen, Pruefungsterminen
/// - (b) `grades`: Noten
/// - (c) `upcoming`: naechstes Semester, falls das Portal es schon zeigt
/// - (d) `older`: fruehere Semester im Hintergrund, neuestes zuerst, gedrosselt, fortsetzbar, nie blockierend;
///   Einstellung "Ältere Semester laden: Automatisch / Nur WLAN / Aus" (`OlderSemesters.Mode`), Stromsparmodus pausiert
///
/// Nach (a) zeigt die Oberflaeche das aktuelle Semester ("Aktuelles Semester ist da · ältere Semester werden im
/// Hintergrund geladen (3 von 6)"). Der Stand der Stufen gehoert nur zu diesem Geraet (`sync_stage_state`, erst bei
/// Bedarf angelegt, nicht im Geraete-Abgleich).
public enum SyncStage: String, CaseIterable, Sendable, Comparable {
    case current, grades, upcoming, older

    public static func < (a: SyncStage, b: SyncStage) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .current: return "Aktuelles Semester"
        case .grades: return "Noten"
        case .upcoming: return "Nächstes Semester"
        case .older: return "Frühere Semester"
        }
    }
}

public enum SyncOrder {
    // MARK: Aktuelles Semester

    /// Semester aus der Semesterliste eines Portals: Titel ("SoSe 2026", LSF-Kennung "20262") und, falls bekannt,
    /// Beginn und Ende (ISO). Stud.IP: `semesters` der Kursliste; HISinOne/LSF: Semesterwechsel; Moodle: Kategorien.
    public struct PortalTerm: Sendable, Equatable {
        public let title: String
        public let start: String?
        public let end: String?
        public init(title: String, start: String? = nil, end: String? = nil) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Semesterbeginn (Monat) je Hochschule: (Sommer, Winter); LUH und Hildesheim April/Oktober, HsH Maerz/September
    public static func termStarts(_ university: UniversityKey?) -> (summer: Int, winter: Int) {
        university == .hsh ? (3, 9) : (4, 10)
    }

    /// Semester nach dem Datum mit den Grenzen der Hochschule (`date_term`)
    public static func dateTerm(_ today: String, university: UniversityKey? = nil) -> Semesters.Key {
        let (s, w) = termStarts(university)
        let y = Int(PyText.slice(today, 0, 4)) ?? 0, m = Int(PyText.slice(today, 5, 7)) ?? 0
        if s <= m && m < w { return Semesters.Key(year: y, half: 1) }
        return Semesters.Key(year: m >= w ? y : y - 1, half: 2)
    }

    /// Schluessel eines Semesters: Text ("SoSe 2026", "WS 26/27") oder LSF-Kennung ("20262" = WiSe 2026/27)
    public static func termKey(_ s: String?) -> Semesters.Key? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count == 5, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber), let half = Int(String(s.suffix(1))), half == 1 || half == 2,
           let year = Int(String(s.prefix(4))) {
            return Semesters.Key(year: year, half: half)
        }
        return Semesters.key(s)
    }

    /// Aktuelles Semester (`current_term`): 1. ein Semester des Portals, das heute laeuft (juengster Beginn), 2. sonst
    /// das Datum mit den Grenzen der Hochschule
    public static func currentTerm(today: String, terms: [PortalTerm] = [], university: UniversityKey? = nil) -> Semesters.Key {
        let day = PyText.slice(today, 0, 10)
        var running: [(String, Semesters.Key)] = []
        for t in terms {
            guard let k = termKey(t.title), let start = t.start.map({ PyText.slice($0, 0, 10) }), let end = t.end.map({ PyText.slice($0, 0, 10) }),
                  !start.isEmpty, !end.isEmpty, start <= day, day <= end else { continue }
            running.append((start, k))
        }
        if let best = running.max(by: { ($0.0, $0.1) < ($1.0, $1.1) }) { return best.1 }
        return dateTerm(day, university: university)
    }

    /// Stufe eines Kurses (`split`): aus -> `older`; aktiv und spaeter als das aktuelle Semester -> `upcoming`; sonst
    /// `current` (auch ohne erkennbares Semester und noch laufende Kurse des Vorsemesters in der Pruefungszeit)
    public static func stage(active: Bool, semester: String?, semesterEnd: String? = nil, current: Semesters.Key) -> SyncStage {
        if !active { return .older }
        if let k = Semesters.key(semester) ?? Semesters.key(semesterEnd), k > current { return .upcoming }
        return .current
    }

    /// Kurse frueherer Semester: neuestes zuerst, ohne erkennbares Semester zuletzt, sonst wie geliefert
    public static func newestFirst<C>(_ items: [C], semester: (C) -> String?) -> [C] {
        items.enumerated().sorted { a, b in
            let ka = Semesters.key(semester(a.element)), kb = Semesters.key(semester(b.element))
            if ka != kb {
                guard let ka else { return false }
                guard let kb else { return true }
                return ka > kb
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Stufen ausfuehren

    /// Ein Schritt des Abgleichs: Stufe, Name (Protokoll), Arbeit
    public struct Step: Sendable {
        public let stage: SyncStage
        public let name: String
        public let run: @Sendable () async throws -> Void
        public init(_ stage: SyncStage, _ name: String, _ run: @escaping @Sendable () async throws -> Void) {
            self.stage = stage
            self.name = name
            self.run = run
        }
    }

    public struct StepResult: Sendable, Equatable {
        public let stage: SyncStage
        public let name: String
        public let ok: Bool
    }

    /// Schritte in der Reihenfolge der Stufen (innerhalb einer Stufe wie gegeben); ein Fehler haelt die uebrigen nicht
    /// an, ein Abbruch schon. `onStage` kommt, sobald alle Schritte einer Stufe durch sind.
    @discardableResult
    public static func run(_ steps: [Step], onStage: (@Sendable (SyncStage) async -> Void)? = nil) async -> [StepResult] {
        let ordered = steps.enumerated().sorted { ($0.element.stage, $0.offset) < ($1.element.stage, $1.offset) }.map(\.element)
        var out: [StepResult] = []
        for (i, step) in ordered.enumerated() {
            if Task.isCancelled { break }
            var ok = true
            do { try await step.run() } catch { ok = false }
            out.append(StepResult(stage: step.stage, name: step.name, ok: ok))
            if i + 1 == ordered.count || ordered[i + 1].stage != step.stage { await onStage?(step.stage) }
        }
        return out
    }

    // MARK: Stand je Geraet

    static let table = "CREATE TABLE IF NOT EXISTS sync_stage_state (key TEXT PRIMARY KEY, value TEXT);"

    public static func state(_ c: SQLiteConnection, _ key: String) throws -> String? {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_stage_state'") != nil else { return nil }
        return try c.queryOne("SELECT value FROM sync_stage_state WHERE key=?", [.text(key)])?["value"]?.string
    }

    public static func setState(_ c: SQLiteConnection, _ key: String, _ value: String?) throws {
        try c.executeScript(table)
        if let value {
            try c.execute("INSERT OR REPLACE INTO sync_stage_state(key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try c.execute("DELETE FROM sync_stage_state WHERE key=?", [.text(key)])
        }
    }

    /// Stufe (a) ist durch: die Oberflaeche zeigt das aktuelle Semester
    public static func markCurrentReady(_ c: SQLiteConnection, now: String) throws {
        try setState(c, "current_ready_at", now)
    }

    /// Stufe (d) laeuft bzw. pausiert (Grund wie `Pause.rawValue`)
    public static func setOlder(_ c: SQLiteConnection, running: Bool, paused: OlderLoadPolicy.Pause? = nil) throws {
        try setState(c, "older_running", running ? "1" : nil)
        try setState(c, "older_paused", paused?.rawValue)
    }

    // MARK: Fortschritt und Hinweis

    public struct OlderProgress: Sendable, Equatable {
        /// Semester mit Kursen frueherer Semester, davon vollstaendig geladene; Kurse, die Stufe (d) noch holt
        public let total: Int
        public let done: Int
        public let pending: Int
        public init(total: Int, done: Int, pending: Int) {
            self.total = total
            self.done = done
            self.pending = pending
        }
    }

    public static func olderProgress(_ c: SQLiteConnection, today: String) throws -> OlderProgress {
        let groups = try OlderSemesters.groups(c, today: today)
        let done = groups.filter { $0.courses.allSatisfy(\.loaded) }.count
        return OlderProgress(total: groups.count, done: done, pending: try OlderSemesters.pending(c, today: today).count)
    }

    /// Hinweis unter "Ältere Semester laden" (Einstellungen → Module), gleich in der Web-App (older-semesters.js)
    public static let olderFilesHint = "StudiNow lädt immer zuerst das aktuelle Semester samt Stundenplan, frühere Semester danach im Hintergrund, neuestes zuerst. Aus: StudiNow lädt nur Dateien des aktuellen Semesters. Frühere Semester lädst du jederzeit in der Bibliothek, je Semester oder je Kurs."

    /// Kurzer Hinweis fuer Module und Abgleich (`hint_text`); nil, wenn es nichts zu sagen gibt
    public static func hintText(currentReady: Bool, progress: OlderProgress, running: Bool = false, paused: OlderLoadPolicy.Pause? = nil) -> String? {
        guard currentReady else { return "Aktuelles Semester wird geladen …" }
        guard progress.total > 0, progress.pending > 0 || running else { return nil }
        if let paused { return "Aktuelles Semester ist da · ältere Semester \(paused.text) (\(progress.done) von \(progress.total))" }
        return "Aktuelles Semester ist da · ältere Semester werden im Hintergrund geladen (\(progress.done) von \(progress.total))"
    }

    /// Hochschule der Datenbank (`settings.university`)
    static func university(_ c: SQLiteConnection) throws -> UniversityKey? {
        try c.queryOne("SELECT value FROM settings WHERE key='university'")?["value"]?.string.flatMap(UniversityKey.init(rawValue:))
    }

    /// `GET /api/sync-order` (`status`): gleiche Form wie am PC
    public static func status(_ c: SQLiteConnection, today: String) throws -> JSONValue {
        var readyAt = try state(c, "current_ready_at")
        if readyAt == nil {
            // Bestand von vor dem 05.11.2026: ein erfolgreicher Abgleich heisst, das aktuelle Semester ist da
            readyAt = try c.queryOne("SELECT finished_at FROM sync_log WHERE ok=1 ORDER BY id DESC LIMIT 1")?["finished_at"]?.string
        }
        let progress = try olderProgress(c, today: today)
        let running = try state(c, "older_running") == "1"
        let paused = try state(c, "older_paused").flatMap(OlderLoadPolicy.Pause.init(rawValue:))
        let cur = currentTerm(today: today, university: try university(c))
        let hint = hintText(currentReady: readyAt != nil, progress: progress, running: running, paused: paused)
        return [
            "current": ["key": cur.json, "label": .string(Semesters.label(cur)), "ready": .bool(readyAt != nil), "ready_at": readyAt.map(JSONValue.string) ?? .null],
            "older": ["mode": .string(try OlderSemesters.mode(c).rawValue), "total": .number(Double(progress.total)), "done": .number(Double(progress.done)),
                      "pending": .number(Double(progress.pending)), "running": .bool(running), "paused": paused.map { .string($0.rawValue) } ?? .null],
            "hint": hint.map(JSONValue.string) ?? .null,
        ]
    }

    // MARK: Module nach Semestern

    /// `GET /api/module-semesters` (`modules_by_semester`): aktuelles Semester (Modul-IDs), naechstes, fruehere
    /// neuestes zuerst mit echten Modulen und erkannten Faechern aus Kursen ohne Modul; Zahlen je Semester. Schreibt
    /// (`ensureModules`).
    public static func modulesBySemester(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue {
        let today = clock.today
        try LocalModules.ensureModules(c, clock: clock)
        let cur = currentTerm(today: today, university: try university(c))
        struct Course { let id: String; let title: String; let subject: String?; let kind: String?; let key: Semesters.Key?
                        let moduleID: Int?; let active: Bool; let files: Int; let downloaded: Int }
        let courses: [Course] = try c.rows("""
            SELECT c.id, c.title, c.subject, c.kind, c.semester, c.semester_end, c.module_id, COALESCE(c.active, 1) AS active,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL) AS files,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL AND COALESCE(f.local_path, '')<>'') AS downloaded
            FROM courses c WHERE c.id <> '__user__'
            """).compactMap { r in
            guard let id = r["id"]?.string else { return nil }
            return Course(id: id, title: r["title"]?.string ?? "", subject: r["subject"]?.string, kind: r["kind"]?.string,
                          key: Semesters.key(r["semester"]?.string) ?? Semesters.key(r["semester_end"]?.string),
                          moduleID: r["module_id"]?.int, active: (r["active"]?.int ?? 1) != 0,
                          files: r["files"]?.int ?? 0, downloaded: r["downloaded"]?.int ?? 0)
        }
        struct Module { let id: Int; let name: String; let color: String?; let key: Semesters.Key?; let active: Bool }
        let modules: [Module] = try c.rows("SELECT id, name, color, semester, COALESCE(active, 1) AS active FROM modules ORDER BY id").compactMap { r in
            guard let id = r["id"]?.int else { return nil }
            return Module(id: id, name: r["name"]?.string ?? "", color: r["color"]?.string, key: Semesters.key(r["semester"]?.string),
                          active: (r["active"]?.int ?? 1) != 0)
        }
        let loaded = Set(try OlderSemesters.courses(c, today: today).filter(\.loaded).map(\.id))
        let moduleIDs = Set(modules.map(\.id))

        struct Item { var name: String; var moduleID: Int?; var color: String?; var courses: [Course] }
        func itemJSON(_ it: Item) -> JSONValue {
            let files = it.courses.reduce(0) { $0 + $1.files }
            let done = it.courses.allSatisfy { loaded.contains($0.id) || $0.active }
            return ["name": .string(it.name), "module_id": it.moduleID.map { .number(Double($0)) } ?? .null, "color": it.color.map(JSONValue.string) ?? .null,
                    "course_ids": .array(it.courses.map { .string($0.id) }), "courses": .number(Double(it.courses.count)),
                    "files": .number(Double(files)), "downloaded": .number(Double(it.courses.reduce(0) { $0 + $1.downloaded })),
                    "loaded": .bool(done)]
        }
        func groupJSON(key: Semesters.Key?, label: String, items: [Item], moduleIDs ids: [Int]? = nil) -> JSONValue {
            let sorted = items.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let files = sorted.reduce(0) { $0 + $1.courses.reduce(0) { $0 + $1.files } }
            let done = sorted.reduce(0) { $0 + $1.courses.reduce(0) { $0 + $1.downloaded } }
            var g: [String: JSONValue] = ["key": key?.json ?? .null, "label": .string(label), "items": .array(sorted.map(itemJSON)),
                                          "count": .number(Double(sorted.count)), "files": .number(Double(files)), "downloaded": .number(Double(done)),
                                          "loaded": .bool(sorted.allSatisfy { $0.courses.allSatisfy { loaded.contains($0.id) || $0.active } })]
            if let ids { g["module_ids"] = .array(ids.map { .number(Double($0)) }) }
            return .object(g)
        }

        var currentIDs: [Int] = []
        var upcoming: [Semesters.Key: (ids: [Int], items: [Item])] = [:]
        var older: [Semesters.Key?: [Item]] = [:]
        var olderOrder: [Semesters.Key?] = []
        func addOlder(_ k: Semesters.Key?, _ item: Item) {
            if older[k] == nil { older[k] = []; olderOrder.append(k) }
            older[k]?.append(item)
        }
        for m in modules {
            let cs = courses.filter { $0.moduleID == m.id }
            let k = cs.compactMap(\.key).max() ?? m.key
            if m.active || cs.contains(where: \.active) {
                if let k, k > cur, cs.filter(\.active).allSatisfy({ ($0.key ?? cur) > cur }) {
                    upcoming[k, default: ([], [])].ids.append(m.id)
                    upcoming[k, default: ([], [])].items.append(Item(name: m.name, moduleID: m.id, color: m.color, courses: cs))
                } else {
                    currentIDs.append(m.id)
                }
            } else {
                addOlder(k, Item(name: m.name, moduleID: m.id, color: m.color, courses: cs))
            }
        }
        // Kurse ohne Modul: fruehere je Semester nach Fach erkannt (zwei Kurse "Mathematik I" -> ein Eintrag)
        for course in courses where course.moduleID.map({ !moduleIDs.contains($0) }) ?? true {
            if course.active || (course.kind == "sonstiges" && (course.subject ?? "").isEmpty) { continue }
            let name = (course.subject?.isEmpty == false ? course.subject! : course.title.isEmpty ? "Kurs" : course.title)
                .trimmingCharacters(in: .whitespaces)
            if let i = older[course.key]?.firstIndex(where: { $0.moduleID == nil && $0.name == name }) {
                older[course.key]?[i].courses.append(course)
            } else {
                addOlder(course.key, Item(name: name, moduleID: nil, color: nil, courses: [course]))
            }
        }
        let olderKeys = olderOrder.sorted { a, b in
            guard let a else { return false }
            guard let b else { return true }
            return a > b
        }
        return [
            "current": ["key": cur.json, "label": .string(Semesters.label(cur)), "module_ids": .array(currentIDs.map { .number(Double($0)) }),
                        "count": .number(Double(currentIDs.count))],
            "upcoming": .array(upcoming.keys.sorted().map { k in groupJSON(key: k, label: Semesters.label(k), items: upcoming[k]!.items, moduleIDs: upcoming[k]!.ids) }),
            "older": .array(olderKeys.map { k in groupJSON(key: k, label: k.map(Semesters.label) ?? "Ohne Semesterangabe", items: older[k] ?? []) }),
            "status": try status(c, today: today),
        ]
    }
}

/// Darf Stufe (d) jetzt laufen? (`older_allowed`): Stromsparmodus pausiert, "Nur WLAN" ohne WLAN wartet, im
/// Hintergrund nur mit der Erlaubnis des Systems (BGTask). Bei "Aus" holt Stufe (d) nur Vorgemerktes
/// (`OlderSemesters.pending`).
public enum OlderLoadPolicy {
    public enum Pause: String, Sendable, Equatable {
        case lowPower = "low_power"
        case wifi
        case closed
        case user

        public var text: String {
            switch self {
            case .lowPower: return "pausiert (Stromsparmodus)"
            case .wifi: return "warten auf WLAN"
            case .closed: return "laden weiter, sobald StudiNow offen ist"
            case .user: return "angehalten"
            }
        }
    }

    /// nil: darf laufen; sonst der Grund der Pause
    public static func decide(mode: OlderSemesters.Mode, lowPower: Bool, onWiFi: Bool, appOpen: Bool = true) -> Pause? {
        if !appOpen { return .closed }
        if lowPower { return .lowPower }
        if mode == .wifi && !onWiFi { return .wifi }
        return nil
    }
}

/// `GET /api/sync-order` und `GET /api/module-semesters` wie app/sync_order_api.py
enum SyncOrderEndpoints: LocalEndpointModule {
    static let name = "Abgleich-Stufen"

    static func register(on router: LocalRouter) {
        router.get("/api/sync-order") { _, ctx in
            let today = ctx.clock.today
            return .json(try await ctx.database.withConnection { try SyncOrder.status($0, today: today) })
        }
        router.get("/api/module-semesters") { _, ctx in
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SyncOrder.modulesBySemester($0, clock: clock) })
        }
    }
}
