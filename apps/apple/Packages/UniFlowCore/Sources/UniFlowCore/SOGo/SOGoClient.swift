import Foundation

/// Abruf bei SOGo (Uni-Mail, Uni-Kalender der LUH) mit der Sitzung der Webansicht, wie `SOGoWeb` in app/sogo.py.
/// Jede JSON-Anfrage traegt `X-XSRF-TOKEN` (Wert des Cookies XSRF-TOKEN; setzt SOGo ein neues, gilt ab dann das neue).
/// Lesende Anfragen wiederholen bei Netzfehlern, 5xx und 429 (`UniRetry`); schreibende (Markieren, Papierkorb,
/// Entwurf, Senden) gehen genau einmal. `send` nur nach dem Knopf "Senden". Endpunkte: docs/UNI-MAIL-2026-11-05.md.
public final class SOGoClient: @unchecked Sendable {
    public let user: String
    let transport: UniTransport
    let retry: UniRetry
    private let lock = NSLock()
    private var token: String?

    public init(user: String, transport: UniTransport, xsrf: String?, retry: UniRetry = UniRetry()) {
        self.user = user
        self.transport = transport
        self.retry = retry
        token = xsrf.map { $0.removingPercentEncoding ?? $0 }
    }

    /// aktueller Wert fuer X-XSRF-TOKEN
    public var xsrf: String? { lock.withLock { token } }

    /// Wert des Cookies XSRF-TOKEN aus einer Liste (nur fuer den Rechner von SOGo)
    public static func xsrf(from cookies: [HTTPCookie]) -> String? {
        cookies.first { c in
            let d = c.domain.lowercased().hasPrefix(".") ? String(c.domain.lowercased().dropFirst()) : c.domain.lowercased()
            return c.name == "XSRF-TOKEN" && (SOGo.host == d || SOGo.host.hasSuffix("." + d))
        }.map { $0.value.removingPercentEncoding ?? $0.value }
    }

    func url(_ path: String) throws -> URL {
        let s: String
        if path.hasPrefix("https://") { s = path } else if path.hasPrefix("/") { s = "https://\(SOGo.host)" + path } else { s = SOGo.userBase(user) + "/" + path }
        guard let u = URL(string: s), u.scheme == "https", u.host?.lowercased() == SOGo.host else { throw SOGoError.bad("Anfrage außerhalb von SOGo abgelehnt") }
        return u
    }

    private func remember(_ r: UniResponse) {
        guard let set = r.headers["set-cookie"], let range = set.range(of: "XSRF-TOKEN=") else { return }
        let v = set[range.upperBound...].prefix { $0 != ";" && $0 != "," }
        guard !v.isEmpty else { return }
        lock.withLock { token = String(v).removingPercentEncoding ?? String(v) }
    }

    /// Eine Anfrage; `write`: genau ein Versuch
    func request(_ method: String, _ path: String, json: JSONValue? = nil, raw: Data? = nil, contentType: String? = nil,
                 accept: String = "application/json", write: Bool = false) async throws -> UniResponse {
        var headers = ["Accept": accept]
        if let t = xsrf, !t.isEmpty { headers["X-XSRF-TOKEN"] = t }
        var body = raw
        if let json {
            body = json.serialized()
            headers["Content-Type"] = "application/json;charset=utf-8"
        } else if let contentType {
            headers["Content-Type"] = contentType
        }
        let r = UniRequest(url: try url(path), method: method, headers: headers, body: body)
        let resp: UniResponse
        do {
            resp = write ? try await transport.send(r) : try await transport.fetch(r, retry: retry)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            _ = e
            throw SOGoError.offline
        } catch let e as HildesheimError {
            if case .http(let s, _) = e { throw SOGoError.http(s) }
            throw SOGoError.bad(e.description)
        }
        remember(resp)
        let isJSON = (resp.headers["content-type"] ?? "").lowercased().contains("json")
        let text = isJSON ? "" : String(decoding: resp.body.prefix(4000), as: UTF8.self)
        if SOGo.expired(status: resp.status, finalURL: resp.finalURL?.absoluteString, body: text) { throw SOGoError.needsLogin }
        return resp
    }

    func json(_ method: String, _ path: String, _ body: JSONValue? = nil, ok: Set<Int> = [200, 201], write: Bool = false) async throws -> JSONValue {
        let r = try await request(method, path, json: body, write: write)
        guard ok.contains(r.status) else { throw SOGoError.http(r.status) }
        guard let v = try? JSONValue.parse(r.body.isEmpty ? Data("null".utf8) : r.body) else { throw SOGoError.bad("keine JSON-Antwort") }
        return v
    }

    // MARK: Mail lesen

    public func mailboxes() async throws -> [JSONValue] { SOGo.mailboxes(try await json("GET", "Mail/0/view")) }

    /// Ordner neu lesen: alle UIDs (neueste zuerst), erste Seite, ungelesene; mit Suchtext Betreff oder Absender
    public func folder(_ path: String = "INBOX", query: String = "") async throws -> JSONValue {
        SOGo.folderListing(try await json("POST", "Mail/0/\(SOGo.folderPath(path))/view", SOGo.folderRequest(query: query)), folder: path)
    }

    /// Kopfzeilen einer Seite (UIDs aus der ersten Antwort)
    public func headers(_ path: String, uids: [Int]) async throws -> [JSONValue] {
        guard !uids.isEmpty else { return [] }
        let body: JSONValue = ["uids": .array(uids.map { .number(Double($0)) })]
        return SOGo.ordered(SOGo.headers(try await json("POST", "Mail/0/\(SOGo.folderPath(path))/headers", body)), uids)
    }

    /// Nachricht lesen (SOGo markiert sie dabei als gelesen, wie in der Weboberflaeche)
    public func message(_ path: String, uid: Int) async throws -> JSONValue {
        SOGo.message(try await json("GET", "Mail/0/\(SOGo.folderPath(path))/\(uid)/view"), folder: path, uid: uid)
    }

    public func unseen(_ path: String = "INBOX") async throws -> Int? {
        SOGo.unseen(try await json("POST", "Mail/unseenCount", ["mailboxes": [.string(SOGo.mailboxID(path))]]), folder: path)
    }

    /// Anhang direkt in eine Datei (nur Pfade unter /SOGo/so/ dieses Rechners)
    public func download(_ attachmentPath: String, to destination: URL) async throws {
        guard let p = SOGo.attachmentPath(.string(attachmentPath)) else { throw SOGoError.bad("Anhang nicht von SOGo") }
        var headers = ["Accept": "*/*"]
        if let t = xsrf, !t.isEmpty { headers["X-XSRF-TOKEN"] = t }
        let r: UniResponse
        do {
            r = try await transport.download(UniRequest(url: try url(SOGo.quotePath(p)), headers: headers), to: destination)
        } catch let e as URLError where e.code != .cancelled {
            _ = e
            throw SOGoError.offline
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        let type = (r.headers["content-type"] ?? "").lowercased()
        var head = ""
        if type.contains("html"), let h = try? FileHandle(forReadingFrom: destination) {
            head = String(decoding: h.readData(ofLength: 4000), as: UTF8.self)
            try? h.close()
        }
        if SOGo.expired(status: r.status, finalURL: r.finalURL?.absoluteString, body: head) {
            try? FileManager.default.removeItem(at: destination)
            throw SOGoError.needsLogin
        }
        guard r.status == 200 else { try? FileManager.default.removeItem(at: destination); throw SOGoError.http(r.status) }
        if size > SOGo.maxAttachment { try? FileManager.default.removeItem(at: destination); throw SOGoError.bad("Anhang zu groß") }
    }

    // MARK: Markieren, Papierkorb (je genau eine Anfrage)

    public func markRead(_ path: String, uid: Int, read: Bool) async throws {
        _ = try await json("GET", "Mail/0/\(SOGo.folderPath(path))/\(uid)/\(read ? "markMessageRead" : "markMessageUnread")", write: true)
    }

    public func flag(_ path: String, uid: Int, flagged: Bool) async throws {
        _ = try await json("POST", "Mail/0/\(SOGo.folderPath(path))/\(uid)/\(flagged ? "markMessageFlagged" : "markMessageUnflagged")", .object([:]), write: true)
    }

    /// In den Papierkorb (SOGo verschiebt; nie endgueltig loeschen, nie "withoutTrash")
    public func trash(_ path: String, uids: [Int]) async throws {
        _ = try await json("POST", "Mail/0/\(SOGo.folderPath(path))/batchDelete", ["uids": .array(uids.map { .number(Double($0)) })], write: true)
    }

    public func move(_ path: String, uids: [Int], to target: String) async throws {
        _ = try await json("POST", "Mail/0/\(SOGo.folderPath(path))/moveMessages",
                           ["uids": .array(uids.map { .number(Double($0)) }), "folder": .string(SOGo.moveTarget(target))], write: true)
    }

    // MARK: Schreiben

    /// Neuer Entwurf ("compose") oder Antwort/Weiterleitung einer Nachricht; sendet nichts
    public func newDraft(_ action: String = "compose", folder: String = "INBOX", uid: Int? = nil) async throws -> JSONValue {
        let created: JSONValue
        var source: JSONValue = .null
        switch action {
        case "compose":
            created = try SOGo.created(try await json("GET", "Mail/0/compose", write: true))
        case "reply", "replyall", "forward":
            guard let uid else { throw SOGoError.input("Nachricht fehlt") }
            created = try SOGo.created(try await json("GET", "Mail/0/\(SOGo.folderPath(folder))/\(uid)/\(action)", write: true))
            source = ["folder": .string(folder), "uid": .number(Double(uid))]
        default:
            throw SOGoError.input("Unbekannte Aktion")
        }
        let edit = try await json("GET", "Mail/0/\(SOGo.folderPath(created["mailbox_path"]?.string ?? "Drafts"))/\(created["draft_id"]?.string ?? "")/edit")
        return SOGo.draft(created: created, edit: edit, action: action, source: source)
    }

    func draftPath(_ d: JSONValue) throws -> String {
        let id = d["draft_id"]?.string ?? ""
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { throw SOGoError.input("Entwurf fehlt") }
        return "Mail/0/\(SOGo.folderPath(d["mailbox_path"]?.string ?? "Drafts"))/\(id)"
    }

    /// Als Entwurf speichern; Rueckgabe: UID des Entwurfs
    @discardableResult
    public func save(_ d: JSONValue, body: JSONValue) async throws -> Int? {
        SOGo.flattenUIDs(.array([try await json("POST", try draftPath(d) + "/save", body, write: true)["uid"] ?? .null])).first
    }

    /// Anhang an den Entwurf (multipart, Feld "attachments")
    public func attach(_ d: JSONValue, name: String, data: Data, mime: String) async throws -> JSONValue {
        guard data.count <= SOGo.maxAttachment else { throw SOGoError.input("Der Anhang ist größer als 20 MB.") }
        let m = SOGo.multipart(name: name, data: data, mime: mime)
        let r = try await request("POST", try draftPath(d) + "/save", raw: m.body, contentType: m.contentType, write: true)
        guard r.status == 200 else { throw SOGoError.http(r.status) }
        let v = try? JSONValue.parse(r.body)
        let first = v?["lastAttachmentAttrs"]?.array?.first
        let n = PyText.strip(SOGo.text(first?["filename"]))
        return ["name": .string(n.isEmpty ? SOGo.cleanFilename(name) : n), "size": .string(PyText.strip(SOGo.text(first?["size"])))]
    }

    /// Senden: genau eine Anfrage .../send, nur nach dem Knopf "Senden". Eingabefehler werfen vor jeder Anfrage.
    public func send(_ d: JSONValue, body: JSONValue) async throws -> (ok: Bool, message: String) {
        if let err = SOGo.checkSend(body) { throw SOGoError.input(err) }
        let r = try await request("POST", try draftPath(d) + "/send", json: body, write: true)
        return SOGo.sendResult(status: r.status, try? JSONValue.parse(r.body))
    }

    // MARK: Kalender

    /// Termine ab `day` (Tag seit 1970, Berlin) fuer 7 bzw. 30 Tage
    public func events(day: Int, days: Int) async throws -> [JSONValue] {
        let q = SOGo.eventsQuery(day: day, days: days).map { "\($0.0)=\(PyText.quote($0.1, safe: ""))" }.joined(separator: "&")
        return SOGo.events(try await json("GET", "Calendar/eventslist?\(q)"))
    }

    public func calendars() async throws -> [JSONValue] { SOGo.calendars(try await json("GET", "Calendar/calendarslist")) }
}
