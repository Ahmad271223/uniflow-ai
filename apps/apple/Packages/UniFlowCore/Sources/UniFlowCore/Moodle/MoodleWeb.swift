import Foundation

// Allgemeines Moodle mit der Sitzung der Webansicht (Cookies setzt der Transport der App): Hochschule Hannover
// (moodle.hs-hannover.de) und Learnweb der Uni Hildesheim. Grundlage fuer Nachrichten (`MoodleMessages`) und Abgaben
// (`MoodleAssign`), docs/HSH-2026-11-05.md. Lesen ueber /lib/ajax/service.php mit dem sesskey der Seite wie das
// Moodle selbst (nur Funktionen, die Moodle fuer AJAX freigibt), Schreiben nur auf Knopfdruck des Menschen und ohne
// stilles Wiederholen (eine zweite Anfrage koennte doppelt senden bzw. abgeben).

public enum MoodleError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Anmeldeseite statt der erwarteten Seite oder Antwort: neu anmelden
    case sessionExpired
    /// Moodle lehnt ab (Fehlercode der AJAX-Antwort oder des Uploads); kein Text aus Moodle (koennte Eingaben enthalten)
    case refused(String)
    case http(Int)
    /// erwartetes Formular oder Feld fehlt (Seitenaufbau anders als angenommen)
    case unexpectedPage(String)

    public var description: String {
        switch self {
        case .sessionExpired: return "Die Moodle-Anmeldung ist abgelaufen. Bitte neu anmelden."
        case .refused(let code): return "Moodle hat abgelehnt (\(code))."
        case .http(let s): return "Moodle antwortet mit HTTP \(s)."
        case .unexpectedPage(let what): return "Die Moodle-Seite sieht anders aus als erwartet (\(what))."
        }
    }

    public var errorDescription: String? { description }
}

/// Eine Moodle-Instanz mit der Sitzung der App: Seiten lesen, AJAX, Formulare (nur auf Knopfdruck)
public actor MoodleWeb {
    public let base: String
    private let transport: UniTransport
    private let retry: UniRetry
    /// Schreiben: genau ein Versuch
    private static let once = UniRetry(attempts: 1, delayNanos: { _ in 0 })
    private var session: (sesskey: String, userID: Int?)?

    public init(base: String, transport: UniTransport, retry: UniRetry = UniRetry()) {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.transport = transport
        self.retry = retry
    }

    // MARK: Regeln (rein)

    private static let userIDREs = [HText.regex(#"data-userid="(\d+)""#), HText.regex(#"data-user-id="(\d+)""#),
                                    HText.regex(#""userid"\s*:\s*"?(\d+)"#), HText.regex(#"user/profile\.php\?id=(\d+)"#)]

    /// Kennung des angemeldeten Nutzers aus einer Moodle-Seite (Nachrichten-Leiste, Profil-Link); nil, wenn unklar
    public static func userID(fromPage html: String) -> Int? {
        for re in userIDREs {
            if let s = HText.match(re, html)?.groups[1] ?? nil, let n = Int(s), n > 0 { return n }
        }
        return nil
    }

    static func isLoginURL(_ url: URL?) -> Bool {
        guard let s = url?.absoluteString else { return false }
        return s.contains("/login/index.php") || HildesheimCAS.isCASPage(s)
    }

    /// Transport-Fehler in Moodle-Fehler uebersetzen (HTTP-Status nach erschoepften Versuchen)
    private func fetch(_ req: UniRequest, retry: UniRetry) async throws -> UniResponse {
        do {
            return try await transport.fetch(req, retry: retry)
        } catch HildesheimError.http(let status, _) {
            throw MoodleError.http(status)
        } catch HildesheimError.sessionExpired {
            throw MoodleError.sessionExpired
        }
    }

    // MARK: Sitzung

    /// Eine Seite der Instanz lesen (GET); Anmeldeseite = abgelaufen
    public func page(_ path: String) async throws -> (html: String, url: URL) {
        guard let url = URL(string: path.hasPrefix("http") ? path : base + path) else { throw MoodleError.unexpectedPage(path) }
        let resp = try await fetch(UniRequest(url: url), retry: retry)
        let final = resp.finalURL ?? url
        if Self.isLoginURL(final) { throw MoodleError.sessionExpired }
        guard resp.status == 200 else { throw MoodleError.http(resp.status) }
        let html = resp.text
        guard Learnweb.isLoggedIn(html: html) else { throw MoodleError.sessionExpired }
        if session == nil, let k = Learnweb.sesskey(fromPage: html) { session = (k, Self.userID(fromPage: html)) }
        return (html, final)
    }

    /// sesskey und Nutzerkennung (aus der Nachrichten-Seite, die beides traegt)
    public func current() async throws -> (sesskey: String, userID: Int?) {
        if let s = session, s.userID != nil { return s }
        let (html, _) = try await page("/message/index.php")
        guard let k = Learnweb.sesskey(fromPage: html) else { throw MoodleError.sessionExpired }
        let s = (k, Self.userID(fromPage: html) ?? session?.userID)
        session = s
        return s
    }

    /// AJAX-Aufruf wie das Moodle selbst; `write`: genau ein Versuch
    public func ajax(_ function: String, _ args: JSONValue, write: Bool = false) async throws -> JSONValue {
        let key = try await current().sesskey
        guard let url = URL(string: "\(base)/lib/ajax/service.php?sesskey=\(key)&info=\(function)") else { throw MoodleError.unexpectedPage(function) }
        let payload = JSONValue.array([.object(["index": .number(0), "methodname": .string(function), "args": args])])
        let req = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/json"], body: payload.serialized())
        let resp = try await fetch(req, retry: write ? Self.once : retry)
        if Self.isLoginURL(resp.finalURL) { throw MoodleError.sessionExpired }
        guard resp.status == 200 else { throw MoodleError.http(resp.status) }
        guard let first = (try? JSONValue.parse(resp.body))?.array?.first else {
            if UniStore.startsLikeWebPage(resp.body) { session = nil; throw MoodleError.sessionExpired }
            throw MoodleError.unexpectedPage(function)
        }
        if first["error"]?.bool == true || first["exception"] != nil {
            let code = first["exception"]?["errorcode"]?.string ?? first["errorcode"]?.string ?? "error"
            if ["invalidsesskey", "servicerequireslogin", "requireloginerror", "sessionexpired"].contains(code) {
                session = nil
                throw MoodleError.sessionExpired
            }
            throw MoodleError.refused("\(function): \(code)")
        }
        return first["data"] ?? .null
    }

    /// Formular absenden (POST, application/x-www-form-urlencoded), genau ein Versuch; folgt der Weiterleitung
    public func postForm(_ path: String, _ fields: [(String, String)]) async throws -> (html: String, url: URL) {
        guard let url = URL(string: path.hasPrefix("http") ? path : base + path) else { throw MoodleError.unexpectedPage(path) }
        let req = UniRequest(url: url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: HText.form(fields))
        let resp = try await fetch(req, retry: Self.once)
        let final = resp.finalURL ?? url
        if Self.isLoginURL(final) { throw MoodleError.sessionExpired }
        guard (200..<300).contains(resp.status) else { throw MoodleError.http(resp.status) }
        return (resp.text, final)
    }

    /// Datei hochladen (multipart/form-data), genau ein Versuch; Antwort als JSON
    public func postMultipart(_ path: String, fields: [(String, String)], file: (field: String, name: String, mime: String, data: Data)) async throws -> JSONValue {
        guard let url = URL(string: base + path) else { throw MoodleError.unexpectedPage(path) }
        let boundary = "----StudiNow" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        let safeName = file.name.replacingOccurrences(of: "\"", with: "")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(safeName)\"\r\nContent-Type: \(file.mime)\r\n\r\n")
        body.append(file.data)
        add("\r\n--\(boundary)--\r\n")
        let req = UniRequest(url: url, method: "POST", headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body)
        let resp = try await fetch(req, retry: Self.once)
        if Self.isLoginURL(resp.finalURL) { throw MoodleError.sessionExpired }
        guard resp.status == 200 else { throw MoodleError.http(resp.status) }
        guard let j = try? JSONValue.parse(resp.body) else {
            if UniStore.startsLikeWebPage(resp.body) { throw MoodleError.sessionExpired }
            throw MoodleError.unexpectedPage("Upload")
        }
        if let e = j["error"]?.string, !e.isEmpty { throw MoodleError.refused("Upload: \(j["errorcode"]?.string ?? "error")") }
        return j
    }
}
