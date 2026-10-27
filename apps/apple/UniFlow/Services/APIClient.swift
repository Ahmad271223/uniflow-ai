import Foundation
import UniFlowCore

struct APIError: LocalizedError {
    let status: Int
    /// Antworttext (bei FastAPI und dem lokalen Backend JSON mit "detail"), gekuerzt
    let message: String
    /// eigene, verstaendliche Meldung der App (z. B. "Noch nicht geladen" im Editor); geht vor
    var text: String? = nil
    /// "detail" aus dem ganzen Antworttext (`init(status:body:)`): vorher wurde erst gekuerzt und dann gelesen, ein
    /// laengerer Text (z. B. eine Liste von Pruefungsfehlern) war dann kein JSON mehr und die Meldung ging verloren
    var detail: String? = nil

    /// wie api() in core.js: Text aus "detail" der Antwort, sonst der HTTP-Statustext (z. B. "Not Found"). Eine eigene
    /// Meldung (`text`) geht vor: vorher zeigte der Editor fuer eine Nicht-PDF "No Error" und fuer eine nicht geladene
    /// Datei "Not Found".
    var errorDescription: String? {
        if let text { return text }
        if let detail, !detail.isEmpty { return detail }
        if let d = Self.detail(in: Data(message.utf8)) { return d }
        return status > 0 ? HTTPURLResponse.localizedString(forStatusCode: status).capitalized : message
    }

    /// Hoechstens so viele Zeichen fuer `message` und `detail` (ganze Zeichen, kein halbes UTF-8)
    static let messageLimit = 400
    static let detailLimit = 1000

    /// Fehler aus einer Antwort: "detail" aus dem ganzen Text, `message` gekuerzt
    init(status: Int, body: Data) {
        self.status = status
        self.message = String(String(decoding: body, as: UTF8.self).prefix(Self.messageLimit))
        self.detail = Self.detail(in: body)
    }

    init(status: Int, message: String, text: String? = nil, detail: String? = nil) {
        self.status = status
        self.message = message
        self.text = text
        self.detail = detail
    }

    /// "detail" einer FastAPI-Antwort: Text, oder bei Pruefungsfehlern (422) die Meldungen der Liste ("msg")
    static func detail(in body: Data) -> String? {
        guard let v = try? JSONValue.parse(body), let d = v["detail"] else { return nil }
        if let s = d.string, !s.isEmpty { return String(s.prefix(detailLimit)) }
        let msgs = (d.array ?? []).compactMap { $0["msg"]?.string ?? $0.string }.filter { !$0.isEmpty }
        return msgs.isEmpty ? nil : String(msgs.prefix(3).joined(separator: "; ").prefix(detailLimit))
    }
}

/// Meldungen, wenn sich eine Datei nicht im Editor oeffnen laesst
enum DocumentOpenText {
    static let notLoaded = "Diese Datei ist noch nicht geladen. Der nächste Abgleich lädt sie auf dieses iPad."
    static let notPDF = "Diese Datei ist keine PDF und öffnet sich nicht im Editor. Mit „Öffnen in …“ zeigst du sie in einer passenden App."
    static let notFound = "Dokument nicht gefunden. Es liegt im Papierkorb oder gehört zu einem abgewählten Kurs."

    /// Antwort von /content ohne PDF
    static func problem(status: Int) -> String {
        switch status {
        case 404: return notLoaded
        case 200: return notPDF
        default: return "Das Dokument ist gerade nicht verfügbar (Fehler \(status))."
        }
    }
}

/// HTTP-Status fuer die Synchronisierung: 401/403 sind nicht "Offline", 5xx ist ein Serverfehler. Ohne Antwort
/// (`status <= 0`) gilt der Fehler als Netzfehler.
extension APIError: HTTPStatusError {
    var httpStatus: Int { status }
    /// "detail" der Antwort (z. B. 409 "noch nicht moeglich" des lokalen Backends)
    var httpDetail: String? {
        if let detail, !detail.isEmpty { return detail }
        return Self.detail(in: Data(message.utf8))
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

    /// Wert eines Query-Parameters wie `encodeURIComponent` im Web (unkodiert bleiben Buchstaben, Ziffern und
    /// "-_.!~*'()", ueber die eine Prozent-Kodierung `PyText.quote`). `.urlQueryAllowed` liess "+", "&" und "=" stehen:
    /// das lokale Backend (wie `parse_qsl`) und Starlette machten aus "C++" "C  " und schnitten "A & B" nach "A " ab.
    static func queryValue(_ s: String) -> String { PyText.quote(s, safe: "!*'()") }

    /// Lokales Backend des Geraets
    static func local(_ host: LocalBackendHost = .shared) -> APIClient {
        APIClient(base: localBase, transport: LocalTransport(host: host))
    }

    /// Adresse fuer einen API-Pfad. Nur Pfade unter `/api/` derselben Quelle (Schema, Host, Port wie `base`): ein
    /// absoluter Link oder ein Pfad wie `//anderer.host/…` (z. B. `src` eines Bildobjekts aus fremden Notizen) loeste
    /// sich sonst gegen einen fremden Host auf, beim eigenen Server mit der PIN als Cookie.
    static func url(_ path: String, base: URL) -> URL? {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == base.scheme?.lowercased(), url.host?.lowercased() == base.host?.lowercased(),
              url.port == base.port, url.user == nil else { return nil }
        // erster Pfadteil "api" (nach Aufloesen von "..")
        let parts = url.standardized.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "api" else { return nil }
        return url
    }

    private func request(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = Self.url(path, base: base) else {
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
        guard (200..<300).contains(http.statusCode) else { throw APIError(status: http.statusCode, body: d) }
        return try JSONDecoder().decode(T.self, from: d)
    }

    /// Datei hochladen (multipart/form-data), z. B. PDF-Import ueber `POST /api/notebooks`.
    func upload(_ path: String, fields: [String: String], fileField: String, fileName: String, mimeType: String, data: Data) async throws -> JSONValue {
        try await form(path, fields: fields, file: (fileField, fileName, mimeType, data))
    }

    /// Formular wie FormData im Web (multipart/form-data), Datei optional. Kopfzeilen (Feld- und Dateiname, Typ)
    /// bereinigt `MultipartBody` im Kern; eine erfolgreiche Antwort ohne Inhalt ist `.null` wie bei `value`, kein
    /// Lesefehler (sonst hiesse ein gespeicherter Upload "fehlgeschlagen" und ein zweiter Versuch legte ihn doppelt an).
    /// Der Upload wird nie automatisch wiederholt.
    func form(_ path: String, fields: [String: String], file: (field: String, name: String, mime: String, data: Data)? = nil) async throws -> JSONValue {
        let boundary = "uniflow-" + UUID().uuidString
        let body = MultipartBody.build(fields: fields, file: file.map { MultipartBody.File(field: $0.field, name: $0.name, mime: $0.mime, data: $0.data) },
                                       boundary: boundary)
        var r = try request(path, method: "POST", body: nil)
        r.httpBody = body
        r.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let (d, http) = try await transport.send(r)
        guard (200..<300).contains(http.statusCode) else { throw APIError(status: http.statusCode, body: d) }
        return d.isEmpty ? .null : try JSONValue.parse(d)
    }

    /// Roh-JSON (verlustfrei, auch fuer Felder, die die App nicht kennt).
    func value(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        let (d, http) = try await data(path, method: method, body: body?.serialized())
        guard (200..<300).contains(http.statusCode) else { throw APIError(status: http.statusCode, body: d) }
        return d.isEmpty ? .null : try JSONValue.parse(d)
    }
}

/// Notizen ueber `GET/PUT /api/files/{id}/annotations` (409 bei Konflikt, siehe app/server.py).
///
/// Server (app/server.py) und lokales Backend (`AnnotationEndpoints`) antworten immer mit `version` (GET, PUT, 409)
/// und `data` als Objekt (GET, 409). Fehlt das, ist die Antwort unbrauchbar: kein Stand "Version 0, leer", keine
/// geratene Version `baseVersion + 1`, kein leeres Dokument als Konfliktstand. Ein leerer Konfliktstand liess die
/// Zusammenfuehrung alle hier unveraenderten Seiten als "auf dem Server geloescht" werten, der naechste Upload haette
/// sie dort geloescht. Stattdessen ein Serverfehler (502): die Notizen bleiben im Journal, der Abgleich versucht es mit
/// wachsendem Abstand erneut (`SyncEngine`, `SyncIssue.serverfehler`).
struct HTTPAnnotationTransport: AnnotationTransport {
    let api: APIClient

    static func invalid(_ what: String) -> APIError {
        APIError(status: 502, message: what, text: "Ungültige Antwort des Servers (\(what)) – deine Notizen bleiben lokal gesichert.")
    }

    /// `version` als ganze Zahl ab 0 (bei 409 und nach dem Speichern ab 1)
    static func version(_ v: JSONValue, minimum: Int) -> Int? {
        guard let n = v["version"]?.int, n >= minimum, v["version"]?.double == Double(n) else { return nil }
        return n
    }

    func fetch(documentID: String) async throws -> ServerSnapshot {
        let v = try await api.value("/api/files/\(documentID)/annotations")
        guard let version = Self.version(v, minimum: 0) else { throw Self.invalid("Notizen ohne Versionsnummer") }
        guard let data = v["data"], data.object != nil else { throw Self.invalid("Notizen ohne Daten") }
        return ServerSnapshot(version: version, root: data)
    }

    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        let (d, http) = try await api.data("/api/files/\(documentID)/annotations?base_version=\(baseVersion)",
                                           method: "PUT", body: root.serialized())
        switch http.statusCode {
        case 200..<300:
            guard let v = try? JSONValue.parse(d), let version = Self.version(v, minimum: 1) else {
                throw Self.invalid("gespeichert ohne Versionsnummer")
            }
            return .saved(version: version)
        case 409:
            // Konflikt nur mit neuerem Stand; 409 ohne "version" heisst "kann hier nicht speichern" (lokales Backend:
            // Dokument fehlt in der Datenbank): Fehler mit Meldung, die Notizen bleiben im Journal
            let v = (try? JSONValue.parse(d)) ?? .null
            guard v["version"] != nil else { throw APIError(status: 409, body: d) }
            guard let version = Self.version(v, minimum: 1), let data = v["data"], data.object != nil else {
                throw Self.invalid("Konflikt ohne Serverstand")
            }
            return .conflict(ServerSnapshot(version: version, root: data))
        default:
            throw APIError(status: http.statusCode, body: d)
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
    /// Geladene PDF: dieselbe Regel wie die Bibliothek (`kind == "pdf"`, das `UniRules.fileKind` auch bei mime
    /// application/pdf ohne Endung setzt); vorher nur die Endung .pdf. Ein importiertes Bild bleibt `kind == "image"`,
    /// liegt nach der Umwandlung aber als einseitige PDF vor (`page_count` gesetzt; ohne Umwandlung nil)
    var isPDF: Bool { downloaded_at != nil && (kind == "pdf" || (kind == "image" && page_count != nil)) }
    /// Notizbuch oder Whiteboard (keine Datei, nur Seiten des Modells)
    var isNotebook: Bool { kind == "notebook" || kind == "whiteboard" }
    /// Oeffnet sich im Editor (geladene PDF, Notizbuch, Whiteboard); sonst `DocumentOpenText`
    var opensInEditor: Bool { isPDF || isNotebook }
}
