import Foundation
import UniFlowCore

struct APIError: LocalizedError {
    let status: Int
    let message: String
    /// wie api() in core.js: Text aus "detail" der Antwort, sonst der HTTP-Statustext (z. B. "Not Found")
    var errorDescription: String? {
        if let v = try? JSONValue.parse(message), let d = v["detail"]?.string, !d.isEmpty { return d }
        return status > 0 ? HTTPURLResponse.localizedString(forStatusCode: status).capitalized : message
    }
}

/// HTTP-Status fuer die Synchronisierung: 401/403 sind nicht "Offline", 5xx ist ein Serverfehler. Ohne Antwort
/// (`status <= 0`) gilt der Fehler als Netzfehler.
extension APIError: HTTPStatusError {
    var httpStatus: Int { status }
    /// "detail" der Antwort (z. B. 409 "noch nicht moeglich" des lokalen Backends)
    var httpDetail: String? {
        guard let v = try? JSONValue.parse(message), let d = v["detail"]?.string, !d.isEmpty else { return nil }
        return d
    }
}

/// Weg einer Anfrage: ins Netz zum eigenen Server (`HTTPTransport`) oder an das lokale Backend des Geraets
/// (`LocalTransport`, Services/LocalBackendHost.swift). Antworten kommen in beiden Faellen als HTTPURLResponse mit
/// Status und JSON wie bei FastAPI, Fehler also auch lokal als `{"detail": ...}`.
protocol APITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Eigener UniFlow-Server ueber URLSession. Die PIN geht als Cookie mit (wie im Browser).
struct HTTPTransport: APITransport {
    let pin: String?
    private let session: URLSession

    init(pin: String?) {
        self.pin = pin
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = request
        if let pin, !pin.isEmpty { r.setValue("lernapp_pin=\(pin)", forHTTPHeaderField: "Cookie") }
        let (d, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError(status: -1, message: "Keine HTTP-Antwort") }
        return (d, http)
    }
}

/// Zugriff auf die `/api/`-Pfade: beim eigenen Server ueber HTTP, sonst beim lokalen Backend (Basis
/// `uniflow-local://device/`, trennt auch den Zwischenspeicher von Serverdaten). Die Ansichten sehen in beiden
/// Faellen dieselben Antworten. Unveraenderlich nach dem Anlegen und daher sicher von mehreren Threads nutzbar.
final class APIClient: @unchecked Sendable {
    /// Basis-URL des lokalen Backends
    static let localBase = URL(string: "uniflow-local://device/")!

    let base: URL
    let transport: APITransport
    /// PIN fuer eingebettete Web-Ansichten (Cookie lernapp_pin); lokal nil
    var pinValue: String? { (transport as? HTTPTransport)?.pin }
    /// Antworten kommen vom lokalen Backend dieses Geraets
    var isLocal: Bool { base.scheme == DataSourceNamespace.localScheme }
    /// Datenquelle fuer Journal und Zwischenspeicher (lokal oder dieser Server)
    var namespace: DataSourceNamespace { DataSourceNamespace(base: base) }

    /// Eigener UniFlow-Server
    convenience init(base: URL, pin: String?) {
        self.init(base: base, transport: HTTPTransport(pin: pin))
    }

    init(base: URL, transport: APITransport) {
        self.base = base
        self.transport = transport
    }

    /// Lokales Backend des Geraets
    static func local(_ host: LocalBackendHost = .shared) -> APIClient {
        APIClient(base: localBase, transport: LocalTransport(host: host))
    }

    private func request(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw APIError(status: -1, message: "Ungültiger Pfad \(path)")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await transport.send(try request(path, method: method, body: body))
    }

    func json<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (d, http) = try await data(path)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: String(decoding: d.prefix(400), as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: d)
    }

    /// Datei hochladen (multipart/form-data), z. B. PDF-Import ueber `POST /api/notebooks`.
    func upload(_ path: String, fields: [String: String], fileField: String, fileName: String, mimeType: String, data: Data) async throws -> JSONValue {
        try await form(path, fields: fields, file: (fileField, fileName, mimeType, data))
    }

    /// Formular wie FormData im Web (multipart/form-data), Datei optional
    func form(_ path: String, fields: [String: String], file: (field: String, name: String, mime: String, data: Data)? = nil) async throws -> JSONValue {
        let boundary = "uniflow-" + UUID().uuidString
        let crlf = "\r\n"
        var body = Data()
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data(("--" + boundary + crlf + "Content-Disposition: form-data; name=\"" + k + "\"" + crlf + crlf + v + crlf).utf8))
        }
        if let file {
            let safeName = file.name.components(separatedBy: CharacterSet(charactersIn: "\"\r\n")).joined(separator: "_")
            body.append(Data(("--" + boundary + crlf + "Content-Disposition: form-data; name=\"" + file.field + "\"; filename=\"" + safeName + "\"" + crlf
                              + "Content-Type: " + file.mime + crlf + crlf).utf8))
            body.append(file.data)
            body.append(Data(crlf.utf8))
        }
        body.append(Data(("--" + boundary + "--" + crlf).utf8))
        var r = try request(path, method: "POST", body: nil)
        r.httpBody = body
        r.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let (d, http) = try await transport.send(r)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: String(decoding: d.prefix(400), as: UTF8.self))
        }
        return try JSONValue.parse(d)
    }

    /// Roh-JSON (verlustfrei, auch fuer Felder, die die App nicht kennt).
    func value(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        let (d, http) = try await data(path, method: method, body: body?.serialized())
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: String(decoding: d.prefix(400), as: UTF8.self))
        }
        return d.isEmpty ? .null : try JSONValue.parse(d)
    }
}

/// Notizen ueber `GET/PUT /api/files/{id}/annotations` (409 bei Konflikt, siehe app/server.py).
struct HTTPAnnotationTransport: AnnotationTransport {
    let api: APIClient

    func fetch(documentID: String) async throws -> ServerSnapshot {
        let v = try await api.value("/api/files/\(documentID)/annotations")
        return ServerSnapshot(version: v["version"]?.int ?? 0, root: v["data"] ?? AnnotationDocument.emptyRoot)
    }

    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        let (d, http) = try await api.data("/api/files/\(documentID)/annotations?base_version=\(baseVersion)",
                                           method: "PUT", body: root.serialized())
        switch http.statusCode {
        case 200..<300:
            let v = try JSONValue.parse(d)
            return .saved(version: v["version"]?.int ?? baseVersion + 1)
        case 409:
            // Konflikt nur mit neuerem Stand; 409 ohne "version" heisst "kann hier (noch) nicht speichern" (lokales
            // Backend vor S3): Fehler mit Meldung, die Notizen bleiben im Journal
            let v = try JSONValue.parse(d)
            guard v["version"] != nil else { throw APIError(status: 409, message: String(decoding: d.prefix(400), as: UTF8.self)) }
            return .conflict(ServerSnapshot(version: v["version"]?.int ?? 0, root: v["data"] ?? AnnotationDocument.emptyRoot))
        default:
            throw APIError(status: http.statusCode, message: String(decoding: d.prefix(300), as: UTF8.self))
        }
    }
}

// MARK: - Antworten des Servers (nur die genutzten Felder; unbekannte werden ignoriert)

struct LibraryResponse: Decodable {
    let files: [LibFile]
    let modules: [LibModule]
}

struct LibModule: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let color: String?
}

struct LibFile: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let title: String?
    let kind: String?
    let module_id: Int?
    let subject: String?
    let doc_type: String?
    let ai_title: String?
    let sub_label: String?
    let downloaded_at: String?
    let has_notes: Int?
    let page_count: Int?
    let studip_folder: String?

    var displayTitle: String { ai_title ?? title ?? name }
    var isPDF: Bool { name.lowercased().hasSuffix(".pdf") && downloaded_at != nil }
}
