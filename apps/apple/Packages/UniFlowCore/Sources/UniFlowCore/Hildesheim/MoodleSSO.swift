import Foundation

/// Antwort von `tool_mobile_get_public_config` (oeffentlich, ohne Anmeldung): Name der Instanz und was das Moodle-SSO
/// braucht. Moodle leitet am Ende auf `<schema>://token=<base64>` weiter; ist `forcedurlscheme` gesetzt, nimmt Moodle
/// dieses Schema statt des angefragten (Standard "moodlemobile").
public struct MoodlePublicConfig: Sendable, Equatable {
    public let wwwroot: String?
    public let httpsWWWRoot: String?
    public let siteName: String?
    public let launchURL: String?
    /// 1 = in der App, 2 = Browser, 3 = eingebetteter Browser
    public let typeOfLogin: Int?
    public let enableMobileWebService: Bool?
    public let forcedURLScheme: String?
    public let identityProviders: [String]

    public static func parse(_ j: JSONValue) -> MoodlePublicConfig {
        func flag(_ v: JSONValue?) -> Bool? {
            switch v {
            case .bool(let b)?: return b
            case .number(let n)?: return n != 0
            case .string(let s)?: return s == "1" || s.lowercased() == "true"
            default: return nil
            }
        }
        let forced = (j["forcedurlscheme"]?.string ?? j["tool_mobile_forcedurlscheme"]?.string)?.trimmingCharacters(in: .whitespaces)
        return MoodlePublicConfig(
            wwwroot: j["wwwroot"]?.string, httpsWWWRoot: j["httpswwwroot"]?.string, siteName: j["sitename"]?.string,
            launchURL: j["launchurl"]?.string, typeOfLogin: j["typeoflogin"]?.int, enableMobileWebService: flag(j["enablemobilewebservice"]),
            forcedURLScheme: forced.flatMap { MoodleSSO.isValidScheme($0) ? $0.lowercased() : nil },
            identityProviders: (j["identityproviders"]?.array ?? []).compactMap { $0["name"]?.string })
    }

    /// Schema der abschliessenden Weiterleitung
    public var urlScheme: String { forcedURLScheme ?? MoodleSSO.defaultScheme }

    /// SSO-Start moeglich: launchurl vorhanden und Mobile-Webservice nicht ausgeschaltet
    public var ssoAvailable: Bool { launchURL.map { !$0.isEmpty } == true && enableMobileWebService != false }
}

/// Moodle-Anmeldung fuer Apps (`learnweb.launch_url`, `learnweb.parse_launch_token`), docs/AUFTRAG-HILDESHEIM-IPAD.md
/// Abschnitt 3.
///
/// Ablauf in der App: erst `publicConfig` (ist der Mobile-Webservice an, welches Schema?), dann `launchURL(config:...)`
/// im WKWebView oeffnen (Datenspeicher des Containers), dort meldet sich der Nutzer beim CAS selbst an. Danach leitet
/// Moodle auf `<schema>://token=<base64>` weiter; die Webansicht faengt diese Adresse in `decidePolicyFor
/// navigationAction` ab (nicht an das System weitergeben) und gibt sie an `parseLaunchToken`. Der Schluessel gilt fuer
/// den REST-Weg: Dateien ohne Browser, Moodle verbucht keine Aufrufe. Gegen das echte Learnweb noch nicht geprueft.
public enum MoodleSSO {
    public static let defaultScheme = "moodlemobile"
    public static let service = "moodle_mobile_app"

    /// Start-Adresse wie `learnweb.launch_url`
    public static func launchURL(base: String, passport: String, scheme: String = defaultScheme) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return launch(b + "/admin/tool/mobile/launch.php", passport: passport, scheme: scheme)
    }

    /// Start aus der Konfiguration: SSO muss moeglich sein, die launchurl HTTPS auf dem Rechner des Learnweb; das
    /// Schema gibt die Uni vor (`forcedurlscheme`), sonst "moodlemobile".
    public static func launchURL(config: MoodlePublicConfig, base: String, passport: String) throws -> String {
        guard config.ssoAvailable, let raw = config.launchURL, let launch = URL(string: raw) else {
            throw HildesheimError.ssoUnavailable("keine launchurl oder Mobile-Webservice aus")
        }
        guard launch.scheme?.lowercased() == "https", let host = launch.host?.lowercased(), host == URL(string: base)?.host?.lowercased(),
              launch.query == nil else {
            throw HildesheimError.ssoUnavailable("launchurl auf fremdem Rechner")
        }
        guard LearnwebToken.isAlnum(passport, 8...64) else { throw HildesheimError.ssoUnavailable("ungültiger passport") }
        return Self.launch(raw, passport: passport, scheme: config.urlScheme)
    }

    private static func launch(_ launchPHP: String, passport: String, scheme: String) -> String {
        "\(launchPHP)?service=\(service)&passport=\(HText.quoteAll(passport))&urlscheme=\(HText.quoteAll(scheme))"
    }

    /// Zufaelliger Passport fuer einen Anmeldevorgang (merken, bis die Weiterleitung kommt)
    public static func newPassport() -> String {
        String((0..<24).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// Schema nach RFC 3986, ohne http/https/file/javascript/data/about (die duerfen nie als Token-Antwort gelten)
    static func isValidScheme(_ s: String) -> Bool {
        let l = s.lowercased()
        guard let first = l.unicodeScalars.first, ("a"..."z").contains(first), l.count <= 64,
              !["http", "https", "file", "javascript", "data", "about"].contains(l) else { return false }
        return l.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) }
    }

    /// Konfiguration ueber `lib/ajax/service-nologin.php` (ohne Anmeldung, wie die Moodle-App), mit den Wiederholungen
    /// aller Hochschul-Abfragen (`UniRetry`). Moodle meldet einen Fehler (z. B. servicenotavailable): `ssoUnavailable`.
    public static func publicConfig(base: String, transport: UniTransport, retry: UniRetry = UniRetry()) async throws -> MoodlePublicConfig {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + "/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config") else {
            throw HildesheimError.badResponse(base)
        }
        let body = JSONValue.array([.object(["index": .number(0), "methodname": .string("tool_mobile_get_public_config"), "args": .object([:])])])
        let resp = try await transport.fetch(UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"],
                                                        body: body.serialized()), retry: retry)
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: b + "/lib/ajax/service-nologin.php") }
        guard let j = try? JSONValue.parse(resp.body) else { throw HildesheimError.badResponse("Konfiguration ist kein JSON") }
        let first = j.array?.first ?? j
        if first["error"]?.bool == true {
            throw HildesheimError.ssoUnavailable(first["exception"]?["errorcode"]?.string ?? "Fehler")
        }
        guard let data = first["data"] ?? (j.object != nil ? j : nil), data.object != nil else {
            throw HildesheimError.badResponse("Konfiguration ohne Daten")
        }
        return MoodlePublicConfig.parse(data)
    }

    /// Ist das die abschliessende Weiterleitung `<schema>://token=...`? Nur das erwartete Schema zaehlt.
    public static func isTokenRedirect(_ url: String?, scheme: String) -> Bool {
        guard let url else { return false }
        return url.lowercased().hasPrefix(scheme.lowercased() + "://token=")
    }

    private static let tokenRE = HText.regex("token=([A-Za-z0-9+/=_-]+)")

    /// `parse_launch_token`: base64(md5(wwwroot + passport) ":::" token [":::" privatetoken]). Prueft die Signatur
    /// gegen die eigene Learnweb-Adresse (`base`, dazu `siteURLs` wie wwwroot aus der Konfiguration; wie die
    /// Moodle-App auch mit http/https und "/" am Ende) und den eigenen Passport; bei fremder Adresse, fremdem Passport,
    /// anderem Schema (`scheme`, falls angegeben) oder einem Schluessel, der nicht alphanumerisch ist: nil.
    public static func parseLaunchToken(_ redirectURL: String, base: String, passport: String, scheme: String? = nil,
                                        siteURLs: [String] = []) -> LearnwebToken? {
        if let scheme, !isTokenRedirect(redirectURL, scheme: scheme) { return nil }
        guard let raw0 = HText.match(tokenRE, HText.unquote(redirectURL))?.groups[1] ?? nil else { return nil }
        var raw = raw0.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw += "=" }
        guard let data = Data(base64Encoded: raw), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        var candidates: [String] = []
        for site in [base] + siteURLs {
            var u = site.trimmingCharacters(in: .whitespaces)
            while u.hasSuffix("/") { u.removeLast() }
            guard !u.isEmpty else { continue }
            let swapped = u.hasPrefix("https://") ? "http://" + u.dropFirst(8) : (u.hasPrefix("http://") ? "https://" + u.dropFirst(7) : u)
            candidates += [u, u + "/", swapped, swapped + "/"]
        }
        let signature = parts[0].lowercased()
        guard candidates.contains(where: { MD5.hex($0 + passport) == signature }) else { return nil }
        return LearnwebToken(parts[1], privateToken: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }
}

