import Foundation

// Platzhalter bis zur Portierung (docs/IPAD-OHNE-PC.md, Abschnitt 5): Jeder Pfad, den die App aufruft, bekommt eine
// gueltige Antwort in der Form von app/server.py, wie sie der PC-Server bei leerer Datenbank gibt (leere Listen,
// leere Objekte mit denselben Feldern, Datumsangaben aus der Uhr). Viele Seiten laden mehrere Pfade gemeinsam
// (async let) – ein einziger Fehler liesse die ganze Seite scheitern.
//
// Regeln:
// - Lesen: leere Antwort in Server-Form; einzelne Eintraege nach ID gibt es noch nicht -> 404 wie auf dem PC.
// - Aendern/Loeschen vorhandener Eintraege: Antwort wie der PC-Server, wenn es den Eintrag nicht gibt.
// - Anlegen: 409 mit klarer Meldung, bis die Funktion portiert ist (nichts wird vorgetaeuscht).
// - Ein echter Endpunkt mit demselben Pfad ersetzt den Platzhalter (LocalRoute.placeholder), ohne ihn zu aendern.

enum LocalPending {
    /// `_bg_state` ohne laufende Hintergrundaufgabe (auf dem Geraet gibt es keine)
    static let bg: JSONValue = ["running": false, "task": .null, "message": ""]

    /// Anlegen geht noch nicht: 409 mit Meldung
    static func notYet(_ what: String) -> LocalHTTPError {
        LocalHTTPError(status: 409, message: "\(what) geht auf diesem iPad noch nicht.")
    }

    static func settings(_ ctx: LocalContext) async throws -> [String: JSONValue] {
        try await ctx.database.withConnection { try LocalSettings.read($0) }
    }

    /// Datum aus der Query wie `date.fromisoformat` (Python antwortet bei falschem Datum mit 500, hier 422)
    static func day(_ req: LocalRequest, _ name: String) throws -> Int {
        let text = try req.requiredQuery(name)
        guard let d = BerlinClock.parseISODate(text) else {
            throw LocalHTTPError(status: 422, message: "Ungültiges Datum: \(text)")
        }
        return d
    }

    static func iso(_ day: Int) -> String { BerlinClock.isoDate(day) }

    static func today(_ ctx: LocalContext) -> Int { BerlinClock.parseISODate(ctx.clock.today) ?? 0 }

    static func weekday(_ day: Int) -> Int { BerlinClock.weekday(day) }

    /// Tag ohne Lernpakete: "frei" an freien Tagen, sonst "leer" (study.calendar)
    static func emptyStatus(_ day: Int, settings s: [String: JSONValue]) -> String {
        let learn = (s["learn_days"]?.array ?? []).compactMap(\.int)
        return learn.contains(weekday(day)) ? "leer" : "frei"
    }

    /// Ein Tag aus `study.calendar` ohne Pakete und Termine
    static func calendarDay(_ day: Int, settings s: [String: JSONValue]) -> JSONValue {
        ["date": .string(iso(day)), "weekday": .number(Double(weekday(day))), "status": .string(emptyStatus(day, settings: s)),
         "minutes": 0, "tasks_done": 0, "tasks_total": 0, "packages": [], "events": []]
    }

    /// Leerer Rumpf von `GET /api/files/{id}/annotations`, wenn es noch keine Notizen gibt
    static let emptyAnnotations: JSONValue = ["data": ["version": 2, "pages": [:], "zoom": 1.2], "updated_at": .null, "version": 0]
}
