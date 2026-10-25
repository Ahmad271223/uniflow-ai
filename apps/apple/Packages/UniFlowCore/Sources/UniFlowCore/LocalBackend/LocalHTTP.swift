import Foundation

// Anfrage und Antwort des lokalen Backends: dieselben Teile wie bei app/server.py (FastAPI/Starlette), aber ohne
// Netzwerk. Die App baut daraus eine HTTPURLResponse (LocalTransport); URLRequest gibt es unter Linux nur in
// FoundationNetworking, darum kennt der Kern nur URL, Kopfzeilen und Bytes.

/// Anfrage an das lokale Backend.
public struct LocalRequest: Sendable {
    public var method: String
    /// Pfad ohne Query, prozent-dekodiert (wie `scope["path"]` bei Starlette)
    public var path: String
    /// Query-Paare in Reihenfolge, dekodiert wie `parse_qsl(keep_blank_values=True)` ("+" = Leerzeichen)
    public var query: [QueryItem]
    /// Kopfzeilen mit kleingeschriebenen Namen
    public var headers: [String: String]
    public var body: Data
    /// vom Router gesetzt: Werte der Platzhalter im Pfadmuster ({file_id} ...)
    public internal(set) var pathParams: [String: String] = [:]

    public struct QueryItem: Sendable, Equatable {
        public let name: String
        public let value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    public init(method: String, path: String, query: [QueryItem] = [], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    /// Aus der URL einer Anfrage der App (z. B. `uniflow-local://device/api/settings?x=1`).
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let rawPath = parts?.percentEncodedPath ?? url.path
        let path = rawPath.removingPercentEncoding ?? rawPath
        self.init(method: method, path: path.isEmpty ? "/" : path,
                  query: LocalRequest.parseQuery(parts?.percentEncodedQuery ?? ""), headers: headers, body: body ?? Data())
    }

    /// `parse_qsl` mit `keep_blank_values=True`: Trennzeichen "&", "+" wird Leerzeichen, dann Prozent-Dekodierung.
    public static func parseQuery(_ raw: String) -> [QueryItem] {
        raw.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let plus = s.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            return QueryItem(decode(kv[0]), kv.count > 1 ? decode(kv[1]) : "")
        }
    }

    /// Wert eines Query-Parameters; bei Wiederholung gilt wie bei Starlette der letzte.
    public func query(_ name: String) -> String? { query.last { $0.name == name }?.value }

    /// Bool-Parameter wie FastAPI (`?due=true`, `1`, `yes`, `on`); nil ohne Angabe, Fehler bei anderem Text.
    public func boolQuery(_ name: String) throws -> Bool? {
        guard let v = query(name) else { return nil }
        switch v.lowercased() {
        case "1", "true", "yes", "on", "y", "t": return true
        case "0", "false", "no", "off", "n", "f": return false
        default: throw LocalHTTPError.validation(type: "bool_parsing", loc: ["query", name], msg: "Input should be a valid boolean, unable to interpret input", input: .string(v))
        }
    }

    /// Pflicht-Parameter wie `start: str` in FastAPI: fehlt er, kommt 422.
    public func requiredQuery(_ name: String) throws -> String {
        guard let v = query(name) else {
            throw LocalHTTPError.validation(type: "missing", loc: ["query", name], msg: "Field required", input: .null)
        }
        return v
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Inhalt als JSON wie `Body(...)`: leer oder kein gueltiges JSON -> 422.
    public func jsonBody() throws -> JSONValue {
        guard !body.isEmpty else {
            throw LocalHTTPError.validation(type: "missing", loc: ["body"], msg: "Field required", input: .null)
        }
        do { return try JSONValue.parse(body) } catch {
            throw LocalHTTPError.validation(type: "json_invalid", loc: ["body"], msg: "JSON decode error", input: .null)
        }
    }

    /// `body: dict = Body(...)`; mit `orEmpty` wie `Body(default={})` (leerer Inhalt = leeres Objekt).
    public func objectBody(orEmpty: Bool = false) throws -> [String: JSONValue] {
        if orEmpty && body.isEmpty { return [:] }
        let v = try jsonBody()
        guard let o = v.object else {
            throw LocalHTTPError.validation(type: "dict_type", loc: ["body"], msg: "Input should be a valid dictionary", input: v)
        }
        return o
    }

    /// Wie `objectBody`, aber mit Reihenfolge und ganzen/gebrochenen Zahlen wie Pythons `json.loads`
    /// (fuer Werte, die als Text gespeichert werden, z. B. `set_setting`).
    public func pythonObjectBody() throws -> [PyJSON.Member] {
        let plain = try objectBody()                                     // gleiche 422-Meldungen wie oben
        guard case .object(let members) = try PyJSON.parse(body) else {
            throw LocalHTTPError.validation(type: "dict_type", loc: ["body"], msg: "Input should be a valid dictionary", input: .object(plain))
        }
        return members
    }

    /// multipart/form-data (Formulare wie FormData im Web, z. B. `POST /api/notebooks`).
    public func multipart() throws -> MultipartForm {
        guard let type = header("content-type") else { throw LocalHTTPError(status: 400, message: "Content-Type fehlt") }
        return try MultipartForm.parse(body, contentType: type)
    }
}

/// Antwort des lokalen Backends.
public struct LocalResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// JSON-Antwort wie `JSONResponse` (FastAPI gibt `None` als `null` aus).
    public static func json(_ value: JSONValue, status: Int = 200) -> LocalResponse {
        LocalResponse(status: status, headers: ["Content-Type": "application/json"], body: value.serialized())
    }

    /// Fehler wie `HTTPException(status, detail)`: `{"detail": ...}`
    public static func detail(_ status: Int, _ message: String) -> LocalResponse {
        .json(["detail": .string(message)], status: status)
    }

    /// `HTTPException(404)` ohne Text
    public static let notFound = detail(404, "Not Found")

    public static let ok: LocalResponse = .json(["ok": true])

    /// Inhalt als JSON (nil, wenn er keines ist)
    public var json: JSONValue? { try? JSONValue.parse(body) }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Fehler eines Endpunkts mit HTTP-Status, wie `HTTPException` in app/server.py.
public struct LocalHTTPError: Error, Equatable, CustomStringConvertible {
    public let status: Int
    /// Inhalt von "detail": Text oder (bei 422) die Liste der Validierungsfehler wie bei FastAPI
    public let detail: JSONValue

    public init(status: Int, message: String) {
        self.status = status
        self.detail = .string(message)
    }

    public init(status: Int, detail: JSONValue) {
        self.status = status
        self.detail = detail
    }

    /// 422 in der Form von FastAPI: `{"detail": [{"type", "loc", "msg", "input"}]}`
    public static func validation(type: String, loc: [String], msg: String, input: JSONValue) -> LocalHTTPError {
        LocalHTTPError(status: 422, detail: [["type": .string(type), "loc": .array(loc.map { .string($0) }), "msg": .string(msg), "input": input]])
    }

    public static func notFound(_ message: String = "Not Found") -> LocalHTTPError { LocalHTTPError(status: 404, message: message) }

    public var response: LocalResponse { .json(["detail": detail], status: status) }

    public var description: String { "HTTP \(status): \(detail.string ?? detail.jsonString())" }
}
