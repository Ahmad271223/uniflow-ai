import Foundation

// Stud.IP direkt vom Geraet: die Anmeldung laeuft auf der echten Hochschulseite (WebSSO), danach nutzt die App
// das Sitzungs-Cookie fuer die JSON:API. Dieselben Routen wie app/studip_sync.py; am 25.10.2026 an der LUH
// geprueft: Ordnerbaum ueber die API liefert dieselben 151 Dateien wie der PC-Abgleich, Download per
// file-refs/{id}/content byte-genau.

/// Antwort einer HTTP-Anfrage. Ohne URLSession, damit der Kern auch unter Linux testbar bleibt.
public struct HTTPReply: Sendable {
    public let status: Int
    public let contentType: String
    public let finalURL: URL?
    public let body: Data

    public init(status: Int, contentType: String = "", finalURL: URL? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.finalURL = finalURL
        self.body = body
    }
}

/// Transport fuer Stud.IP-Anfragen: die App setzt das Sitzungs-Cookie, Tests liefern feste Antworten.
public protocol StudIPTransport: Sendable {
    func get(_ url: URL, accept: String?) async throws -> HTTPReply
    /// Antwort direkt in `file` schreiben (grosse Dateien nicht im Arbeitsspeicher); `body` der Rueckgabe ist leer.
    func download(_ url: URL, to file: URL) async throws -> HTTPReply
}

extension StudIPTransport {
    /// Ersatz fuer Transporte ohne eigenen Download (Tests): ueber `get`, danach in die Datei.
    public func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        let r = try await get(url, accept: nil)
        try r.body.write(to: file, options: .atomic)
        return HTTPReply(status: r.status, contentType: r.contentType, finalURL: r.finalURL)
    }
}

public enum StudIPError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 401 oder Weiterleitung auf die Anmeldeseite: Nutzer muss sich neu anmelden.
    case sessionExpired
    case http(status: Int, path: String)
    case badResponse(String)
    case requestLimit

    public var description: String {
        switch self {
        case .sessionExpired: return "Stud.IP-Anmeldung abgelaufen. Bitte neu anmelden."
        case .http(let s, let p): return "Stud.IP antwortet mit HTTP \(s) (\(p))."
        case .badResponse(let r): return "Unerwartete Antwort von Stud.IP: \(r)"
        case .requestLimit: return "Abgleich abgebrochen: zu viele Anfragen in einem Durchgang."
        }
    }

    public var errorDescription: String? { description }

    /// Fehler, der nur einen Kurs oder eine Datei betrifft (HTTP-Fehler, unerwartete Antwort, z. B. ein Kurs ohne
    /// Dateibereich oder eine gesperrte Datei): Der Abgleich macht wie run_sync in app/studip_sync.py mit dem
    /// naechsten weiter. Abgelaufene Sitzung und Anfragegrenze brechen den Lauf ab.
    public var affectsOnlyItem: Bool {
        switch self {
        case .http, .badResponse: return true
        case .sessionExpired, .requestLimit: return false
        }
    }
}

public struct StudIPCourse: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let number: String?
    public let semesterTitle: String?
    /// Beginn des Startsemesters wie geliefert (ISO-8601), zum Sortieren und fuer die Vorauswahl.
    public let semesterStart: String?

    public init(id: String, title: String, number: String? = nil, semesterTitle: String? = nil, semesterStart: String? = nil) {
        self.id = id
        self.title = title
        self.number = number
        self.semesterTitle = semesterTitle
        self.semesterStart = semesterStart
    }
}

public struct StudIPFile: Sendable, Equatable, Codable {
    public let id: String
    public let courseID: String
    public let name: String
    public let size: Int
    public let mimeType: String?
    /// Aenderungszeitpunkt wie geliefert; dient nur dem Vergleich mit dem lokalen Stand.
    public let changed: String
    public let isDownloadable: Bool
    /// Ordnerpfad im Kurs ohne Wurzelordner, z. B. "Vorlesung/Folien".
    public let folderPath: String

    public init(id: String, courseID: String, name: String, size: Int, mimeType: String? = nil, changed: String,
                isDownloadable: Bool = true, folderPath: String = "") {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.changed = changed
        self.isDownloadable = isDownloadable
        self.folderPath = folderPath
    }
}

/// Nur lesender Zugriff auf die Stud.IP-JSON:API. Anfragen laufen nacheinander mit kurzer Pause, damit der
/// Abgleich die Hochschule nicht staerker belastet als ein Mensch, der durch die Ordner klickt.
public actor StudIPClient {
    public let base: URL
    private let transport: StudIPTransport
    private let pauseNanos: UInt64
    private let maxRequests: Int
    public private(set) var requestCount = 0

    static let jsonAPI = "application/vnd.api+json"

    public init(base: URL, transport: StudIPTransport, pauseMillis: UInt64 = 250, maxRequests: Int = 1500) {
        self.base = base
        self.transport = transport
        self.pauseNanos = pauseMillis * 1_000_000
        self.maxRequests = maxRequests
    }

    // MARK: Anfragen

    /// Pfad (mit oder ohne fuehrenden Schraegstrich) oder vollstaendiger Link aus `links.next`; nur der eigene Host.
    func url(_ pathOrLink: String) throws -> URL {
        var s = pathOrLink
        if !(s.hasPrefix("http://") || s.hasPrefix("https://")) {
            var b = base.absoluteString
            while b.hasSuffix("/") { b.removeLast() }
            s = b + (s.hasPrefix("/") ? "" : "/") + s
        }
        // eckige Klammern (page[limit]) sind in URLs nicht erlaubt; Stud.IP versteht die kodierte Form
        s = s.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
        guard let u = URL(string: s), u.host == base.host else { throw StudIPError.badResponse("fremde oder ungültige Adresse") }
        return u
    }

    /// Pfad ohne Kennungen fuer Fehlermeldungen (keine Kurs- oder Datei-IDs im Protokoll).
    static func scrub(_ path: String) -> String {
        let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return noQuery.replacingOccurrences(of: "[0-9a-f]{32}", with: ":id", options: .regularExpression)
    }

    private func send(_ pathOrLink: String, accept: String?) async throws -> HTTPReply {
        let transport = self.transport
        return try await perform(pathOrLink) { try await transport.get($0, accept: accept) }
    }

    /// Eine Anfrage mit Pause und Anfragegrenze; abgelaufene Sitzung und HTTP-Fehler werden zu `StudIPError`.
    private func perform(_ pathOrLink: String, _ call: (URL) async throws -> HTTPReply) async throws -> HTTPReply {
        guard requestCount < maxRequests else { throw StudIPError.requestLimit }
        if requestCount > 0, pauseNanos > 0 { try await Task.sleep(nanoseconds: pauseNanos) }
        requestCount += 1
        let reply = try await call(try url(pathOrLink))
        if reply.status == 401 || Self.looksLikeLogin(reply) { throw StudIPError.sessionExpired }
        guard (200..<300).contains(reply.status) else { throw StudIPError.http(status: reply.status, path: Self.scrub(pathOrLink)) }
        return reply
    }

    /// Abgelaufene Sitzung: Stud.IP leitet Seitenaufrufe auf die Anmeldung (bzw. die SSO-Seite) um.
    static func looksLikeLogin(_ r: HTTPReply) -> Bool {
        guard let u = r.finalURL else { return false }
        let p = u.path.lowercased()
        return p.contains("/dispatch.php/login") || p.contains("/idp/") || (u.host ?? "").hasPrefix("sso.")
    }

    func json(_ pathOrLink: String) async throws -> JSONValue {
        let r = try await send(pathOrLink, accept: Self.jsonAPI)
        if r.contentType.lowercased().contains("text/html") { throw StudIPError.sessionExpired }
        do { return try JSONValue.parse(r.body) } catch { throw StudIPError.badResponse("kein JSON (\(Self.scrub(pathOrLink)))") }
    }

    /// Alle Seiten einer Liste (JSON:API `links.next`); `included` wird mitgesammelt.
    func list(_ path: String) async throws -> (data: [JSONValue], included: [JSONValue]) {
        var data: [JSONValue] = [], included: [JSONValue] = []
        var next: String? = path
        var seen = Set<String>()
        while let n = next, !seen.contains(n) {
            seen.insert(n)
            let j = try await json(n)
            data += j["data"]?.array ?? []
            included += j["included"]?.array ?? []
            next = j["links"]?["next"]?.string
        }
        return (data, included)
    }

    // MARK: Daten

    public func currentUserID() async throws -> String {
        guard let id = try await json("jsonapi.php/v1/users/me")["data"]?["id"]?.string else {
            throw StudIPError.badResponse("users/me ohne ID")
        }
        return id
    }

    public func courses(userID: String) async throws -> [StudIPCourse] {
        let (data, included) = try await list("jsonapi.php/v1/users/\(userID)/courses?page[limit]=100&include=start-semester")
        var semesters: [String: (title: String?, start: String?)] = [:]
        for i in included where i["type"]?.string == "semesters" {
            if let id = i["id"]?.string { semesters[id] = (i["attributes"]?["title"]?.string, i["attributes"]?["start"]?.string) }
        }
        return data.compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            let a = c["attributes"]
            let semID = c["relationships"]?["start-semester"]?["data"]?["id"]?.string
            let title = (a?["title"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let number = a?["course-number"]?.string?.trimmingCharacters(in: .whitespaces)
            return StudIPCourse(id: id, title: title.isEmpty ? "Kurs" : title, number: (number?.isEmpty ?? true) ? nil : number,
                                semesterTitle: semID.flatMap { semesters[$0]?.title }, semesterStart: semID.flatMap { semesters[$0]?.start })
        }
    }

    /// Alle Dateien eines Kurses ueber den Ordnerbaum (Wurzelordner -> Unterordner, hoechstens 6 Ebenen tief).
    public func files(courseID: String) async throws -> [StudIPFile] {
        let (tops, _) = try await list("jsonapi.php/v1/courses/\(courseID)/folders?page[limit]=200")
        let roots = tops.filter { $0["attributes"]?["folder-type"]?.string == "RootFolder" }
        var out: [StudIPFile] = []
        var seen = Set<String>()
        for root in (roots.isEmpty ? Array(tops.prefix(1)) : roots) {
            guard let id = root["id"]?.string else { continue }
            try await walk(folderID: id, path: "", depth: 0, courseID: courseID, seen: &seen, into: &out)
        }
        return out
    }

    private func walk(folderID: String, path: String, depth: Int, courseID: String,
                      seen: inout Set<String>, into out: inout [StudIPFile]) async throws {
        guard depth <= 6, !seen.contains(folderID) else { return }
        seen.insert(folderID)
        let (refs, _) = try await list("jsonapi.php/v1/folders/\(folderID)/file-refs?page[limit]=500")
        for r in refs {
            guard let id = r["id"]?.string else { continue }
            let a = r["attributes"]
            let changed = a?["chdate"]?.string ?? a?["chdate"]?.double.map { JSONValue.format($0) } ?? ""
            out.append(StudIPFile(id: id, courseID: courseID, name: a?["name"]?.string ?? id, size: a?["filesize"]?.int ?? 0,
                                  mimeType: a?["mime-type"]?.string, changed: changed,
                                  isDownloadable: a?["is-downloadable"]?.bool ?? true, folderPath: path))
        }
        let (subs, _) = try await list("jsonapi.php/v1/folders/\(folderID)/folders?page[limit]=200")
        for s in subs {
            guard let id = s["id"]?.string else { continue }
            let name = (s["attributes"]?["name"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            try await walk(folderID: id, path: path.isEmpty ? name : "\(path)/\(name)", depth: depth + 1,
                           courseID: courseID, seen: &seen, into: &out)
        }
    }

    /// Inhalt einer Datei direkt nach `file` (grosse Dateien nicht im Arbeitsspeicher). Liefert Stud.IP statt der
    /// Datei eine HTML-Anmeldeseite, ist die Sitzung abgelaufen. Bei jedem Fehler bleibt keine halbe Datei liegen.
    public func download(fileID: String, to file: URL) async throws {
        let transport = self.transport
        do {
            let r = try await perform("jsonapi.php/v1/file-refs/\(fileID)/content") { try await transport.download($0, to: file) }
            if r.contentType.lowercased().contains("text/html"), Self.head(of: file).lowercased().contains("login") {
                throw StudIPError.sessionExpired
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Anfang einer Datei als Text (Erkennen der Anmeldeseite, ohne die ganze Datei zu lesen)
    static func head(of file: URL, bytes: Int = 4000) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? h.close() }
        return String(decoding: (try? h.read(upToCount: bytes)) ?? Data(), as: UTF8.self)
    }
}
