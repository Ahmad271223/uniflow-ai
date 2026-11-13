import Foundation

/// Faecher im Lernkalender (Auftrag des Inhabers 12.11.2026): einmal selbst entscheiden, welche Module der Lernkalender
/// plant. Nicht gewaehlte Faecher bekommen keine Lernpakete und Lernbloecke, bleiben aber in Modulen, Stundenplan und
/// Dokumenten sichtbar.
///
/// Gespeichert in `settings` (mit dem Geraeteabgleich wie die uebrigen Lerneinstellungen) als Liste der Module, die
/// der Lernkalender *nicht* plant (`plan_modules_off`, Modulnamen: Module heissen wie ihr Fach, `ensureModules`
/// erkennt sie am Namen; die IDs unterscheiden sich je Geraet). Darum sind alle aktuellen Module von selbst
/// geplant, auch neue eines spaeteren Abgleichs; Module, die fuer eine Studiengruppe entstehen
/// (`StudIPStudyGroups.applyModules`), kommen beim Anlegen auf die Liste.
///
/// Bewusst klein und abgegrenzt (parallel entsteht der Smart Planner mit Lernzielen je Modul): diese Liste, der Filter
/// `plannedModules` an den Stellen, die Module zum Planen lesen, und `GET/POST /api/calendar/modules`.
public enum StudyPlanModules {
    /// Liste (JSON) der Modulnamen, die der Lernkalender nicht plant
    public static let offKey = "plan_modules_off"
    /// "1", sobald die Frage "Was soll in den Lernkalender?" beantwortet oder mit "Später" geschlossen ist
    public static let askedKey = "plan_modules_asked"

    /// Modulnamen, die der Lernkalender nicht plant (kaputter Eintrag: keine)
    public static func off(_ c: SQLiteConnection) throws -> Set<String> {
        guard let text = try c.queryOne("SELECT value FROM settings WHERE key=?", [.text(offKey)])?[0].string,
              let list = (try? PyJSON.parse(text))?.json.array else { return [] }
        return Set(list.compactMap(\.string))
    }

    static func write(_ c: SQLiteConnection, off names: Set<String>) throws {
        let text = JSONValue.array(names.sorted().map(JSONValue.string)).jsonString()
        try c.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      [.text(offKey), .text(text)])
    }

    /// Ein Modul im Lernkalender planen (`on`) oder nicht
    public static func setPlanned(_ c: SQLiteConnection, name: String, _ on: Bool) throws {
        var names = try off(c)
        if on { names.remove(name) } else { names.insert(name) }
        try write(c, off: names)
    }

    /// Umbenanntes Modul: die Wahl bleibt (Modul-Bearbeiten)
    static func renamed(_ c: SQLiteConnection, from old: String, to new: String) throws {
        var names = try off(c)
        guard old != new, names.remove(old) != nil else { return }
        names.insert(new)
        try write(c, off: names)
    }

    public static func asked(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT value FROM settings WHERE key=?", [.text(askedKey)])?[0].string == "1"
    }

    static func markAsked(_ c: SQLiteConnection) throws {
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, '1')", [.text(askedKey)])
    }

    /// Die Module, die der Lernkalender plant: aktive Module (wie bisher, nach `sort`) ohne die abgewaehlten
    static func plannedModules(_ c: SQLiteConnection) throws -> [SQLiteRow] {
        let skip = try off(c)
        return try c.query("SELECT * FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort").filter { m in
            guard let name = m["name"]?.string else { return true }
            return !skip.contains(name)
        }
    }

    /// IDs aller Module (auch inaktiver), die der Lernkalender nicht plant
    static func offModuleIDs(_ c: SQLiteConnection) throws -> Set<Int64> {
        let skip = try off(c)
        guard !skip.isEmpty else { return [] }
        return Set(try c.query("SELECT id, name FROM modules").compactMap { m in
            guard let name = m["name"]?.string, skip.contains(name) else { return nil }
            return m["id"]?.int64
        })
    }

    /// Plant der Lernkalender dieses Modul? (ohne Modul: ja)
    static func isPlanned(_ c: SQLiteConnection, moduleID: SQLiteValue?) throws -> Bool {
        guard let id = moduleID?.int64 else { return true }
        return try !offModuleIDs(c).contains(id)
    }

    /// Lernpakete, die automatisch entstanden und nie angefasst wurden (alter Lernplan `generated=1` oder
    /// Stundenplaner-Block ohne Sperre und ohne Verschieben von Hand): nichts erledigt, nichts begonnen, keine Lernzeit
    static let untouchedAutoSQL = """
        (COALESCE(p.generated,0)=1 OR p.source='smart') AND COALESCE(p.locked,0)=0 AND COALESCE(p.manual,0)=0
        AND p.status NOT IN ('erledigt','teilweise','in_bearbeitung')
        AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id AND t.status IN ('erledigt','teilweise','in_bearbeitung'))
        AND NOT EXISTS (SELECT 1 FROM study_sessions s WHERE s.package_id=p.id AND s.deleted_at IS NULL)
        """

    /// Abgewaehlte Module: ihre unberuehrten automatischen Lernpakete und -bloecke entfernen (auch vergangene, damit
    /// "Nachholen" sie nicht wieder einplant). Selbst angelegte, gesperrte, verschobene oder begonnene bleiben und
    /// werden gezaehlt (`kept`: kuenftige, nicht erledigte), damit die App fragen kann. Mit `own` auch diese kuenftigen
    /// (nur auf ausdrueckliche Rueckfrage; Erledigtes und Lernzeit bleiben immer).
    @discardableResult
    static func dropUnplanned(_ c: SQLiteConnection, today: Int, own: Bool = false) throws -> (removed: Int, kept: Int) {
        let ids = try offModuleIDs(c)
        guard !ids.isEmpty else { return (0, 0) }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let args = ids.sorted().map { SQLiteValue.integer($0) }
        var removed = 0
        for p in try c.query("SELECT p.id FROM study_packages p WHERE p.module_id IN (\(marks)) AND \(untouchedAutoSQL)", args) {
            try c.execute("DELETE FROM study_tasks WHERE package_id=?", [p["id"] ?? .null])
            try c.execute("DELETE FROM study_packages WHERE id=?", [p["id"] ?? .null])
            removed += 1
        }
        let futureSQL = """
            SELECT p.id FROM study_packages p WHERE p.module_id IN (\(marks)) AND p.date >= ?
            AND p.status NOT IN ('erledigt','teilweise','verschoben','uebersprungen')
            """
        if own {
            for p in try c.query(futureSQL, args + [.text(BerlinClock.isoDate(today))]) {
                let id = p["id"] ?? .null
                try c.execute("DELETE FROM study_tasks WHERE package_id=? AND status<>'erledigt'", [id])
                if try c.queryOne("SELECT 1 FROM study_tasks WHERE package_id=?", [id]) == nil {
                    try c.execute("UPDATE study_sessions SET package_id=NULL WHERE package_id=?", [id])
                    try c.execute("DELETE FROM study_packages WHERE id=?", [id])
                    removed += 1
                }
            }
        }
        let kept = try c.query(futureSQL, args + [.text(BerlinClock.isoDate(today))]).count
        return (removed, kept)
    }

    /// `GET /api/calendar/modules`: aktuelle Module mit Haken "Im Lernkalender planen" und ob schon gefragt wurde;
    /// `kept`: kuenftige selbst angelegte/geaenderte Lernpakete abgewaehlter Module (die App fragt, ob sie weg sollen)
    public static func overview(_ c: SQLiteConnection, today: Int? = nil) throws -> JSONValue {
        let skip = try off(c)
        let modules: [JSONValue] = try c.query("SELECT id, name, color FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, name").map { m in
            let name = m["name"]?.string ?? ""
            return ["id": m["id"]?.json ?? .null, "name": .string(name), "color": m["color"]?.json ?? .null,
                    "planned": .bool(!skip.contains(name))]
        }
        var out: [String: JSONValue] = ["asked": .bool(try asked(c)), "modules": .array(modules)]
        if let today { out["kept"] = .number(Double(try keptCount(c, today: today))) }
        return .object(out)
    }

    static func keptCount(_ c: SQLiteConnection, today: Int) throws -> Int {
        let ids = try offModuleIDs(c)
        guard !ids.isEmpty else { return 0 }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try c.query("""
            SELECT p.id FROM study_packages p WHERE p.module_id IN (\(marks)) AND p.date >= ?
            AND p.status NOT IN ('erledigt','teilweise','verschoben','uebersprungen')
            """, ids.sorted().map { SQLiteValue.integer($0) } + [.text(BerlinClock.isoDate(today))]).count
    }

    /// `POST /api/calendar/modules` mit `{"modules": [{"name": …, "planned": true|false}]}` (fehlt die Liste: nur
    /// "gefragt" merken, z. B. "Später"). Nicht genannte Module behalten ihre Wahl. Abgewaehlte Module verlieren sofort
    /// ihre unberuehrten automatischen Lernpakete; `"remove_own": true` (nach Rueckfrage) auch die selbst angelegten
    /// bzw. geaenderten kuenftigen.
    public static func save(_ c: SQLiteConnection, _ body: JSONValue, today: Int) throws {
        var names = try off(c)
        for m in body["modules"]?.array ?? [] {
            guard let name = m["name"]?.string, !name.isEmpty, let on = m["planned"]?.bool else {
                throw LocalHTTPError(status: 422, message: "modules: Liste aus name und planned")
            }
            if on { names.remove(name) } else { names.insert(name) }
        }
        if body["modules"] != nil { try write(c, off: names) }
        if let own = body["remove_own"], own.bool == nil { throw LocalHTTPError(status: 422, message: "remove_own: ja oder nein") }
        try dropUnplanned(c, today: today, own: body["remove_own"]?.bool == true)
        try markAsked(c)
    }
}

/// `/api/calendar/modules`: Faecher im Lernkalender (nur lokal)
enum StudyPlanModulesEndpoints: LocalEndpointModule {
    static let name = "Fächer im Lernkalender"

    static func register(on router: LocalRouter) {
        router.get("/api/calendar/modules") { _, ctx in
            let today = LocalTimetable.today(ctx.clock)
            return .json(try await ctx.database.withConnection { try StudyPlanModules.overview($0, today: today) })
        }
        router.post("/api/calendar/modules") { req, ctx in
            let body = try req.jsonBody()
            let today = LocalTimetable.today(ctx.clock)
            return .json(try await ctx.database.transaction { c in
                try StudyPlanModules.save(c, body, today: today)
                return try StudyPlanModules.overview(c, today: today)
            })
        }
    }
}
