import Foundation

/// Ausfaelle laut Stud.IP in der Anzeige ausblenden, wie Stud.IP selbst (Entscheidung des Inhabers, 28.10.2026: in der
/// Weihnachtswoche markiert Stud.IP 13 Veranstaltungen als ausgefallen, der Stud.IP-Kalender zeigt dann nichts, UniFlow
/// zeigte sie durchgestrichen). Nur auf dem Geraet und nur fuer die Anzeige: die Antworten von `occurrences` bleiben wie
/// in Python (`status` "ausfall", Vertraege woche.json und timetable-logic.json); die App holt die Ausfaelle laut
/// Stud.IP eines Zeitraums ueber `GET /api/timetable/studip-cancelled` und laesst genau diese Vorkommen weg.
///
/// Ausfall laut Stud.IP heisst: Ausnahme `cancelled` mit der Notiz, die der Abgleich setzt (`StudIPScheduleImport.note`,
/// `apply_import` mit Quelle studip*). Was der Nutzer selbst als ausgefallen oder nicht besucht markiert (Ausnahme ohne
/// diese Notiz, `attend=0`), bleibt sichtbar, damit er es zuruecknehmen kann. Setzt der Nutzer einen Ausfall laut Stud.IP
/// zurueck, wird daraus "attend" mit `resetNote` (`set_exception` wie Python seit a7827c6): der Termin ist dann kein
/// Ausfall mehr und bleibt sichtbar; der naechste Abgleich traegt den Ausfall nicht wieder ein, weil der Tag schon eine
/// Ausnahme hat. Belegte Zeit ist ein Ausfall ohnehin nicht
/// (`busy_blocks` zaehlt nur "teilnahme"), freie Fenster und Lernplan haben die Zeit also schon frei.
public enum StudIPCancellations {
    /// Notiz der Ausnahme, die der Stud.IP-Abgleich setzt (`STUDIP_CANCEL_NOTE`)
    public static let note = "Ausfall laut Stud.IP"
    /// Notiz, wenn der Nutzer einen Ausfall laut Stud.IP zuruecksetzt (`STUDIP_CANCEL_RESET_NOTE`, a7827c6): der Termin
    /// steht als "attend" da und bleibt sichtbar
    public static let resetNote = "Findet statt (Ausfall laut Stud.IP zurückgesetzt)"

    /// Ausfaelle laut Stud.IP mit Datum im Zeitraum (ISO-Tage, einschliesslich): `[{"event_id", "date"}]`
    static func list(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> JSONValue {
        let rows = try c.rows("""
            SELECT x.event_id, x.date FROM event_exceptions x JOIN course_events e ON e.id=x.event_id
            WHERE x.type='cancelled' AND x.note=? AND x.date>=? AND x.date<=? ORDER BY x.date, x.event_id
            """, [.text(note), .text(BerlinClock.isoDate(start)), .text(BerlinClock.isoDate(end))])
        return .array(rows.map { ["event_id": $0["event_id"] ?? .null, "date": $0["date"] ?? .null] })
    }

    /// Schluessel eines Vorkommens: Serie und Tag
    public static func key(eventID: Int, date: String) -> String { "\(eventID)|\(date)" }

    /// Schluessel aus der Antwort von `GET /api/timetable/studip-cancelled`
    public static func keys(_ list: JSONValue?) -> Set<String> {
        Set((list?.array ?? []).compactMap { r in
            guard let id = r["event_id"]?.int, let d = r["date"]?.string else { return nil }
            return key(eventID: id, date: d)
        })
    }

    /// Ausgefallen laut Stud.IP: Status "ausfall" mit Ausnahme "cancelled" an einem Tag aus `keys`
    public static func hides(_ occurrence: JSONValue, keys: Set<String>) -> Bool {
        guard occurrence["status"] == "ausfall", occurrence["exception"] == "cancelled",
              let id = occurrence["event_id"]?.int, let d = occurrence["date"]?.string else { return false }
        return keys.contains(key(eventID: id, date: d))
    }

    /// Vorkommen ohne die Ausfaelle laut Stud.IP
    public static func visible(_ events: [JSONValue], keys: Set<String>) -> [JSONValue] {
        keys.isEmpty ? events : events.filter { !hides($0, keys: keys) }
    }

    /// Antwort mit `days[].events` (Woche, Lernkalender) bzw. `events` (Tag) ohne die Ausfaelle laut Stud.IP; alles
    /// andere bleibt, wie es kam
    public static func hiding(in response: JSONValue, keys: Set<String>) -> JSONValue {
        guard !keys.isEmpty, var o = response.object else { return response }
        if let list = o["events"]?.array { o["events"] = .array(visible(list, keys: keys)) }
        if let days = o["days"]?.array {
            o["days"] = .array(days.map { d in
                guard var day = d.object, let list = day["events"]?.array else { return d }
                day["events"] = .array(visible(list, keys: keys))
                return .object(day)
            })
        }
        return .object(o)
    }
}
