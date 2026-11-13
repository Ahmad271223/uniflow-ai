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

    /// `GET /api/calendar/modules`: aktuelle Module mit Haken "Im Lernkalender planen" und ob schon gefragt wurde
    public static func overview(_ c: SQLiteConnection) throws -> JSONValue {
        let skip = try off(c)
        let modules: [JSONValue] = try c.query("SELECT id, name, color FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, name").map { m in
            let name = m["name"]?.string ?? ""
            return ["id": m["id"]?.json ?? .null, "name": .string(name), "color": m["color"]?.json ?? .null,
                    "planned": .bool(!skip.contains(name))]
        }
        return ["asked": .bool(try asked(c)), "modules": .array(modules)]
    }

    /// `POST /api/calendar/modules` mit `{"modules": [{"name": …, "planned": true|false}]}` (fehlt die Liste: nur
    /// "gefragt" merken, z. B. "Später"). Nicht genannte Module behalten ihre Wahl.
    public static func save(_ c: SQLiteConnection, _ body: JSONValue) throws {
        var names = try off(c)
        for m in body["modules"]?.array ?? [] {
            guard let name = m["name"]?.string, !name.isEmpty, let on = m["planned"]?.bool else {
                throw LocalHTTPError(status: 422, message: "modules: Liste aus name und planned")
            }
            if on { names.remove(name) } else { names.insert(name) }
        }
        if body["modules"] != nil { try write(c, off: names) }
        try markAsked(c)
    }
}

/// `/api/calendar/modules`: Faecher im Lernkalender (nur lokal)
enum StudyPlanModulesEndpoints: LocalEndpointModule {
    static let name = "Fächer im Lernkalender"

    static func register(on router: LocalRouter) {
        router.get("/api/calendar/modules") { _, ctx in
            .json(try await ctx.database.withConnection { try StudyPlanModules.overview($0) })
        }
        router.post("/api/calendar/modules") { req, ctx in
            let body = try req.jsonBody()
            return .json(try await ctx.database.transaction { c in
                try StudyPlanModules.save(c, body)
                return try StudyPlanModules.overview(c)
            })
        }
    }
}
