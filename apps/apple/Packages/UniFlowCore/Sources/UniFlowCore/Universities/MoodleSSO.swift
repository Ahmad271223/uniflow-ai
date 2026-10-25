import Foundation

// Learnweb-Schluessel ueber den Moodle-SSO-Start (wie die offizielle Moodle-App), docs/AUFTRAG-HILDESHEIM-IPAD.md
// Abschnitt 3:
//  1. tool_mobile_get_public_config lesen: `launchurl` (admin/tool/mobile/launch.php) und ob der Mobile-Webservice
//     an ist. Moodle leitet am Ende auf `<schema>://token=<base64>` weiter; ist `forcedurlscheme` gesetzt, nimmt
//     Moodle dieses Schema statt des angefragten (Standard "moodlemobile").
//  2. In der Webansicht `launch.php?service=moodle_mobile_app&passport=<zufall>&urlscheme=<schema>` oeffnen; die
//     Studierenden melden sich am CAS selbst an.
//  3. Die letzte Weiterleitung in decidePolicyFor abfangen (nicht an das System geben) und hier zerlegen:
//     base64("<md5(wwwroot + passport)>:::<token>[:::<privatetoken>]"). Passt die Pruefsumme nicht, wird der
//     Token verworfen (die Antwort gehoert nicht zu diesem Start).
// Der Kern ruft keine Seite auf; die Abfrage der Konfiguration laeuft ueber denselben Transport wie der Client.
// Gegen das echte Learnweb noch nicht geprueft (keine Anmeldung in diesem Schritt).

/// Antwort von tool_mobile_get_public_config (nur die Felder fuer die Anmeldung).
public struct MoodlePublicConfig: Sendable, Equatable {
    public let wwwroot: String?
    public let httpsWWWRoot: String?
    public let siteName: String?
    public let launchURL: URL?
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
        let forced = (j["forcedurlscheme"]?.string ?? j["tool_mobile_forcedurlscheme"]?.string)?
            .trimmingCharacters(in: .whitespaces)
        return MoodlePublicConfig(
            wwwroot: j["wwwroot"]?.string, httpsWWWRoot: j["httpswwwroot"]?.string, siteName: j["sitename"]?.string,
            launchURL: j["launchurl"]?.string.flatMap(URL.init(string:)), typeOfLogin: j["typeoflogin"]?.int,
            enableMobileWebService: flag(j["enablemobilewebservice"]),
            forcedURLScheme: forced.flatMap { MoodleSSO.isValidScheme($0) ? $0.lowercased() : nil },
            identityProviders: (j["identityproviders"]?.array ?? []).compactMap { $0["name"]?.string })
    }

    /// Schema der abschliessenden Weiterleitung
    public var urlScheme: String { forcedURLScheme ?? MoodleSSO.defaultScheme }

    /// SSO-Start moeglich: launchurl vorhanden und Mobile-Webservice nicht ausgeschaltet
    public var ssoAvailable: Bool { launchURL != nil && enableMobileWebService != false }
}

public enum MoodleSSO {
    public static let defaultScheme = "moodlemobile"
    public static let service = "moodle_mobile_app"

    /// Schema nach RFC 3986, ohne http/https/file/javascript (die duerfen nie als Token-Antwort gelten)
    static func isValidScheme(_ s: String) -> Bool {
        let l = s.lowercased()
        guard let first = l.unicodeScalars.first, ("a"..."z").contains(first), l.count <= 64,
              !["http", "https", "file", "javascript", "data", "about"].contains(l) else { return false }
        return l.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) }
    }

    /// Anfrage an lib/ajax/service-nologin.php (ohne Anmeldung, wie die Moodle-App).
    public static func publicConfigRequest(base: URL) -> LearnwebRequest {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        let payload: JSONValue = [["index": 0, "methodname": "tool_mobile_get_public_config", "args": .object([:])]]
        return LearnwebRequest(method: .post, url: URL(string: b + "/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config")!,
                               contentType: "application/json", body: payload.serialized())
    }

    public static func parsePublicConfigReply(_ reply: LearnwebReply) throws -> MoodlePublicConfig {
        guard (200..<300).contains(reply.status) else { throw LearnwebError.http(status: reply.status, path: "lib/ajax/service-nologin.php") }
        guard let j = try? JSONValue.parse(reply.body) else { throw LearnwebError.badResponse("Konfiguration ist kein JSON") }
        let first = j.array?.first ?? j
        if first["error"]?.bool == true {
            throw LearnwebError.ssoUnavailable(first["exception"]?["errorcode"]?.string ?? "Fehler")
        }
        guard let data = first["data"] ?? (j.object != nil ? j : nil), data.object != nil else {
            throw LearnwebError.badResponse("Konfiguration ohne Daten")
        }
        return MoodlePublicConfig.parse(data)
    }

    /// Konfiguration abfragen (mit denselben Wiederholungen wie der Client, Netz ueber den Transport).
    public static func fetchPublicConfig(base: URL, transport: LearnwebTransport,
                                         retry: LearnwebRetry = LearnwebRetry()) async throws -> MoodlePublicConfig {
        var last: Error = LearnwebError.network("keine Antwort")
        for attempt in 1...retry.attempts {
            if attempt > 1 { try await retry.sleep(retry.delayNanos(beforeAttempt: attempt)) }
            do {
                let r = try await transport.send(publicConfigRequest(base: base))
                if LearnwebRetry.isRetryable(status: r.status), attempt < retry.attempts {
                    last = LearnwebError.http(status: r.status, path: "lib/ajax/service-nologin.php")
                    continue
                }
                return try parsePublicConfigReply(r)
            } catch let e as LearnwebError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = LearnwebError.network((error as NSError).localizedDescription)
            }
        }
        throw last
    }

    /// Zufaelliger passport (32 Hex-Zeichen); gilt fuer genau einen Start.
    public static func newPassport() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max, using: &g)) }.joined()
    }

    /// `launch.php?service=moodle_mobile_app&passport=<passport>&urlscheme=<schema>` aus der Konfiguration; die
    /// launchurl muss auf dem Rechner des Learnweb liegen und HTTPS sein.
    public static func launchURL(config: MoodlePublicConfig, base: URL, passport: String) throws -> URL {
        guard config.ssoAvailable, let launch = config.launchURL else {
            throw LearnwebError.ssoUnavailable("keine launchurl oder Mobile-Webservice aus")
        }
        guard launch.scheme?.lowercased() == "https", launch.host?.lowercased() == base.host?.lowercased() else {
            throw LearnwebError.ssoUnavailable("launchurl auf fremdem Rechner")
        }
        guard LearnwebToken.isAlnum(passport, 8...64) else { throw LearnwebError.ssoUnavailable("ungültiger passport") }
        var c = URLComponents(url: launch, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "service", value: service),
                                               URLQueryItem(name: "passport", value: passport),
                                               URLQueryItem(name: "urlscheme", value: config.urlScheme)]
        return c.url!
    }

    /// Ist das die abschliessende Weiterleitung `<schema>://token=...`? Nur das erwartete Schema zaehlt.
    public static func isTokenRedirect(_ url: URL?, scheme: String) -> Bool {
        guard let s = url?.absoluteString else { return false }
        return s.lowercased().hasPrefix(scheme.lowercased() + "://token=")
    }

    /// Weiterleitung zerlegen und pruefen. `siteURLs`: wwwroot aus der Konfiguration und die eigene Basisadresse;
    /// geprueft wird md5(<url> + passport) mit und ohne "/" am Ende und mit http/https wie die Moodle-App.
    public static func token(fromRedirect url: URL, scheme: String, passport: String, siteURLs: [String]) throws -> LearnwebToken {
        guard isTokenRedirect(url, scheme: scheme) else { throw LearnwebError.ssoRejected("unerwartete Adresse") }
        var payload = String(url.absoluteString.dropFirst(scheme.count + "://token=".count))
        if let cut = payload.firstIndex(where: { $0 == "#" || $0 == "&" }) { payload = String(payload[..<cut]) }
        payload = LearnwebParsing.unquote(payload).trimmingCharacters(in: .whitespacesAndNewlines)
        // Moodle: base64_encode (Standard-Alphabet); fehlende Auffuellung ergaenzen
        var b64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8) else {
            throw LearnwebError.ssoRejected("Antwort nicht lesbar")
        }
        let parts = text.components(separatedBy: ":::")
        guard parts.count >= 2 else { throw LearnwebError.ssoRejected("Antwort unvollständig") }
        let signature = parts[0].lowercased()
        var candidates: [String] = []
        for raw in siteURLs {
            var u = raw.trimmingCharacters(in: .whitespaces)
            while u.hasSuffix("/") { u.removeLast() }
            guard !u.isEmpty else { continue }
            let swapped = u.hasPrefix("https://") ? "http://" + u.dropFirst(8) : (u.hasPrefix("http://") ? "https://" + u.dropFirst(7) : u)
            candidates += [u, u + "/", swapped, swapped + "/"]
        }
        guard candidates.contains(where: { InsecureHash.md5Hex($0 + passport) == signature }) else {
            throw LearnwebError.ssoRejected("Prüfsumme passt nicht zu diesem Start")
        }
        guard let token = LearnwebToken(parts[1], privateToken: parts.count > 2 ? parts[2] : nil) else {
            throw LearnwebError.ssoRejected("ungültiger Schlüssel")
        }
        return token
    }
}
