import Foundation

// Learnweb-Zugriff vom Geraet, nur lesend, zwei Wege wie app/learnweb.py:
//  1. Schluessel (Token aus dem Moodle-SSO oder selbst erzeugt): REST core_webservice_get_site_info ->
//     core_enrol_get_users_courses -> core_course_get_contents. Moodle verbucht dabei keine Aufrufe.
//  2. Sitzung (Cookies der Webansicht + sesskey der Seite): AJAX core_course_get_enrolled_courses_by_timeline_
//     classification + core_courseformat_get_state; Dateilinks ueber mod/resource/view.php?redirect=1 und die
//     Ordnerseite. core_course_get_contents ist per AJAX gesperrt (servicenotavailable, geprueft 25.10.2026).
// Das Netz liegt hinter `LearnwebTransport`, damit die Tests ohne Netzwerk laufen. Der Token steht nie in einer
// Adresse, nie in einer Fehlermeldung und nie in einer Beschreibung: REST und Downloads schicken ihn im
// Formular-Koerper (POST), erst beim Abruf.

// MARK: - Zugang (geschwaerzt)

/// Learnweb-Schluessel ("Moodle mobile web service"). Nicht Codable und in Beschreibungen geschwaerzt; die App legt
/// ihn nur im Schluesselbund ab (`keychainValue`).
public struct LearnwebToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let token: String
    /// privater Schluessel aus dem SSO (nur ueber HTTPS und nicht fuer Admins); wird hier nicht verwendet
    let privateToken: String?

    /// Moodle-Schluessel sind alphanumerisch (PARAM_ALPHANUM); alles andere wird abgelehnt.
    public init?(_ token: String, privateToken: String? = nil) {
        guard LearnwebToken.isAlnum(token, 16...256) else { return nil }
        self.token = token
        self.privateToken = privateToken.flatMap { LearnwebToken.isAlnum($0, 1...256) ? $0 : nil }
    }

    static func isAlnum(_ s: String, _ len: ClosedRange<Int>) -> Bool {
        len.contains(s.utf8.count) && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
    }

    /// Nur zum Ablegen im Schluesselbund der App.
    public var keychainValue: String { token }

    public var description: String { "LearnwebToken(***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Angemeldete Learnweb-Sitzung: der sesskey der Seite (M.cfg.sesskey); die Cookies haelt der Transport.
public struct LearnwebSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let sesskey: String

    public init?(sesskey: String) {
        guard LearnwebToken.isAlnum(sesskey, 1...64) else { return nil }
        self.sesskey = sesskey
    }

    /// sesskey aus dem HTML einer angemeldeten Moodle-Seite ("sesskey":"..." in M.cfg).
    public static func fromPage(html: String) -> LearnwebSession? {
        guard isLoggedIn(html: html),
              let k = LearnwebParsing.firstMatch(#""sesskey"\s*:\s*"([A-Za-z0-9]+)""#, in: html)?.groups[0] else { return nil }
        return LearnwebSession(sesskey: k)
    }

    /// Wie LOGGED_IN_JS: sesskey vorhanden und body ohne Klasse "notloggedin".
    public static func isLoggedIn(html: String) -> Bool {
        guard html.contains("sesskey") else { return false }
        if let body = LearnwebParsing.firstMatch(#"<body\b[^>]*\bclass\s*=\s*["']([^"']*)["']"#, in: html, caseless: true)?.groups[0],
           body.split(separator: " ").contains("notloggedin") { return false }
        return true
    }

    public var description: String { "LearnwebSession(sesskey: ***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - Transport

public struct LearnwebRequest: Sendable, CustomStringConvertible {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }
    public let method: Method
    /// nie mit Token
    public let url: URL
    public let contentType: String?
    /// kann den Token enthalten: nie loggen
    public let body: Data?
    /// false: Weiterleitung nicht folgen, sondern mit `location` antworten (mod/resource/view.php?redirect=1)
    public let followRedirects: Bool

    public init(method: Method, url: URL, contentType: String? = nil, body: Data? = nil, followRedirects: Bool = true) {
        self.method = method
        self.url = url
        self.contentType = contentType
        self.body = body
        self.followRedirects = followRedirects
    }

    /// ohne Koerper und ohne Abfrage (sesskey)
    public var description: String { "\(method.rawValue) \(LearnwebClient.scrub(url.absoluteString))" }
}

public struct LearnwebReply: Sendable {
    public let status: Int
    public let contentType: String
    /// Adresse nach allen Weiterleitungen (CAS-Anmeldung = Sitzung abgelaufen)
    public let finalURL: URL?
    /// Location-Kopf bei nicht verfolgter Weiterleitung
    public let location: String?
    public let body: Data

    public init(status: Int, contentType: String = "", finalURL: URL? = nil, location: String? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.finalURL = finalURL
        self.location = location
        self.body = body
    }
}

/// Netz fuer Learnweb: die App nutzt eine eigene URLSession (Cookies der Uni-Webansicht), Tests feste Antworten.
public protocol LearnwebTransport: Sendable {
    func send(_ request: LearnwebRequest) async throws -> LearnwebReply
}

// MARK: - Fehler

public enum LearnwebError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// HTML statt Datei, Weiterleitung auf das CAS oder die Moodle-Anmeldung: neu anmelden, nichts speichern
    case sessionExpired
    /// Schluessel ungueltig oder abgelaufen (invalidtoken): Sitzung oder neuen Schluessel verwenden
    case tokenRejected
    case moodle(function: String, code: String, message: String)
    case http(status: Int, path: String)
    case badResponse(String)
    /// Netzwerkfehler oder Zeitueberschreitung nach allen Versuchen
    case network(String)
    case ssoUnavailable(String)
    case ssoRejected(String)

    public var description: String {
        switch self {
        case .sessionExpired: return "Learnweb-Anmeldung abgelaufen. Bitte neu anmelden."
        case .tokenRejected: return "Der Learnweb-Schlüssel gilt nicht mehr. Bitte neu anmelden."
        case .moodle(let f, let c, let m): return "Learnweb meldet bei \(f): \(c)\(m.isEmpty ? "" : " (\(m))")"
        case .http(let s, let p): return "Learnweb antwortet mit HTTP \(s) (\(p))."
        case .badResponse(let r): return "Unerwartete Antwort vom Learnweb: \(r)"
        case .network(let r): return "Learnweb nicht erreichbar: \(r)"
        case .ssoUnavailable(let r): return "Anmeldung über die Learnweb-App-Schnittstelle nicht möglich: \(r)"
        case .ssoRejected(let r): return "Antwort der Learnweb-Anmeldung abgelehnt: \(r)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Wiederholen

/// Netzwerkfehler, Zeitueberschreitungen, 429 und 5xx: wiederholen mit wachsender Pause (Standard 3 Versuche).
public struct LearnwebRetry: Sendable {
    public var attempts: Int
    public var baseDelayMillis: UInt64
    public var sleep: @Sendable (UInt64) async throws -> Void

    public init(attempts: Int = 3, baseDelayMillis: UInt64 = 800,
                sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.attempts = max(1, attempts)
        self.baseDelayMillis = baseDelayMillis
        self.sleep = sleep
    }

    /// Pause vor Versuch `n` (ab 2): 1x, 2x, 4x ... baseDelayMillis
    func delayNanos(beforeAttempt n: Int) -> UInt64 { (baseDelayMillis * 1_000_000) << UInt64(max(0, n - 2)) }

    static func isRetryable(status: Int) -> Bool { status == 429 || (500...599).contains(status) }
}

// MARK: - Ergebnis eines Durchgangs

/// Ergebnis von `LearnwebClient.fetchAll`: je Kurs Dateien oder Fehler. Ein Fehler in einem Kurs ueberspringt nur
/// diesen Kurs; laeuft die Anmeldung ab, endet der Durchgang mit `needsLogin`, wird er abgebrochen, mit `cancelled`
/// (bisherige Kurse bleiben in beiden Faellen erhalten). Nur Kurse in `files` gelten als vollstaendig abgefragt.
public struct LearnwebSnapshot: Sendable, Equatable {
    public var courses: [LearnwebCourse] = []
    public var files: [String: [LearnwebFile]] = [:]
    public var failures: [String: String] = [:]
    public var needsLogin = false
    /// Durchgang abgebrochen (Task.cancel, z. B. Ansicht geschlossen): kein Fehler der Kurse, nichts daraus ableiten
    public var cancelled = false
    /// Kurse, die wegen abgelaufener Anmeldung oder Abbruch nicht (fertig) abgefragt wurden
    public var notAttempted: [String] = []

    public init() {}
}

// MARK: - Client

public actor LearnwebClient {
    public enum Access: Sendable {
        case token(LearnwebToken)
        case session(LearnwebSession)
    }

    public let base: URL
    private let access: Access
    private let transport: LearnwebTransport
    private let retry: LearnwebRetry
    /// CAS der Hochschule: Weiterleitung dorthin = Sitzung abgelaufen
    private let casBase: URL?
    public private(set) var requestCount = 0

    public init(base: URL, access: Access, transport: LearnwebTransport, retry: LearnwebRetry = LearnwebRetry(),
                casBase: URL? = UniversityProfile.hildesheimCAS) {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        self.base = URL(string: s) ?? base
        self.access = access
        self.transport = transport
        self.retry = retry
        self.casBase = casBase
    }

    public var usesToken: Bool { if case .token = access { return true }; return false }

    // MARK: Daten

    public func courses() async throws -> [LearnwebCourse] {
        switch access {
        case .token:
            guard let uid = try await call("core_webservice_get_site_info", [])["userid"]?.int else {
                throw LearnwebError.badResponse("site_info ohne userid")
            }
            let list = try await call("core_enrol_get_users_courses", [("userid", String(uid))])
            return (list.array ?? []).compactMap(LearnwebParsing.course)
        case .session:
            let data = try await ajax("core_course_get_enrolled_courses_by_timeline_classification",
                                      ["classification": "all", "limit": 0, "offset": 0, "sort": "fullname"])
            return (data["courses"]?.array ?? []).compactMap(LearnwebParsing.course)
        }
    }

    public func files(courseID: Int) async throws -> [LearnwebFile] {
        switch access {
        case .token:
            return LearnwebParsing.filesFromContents(try await call("core_course_get_contents", [("courseid", String(courseID))]))
        case .session:
            let raw = try await ajax("core_courseformat_get_state", ["courseid": .number(Double(courseID))])
            guard let text = raw.string, let state = try? JSONValue.parse(text) else {
                throw LearnwebError.badResponse("core_courseformat_get_state ohne Zustand")
            }
            return try await LearnwebParsing.filesFromState(state, resourceLinks: { try await self.resourceLinks(cmid: $0) },
                                                            folderLinks: { try await self.folderLinks(cmid: $0) })
        }
    }

    /// Alle sichtbaren Kurse (optional nur Semester mit `semesterFilter`), je Kurs die Dateiliste. Fehler je Kurs
    /// werden gesammelt; nur eine abgelaufene Anmeldung (`needsLogin`) oder ein Abbruch (`cancelled`) beendet den
    /// Durchgang, die restlichen Kurse stehen dann in `notAttempted`. Ein Abbruch schon beim Holen der Kursliste
    /// wirft `CancellationError`.
    public func fetchAll(semesterFilter: String? = nil) async throws -> LearnwebSnapshot {
        var snap = LearnwebSnapshot()
        var list = try await courses().filter { !$0.hidden }
        if let f = semesterFilter?.lowercased(), !f.isEmpty { list = list.filter { $0.semester.lowercased().contains(f) } }
        snap.courses = list
        courseLoop: for (i, c) in list.enumerated() {
            do {
                try Task.checkCancellation()
                snap.files[c.id] = try await files(courseID: c.moodleID)
            } catch LearnwebError.sessionExpired, LearnwebError.tokenRejected {
                snap.needsLogin = true
                snap.notAttempted = list[i...].map(\.id)
                break courseLoop
            } catch let e where e is CancellationError || Task.isCancelled {
                // Abbruch ist kein Fehler des Kurses (auch URLError(.cancelled) einer abgebrochenen Aufgabe)
                snap.cancelled = true
                snap.notAttempted = list[i...].map(\.id)
                break courseLoop
            } catch {
                snap.failures[c.id] = redact(String(describing: error))
            }
        }
        return snap
    }

    /// Inhalt einer Datei. Mit Schluessel: POST an die Pluginfile-Adresse mit `token` im Koerper (nie in der Adresse);
    /// mit Sitzung: GET mit den Cookies. Kommt eine HTML-Seite statt der Datei, ist die Anmeldung abgelaufen: nichts
    /// speichern (`sessionExpired`). Der Token geht nur an den eigenen Rechner ueber HTTPS.
    public func download(_ file: LearnwebFile) async throws -> Data {
        let reply = try await send(try downloadRequest(file))
        return try checkDownload(reply, name: file.name)
    }

    /// Anfrage fuer `download` (fuer den Transport der App und fuer Tests).
    public func downloadRequest(_ file: LearnwebFile) throws -> LearnwebRequest {
        guard let url = URL(string: file.downloadURL), url.host?.lowercased() == base.host?.lowercased(),
              url.scheme?.lowercased() == "https" else { throw LearnwebError.badResponse("fremde oder ungültige Adresse") }
        switch access {
        case .token(let t):
            return LearnwebRequest(method: .post, url: url, contentType: "application/x-www-form-urlencoded",
                                   body: Self.form([("token", t.token)]))
        case .session:
            return LearnwebRequest(method: .get, url: url)
        }
    }

    func checkDownload(_ r: LearnwebReply, name: String) throws -> Data {
        if isLogin(r.finalURL) { throw LearnwebError.sessionExpired }
        guard (200..<300).contains(r.status) else { throw LearnwebError.http(status: r.status, path: Self.scrub(r.finalURL?.absoluteString ?? "")) }
        let lower = name.lowercased()
        if Self.looksLikeHTML(r.body), !(lower.hasSuffix(".html") || lower.hasSuffix(".htm")) { throw LearnwebError.sessionExpired }
        // webservice/pluginfile.php meldet Fehler als JSON ({"error": ..., "errorcode": "invalidtoken"})
        if !lower.hasSuffix(".json"), r.body.first == UInt8(ascii: "{"), r.body.count < 4096,
           let j = try? JSONValue.parse(r.body), let code = j["errorcode"]?.string {
            if code == "invalidtoken" { throw LearnwebError.tokenRejected }
            throw LearnwebError.moodle(function: "pluginfile", code: code, message: "")
        }
        return r.body
    }

    /// Beginnt der Inhalt (nach Leerraum/BOM) mit <!doctype html oder <html?
    static func looksLikeHTML(_ body: Data) -> Bool {
        var bytes = body.prefix(512)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        while let c = bytes.first, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { bytes = bytes.dropFirst() }
        let head = String(decoding: bytes.prefix(15), as: UTF8.self).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    // MARK: REST (Schluessel)

    func call(_ fn: String, _ params: [(String, String)]) async throws -> JSONValue {
        guard case .token(let t) = access else { throw LearnwebError.badResponse("REST ohne Schlüssel") }
        let body = Self.form([("wstoken", t.token), ("wsfunction", fn), ("moodlewsrestformat", "json")] + params)
        let r = try await send(LearnwebRequest(method: .post, url: base.appendingPathComponent("webservice/rest/server.php"),
                                               contentType: "application/x-www-form-urlencoded", body: body))
        guard (200..<300).contains(r.status) else { throw LearnwebError.http(status: r.status, path: "webservice/rest/server.php") }
        guard let j = try? JSONValue.parse(r.body) else {
            if Self.looksLikeHTML(r.body) { throw LearnwebError.sessionExpired }
            throw LearnwebError.badResponse("kein JSON (\(fn))")
        }
        if j["exception"] != nil || j["errorcode"]?.string != nil {
            let code = j["errorcode"]?.string ?? "?"
            if code == "invalidtoken" { throw LearnwebError.tokenRejected }
            throw LearnwebError.moodle(function: fn, code: code, message: redact(String((j["message"]?.string ?? "").prefix(160))))
        }
        return j
    }

    // MARK: AJAX (Sitzung)

    func ajax(_ fn: String, _ args: JSONValue) async throws -> JSONValue {
        guard case .session(let s) = access else { throw LearnwebError.badResponse("AJAX ohne Sitzung") }
        let payload: JSONValue = [["index": 0, "methodname": .string(fn), "args": args]]
        let url = URL(string: base.absoluteString + "/lib/ajax/service.php?sesskey=\(s.sesskey)&info=\(fn)")!
        let r = try await send(LearnwebRequest(method: .post, url: url, contentType: "application/json", body: payload.serialized()))
        if isLogin(r.finalURL) { throw LearnwebError.sessionExpired }
        guard (200..<300).contains(r.status) else { throw LearnwebError.http(status: r.status, path: "lib/ajax/service.php") }
        guard let j = try? JSONValue.parse(r.body) else {
            if Self.looksLikeHTML(r.body) { throw LearnwebError.sessionExpired }
            throw LearnwebError.badResponse("kein JSON (\(fn))")
        }
        let first = j.array?.first ?? j
        if first["error"]?.bool == true || first["exception"] != nil {
            let ex = first["exception"] ?? first
            let code = ex["errorcode"]?.string ?? "?"
            if ["servicerequireslogin", "requireloginerror", "invalidsesskey", "sessionexpired"].contains(code) {
                throw LearnwebError.sessionExpired
            }
            throw LearnwebError.moodle(function: fn, code: code, message: redact(String((ex["message"]?.string ?? "").prefix(160))))
        }
        return first["data"] ?? .null
    }

    /// mod/resource/view.php?id=<cmid>&redirect=1 nur bis zur Weiterleitung (ohne Inhalt); Anzeigeart "eingebettet":
    /// Link aus der Seite.
    func resourceLinks(cmid: String) async throws -> [String] {
        guard Self.isDigits(cmid), let url = URL(string: base.absoluteString + "/mod/resource/view.php?id=\(cmid)&redirect=1") else { return [] }
        let r = try await send(LearnwebRequest(method: .get, url: url, followRedirects: false))
        if isLogin(r.finalURL) { throw LearnwebError.sessionExpired }
        if let loc = r.location {
            let abs = URL(string: loc, relativeTo: URL(string: base.absoluteString + "/"))?.absoluteURL
            if isLogin(abs) { throw LearnwebError.sessionExpired }
            if loc.contains("pluginfile.php"), let a = abs?.absoluteString { return [a] }
        }
        try Self.checkLinkPage(r, path: "mod/resource/view.php")
        guard r.status < 400 else { return [] }
        return LearnwebParsing.embeddedResourceLink(html: String(decoding: r.body, as: UTF8.self)).map { [$0] } ?? []
    }

    func folderLinks(cmid: String) async throws -> [String] {
        guard Self.isDigits(cmid), let url = URL(string: base.absoluteString + "/mod/folder/view.php?id=\(cmid)") else { return [] }
        let r = try await send(LearnwebRequest(method: .get, url: url))
        if isLogin(r.finalURL) { throw LearnwebError.sessionExpired }
        try Self.checkLinkPage(r, path: "mod/folder/view.php")
        guard r.status < 400 else { return [] }
        return LearnwebParsing.folderLinks(html: String(decoding: r.body, as: UTF8.self))
    }

    /// 429/5xx auch nach allen Versuchen: der Kurs ist nicht vollstaendig abgefragt -> Fehler des Kurses (Ausfallregel:
    /// wiederholen, danach Kurs ueberspringen), nie still eine kuerzere Dateiliste. 403/404 (Inhalt nicht sichtbar)
    /// bleiben wie am PC eine leere Liste.
    static func checkLinkPage(_ r: LearnwebReply, path: String) throws {
        if LearnwebRetry.isRetryable(status: r.status) { throw LearnwebError.http(status: r.status, path: path) }
    }

    // MARK: Senden mit Wiederholung

    func send(_ request: LearnwebRequest) async throws -> LearnwebReply {
        var last: Error = LearnwebError.network("keine Antwort")
        for attempt in 1...retry.attempts {
            if attempt > 1 { try await retry.sleep(retry.delayNanos(beforeAttempt: attempt)) }
            try Task.checkCancellation()
            requestCount += 1
            do {
                let r = try await transport.send(request)
                if LearnwebRetry.isRetryable(status: r.status), attempt < retry.attempts {
                    last = LearnwebError.http(status: r.status, path: Self.scrub(request.url.absoluteString))
                    continue
                }
                return r
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as LearnwebError {
                throw e
            } catch {
                // abgebrochene Aufgabe (URLSession meldet dann URLError(.cancelled)): nicht wiederholen, Abbruch melden
                if Task.isCancelled { throw CancellationError() }
                last = LearnwebError.network(redact((error as NSError).localizedDescription))
            }
        }
        throw last
    }

    // MARK: Hilfen

    /// Weiterleitung auf das CAS oder die Moodle-Anmeldung
    func isLogin(_ url: URL?) -> Bool {
        guard let url else { return false }
        if let casBase, CASLogin.isLoginPage(url, casBase: casBase) { return true }
        return url.host?.lowercased() == base.host?.lowercased() && url.path.hasPrefix(base.path + "/login/")
    }

    static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (0x30...0x39).contains($0) } }

    /// Token und sesskey aus Texten entfernen (Fehlermeldungen von aussen).
    func redact(_ s: String) -> String {
        var out = s
        switch access {
        case .token(let t):
            out = out.replacingOccurrences(of: t.token, with: "***")
            if let p = t.privateToken { out = out.replacingOccurrences(of: p, with: "***") }
        case .session(let x): out = out.replacingOccurrences(of: x.sesskey, with: "***")
        }
        return out
    }

    /// Pfad ohne Abfrage (keine sesskeys oder IDs in Meldungen)
    static func scrub(_ address: String) -> String {
        let noQuery = address.split(separator: "?", maxSplits: 1).first.map(String.init) ?? address
        return noQuery.split(separator: "#", maxSplits: 1).first.map(String.init) ?? noQuery
    }

    /// application/x-www-form-urlencoded wie urllib.parse.urlencode (quote_plus)
    static func form(_ pairs: [(String, String)]) -> Data {
        func enc(_ s: String) -> String {
            var out = ""
            for byte in s.utf8 {
                switch byte {
                case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2E, 0x2D, 0x7E: out.append(Character(Unicode.Scalar(byte)))
                case 0x20: out.append("+")
                default: out += String(format: "%%%02X", byte)
                }
            }
            return out
        }
        return Data(pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&").utf8)
    }
}
