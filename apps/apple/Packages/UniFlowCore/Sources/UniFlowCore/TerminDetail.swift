import Foundation

// Termin-Detail (06.11.2026, Auftrag des Inhabers): Stundenplan oder Lernkalender -> Termin antippen -> Raum (Antippen
// startet die Route zu Fuss in Google Maps) und alle Lehrenden des Kurses (Antippen der E-Mail -> neue Uni-Mail).
// Regeln ohne Oberflaeche, gleich in app/static/termin-detail-logic.js (Web, Windows); gemeinsame Faelle in
// packages/shared-contracts/fixtures/termin-detail/cases.json. Daten: GET /api/rooms/resolve (`LocalRooms`) und
// GET /api/lecturers?course_id= (`StudIPLecturers`). Lehrende nur an der LUH (Stud.IP), Raumfinder-Route nur an der LUH.

public enum TerminDetail {

    /// Was das Antippen eines Raums tut
    public enum RouteAction: Equatable, Sendable {
        /// Route zu Fuss sofort oeffnen (Google-Maps-App bzw. Webadresse)
        case route(String)
        /// nicht eindeutig aufgeloest: Raumfinder mit vorbelegter Suche
        case search(String)
        /// Online-Termin: kein Ort
        case none
    }

    /// Was das Antippen einer E-Mail-Adresse tut
    public enum MailChoice: String, Sendable {
        /// neue E-Mail in Uni-Mail (SOGo, vom Uni-Postfach), gesendet erst mit "Senden"
        case compose
        /// Uni-Mail gibt es hier, ist aber nicht verbunden: zuerst "Uni-Mail verbinden" anbieten (sonst mailto:)
        case connect
        /// keine Uni-Mail: Mail-App des Geraets
        case mailto
        /// keine Adresse: "Nachricht in Stud.IP"
        case studip
    }

    /// Stand von Uni-Mail fuer `mailChoice`
    public enum UniMailState: String, Sendable { case connected, disconnected, none }

    /// Ein Raum eines Termins: Text und ob er zum Raumfinder fuehrt (nicht nur "Online")
    public struct Room: Equatable, Sendable {
        public let text: String
        public let link: Bool
        public init(text: String, link: Bool) { self.text = text; self.link = link }
    }

    /// Raeume eines Termins ("1101 - F102 · Online" -> zwei); Teile wie `Rooms.segments`, hoechstens vier
    public static func rooms(_ text: String?) -> [Room] {
        Rooms.segments(text).map { Room(text: $0, link: Rooms.mayLink($0)) }
    }

    /// Antippen eines Raums nach GET /api/rooms/resolve (ein Teil): gefunden (Raum oder Gebaeude) -> Route zu Fuss,
    /// sonst Raumfinder mit dem Text; nur https bzw. comgooglemaps
    public static func route(_ part: JSONValue, appInstalled: Bool) -> RouteAction {
        let status = part["status"]?.string ?? ""
        if status == "online" { return .none }
        let text = part["text"]?.string ?? ""
        if ["found", "building"].contains(status) {
            let key = appInstalled ? "google_app_route" : "google_route"
            let url = part["maps"]?[key]?.string ?? (appInstalled ? part["maps"]?["google_route"]?.string : nil)
            if let url, url.hasPrefix("https://") || url.hasPrefix("comgooglemaps://") { return .route(url) }
        }
        return .search(text)
    }

    /// Dozent/innen (auch mit zusaetzlicher Tutor-Rolle) und reine Tutor/innen, Reihenfolge wie geliefert
    public static func groups(_ people: [JSONValue]) -> (lecturers: [JSONValue], tutors: [JSONValue]) {
        let isLecturer: (JSONValue) -> Bool = { p in (p["roles"]?.array ?? []).contains { $0.string == "dozent" } }
        return (people.filter(isLecturer), people.filter { !isLecturer($0) })
    }

    /// "Allen Lehrenden schreiben": Adressen der Dozent/innen, ohne leere und doppelte
    public static func recipients(_ people: [JSONValue]) -> [String] {
        var out: [String] = []
        for p in groups(people).lecturers {
            let e = PyText.strip(p["email"]?.string ?? "")
            if !e.isEmpty, !out.contains(where: { PyText.lower($0) == PyText.lower(e) }) { out.append(e) }
        }
        return out
    }

    /// Betreff: "Frage zu <Kurs>"
    public static func subject(_ title: String?) -> String {
        let t = PyText.strip(title ?? "")
        return t.isEmpty ? "" : "Frage zu \(t)"
    }

    /// mailto: mit allen Empfaengern und Betreff (Rueckweg ohne Uni-Mail); nil ohne Adresse
    public static func mailto(_ to: [String], subject: String) -> String? {
        let list = to.map { PyText.strip($0) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { return nil }
        let s = PyText.strip(subject)
        return "mailto:" + list.joined(separator: ",") + (s.isEmpty ? "" : "?subject=" + PyText.quote(s, safe: ""))
    }

    public static func mailChoice(_ to: [String], uniMail: UniMailState) -> MailChoice {
        guard to.contains(where: { !PyText.strip($0).isEmpty }) else { return .studip }
        switch uniMail {
        case .connected: return .compose
        case .disconnected: return .connect
        case .none: return .mailto
        }
    }

    /// Abfrage fuer GET /api/lecturers: der Stud.IP-Kurs des Termins, sonst sein Modul; nil ohne beides
    public static func lecturersQuery(_ e: JSONValue) -> String? {
        if let c = e["course_id"]?.string, !PyText.strip(c).isEmpty { return "course_id=" + PyText.quote(c, safe: "") }
        if let m = e["module_id"]?.int { return "module_id=\(m)" }
        return nil
    }

    /// Lehrende im Termin nur an der LUH (Stud.IP); HsH und Hildesheim vorerst nicht
    public static func showsLecturers(university: String?) -> Bool { university == "luh" }
}
