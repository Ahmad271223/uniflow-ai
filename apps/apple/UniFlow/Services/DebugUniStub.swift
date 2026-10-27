import Foundation
import UniFlowCore
import WebKit

/// Nur Debug-Builds, Startargument `-UFLoginStub <ordner>`: der erste Start und die Abgleiche laufen gegen lokale
/// Nachbildungen statt gegen die Seiten der Hochschulen (Simulator, Bildschirmfotos, Pruefung mit erfundenen Daten;
/// nie eine echte Uni-Seite, nie ein Netz). Im Release-Build gibt es nichts davon.
///
/// Im Ordner liegen:
/// - `studip.html`, `qis.html`, `learnweb.html`, `lsf.html`: Anmeldeseiten, die die Anmeldeansichten statt der echten
///   Seite laden (file-URL). Eine Seite `<dienst>-angemeldet.html`
///   gilt als angemeldet, sobald die Webansicht sie zeigt (der Knopf "Anmelden" der Nachbildung fuehrt dorthin).
/// - `routes.json`: Antworten der Abgleiche (Stud.IP JSON:API, Opencast, QIS, Learnweb, LSF): Liste von
///   `{"match": "<Teil der Adresse>", "bodyMatch": "<Teil des Anfrage-Koerpers>", "file": "<Datei im Ordner>" | "body": "<Text>",
///   "status": 200, "contentType": "..."}`; die erste passende Zeile antwortet (Learnweb-REST unterscheidet sich nur im
///   Koerper), ohne Treffer 404.
enum DebugUniStub {
    /// Ordner der Nachbildungen; nil ohne Startargument oder im Release
    static var directory: URL? {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "UFLoginStub"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }

    static var isActive: Bool { directory != nil }

    /// Anmeldeseite eines Dienstes ("studip", "qis", "learnweb", "lsf"): die Nachbildung, sonst die echte Adresse
    static func loginPage(_ service: String, real: URL) -> URL {
        guard let dir = directory else { return real }
        let page = dir.appendingPathComponent("\(service).html")
        return FileManager.default.fileExists(atPath: page.path) ? page : real
    }

    /// Zeigt die Webansicht die Seite "<dienst>-angemeldet.html" der Nachbildung?
    static func isSignedIn(_ url: URL?, service: String) -> Bool {
        guard isActive, let url, url.isFileURL else { return false }
        return url.lastPathComponent == "\(service)-angemeldet.html"
    }

    /// Erfundenes Sitzungs-Cookie fuer die Stud.IP-Anmeldung der Nachbildung (leer gaelte als abgemeldet)
    static func studipCookies() -> [HTTPCookie] {
        guard isActive, let host = StudIPSync.base.host else { return [] }
        return [HTTPCookie(properties: [.name: "Seminar_Session", .value: "stub-sitzung", .domain: host, .path: "/", .secure: "TRUE",
                                        .expires: Date().addingTimeInterval(7 * 24 * 3600)])].compactMap { $0 }
    }

    /// Transport der Abgleiche (Learnweb/LSF, QIS) aus `routes.json`; nil ohne Stub (dann URLSession)
    static var transportFactory: (@MainActor (WKWebsiteDataStore) async -> UniTransport)? {
        guard let t = transport() else { return nil }
        return { _ in t }
    }

    /// Stud.IP-Transport aus `routes.json`; nil ohne Stub
    static func studipTransport() -> StudIPTransport? { transport() }

    private static func transport() -> DebugStubTransport? {
        guard let dir = directory else { return nil }
        return DebugStubTransport(directory: dir)
    }
}

/// Feste Antworten aus `routes.json` eines Ordners (nur Debug-Stub). Nichts geht ins Netz.
final class DebugStubTransport: UniTransport, StudIPTransport, @unchecked Sendable {
    struct Route: Decodable {
        let match: String
        /// Text, der im Koerper der Anfrage stehen muss (POST-Formulare des Learnweb)
        var bodyMatch: String?
        var status: Int?
        var file: String?
        var body: String?
        var contentType: String?
    }

    let directory: URL
    private let routes: [Route]

    init(directory: URL) {
        self.directory = directory
        let data = (try? Data(contentsOf: directory.appendingPathComponent("routes.json"))) ?? Data()
        routes = (try? JSONDecoder().decode([Route].self, from: data)) ?? []
    }

    func reply(_ url: URL, body: Data? = nil) -> UniResponse {
        let address = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let text = String(decoding: body ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
        guard let r = routes.first(where: { address.contains($0.match) && ($0.bodyMatch.map { text.contains($0) } ?? true) }) else {
            return UniResponse(status: 404, headers: ["Content-Type": "text/plain"], finalURL: url, body: Data("nicht im Stub".utf8))
        }
        var body = Data()
        if let f = r.file { body = (try? Data(contentsOf: directory.appendingPathComponent(f))) ?? Data() }
        else if let b = r.body { body = Data(b.utf8) }
        let type = r.contentType ?? (r.file?.hasSuffix(".json") == true ? "application/vnd.api+json"
                                     : r.file?.hasSuffix(".pdf") == true ? "application/pdf" : "text/html; charset=utf-8")
        return UniResponse(status: r.status ?? 200, headers: ["Content-Type": type], finalURL: url, body: body)
    }

    // UniTransport
    func send(_ request: UniRequest) async throws -> UniResponse { reply(request.url, body: request.body) }

    func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse {
        let r = reply(request.url, body: request.body)
        try r.body.write(to: destination)
        return UniResponse(status: r.status, headers: r.headers, finalURL: r.finalURL)
    }

    // StudIPTransport
    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let r = reply(url)
        return HTTPReply(status: r.status, contentType: r.headers["content-type"] ?? "", finalURL: r.finalURL, body: r.body)
    }

    func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        let r = try await download(UniRequest(url: url), to: file)
        return HTTPReply(status: r.status, contentType: r.headers["content-type"] ?? "", finalURL: r.finalURL)
    }
}
