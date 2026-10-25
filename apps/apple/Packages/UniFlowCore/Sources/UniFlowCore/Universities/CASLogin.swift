import Foundation

// Anmeldung ueber ein Apereo-CAS (Uni Hildesheim: https://www.uni-hildesheim.de/sso), Regeln wie app/cas.py.
// Ablauf auf dem iPad: Dienst-URL ueber /login?service=... in der Webansicht oeffnen. Gilt die CAS-Sitzung noch,
// leitet das CAS sofort zur service-URL zurueck. Sonst zeigt es das Formular (#username, #password, Knopf
// name=submit); die Studierenden tippen selbst auf "Anmelden". Der Kern ruft keine Seite auf und kennt kein Passwort.

public enum CASLogin {
    /// Formularfelder des CAS (Live-Test 25.10.2026, app/cas.py)
    public static let userSelectors = ["#username", "input[name='username']", "input[autocomplete='username']"]
    public static let passwordSelectors = ["#password", "input[name='password']"]
    public static let submitName = "submit"
    /// Fehlertext nach falscher Eingabe
    public static let errorPanelID = "loginErrorsPanel"

    /// Wie `cas.login_url`: service vollstaendig kodiert (quote(service, safe='')).
    public static func loginURL(casBase: URL, service: String) -> URL {
        var b = casBase.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: "\(b)/login?service=\(quoteAll(service))")!
    }

    /// Wie urllib.parse.quote(s, safe=''): nur A-Z a-z 0-9 _ . - ~ bleiben, alles andere als %XX (UTF-8).
    static func quoteAll(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2E, 0x2D, 0x7E: out.append(Character(Unicode.Scalar(byte)))
            default: out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Wie `cas.is_cas_page`: Adresse zeigt auf die CAS-Anmeldung (Rechner mit oder ohne "www.").
    /// Eine Weiterleitung hierher heisst: noch nicht angemeldet oder Sitzung abgelaufen.
    public static func isLoginPage(_ url: URL?, casBase: URL) -> Bool {
        guard let url else { return false }
        func host(_ u: URL) -> String {
            let h = (u.host ?? "").lowercased()
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        var casPath = casBase.path
        while casPath.hasSuffix("/") { casPath.removeLast() }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return host(url) == host(casBase) && path.hasPrefix(casPath + "/login")
    }

    /// Abgelaufene Sitzung eines Dienstes (Learnweb, LSF): eine Antwort endet auf der CAS-Anmeldung.
    public static func isSessionExpired(finalURL: URL?, casBase: URL) -> Bool { isLoginPage(finalURL, casBase: casBase) }

    /// Erfolg = Ruecksprung zur service-URL (gleiches Schema, gleicher Rechner, Pfad beginnt mit dem der service-URL).
    /// Das CAS haengt `ticket=` an; die Abfrage wird darum nicht verglichen.
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

    public static func state(url: URL?, html: String?, service: URL, casBase: URL) -> State {
        if isLoginPage(url, casBase: casBase) {
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

    /// Text in #loginErrorsPanel (ohne Tags, Leerraum zusammengefasst, hoechstens 200 Zeichen), sonst nil.
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

    static func tags(in html: String, names: Set<String>) -> [Tag] {
        guard let re = try? NSRegularExpression(pattern: #"<(input|button)\b([^>]*)>"#, options: [.caseInsensitive]) else { return [] }
        let attrRE = try? NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)
        let ns = html as NSString
        var out: [Tag] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            guard names.contains(name) else { continue }
            let body = ns.substring(with: m.range(at: 2))
            let b = body as NSString
            var attrs: [String: String] = [:]
            for a in attrRE?.matches(in: body, range: NSRange(location: 0, length: b.length)) ?? [] {
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
