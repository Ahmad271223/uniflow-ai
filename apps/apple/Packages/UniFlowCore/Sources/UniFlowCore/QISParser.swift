import Foundation

// QIS (HIS QIS der LUH) direkt vom Geraet lesen: die App zeigt die echte QIS-Seite in einer Webansicht, der Nutzer
// meldet sich selbst an. Danach gibt die App das HTML der jeweils angezeigten Seite an `QISPage.parse` und folgt den
// gefundenen Links (Mein Studium -> Notenspiegel -> Abschluss -> Studiengang -> Leistungen). Dieselben Regeln wie
// app/qis.py (Kopfzeilen der Leistungstabelle, Zusammenfassung), Aufbau der Seiten in docs/QIS-STUDIP-STRUKTUR.md.
// Der Kern ruft selbst keine Seite auf und oeffnet keine Bescheinigung (jeder verpublish-Aufruf erzeugt ein Dokument).

// MARK: - Sitzung

/// Sitzungsparameter `asi` der gerade angezeigten QIS-Seite. Gilt nur fuer die laufende Anmeldung: absichtlich nicht
/// Codable, von aussen nicht lesbar und in Beschreibungen geschwaerzt, damit er weder gespeichert noch geloggt wird.
/// Entsteht nur in `QISPage.parse` aus dem HTML der aktuellen Seite.
public struct QISSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: String

    init?(token: String) {
        guard (1...128).contains(token.count), token.unicodeScalars.allSatisfy(QISSession.allowed.contains) else { return nil }
        self.token = token
    }

    /// Zeichen, die QIS in asi verwendet; alles andere wird verworfen (kein Einschleusen in die Adresse).
    static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~$-")

    public var description: String { "QISSession(asi: ***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - Links

/// Ein Link einer QIS-Seite. `address` ist absolut und ohne Sitzungsparameter (asi, jsessionid), darf also
/// gespeichert und verglichen werden; zum Aufrufen `QISPage.url(for:)` der aktuellen Seite verwenden.
public struct QISLink: Sendable, Hashable, Codable {
    /// sichtbarer Text, sonst title-Attribut, sonst alt-Text eines Bildes im Link
    public let text: String
    public let address: String
    /// Abfrageparameter ohne asi; Namen klein geschrieben, Werte dekodiert (z. B. "nodeid": "auswahlBaum|abschluss:abschl=82")
    public let parameters: [String: String]

    public var state: String? { parameters["state"] }

    /// Name des Studiengangs aus "Leistungen fuer <Studiengang> anzeigen", sonst nil.
    public var studiengang: String? {
        let lower = text.lowercased()
        for prefix in ["leistungen für ", "leistungen fuer "] where lower.hasPrefix(prefix) && lower.hasSuffix(" anzeigen") {
            let name = text.dropFirst(prefix.count).dropLast(" anzeigen".count)
            let clean = QISParser.clean(String(name))
            return clean.isEmpty ? nil : clean
        }
        return nil
    }

    var host: String? { URL(string: address)?.host?.lowercased() }
}

/// Bekannte Ziele auf den QIS-Seiten. "Pruefungsanmeldung/-abmeldung" gehoert bewusst nicht dazu.
public enum QISTarget: String, Sendable, CaseIterable {
    /// Startseite -> "Mein Studium" (moduleParameter=studyPOSMenu)
    case meinStudium
    /// Mein Studium -> "Notenspiegel / Studienverlauf" (state=notenspiegelStudent, next=tree.vm)
    case notenspiegel
    /// Studienverlauf (next=studienverlauf.vm); wird fuer die Noten nicht gebraucht
    case studienverlauf
    /// Baum: "Abschluss <Nr> <Name>" (nodeID=...|abschluss:..., aufklappen mit expand)
    case abschluss
    /// Baum: "Leistungen fuer <Studiengang> (PO-Version <Jahr>) anzeigen" (next=list.vm, nodeID=...|studiengang:...)
    case leistungen
    /// Startseite -> "Meine Bescheinigungen" (moduleParameter=studentReportsMenu)
    case bescheinigungen
    case logout
}

/// Link auf eine Bescheinigung (state=verpublish). Wird nur aufgelistet, nie aufgerufen.
public struct QISDocumentLink: Sendable, Hashable, Codable {
    public let title: String
    public let link: QISLink
}

// MARK: - Leistungen

/// Eine Zeile des Notenspiegels, Felder wie die Tabelle `grades` des PC-Servers (alles Text wie in QIS angezeigt).
public struct QISGrade: Sendable, Hashable, Codable {
    public var pruefungsnr: String?
    public var text: String
    public var semester: String?
    public var note: String?
    public var status: String?
    public var credits: String?
    public var versuch: String?
    public var datum: String?
    public var abschluss: String?
    /// alle Zellen der Zeile, mit " | " verbunden
    public var raw: String

    public init(pruefungsnr: String? = nil, text: String, semester: String? = nil, note: String? = nil, status: String? = nil,
                credits: String? = nil, versuch: String? = nil, datum: String? = nil, abschluss: String? = nil, raw: String = "") {
        self.pruefungsnr = pruefungsnr
        self.text = text
        self.semester = semester
        self.note = note
        self.status = status
        self.credits = credits
        self.versuch = versuch
        self.datum = datum
        self.abschluss = abschluss
        self.raw = raw
    }
}

/// Wie qis.summary(): Durchschnitt nach Credits gewichtet, Summe der Credits der benoteten Leistungen, Anzahl bestanden.
public struct QISGradeSummary: Sendable, Equatable {
    public let average: Double?
    public let credits: Double
    public let passed: Int
}

// MARK: - Seite

/// Eine gelesene QIS-Seite. Enthaelt die Sitzung und ist deshalb nicht Codable: nur fuer den naechsten Schritt
/// verwenden, nicht aufbewahren. Die Stammdaten-Tabelle wird schon beim Lesen verworfen.
public struct QISPage: Sendable {
    /// Adresse der Seite ohne Sitzungsparameter
    public let address: String
    public let title: String
    public let links: [QISLink]
    public let documents: [QISDocumentLink]
    /// Anmeldeformular (Passwortfeld) auf der Seite: Nutzer muss sich in der Webansicht selbst anmelden.
    public let hasLoginForm: Bool
    public let session: QISSession?
    let tables: [HTMLTable]

    public var isLoggedIn: Bool { link(.logout) != nil }

    public static func parse(html: String, url: URL) -> QISPage {
        let scan = HTMLScanner.scan(html)
        var base = url
        if let b = scan.base, let resolved = QISParser.resolve(b, base: url).flatMap(URL.init(string:)) { base = resolved }
        let pageHost = url.host?.lowercased()
        var tokens: [String] = []
        func note(_ token: String?) { if let t = token, QISSession(token: t) != nil { tokens.append(t) } }

        let (pageAddress, pageToken) = QISParser.stripSession(url.absoluteString)
        note(pageToken)
        var links: [QISLink] = []
        var documents: [QISDocumentLink] = []
        var seenDocs = Set<String>()
        for a in scan.anchors {
            guard let abs = QISParser.resolve(a.href, base: base) else { continue }
            let (address, token) = QISParser.stripSession(abs)
            let link = QISLink(text: a.label, address: address, parameters: QISParser.parameters(of: address))
            // asi nur von Links auf denselben Rechner uebernehmen
            if link.host == pageHost { note(token) }
            links.append(link)
            if link.state?.lowercased() == "verpublish", seenDocs.insert(address).inserted {
                documents.append(QISDocumentLink(title: QISParser.documentTitle(a), link: link))
            }
        }
        for action in scan.formActions {
            guard let abs = QISParser.resolve(action, base: base) else { continue }
            if URL(string: abs)?.host?.lowercased() == pageHost { note(QISParser.stripSession(abs).asi) }
        }
        scan.hiddenASI.forEach(note)
        // haeufigster Wert gewinnt, bei Gleichstand der zuerst gesehene
        var counts: [String: Int] = [:]
        tokens.forEach { counts[$0, default: 0] += 1 }
        let best = tokens.max { counts[$0]! < counts[$1]! || (counts[$0]! == counts[$1]! && tokens.firstIndex(of: $0)! > tokens.firstIndex(of: $1)!) }

        return QISPage(address: pageAddress, title: scan.h1 ?? scan.title, links: links, documents: documents,
                       hasLoginForm: scan.hasPassword, session: best.flatMap { QISSession(token: $0) },
                       tables: scan.tables.filter { !QISParser.isStammdaten($0) })
    }

    /// Alle Links zu einem Ziel, zuerst die ueber Parameter erkannten, dann die ueber den Text; ohne Doppelte.
    /// Nur Links auf denselben Rechner wie die Seite.
    public func links(_ target: QISTarget) -> [QISLink] {
        let host = URL(string: address)?.host?.lowercased()
        var seen = Set<String>()
        return links.compactMap { l -> (Int, QISLink)? in
            guard l.host == host, let p = QISParser.match(l, target) else { return nil }
            return (p, l)
        }
        .enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        .map(\.element.1)
        .filter { seen.insert($0.address).inserted }
    }

    public func link(_ target: QISTarget) -> QISLink? { links(target).first }

    /// Adresse zum Aufrufen: der Link mit dem asi dieser Seite. Nur fuer den sofortigen Aufruf, nicht speichern.
    /// Fuer fremde Rechner wird asi nie angehaengt.
    public func url(for link: QISLink) -> URL? {
        guard let session, link.host != nil, link.host == URL(string: address)?.host?.lowercased() else {
            return URL(string: link.address)
        }
        return URL(string: link.address + (link.address.contains("?") ? "&" : "?") + "asi=" + session.token)
    }

    /// Naechste Schritte Richtung Leistungen: Studiengaenge, sonst Abschluesse aufklappen, sonst Notenspiegel,
    /// sonst Mein Studium. Leer, wenn es auf dieser Seite nichts weiter gibt.
    /// `visited` (Adressen ohne asi) wird je Gruppe vorher entfernt: sind die Studiengaenge eines Abschlusses schon
    /// besucht, kommen die uebrigen Abschluesse dran. Ein Baumknoten, dessen nodeID schon besucht wurde oder unter
    /// dem schon ein Knoten besucht wurde, gilt als aufgeklappt und wird nicht erneut angeboten (kein Zuklappen).
    public func nextLinksTowardGrades(excluding visited: Set<String> = []) -> [QISLink] {
        let visitedNodes = visited.compactMap { QISParser.parameters(of: $0)["nodeid"]?.lowercased() }.filter { !$0.isEmpty }
        func isOpen(_ l: QISLink) -> Bool {
            guard !visited.contains(l.address) else { return false }
            guard let node = l.parameters["nodeid"]?.lowercased(), !node.isEmpty else { return true }
            return !visitedNodes.contains { $0 == node || $0.hasPrefix(node + ",") || $0.hasPrefix(node + "|") }
        }
        for t in [QISTarget.leistungen, .abschluss] {
            let l = links(t).filter(isOpen)
            if !l.isEmpty { return Array(l.prefix(10)) }
        }
        for t in [QISTarget.notenspiegel, .meinStudium] {
            if let l = links(t).first(where: isOpen) { return [l] }
        }
        return []
    }

    /// Anzahl der erkannten Leistungstabellen (Kopfzeile mit Pruefungstext und Note); 0 bei "keine Leistungen".
    public var gradeTableCount: Int { tables.filter { QISParser.headerRow(of: $0) != nil }.count }

    /// Leistungen aller Tabellen der Seite. `abschluss` wie in qis.py: Text des Links, ueber den die Seite erreicht
    /// wurde (eine eigene Spalte "Abschluss" hat Vorrang).
    public func grades(abschluss: String = "") -> [QISGrade] {
        QISParser.merge(tables.flatMap { QISParser.grades(in: $0, abschluss: abschluss) })
    }
}

// MARK: - Sammeln ueber mehrere Seiten

/// Sammelt beim Durchklicken die Leistungen und Bescheinigungs-Links mehrerer Seiten des QIS der LUH. Enthaelt kein
/// asi und darf gespeichert werden. Den Notenspiegel des LSF Hildesheim liest `LSFClient.grades` (Hildesheim/LearnwebAPI.swift).
public struct QISCollector: Sendable, Equatable, Codable {
    public private(set) var grades: [QISGrade] = []
    public private(set) var documents: [QISDocumentLink] = []
    /// besuchte Adressen (ohne asi), damit kein Link zweimal aufgerufen und kein Baumknoten wieder zugeklappt wird
    public private(set) var visited: Set<String> = []

    public init() {}

    /// Seite uebernehmen; `link` ist der Link, ueber den sie erreicht wurde (bestimmt den Abschluss der Leistungen).
    public mutating func absorb(_ page: QISPage, via link: QISLink? = nil) {
        visited.insert(page.address)
        if let link { visited.insert(link.address) }
        let abschluss = link.map { $0.studiengang ?? $0.text } ?? ""
        grades = QISParser.merge(grades + page.grades(abschluss: abschluss))
        var known = Set(documents.map(\.link.address))
        for d in page.documents where known.insert(d.link.address).inserted { documents.append(d) }
    }

    /// Noch nicht besuchte Links Richtung Leistungen auf dieser Seite (besuchte schon vor der Wahl der Gruppe entfernt).
    public func nextLinks(on page: QISPage) -> [QISLink] {
        page.nextLinksTowardGrades(excluding: visited)
    }

    public var summary: QISGradeSummary { QISParser.summary(grades) }

    public func apiJSON(fetchedAt: String? = nil, lastRun: JSONValue = .null) -> JSONValue {
        QISParser.apiJSON(grades: grades, documents: documents, fetchedAt: fetchedAt, lastRun: lastRun)
    }
}

// MARK: - Regeln

public enum QISParser {
    /// Kopfzeilen der Leistungstabelle wie GRADE_HEADERS in qis.py (erstes Wort, ohne Satzzeichen), dazu die
    /// Schreibweisen ohne Umlaut und die Spalte "Abschluss".
    static let gradeHeaders: [String: String] = [
        "prüfungsnr": "pruefungsnr", "pruefungsnr": "pruefungsnr", "prüfungsnummer": "pruefungsnr", "pruefungsnummer": "pruefungsnr",
        "nr": "pruefungsnr",
        "prüfungstext": "text", "pruefungstext": "text", "text": "text",
        "semester": "semester", "note": "note",
        "status": "status", "vermerk": "status",
        "credits": "credits", "ects": "credits", "bonus": "credits",
        "versuch": "versuch",
        "datum": "datum", "prüfungsdatum": "datum", "pruefungsdatum": "datum",
        "abschluss": "abschluss",
    ]

    /// Leerraum zusammenfassen (auch geschuetzte Leerzeichen), weiche Trennzeichen entfernen.
    public static func clean(_ s: String) -> String {
        s.unicodeScalars.contains { $0 == "\u{AD}" || $0 == "\u{200B}" }
            ? clean(String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\u{AD}" && $0 != "\u{200B}" })))
            : s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Stammdaten (Name, Geburtsdatum, Matrikelnummer, Anschrift) werden nie gelesen: Tabelle mit diesem summary
    /// oder mit typischen Stammdaten-Zeilen.
    static func isStammdaten(_ t: HTMLTable) -> Bool {
        if t.summary.lowercased().contains("stammdaten") { return true }
        let labels = ["matrikelnummer", "matrikelnr", "geburtsdatum", "geburtsort", "anschrift"]
        return t.rows.contains { row in row.contains { c in let l = c.text.lowercased(); return labels.contains { l.hasPrefix($0) } } }
    }

    static func headerKey(_ cell: String) -> String? {
        guard let first = cell.lowercased().split(separator: " ").first else { return nil }
        let word = String(first).filter { !".:;,*()-".contains($0) }
        return gradeHeaders[word]
    }

    /// Zellen mit colspan aufgefaechert, damit die Spalten zur Kopfzeile passen.
    static func spread(_ cells: [HTMLTableCell]) -> [String] {
        cells.flatMap { [$0.text] + Array(repeating: "", count: $0.colspan - 1) }
    }

    /// Kopfzeile (Index und Spaltenzuordnung) innerhalb der ersten Zeilen; qis.py prueft nur die erste Zeile,
    /// hier darf eine Ueberschrift-Zeile davor stehen.
    static func headerRow(of t: HTMLTable) -> (index: Int, keys: [String?], labels: [String])? {
        for (i, row) in t.rows.prefix(6).enumerated() {
            let labels = spread(row)
            let keys = labels.map(headerKey)
            if keys.contains("text"), keys.contains("note") { return (i, keys, labels) }
        }
        return nil
    }

    static func grades(in t: HTMLTable, abschluss: String) -> [QISGrade] {
        guard let header = headerRow(of: t) else { return [] }
        let textLabel = header.keys.firstIndex(of: "text").map { header.labels[$0].lowercased() }
        var out: [QISGrade] = []
        for row in t.rows.dropFirst(header.index + 1) {
            let tds = row.filter { !$0.isHeader }
            guard tds.count >= 3 else { continue }
            var rec: [String: String] = [:]
            for (k, v) in zip(header.keys, spread(tds)) { if let k, rec[k] == nil { rec[k] = v } }
            guard let text = rec["text"], !text.isEmpty, text.lowercased() != textLabel else { continue }
            let own = rec["abschluss"].flatMap { $0.isEmpty ? nil : $0 }
            out.append(QISGrade(pruefungsnr: rec["pruefungsnr"], text: text, semester: rec["semester"], note: rec["note"],
                                status: rec["status"], credits: rec["credits"], versuch: rec["versuch"], datum: rec["datum"],
                                abschluss: own ?? abschluss, raw: tds.map(\.text).joined(separator: " | ")))
        }
        return out
    }

    /// Doppelte entfernen wie fetch_grades: gleiche Pruefungsnr., Text, Semester und Versuch; die erste bleibt.
    public static func merge(_ grades: [QISGrade]) -> [QISGrade] {
        var seen = Set<[String?]>()
        return grades.filter { seen.insert([$0.pruefungsnr, $0.text, $0.semester, $0.versuch]).inserted }
    }

    /// Zahl wie float(str(x).replace(",", ".")) in Python; nil, wenn das nicht ginge.
    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
        return Double(t)
    }

    /// Wie qis.summary(): jede Note von 1,0 bis 5,0 zaehlt (die Status-Bedingung dort trifft immer zu), gewichtet
    /// nach Credits; ohne Credits einfacher Mittelwert. Gerundet auf zwei Stellen wie round(x, 2). Summen wie Pythons
    /// `sum()` (kompensiert, `PyMath.sum`) in Zeilenreihenfolge: mit einfacher Summe lag der Schnitt an Rundungsgrenzen
    /// x,xx5 um 0,01 neben dem PC (2,7249999… statt 2,725).
    public static func summary(_ grades: [QISGrade]) -> QISGradeSummary {
        var graded: [(n: Double, c: Double)] = []
        for g in grades {
            guard let n = number(g.note ?? "") else { continue }
            let cs = (g.credits ?? "").isEmpty ? "0" : g.credits!
            guard let c = number(cs) else { continue }
            if n >= 1.0, n <= 5.0 { graded.append((n, c)) }
        }
        let cp = PyMath.sum(graded.map(\.c))
        let avg: Double?
        if cp != 0 { avg = round2(PyMath.sum(graded.map { $0.n * $0.c }) / cp) }
        else if !graded.isEmpty { avg = round2(PyMath.sum(graded.map(\.n)) / Double(graded.count)) }
        else { avg = nil }
        let passed = grades.filter { ($0.status ?? "").lowercased().hasPrefix("be") }.count
        return QISGradeSummary(average: avg, credits: cp, passed: passed)
    }

    /// Wie round(x, 2) in Python: rundet den exakten Binaerwert (1.075 ist binaer etwas kleiner -> 1.07), nicht x*100.
    /// printf rundet ebenfalls den exakten Wert, Gleichstand zur geraden Ziffer (0.125 -> 0.12); ohne Locale immer ".".
    static func round2(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.2f", x)) ?? x
    }

    /// Ergebnis im Format von GET /api/grades des PC-Servers (grades sortiert wie "ORDER BY semester DESC, text"),
    /// damit die Ansicht "Uni & Noten" es unveraendert anzeigen kann.
    /// Bescheinigungen weichen bewusst ab: der PC liefert gespeicherte PDFs (id, title, local_path, fetched_at), hier
    /// gibt es nur Links (QIS-Adresse ohne asi in "url", kein local_path). Reihenfolge wie "ORDER BY id DESC" (zuletzt
    /// gefundene zuerst). Die id ist Text "device-<n>" (n = Fundreihenfolge ab 1) und dazu "source": "device", damit
    /// sie nie mit einer PC-id verwechselt und nicht an /api/qis/documents/{id} geschickt wird.
    public static func apiJSON(grades: [QISGrade], documents: [QISDocumentLink] = [], fetchedAt: String? = nil,
                               lastRun: JSONValue = .null) -> JSONValue {
        func s(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }
        func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
        let rows = merge(grades).enumerated().sorted { x, y in
            let (a, b) = (x.element, y.element)
            if a.semester != b.semester {
                guard let sa = a.semester else { return false }      // NULL zuletzt (SQLite DESC)
                guard let sb = b.semester else { return true }
                return less(sb, sa)
            }
            if a.text != b.text { return less(a.text, b.text) }
            return x.offset < y.offset
        }
        let gradeJSON: [JSONValue] = rows.map { (i, g) in
            ["id": .number(Double(i + 1)), "pruefungsnr": s(g.pruefungsnr), "text": .string(g.text), "semester": s(g.semester),
             "note": s(g.note), "status": s(g.status), "credits": s(g.credits), "versuch": s(g.versuch), "datum": s(g.datum),
             "abschluss": s(g.abschluss), "raw": .string(g.raw), "fetched_at": s(fetchedAt)]
        }
        var seen = Set<String>()
        let docJSON: [JSONValue] = documents.filter { seen.insert($0.link.address).inserted }.enumerated().reversed().map { (i, d) in
            ["id": .string("device-\(i + 1)"), "source": "device", "title": .string(d.title), "url": .string(d.link.address),
             "fetched_at": s(fetchedAt)]
        }
        let sum = summary(merge(grades))
        return ["grades": .array(gradeJSON), "average": sum.average.map(JSONValue.number) ?? .null,
                "credits": .number(sum.credits), "passed": .number(Double(sum.passed)), "last_run": lastRun,
                "documents": .array(docJSON)]
    }

    // MARK: Zuordnung der Links

    /// 0 = ueber Parameter erkannt, 1 = ueber den Text, nil = passt nicht.
    static func match(_ l: QISLink, _ target: QISTarget) -> Int? {
        let p = l.parameters
        let t = l.text.lowercased()
        let state = p["state"]?.lowercased() ?? ""
        let next = p["next"]?.lowercased() ?? ""
        let module = p["moduleparameter"]?.lowercased() ?? ""
        let node = p["nodeid"]?.lowercased() ?? ""
        let addr = l.address.lowercased()
        let isLogout = t == "logout" || t == "abmelden" || addr.contains("logout") || (state == "user" && p["type"] == "4")
        if target == .logout {
            return (addr.contains("logout") || (state == "user" && p["type"] == "4")) ? 0 : (isLogout ? 1 : nil)
        }
        if isLogout { return nil }
        let isPDF = state == "verpublish" || t.hasPrefix("pdf") || addr.contains(".pdf")
        switch target {
        case .meinStudium:
            return module == "studyposmenu" ? 0 : (t == "mein studium" ? 1 : nil)
        case .bescheinigungen:
            return module == "studentreportsmenu" ? 0 : (t == "meine bescheinigungen" ? 1 : nil)
        case .notenspiegel:
            guard !isPDF, node.isEmpty, !next.contains("studienverlauf") else { return nil }
            if state == "notenspiegelstudent", next == "tree.vm" { return 0 }
            return t.contains("notenspiegel") ? 1 : nil
        case .studienverlauf:
            return next.contains("studienverlauf") ? 0 : (t == "studienverlauf" ? 1 : nil)
        case .abschluss:
            guard !isPDF, state == "notenspiegelstudent", next != "list.vm", !node.contains("studiengang:") else { return nil }
            if node.contains("abschluss:") { return 0 }
            return t.hasPrefix("abschluss ") ? 1 : nil
        case .leistungen:
            guard !isPDF else { return nil }
            if next == "list.vm", node.contains("studiengang:") { return 0 }
            return l.studiengang != nil ? 1 : nil
        case .logout:
            return nil
        }
    }

    // MARK: Adressen

    /// Absolute Adresse eines href (mit dekodierten Entities); nil fuer javascript:, mailto:, Anker und Nicht-HTTP.
    static func resolve(_ href: String, base: URL) -> String? {
        let h = href.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" }.trimmingCharacters(in: .whitespaces)
        let low = h.lowercased()
        guard !h.isEmpty, !h.hasPrefix("#"),
              !["javascript:", "mailto:", "data:", "tel:"].contains(where: low.hasPrefix) else { return nil }
        guard let u = URL(string: escapeUnsafe(h), relativeTo: base) else { return nil }
        let abs = u.absoluteString
        return abs.lowercased().hasPrefix("http://") || abs.lowercased().hasPrefix("https://") ? abs : nil
    }

    private static let safeASCII = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#@!$&'()*+,;=".utf8)
    private static let hex = Set("0123456789ABCDEFabcdef".utf8)

    /// Zeichen, die URL(string:) ablehnt (|, Leerzeichen, Umlaute, einzelnes %), prozentkodieren.
    static func escapeUnsafe(_ s: String) -> String {
        let b = Array(s.utf8)
        var out = ""
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "%"), i + 2 < b.count, hex.contains(b[i + 1]), hex.contains(b[i + 2]) {
                out.append("%")
            } else if safeASCII.contains(c) {
                out.append(Character(Unicode.Scalar(c)))
            } else {
                out.append(String(format: "%%%02X", c))
            }
            i += 1
        }
        return out
    }

    /// Adresse ohne asi/jsessionid (Abfrage) und ohne ;jsessionid (Pfad) und Anker; dazu der gefundene asi-Wert.
    static func stripSession(_ abs: String) -> (address: String, asi: String?) {
        var s = abs
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        var query: Substring?
        if let q = s.firstIndex(of: "?") { query = s[s.index(after: q)...]; s = String(s[..<q]) }
        while let r = s.range(of: ";jsessionid=", options: .caseInsensitive) {
            let end = s[r.upperBound...].firstIndex(of: "/") ?? s.endIndex
            s.removeSubrange(r.lowerBound..<end)
        }
        var asi: String?
        var kept: [Substring] = []
        for item in query?.split(separator: "&") ?? [] {
            let name = decode(String(item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])).lowercased()
            if name == "asi" {
                if asi == nil, let eq = item.firstIndex(of: "=") { asi = decode(String(item[item.index(after: eq)...])) }
            } else if name != "jsessionid" {
                kept.append(item)
            }
        }
        return (kept.isEmpty ? s : s + "?" + kept.joined(separator: "&"), asi)
    }

    static func decode(_ s: String) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    static func parameters(of address: String) -> [String: String] {
        guard let q = address.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for item in address[address.index(after: q)...].split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decode(String(kv[0])).lowercased()
            if !name.isEmpty, out[name] == nil { out[name] = kv.count > 1 ? decode(String(kv[1])) : "" }
        }
        return out
    }

    // MARK: Titel der Bescheinigungen

    /// Wie _clean_title in qis.py: "PDF-" vorne und "zum Drucken"/"anzeigen"/"drucken" hinten weg, hoechstens 90 Zeichen.
    public static func cleanTitle(_ raw: String) -> String {
        var t = clean(raw)
        if t.lowercased().hasPrefix("pdf") {
            t = String(t.dropFirst(3))
            if t.hasPrefix("-") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
        }
        for suffix in ["zum drucken", "anzeigen", "drucken"] where t.lowercased().hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if t.hasSuffix("–") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        let short = String(t.prefix(90))
        return short.isEmpty ? "Dokument" : short
    }

    /// Titel wie _click_pdf_links (Linktext, title, sonst Text von closest('td,li,p,div,span')): zuerst Linktext,
    /// dann umgebende Bloecke innerhalb der Zelle (innerster zuerst), dann Zelle und Zeile, dann Bloecke um die
    /// Tabelle. Sehr lange Bloecke (Layout um die ganze Seite) sind kein Titel.
    static func documentTitle(_ a: HTMLAnchor) -> String {
        let inner = a.innerBlockTexts.filter { $0.count <= 200 }
        let outer = a.outerBlockTexts.filter { $0.count <= 200 }
        for candidate in [a.label] + inner + [a.cellText, a.rowText] + outer {
            let t = cleanTitle(candidate)
            if !["pdf", "dokument"].contains(t.lowercased()) { return t }
        }
        return "Dokument"
    }

    // MARK: Entities

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "shy": "\u{AD}",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "Eacute": "É", "ccedil": "ç", "oacute": "ó",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•", "sect": "§", "para": "¶", "deg": "°",
        "copy": "©", "reg": "®", "euro": "€", "times": "×", "laquo": "«", "raquo": "»",
        "bdquo": "„", "ldquo": "“", "rdquo": "”", "sbquo": "‚", "lsquo": "‘", "rsquo": "’",
        "frac12": "½", "sup2": "²", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}",
    ]

    /// Windows-1252 statt C1-Steuerzeichen bei &#128;-&#159; (wie Browser)
    static let cp1252: [UInt32: UInt32] = [0x80: 0x20AC, 0x82: 0x201A, 0x84: 0x201E, 0x85: 0x2026, 0x8B: 0x2039,
                                           0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022,
                                           0x96: 0x2013, 0x97: 0x2014, 0x99: 0x2122, 0x9B: 0x203A]

    /// HTML-Entities (benannt, dezimal, hexadezimal) mit abschliessendem Semikolon dekodieren; Unbekanntes bleibt.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let sc = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < sc.count {
            if sc[i] == "&" {
                var j = i + 1
                while j < sc.count, j - i <= 32, sc[j].isASCII, sc[j] == "#" || CharacterSet.alphanumerics.contains(sc[j]) { j += 1 }
                if j < sc.count, sc[j] == ";", j > i + 1, let r = entity(String(String.UnicodeScalarView(sc[(i + 1)..<j]))) {
                    out.append(contentsOf: r.unicodeScalars)
                    i = j + 1
                    continue
                }
            }
            out.append(sc[i])
            i += 1
        }
        return String(out)
    }

    static func entity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name] }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" { value = UInt32(digits.dropFirst(), radix: 16) }
        else { value = UInt32(digits, radix: 10) }
        guard var v = value else { return nil }
        if let w = cp1252[v] { v = w }
        guard v != 0, let u = Unicode.Scalar(v) else { return "\u{FFFD}" }
        return String(Character(u))
    }
}

// MARK: - Tabellen und Links einer Seite

// QIS liefert kein wohlgeformtes HTML (offene td/tr, Layout-Tabellen ineinander). Aus den Bausteinen von
// `HTMLTokenizer` entstehen die Tabellen (Text je Zelle, innerste Tabelle bekommt den Text) und die Links; Inhalt von
// script/style faellt weg, der Seitentitel bleibt.

struct HTMLTableCell: Sendable, Equatable {
    let text: String
    let isHeader: Bool
    let colspan: Int
}

struct HTMLTable: Sendable, Equatable {
    let summary: String
    let rows: [[HTMLTableCell]]
}

struct HTMLAnchor: Sendable {
    let href: String
    /// Text, sonst title-Attribut, sonst alt eines Bildes
    let label: String
    /// Text der umgebenden Tabellenzelle und der ganzen Zeile (beides leer in Stammdaten-Tabellen)
    let cellText: String
    let rowText: String
    /// Text der umgebenden Bloecke (li, p, div, span), innerster zuerst: innerhalb der Zelle des Links bzw. ausserhalb
    /// jeder Tabelle (`inner`) und um die Tabelle herum (`outer`). Ohne Text aus Stammdaten-Tabellen.
    var innerBlockTexts: [String] = []
    var outerBlockTexts: [String] = []
}

struct HTMLScan: Sendable {
    var tables: [HTMLTable] = []
    var anchors: [HTMLAnchor] = []
    var formActions: [String] = []
    var hiddenASI: [String] = []
    var base: String?
    var title = ""
    var h1: String?
    var hasPassword = false
}

enum HTMLScanner {
    final class CellBuilder {
        let isHeader: Bool
        let colspan: Int
        var parts: [String] = []
        init(isHeader: Bool, colspan: Int) { self.isHeader = isHeader; self.colspan = colspan }
        var text: String { QISParser.clean(parts.joined()) }
    }

    final class TableBuilder {
        let summary: String
        let order: Int
        /// umgebende Tabelle (verschachtelte Layout-Tabellen)
        let parent: TableBuilder?
        var rows: [[CellBuilder]] = []
        var rowOpen = false
        var cell: CellBuilder?
        var finished: HTMLTable?
        init(summary: String, order: Int, parent: TableBuilder?) { self.summary = summary; self.order = order; self.parent = parent }

        func startRow() { endRow(); rowOpen = true; rows.append([]) }
        func endRow() { cell = nil; rowOpen = false }
        func startCell(header: Bool, colspan: Int) {
            cell = nil
            if !rowOpen { startRow() }
            let c = CellBuilder(isHeader: header, colspan: colspan)
            rows[rows.count - 1].append(c)
            cell = c
        }
        func finish() -> HTMLTable {
            let t = HTMLTable(summary: QISParser.clean(summary),
                              rows: rows.map { $0.map { HTMLTableCell(text: $0.text, isHeader: $0.isHeader, colspan: $0.colspan) } }
                                  .filter { !$0.isEmpty })
            finished = t
            return t
        }
    }

    final class AnchorBuilder {
        let href: String
        let title: String
        weak var cell: CellBuilder?
        weak var table: TableBuilder?
        let row: Int?
        var parts: [String] = []
        var images: [String] = []
        /// offene Bloecke beim Start des Links, innerster zuerst (ohne ul/ol)
        var blocks: [BlockBuilder] = []
        init(href: String, title: String, table: TableBuilder?) {
            self.href = href; self.title = title; self.cell = table?.cell; self.table = table
            row = table.flatMap { $0.rowOpen ? $0.rows.count - 1 : nil }
        }
    }

    /// Offenes li/p/div/span (und ul/ol, nur fuer das Schliessen von li). Sammelt allen Text darin, je Teil mit der
    /// innersten Tabelle, damit Text aus Stammdaten-Tabellen spaeter verworfen werden kann.
    final class BlockBuilder {
        let name: String
        /// Zelle, in der der Block geoeffnet wurde (nil ausserhalb von Zellen); endet die Zelle, endet auch der Block
        let cell: CellBuilder?
        var parts: [(text: String, table: TableBuilder?)] = []
        init(name: String, cell: CellBuilder?) { self.name = name; self.cell = cell }
        var isList: Bool { name == "ul" || name == "ol" }
    }

    final class Builder {
        var scan = HTMLScan()
        var stack: [TableBuilder] = []
        var done: [TableBuilder] = []
        var all: [TableBuilder] = []         // haelt die Zellen fuer die Links am Leben
        var anchors: [AnchorBuilder] = []
        var open: AnchorBuilder?
        var h1Parts: [String]?
        var counter = 0
        /// offene Bloecke, aeusserster zuerst
        var blocks: [BlockBuilder] = []

        /// Text mit dekodierten Entities (`HTMLToken.text`)
        func text(_ t: String) {
            stack.last?.cell?.parts.append(t)
            open?.parts.append(t)
            h1Parts?.append(t)
            if !blocks.isEmpty {
                let table = stack.last
                for b in blocks { b.parts.append((t, table)) }
            }
        }

        func space() { text(" ") }

        func openBlock(_ name: String) {
            guard blocks.count < 64 else { return }
            blocks.append(BlockBuilder(name: name, cell: stack.last?.cell))
        }

        /// Zuletzt geoeffneten Block `name` samt allem darin schliessen, ausser danach wurde einer der `stoppers`
        /// geoeffnet (ein li schliesst kein li einer aeusseren Liste).
        func closeBlock(_ name: String, unless stoppers: Set<String> = []) {
            guard let i = blocks.lastIndex(where: { $0.name == name }),
                  !blocks[(i + 1)...].contains(where: { stoppers.contains($0.name) }) else { return }
            blocks.removeSubrange(i...)
        }

        /// Zelle endet: darin geoeffnete Bloecke enden mit ihr (offene div/li in QIS-Tabellen).
        func closeBlocks(in cell: CellBuilder?) {
            guard let cell else { return }
            blocks.removeAll { $0.cell === cell }
        }

        static let blockStoppers: Set<String> = ["div", "li", "ul", "ol"]

        func start(_ name: String, _ attrs: [String: String]) {
            switch name {
            case "table":
                let t = TableBuilder(summary: attrs["summary"] ?? "", order: counter, parent: stack.last)
                counter += 1
                stack.append(t)
                all.append(t)
            case "tr":
                let before = stack.last?.cell
                stack.last?.startRow()
                closeBlocks(in: before)
            case "td", "th":
                let before = stack.last?.cell
                stack.last?.startCell(header: name == "th", colspan: min(max(Int(attrs["colspan"] ?? "") ?? 1, 1), 20))
                closeBlocks(in: before)
            case "a":
                closeAnchor()
                if let href = attrs["href"] {
                    let a = AnchorBuilder(href: href, title: attrs["title"] ?? "", table: stack.last)
                    a.blocks = blocks.reversed().filter { !$0.isList }
                    anchors.append(a)
                    open = a
                }
            case "img":
                if let a = open { a.images.append(attrs["alt"] ?? attrs["title"] ?? "") }
            case "li":
                closeBlock("li", unless: ["ul", "ol"])
                space()
                openBlock("li")
            case "p", "div":
                closeBlock("p", unless: Builder.blockStoppers)
                space()
                openBlock(name)
            case "ul", "ol":
                closeBlock("p", unless: Builder.blockStoppers)
                openBlock(name)
            case "span":
                openBlock("span")
            case "br", "hr":
                space()
            case "input":
                let type = (attrs["type"] ?? "").lowercased()
                let n = (attrs["name"] ?? "").lowercased()
                if n == "asi", let v = attrs["value"] { scan.hiddenASI.append(v) }
                if type == "password" || n == "fdsa" { scan.hasPassword = true }
            case "form":
                if let a = attrs["action"] { scan.formActions.append(a) }
            case "base":
                if scan.base == nil, let h = attrs["href"] { scan.base = h }
            case "h1":
                if scan.h1 == nil, h1Parts == nil { h1Parts = [] }
            default: break
            }
        }

        func end(_ name: String) {
            switch name {
            case "table":
                if let t = stack.popLast() { closeBlocks(in: t.cell); _ = t.finish(); done.append(t) }
            case "tr":
                closeBlocks(in: stack.last?.cell)
                stack.last?.endRow()
            case "td", "th":
                closeBlocks(in: stack.last?.cell)
                stack.last?.cell = nil
            case "a": closeAnchor()
            case "li":
                space()
                closeBlock("li", unless: ["ul", "ol"])
            case "p", "div":
                space()
                closeBlock(name)
            case "span", "ul", "ol":
                closeBlock(name)
            case "h1":
                if let p = h1Parts {
                    let t = QISParser.clean(p.joined())
                    if !t.isEmpty { scan.h1 = t }
                    h1Parts = nil
                }
            default: break
            }
        }

        func closeAnchor() { open = nil }

        func result() -> HTMLScan {
            while let t = stack.popLast() { _ = t.finish(); done.append(t) }
            scan.tables = done.sorted { $0.order < $1.order }.compactMap(\.finished)
            // Stammdaten-Tabellen samt allen darin verschachtelten Tabellen
            func inStammdaten(_ t: TableBuilder) -> Bool {
                var x: TableBuilder? = t
                while let y = x { if y.finished.map(QISParser.isStammdaten) ?? false { return true }; x = y.parent }
                return false
            }
            let secret = Set(all.filter(inStammdaten).map(ObjectIdentifier.init))
            func isSecret(_ t: TableBuilder?) -> Bool { t.map { secret.contains(ObjectIdentifier($0)) } ?? false }
            scan.anchors = anchors.map { a in
                var label = QISParser.clean(a.parts.joined())
                if label.isEmpty { label = QISParser.clean(a.title) }
                if label.isEmpty { label = QISParser.clean(a.images.joined(separator: " ")) }
                guard !isSecret(a.table) else { return HTMLAnchor(href: a.href, label: label, cellText: "", rowText: "") }
                var inner: [String] = []
                var outer: [String] = []
                for b in a.blocks {
                    let t = QISParser.clean(b.parts.filter { !isSecret($0.table) }.map(\.text).joined())
                    if b.cell === a.cell { inner.append(t) } else { outer.append(t) }
                }
                guard let t = a.table else {
                    return HTMLAnchor(href: a.href, label: label, cellText: "", rowText: "", innerBlockTexts: inner, outerBlockTexts: outer)
                }
                let row = a.row.map { QISParser.clean(t.rows[$0].map(\.text).joined(separator: " ")) } ?? ""
                return HTMLAnchor(href: a.href, label: label, cellText: a.cell?.text ?? "", rowText: row,
                                  innerBlockTexts: inner, outerBlockTexts: outer)
            }
            return scan
        }
    }

    static func scan(_ html: String) -> HTMLScan {
        let builder = Builder()
        for t in HTMLTokenizer.tokens(html) {
            switch t {
            case .start(let name, let attrs): builder.start(name, attrs)
            case .end(let name): builder.end(name)
            case .text(let s): builder.text(s)
            case .raw(let name, let s):
                if name == "title", builder.scan.title.isEmpty { builder.scan.title = QISParser.clean(QISParser.decodeEntities(s)) }
            }
        }
        return builder.result()
    }
}
