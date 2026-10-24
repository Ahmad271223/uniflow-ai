import Foundation
import UniFlowCore

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "Server-Fehler \(status): \(message)" }
}

/// HTTP-Zugriff auf den bestehenden UniFlow-Server. Die PIN geht als Cookie mit (wie im Browser).
/// Unveraenderlich nach dem Anlegen und daher sicher von mehreren Threads nutzbar.
final class APIClient: @unchecked Sendable {
    let base: URL
    private let pin: String?
    private let session: URLSession

    init(base: URL, pin: String?) {
        self.base = base
        self.pin = pin
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private func request(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw APIError(status: -1, message: "Ungültiger Pfad \(path)")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let pin, !pin.isEmpty { r.setValue("lernapp_pin=\(pin)", forHTTPHeaderField: "Cookie") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let (d, resp) = try await session.data(for: try request(path, method: method, body: body))
        guard let http = resp as? HTTPURLResponse else { throw APIError(status: -1, message: "Keine HTTP-Antwort") }
        return (d, http)
    }

    func json<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (d, http) = try await data(path)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: String(decoding: d.prefix(400), as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: d)
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
            let v = try JSONValue.parse(d)
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
