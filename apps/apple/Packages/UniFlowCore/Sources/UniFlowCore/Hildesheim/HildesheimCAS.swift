import Foundation

/// Apereo-CAS der Uni Hildesheim (`app/cas.py`). Die Anmeldung selbst passiert in der App im WKWebView mit dem
/// Website-Datenspeicher des Containers (`DataContainerKey.websiteDataStoreID`); hier nur die Adressen, die Erkennung
/// der Loginseite und ihr Fehlertext. Ablauf: Dienst-URL ueber /login?service=... oeffnen. Gilt die CAS-Sitzung noch,
/// leitet das CAS sofort zur service-URL zurueck. Sonst zeigt es das Formular (#username, #password); die App fuellt
/// hoechstens vor, auf "Anmelden" tippen die Studierenden selbst. Ob die Anmeldung fertig ist, entscheidet der Dienst
/// selbst (`LSFClient.isLoggedIn`, `Learnweb.isLoggedIn`). Der Kern ruft keine Seite auf und kennt kein Passwort.
public enum HildesheimCAS {
    /// Adressen aus dem Hochschul-Profil (eine Quelle wie app/universities.py)
    public static let casBase = UniversityProfile.hildesheimCAS.absoluteString
    public static let lsfBase = UniversityProfile.hildesheimLSF.absoluteString

    /// Formularfelder des CAS (Live-Test 25.10.2026, USER_SELECTORS/PASS_SELECTORS in app/cas.py)
    public static let userSelectors = ["#username", "input[name='username']", "input[autocomplete='username']"]
    public static let passwordSelectors = ["#password", "input[name='password']"]
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
}
