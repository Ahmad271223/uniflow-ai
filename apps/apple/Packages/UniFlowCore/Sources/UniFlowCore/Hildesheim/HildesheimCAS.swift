import Foundation

/// Apereo-CAS der Uni Hildesheim (`app/cas.py`). Die Anmeldung selbst passiert in der App im WKWebView mit eigenem
/// Website-Datenspeicher je (Nutzer, Hochschule); hier nur die Adressen und die Erkennung der Loginseite.
public enum HildesheimCAS {
    public static let casBase = "https://www.uni-hildesheim.de/sso"
    public static let lsfBase = "https://lsf.uni-hildesheim.de"

    /// `<cas>/login?service=<Dienst>` (Dienst vollstaendig kodiert)
    public static func loginURL(casBase: String = casBase, service: String) -> String {
        var b = casBase
        while b.hasSuffix("/") { b.removeLast() }
        return "\(b)/login?service=\(HText.quoteAll(service))"
    }

    /// Zeigt die URL auf die CAS-Loginseite? (dann fehlt die Anmeldung). "www." wird ignoriert.
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

    /// Einstieg fuer das LSF (Link "Anmelden mit UNI-Account (SSO)" der LSF-Startseite)
    public static var lsfLoginURL: String { loginURL(service: "\(lsfBase)/qisserver/rds?state=user&type=1") }

    /// Einstieg fuer das Learnweb einer Instanz (`https://www.uni-hildesheim.de/learnweb2026`)
    public static func learnwebLoginURL(base: String) -> String { "\(base)/login/index.php?authCAS=CAS" }
}
