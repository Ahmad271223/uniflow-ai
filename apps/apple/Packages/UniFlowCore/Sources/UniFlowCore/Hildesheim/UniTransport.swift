import Foundation

/// HTTP fuer Hochschul-Abgleiche (Learnweb, LSF), ohne URLSession im Kern: die App setzt eine Umsetzung mit
/// URLSession und den Cookies der Hochschule ein (eigener Datenspeicher je Nutzer und Uni), Tests feste Antworten.
public struct UniRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// false: Weiterleitungen nicht folgen (Moodle-Dateilink: nur den Location-Header lesen)
    public var followRedirects: Bool

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, followRedirects: Bool = true) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
    }
}

public struct UniResponse: Sendable {
    public let status: Int
    /// Kopfzeilen mit kleingeschriebenen Namen
    public let headers: [String: String]
    public let finalURL: URL?
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], finalURL: URL? = nil, body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.finalURL = finalURL
        self.body = body
    }

    /// Text des Inhalts (UTF-8, sonst Latin-1 wie aeltere HIS-Seiten)
    public var text: String { String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? "" }
}

public protocol UniTransport: Sendable {
    func send(_ request: UniRequest) async throws -> UniResponse
    /// Inhalt direkt in eine Datei schreiben (nicht im Arbeitsspeicher halten); `body` der Antwort bleibt leer.
    func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse
}

public enum HildesheimError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Weiterleitung auf die CAS-Loginseite oder Moodle-Login: neu anmelden
    case sessionExpired(String)
    /// Learnweb-Schluessel ungueltig oder zurueckgezogen
    case invalidToken
    case http(status: Int, url: String)
    case badResponse(String)
    /// Statt einer Datei kam eine Webseite (meist abgelaufene Anmeldung); nichts gespeichert
    case htmlInsteadOfFile(String)
    case noLearnwebInstance

    public var description: String {
        switch self {
        case .sessionExpired(let s): return "Anmeldung bei \(s) abgelaufen. Bitte neu anmelden."
        case .invalidToken: return "Der Learnweb-Schlüssel gilt nicht mehr. Bitte neu verbinden."
        case .http(let s, let u): return "HTTP \(s) bei \(u)"
        case .badResponse(let r): return "Unerwartete Antwort: \(r)"
        case .htmlInsteadOfFile(let u): return "Statt der Datei kam eine Webseite zurück (Anmeldung abgelaufen?): \(u)"
        case .noLearnwebInstance: return "Kein Learnweb für das aktuelle Semester erreichbar."
        }
    }

    public var errorDescription: String? { description }

    /// Lohnt ein zweiter Versuch? (Netz, Zeitueberschreitung, 5xx, 429 ja; Anmeldung und Inhalt nein)
    var isTransient: Bool {
        if case .http(let s, _) = self { return s == 429 || s >= 500 }
        return false
    }
}

/// Wiederholungen bei Netzfehlern: abgerissene Verbindung, Zeitueberschreitung, 5xx und 429.
public struct UniRetry: Sendable {
    public var attempts: Int
    /// Wartezeit vor Versuch n (n ab 1) in Nanosekunden; Tests setzen 0
    public var delayNanos: @Sendable (Int) -> UInt64

    public init(attempts: Int = 3, delayNanos: @escaping @Sendable (Int) -> UInt64 = { UInt64($0) * 1_500_000_000 }) {
        self.attempts = attempts
        self.delayNanos = delayNanos
    }

    public static let none = UniRetry(attempts: 1, delayNanos: { _ in 0 })

    func run<T>(_ body: () async throws -> T) async throws -> T {
        var last: Error?
        for n in 0..<max(1, attempts) {
            if n > 0 { try? await Task.sleep(nanoseconds: delayNanos(n)) }
            do {
                return try await body()
            } catch let e as HildesheimError where !e.isTransient {
                throw e
            } catch {
                last = error
            }
        }
        throw last ?? HildesheimError.badResponse("unbekannter Fehler")
    }
}

extension UniTransport {
    /// GET/POST mit Wiederholungen; 5xx/429 werden zu `HildesheimError.http` (wiederholbar), andere Fehlercodes nicht.
    func fetch(_ r: UniRequest, retry: UniRetry) async throws -> UniResponse {
        try await retry.run {
            let resp = try await send(r)
            if resp.status == 429 || resp.status >= 500 { throw HildesheimError.http(status: resp.status, url: r.url.absoluteString) }
            return resp
        }
    }
}
