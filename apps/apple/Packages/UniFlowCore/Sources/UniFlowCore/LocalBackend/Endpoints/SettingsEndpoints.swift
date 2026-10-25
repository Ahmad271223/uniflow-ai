import Foundation

/// Einstellungen wie `db.get_settings`/`db.set_setting` in app/db.py: in `settings` steht alles als Text, beim Lesen
/// entstehen dieselben abgeleiteten Felder (Zahlen, Wahrheitswerte, Listen, `minutes_per_day`, `learn_days`).
/// Fehler, an denen Python scheitert (z. B. `hours_per_day` = "abc"), werden zu 500 mit Meldung.
public enum LocalSettings {
    /// `get_settings(conn)`
    public static func read(_ c: SQLiteConnection) throws -> [String: JSONValue] {
        var s: [String: SQLiteValue] = [:]
        for r in try c.query("SELECT key, value FROM settings") {
            guard let k = r[0].string else { continue }
            s[k] = r[1]
        }
        var out: [String: JSONValue] = [:]
        for (k, v) in s { out[k] = v.json ?? .null }

        let hours = try float(s["hours_per_day"], default: 4, key: "hours_per_day")
        out["hours_per_day"] = .number(hours)
        let freeDays = try loads(s["free_days"], default: "[6]", key: "free_days")
        out["free_days"] = freeDays
        out["test_default_minutes"] = .number(Double(try strictInt(s["test_default_minutes"], default: 90, key: "test_default_minutes")))
        out["auto_plan"] = .bool(flag(s["auto_plan"], default: "1"))
        out["auto_tests"] = .bool(flag(s["auto_tests"], default: "1"))
        for (k, d) in [("subjects_per_day", 2), ("parts_lecture", 1), ("parts_exercise", 1), ("tests_per_subject", 1),
                       ("test_minutes", 45), ("break_minutes", 15)] {
            out[k] = .number(Double(try lenientInt(s[k], default: d, key: k)))
        }
        out["exam_priority"] = .bool(flag(s["exam_priority"], default: "1"))
        out["auto_suggest"] = .bool(flag(s["auto_suggest"], default: "1"))
        // int(hours * 60): schneidet ab; nan/inf scheitern in Python
        let minutes = hours * 60
        guard minutes.isFinite, abs(minutes) < 9e15 else {
            throw LocalHTTPError(status: 500, message: "Einstellung hours_per_day ist keine endliche Zahl")
        }
        out["minutes_per_day"] = .number(Double(Int(minutes)))
        out["learn_days"] = .array(try (0..<7).filter { !(try contains(freeDays, $0)) }.map { .number(Double($0)) })
        for (k, d) in [("travel_minutes", 30), ("min_slot_minutes", 30)] {
            out[k] = .number(Double(try lenientInt(s[k], default: d, key: k)))
        }
        out["learn_start"] = raw(s["learn_start"], default: "08:00")
        out["learn_end"] = raw(s["learn_end"], default: "21:00")
        // json.loads mit Rueckfall [] bei kaputtem JSON (aber nicht bei NULL: TypeError wie in Python)
        if let v = s["blocked_times"] {
            guard let text = v.string else { throw typeError("blocked_times") }
            out["blocked_times"] = (try? PyJSON.parse(text))?.json ?? .array([])
        } else {
            out["blocked_times"] = .array([])
        }
        out["pen_input"] = raw(s["pen_input"], default: "all")
        return out
    }

    /// `_public_settings`: ohne die PIN des PC-Servers
    public static func publicSettings(_ s: [String: JSONValue]) -> [String: JSONValue] {
        var p = s
        p["lan_pin"] = nil
        return p
    }

    /// `set_setting(conn, key, value)`: Listen und Objekte als `json.dumps`, Wahrheitswerte als "1"/"0", sonst `str(value)`.
    public static func write(_ c: SQLiteConnection, key: String, value: PyJSON) throws {
        try c.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      [.text(key), .text(text(of: value))])
    }

    /// Der Text, den `set_setting` speichert
    public static func text(of value: PyJSON) -> String {
        switch value {
        case .array, .object: return value.dumps
        case .bool(let b): return b ? "1" : "0"
        case .null: return "None"                                  // str(None)
        case .int(let digits): return digits
        case .float(let d): return PyJSON.repr(d)
        case .string(let s): return s
        }
    }

    // MARK: Python-Umwandlungen

    private static func typeError(_ key: String) -> LocalHTTPError {
        LocalHTTPError(status: 500, message: "Einstellung \(key) hat einen ungültigen Typ")
    }

    private static func valueError(_ key: String) -> LocalHTTPError {
        LocalHTTPError(status: 500, message: "Einstellung \(key) ist keine gültige Zahl")
    }

    /// `float(s.get(key, default))`
    private static func float(_ v: SQLiteValue?, default d: Double, key: String) throws -> Double {
        guard let v else { return d }
        switch v {
        case .text(let t):
            guard let f = PyConvert.float(t) else { throw valueError(key) }
            return f
        case .integer(let i): return Double(i)
        case .real(let r): return r
        case .null, .blob: throw typeError(key)
        }
    }

    /// `int(s.get(key, default))` ohne Rueckfall (test_default_minutes)
    private static func strictInt(_ v: SQLiteValue?, default d: Int, key: String) throws -> Int {
        guard let v else { return d }
        switch v {
        case .text(let t):
            guard let i = PyConvert.int(t) else { throw valueError(key) }
            return i
        case .integer(let i): return Int(i)
        case .real(let r):
            guard r.isFinite else { throw valueError(key) }
            return Int(r)
        case .null, .blob: throw typeError(key)
        }
    }

    /// `try: int(...) except ValueError: default` – NULL bleibt ein TypeError wie in Python
    private static func lenientInt(_ v: SQLiteValue?, default d: Int, key: String) throws -> Int {
        do { return try strictInt(v, default: d, key: key) } catch let e as LocalHTTPError where e == valueError(key) { return d }
    }

    /// `s.get(key, default) == "1"`
    private static func flag(_ v: SQLiteValue?, default d: String) -> Bool {
        guard let v else { return d == "1" }
        return v.string == "1"
    }

    private static func raw(_ v: SQLiteValue?, default d: String) -> JSONValue {
        guard let v else { return .string(d) }
        return v.json ?? .null
    }

    /// `json.loads(s.get(key, default))`; kaputtes JSON scheitert wie in Python
    private static func loads(_ v: SQLiteValue?, default d: String, key: String) throws -> JSONValue {
        let text: String
        if let v {
            guard let t = v.string else { throw typeError(key) }
            text = t
        } else {
            text = d
        }
        do { return try PyJSON.parse(text).json } catch { throw LocalHTTPError(status: 500, message: "Einstellung \(key) ist kein gültiges JSON") }
    }

    /// `day in free_days`: Liste wie in Python (True == 1), Objekt prueft Schluessel (Text, also nie), sonst TypeError
    private static func contains(_ container: JSONValue, _ day: Int) throws -> Bool {
        switch container {
        case .array(let items):
            return items.contains { item in
                switch item {
                case .number(let n): return n == Double(day)
                case .bool(let b): return (b ? 1 : 0) == day
                default: return false
                }
            }
        case .object: return false
        default: throw typeError("free_days")
        }
    }
}

/// `GET/PUT /api/settings` wie app/server.py: alle Schluessel erlaubt (wie dort), Antwort ohne `lan_pin`.
public enum SettingsEndpoints: LocalEndpointModule {
    public static let name = "Einstellungen"

    public static func register(on router: LocalRouter) {
        router.get("/api/settings") { _, ctx in
            let s = try await ctx.database.withConnection { try LocalSettings.read($0) }
            return .json(.object(LocalSettings.publicSettings(s)))
        }

        router.put("/api/settings") { req, ctx in
            let members = try req.pythonObjectBody()
            let s = try await ctx.database.transaction { c -> [String: JSONValue] in
                for m in members { try LocalSettings.write(c, key: m.key, value: m.value) }
                return try LocalSettings.read(c)
            }
            return .json(.object(LocalSettings.publicSettings(s)))
        }
    }
}
