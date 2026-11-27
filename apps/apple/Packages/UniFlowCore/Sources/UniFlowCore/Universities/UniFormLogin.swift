import Foundation

// Anmeldung im Hintergrund ohne Webansicht (Entscheidung des Inhabers 20.11.2026: "ja versuch, weil bei Studo geht das
// auch problemlos"; docs/HINTERGRUND-ANMELDUNG-2026-11-20.md). Bei geschlossener App ist eine unsichtbare Webansicht
// unzuverlaessig (kein Fenster, WebKit kann pausieren, JavaScript dauert); die Anmeldeseiten von QIS (HIS-QIS),
// WebSSO der LUH (Shibboleth) und CAS der Uni Hildesheim sind aber klassische HTML-Formulare, die auch ohne JavaScript
// gehen. Hier steht der reine Ablauf (ohne URLSession und WebKit testbar, Transport `UniTransport`):
//
// - Startseite des Dienstes laden. Ist sie schon die angemeldete Seite (`isDone`), fertig - ohne Passwort.
// - Weiterleitungsformulare des SSO (SAML-Antwort an Stud.IP, Pruefseite des Shibboleth-IdP) schickt der Ablauf mit
//   ihren versteckten Feldern weiter, nie ein Formular mit Auswahl (Zustimmung) oder Eingabefeld - so meldet eine noch
//   gueltige Uni-Anmeldung (IdP- bzw. CAS-Cookie) still neu an, ohne Passwort.
// - Ein bekanntes Anmeldeformular (`UniLoginForms`, nur `allowedForms`) bekommt Benutzername und Passwort genau EINMAL
//   je Ablauf, nur per POST an den Formular-Rechner und -Pfad der Hochschule (HTTPS). Kommt danach dasselbe Formular mit
//   Fehlertext, hat die Hochschule das Passwort abgelehnt (`.rejected`); ohne Fehlertext oder mit einer unbekannten
//   Seite (Captcha, zweiter Faktor) `.failed`. Ohne Passwort (`credential == nil`) endet er dort mit `.needsPassword`.
// - Nie aufgerufen werden Adressen zum Abmelden, zur Pruefungsan-/abmeldung, zum Ruecktritt, zu Bescheinigungen
//   (`forbidden`); nie ein fremder Rechner; nie mehr als `maxSteps` Anfragen, nie laenger als `deadline`.
// - `.unsupported`: Seite ohne erkanntes Formular, Passwort NICHT gesendet - der Aufrufer darf es einmal anders
//   versuchen (unsichtbare Webansicht). Nach gesendetem Passwort gibt es nie einen zweiten Weg im selben Versuch.
// - Abbruch (iOS beendet die Hintergrundzeit, `Task.cancel`): `.cancelled`, nie als "abgelehnt".
// Gelesen werden nur Formularfelder und die Erfolgspruefung des Dienstes; keine Namen, Adressen, Geburtsdaten oder
// Matrikelnummern, nichts wird gespeichert ausser den Cookies (das macht die App).

/// Ein Formular einer Seite (nur, was der Ablauf braucht)
public struct UniHTMLForm: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var name: String
        /// klein: "hidden", "text", "password", "submit", "checkbox" … ("select" fuer Auswahllisten)
        public var type: String
        public var value: String
        public var id: String
        public var checked: Bool
    }

    /// Ziel wie im HTML (Entities dekodiert); nil oder leer: dieselbe Seite
    public var action: String?
    /// klein, Vorgabe "get"
    public var method: String
    public var fields: [Field]
    /// Absende-Knoepfe (input submit/image, button ohne type oder type=submit)
    public var submits: [Field]

    public var hasPassword: Bool { fields.contains { $0.type == "password" } }

    /// Zieladresse gegen die Seite aufgeloest
    public func target(base: URL) -> URL? {
        guard let a = action?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return base }
        return URL(string: a, relativeTo: base)?.absoluteURL
    }
}

public enum UniFormScanner {
    /// Alle Formulare einer Seite (Felder ausserhalb eines Formulars zaehlen nicht)
    public static func forms(_ html: String) -> [UniHTMLForm] {
        var out: [UniHTMLForm] = []
        var open: UniHTMLForm?
        var select: UniHTMLForm.Field?
        for t in HTMLTokenizer.tokens(html) {
            switch t {
            case .start("form", let a):
                if let f = open { out.append(f) }
                open = UniHTMLForm(action: a["action"], method: (a["method"] ?? "get").lowercased(), fields: [], submits: [])
            case .end("form"):
                if let s = select { open?.fields.append(s); select = nil }
                if let f = open { out.append(f) }
                open = nil
            case .start("input", let a):
                guard open != nil else { continue }
                let type = (a["type"] ?? "text").lowercased()
                let f = UniHTMLForm.Field(name: a["name"] ?? "", type: type, value: a["value"] ?? "", id: a["id"] ?? "",
                                          checked: a["checked"] != nil)
                if type == "submit" || type == "image" { open?.submits.append(f) } else { open?.fields.append(f) }
            case .start("button", let a):
                guard open != nil else { continue }
                let type = (a["type"] ?? "submit").lowercased()
                guard type == "submit" else { continue }
                open?.submits.append(UniHTMLForm.Field(name: a["name"] ?? "", type: "submit", value: a["value"] ?? "", id: a["id"] ?? "", checked: false))
            case .start("select", let a):
                guard open != nil else { continue }
                if let s = select { open?.fields.append(s) }
                select = UniHTMLForm.Field(name: a["name"] ?? "", type: "select", value: "", id: a["id"] ?? "", checked: false)
            case .start("option", let a):
                guard var s = select else { continue }
                // erste Option oder die ausgewaehlte (wie ein Browser ohne Eingabe)
                if s.value.isEmpty && !s.checked || a["selected"] != nil {
                    s.value = a["value"] ?? ""
                    s.checked = s.checked || a["selected"] != nil
                }
                select = s
            case .end("select"):
                if let s = select { open?.fields.append(s) }
                select = nil
            default:
                continue
            }
        }
        if let f = open { out.append(f) }
        return out
    }
}

public enum UniFormLogin {
    public enum Result: Equatable, Sendable {
        /// angemeldete Seite des Dienstes erreicht (`passwordSent == false`: still, ueber die noch gueltige Uni-Anmeldung)
        case done(passwordSent: Bool)
        /// Passwort gesendet, Formular mit Fehlertext der Seite wieder da: abgelehnt
        case rejected
        /// Zeit um, Netzfehler, unerwartete Seite (Captcha, zweiter Faktor, Zustimmung), Formular ohne Fehlertext
        case failed(passwordSent: Bool)
        /// ohne Passwort aufgerufen und die Hochschule will es: nichts gesendet
        case needsPassword
        /// kein bekanntes Formular, nichts gesendet: ein anderer Weg (Webansicht) ist erlaubt
        case unsupported
        /// Weiterleitung auf einen fremden Rechner oder eine verbotene Adresse: abgebrochen
        case blocked
        /// iOS hat die Zeit beendet (`Task.cancel`): kein Urteil ueber das Passwort
        case cancelled(passwordSent: Bool)
    }

    /// Diese Formulare darf der Ablauf ohne Webansicht ausfuellen: Feldnamen am echten Formular bestaetigt und klassisch
    /// ohne JavaScript (QIS, WebSSO, CAS, Stud.IP Goettingen). SOGo (JavaScript-Anwendung), HISinOne (Ajax) und Moodle nicht.
    /// Stud.IP Goettingen (`form#login-form`, POST auf dieselbe Adresse, versteckt `security_token`, `login_ticket`,
    /// `resolution`) seit 27.11.2026: nach dem echten Kontotest in der App freigegeben (Inhaber: „Ja, freigeben“)
    public static let allowedForms: Set<String> = [UniLoginForms.luhQIS.id, UniLoginForms.luhWebSSO.id,
                                                    UniLoginForms.hildesheimCAS.id, UniLoginForms.hildesheimCASBare.id,
                                                    UniLoginForms.goettingenStudIP.id]

    /// Teile von Adressen, die der Ablauf nie aufruft (Abmelden, Pruefungsan-/abmeldung, Ruecktritt, Bescheinigungen,
    /// Berichte; QIS: `state=user&type=4` ist das Abmelden)
    public static let forbiddenParts = ["logout", "abmeld", "prfanm", "pruefungsanm", "prüfungsanm", "anmeldung", "ruecktritt",
                                        "rücktritt", "storn", "verpublish", "hisreports", "state=user&type=4", "/slo"]

    public static func forbidden(_ url: URL) -> Bool {
        let s = (url.absoluteString.removingPercentEncoding ?? url.absoluteString).lowercased()
        return forbiddenParts.contains { s.contains($0) }
    }

    /// hoechstens so viele Anfragen je Ablauf (Startseite, Weiterleitungen, Weiterleitungsformulare, ein Formular mit
    /// Passwort)
    public static let maxSteps = 20
    /// hoechstens so viele Weiterleitungsformulare (Pruefseite des IdP, SAML-Antwort)
    public static let maxRelays = 4
    /// Zeitlimit je Anfrage ohne Daten
    public static let requestTimeout: TimeInterval = 12

    /// - Parameters:
    ///   - entry: Startseite des Dienstes bzw. Einstieg ins SSO
    ///   - domains: registrierbare Domains der Hochschule (nur dorthin, nur HTTPS)
    ///   - credential: nil = nur still (ohne Passwort)
    ///   - deadline: spaetestens dann Schluss (`.failed`)
    ///   - isDone: Erfolgsseite des Dienstes
    public static func run(transport: UniTransport, entry: URL, university: UniversityKey, domains: [String],
                           credential: (username: String, password: String)?, deadline: Date,
                           now: @escaping () -> Date = { Date() },
                           isDone: (URL, String) async -> Bool) async -> Result {
        var request = UniRequest(url: entry, followRedirects: false, timeout: requestTimeout)
        var passwordSent = false
        var submitted = 0
        var relays = 0
        for _ in 0..<maxSteps {
            if Task.isCancelled { return .cancelled(passwordSent: passwordSent) }
            if now() >= deadline { return .failed(passwordSent: passwordSent) }
            guard UniAutoLoginFlow.allowed(request.url, domains: domains) else { return .blocked }
            if forbidden(request.url) { return .blocked }
            let response: UniResponse
            do {
                response = try await transport.send(request)
            } catch {
                return Task.isCancelled ? .cancelled(passwordSent: passwordSent) : .failed(passwordSent: passwordSent)
            }
            if Task.isCancelled { return .cancelled(passwordSent: passwordSent) }
            let url = response.finalURL ?? request.url
            guard UniAutoLoginFlow.allowed(url, domains: domains) else { return .blocked }
            if forbidden(url) { return .blocked }
            // Weiterleitungen folgt der Ablauf selbst: jede Zwischenadresse wird vorher geprueft (Rechner, verbotene Ziele)
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard let loc = response.headers["location"], let next = URL(string: loc, relativeTo: url)?.absoluteURL else {
                    return .failed(passwordSent: passwordSent)
                }
                // 307/308 behalten Methode und Koerper, aber nie an einen anderen Rechner
                let keep = (response.status == 307 || response.status == 308) && request.method == "POST"
                if keep, next.host?.lowercased() != request.url.host?.lowercased() { return .blocked }
                request = keep ? UniRequest(url: next, method: "POST", headers: request.headers, body: request.body,
                                            followRedirects: false, timeout: requestTimeout)
                    : UniRequest(url: next, followRedirects: false, timeout: requestTimeout)
                continue
            }
            guard (200..<300).contains(response.status) else { return .failed(passwordSent: passwordSent) }
            let html = response.text
            if await isDone(url, html) { return .done(passwordSent: passwordSent) }
            let forms = UniFormScanner.forms(html)

            // Anmeldeformular der Hochschule
            if let spec = UniLoginForms.form(for: url, university: university), spec.appears(in: html) {
                if submitted > 0 {
                    // nach dem eigenen Absenden wieder da: abgelehnt nur mit Fehlertext (wie die Webansicht)
                    return UniAutoLoginFlow.rejects(spec, html: html) ? .rejected : .failed(passwordSent: true)
                }
                guard allowedForms.contains(spec.id) else { return .unsupported }
                guard let credential else { return .needsPassword }
                guard let form = loginForm(forms, spec: spec) else { return .unsupported }
                // Captcha oder zusaetzliche Eingabe: das kann nur der Mensch (nichts senden)
                if needsHuman(form, spec: spec) { return .failed(passwordSent: false) }
                guard let target = form.target(base: url), form.method == "post", spec.matches(target),
                      !forbidden(target) else { return .unsupported }
                // Umlaute nur, wenn die Seite sicher UTF-8 spricht (sonst kaeme ein falsch kodiertes Passwort an und
                // gaelte als abgelehnt): dann lieber die Webansicht
                let ascii = (credential.username + credential.password).unicodeScalars.allSatisfy { $0.isASCII }
                guard ascii || isUTF8(response, html: html) else { return .unsupported }
                let body = encode(fields(form, spec: spec, credential: credential))
                request = UniRequest(url: target, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded",
                                                                            "Referer": url.absoluteString],
                                     body: Data(body.utf8), followRedirects: false, timeout: requestTimeout)
                submitted += 1
                passwordSent = true
                continue
            }

            // Weiterleitungsformular des SSO (ohne Passwort, ohne Auswahl)
            if relays < maxRelays, let (form, target) = relayForm(forms, base: url, domains: domains) {
                relays += 1
                let body = encode(hiddenFields(form))
                request = UniRequest(url: target, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                     body: Data(body.utf8), followRedirects: false, timeout: requestTimeout)
                continue
            }
            return passwordSent ? .failed(passwordSent: true) : .unsupported
        }
        return .failed(passwordSent: passwordSent)
    }

    // MARK: Formulare

    /// Namen bzw. IDs aus den Selektoren eines Formulars (`input[name="asdf"]`, `input#asdf`)
    static func names(_ selectors: [String]) -> (names: Set<String>, ids: Set<String>) {
        var n = Set<String>(), i = Set<String>()
        for s in selectors {
            if let r = s.range(of: "name=\""), let e = s[r.upperBound...].firstIndex(of: "\"") { n.insert(String(s[r.upperBound..<e])) }
            if let h = s.firstIndex(of: "#") {
                let rest = s[s.index(after: h)...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                if !rest.isEmpty { i.insert(String(rest)) }
            }
        }
        return (n, i)
    }

    static func field(_ f: UniHTMLForm.Field, in selectors: [String]) -> Bool {
        let (n, i) = names(selectors)
        return (!f.name.isEmpty && n.contains(f.name)) || (!f.id.isEmpty && i.contains(f.id))
    }

    /// Das Formular mit Benutzer- und Passwortfeld der Hochschule
    static func loginForm(_ forms: [UniHTMLForm], spec: UniLoginForm) -> UniHTMLForm? {
        forms.first { f in
            f.fields.contains { $0.type == "password" && field($0, in: spec.passwordFields) && !$0.name.isEmpty }
                && f.fields.contains { $0.type != "password" && $0.type != "hidden" && field($0, in: spec.userFields) && !$0.name.isEmpty }
        }
    }

    /// Weitere sichtbare Eingaben (Captcha, Code) oder ein zweites Passwortfeld: nicht ohne den Menschen
    static func needsHuman(_ form: UniHTMLForm, spec: UniLoginForm) -> Bool {
        let visible = form.fields.filter { !["hidden", "checkbox", "radio", "select", "submit", "button", "reset"].contains($0.type) }
        let unknown = visible.filter { !field($0, in: spec.userFields) && !field($0, in: spec.passwordFields) }
        let captcha = form.fields.contains { ($0.name + " " + $0.id).lowercased().contains("captcha") }
        return captcha || !unknown.isEmpty || form.fields.filter({ $0.type == "password" }).count > 1
    }

    /// Felder fuer das Absenden: versteckte und vorbelegte wie im Formular, Benutzer und Passwort eingesetzt, Haken nur
    /// wie vorgegeben (nie Zustimmung), dazu der erste benannte Absende-Knopf (QIS `submit`, IdP `_eventId_proceed`)
    static func fields(_ form: UniHTMLForm, spec: UniLoginForm, credential: (username: String, password: String)) -> [(String, String)] {
        var out: [(String, String)] = []
        for f in form.fields where !f.name.isEmpty {
            switch f.type {
            case "password": out.append((f.name, credential.password))
            case "checkbox", "radio": if f.checked { out.append((f.name, f.value.isEmpty ? "on" : f.value)) }
            case "button", "reset", "file": continue
            default:
                out.append((f.name, field(f, in: spec.userFields) && f.type != "hidden" ? credential.username : f.value))
            }
        }
        if let b = form.submits.first(where: { !$0.name.isEmpty }) { out.append((b.name, b.value)) }
        return out
    }

    static func hiddenFields(_ form: UniHTMLForm) -> [(String, String)] {
        var out = form.fields.filter { !$0.name.isEmpty && $0.type == "hidden" }.map { ($0.name, $0.value) }
        if let b = form.submits.first(where: { !$0.name.isEmpty }) { out.append((b.name, b.value)) }
        return out
    }

    /// Weiterleitungsformular des SSO: POST an einen Rechner der Hochschule, nur versteckte Felder (kein Passwort, keine
    /// Eingabe, keine Auswahl), und es ist erkennbar eines des SSO: SAML-Antwort/-Anfrage, Ziel `/Shibboleth.sso/`, die
    /// Pruefseite des Shibboleth-IdP (`shib_idp_ls…`) oder das CAS-Ticket-Formular
    static func relayForm(_ forms: [UniHTMLForm], base: URL, domains: [String]) -> (UniHTMLForm, URL)? {
        for f in forms where f.method == "post" {
            guard !f.hasPassword, let target = f.target(base: base), UniAutoLoginFlow.allowed(target, domains: domains),
                  !forbidden(target) else { continue }
            let named = f.fields.filter { !$0.name.isEmpty }
            guard !named.isEmpty, named.allSatisfy({ $0.type == "hidden" }) else { continue }
            let keys = named.map { $0.name.lowercased() }
            let path = target.path.lowercased()
            let saml = keys.contains("samlresponse") || keys.contains("samlrequest")
            let shibLocalStorage = path.contains("/idp/profile/") && keys.allSatisfy { $0.hasPrefix("shib_idp_ls") || $0 == "_eventid_proceed" || $0 == "csrf_token" }
            let sp = path.contains("/shibboleth.sso/")
            let casTicket = path.contains("/sso/login") && keys.contains("execution") && !keys.contains("username")
                && keys.allSatisfy { ["execution", "_eventid", "geolocation", "lt"].contains($0) }
            if saml || shibLocalStorage || sp || casTicket { return (f, target) }
        }
        return nil
    }

    // MARK: Kodierung

    static let formAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        s.insert(charactersIn: "-._*")
        return s
    }()

    /// application/x-www-form-urlencoded (UTF-8, Leerzeichen als +)
    static func encode(_ pairs: [(String, String)]) -> String {
        func e(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: formAllowed.union(CharacterSet(charactersIn: " "))) ?? "")
                .replacingOccurrences(of: " ", with: "+")
        }
        return pairs.map { e($0.0) + "=" + e($0.1) }.joined(separator: "&")
    }

    /// Spricht die Seite sicher UTF-8 (Kopfzeile oder meta charset)?
    static func isUTF8(_ r: UniResponse, html: String) -> Bool {
        let header = (r.headers["content-type"] ?? "").lowercased()
        if header.contains("charset=") { return header.contains("utf-8") || header.contains("utf8") }
        let head = String(html.prefix(4096)).lowercased().replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        return head.contains("charset=utf-8") || head.contains("charset=utf8")
    }
}
