import Foundation

// "Info über angemeldete Prüfungen" aus dem QIS der LUH, nur lesend (Entscheidung des Inhabers 05.11.2026,
// docs/PRUEFUNGSANMELDUNG-2026-11-05.md). Dieselbe Sitzung wie der Notenspiegel (`QISClient`): Startseite ->
// "Mein Studium" -> Link "Info über angemeldete Prüfungen" -> Tabellen; ohne Tabelle den Baum (Abschluss,
// Studiengang) aufklappen, hoechstens `maxPages` Seiten.
//
// LUH AM ECHTEN KONTO GESEHEN (10.11.2026, nur lesend; anonymisierte Seiten fixtures/exam-registration/qis-echt-*.html):
// "Mein Studium" -> "Info über angemeldete Prüfungen" (state=examsinfosStudent, next=tree.vm) -> Baum "Abschluss 82
// Bachelor of Science" (Link "Diesen Zweig aufklappen", expand=0; aufgeklappt heisst derselbe Link "zuklappen",
// expand=1) -> Bild-Link "angemeldete Prüfungen anzeigen für <Studiengang>" (next=list.vm) -> Tabelle mit den Spalten
// PrfNr. | Prüfungsbezeichnung | Prüfer/in | Semester (Termin) | Anmeldedatum *) | Rücktritt über QIS möglich bis |
// Prüfungsdatum (keine Status-Spalte, Datum und Ruecktritt oft leer). Der Baum merkt sich das Aufklappen in der
// Sitzung: ein schon aufgeklappter Zweig wird nicht wieder zugeklappt. Daneben bleiben die erfundenen Seiten
// (qis-*.html); der Leser ist absichtlich tolerant (Spaltenkoepfe ueber das erste Wort, Link ueber den Text).
//
// Uni Hildesheim (`QISGradeLayout.hildesheim`, dieselbe HIS-Software im LSF): Startseite des LSF ("Meine Funktionen")
// -> "POS-Management" -> "Meine POS-Anmeldungen" (Weg laut Schnellanleitung der Uni, Seite selbst NICHT GESEHEN; Fixture
// fixtures/exam-registration/lsf-*.html ist erfunden). Tabellen wie im Hildesheimer Notenspiegel: Zeile "Abschluss: ..."
// vor der Kopfzeile, "Prüfungsnr." und "Bezeichnung der Leistung / der Lehrveranstaltung"; Status auch "zugelassen",
// "storniert", "nicht zugelassen". "An-/Abmeldung zu Studien-/Prüfungsleistungen" und "Zur Anmeldung"/"Zur Stornierung"
// werden nie aufgerufen.
//
// Sicherheit: Es wird nie einem Link zur Pruefungsanmeldung/-abmeldung gefolgt (`QISRegistrationLinks.isForbidden`:
// Text oder Parameter mit Anmeldung, Abmeldung, Ruecktritt), nie ein Formular abgeschickt (nur GET der gefundenen
// Links), nie eine Bescheinigung geoeffnet. asi und Stammdaten wie beim Notenspiegel: nie gespeichert.

/// Eine Zeile der Seite "Info über angemeldete Prüfungen" (Texte wie angezeigt)
public struct QISRegistration: Sendable, Hashable, Codable {
    public var pruefungsnr: String?
    public var text: String
    public var semester: String?
    /// Datum wie angezeigt ("12.02.2027", "12.02.2027 09:00")
    public var datum: String?
    public var time: String?
    public var room: String?
    public var pruefer: String?
    public var versuch: String?
    public var status: String?
    /// Ruecktritt/Abmeldung bis (wie angezeigt)
    public var withdraw: String?
    public var form: String?
    public var abschluss: String?
    public var raw: String

    /// Oeffentlich fuer App-Tests (Zeilen wie aus "Meine POS-Anmeldungen" bzw. "Info ueber angemeldete Pruefungen")
    public init(pruefungsnr: String? = nil, text: String, semester: String? = nil, datum: String? = nil, time: String? = nil,
                room: String? = nil, pruefer: String? = nil, versuch: String? = nil, status: String? = nil,
                withdraw: String? = nil, form: String? = nil, abschluss: String? = nil, raw: String = "") {
        self.pruefungsnr = pruefungsnr; self.text = text; self.semester = semester; self.datum = datum; self.time = time
        self.room = room; self.pruefer = pruefer; self.versuch = versuch; self.status = status; self.withdraw = withdraw
        self.form = form; self.abschluss = abschluss; self.raw = raw
    }

    /// angemeldet (leer, AN, angemeldet, zugelassen ...); abgemeldet, Ruecktritt und bewertete Zeilen nicht
    public var registered: Bool { RegistrationRows.isRegistered(status) }
    /// "YYYY-MM-DD" aus `datum`
    public var isoDate: String? { RegistrationRows.isoDate(datum) }
    /// Uhrzeit aus eigener Spalte oder aus dem Datum ("12.02.2027 09:00")
    public var clock: String? { RegistrationRows.clock(time) ?? RegistrationRows.clock(datum) }
    public var isoWithdraw: String? { RegistrationRows.isoDate(withdraw) }
}

/// Tabellen der Info-Seite als Zeilen von Zellentexten -> `QISRegistration` (wie `GradeRows` fuer den Notenspiegel)
public enum RegistrationRows {
    /// erstes Wort einer Kopfzelle -> Feld ("prüfungs-nr." -> zweites Wort)
    static let headers: [String: String] = [
        "prüfungsnr": "pruefungsnr", "pruefungsnr": "pruefungsnr", "nr": "pruefungsnr", "prüfungsnummer": "pruefungsnr",
        "pnr": "pruefungsnr", "modulnr": "pruefungsnr", "nummer": "pruefungsnr", "prfnr": "pruefungsnr",
        "prüfungstext": "text", "pruefungstext": "text", "text": "text", "bezeichnung": "text", "prüfung": "text",
        "pruefung": "text", "titel": "text", "veranstaltung": "text", "modul": "text", "leistung": "text",
        "prüfungsleistung": "text", "veranstaltungstitel": "text",
        // echte LUH-Seite (10.11.2026): "PrfNr." und "Prüfungsbezeichnung"
        "prüfungsbezeichnung": "text", "pruefungsbezeichnung": "text",
        "semester": "semester", "sem": "semester",
        "datum": "datum", "prüfungsdatum": "datum", "pruefungsdatum": "datum", "termin": "datum", "prüfungstermin": "datum",
        "tag": "datum",
        "uhrzeit": "time", "zeit": "time", "beginn": "time",
        "raum": "room", "ort": "room", "hörsaal": "room",
        "prüfer": "pruefer", "pruefer": "pruefer", "prüferin": "pruefer", "prüfende": "pruefer", "prüfender": "pruefer",
        "dozent": "pruefer", "dozentin": "pruefer",
        "versuch": "versuch",
        "status": "status", "vermerk": "status", "zustand": "status",
        "rücktritt": "withdraw", "ruecktritt": "withdraw", "rücktrittsfrist": "withdraw", "abmeldung": "withdraw",
        "abmeldefrist": "withdraw", "abmelden": "withdraw", "abmeldeschluss": "withdraw",
        "form": "form", "prüfungsform": "form", "pruefungsform": "form", "art": "form", "prüfungsart": "form", "prfart": "form",
        "note": "note", "bewertung": "note",
    ]
    private static let nonWordRE = HText.regex("[^\\wäöüß]+")

    static func headerMap(_ cells: [String]) -> [String?] {
        cells.map { h in
            let words = HText.replace(nonWordRE, in: h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), with: " ")
                .split(separator: " ").map(String.init)
            guard let first = words.first else { return nil }
            if (first == "prüfungs" || first == "pruefungs"), words.count > 1 {
                return headers[first + words[1]] ?? headers[words[1]]
            }
            return headers[first]
        }
    }

    /// Kopfzeile der Info-Seite: Pruefungstext und mindestens Nr., Datum oder Semester; keine Spalte "Note"
    /// (das ist der Notenspiegel, den `GradeRows` liest)
    static func isHeader(_ map: [String?]) -> Bool {
        map.contains("text") && !map.contains("note") && (map.contains("pruefungsnr") || map.contains("datum") || map.contains("semester"))
    }

    static let negative: Set<String> = ["amd", "abgemeldet", "rt", "rte", "rtu", "rücktritt", "ruecktritt", "zurückgetreten",
                                        "be", "bestanden", "nb", "nicht bestanden", "en", "endgültig nicht bestanden", "ab",
                                        "storniert", "abgelehnt", "nicht zugelassen"]

    /// Status einer Zeile -> angemeldet? Leer gilt als angemeldet (die Seite listet nur Anmeldungen)
    public static func isRegistered(_ status: String?) -> Bool {
        let s = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // LSF Hildesheim: stornierte, abgelehnte und nicht zugelassene POS-Anmeldungen
        if s.hasPrefix("storn") || s.hasPrefix("abgelehnt") || s.hasPrefix("nicht zugelassen") { return false }
        if s.isEmpty || s == "an" || s.contains("angemeldet") && !s.contains("abgemeldet") || s.contains("zugelassen") { return true }
        if negative.contains(s) || s.hasPrefix("abgemeldet") || s.hasPrefix("rücktritt") || s.hasPrefix("nicht bestanden")
            || s.hasPrefix("endgültig") || s.hasPrefix("bestanden") { return false }
        return true
    }

    private static let dmyRE = HText.regex(#"(\d{1,2})\.(\d{1,2})\.(\d{4})"#)
    private static let isoRE = HText.regex(#"(\d{4})-(\d{2})-(\d{2})"#)
    private static let clockRE = HText.regex(#"(?<!\d)(\d{1,2})[:.](\d{2})(?:\s*Uhr)?(?![\d.])"#)

    /// "12.02.2027" / "Fr, 12.02.2027 09:00" / "2027-02-12" -> "2027-02-12"; nil ohne gueltiges Datum
    public static func isoDate(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        var parts: (Int, Int, Int)?
        if let m = HText.match(dmyRE, s), let d = m.groups[1].flatMap({ Int($0) }), let mo = m.groups[2].flatMap({ Int($0) }),
           let y = m.groups[3].flatMap({ Int($0) }) {
            parts = (y, mo, d)
        } else if let m = HText.match(isoRE, s), let y = m.groups[1].flatMap({ Int($0) }), let mo = m.groups[2].flatMap({ Int($0) }),
                  let d = m.groups[3].flatMap({ Int($0) }) {
            parts = (y, mo, d)
        }
        guard let (y, mo, d) = parts, y >= 2000, (1...12).contains(mo), d >= 1, d <= BerlinClock.daysInMonth(year: y, month: mo) else { return nil }
        return BerlinClock.isoDate(BerlinClock.dayNumber(year: y, month: mo, day: d))
    }

    /// "09:00", "9.15 Uhr" -> "09:00"/"09:15"; nil ohne Uhrzeit (ein Datum "12.02." ist keine)
    public static func clock(_ s: String?) -> String? {
        guard var s, !s.isEmpty else { return nil }
        if let m = HText.match(dmyRE, s) { s = s.replacingOccurrences(of: m.groups[0] ?? "", with: " ") }
        guard let m = HText.match(clockRE, s), let h = m.groups[1].flatMap({ Int($0) }), let mi = m.groups[2].flatMap({ Int($0) }),
              (0...23).contains(h), (0...59).contains(mi) else { return nil }
        return BerlinClock.pad(h, 2) + ":" + BerlinClock.pad(mi, 2)
    }

    private static let abschlussRE = HText.regex("^(Abschluss:.*?PO-Version:\\s*\\d+)", [.caseInsensitive])

    public static func parse(rows: [[String]], abschluss: String = "") -> [QISRegistration] {
        var out: [QISRegistration] = []
        var mapped: [String?]?
        var abschluss = abschluss
        for rawCells in rows {
            let cells = rawCells.map { HText.collapse($0) }
            guard !GradeRows.isStammdatenRow(cells) else { continue }
            // LSF Hildesheim: "Abschluss: ..." vor der Kopfzeile (wie `GradeRows`)
            let joined = cells.filter { !$0.isEmpty }.joined(separator: " ")
            if joined.lowercased().hasPrefix("abschluss:") {
                abschluss = String(((HText.match(abschlussRE, joined)?.groups[1] ?? nil) ?? joined).prefix(160))
                mapped = nil
                continue
            }
            let hm = headerMap(cells)
            if isHeader(hm) { mapped = hm; continue }
            if hm.contains("note") && hm.contains("text") { mapped = nil; continue }        // Notenspiegel-Kopf: nicht hier
            guard let map = mapped else { continue }
            let filled = cells.filter { !$0.isEmpty }
            guard filled.count >= 2 else { continue }                                       // Bereichszeile ("Pflichtmodule")
            var f: [String: String] = [:]
            for (k, v) in zip(map, cells) where !v.isEmpty {
                if let k, f[k] == nil { f[k] = v }
            }
            guard let text = f["text"], !text.isEmpty,
                  f["pruefungsnr"] != nil || f["datum"] != nil || f["semester"] != nil || f["status"] != nil else { continue }
            out.append(QISRegistration(pruefungsnr: f["pruefungsnr"], text: text, semester: f["semester"], datum: f["datum"],
                                       time: f["time"], room: f["room"], pruefer: f["pruefer"], versuch: f["versuch"],
                                       status: f["status"], withdraw: f["withdraw"], form: f["form"],
                                       abschluss: abschluss.isEmpty ? nil : abschluss, raw: cells.joined(separator: " | ")))
        }
        return out
    }

    /// Doppelte entfernen (gleiche Nr., Text, Semester, Datum); die erste bleibt
    static func merge(_ rows: [QISRegistration]) -> [QISRegistration] {
        var seen = Set<[String?]>()
        return rows.filter { seen.insert([$0.pruefungsnr, $0.text, $0.semester, $0.datum]).inserted }
    }
}

/// Welche Links der Abruf nimmt: der Info-Link und die Baumknoten dahinter; nie Anmeldung/Abmeldung
public enum QISRegistrationLinks {
    static func folded(_ s: String) -> String { ExamRegistrationPeriods.fold(QISParser.clean(s)) }

    /// Link "Info über angemeldete Prüfungen" (auch "angemeldete Prüfungen anzeigen", Bild-alt/title) bzw. im LSF der
    /// Uni Hildesheim "Meine POS-Anmeldungen"
    public static func isInfo(_ l: QISLink) -> Bool {
        guard !isForbidden(l) else { return false }
        let t = folded(l.text)
        return t.contains("angemeldete pruefungen") || t.contains("angemeldeten pruefungen") || t.contains("angemeldete leistungen")
            || isPOSOverview(l)
    }

    /// "Meine POS-Anmeldungen" (LSF Hildesheim): reine Uebersicht, nur ueber den Text erkannt
    static func isPOSOverview(_ l: QISLink) -> Bool {
        let t = folded(l.text).replacingOccurrences(of: "-", with: " ")
        return t == "meine pos anmeldungen" || t == "meine anmeldungen"
    }

    /// "POS-Management" (LSF Hildesheim, Untermenue von "Meine Funktionen"): Weg zur Uebersicht
    static func isPOSMenu(_ l: QISLink) -> Bool {
        let t = folded(l.text).replacingOccurrences(of: "-", with: " ")
        return t == "pos management" && !isForbidden(l)
    }

    private static let programRE = HText.regex(#"(?:prüfungen|pruefungen|leistungen)\s+f(?:ü|ue)r\s+(.+?)\s+anzeigen\s*$"#, [.caseInsensitive])
    /// echte LUH-Seite: "angemeldete Prüfungen anzeigen für Technische Informatik (PO-Version 2017)"
    private static let programAfterRE = HText.regex(#"(?:prüfungen|pruefungen|leistungen)\s+anzeigen\s+f(?:ü|ue)r\s+(.+?)\s*$"#, [.caseInsensitive])

    /// Studiengang aus "Angemeldete Prüfungen für <Studiengang> anzeigen" (wie `QISLink.studiengang`) oder
    /// "angemeldete Prüfungen anzeigen für <Studiengang>", sonst nil
    static func studiengang(_ l: QISLink) -> String? {
        if let s = l.studiengang { return s }
        let text = QISParser.clean(l.text)
        guard let g = (HText.match(programRE, text) ?? HText.match(programAfterRE, text))?.groups[1] ?? nil else { return nil }
        let c = QISParser.clean(g)
        return c.isEmpty ? nil : c
    }

    /// Nie folgen: Pruefungsanmeldung/-abmeldung, Ruecktritt, Bescheinigungen, PDF (auch der PDF-Druck der Liste,
    /// state=hisreports), Abmelden (Logout)
    public static func isForbidden(_ l: QISLink) -> Bool {
        let t = folded(l.text)
        if ["abmeld", "ruecktritt", "zuruecktreten", "anmelden", "abmelden", "logout", "storn", "zur anmeldung"].contains(where: { t.contains($0) }) {
            return true
        }
        // "Meine POS-Anmeldungen" (LSF Hildesheim) ist eine Uebersicht: der Text darf "Anmeldungen" nennen, die Parameter
        // duerfen "anmeldungen" enthalten; Abmelden, Stornieren und der Anmeldeablauf (prfanm) bleiben gesperrt
        let overview = isPOSOverview(l)
        if t.contains("anmeldung") && !t.contains("angemeldet") && !overview { return true }
        let p = l.parameters
        for key in ["state", "next", "moduleparameter", "menuid", "navigationposition", "breadcrumb", "subitem"] {
            let v = ExamRegistrationPeriods.fold(p[key] ?? "")
            if ["abmeld", "prfanm", "pruefungsan", "ruecktritt", "rucktritt", "logout", "storn"].contains(where: { v.contains($0) }) { return true }
            if v.contains("anmeld") && !(overview && v.contains("anmeldungen")) { return true }
        }
        let a = l.address.lowercased()
        if ["verpublish", "hisreports"].contains((p["state"] ?? "").lowercased()) || a.contains(".pdf") || a.contains("logout")
            || a.contains("storn") || t.hasPrefix("pdf") { return true }
        if p["state"] == "user", p["type"] == "4" { return true }
        return false
    }

    /// Naechste Links auf einer Seite hinter dem Info-Link: weitere Info-Links und Baumknoten (gleicher `state`,
    /// mit nodeID oder Liste); nur derselbe Rechner, ohne besuchte, hoechstens 10. Listen zuerst (sie tragen die
    /// Tabelle); ein schon aufgeklappter Zweig wird nicht angefasst (kein Zuklappen: echte LUH-Seite, expand=1).
    static func next(on page: QISPage, info: QISLink, visited: Set<String>) -> [QISLink] {
        let host = URL(string: page.address)?.host?.lowercased()
        let state = info.state?.lowercased()
        // ein schon besuchter Baumknoten wird nicht wieder angeboten (kein Zuklappen), Listen schon
        let visitedNodes = Set(visited.compactMap { QISParser.parameters(of: $0)["nodeid"]?.lowercased() }.filter { !$0.isEmpty })
        // Knoten aller Links der Seite: ein Zweig ist schon aufgeklappt, wenn ein anderer Link darunter liegt ("knoten|...")
        let nodes = Set(page.links.filter { $0.host == host }.compactMap { $0.parameters["nodeid"]?.lowercased() }.filter { !$0.isEmpty })
        func isList(_ l: QISLink) -> Bool { (l.parameters["next"] ?? "").lowercased() == "list.vm" }
        var seen = Set<String>()
        let out = page.links.filter { l in
            guard l.host == host, !visited.contains(l.address), !isForbidden(l), seen.insert(l.address).inserted else { return false }
            let list = isList(l)
            let node = (l.parameters["nodeid"] ?? "").lowercased()
            if !node.isEmpty, !list {
                if visitedNodes.contains(node) || l.parameters["expand"] == "1" { return false }
                if nodes.contains(where: { $0.hasPrefix(node + "|") }) { return false }
            }
            if isInfo(l) { return true }
            guard let state, l.state?.lowercased() == state else { return false }
            return !node.isEmpty || list
        }
        return Array((out.filter(isList) + out.filter { !isList($0) }).prefix(10))
    }
}

public enum QISRegistrationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// weder auf der Startseite noch unter "Mein Studium" ein Link "Info über angemeldete Prüfungen"
    case infoNotFound
    /// LSF Hildesheim: weder auf "Meine Funktionen" noch unter "POS-Management" ein Link "Meine POS-Anmeldungen"
    case posOverviewNotFound

    public var description: String {
        switch self {
        case .infoNotFound: return "Die Seite „Info über angemeldete Prüfungen“ wurde im QIS nicht gefunden."
        case .posOverviewNotFound: return "Die Seite „Meine POS-Anmeldungen“ wurde im LSF nicht gefunden."
        }
    }

    public var errorDescription: String? { description }
}

public struct QISRegistrationResult: Sendable, Equatable {
    public let registrations: [QISRegistration]
    public let pages: Int
    public let tables: Int
}

/// Liest "Info über angemeldete Prüfungen" mit einer angemeldeten QIS-Sitzung (Cookies setzt der Transport der App)
public actor QISRegistrationClient {
    public static let defaultMaxPages = 12

    private let transport: UniTransport
    private let retry: UniRetry
    private let start: URL
    private let maxPages: Int
    private let layout: QISGradeLayout

    /// `layout: .hildesheim`: LSF der Uni Hildesheim (Start `UniversityProfile.hildesheimLSFStart`, Weg ueber
    /// "POS-Management" zu "Meine POS-Anmeldungen")
    public init(transport: UniTransport, retry: UniRetry = UniRetry(), start: URL? = nil,
                maxPages: Int = QISRegistrationClient.defaultMaxPages, layout: QISGradeLayout = .luh) {
        self.transport = transport
        self.retry = retry
        self.start = start ?? (layout == .hildesheim ? UniversityProfile.hildesheimLSFStart : QISClient.startURL)
        self.maxPages = maxPages
        self.layout = layout
    }

    private func page(_ url: URL) async throws -> QISPage {
        let resp = try await transport.fetch(UniRequest(url: url), retry: retry)
        // LSF Hildesheim: abgelaufene Sitzung leitet zur CAS-Anmeldung
        if layout == .hildesheim, HildesheimCAS.isCASPage(resp.finalURL?.absoluteString ?? "") { throw QISError.sessionExpired }
        guard resp.status == 200 else { throw QISError.http(status: resp.status) }
        let p = QISPage.parse(html: resp.text, url: resp.finalURL ?? url)
        if p.hasLoginForm || !p.isLoggedIn { throw QISError.sessionExpired }
        return p
    }

    /// Zwischenschritt zur Info-Seite: "Mein Studium" (LUH) bzw. "POS-Management" (LSF Hildesheim)
    private func menu(on p: QISPage) -> QISLink? {
        switch layout {
        case .luh, .hisinone: return p.link(.meinStudium)          // HsH: altes QIS icms (gleiche HIS-QIS-Technik)
        case .hildesheim:
            let host = URL(string: p.address)?.host?.lowercased()
            return p.links.first { $0.host == host && QISRegistrationLinks.isPOSMenu($0) }
        }
    }

    static func tables(_ p: QISPage) -> [HTMLTable] {
        p.tables.filter { t in t.rows.contains { RegistrationRows.isHeader(RegistrationRows.headerMap($0.map(\.text))) } }
    }

    public func fetch() async throws -> QISRegistrationResult {
        let first = try await page(start)
        var pages = 1
        var from = first
        var info = first.links.first(where: QISRegistrationLinks.isInfo)
        if info == nil, let studium = menu(on: first), !QISRegistrationLinks.isForbidden(studium), let url = first.url(for: studium) {
            from = try await page(url)
            pages += 1
            info = from.links.first(where: QISRegistrationLinks.isInfo)
        }
        guard let info else { throw layout == .hildesheim ? QISRegistrationError.posOverviewNotFound : QISRegistrationError.infoNotFound }
        var visited = Set<String>([first.address, from.address])
        var rows: [QISRegistration] = []
        var tableCount = 0
        var pending: [(link: QISLink, from: QISPage)] = [(info, from)]
        while !pending.isEmpty, pages < maxPages {
            let next = pending.removeFirst()
            guard !visited.contains(next.link.address), !QISRegistrationLinks.isForbidden(next.link),
                  let url = next.from.url(for: next.link) else { continue }
            try Task.checkCancellation()
            let p = try await page(url)
            pages += 1
            visited.insert(next.link.address)
            visited.insert(p.address)
            let abschluss = QISRegistrationLinks.studiengang(next.link) ?? ""
            for t in Self.tables(p) {
                tableCount += 1
                rows += RegistrationRows.parse(rows: t.rows.map { $0.map(\.text) }, abschluss: abschluss)
            }
            // erst in die Tiefe (Abschluss -> Studiengang -> Liste), dann die uebrigen
            pending = QISRegistrationLinks.next(on: p, info: info, visited: visited).map { ($0, p) } + pending
        }
        return QISRegistrationResult(registrations: RegistrationRows.merge(rows), pages: pages, tables: tableCount)
    }
}

/// Angemeldete Pruefungen in die Datenbank (nur Geraet): Tabelle `exam_registrations` (je Abruf ersetzt) und der
/// Stand in `settings.exam_registration_run` (`{at, ok, count, message}`)
public enum QISRegistrationsSync {
    public static let runKey = "exam_registration_run"

    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS exam_registrations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pruefungsnr TEXT, text TEXT NOT NULL, semester TEXT, datum TEXT, time TEXT, room TEXT, pruefer TEXT,
            versuch TEXT, status TEXT, withdraw TEXT, form TEXT, abschluss TEXT, raw TEXT, fetched_at TEXT
        );
        """

    public struct Report: Sendable, Equatable {
        public var count: Int?
        public var needsLogin = false
        public var cancelled = false
        public var message = ""
        public var ok: Bool { count != nil }

        public init(count: Int? = nil, needsLogin: Bool = false, cancelled: Bool = false, message: String = "") {
            self.count = count
            self.needsLogin = needsLogin
            self.cancelled = cancelled
            self.message = message
        }
    }

    static func message(count: Int, system: String = "QIS") -> String {
        switch count {
        case 0: return "Im \(system) sind keine Prüfungen angemeldet."
        case 1: return "1 angemeldete Prüfung gelesen."
        default: return "\(count) angemeldete Prüfungen gelesen."
        }
    }

    static func hasTable(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='exam_registrations'") != nil
    }

    /// Zeilen ersetzen (abgemeldete verschwinden so auch aus der App)
    public static func store(_ c: SQLiteConnection, _ rows: [QISRegistration], now: String) throws {
        try c.executeScript(tableSQL)
        try c.execute("DELETE FROM exam_registrations")
        for r in rows {
            func t(_ s: String?) -> SQLiteValue { s.map(SQLiteValue.text) ?? .null }
            try c.execute("""
                INSERT INTO exam_registrations(pruefungsnr, text, semester, datum, time, room, pruefer, versuch, status, withdraw,
                    form, abschluss, raw, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [t(r.pruefungsnr), .text(r.text), t(r.semester), t(r.datum), t(r.time), t(r.room), t(r.pruefer), t(r.versuch),
                      t(r.status), t(r.withdraw), t(r.form), t(r.abschluss), .text(r.raw), .text(now)])
        }
    }

    /// Gespeicherte Zeilen (leer ohne Tabelle)
    public static func rows(_ c: SQLiteConnection) throws -> [QISRegistration] {
        guard try hasTable(c) else { return [] }
        return try c.rows("SELECT * FROM exam_registrations ORDER BY id").map { r in
            func s(_ k: String) -> String? { r[k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
            return QISRegistration(pruefungsnr: s("pruefungsnr"), text: s("text") ?? "", semester: s("semester"), datum: s("datum"),
                                   time: s("time"), room: s("room"), pruefer: s("pruefer"), versuch: s("versuch"), status: s("status"),
                                   withdraw: s("withdraw"), form: s("form"), abschluss: s("abschluss"), raw: s("raw") ?? "")
        }
    }

    /// Stand des letzten Abrufs oder nil
    public static func lastRun(_ c: SQLiteConnection) throws -> JSONValue? {
        guard let raw = try c.scalar("SELECT value FROM settings WHERE key=?", [.text(runKey)])?.string, !raw.isEmpty else { return nil }
        return try? JSONValue.parse(raw)
    }

    static func saveRun(_ c: SQLiteConnection, at: String, ok: Bool, count: Int, message: String) throws {
        try LocalSettings.write(c, key: runKey, value: .object([
            PyJSON.Member("at", .string(at)), PyJSON.Member("ok", .bool(ok)), PyJSON.Member("count", .int(String(count))),
            PyJSON.Member("message", .string(message)),
        ]))
    }

    /// `layout: .hildesheim`: "Meine POS-Anmeldungen" im LSF (HildesheimSync nach dem Notenspiegel)
    public static func run(db: SQLiteDatabase, transport: UniTransport, clock: UniFlowClock = .system, retry: UniRetry = UniRetry(),
                           maxPages: Int = QISRegistrationClient.defaultMaxPages, layout: QISGradeLayout = .luh) async -> Report {
        do {
            let r = try await QISRegistrationClient(transport: transport, retry: retry, maxPages: maxPages, layout: layout).fetch()
            let now = clock.nowISO
            let text = message(count: r.registrations.filter(\.registered).count, system: layout == .hildesheim ? "LSF" : "QIS")
            let rows = r.registrations
            try await db.transaction { c in
                try store(c, rows, now: now)
                try saveRun(c, at: now, ok: true, count: rows.filter(\.registered).count, message: text)
            }
            return Report(count: rows.filter(\.registered).count, message: text)
        } catch {
            if QISGradesSync.isCancellation(error) { return Report(cancelled: true, message: "Abruf abgebrochen") }
            let text = (error as? QISRegistrationError)?.description ?? QISGradesSync.describe(error)
            let now = clock.nowISO
            _ = try? await db.transaction { c in try saveRun(c, at: now, ok: false, count: 0, message: text) }
            return Report(needsLogin: (error as? QISError) == .sessionExpired, message: text)
        }
    }
}
