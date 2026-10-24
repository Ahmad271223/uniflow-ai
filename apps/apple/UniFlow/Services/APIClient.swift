import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "Server-Fehler \(status): \(message)" }
}

/// HTTP-Zugriff auf den bestehenden UniFlow-Server. Die PIN geht als Cookie mit (wie im Browser).
final class APIClient {
    let base: URL
    private let pin: String?
    private let session: URLSession

    init(base: URL, pin: String?) {
        self.base = base
        self.pin = pin
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    private func request(_ path: String, method: String, body: Data?) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        r.httpMethod = method
        if let pin, !pin.isEmpty { r.setValue("lernapp_pin=\(pin)", forHTTPHeaderField: "Cookie") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let (d, resp) = try await session.data(for: request(path, method: method, body: body))
        guard let http = resp as? HTTPURLResponse else { throw APIError(status: -1, message: "Keine HTTP-Antwort") }
        return (d, http)
    }

    func json<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (d, http) = try await data(path)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, message: String(data: d, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: d)
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

    var displayTitle: String { ai_title ?? title ?? name }
    var isPDF: Bool { name.lowercased().hasSuffix(".pdf") && downloaded_at != nil }
}

struct AnnotationsResponse: Decodable {
    let data: JSONValue?
    let version: Int
}

struct SaveResponse: Decodable {
    let ok: Bool
    let version: Int
}

struct ConflictResponse: Decodable {
    let version: Int
    let data: JSONValue
}
