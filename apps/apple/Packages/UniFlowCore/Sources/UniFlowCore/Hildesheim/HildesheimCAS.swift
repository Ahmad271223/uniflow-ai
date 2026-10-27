import Foundation

/// Apereo-CAS der Uni Hildesheim (`app/cas.py`). Die Anmeldung selbst passiert in der App im WKWebView mit dem
/// Website-Datenspeicher des Containers (`DataContainerKey.websiteDataStoreID`); hier nur die Adressen, die Erkennung
/// der Loginseite und ihr Fehlertext. Ablauf: Dienst-URL ueber /login?service=... oeffnen. Gilt die CAS-Sitzung noch,
/// leitet das CAS sofort zur service-URL zurueck. Sonst zeigt es das Formular; die Studierenden tippen selbst und tippen
/// selbst auf "Anmelden", ein gespeichertes Passwort setzt hoechstens iOS ein (Schluesselbund), nie die App. Ob die
/// Anmeldung fertig ist, entscheidet der Dienst selbst (`LSFClient.isLoggedIn`, `Learnweb.isLoggedIn`). Der Kern ruft
/// keine Seite auf und kennt kein Passwort.
public enum HildesheimCAS {
    /// Adressen aus dem Hochschul-Profil (eine Quelle wie app/universities.py)
    public static let casBase = UniversityProfile.hildesheimCAS.absoluteString
    public static let lsfBase = UniversityProfile.hildesheimLSF.absoluteString

    /// Fehlertext nach falscher Eingabe
    public static let errorPanelID = "loginErrorsPanel"

    /// `<cas>/login?service=<Dienst>` (Dienst vollstaendig kodiert wie `cas.login_url`)
    public static func loginURL(casBase: String = casBase, service: String) -> String {
        var b = casBase
        while b.hasSuffix("/") { b.removeLast() }
        return "\(b)/login?service=\(PyText.quote(service, safe: ""))"
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

    /// Text im Element mit der ID `errorPanelID` (ohne Tags, Leerraum zusammengefasst, hoechstens 200 Zeichen wie
    /// `[:200]` in app/cas.py), sonst nil. Ueber `HTMLTokenizer` wie die uebrigen Seiten: der Inhalt von script und
    /// style zaehlt nicht als Text (vorher per Regex mitgelesen).
    public static func errorText(html: String) -> String? {
        var inside: String?
        var depth = 0
        var text: [String] = []
        for t in HTMLTokenizer.tokens(html) {
            switch t {
            case .start(let name, let attrs):
                if let open = inside {
                    if name == open { depth += 1 }
                } else if attrs["id"] == errorPanelID {
                    inside = name
                    depth = 1
                }
            case .end(let name):
                guard let open = inside, name == open else { continue }
                depth -= 1
                if depth == 0 { inside = nil }
            case .text(let s):
                if inside != nil { text.append(s) }
            case .raw:
                continue
            }
            if inside == nil, !text.isEmpty { break }
        }
        let clean = QISParser.clean(text.joined(separator: " "))
        return clean.isEmpty ? nil : String(clean.prefix(200))
    }

    /// Link einer LSF-Seite als volle Adresse: http(s) bleibt, "/qisserver/rds?…" gegen die Basis, "rds?…" relativ zu
    /// /qisserver/. Der Link ist schon dekodiert (aus `HTMLScanner` bzw. einmal in `LSFCalendar.planICSLink`). Vorher an
    /// zwei Stellen nachgebaut, mit "…/qisserver/qisserver/rds?…" fuer wurzelrelative Links und zweitem Dekodieren.
    public static func lsfAbsolute(_ href: String, base: String = lsfBase) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        if href.hasPrefix("/") { return base + href }
        return "\(base)/qisserver/" + href
    }
}
