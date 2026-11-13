import Foundation

// "Im QIS zur Prüfung anmelden" fuehrt direkt zum Modul (Wunsch des Inhabers 13.11.2026). Das QIS der LUH hat keine
// festen Adressen fuer eine Pruefung: jeder Link traegt den Sitzungsparameter asi, und der Zustand des Anmeldebaums
// (welche Zweige offen sind) liegt in der Sitzung des Servers. Darum geht der In-App-Browser den Weg wie ein Mensch:
// Startseite -> "Mein Studium" -> "Prüfungsanmeldung/-abmeldung" (Hinweisseite) -> Baum, klappt die Zweige auf, bis das
// Modul bzw. die Pruefung zu sehen ist, und markiert die Zeile. Dieser Teil entscheidet nur, welcher Link als Naechstes
// geoeffnet wird; die App (UniWebView.swift, `QISRegistrationGuideRunner`) laedt ihn und markiert.
//
// Harte Regeln (Inhaber): Nie selbst anmelden, abmelden oder Logout. Gefolgt wird nur
//  - "Mein Studium" (moduleParameter=studyPOSMenu),
//  - dem Menuepunkt "Prüfungsanmeldung/-abmeldung" (state=info, moduleParameter=prfAnmStudent, next=info.vm: nur Hinweise),
//  - einem Link in den Anmeldebaum ohne Knoten (state=prfAnmStudent, next=tree.vm, ohne nodeID) und
//  - Baumknoten zum Aufklappen (state=prfAnmStudent, nodeID, expand=0, next=tree.vm).
// Nie: Zuklappen (expand=1), Links mit "anmelden", "abmelden", "Rücktritt", "Logout", "Storno", "bestätigen",
// "akzeptieren", PDF/Bescheinigungen, nie ein Formular (Hinweise bestaetigen tut der Mensch), nie ein anderer Rechner.
// Gelesen wird nur die Struktur der Seite (Links), keine Namen, Matrikelnummern oder Passwoerter; asi wird nie gespeichert
// (`QISLink.address` ist ohne asi, `QISPage.url(for:)` haengt ihn nur fuer den sofortigen Aufruf an).
//
// Die echte Seite des Anmeldebaums war bis 13.11.2026 nicht zu sehen (nur "Info über angemeldete Prüfungen",
// docs/PRUEFUNGSANMELDUNG-2026-11-05.md); der Aufbau folgt dem echten Baum dort (gleiche Parameter, `state` anders).
// Findet der Weg nichts Passendes, haelt er an und sagt es (`notFound`, `unknown`): der Mensch klappt selbst auf.

/// Was im Anmeldebaum gesucht wird: Titel des Moduls (aus dem Studienverlauf) und, wenn bekannt, die Pruefungsnummer
public struct QISRegistrationTarget: Sendable, Equatable, Hashable, Codable {
    public let title: String
    public let nr: String?

    public init(title: String, nr: String? = nil) {
        self.title = title
        let n = nr?.trimmingCharacters(in: .whitespaces) ?? ""
        self.nr = n.isEmpty ? nil : n
    }
}

public enum QISRegistrationGuide {
    /// Gefundene Zeile: Link (Adresse ohne asi, wie `QISLink.address`) und sein Text
    public struct Highlight: Sendable, Equatable {
        public let address: String
        public let text: String
    }

    public enum Step: Sendable, Equatable {
        /// diesen Link laden (GET; Menue oder Baumknoten, nie eine Handlung)
        case follow(URL)
        /// gefunden: markieren; anmelden tut der Mensch
        case highlight(Highlight)
        /// Anmeldeseite des QIS: der Mensch meldet sich an (Autofill), danach geht es weiter
        case login
        /// Hinweisseite der Pruefungsanmeldung ohne Link weiter (Formular, Haken): der Mensch bestaetigt selbst
        case confirmNotice
        /// Baum ganz aufgeklappt bzw. Schrittgrenze erreicht, ohne Treffer
        case notFound
        /// Seite unbekannt (anderer Rechner, Fehlerseite): anhalten
        case unknown
    }

    /// Fortschritt eines Durchlaufs (nur Adressen ohne asi und nodeIDs, nichts Persoenliches)
    public struct Progress: Sendable, Equatable {
        /// geoeffnete Adressen (ohne asi): nie zweimal derselbe Menue-Link
        public var followed: Set<String> = []
        /// aufgeklappte Baumknoten (nodeID, klein)
        public var expanded: Set<String> = []
        public var steps = 0

        public init() {}
    }

    /// hoechstens so viele Seiten je Suche (der Baum eines Studiengangs hat selten mehr als 30 Zweige)
    public static let maxSteps = 40

    /// Woerter in Linktexten, denen nie gefolgt wird (Handlungen)
    static let actionWords = ["anmelden", "abmelden", "rücktritt", "ruecktritt", "logout", "storn", "bestätig", "bestaetig",
                              "akzeptier", "löschen", "pdf", "drucken"]

    /// Naechster Schritt fuer die angezeigte Seite. `progress` merkt sich, was schon geoeffnet ist.
    public static func step(html: String, url: URL, target: QISRegistrationTarget,
                            progress: inout Progress) -> Step {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return .unknown }
        let page = QISPage.parse(html: html, url: url)
        if page.hasLoginForm { return .login }
        let own = page.links.filter { $0.host == host }

        // 1. Anmeldebaum: Treffer markieren bzw. sein Zweig aufklappen, sonst den naechsten Zweig
        let nodes = own.filter(isTreeNode)
        if !nodes.isEmpty {
            if let best = bestMatch(nodes, target) {
                let node = nodeID(best)
                if best.parameters["expand"] == "0", !progress.expanded.contains(node), progress.steps < maxSteps,
                   let next = page.url(for: best) {
                    progress.expanded.insert(node)
                    progress.steps += 1
                    return .follow(next)
                }
                return .highlight(Highlight(address: best.address, text: QISParser.clean(best.text)))
            }
            guard progress.steps < maxSteps else { return .notFound }
            let open = nodes.filter { $0.parameters["expand"] == "0" && !isExpanded(nodeID($0), progress.expanded) }
            // Zweige, deren Text Woerter des Moduls teilt, zuerst; sonst flache vor tiefen (Bereiche vor Modulen), dann
            // Reihenfolge der Seite
            let ordered = open.enumerated().sorted { a, b in
                let ka = (sharesWords(a.element.text, target) ? 0 : 1, depth(a.element), a.offset)
                let kb = (sharesWords(b.element.text, target) ? 0 : 1, depth(b.element), b.offset)
                return ka < kb
            }.map(\.element)
            guard let next = ordered.first, let u = page.url(for: next) else { return .notFound }
            progress.expanded.insert(nodeID(next))
            progress.steps += 1
            return .follow(u)
        }

        // 2. Hinweisseite bzw. Einstieg: Link in den Baum (ohne Knoten)
        if let entry = own.first(where: { isTreeEntry($0) && !progress.followed.contains($0.address) }) {
            return follow(entry, page, &progress)
        }
        if isNoticePage(url) { return .confirmNotice }

        // 3. Menue: "Prüfungsanmeldung/-abmeldung", sonst "Mein Studium"
        if let menu = own.first(where: { isRegistrationMenu($0) && !progress.followed.contains($0.address) }) {
            return follow(menu, page, &progress)
        }
        if let studium = page.links(.meinStudium).first(where: { !progress.followed.contains($0.address) && !hasActionWord($0) }) {
            return follow(studium, page, &progress)
        }
        return .unknown
    }

    private static func follow(_ l: QISLink, _ page: QISPage, _ progress: inout Progress) -> Step {
        guard progress.steps < maxSteps, let u = page.url(for: l) else { return .notFound }
        progress.followed.insert(l.address)
        progress.steps += 1
        return .follow(u)
    }

    // MARK: Links

    static func hasActionWord(_ l: QISLink) -> Bool {
        let t = l.text.lowercased()
        return actionWords.contains { t.contains($0) }
    }

    static func param(_ l: QISLink, _ name: String) -> String { l.parameters[name]?.lowercased() ?? "" }

    static func nodeID(_ l: QISLink) -> String { param(l, "nodeid") }

    /// Tiefe eines Knotens (Zahl der Glieder der nodeID)
    static func depth(_ l: QISLink) -> Int { nodeID(l).split(separator: "|").count }

    /// Menuepunkt "Prüfungsanmeldung/-abmeldung": nur die Hinweisseite (state=info, next=info.vm)
    public static func isRegistrationMenu(_ l: QISLink) -> Bool {
        param(l, "state") == "info" && param(l, "moduleparameter") == "prfanmstudent" && param(l, "next") == "info.vm"
            && param(l, "type").isEmpty
    }

    /// Link von der Hinweisseite in den Anmeldebaum (ohne Knoten, ohne Handlung)
    public static func isTreeEntry(_ l: QISLink) -> Bool {
        param(l, "state") == "prfanmstudent" && param(l, "next").hasPrefix("tree") && nodeID(l).isEmpty
            && param(l, "expand").isEmpty && !hasActionWord(l) && l.parameters.keys.allSatisfy(allowedTreeParameters.contains)
    }

    /// Baumknoten der Pruefungsanmeldung (Auf- oder Zuklappen); nur solche werden geoeffnet bzw. markiert
    public static func isTreeNode(_ l: QISLink) -> Bool {
        param(l, "state") == "prfanmstudent" && !nodeID(l).isEmpty && ["0", "1"].contains(param(l, "expand"))
            && param(l, "next").hasPrefix("tree") && !hasActionWord(l) && l.parameters.keys.allSatisfy(allowedTreeParameters.contains)
    }

    /// Parameter eines Baumlinks; alles andere (z. B. eine Pruefungsnummer zum Anmelden) gehoert zu einer Handlung
    static let allowedTreeParameters: Set<String> = ["state", "struct", "navigation", "next", "nextdir", "nodeid", "expand",
                                                     "laststate", "menuid", "breadcrumb", "breadcrumbsource",
                                                     "menu_open", "topitem", "subitem"]

    /// Hinweisseite der Pruefungsanmeldung (Adresse der angezeigten Seite)
    static func isNoticePage(_ url: URL) -> Bool {
        let p = QISParser.parameters(of: QISParser.stripSession(url.absoluteString).address)
        return p["state"]?.lowercased() == "info" && p["moduleparameter"]?.lowercased() == "prfanmstudent"
    }

    /// Zweig gilt als offen, wenn er oder ein Zweig darunter schon aufgeklappt wurde
    static func isExpanded(_ node: String, _ expanded: Set<String>) -> Bool {
        expanded.contains { $0 == node || $0.hasPrefix(node + "|") }
    }

    // MARK: Zuordnung Text -> Modul

    /// Fuellwoerter der Baumtexte ("Modul", "Prüfung", "PL", ...), entfernt vor dem Vergleich
    static let fillers: Set<String> = ["modul", "prüfung", "pruefung", "prüfungsleistung", "pruefungsleistung", "studienleistung",
                                       "klausur", "pl", "sl", "teilleistung", "leistung"]

    /// Pruefungsnummern (3 bis 8 Ziffern) im Text
    static func numbers(_ text: String) -> [String] {
        text.split { !$0.isNumber }.map(String.init).filter { (3...8).contains($0.count) }
    }

    /// Text ohne Nummern und Fuellwoerter, als Schluessel wie im Studienverlauf (`StudyPlanEngine.nameKey`)
    static func key(_ text: String) -> String {
        let words = QISParser.clean(text).split { $0 == " " || $0 == ":" || $0 == "(" || $0 == ")" || $0 == "-" || $0 == "–" }
            .map(String.init)
            .filter { w in !w.allSatisfy(\.isNumber) && !fillers.contains(w.lowercased()) }
        return StudyPlanEngine.nameKey(words.joined(separator: " "))
    }

    /// 100: Pruefungsnummer; 80: gleicher Name; 60: gleicher Name wie ein Teil ("Thermodynamik I / Chemie");
    /// 40: Name endet mit dem Modul bzw. einem Teil (ganze Woerter); 0: passt nicht
    public static func score(_ text: String, _ target: QISRegistrationTarget) -> Int {
        if let nr = target.nr, numbers(text).contains(nr) { return 100 }
        let k = key(text)
        let t = StudyPlanEngine.nameKey(target.title)
        guard k.count >= StudyPlanEngine.minPartKey, !t.isEmpty else { return 0 }
        if k == t { return 80 }
        let parts = StudyPlanEngine.titleParts(.string(target.title)).parts
        if parts.contains(where: { $0.key == k }) { return 60 }
        if t.count >= StudyPlanEngine.minPartKey, k.hasSuffix(" " + t) { return 40 }
        if StudyPlanEngine.partIndex(.string(k), parts) != nil { return 40 }
        return 0
    }

    /// bester Knoten; bei Gleichstand der tiefere (Modul vor Bereich), dann der erste der Seite
    static func bestMatch(_ nodes: [QISLink], _ target: QISRegistrationTarget) -> QISLink? {
        var best: (score: Int, depth: Int, link: QISLink)?
        for l in nodes {
            let s = score(l.text, target)
            guard s > 0 else { continue }
            let d = depth(l)
            if best == nil || s > best!.score || (s == best!.score && d > best!.depth) { best = (s, d, l) }
        }
        return best?.link
    }

    /// Text teilt ein laengeres Wort mit dem Modul (Zweig zuerst aufklappen)
    static func sharesWords(_ text: String, _ target: QISRegistrationTarget) -> Bool {
        let words = Set(StudyPlanEngine.nameKey(target.title).split(separator: " ").filter { $0.count >= 5 })
        guard !words.isEmpty else { return false }
        return key(text).split(separator: " ").contains { words.contains($0) }
    }
}
