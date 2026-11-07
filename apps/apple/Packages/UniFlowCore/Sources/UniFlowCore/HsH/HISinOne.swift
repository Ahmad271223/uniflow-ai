import Foundation

// Campusmanagement (HISinOne) der Hochschule Hannover, wie app/hisinone.py (docs/HSH-2026-11-05.md). Adressen und
// Tabellen am 05.11.2026 vom Koordinator mit der Anmeldung des Inhabers nur lesend angesehen (ohne persoenliche
// Daten); die Tests nutzen nachgebaute Seiten (packages/shared-contracts/fixtures/hsh, als NACHGEBAUT gekennzeichnet).
//
// - Anmeldung per SAML ("Anmelden mit SSO Hochschule Hannover"); angemeldet = Abmelden-Link (category=auth.logout).
//   Jede Seite traegt ein verstecktes Dialogfeld "Sitzung abgelaufen" mit Benutzerkennung/Passwort: das zaehlt nie.
// - Stundenplan: die Abo-Adresse steht schon im DOM (textarea ...:ical:cal_add); sie ist persoenlich (user+hash) und
//   wird wie ein Schluessel behandelt (nur Schluesselbund, nie in Meldungen oder Protokollen).
// - Leistungen: Baumtabelle mit 15 Spalten (jede Tabelle doppelt im HTML). Fakultaeten ohne HISinOne-Leistungen: das
//   alte QIS icms.hs-hannover.de im Iframe "Pruefungen und Studium" (gleiche HIS-QIS-Technik wie die LUH).
// - Pruefungen anmelden: nur lesen, welche angemeldet ("zugelassen") sind; nie an- oder abmelden.

public enum HISinOne {
    public static let host = UniversityProfile.hshCampus.host?.lowercased() ?? "campusmanagement.hs-hannover.de"
    static let pages = UniversityProfile.hshCampus.absoluteString + "/qisserver/pages"
    public static let timetableURL = URL(string: pages + "/plan/individualTimetable.xhtml?_flowId=individualTimetableSchedule-flow")!
    public static let gradesURL = URL(string: pages + "/sul/examAssessment/personExamsReadonly.xhtml?_flowId=examsOverviewForPerson-flow")!
    public static let examRegistrationURL = URL(string: pages + "/cm/exa/nominalactualcomparison/sollistvergleichBaum.xhtml?_flowId=sollistvergleich-flow")!
    public static let qisIframeURL = URL(string: pages + "/cs/sys/portal/hisinoneIframePage.faces?id=qis_meine_funktionen")!
    public static let exportPath = "/qisserver/pages/cm/exa/timetable/individualTimetableCalendarExport.faces"

    public static func isCampusURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return url.host?.lowercased() == host
    }

    private static let logoutRE = HText.regex("category=auth\\.logout", [.caseInsensitive])
    private static let loginHintRE = HText.regex("identityprovider/redirect/\\d+/login|Anmelden mit SSO|category=auth\\.login", [.caseInsensitive])

    /// Angemeldet: Seite von HISinOne mit Abmelden-Link; die Felder des versteckten Dialogs aendern daran nichts
    public static func isLoggedIn(html: String, url: URL?) -> Bool {
        guard isCampusURL(url) else { return false }
        return HText.match(logoutRE, html) != nil
    }

    /// Nicht angemeldet: kein Abmelden-Link, dafuer der SSO-Knopf oder das Anmeldeformular
    public static func isLoginPage(html: String) -> Bool {
        HText.match(logoutRE, html) == nil && HText.match(loginHintRE, html) != nil
    }

    // MARK: Fehlerseite des SSO (IdP)

    /// Eigene Anmeldeseite des Campusmanagements (Benutzerkennung/Passwort mit dem SSO-Account, ohne IdP): Ausweg,
    /// wenn der IdP auf die SAML-Anfrage von HISinOne nur seine Fehlerseite zeigt
    public static let ownLoginURL = UniversityProfile.hshCampusStart

    private static let idpErrorRE = HText.regex("TrackID", [.caseInsensitive])
    private static let idpErrorTextRE = HText.regex("Ein Fehler ist aufgetreten|An Error Occurred|class=\"error-(?:container|text)\"", [.caseInsensitive])

    /// Fehlerseite des SSO der HsH (SimpleSAMLphp, "SSO Login – Ein Fehler ist aufgetreten … TrackID: …"). Am 07.11.2026
    /// zeigte der IdP sie auf jede SAML-Anfrage des Campusmanagements, auch ohne App und ohne Cookies (fuer andere
    /// Dienste der HsH kam das Anmeldeformular): ein Fehler der Hochschule, kein falsches Passwort. Nie mit Passwortfeld.
    public static func isIdPErrorPage(html: String, url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == UniversityProfile.hshIdPHost,
              url.path.hasPrefix("/simplesaml/") else { return false }
        let h = html.lowercased()
        if h.contains("type=\"password\"") || h.contains("type='password'") { return false }
        return HText.match(idpErrorRE, html) != nil && HText.match(idpErrorTextRE, html) != nil
    }

    // MARK: Stundenplan-Abo

    private static let textareaRE = HText.regex("<textarea\\b[^>]*\\bid=\"[^\"]*ical[^\"]*\"[^>]*>([^<]*)</textarea>", [.caseInsensitive])

    /// Abo-Adresse des Stundenplans: nur HISinOne-Rechner, Pfad des Exports, mit user und hash
    public static func isExportURL(_ url: URL?) -> Bool {
        guard let url, isCampusURL(url), url.path == exportPath, let q = url.query else { return false }
        return q.contains("user=") && q.contains("hash=")
    }

    /// Abo-Adresse aus der Stundenplan-Seite (textarea des Popups "Daten für iCalendar (ics) exportieren"); nil ohne
    public static func icalLink(html: String) -> URL? {
        for g in HText.allMatches(textareaRE, html) {
            let raw = QISParser.decodeEntities(g).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: raw), isExportURL(url) { return url }
        }
        return nil
    }

    /// Serien aus dem iCal-Export (Titel wie exportiert, Bemerkung aus DESCRIPTION)
    public static func planEntries(ics: String) -> [LSFCalendar.Entry] {
        LSFCalendar.parseICS(ics).map { e in
            var e = e
            e.note = LSFCalendar.noteText(e.description)
            return e
        }
    }

    // MARK: Leistungen

    /// HISinOne-Spaltennamen -> Namen, die `GradeRows` kennt (wie `_HEADER_ALIASES` in app/hisinone.py)
    static let headerAliases: [String: String] = [
        "titel": "Text", "freigabedatum": "Datum", "nummer": "Nr.", "prüfungsnummer": "Prüfungsnr.", "ects-punkte": "ECTS",
        "leistungspunkte": "Credits", "lp": "Credits", "cp": "Credits", "bewertung": "Note", "prüfungsstatus": "Status",
        "anerkannt": "Vermerk", "termin": "Semester",
    ]
    private static let levelRE = HText.regex("^\\d+(?:\\.\\d+)*$")

    /// Leistungen der Leistungsuebersicht wie `hisinone.parse_grades`: Baumtabelle (Ebene, Titel, Nummer, Versuch,
    /// Ruecktritt, Note, Bonus, Malus, Status, ...), Bonus = Leistungspunkte, Abschluss = Titel der obersten Ebene;
    /// jede Leistung einmal (Tabellen stehen doppelt), Tabellen mit Stammdaten nie
    public static func grades(html: String) -> [QISGrade] {
        let scan = HTMLScanner.scan(html)
        var out: [QISGrade] = []
        var seen = Set<String>()
        for table in scan.tables where !QISParser.isStammdaten(table) {
            var header: [String]?
            var abschluss = ""
            for row in table.rows.map({ $0.map(\.text) }) {
                let low = row.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if low.contains("note"), low.contains(where: { $0 == "titel" || $0 == "text" || $0 == "bezeichnung" }) {
                    header = row.map { headerAliases[$0.trimmingCharacters(in: .whitespaces).lowercased()] ?? $0 }
                    continue
                }
                guard let header else { continue }
                let level = row.first?.trimmingCharacters(in: .whitespaces) ?? ""
                if HText.match(levelRE, level) != nil, !level.contains("."), row.count > 1, !row[1].isEmpty {
                    abschluss = String(row[1].prefix(160))
                }
                for g in GradeRows.parse(rows: [header, row], abschluss: abschluss) {
                    let key = [g.pruefungsnr ?? "", g.text, g.semester ?? "", g.versuch ?? "", g.note ?? "", g.status ?? ""].joined(separator: "\u{1}")
                    if seen.insert(key).inserted { out.append(g) }
                }
            }
        }
        return out
    }

    // MARK: Pruefungen anmelden (nur lesen)

    public struct ExamRow: Sendable, Equatable {
        public enum State: String, Sendable { case registered = "angemeldet", open = "offen", unknown = "unbekannt" }
        public let number: String
        public let title: String
        public let hint: String
        public let state: State
    }

    private static let trRE = HText.regex("<tr\\b[^>]*>(.*?)</tr>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let tagRE = HText.regex("<[^>]+>")
    private static let attrRE = HText.regex("(?:alt|title)=\"([^\"]*)\"", [.caseInsensitive])
    private static let examRE = HText.regex("\\b(\\d{4,8})\\s+(.+?)(?:\\s+-\\s+(.+?))?\\s*$")

    /// Zeilen der Seite "Pruefungen anmelden" (sollistvergleichBaum) wie `hisinone.exam_registrations`
    public static func examRows(html: String) -> [ExamRow] {
        var out: [ExamRow] = []
        var seen = Set<String>()
        for inner in HText.allMatches(trRE, html) {
            guard inner.lowercased().contains("<td") else { continue }
            var text = HText.collapse(QISParser.decodeEntities(HText.replace(tagRE, in: inner, with: " ")))
            if let r = text.range(of: " Detailansicht") { text = String(text[..<r.lowerBound]) }
            guard let e = HText.match(examRE, text), let number = e.groups[1] ?? nil, let title = e.groups[2] ?? nil else { continue }
            let hint = (e.groups[3] ?? nil) ?? ""
            let actions = HText.allMatches(attrRE, inner).joined(separator: " ").lowercased()
            let state: ExamRow.State
            if actions.contains("abmelden") || hint.lowercased().contains("zugelassen") || hint.lowercased().contains("angemeldet") {
                state = .registered
            } else if actions.contains("anmelden") {
                state = .open
            } else {
                state = .unknown
            }
            if seen.insert(number).inserted {
                out.append(ExamRow(number: number, title: title.trimmingCharacters(in: .whitespaces), hint: hint, state: state))
            }
        }
        return out
    }

    // MARK: Altes QIS im Iframe

    private static let iframeRE = HText.regex("<iframe\\b[^>]*\\bsrc=\"([^\"]+)\"", [.caseInsensitive])

    /// Adresse des alten QIS im Iframe "Pruefungen und Studium" (nur auf dem HISinOne-Rechner; leitet per SSO weiter)
    public static func iframeSource(html: String) -> URL? {
        guard let raw = HText.match(iframeRE, html)?.groups[1] ?? nil else { return nil }
        let s = QISParser.decodeEntities(raw)
        let url = s.hasPrefix("/") ? URL(string: UniversityProfile.hshCampus.absoluteString + s) : URL(string: s)
        return isCampusURL(url) ? url : nil
    }
}

/// Campusmanagement der HsH mit der angemeldeten Sitzung (Cookies setzt der Transport): Stundenplan, Leistungen,
/// angemeldete Pruefungen. Nur lesend. `savedICal`: gemerkte Abo-Adresse (Schluesselbund); der Stundenplan kommt
/// damit auch ohne gueltige Sitzung. Eine neu gefundene Abo-Adresse liefert `foundICal` (die App legt sie ab).
public actor HISinOneClient: UniCampusClient {
    private let transport: UniTransport
    private let retry: UniRetry
    private let savedICal: URL?
    public private(set) var foundICal: URL?
    static let source = "Campusmanagement"

    public init(transport: UniTransport, retry: UniRetry = UniRetry(), savedICal: URL? = nil) {
        self.transport = transport
        self.retry = retry
        self.savedICal = HISinOne.isExportURL(savedICal) ? savedICal : nil
    }

    private func page(_ url: URL) async throws -> String {
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        let final = resp.finalURL ?? url
        if !HISinOne.isCampusURL(final) { throw HildesheimError.sessionExpired(Self.source) }   // IdP-Anmeldung
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: url.absoluteString) }
        guard HISinOne.isLoggedIn(html: resp.text, url: final) else { throw HildesheimError.sessionExpired(Self.source) }
        return resp.text
    }

    /// Seite lesen (fuer Erweiterungen wie den Studienservice)
    func campusPage(_ url: URL) async throws -> String { try await page(url) }

    /// Lesendes Absenden eines JSF-Formulars (Reiterwechsel), genau ein Versuch; danach dieselben Pruefungen wie `page`
    func campusPost(_ url: URL, _ fields: [(String, String)]) async throws -> String {
        let req = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: HText.form(fields))
        let resp = try await transport.fetch(req, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
        let final = resp.finalURL ?? url
        if !HISinOne.isCampusURL(final) { throw HildesheimError.sessionExpired(Self.source) }
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: url.absoluteString) }
        guard HISinOne.isLoggedIn(html: resp.text, url: final) else { throw HildesheimError.sessionExpired(Self.source) }
        return resp.text
    }

    private func ics(_ url: URL) async throws -> [LSFCalendar.Entry] {
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        let text = resp.text
        guard resp.status == 200, text.contains("BEGIN:VCALENDAR") else { throw HildesheimError.badResponse("Stundenplan-Abo") }
        let entries = HISinOne.planEntries(ics: text)
        // ein Kalender ohne Termin bei vorhandenem Export: unvollstaendig, nichts uebernehmen (keine Serie entfernen)
        guard !entries.isEmpty else { throw HildesheimError.badResponse("Stundenplan-Abo ohne Termine") }
        return entries
    }

    /// Serien des Stundenplans: mit Sitzung ueber die Stundenplan-Seite (Abo-Adresse), sonst ueber die gemerkte
    public func planEntries() async throws -> [LSFCalendar.Entry]? {
        do {
            let html = try await page(HISinOne.timetableURL)
            guard let link = HISinOne.icalLink(html: html) else { return nil }
            foundICal = link
            return try await ics(link)
        } catch HildesheimError.sessionExpired(let s) {
            guard let savedICal else { throw HildesheimError.sessionExpired(s) }
            return try await ics(savedICal)
        }
    }

    /// Leistungen aus HISinOne; ist die Leistungsuebersicht leer, der Notenspiegel im alten QIS (`QISClient`)
    public func grades() async throws -> [QISGrade] {
        let g = HISinOne.grades(html: try await page(HISinOne.gradesURL))
        if !g.isEmpty { return g }
        guard let start = try await icmsStart() else { return [] }
        do {
            return try await QISClient(transport: transport, retry: retry, start: start).fetch().grades
        } catch QISError.notenspiegelNotFound {
            return []
        } catch QISError.sessionExpired {
            throw HildesheimError.sessionExpired(Self.source)
        }
    }

    private func icmsStart() async throws -> URL? {
        HISinOne.iframeSource(html: try await page(HISinOne.qisIframeURL))
    }

    /// Angemeldete Pruefungen: HISinOne ("Pruefungen anmelden", Zeilen mit zugelassen/abmelden) und das alte QIS
    /// ("Info über angemeldete Prüfungen"). Meldet nie an oder ab.
    public func registrations() async throws -> [QISRegistration] {
        var rows = HISinOne.examRows(html: try await page(HISinOne.examRegistrationURL))
            .filter { $0.state == .registered }
            .map { QISRegistration(pruefungsnr: $0.number, text: $0.title, status: "angemeldet", raw: $0.hint) }
        if let start = try? await icmsStart(),
           let r = try? await QISRegistrationClient(transport: transport, retry: retry, start: start, layout: .hisinone).fetch() {
            rows += r.registrations
        }
        return rows
    }
}
