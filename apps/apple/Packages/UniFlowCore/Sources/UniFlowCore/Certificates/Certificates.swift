import Foundation

// Bescheinigungen aus den Hochschulportalen (Auftrag des Inhabers 06.11.2026: "Immatrikulationsbescheinigung sehen,
// alle deren Noten, alles komplett, deren Bescheinigungen die es noch so gibt"), docs/BESCHEINIGUNGEN-2026-11-06.md.
//
// Dieselben Regeln wie app/certificates.py (gemeinsame Faelle: packages/shared-contracts/fixtures/certificates,
// tools/gen-certificates-fixture.py):
// - Art eines Dokuments aus dem Titel (`CertificateText.kinds`): Immatrikulations-/Studienbescheinigung, BAfoeG (§ 9),
//   Datenkontrollblatt, Notenspiegel/Leistungsuebersicht, Rueckmeldebescheinigung, Bescheide, Weitere. Ein Titel kann
//   mehrere Arten abdecken (LUH: "Studienzeit- / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG").
// - Semester aus dem Titel ("WiSe 2026/27", "SoSe 2026").
// - Angebote einer QIS/LSF-Seite (`CertificateParser.qisOffers`): Links mit state=verpublish oder auf eine .pdf, Adresse
//   ohne asi/jsessionid (darf gespeichert werden). Ein verpublish-Aufruf ERZEUGT im QIS ein Dokument: die Liste liest
//   nur die Links, aufgerufen wird ein Link erst, wenn der Mensch "Herunterladen" tippt.
// - Angebote der HISinOne-Seite "Bescheide und Bescheinigungen" (`CertificateParser.hisinoneOffers`): Tabellenzeilen
//   mit einem PDF-/Drucken-Link oder -Knopf, dazu eine Semesterauswahl (select), falls die Seite eine hat. Der Aufbau ist
//   an der HsH noch nicht mit einem Konto mit Bescheiden gesehen worden (Liste war leer): `confirmed` = false.
// Gespeichert wird die Liste als JSON in `settings` (Schluessel `certificates`), die PDFs unter `qis/` im Datenordner
// des Containers mit dem Datum des Abrufs ("Stand").

/// Art einer Bescheinigung (Reihenfolge = Reihenfolge der Anzeige)
public enum CertificateKind: String, Codable, CaseIterable, Sendable {
    case immatrikulation
    case bafoeg
    case datenkontrollblatt
    case notenspiegel
    case rueckmeldung
    case bescheid
    case sonstige

    public var label: String {
        switch self {
        case .immatrikulation: return "Immatrikulations- / Studienbescheinigung"
        case .bafoeg: return "BAföG-Bescheinigung (§ 9)"
        case .datenkontrollblatt: return "Datenkontrollblatt"
        case .notenspiegel: return "Notenspiegel / Leistungsübersicht (PDF)"
        case .rueckmeldung: return "Rückmeldebescheinigung"
        case .bescheid: return "Bescheide und Zahlungsnachweise"
        case .sonstige: return "Weitere Dokumente"
        }
    }

    /// Diese Arten bieten Hochschulportale ueblicherweise an; fehlt eine, sagt die Seite es ehrlich
    public static let standard: [CertificateKind] = [.immatrikulation, .bafoeg, .datenkontrollblatt, .notenspiegel, .rueckmeldung]

    /// Erkennung: zuerst die eindeutigen Woerter (Reihenfolge wie `KIND_RULES` in app/certificates.py)
    static let rules: [(CertificateKind, [String])] = [
        (.datenkontrollblatt, ["datenkontrollblatt"]),
        (.rueckmeldung, ["rückmeldebescheinigung", "rueckmeldebescheinigung", "rückmeldung", "rueckmeldung"]),
        (.immatrikulation, ["immatrikulation", "studienbescheinigung", "studienzeit", "studierendenbescheinigung",
                            "semesterbescheinigung", "enrolment", "enrollment", "certificate of study"]),
        (.bafoeg, ["bafög", "bafoeg", "§ 9", "§9"]),
        (.notenspiegel, ["notenspiegel", "leistungsübersicht", "leistungsuebersicht", "leistungsspiegel", "notenübersicht",
                         "transcript", "leistungsnachweis", "leistungen"]),
        (.bescheid, ["bescheid", "gebühr", "beitrag", "zahlung", "payment"]),
    ]
}

/// Wahl eines Semesters, wenn das Portal eine Auswahl anbietet (HISinOne: select)
public struct CertificateSemester: Codable, Sendable, Equatable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// Ein Dokument, das das Portal anbietet. `address` (QIS) ist ohne Sitzungsparameter; zum Herunterladen wird die
/// Seite mit dem Link neu gelesen (frischer asi) und genau dieser Link einmal aufgerufen.
public struct CertificateOffer: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var kind: CertificateKind
    /// alle abgedeckten Arten (erste = `kind`)
    public var kinds: [CertificateKind]
    public var semester: String?
    public var semesters: [CertificateSemester]
    /// "bescheinigungen" (Menue), "notenspiegel" (Notenspiegel-Seiten), "studienservice" (HISinOne)
    public var source: String
    /// "qis" (HIS QIS/LSF, auch das alte QIS der HsH) oder "hisinone"
    public var portal: String
    public var address: String?
    /// Aufbau an echten Seiten gesehen (LUH); sonst aus Strukturnotizen und HIS-Standard nachgebaut
    public var confirmed: Bool

    public init(id: String, title: String, kind: CertificateKind, kinds: [CertificateKind], semester: String?,
                semesters: [CertificateSemester] = [], source: String, portal: String, address: String?, confirmed: Bool) {
        self.id = id
        self.title = title
        self.kind = kind
        self.kinds = kinds
        self.semester = semester
        self.semesters = semesters
        self.source = source
        self.portal = portal
        self.address = address
        self.confirmed = confirmed
    }
}

// MARK: - Text

public enum CertificateText {
    private static let tagRE = HText.regex("<[^>]+>")
    private static let pdfPrefixRE = HText.regex("^pdf\\s*-?\\s*", [.caseInsensitive])
    private static let actionSuffixRE = HText.regex("\\s*(zum drucken|anzeigen|drucken|herunterladen|öffnen|pdf)\\s*$", [.caseInsensitive])
    private static let trailRE = HText.regex("[\\s–\\-:|]+$")
    private static let winterRE = HText.regex("(?<!ab )(?<!seit )\\b(?:wintersemester|wise|ws)\\s*(\\d{4}|\\d{2})\\s*/\\s*(\\d{4}|\\d{2})\\b", [.caseInsensitive])
    private static let summerRE = HText.regex("(?<!ab )(?<!seit )\\b(?:sommersemester|sose|ss)\\s*(\\d{4}|\\d{2})\\b", [.caseInsensitive])

    /// Woerter, die allein kein Titel sind (Linktext "PDF", "Drucken" ...)
    static let generic: Set<String> = ["", "pdf", "dokument", "download", "herunterladen", "öffnen", "anzeigen", "drucken"]

    /// Tags entfernen, Entities dekodieren, Leerraum zusammenfassen
    public static func text(_ html: String) -> String {
        HText.collapse(QISParser.decodeEntities(HText.replace(tagRE, in: html, with: " ")))
    }

    /// Titel ohne "PDF-" vorne und "zum Drucken"/"anzeigen"/"PDF" hinten, hoechstens 90 Zeichen (wie `clean_title`)
    public static func cleanTitle(_ raw: String) -> String {
        var t = HText.collapse(raw)
        t = HText.replace(pdfPrefixRE, in: t, with: "")
        for _ in 0..<2 { t = HText.replace(actionSuffixRE, in: t, with: "") }
        t = HText.replace(trailRE, in: t, with: "")
        return String(t.prefix(90))
    }

    static func isGeneric(_ t: String) -> Bool { generic.contains(t.lowercased()) }

    /// Alle Arten, die der Text nennt (Reihenfolge der Regeln); ohne Treffer `.sonstige`
    public static func kinds(_ text: String) -> [CertificateKind] {
        let low = text.lowercased()
        let found = CertificateKind.rules.filter { _, words in words.contains { low.contains($0) } }.map(\.0)
        return found.isEmpty ? [.sonstige] : found
    }

    /// "WiSe 2026/27" bzw. "SoSe 2026" aus dem Text (der zuerst genannte); nil ohne Semester
    public static func semester(_ text: String) -> String? {
        func year(_ s: String) -> Int { s.count == 2 ? 2000 + (Int(s) ?? 0) : (Int(s) ?? 0) }
        var best: (Int, String)?
        if let m = HText.match(winterRE, text), let a = m.groups[1] ?? nil, let b = m.groups[2] ?? nil {
            let pos = text.distance(from: text.startIndex, to: m.range.lowerBound)
            best = (pos, String(format: "WiSe %d/%02d", year(a), year(b) % 100))
        }
        if let m = HText.match(summerRE, text), let a = m.groups[1] ?? nil {
            let pos = text.distance(from: text.startIndex, to: m.range.lowerBound)
            if best == nil || pos < best!.0 { best = (pos, "SoSe \(year(a))") }
        }
        return best?.1
    }

    /// Sortierschluessel: neuestes Semester zuerst (WiSe 2026/27 > SoSe 2026), ohne Semester zuletzt
    public static func semesterRank(_ s: String?) -> Int {
        guard let s else { return -1 }
        let digits = s.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 0
        return digits * 2 + (s.hasPrefix("WiSe") ? 1 : 0)
    }

    /// Kurzkennung eines Angebots: md5(Hochschule|Ort) auf 12 Zeichen (Ort ohne Prozentkodierung)
    public static func offerID(university: String, locator: String) -> String {
        String(MD5.hex(university + "|" + (locator.removingPercentEncoding ?? locator)).prefix(12))
    }
}

// MARK: - Lesen der Seiten (rein, ohne Netz)

public enum CertificateParser {
    private static let anchorRE = HText.regex("<a\\b([^>]*)>(.*?)</a>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let attrRE = HText.regex("([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
    private static let altRE = HText.regex("\\balt\\s*=\\s*\"([^\"]*)\"", [.caseInsensitive])
    private static let blockOpenRE = HText.regex("<(?:tr|li|p)\\b", [.caseInsensitive])

    /// Attribute eines Tags (Namen klein, Werte mit dekodierten Entities)
    static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        let ns = s as NSString
        for m in attrRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound { value = ns.substring(with: m.range(at: g)); break }
            if out[name] == nil { out[name] = QISParser.decodeEntities(value) }
        }
        return out
    }

    /// Text der Zeile bzw. des Listenpunkts um einen Link: ab dem letzten tr/li/p vor dem Link bis zu seinem Ende
    static func context(_ html: NSString, anchor: NSRange) -> String {
        let from = max(0, anchor.location - 2000)
        let window = NSRange(location: from, length: anchor.location - from)
        guard let last = blockOpenRE.matches(in: html as String, range: window).last else { return "" }
        return CertificateText.text(html.substring(with: NSRange(location: last.range.location, length: NSMaxRange(anchor) - last.range.location)))
    }

    /// Titel eines Links: Linktext, sonst title, sonst Text der Zeile; "PDF" allein ist kein Titel
    static func title(label: String, attrTitle: String, context: String) -> String {
        for candidate in [label, attrTitle, context] {
            let t = CertificateText.cleanTitle(candidate)
            if !CertificateText.isGeneric(t) { return t }
        }
        return "Dokument"
    }

    /// Angebote einer QIS/LSF-Seite: Links mit state=verpublish (nicht state=verify) oder auf eine .pdf auf demselben
    /// Rechner; Adresse ohne asi. Wird nur gelesen, kein Link aufgerufen.
    public static func qisOffers(html: String, url: URL, source: String, university: String, confirmed: Bool) -> [CertificateOffer] {
        let ns = html as NSString
        let host = url.host?.lowercased()
        var out: [CertificateOffer] = []
        var seen = Set<String>()
        for m in anchorRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = attributes(ns.substring(with: m.range(at: 1)))
            guard let href = attrs["href"], let abs = QISParser.resolve(href, base: url) else { continue }
            let address = QISParser.stripSession(abs).address
            guard URL(string: address)?.host?.lowercased() == host else { continue }
            let state = QISParser.parameters(of: address)["state"]?.lowercased() ?? ""
            let path = HText.urlPath(address).lowercased()
            guard state != "verify", state == "verpublish" || path.hasSuffix(".pdf") else { continue }
            guard seen.insert(address).inserted else { continue }
            let inner = ns.substring(with: m.range(at: 2))
            var label = CertificateText.text(inner)
            if label.isEmpty, let alt = HText.match(altRE, inner)?.groups[1] ?? nil { label = QISParser.decodeEntities(alt) }
            let ctx = context(ns, anchor: m.range)
            let t = title(label: label, attrTitle: attrs["title"] ?? "", context: ctx)
            let kinds = CertificateText.kinds(t)
            out.append(CertificateOffer(id: CertificateText.offerID(university: university, locator: address), title: t,
                                        kind: kinds[0], kinds: kinds,
                                        semester: CertificateText.semester(t) ?? CertificateText.semester(ctx),
                                        source: source, portal: "qis", address: address, confirmed: confirmed))
        }
        return out
    }

    // MARK: HISinOne "Bescheide und Bescheinigungen"

    private static let rowRE = HText.regex("<tr\\b[^>]*>(.*?)</tr>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let cellRE = HText.regex("<t[dh]\\b[^>]*>(.*?)</t[dh]>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let buttonRE = HText.regex("<(?:button|input)\\b([^>]*)>(?:((?:(?!<input\\b|<button\\b).)*?)</button>)?", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let selectRE = HText.regex("<select\\b([^>]*)>(.*?)</select>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let optionRE = HText.regex("<option\\b([^>]*)>(.*?)</option>", [.caseInsensitive, .dotMatchesLineSeparators])
    /// Woerter eines Knopfes/Links, der ein Dokument liefert
    static let actionWords = ["pdf", "drucken", "herunterladen", "download", "anzeigen", "erzeugen", "öffnen", "bescheinigung"]
    static let linkHints = [".pdf", "download", "report", "print", "document"]

    /// Eine Aktion in einer Zeile: Link (GET) oder Knopf des umgebenden Formulars (POST)
    public struct HISinOneAction: Sendable, Equatable {
        public var href: String?
        public var button: (name: String, value: String)?
        public static func == (a: Self, b: Self) -> Bool { a.href == b.href && a.button?.name == b.button?.name && a.button?.value == b.button?.value }
    }

    /// Zeilen mit Dokument: (Titel, Semester, Aktion)
    static func hisinoneRows(html: String) -> [(title: String, semester: String?, action: HISinOneAction)] {
        var out: [(title: String, semester: String?, action: HISinOneAction)] = []
        for row in HText.allMatches(rowRE, html) {
            let cells = HText.allMatches(cellRE, row).map(CertificateText.text)
            guard !cells.isEmpty else { continue }
            var action: HISinOneAction?
            let rns = row as NSString
            for m in anchorRE.matches(in: row, range: NSRange(location: 0, length: rns.length)) {
                let a = attributes(rns.substring(with: m.range(at: 1)))
                guard let href = a["href"], !href.lowercased().hasPrefix("javascript"), !href.hasPrefix("#") else { continue }
                let label = (CertificateText.text(rns.substring(with: m.range(at: 2))) + " " + (a["title"] ?? "")).lowercased()
                if linkHints.contains(where: href.lowercased().contains) || actionWords.contains(where: label.contains) {
                    action = HISinOneAction(href: href, button: nil)
                    break
                }
            }
            if action == nil {
                for m in buttonRE.matches(in: row, range: NSRange(location: 0, length: rns.length)) {
                    let a = attributes(rns.substring(with: m.range(at: 1)))
                    let type = (a["type"] ?? "submit").lowercased()
                    guard ["submit", "image"].contains(type), let name = a["name"], !isJobButton(name: name, id: a["id"]) else { continue }
                    let text = m.range(at: 2).location != NSNotFound ? CertificateText.text(rns.substring(with: m.range(at: 2))) : ""
                    let label = [a["value"] ?? "", a["title"] ?? "", a["alt"] ?? "", text].joined(separator: " ").lowercased()
                    if actionWords.contains(where: label.contains) {
                        action = HISinOneAction(href: nil, button: (name, a["value"] ?? text))
                        break
                    }
                }
            }
            guard let action else { continue }
            guard let title = cells.map(CertificateText.cleanTitle).first(where: { t in
                !CertificateText.isGeneric(t) && t.contains(where: \.isLetter) && !actionWords.contains(t.lowercased())
            }) else { continue }
            let rowText = cells.joined(separator: " ")
            out.append((title, CertificateText.semester(title) ?? CertificateText.semester(rowText), action))
        }
        return out
    }

    /// Semesterauswahl der Seite (select mit term/semester/period im Namen bzw. in der Kennung); nur Eintraege mit Semester
    public static func hisinoneSemesters(html: String) -> (name: String, options: [CertificateSemester])? {
        for m in HText.allMatchesFull(selectRE, html) {
            let a = attributes(m[1])
            let key = ((a["name"] ?? "") + " " + (a["id"] ?? "")).lowercased()
            guard let name = a["name"], ["term", "semester", "period"].contains(where: key.contains) else { continue }
            var opts: [CertificateSemester] = []
            for o in HText.allMatchesFull(optionRE, m[2]) {
                let oa = attributes(o[1])
                let label = CertificateText.text(o[2])
                guard let sem = CertificateText.semester(label) else { continue }
                opts.append(CertificateSemester(value: oa["value"] ?? label, label: sem))
            }
            if !opts.isEmpty { return (name, opts) }
        }
        return nil
    }

    /// Knopf eines Berichts im Reiter "Bescheide und Bescheinigungen" (echte Seite der HsH, 06.11.2026):
    /// `studyserviceForm:report:reports:reportButtons:jobConfigurationButtons:<i>:jobConfigurationButtons:<j>:job<k>`
    static func isJobButton(name: String, id: String?) -> Bool {
        [name, id ?? ""].contains { $0.contains("jobConfigurationButtons") && HText.match(jobRE, $0) != nil }
    }
    private static let jobRE = HText.regex(":job\\d*$")

    /// Berichte als Knoepfe (Titel = Text bzw. value/title), in der Reihenfolge der Seite; die Liste haengt vom Konto ab
    public static func hisinoneJobButtons(html: String) -> [(title: String, name: String, value: String)] {
        var out: [(title: String, name: String, value: String)] = []
        let ns = html as NSString
        for m in buttonRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let a = attributes(ns.substring(with: m.range(at: 1)))
            guard let name = a["name"] ?? a["id"], isJobButton(name: name, id: a["id"]) else { continue }
            let text = m.range(at: 2).location != NSNotFound ? CertificateText.text(ns.substring(with: m.range(at: 2))) : ""
            let title = [text, a["value"] ?? "", a["title"] ?? ""].map(CertificateText.cleanTitle).first { !CertificateText.isGeneric($0) } ?? ""
            guard !title.isEmpty else { continue }
            out.append((title, name, a["value"] ?? text))
        }
        return out
    }

    /// Reiter "Bescheide und Bescheinigungen" (Knopf `studyserviceForm:report_TabBtn`) zum lesenden Absenden
    static func hisinoneReportTab(html: String) -> (name: String, value: String)? {
        let ns = html as NSString
        for m in buttonRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let a = attributes(ns.substring(with: m.range(at: 1)))
            guard let name = a["name"], (a["type"] ?? "submit").lowercased() == "submit" else { continue }
            let text = m.range(at: 2).location != NSNotFound ? CertificateText.text(ns.substring(with: m.range(at: 2))) : ""
            if name.hasSuffix("report_TabBtn") || (a["value"] ?? text).contains("Bescheide und Bescheinigungen") { return (name, a["value"] ?? text) }
        }
        return nil
    }

    /// Ist der Reiter mit den Berichten schon offen?
    static func isReportTab(html: String) -> Bool {
        html.contains("jobConfigurationButtons") || html.contains("Keine Bescheide vorhanden")
    }

    private static let pollRE = HText.regex("id=\"([^\"]*jobDownloadPoll[^\"]*)\"")

    /// Kennung des Abfrage-Elements, das den Hintergrundauftrag beobachtet (`...jobDownloadPoll:pollOnStop`)
    static func hisinonePoll(html: String) -> String? { HText.match(pollRE, html)?.groups[1] ?? nil }

    /// Angebote der HISinOne-Seite "Bescheide und Bescheinigungen": Berichtsknoepfe (wie an der HsH gesehen) und
    /// Tabellenzeilen mit PDF-/Drucken-Aktion; Ablauf nach dem Klick (Hintergrundauftrag) noch nicht ausgeloest
    public static func hisinoneOffers(html: String, university: String) -> [CertificateOffer] {
        let semesters = hisinoneSemesters(html: html)?.options ?? []
        var seen = Set<String>()
        let jobs: [CertificateOffer] = hisinoneJobButtons(html: html).compactMap { b in
            let id = CertificateText.offerID(university: university, locator: "hisinone|\(b.title)|")
            guard seen.insert(id).inserted else { return nil }
            let kinds = CertificateText.kinds(b.title)
            return CertificateOffer(id: id, title: b.title, kind: kinds[0], kinds: kinds, semester: CertificateText.semester(b.title),
                                    semesters: [], source: "studienservice", portal: "hisinone", address: nil,
                                    confirmed: university == "hsh" || university == "hildesheim")   // live bestaetigt 06.11.2026
        }
        return jobs + hisinoneRows(html: html).compactMap { r in
            let id = CertificateText.offerID(university: university, locator: "hisinone|\(r.title)|\(r.semester ?? "")")
            guard seen.insert(id).inserted else { return nil }
            let kinds = CertificateText.kinds(r.title)
            return CertificateOffer(id: id, title: r.title, kind: kinds[0], kinds: kinds, semester: r.semester,
                                    semesters: r.semester == nil ? semesters : [], source: "studienservice", portal: "hisinone",
                                    address: nil, confirmed: false)
        }
    }

    /// Formularfelder fuer den Knopf einer Zeile: versteckte Felder und Auswahlen des Formulars, das den Knopf enthaelt,
    /// dazu der Knopf; `semester`: Wert fuer die Semesterauswahl
    static func hisinoneFormRequest(html: String, button: (name: String, value: String), semester: String?, base: URL) -> (url: URL, fields: [(String, String)])? {
        let formRE = HText.regex("<form\\b([^>]*)>(.*?)</form>", [.caseInsensitive, .dotMatchesLineSeparators])
        for f in HText.allMatchesFull(formRE, html) where f[2].contains("name=\"\(button.name)\"") || f[2].contains("name='\(button.name)'") {
            let fa = attributes(f[1])
            guard let action = fa["action"], let url = URL(string: action, relativeTo: base)?.absoluteURL else { continue }
            var fields: [(String, String)] = []
            let body = f[2]
            let bns = body as NSString
            for m in buttonRE.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let a = attributes(bns.substring(with: m.range(at: 1)))
                if (a["type"] ?? "").lowercased() == "hidden", let n = a["name"] { fields.append((n, a["value"] ?? "")) }
            }
            let sel = hisinoneSemesters(html: body)
            for s in HText.allMatchesFull(selectRE, body) {
                let sa = attributes(s[1])
                guard let n = sa["name"] else { continue }
                if let sel, sel.name == n, let semester { fields.append((n, semester)); continue }
                let opts = HText.allMatchesFull(optionRE, s[2])
                let chosen = opts.first { attributes($0[1])["selected"] != nil } ?? opts.first
                if let chosen { fields.append((n, attributes(chosen[1])["value"] ?? CertificateText.text(chosen[2]))) }
            }
            return (url, fields + [(button.name, button.value)])
        }
        return nil
    }

    /// JSF-Ajax-Abfrage fuer das Element `source` (Poll des Hintergrundauftrags): versteckte Felder des Formulars, das
    /// es enthaelt (sonst des ersten mit ViewState), dazu die ueblichen Ajax-Felder. Aufbau HISinOne-/PrimeFaces-Standard,
    /// an der HsH nicht ausgeloest.
    static func hisinoneAjaxRequest(html: String, source: String, base: URL) -> (url: URL, fields: [(String, String)])? {
        let formRE = HText.regex("<form\\b([^>]*)>(.*?)</form>", [.caseInsensitive, .dotMatchesLineSeparators])
        let forms = HText.allMatchesFull(formRE, html)
        guard let f = forms.first(where: { $0[2].contains(source) }) ?? forms.first(where: { $0[2].contains("javax.faces.ViewState") }),
              let action = attributes(f[1])["action"], let url = URL(string: action, relativeTo: base)?.absoluteURL else { return nil }
        var fields: [(String, String)] = []
        let bns = f[2] as NSString
        for m in buttonRE.matches(in: f[2], range: NSRange(location: 0, length: bns.length)) {
            let a = attributes(bns.substring(with: m.range(at: 1)))
            if (a["type"] ?? "").lowercased() == "hidden", let n = a["name"] { fields.append((n, a["value"] ?? "")) }
        }
        let formID = attributes(f[1])["id"] ?? ""
        return (url, fields + [("javax.faces.partial.ajax", "true"), ("javax.faces.source", source),
                               ("javax.faces.partial.execute", source), ("javax.faces.partial.render", formID.isEmpty ? "@form" : formID),
                               (source, source)])
    }

    // MARK: PDF oder Webseite

    private static let embeddedRE = HText.regex("(?:src|href|data|content|url)\\s*=\\s*[\"']?([^\"'\\s>]*(?:\\.pdf|verpublish|hisreports|download)[^\"'\\s>]*)", [.caseInsensitive])

    public static func isPDF(_ data: Data) -> Bool { data.starts(with: Array("%PDF".utf8)) }

    /// Adresse einer PDF in einer Zwischenseite (meta refresh, iframe, embed, Link), nur derselbe Rechner
    static func embeddedPDF(html: String, base: URL) -> URL? {
        for raw in HText.allMatches(embeddedRE, html) {
            var s = QISParser.decodeEntities(raw)
            if s.lowercased().hasPrefix("url=") { s = String(s.dropFirst(4)) }
            guard let abs = QISParser.resolve(s, base: base), let u = URL(string: abs), u.host?.lowercased() == base.host?.lowercased() else { continue }
            return u
        }
        return nil
    }
}

extension HText {
    /// Alle Treffer mit allen Gruppen (fehlende Gruppen leer)
    static func allMatchesFull(_ re: NSRegularExpression, _ s: String) -> [[String]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }
}
