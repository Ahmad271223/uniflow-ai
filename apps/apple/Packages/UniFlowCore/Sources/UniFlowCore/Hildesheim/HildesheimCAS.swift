import Foundation

/// Apereo-CAS der Uni Hildesheim (`app/cas.py`). Die Anmeldung selbst passiert in der App im WKWebView mit dem
/// Website-Datenspeicher des Containers (`DataContainerKey.websiteDataStoreID`); hier nur die Adressen, die Erkennung
/// der Loginseite und der Stand nach dem Laden einer Seite. Ablauf: Dienst-URL ueber /login?service=... oeffnen. Gilt
/// die CAS-Sitzung noch, leitet das CAS sofort zur service-URL zurueck. Sonst zeigt es das Formular (#username,
/// #password, Knopf name=submit); die App fuellt hoechstens vor, auf "Anmelden" tippen die Studierenden selbst. Der
/// Kern ruft keine Seite auf und kennt kein Passwort.
public enum HildesheimCAS {
    /// Adressen aus dem Hochschul-Profil (eine Quelle wie app/universities.py)
    public static let casBase = UniversityProfile.hildesheimCAS.absoluteString
    public static let lsfBase = UniversityProfile.hildesheimLSF.absoluteString

    /// Formularfelder des CAS (Live-Test 25.10.2026, USER_SELECTORS/PASS_SELECTORS in app/cas.py)
    public static let userSelectors = ["#username", "input[name='username']", "input[autocomplete='username']"]
    public static let passwordSelectors = ["#password", "input[name='password']"]
    public static let submitName = "submit"
    /// Fehlertext nach falscher Eingabe
    public static let errorPanelID = "loginErrorsPanel"

    /// `<cas>/login?service=<Dienst>` (Dienst vollstaendig kodiert wie `cas.login_url`)
    public static func loginURL(casBase: String = casBase, service: String) -> String {
        var b = casBase
        while b.hasSuffix("/") { b.removeLast() }
        return "\(b)/login?service=\(HText.quoteAll(service))"
    }

    /// Zeigt die URL auf die CAS-Loginseite (`cas.is_cas_page`)? Dann fehlt die Anmeldung bzw. die Sitzung ist
    /// abgelaufen. "www." wird ignoriert.
    public static func isCASPage(_ url: String, casBase: String = casBase) -> Bool {
        guard let u = URLComponents(string: url), let c = URLComponents(string: casBase) else { return false }
        func host(_ x: URLComponents) -> String {
            let h = (x.host ?? "").lowercased()
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        var up = u.percentEncodedPath, cp = c.percentEncodedPath
        while up.hasSuffix("/") { up.removeLast() }
        while cp.hasSuffix("/") { cp.removeLast() }
        return host(u) == host(c) && up.hasPrefix(cp + "/login")
    }

    /// Einstieg fuer das LSF (Link "Anmelden mit UNI-Account (SSO)" der LSF-Startseite, SSO_ENTRY in app/lsf.py)
    public static var lsfLoginURL: String { loginURL(service: "\(lsfBase)/qisserver/rds?state=user&type=1") }

    /// Einstieg fuer das Learnweb einer Instanz (`https://www.uni-hildesheim.de/learnweb2026`, LEARNWEB_LOGIN)
    public static func learnwebLoginURL(base: String) -> String { "\(base)/login/index.php?authCAS=CAS" }

    /// Erfolg = Ruecksprung zur service-URL (gleiches Schema, gleicher Rechner und Port, Pfad beginnt mit dem der
    /// service-URL). Das CAS haengt `ticket=` an; die Abfrage wird darum nicht verglichen.
    public static func returnedToService(_ url: URL?, service: URL) -> Bool {
        guard let url, url.scheme?.lowercased() == service.scheme?.lowercased(),
              url.host?.lowercased() == service.host?.lowercased(), url.port == service.port else { return false }
        var p = service.path
        while p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty || url.path == p || url.path.hasPrefix(p + "/")
    }

    /// Stand nach dem Laden einer Seite in der Webansicht.
    public enum State: Equatable, Sendable {
        /// CAS-Formular sichtbar: Nutzer muss sich anmelden
        case loginRequired
        /// CAS-Formular mit Fehlertext (z. B. falsches Passwort); Text aus #loginErrorsPanel, hoechstens 200 Zeichen
        case failed(String)
        /// zur service-URL zurueckgekehrt: angemeldet
        case returnedToService
        /// irgendeine andere Seite (Zwischenschritt)
        case elsewhere
    }

    public static func state(url: URL?, html: String?, service: URL, casBase: String = casBase) -> State {
        if let url, isCASPage(url.absoluteString, casBase: casBase) {
            if let html, let message = errorText(html: html), !message.isEmpty { return .failed(message) }
            return .loginRequired
        }
        return returnedToService(url, service: service) ? .returnedToService : .elsewhere
    }

    /// Formularfelder des CAS auf der Seite (nur Vorhandensein, nie Werte).
    public struct Form: Equatable, Sendable {
        public let hasUsername: Bool
        public let hasPassword: Bool
        public let hasSubmit: Bool
        public var isComplete: Bool { hasUsername && hasPassword }
    }

    public static func form(html: String) -> Form {
        var user = false, pass = false, submit = false
        for tag in tags(in: html, names: ["input", "button"]) {
            let id = tag.attrs["id"]?.lowercased() ?? ""
            let name = tag.attrs["name"]?.lowercased() ?? ""
            let type = tag.attrs["type"]?.lowercased() ?? ""
            if id == "username" || (tag.name == "input" && name == "username") { user = true }
            if id == "password" || type == "password" { pass = true }
            if name == submitName { submit = true }
        }
        return Form(hasUsername: user, hasPassword: pass, hasSubmit: submit)
    }

    /// Text in #loginErrorsPanel (ohne Tags, Leerraum zusammengefasst, hoechstens 200 Zeichen wie `[:200]` in
    /// app/cas.py), sonst nil.
    public static func errorText(html: String) -> String? {
        guard let open = html.range(of: #"<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*\bid\s*=\s*["']?loginErrorsPanel\b[^>]*>"#,
                                    options: [.regularExpression, .caseInsensitive]) else { return nil }
        let name = String(html[open].dropFirst().prefix { $0.isLetter || $0.isNumber }).lowercased()
        // bis zum passenden End-Tag; gleichnamige Tags darin mitzaehlen
        var depth = 1
        var from = open.upperBound
        var end = html.endIndex
        while let r = html.range(of: "</?\(name)\\b[^>]*>", options: [.regularExpression, .caseInsensitive],
                                 range: from..<html.endIndex) {
            if html[r].hasPrefix("</") { depth -= 1 } else if !html[r].hasSuffix("/>") { depth += 1 }
            if depth == 0 { end = r.lowerBound; break }
            from = r.upperBound
        }
        let text = String(html[open.upperBound..<end]).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let clean = QISParser.clean(QISParser.decodeEntities(text))
        return clean.isEmpty ? nil : String(clean.prefix(200))
    }

    // MARK: Kleiner Tag-Leser (nur Attribute von input/button)

    struct Tag { let name: String; let attrs: [String: String] }

    private static let tagRE = HText.regex(#"<(input|button)\b([^>]*)>"#, [.caseInsensitive])
    private static let attrRE = HText.regex(#"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)

    static func tags(in html: String, names: Set<String>) -> [Tag] {
        let ns = html as NSString
        var out: [Tag] = []
        for m in tagRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            guard names.contains(name) else { continue }
            let body = ns.substring(with: m.range(at: 2))
            let b = body as NSString
            var attrs: [String: String] = [:]
            for a in attrRE.matches(in: body, range: NSRange(location: 0, length: b.length)) {
                let key = b.substring(with: a.range(at: 1)).lowercased()
                var value = ""
                for g in 2...4 where a.range(at: g).location != NSNotFound { value = b.substring(with: a.range(at: g)) }
                if attrs[key] == nil { attrs[key] = QISParser.decodeEntities(value) }
            }
            out.append(Tag(name: name, attrs: attrs))
        }
        return out
    }
}
