import Foundation

// Studienservice im Campusmanagement der HsH (cm/stu/studyService/start.xhtml?_flowId=studyservice-flow), nur lesen
// (Strukturnotizen "Nachtrag 2", 05.11.2026): Kopf "Rückgemeldet für Wintersemester 2026/27", Reiter "Meine
// Studiengänge" (Fach | Fachsemester | Fachkennzeichen | Prüfungsordnungsversion, gruppiert z. B. "Bachelor -
// Erststudium"), "Zahlungen" ("Offene Zahlungen", leer: "Sie haben keine offenen Zahlungen!"), "Bescheide und
// Bescheinigungen" (documentCenter-flow, leer: "Keine Bescheide vorhanden."). Die Reiter sind JSF-Knoepfe
// (type=submit); ein Reiterwechsel ist ein lesendes Absenden desselben Formulars. Kontaktdaten und Personendaten
// werden nie gelesen oder gespeichert. Nachgebaute Seiten: fixtures/hsh/hisinone-studienservice*.html.

public struct HISinOneStudyService: Sendable, Equatable {
    public struct Program: Sendable, Equatable {
        public var group: String
        public var subject: String
        public var semester: Int?
        public var code: String
        public var po: String
        /// Bezeichnung wie die QIS-Spalte `abschluss` ("Bachelor Angewandte Informatik (PO-Version 2019)"), damit die
        /// Katalogsuche des Studienverlaufs (`StudyCatalogPipeline`) den Studiengang erkennt
        public var label: String {
            let degree = group.split(separator: "-").first.map { HText.collapse(String($0)) } ?? ""
            let poPart = po.isEmpty ? "" : " (PO-Version \(po))"
            return HText.collapse("\(degree) \(subject)") + poPart
        }
    }

    /// "Rückgemeldet für Wintersemester 2026/27"; nil, wenn die Seite es nicht nennt
    public var reregistration: String?
    public var programs: [Program]
    /// Zahl offener Zahlungen (0: "keine offenen Zahlungen"); nil: Reiter nicht gelesen
    public var openPayments: Int?
    /// Zahl der Bescheide (0: "Keine Bescheide vorhanden"); nil: nicht gelesen
    public var documents: Int?

    public static let url = URL(string: HISinOne.pages + "/cm/stu/studyService/start.xhtml?_flowId=studyservice-flow")!

    public var json: JSONValue {
        ["reregistration": reregistration.map(JSONValue.string) ?? .null,
         "programs": .array(programs.map { ["group": .string($0.group), "subject": .string($0.subject),
                                            "semester": $0.semester.map { .number(Double($0)) } ?? .null,
                                            "code": .string($0.code), "po": .string($0.po), "label": .string($0.label)] }),
         "open_payments": openPayments.map { .number(Double($0)) } ?? .null,
         "documents": documents.map { .number(Double($0)) } ?? .null]
    }

    // MARK: Lesen (rein)

    private static let reregRE = HText.regex("((?:Nicht\\s+)?(?:zu)?[rR]ückgemeldet\\s+für\\s+[^<\\n]{3,40}?)\\s*(?:<|\\n|$)")

    public static func reregistration(html: String) -> String? {
        (HText.match(reregRE, html)?.groups[1] ?? nil).map { HText.collapse(QISParser.decodeEntities($0)) }
    }

    /// Tabelle "Meine Studiengänge" (Kopfzeile mit Fach und Fachsemester; einzelne Zellen davor = Gruppe)
    public static func programs(html: String) -> [Program] {
        var out: [Program] = []
        for t in HTMLScanner.scan(html).tables {
            let rows = t.rows.map { $0.map { HText.collapse($0.text) } }
            guard let hIndex = rows.firstIndex(where: { r in r.contains { $0.lowercased() == "fach" } && r.contains { $0.lowercased().hasPrefix("fachsemester") } })
            else { continue }
            let head = rows[hIndex].map { $0.lowercased() }
            func col(_ prefix: String) -> Int? { head.firstIndex { $0.hasPrefix(prefix) } }
            guard let fi = col("fach") else { continue }
            let si = col("fachsemester"), ki = col("fachkennzeichen"), pi = col("prüfungsordnung") ?? col("po")
            var group = ""
            for r in rows.enumerated() where r.offset != hIndex {
                let cells = r.element
                let filled = cells.filter { !$0.isEmpty }
                if filled.count == 1 { group = filled[0]; continue }
                guard cells.count > fi, !cells[fi].isEmpty, cells[fi].lowercased() != "fach" else { continue }
                func cell(_ i: Int?) -> String { i.flatMap { $0 < cells.count ? cells[$0] : nil } ?? "" }
                let semester = Int(cell(si).filter(\.isNumber))
                out.append(Program(group: group, subject: cells[fi], semester: semester, code: cell(ki), po: cell(pi)))
            }
        }
        return out
    }

    /// Offene Zahlungen: 0 bei "keine offenen Zahlungen", sonst die Zeilen der ersten Tabelle nach "Offene Zahlungen"
    public static func openPayments(html: String) -> Int? {
        if html.range(of: "keine offenen Zahlungen", options: .caseInsensitive) != nil { return 0 }
        guard let r = html.range(of: "Offene Zahlungen") else { return nil }
        let rest = String(html[r.upperBound...])
        let end = rest.range(of: "Geleistete Zahlungen").map { String(rest[..<$0.lowerBound]) } ?? rest
        guard let table = HTMLScanner.scan(end).tables.first else { return nil }
        return max(0, table.rows.filter { !$0.contains { $0.isHeader } }.count)
    }

    /// Bescheide: 0 bei "Keine Bescheide vorhanden", sonst Zeilen der Tabelle
    public static func documents(html: String) -> Int? {
        if html.range(of: "Keine Bescheide vorhanden", options: .caseInsensitive) != nil { return 0 }
        guard html.contains("Bescheid") else { return nil }
        return HTMLScanner.scan(html).tables.first.map { $0.rows.filter { !$0.contains { $0.isHeader } }.count }
    }

    // MARK: JSF-Reiter

    private static let formRE = HText.regex("<form\\b([^>]*)>(.*?)</form>", [.caseInsensitive, .dotMatchesLineSeparators])
    private static let inputRE = HText.regex("<(?:input|button)\\b[^>]*>(?:([^<]*)</button>)?", [.caseInsensitive])

    /// Lesendes Absenden fuer einen Reiter ("Zahlungen"): Formular-Adresse und Felder (versteckte Felder samt
    /// javax.faces.ViewState und der Knopf des Reiters); nil, wenn es den Reiter nicht gibt
    public static func tabRequest(html: String, label: String, base: URL = UniversityProfile.hshCampus) -> (url: URL, fields: [(String, String)])? {
        let ns = html as NSString
        for m in formRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = MoodleAssign.attributes("<form " + ns.substring(with: m.range(at: 1)) + ">")
            let body = ns.substring(with: m.range(at: 2))
            guard body.contains(label), let action = attrs["action"],
                  let url = URL(string: action, relativeTo: base)?.absoluteURL, HISinOne.isCampusURL(url) else { continue }
            var fields: [(String, String)] = []
            var button: (String, String)?
            let bns = body as NSString
            for im in inputRE.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                let tag = bns.substring(with: im.range)
                let a = MoodleAssign.attributes(tag)
                let text = im.range(at: 1).location != NSNotFound ? HText.collapse(bns.substring(with: im.range(at: 1))) : ""
                guard let name = a["name"] else { continue }
                let type = (a["type"] ?? "").lowercased()
                if type == "hidden" { fields.append((name, a["value"] ?? "")) }
                if button == nil, type == "submit", (a["value"] ?? "").contains(label) || text.contains(label) || (a["title"] ?? "").contains(label) {
                    button = (name, a["value"] ?? text)
                }
            }
            if let button { return (url, fields + [button]) }
        }
        return nil
    }
}

extension HISinOneStudyService {
    public static let settingsKey = "campus_study_service"

    private static let finishedRE = HText.regex("abgeschlossen|beendet|exmatrikul|ehemalig", [.caseInsensitive])

    /// Der aktuelle Studiengang bei mehreren Zeilen in "Meine Studiengaenge" (Zweitstudium, Haupt- und Nebenfach,
    /// Wechsel): nicht abgeschlossen (Gruppe ohne "abgeschlossen/beendet/exmatrikuliert"), Hauptfach vor Nebenfach,
    /// hoechstes Fachsemester, dann die neuere PO-Version, sonst die erste Zeile; nil ohne Zeile
    public static func current(_ programs: [Program]) -> Program? {
        func rank(_ p: Program) -> (Int, Int, Int, Int) {
            let open = HText.match(finishedRE, p.group) == nil ? 1 : 0
            let kind = p.code.lowercased()
            let main = kind.contains("haupt") ? 1 : (kind.contains("neben") || kind.contains("begleit") ? -1 : 0)
            return (open, main, p.semester ?? -1, Int(p.po.filter(\.isNumber)) ?? -1)
        }
        guard var best = programs.first else { return nil }
        for p in programs.dropFirst() where rank(p) > rank(best) { best = p }
        return best
    }

    /// Stand in den Einstellungen der Datenbank (nur Geraet); der (aktuelle) Studiengang wird als `abschluss` der
    /// Leistungen gesetzt, damit der Studienverlauf Studiengang und PO erkennt: bei genau einem fuer alle Leistungen,
    /// bei mehreren (`current`) nur fuer Leistungen ohne Bezeichnung oder mit dem Namen dieses Fachs - Leistungen
    /// eines anderen Studiengangs behalten ihre Bezeichnung (der Studienverlauf haelt sie auseinander)
    public static func store(_ c: SQLiteConnection, _ s: HISinOneStudyService, now: String) throws {
        var j = s.json
        if case .object(var o) = j {
            o["checked_at"] = .string(now)
            if s.programs.count > 1, let cur = current(s.programs) { o["current"] = .string(cur.label) }
            j = .object(o)
        }
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(settingsKey), .text(j.jsonString())])
        if s.programs.count == 1, let p = s.programs.first, !p.subject.isEmpty {
            try c.execute("UPDATE grades SET abschluss=?", [.text(p.label)])
        } else if s.programs.count > 1, let p = current(s.programs), !p.subject.isEmpty {
            let key = StudyCatalogText.nameKey(p.subject)
            for r in try c.query("SELECT id, abschluss FROM grades") {
                let have = r["abschluss"]?.string ?? ""
                guard have.trimmingCharacters(in: .whitespaces).isEmpty || StudyCatalogText.nameKey(have).contains(key), let id = r["id"] else { continue }
                try c.execute("UPDATE grades SET abschluss=? WHERE id=?", [.text(p.label), id])
            }
        }
    }

    public static func stored(_ c: SQLiteConnection) throws -> JSONValue? {
        guard let raw = try c.queryOne("SELECT value FROM settings WHERE key=?", [.text(settingsKey)])?["value"]?.string else { return nil }
        return try? JSONValue.parse(Data(raw.utf8))
    }
}

extension HISinOneClient {
    /// Studienservice lesen: Rueckmeldung und Studiengaenge, dazu die Reiter Zahlungen und Bescheide (nur Zahlen)
    public func studyService() async throws -> HISinOneStudyService {
        let html = try await campusPage(HISinOneStudyService.url)
        var s = HISinOneStudyService(reregistration: HISinOneStudyService.reregistration(html: html),
                                     programs: HISinOneStudyService.programs(html: html), openPayments: nil, documents: nil)
        if let tab = HISinOneStudyService.tabRequest(html: html, label: "Zahlungen") {
            let page = try await campusPost(tab.url, tab.fields)
            s.openPayments = HISinOneStudyService.openPayments(html: page)
            if let docTab = HISinOneStudyService.tabRequest(html: page, label: "Bescheide") {
                s.documents = HISinOneStudyService.documents(html: try await campusPost(docTab.url, docTab.fields))
            }
        }
        return s
    }
}
