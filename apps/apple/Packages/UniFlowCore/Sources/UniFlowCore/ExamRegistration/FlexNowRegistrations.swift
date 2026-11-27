import Foundation

// Uni Goettingen: angemeldete Pruefungen mit An-/Abmeldefrist aus FlexNow 2, nur lesend (Auftrag 27.11.2026,
// docs/GOETTINGEN-FLEXNOW-2026-11-27.md). Grundlage ist der echte Aufbau, am 27.11.2026 im Chrome des Inhabers mit
// seinem Testkonto gesehen (er hat sich selbst angemeldet; nur gelesen, Zahlen maskiert):
//
// - Anmeldung `https://flexnow2.uni-goettingen.de/` -> `/FN2AUTH/login.jsp`, Formular per POST an
//   `/FN2AUTH/FN2AuthServlet?op=…` mit `kennung`, `kennwort` (ohne zweiten Faktor); danach `/FN2SSS/`.
// - Die Studentenschnittstelle laedt jeden Bereich per `POST /FN2SSS/FrontControllerSS` als HTML-Stueck nach. Was in
//   der Anfrage steht, ist nicht gesehen. Darum liest die App die fertige Seite in der Webansicht (`outerHTML`), wie
//   "Diese Seite auslesen" beim QIS; sie schickt selbst nie eine Anfrage an `FrontControllerSS`.
// - "Aktuelles" (Startansicht) -> "Aktuelle Prüfungen": `ul.class-list` -> `div.class-list-head` "Modul: <Kürzel>:
//   <Titel>" -> li -> `div.PrfContainerAktuelles` -> `div.class-list-head` "Prüfung: <Kürzel>: <Titel> (<Art>)" ->
//   `div.prfangs ul li div.prfangBlock.angemeldet` mit `form.prfangFormAktuelles` (versteckte Kennungen der Anmeldung,
//   hier NIE gelesen und nie abgeschickt) und `div.primaryData div.info-inner`: p "WS##/##", `span.titelBez`
//   "– <PRÜFER>: An-/Abmeldung bis TT.MM.JJJJ, HH Uhr", `div.class-list-head.signed`, `span.fristBis`
//   "TT.MM.JJJJ - TT.MM.JJJJ, HH:MM Uhr" mit b "Abmeldung möglich im Zeitraum:". Ein Pruefungstermin stand nicht da.
//
// Gelesen wird nur, was angemeldet ist (Klasse `angemeldet`); jeder andere Block zaehlt nur als "uebersprungen". Der
// Notenbaum (Studierendendaten) wird hier nicht gelesen: das Testkonto hatte keine Noten, das Format einer Notenzeile
// ist nicht gesehen. Gespeichert wird in dieselbe Tabelle wie die Anmeldungen aus dem QIS (`QISRegistrationsSync`),
// damit Anzeige, Geraeteabgleich und Erinnerungen denselben Weg nehmen.

/// Kleiner Baum aus den Bausteinen von `HTMLTokenizer` (die Webansicht liefert wohlgeformtes `outerHTML`)
final class FlexNowNode {
    enum Child {
        case node(FlexNowNode)
        case text(String)
    }

    let name: String
    let attributes: [String: String]
    var children: [Child] = []
    weak var parent: FlexNowNode?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    lazy var classes: Set<String> = Set((attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))

    func has(_ cls: String) -> Bool { classes.contains(cls) }

    /// Text aller Nachfahren, Leerraum zusammengefasst
    var text: String { QISParser.clean(rawText) }

    private var rawText: String {
        children.map { c -> String in
            switch c {
            case .text(let t): return t
            case .node(let n): return " " + n.rawText + " "
            }
        }.joined()
    }

    var elements: [FlexNowNode] { children.compactMap { if case .node(let n) = $0 { return n } else { return nil } } }

    /// Alle Nachfahren in Lesereihenfolge (ohne sich selbst)
    func descendants(where keep: (FlexNowNode) -> Bool) -> [FlexNowNode] {
        var out: [FlexNowNode] = []
        func walk(_ n: FlexNowNode) {
            for e in n.elements {
                if keep(e) { out.append(e) }
                walk(e)
            }
        }
        walk(self)
        return out
    }

    func first(where keep: (FlexNowNode) -> Bool) -> FlexNowNode? { descendants(where: keep).first }

    func hasAncestor(where keep: (FlexNowNode) -> Bool) -> Bool {
        var p = parent
        while let n = p {
            if keep(n) { return true }
            p = n.parent
        }
        return false
    }

    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                                            "source", "track", "wbr"]

    /// Seite -> Baum. Ein End-Tag schliesst bis zum passenden offenen Element; ohne passendes bleibt er ohne Wirkung.
    static func parse(_ html: String) -> FlexNowNode {
        let root = FlexNowNode(name: "#document")
        var stack = [root]
        for t in HTMLTokenizer.tokens(html, selfClosingEnds: true) {
            switch t {
            case .start(let name, let attrs):
                let n = FlexNowNode(name: name, attributes: attrs)
                n.parent = stack.last
                stack.last?.children.append(.node(n))
                if !voidElements.contains(name) { stack.append(n) }
            case .end(let name):
                guard !voidElements.contains(name), let i = stack.lastIndex(where: { $0.name == name }), i > 0 else { continue }
                stack.removeSubrange(i...)
            case .text(let s):
                stack.last?.children.append(.text(s))
            case .raw:
                continue                                         // script, style, title: kein Inhalt fuer den Leser
            }
        }
        return root
    }
}

/// Rechner, Adressen und Erkennung der FlexNow-Seiten
public enum FlexNowPage {
    public static let host = "flexnow2.uni-goettingen.de"
    /// Einstieg (leitet zur Anmeldung bzw. bei bestehender Sitzung zur Studentenschnittstelle)
    public static let entry = URL(string: "https://flexnow2.uni-goettingen.de/")!
    /// Studentenschnittstelle nach der Anmeldung, Startansicht "Aktuelles"
    public static let start = URL(string: "https://flexnow2.uni-goettingen.de/FN2SSS/")!

    /// HTTPS auf dem Rechner von FlexNow (Standard-Port)
    public static func isFlexNow(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == host else { return false }
        return url.port == nil || url.port == 443
    }

    /// Anmeldeformular von FlexNow im Seiteninhalt (`kennung`/`kennwort`)
    public static func showsLoginForm(_ html: String) -> Bool { UniLoginForms.goettingenFlexNow.appears(in: html) }

    /// Angemeldete Studentenschnittstelle: `/FN2SSS/…` auf dem Rechner von FlexNow, ohne Anmeldeformular
    public static func isSignedIn(url: URL?, html: String) -> Bool {
        guard isFlexNow(url), let path = url?.path, path.hasPrefix("/FN2SSS") else { return false }
        return !showsLoginForm(html)
    }
}

/// Ergebnis des Lesens einer Seite der Studentenschnittstelle
public struct FlexNowAktuelles: Sendable, Equatable {
    /// angemeldete Pruefungen (Texte wie angezeigt)
    public var registrations: [QISRegistration] = []
    /// Zahl der Pruefungsbloecke (`div.PrfContainerAktuelles`)
    public var containers = 0
    /// Bloecke ohne Klasse `angemeldet` (nicht gelesen; dieser Zustand ist am echten Konto nicht gesehen)
    public var skipped = 0
    /// Ueberschrift "Aktuelle Prüfungen" steht auf der Seite
    public var sectionFound = false
    /// der Abschnitt sagt selbst, dass es nichts gibt ("Derzeit keine …")
    public var saidEmpty = false
    /// Anmeldeformular statt der Studentenschnittstelle
    public var loginPage = false

    /// Liste sicher gelesen: Bloecke da oder der Abschnitt sagt "keine". Sonst ist "nichts angemeldet" nicht bekannt
    /// (Seite noch nicht fertig nachgeladen, anderer Bereich offen) und nichts wird geloescht.
    public var reached: Bool { !loginPage && (containers > 0 || (sectionFound && saidEmpty)) }
}

public enum FlexNowParser {
    /// Ueberschriften des Abschnitts (Deutsch; Englisch geraten)
    static let sectionTitles: Set<String> = ["aktuelle pruefungen", "current exams", "current examinations"]
    /// Ueberschriften der anderen Abschnitte von "Aktuelles" (Ende des Abschnitts beim Suchen nach "keine")
    static let otherTitles: Set<String> = ["neueste meldungen", "neueste ergebnisse", "latest news", "latest results"]
    static let emptyWords = ["keine", "no current", "no exams", "none"]

    private static let semesterRE = HText.regex(#"^(?:WS|SS|WiSe|SoSe)\s*\d{2}(?:\s*/\s*\d{2,4})?$"#, [.caseInsensitive])
    private static let dateRE = HText.regex(#"\d{1,2}\.\d{1,2}\.\d{4}"#)
    /// Uhrzeit nach dem letzten Datum: "23:59 Uhr", "23 Uhr", "23.59 Uhr"
    private static let clockAfterRE = HText.regex(#"^[\s,]*(\d{1,2})(?:[:.](\d{2}))?\s*Uhr"#, [.caseInsensitive])

    /// Seite lesen (`outerHTML` der Studentenschnittstelle)
    public static func parse(html: String) -> FlexNowAktuelles {
        var out = FlexNowAktuelles()
        if FlexNowPage.showsLoginForm(html) {
            out.loginPage = true
            return out
        }
        let root = FlexNowNode.parse(html)
        let (found, empty) = section(root)
        out.sectionFound = found
        out.saidEmpty = empty
        var module: String?
        func walk(_ n: FlexNowNode) {
            for e in n.elements {
                if e.has("PrfContainerAktuelles") {
                    out.containers += 1
                    read(container: e, module: module, into: &out)
                    continue                                       // Inhalt gehoert zu diesem Block
                }
                if e.has("class-list-head"), !e.has("signed") {
                    let t = e.text
                    if !t.isEmpty { module = t }
                }
                walk(e)
            }
        }
        walk(root)
        out.registrations = RegistrationRows.merge(out.registrations)
        return out
    }

    /// Ueberschrift "Aktuelle Prüfungen" und ob ihr Abschnitt selbst "keine" sagt: nur der Text der folgenden
    /// Geschwister der Ueberschrift im selben Element, bis zum naechsten Abschnitt, ohne Pruefungsbloecke, hoechstens 400
    /// Zeichen (Fusszeilen oder andere Kaesten der Seite zaehlen nie)
    static func section(_ root: FlexNowNode) -> (found: Bool, empty: Bool) {
        func isTitle(_ n: FlexNowNode) -> Bool { sectionTitles.contains(ExamRegistrationPeriods.fold(n.text)) }
        guard var heading = root.first(where: isTitle) else { return (false, false) }
        // innerstes Element mit genau diesem Text (ein Kasten mit noch leerer Liste hat denselben Text wie seine Ueberschrift)
        while let inner = heading.elements.first(where: isTitle) { heading = inner }
        guard let parent = heading.parent else { return (false, false) }
        var after = ""
        var seen = false
        scan: for c in parent.children {
            if case .node(let e) = c, e === heading { seen = true; continue }
            guard seen else { continue }
            switch c {
            case .text(let t): after += " " + t
            case .node(let e):
                if otherTitles.contains(ExamRegistrationPeriods.fold(e.text)) || e.has("PrfContainerAktuelles") { break scan }
                after += " " + e.text
            }
            if after.count > 400 { break }
        }
        let t = ExamRegistrationPeriods.fold(QISParser.clean(after))
        return (true, emptyWords.contains { t.contains($0) })
    }

    /// "Modul: B.X.0001: Titel" -> (Kuerzel, Titel); die Beschriftung vor dem ersten ": " faellt weg
    static func splitHead(_ s: String) -> (code: String?, title: String) {
        var rest = QISParser.clean(s)
        if let r = rest.range(of: ": "), !rest[..<r.lowerBound].contains(where: \.isNumber) {
            rest = String(rest[r.upperBound...])                   // "Modul", "Prüfung", "Module", "Exam"
        }
        if let r = rest.range(of: ": ") {
            let code = String(rest[..<r.lowerBound])
            if !code.isEmpty, !code.contains(" "), code.contains(where: \.isNumber) || code.contains(".") {
                return (code, QISParser.clean(String(rest[r.upperBound...])))
            }
        }
        return (nil, rest)
    }

    /// "Titel (Prüfungsvorleistung)" -> ("Titel", "Prüfungsvorleistung"); auch geschachtelt: "Titel (Klausur (90
    /// Minuten))" -> ("Titel", "Klausur (90 Minuten)")
    static func splitForm(_ s: String) -> (title: String, form: String?) {
        guard s.hasSuffix(")") else { return (s, nil) }
        var depth = 0
        var i = s.endIndex
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == ")" { depth += 1 } else if s[i] == "(" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        guard depth == 0, s[i] == "(" else { return (s, nil) }
        let form = QISParser.clean(String(s[s.index(after: i)..<s.index(before: s.endIndex)]))
        let title = QISParser.clean(String(s[..<i]))
        return title.isEmpty || form.isEmpty ? (s, nil) : (title, form)
    }

    /// Ende einer Frist: letztes Datum mit Uhrzeit danach ("10.01.2027, 23:59 Uhr"); nur Stunde -> ":00"
    static func deadline(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let ns = s as NSString
        guard let last = dateRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let date = ns.substring(with: last.range)
        let tail = ns.substring(from: last.range.location + last.range.length)
        guard let m = HText.match(clockAfterRE, tail), let h = m.groups[1].flatMap({ Int($0) }), (0...23).contains(h) else { return date }
        let mi = m.groups[2].flatMap { Int($0) } ?? 0
        guard (0...59).contains(mi) else { return date }
        return "\(date), \(BerlinClock.pad(h, 2)):\(BerlinClock.pad(mi, 2)) Uhr"
    }

    /// Text ohne Beschriftung vor dem ersten Doppelpunkt, wenn davor keine Ziffer steht ("Abmeldung möglich im
    /// Zeitraum: 01.11.… - …" -> "01.11.… - …")
    static func dropLabel(_ s: String) -> String {
        guard let r = s.range(of: ":"), !s[..<r.lowerBound].contains(where: \.isNumber) else { return s }
        return QISParser.clean(String(s[r.upperBound...]))
    }

    private static func read(container: FlexNowNode, module: String?, into out: inout FlexNowAktuelles) {
        let head = container.first { $0.has("class-list-head") && !$0.has("signed") && !$0.hasAncestor(where: { $0.has("prfangBlock") }) }
        let (code, rawTitle) = splitHead(head?.text ?? "")
        let (title, form) = splitForm(rawTitle)
        guard !title.isEmpty else { return }
        let moduleText = module.map { m -> String in
            let (c, t) = splitHead(m)
            return [c, t.isEmpty ? nil : t].compactMap { $0 }.joined(separator: ": ")
        }
        for block in container.descendants(where: { $0.has("prfangBlock") }) {
            guard block.has("angemeldet") else { out.skipped += 1; continue }
            let info = block.first { $0.has("info-inner") } ?? block
            let semester = info.descendants { $0.name == "p" }.map(\.text).first { HText.match(semesterRE, $0) != nil }
            let titel = info.first { $0.has("titelBez") }?.text
            let frist = info.first { $0.has("fristBis") }.map { dropLabel($0.text) }
            // "– PRÜFER: An-/Abmeldung bis …": Pruefer vor dem Doppelpunkt
            var pruefer: String?
            if let t = titel {
                let trimmed = t.trimmingCharacters(in: CharacterSet(charactersIn: "–—- ").union(.whitespaces))
                if let r = trimmed.range(of: ":") {
                    let p = QISParser.clean(String(trimmed[..<r.lowerBound]))
                    if !p.isEmpty, p.count <= 120 { pruefer = p }
                }
            }
            let withdraw = deadline(frist) ?? deadline(titel)
            let raw = [moduleText, head?.text, semester, titel, frist.map { "Abmeldung möglich: " + $0 }].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " | ")
            out.registrations.append(QISRegistration(pruefungsnr: code, text: title, semester: semester, pruefer: pruefer,
                                                     status: "angemeldet", withdraw: withdraw, form: form, abschluss: moduleText,
                                                     raw: raw))
        }
    }
}

/// Gelesene Seite -> Tabelle `exam_registrations` (wie `QISRegistrationsSync.run`, aber ohne eigenen Abruf: die Seite
/// kommt aus der Webansicht der App)
public enum FlexNowRegistrationsSync {
    public static let system = "FlexNow"

    static func message(count: Int) -> String {
        switch count {
        case 0: return "In FlexNow sind gerade keine Prüfungen angemeldet."
        case 1: return "1 angemeldete Prüfung aus FlexNow gelesen."
        default: return "\(count) angemeldete Prüfungen aus FlexNow gelesen."
        }
    }

    public static let notReached = "Die Liste „Aktuelle Prüfungen“ in FlexNow war gerade nicht lesbar. Bitte später erneut versuchen."
    public static let expired = "Die FlexNow-Anmeldung ist abgelaufen. Bitte erneut anmelden."

    /// `outerHTML` der Studentenschnittstelle lesen und speichern. Anmeldeseite: `needsLogin`, nichts geaendert. Liste
    /// nicht sicher erreicht: nichts gespeichert, nichts geloescht.
    public static func read(db: SQLiteDatabase, html: String, clock: UniFlowClock = .system) async -> QISRegistrationsSync.Report {
        let page = FlexNowParser.parse(html: html)
        let now = clock.nowISO
        guard !page.loginPage else {
            _ = try? await db.transaction { c in try QISRegistrationsSync.saveRun(c, at: now, ok: false, count: 0, message: expired) }
            return QISRegistrationsSync.Report(needsLogin: true, message: expired)
        }
        guard page.reached else {
            _ = try? await db.transaction { c in try QISRegistrationsSync.saveRun(c, at: now, ok: false, count: 0, message: notReached) }
            return QISRegistrationsSync.Report(message: notReached)
        }
        let rows = page.registrations
        let text = message(count: rows.count)
        do {
            try await db.transaction { c in
                try QISRegistrationsSync.store(c, rows, now: now)
                try QISRegistrationsSync.saveRun(c, at: now, ok: true, count: rows.count, message: text)
            }
        } catch {
            return QISRegistrationsSync.Report(message: QISGradesSync.describe(error))
        }
        return QISRegistrationsSync.Report(count: rows.count, message: text)
    }
}
