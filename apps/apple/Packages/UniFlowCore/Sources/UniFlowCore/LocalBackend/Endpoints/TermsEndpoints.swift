import Foundation

/// Semester wie `timetable.term` und `PUT /api/terms` in app/server.py.
public enum LocalTerms {
    /// Ohne aktives Semester dieselben festen Werte wie Python
    public static let fallback: JSONValue = ["name": "Semester", "start": "2026-10-12", "end": "2027-01-30"]

    /// `timetable.term(conn)`: das zuletzt angelegte aktive Semester
    public static func current(_ c: SQLiteConnection) throws -> JSONValue {
        guard let r = try c.queryOne("SELECT * FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1") else { return fallback }
        return .object(r.json)
    }

    /// Wert zum Binden wie Pythons sqlite3 (Listen und Objekte gehen dort nicht: InterfaceError)
    static func bindable(_ v: PyJSON, field: String) throws -> SQLiteValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .integer(b ? 1 : 0)
        case .int(let digits):
            guard let i = Int64(digits) else { throw LocalHTTPError(status: 422, message: "\(field): Zahl zu groß") }
            return .integer(i)
        case .float(let d): return .real(d)
        case .string(let s): return .text(s)
        case .array, .object: throw LocalHTTPError(status: 422, message: "\(field): Text erwartet")
        }
    }

    /// Wahrheitswert wie in Python (`body.get("name") or "Semester"`)
    static func truthy(_ v: PyJSON?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .int(let d)?: return d != "0"
        case .float(let f)?: return f != 0
        case .string(let s)?: return !s.isEmpty
        case .array(let a)?: return !a.isEmpty
        case .object(let o)?: return !o.isEmpty
        }
    }
}

extension LocalTerms {
    /// Beginn und Ende eines neuen Semesters (Pruefbericht 569): Datum in der Form JJJJ-MM-TT, Ende nicht vor dem
    /// Beginn. Python speichert jeden Wert; der Stundenplan vergleicht die Texte (`date_from`/`date_to` der Serien
    /// fallen auf das Semester zurueck): mit vertauschten Daten oder einem Text wie "kaputt" verschwanden alle Serien
    /// ohne eigene Daten aus dem Stundenplan (Woche leer, ohne Hinweis). Hier 422 mit Meldung, das bisherige Semester
    /// bleibt aktiv.
    static func checkRange(start: SQLiteValue, end: SQLiteValue) throws {
        func day(_ v: SQLiteValue, _ what: String) throws -> Int {
            guard let s = v.string, let d = BerlinClock.parseISODate(s), BerlinClock.isoDate(d) == s else {
                throw LocalHTTPError(status: 422, message: "\(what) des Semesters ist kein gültiges Datum (JJJJ-MM-TT).")
            }
            return d
        }
        let s = try day(start, "Beginn"), e = try day(end, "Ende")
        guard e >= s else { throw LocalHTTPError(status: 422, message: "Das Ende des Semesters liegt vor seinem Beginn.") }
    }
}

/// `GET/PUT /api/terms`. PUT legt ein neues aktives Semester an (die alten werden inaktiv), wie auf dem PC.
/// Abweichungen: Fehlen `start` oder `end`, antwortet Python mit 500 (KeyError); hier 422 mit Meldung. Ungueltige
/// Daten oder ein Ende vor dem Beginn speichert Python, hier 422 (`LocalTerms.checkRange`).
public enum TermsEndpoints: LocalEndpointModule {
    public static let name = "Semester"

    public static func register(on router: LocalRouter) {
        router.get("/api/terms") { _, ctx in
            .json(try await ctx.database.withConnection { try LocalTerms.current($0) })
        }

        router.put("/api/terms") { req, ctx in
            let members = try req.pythonObjectBody()
            func field(_ k: String) -> PyJSON? { members.last { $0.key == k }?.value }
            guard let start = field("start") else { throw LocalHTTPError(status: 422, message: "Beginn des Semesters fehlt (start)") }
            guard let end = field("end") else { throw LocalHTTPError(status: 422, message: "Ende des Semesters fehlt (end)") }
            let nameValue = field("name")
            let name: SQLiteValue = LocalTerms.truthy(nameValue) ? try LocalTerms.bindable(nameValue ?? .null, field: "name") : .text("Semester")
            let s = try LocalTerms.bindable(start, field: "start")
            let e = try LocalTerms.bindable(end, field: "end")
            try LocalTerms.checkRange(start: s, end: e)
            let term = try await ctx.database.transaction { c -> JSONValue in
                try c.execute("UPDATE terms SET active=0")
                try c.execute("INSERT INTO terms(name, start, end, active) VALUES (?,?,?,1)", [name, s, e])
                return try LocalTerms.current(c)
            }
            return .json(term)
        }
    }
}
