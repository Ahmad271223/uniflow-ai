import Foundation

// Auf Stud.IP-Nachrichten antworten (Entscheidung des Inhabers 05.11.2026, docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md).
// Nach dem Abgeben die zweite schreibende Anfrage der App an Stud.IP; nur auf ausdruecklichen Knopfdruck ("Senden"),
// nie im Abgleich, nie still wiederholt (eine zweite Antwort kaeme doppelt an).
//
// Routen laut Stud.IP-Entwicklerdoku (docs.gitlab.studip.de/entwicklung/jsonapi/messages/, gelesen 05.11.2026):
// - `POST messages` mit `{"data":{"type":"messages","attributes":{subject, message, priority},
//   "relationships":{"recipients":{"data":[{"type":"users","id":…}]}}}}`
// - `GET users/{id}/inbox` (Liste, markiert nichts); die Einzelansicht `GET messages/{id}` nutzt die App nie (ob sie in
//   Stud.IP als gelesen markiert, ist unbekannt)
// - `GET users/{id}` fuer Namen weiterer Empfaenger (nur sichtbare Nutzer)
// Namen werden nie gespeichert (Regel 02.11.2026): sie stehen nur im offenen Antwortfenster.

/// Person im Antwortfenster (Kennung und Name, nur im Speicher)
public struct StudIPPerson: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// An wen die Antwort geht
public enum StudIPReplyMode: String, Codable, Sendable, Equatable {
    /// nur an den Absender
    case sender
    /// an den Absender und alle weiteren Empfaenger (ausser einem selbst)
    case all
}

/// Was Stud.IP ueber die Nachricht weiss (live aus dem Posteingang)
public struct StudIPReplyContext: Sendable, Equatable {
    /// Stud.IP-Kennung der Nachricht (ohne "sp-msg-")
    public let messageID: String
    public let subject: String
    public let sender: StudIPPerson
    /// weitere Empfaenger ausser einem selbst und dem Absender (nur Kennungen; Namen per `recipientNames`)
    public let otherRecipientIDs: [String]
    /// Liefert die Liste die Empfaenger ueberhaupt? (sonst nur "Antworten")
    public let recipientsKnown: Bool

    public init(messageID: String, subject: String, sender: StudIPPerson, otherRecipientIDs: [String], recipientsKnown: Bool) {
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.otherRecipientIDs = otherRecipientIDs
        self.recipientsKnown = recipientsKnown
    }

    /// "Allen antworten" moeglich: 1 bis `StudIPMessageReply.maxReplyAll` weitere Empfaenger
    public var allowsReplyAll: Bool { !otherRecipientIDs.isEmpty && otherRecipientIDs.count <= StudIPMessageReply.maxReplyAll }
    /// Rundnachricht (zu viele Empfaenger fuer "Allen antworten")
    public var isCircular: Bool { otherRecipientIDs.count > StudIPMessageReply.maxReplyAll }
}

/// Fehler beim Antworten (Anzeige im Fenster)
public enum StudIPMessageError: Error, Equatable, LocalizedError {
    /// Systemnachricht oder Nachricht ohne Absender
    case systemMessage
    /// Nachricht nicht (mehr) im Posteingang
    case notFound
    /// Stud.IP verlangt fuer schreibende Anfragen mit Sitzungs-Cookie ein Sicherheits-Token (CSRF)
    case securityToken
    /// 403 ohne Hinweis auf das Token
    case forbidden
    /// 400/422: Stud.IP nimmt die Nachricht so nicht an
    case rejected(Int)
    /// Transport kann nicht schreiben
    case unsupported
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .systemMessage:
            return "Diese Nachricht kam von Stud.IP selbst. Auf Systemnachrichten kann man nicht antworten."
        case .notFound:
            return "Die Nachricht ist in Stud.IP nicht mehr im Posteingang (gelöscht oder sehr alt). Antworte bitte direkt in Stud.IP."
        case .securityToken:
            return "Stud.IP hat das Senden aus der App abgelehnt (Sicherheitsprüfung). Antworte bitte direkt in Stud.IP."
        case .forbidden:
            return "Stud.IP hat das Senden abgelehnt (keine Berechtigung). Antworte bitte direkt in Stud.IP."
        case .rejected(let s):
            return "Stud.IP hat die Nachricht nicht angenommen (HTTP \(s)). Antworte bitte direkt in Stud.IP."
        case .unsupported:
            return "Antworten ist hier nicht möglich."
        case .http(let s):
            return "Stud.IP antwortet mit HTTP \(s). Die Nachricht wurde vermutlich nicht gesendet; prüfe in Stud.IP unter „Gesendet“, bevor du es noch einmal versuchst."
        }
    }

    /// Ausweg "In Stud.IP antworten" anbieten
    public var offersWebFallback: Bool {
        switch self {
        case .unsupported: return false
        default: return true
        }
    }
}

/// Regeln ohne Netz
public enum StudIPMessageReply {
    /// hoechstens so viele weitere Empfaenger fuer "Allen antworten" (darueber gilt die Nachricht als Rundnachricht)
    public static let maxReplyAll = 20
    /// so viele Seiten des Posteingangs (je 50) werden nach der Nachricht durchsucht
    public static let inboxPages = 3
    static let localPrefix = "sp-msg-"

    /// Stud.IP-Kennung aus der Kennung der App ("sp-msg-<id>")
    public static func rawID(_ localID: String) -> String {
        localID.hasPrefix(localPrefix) ? String(localID.dropFirst(localPrefix.count)) : localID
    }

    /// Kennung der App aus der Stud.IP-Kennung
    public static func localID(_ rawID: String) -> String { localPrefix + rawID }

    /// Systemnachricht nach der gespeicherten Absender-Anzeige ("Stud.IP" bzw. leer, `StudIPExtras.senderLabel`)
    public static func isReplyable(senderLabel: String?) -> Bool {
        let s = (senderLabel ?? "").trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && s != "Stud.IP"
    }

    /// "Allen antworten" im Leser: der Abgleich kennt die Zahl der Empfaenger (mit einem selbst), 2 bis maxReplyAll + 1
    public static func offersReplyAll(recipients: Int?) -> Bool {
        guard let n = recipients else { return false }
        return n >= 2 && n - 1 <= maxReplyAll
    }

    /// Betreff der Antwort: "RE: " davor wie Stud.IP im Browser, aber nicht doppelt
    public static func replySubject(_ subject: String) -> String {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "(ohne Betreff)" { return "RE: " }
        let lower = s.lowercased()
        if ["re:", "aw:", "re :", "antw:"].contains(where: { lower.hasPrefix($0) }) { return s }
        return "RE: " + s
    }

    private static let quoteDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "dd.MM.yyyy 'um' HH:mm"
        return f
    }()

    /// Zitat des Originals: "Am 02.11.2026 um 08:15 schrieb Prof. Test:" und jede Zeile mit "> "
    public static func quote(_ text: String, senderName: String, sentAt: String?) -> String {
        var head = "\(senderName.isEmpty ? "Absender" : senderName) schrieb:"
        if let d = StudIPExtras.messageInstant(sentAt) { head = "Am \(quoteDate.string(from: d)) " + head }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return ([head] + lines.map { $0.isEmpty ? ">" : "> \($0)" }).joined(separator: "\n")
    }

    /// Text, der gesendet wird: eigener Text, darunter optional das Zitat (reiner Text, Zeilenumbrueche bleiben)
    public static func body(text: String, quote: String?) -> String {
        let own = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote, !quote.isEmpty else { return own }
        return own + "\n\n" + quote
    }

    /// JSON:API-Koerper fuer `POST messages`
    public static func payload(subject: String, text: String, recipientIDs: [String]) -> JSONValue {
        var seen = Set<String>()
        let recipients = recipientIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return ["data": ["type": "messages",
                         "attributes": ["subject": .string(subject), "message": .string(text), "priority": "normal"],
                         "relationships": ["recipients": ["data": .array(recipients.map { ["type": "users", "id": .string($0)] })]]]]
    }

    /// Fehler aus der Antwort auf `POST messages` (nil = gesendet)
    public static func sendError(status: Int, body: Data) -> StudIPMessageError? {
        if (200..<300).contains(status) { return nil }
        let text = String(decoding: body.prefix(4000), as: UTF8.self).lowercased()
        switch status {
        case 403:
            if text.contains("csrf") || text.contains("security token") || text.contains("security_token") || text.contains("sicherheits") {
                return .securityToken
            }
            return .forbidden
        case 400, 422: return .rejected(status)
        default: return .http(status)
        }
    }

    /// Kennung der neuen Nachricht (`data.id` oder `Location` …/messages/{id})
    public static func sentID(location: String?, body: Data) -> String? {
        if let j = try? JSONValue.parse(body), let id = StudIPTerms.id(j["data"]) { return id }
        if let loc = location, let r = loc.range(of: "messages/") {
            let rest = loc[r.upperBound...].split(whereSeparator: { "/?#".contains($0) }).first.map(String.init)
            if let rest, !rest.isEmpty { return rest }
        }
        return nil
    }

    /// Anzeigename eines Nutzers (`formatted-name`, sonst Vor- und Nachname, sonst Benutzername)
    public static func displayName(_ attrs: JSONValue?) -> String? {
        if let f = attrs?["formatted-name"]?.string?.trimmingCharacters(in: .whitespaces), !f.isEmpty { return f }
        let parts = [attrs?["given-name"]?.string, attrs?["family-name"]?.string].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if let u = attrs?["username"]?.string, !u.isEmpty { return u }
        return nil
    }

    /// Antwort-Kontext aus einer Seite des Posteingangs; nil, wenn die Nachricht nicht auf der Seite steht.
    /// Wirft `systemMessage` fuer Systemnachrichten und Nachrichten ohne Absender.
    public static func context(messageID: String, page: JSONValue, me: String) throws -> StudIPReplyContext? {
        guard let m = (page["data"]?.array ?? []).first(where: { StudIPTerms.id($0) == messageID }) else { return nil }
        guard let senderRef = StudIPExtras.rel(m, "sender"), let ref = senderRef, let senderID = StudIPTerms.id(ref),
              senderID != StudIPExtras.systemSender else { throw StudIPMessageError.systemMessage }
        var names: [String: String] = [:]
        for u in page["included"]?.array ?? [] where u["type"]?.string == "users" {
            if let id = StudIPTerms.id(u), let n = displayName(u["attributes"]) { names[id] = n }
        }
        let recipientData = m["relationships"]?["recipients"]?["data"]?.array
        var seen = Set([me, senderID])
        let others = (recipientData ?? []).compactMap { StudIPTerms.id($0) }.filter { seen.insert($0).inserted }
        let subject = Announcements.htmlToText(StudIPExtras.str(StudIPTerms.attrs(m)["subject"]))
        return StudIPReplyContext(messageID: messageID, subject: subject,
                                  sender: StudIPPerson(id: senderID, name: names[senderID] ?? "Absender"),
                                  otherRecipientIDs: others, recipientsKnown: recipientData != nil)
    }

    /// Antworten im Browser (angemeldeter In-App-Browser): Schreibfenster mit `answer_to` (aus der Stud.IP-Oberflaeche
    /// bekannt, nicht dokumentiert; ohne Wirkung oeffnet sich ein leeres Schreibfenster)
    public static func replyWebURL(base: URL, messageID: String) -> URL {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        let id = messageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? messageID
        return URL(string: "\(b)/dispatch.php/messages/write?answer_to=\(id)")!
    }

    /// Ausgang in Stud.IP ("Gesendet")
    public static func outboxWebURL(base: URL) -> URL {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: "\(b)/dispatch.php/messages/sent")!
    }
}

extension StudIPClient {
    /// Antwort-Kontext live aus dem Posteingang (dieselbe Liste wie der Abgleich, markiert nichts als gelesen): eigene
    /// Kennung, dann bis zu `inboxPages` Seiten zu je 50, bis die Nachricht gefunden ist. Nur lesend.
    public func replyContext(messageID: String) async throws -> StudIPReplyContext {
        let me = try await currentUserID()
        var next: String? = "jsonapi.php/v1/users/\(me)/inbox?page[limit]=50&include=sender"
        var pages = 0
        var withInclude = true
        while let path = next, pages < StudIPMessageReply.inboxPages {
            let page: JSONValue
            do {
                page = try await json(path)
            } catch StudIPError.http(let status, _) where status == 400 && withInclude {
                // include unbekannt: ohne (dann ohne Namen)
                withInclude = false
                next = "jsonapi.php/v1/users/\(me)/inbox?page[limit]=50"
                continue
            }
            pages += 1
            if let c = try StudIPMessageReply.context(messageID: messageID, page: page, me: me) { return c }
            next = page["links"]?["next"]?.string
        }
        throw StudIPMessageError.notFound
    }

    /// Namen weiterer Empfaenger (`users/{id}`, hoechstens `maxReplyAll`); unsichtbare oder unbekannte Nutzer heissen
    /// "Stud.IP-Nutzer/in". Nur lesend; eine abgelaufene Sitzung bricht ab.
    public func recipientNames(_ ids: [String]) async throws -> [StudIPPerson] {
        var out: [StudIPPerson] = []
        for id in ids.prefix(StudIPMessageReply.maxReplyAll) {
            var name = "Stud.IP-Nutzer/in"
            do {
                let j = try await json("jsonapi.php/v1/users/\(id)", retryTransient: false)
                name = StudIPMessageReply.displayName(j["data"]?["attributes"]) ?? name
            } catch StudIPError.sessionExpired {
                throw StudIPError.sessionExpired
            } catch {}
            out.append(StudIPPerson(id: id, name: name))
        }
        return out
    }

    /// Nachricht senden (`POST messages`). Genau ein Versuch ohne Wiederholung (sonst kaeme sie doppelt an). Abgelaufene
    /// Sitzung: `StudIPError.sessionExpired` (Stud.IP hat nichts angenommen). Liefert die Kennung der neuen Nachricht.
    public func sendMessage(subject: String, text: String, recipientIDs: [String]) async throws -> String? {
        guard let writer = transport as? StudIPWritingTransport else { throw StudIPMessageError.unsupported }
        let body = StudIPMessageReply.payload(subject: subject, text: text, recipientIDs: recipientIDs).serialized()
        let headers = ["Content-Type": StudIPClient.jsonAPI, "Accept": StudIPClient.jsonAPI,
                       // fuer den Fall, dass Stud.IP Anfragen aus Skripten von der Formular-Pruefung ausnimmt; unbekannt
                       "X-Requested-With": "XMLHttpRequest"]
        let reply = try await perform("jsonapi.php/v1/messages", anyStatus: true, retry: .none) {
            try await writer.send($0, method: "POST", headers: headers, body: body)
        }
        if reply.contentType.lowercased().contains("text/html"), (200..<300).contains(reply.status),
           OpencastParser.looksLikeLoginPage(String(decoding: reply.body.prefix(200_000), as: UTF8.self)) {
            throw StudIPError.sessionExpired
        }
        if let e = StudIPMessageReply.sendError(status: reply.status, body: reply.body) { throw e }
        return StudIPMessageReply.sentID(location: reply.location, body: reply.body)
    }
}

// MARK: Entwurf

/// Entwurf einer Antwort (nur eigener Text, keine Namen); je Nachricht in den Einstellungen des Containers
public struct StudIPReplyDraft: Codable, Sendable, Equatable {
    /// Kennung der App ("sp-msg-…")
    public let messageID: String
    public var mode: StudIPReplyMode
    public var subject: String
    public var text: String
    public var quote: Bool
    public var savedAt: Date

    public init(messageID: String, mode: StudIPReplyMode, subject: String, text: String, quote: Bool, savedAt: Date) {
        self.messageID = messageID
        self.mode = mode
        self.subject = subject
        self.text = text
        self.quote = quote
        self.savedAt = savedAt
    }

    /// Lohnt sich das Aufheben? (eigener Text vorhanden)
    public var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Alle Entwuerfe eines Containers (JSON in dessen Einstellungen), hoechstens `limit`, die aeltesten fallen weg
public struct StudIPReplyDrafts: Codable, Sendable, Equatable {
    public static let defaultsKey = "uniflow.studip.replyDrafts"
    public static let limit = 50
    public private(set) var drafts: [StudIPReplyDraft] = []

    public init(drafts: [StudIPReplyDraft] = []) { self.drafts = drafts }

    public static func decode(_ data: Data?) -> StudIPReplyDrafts {
        guard let data, let d = try? JSONDecoder().decode(StudIPReplyDrafts.self, from: data) else { return StudIPReplyDrafts() }
        return d
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public func draft(for messageID: String) -> StudIPReplyDraft? { drafts.first { $0.messageID == messageID } }

    /// Entwurf setzen (ohne Inhalt: entfernen)
    public mutating func put(_ d: StudIPReplyDraft) {
        drafts.removeAll { $0.messageID == d.messageID }
        guard d.hasContent else { return }
        drafts.insert(d, at: 0)
        if drafts.count > Self.limit { drafts.removeLast(drafts.count - Self.limit) }
    }

    public mutating func remove(_ messageID: String) { drafts.removeAll { $0.messageID == messageID } }

    /// Lesen/Schreiben in Einstellungen
    public static func load(_ defaults: UserDefaults) -> StudIPReplyDrafts { decode(defaults.data(forKey: defaultsKey)) }
    public func save(_ defaults: UserDefaults) { defaults.set(encoded(), forKey: Self.defaultsKey) }
}

// MARK: Verlauf

/// Gesendete Antwort (nur eigener Text und Zahl der Empfaenger, keine Namen)
public struct StudIPReplyRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(messageID)|\(at.timeIntervalSince1970)" }
    /// Kennung der App der beantworteten Nachricht ("sp-msg-…")
    public let messageID: String
    public let at: Date
    public let subject: String
    /// eigener Text ohne Zitat
    public let text: String
    public let quoted: Bool
    public let mode: StudIPReplyMode
    public let recipients: Int
    /// Kennung der neuen Nachricht in Stud.IP (nil, wenn Stud.IP keine nennt)
    public let sentID: String?

    public init(messageID: String, at: Date, subject: String, text: String, quoted: Bool, mode: StudIPReplyMode, recipients: Int, sentID: String?) {
        self.messageID = messageID
        self.at = at
        self.subject = subject
        self.text = text
        self.quoted = quoted
        self.mode = mode
        self.recipients = recipients
        self.sentID = sentID
    }

    /// "Beantwortet am 05.11.2026, 14:30"
    public func line(timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = timeZone
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return "Beantwortet am \(f.string(from: at))"
    }
}

/// Verlauf aller Antworten eines Containers, neueste zuerst, hoechstens `limit`
public struct StudIPReplyLog: Codable, Sendable, Equatable {
    public static let defaultsKey = "uniflow.studip.replies"
    public static let limit = 300
    public private(set) var records: [StudIPReplyRecord] = []

    public init(records: [StudIPReplyRecord] = []) { self.records = records }

    public static func decode(_ data: Data?) -> StudIPReplyLog {
        guard let data, let log = try? JSONDecoder().decode(StudIPReplyLog.self, from: data) else { return StudIPReplyLog() }
        return log
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public mutating func add(_ r: StudIPReplyRecord) {
        records.insert(r, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
    }

    public func records(for messageID: String) -> [StudIPReplyRecord] { records.filter { $0.messageID == messageID } }

    /// beantwortete Nachrichten (Kennungen der App)
    public var answered: Set<String> { Set(records.map(\.messageID)) }

    public static func load(_ defaults: UserDefaults) -> StudIPReplyLog { decode(defaults.data(forKey: defaultsKey)) }
    public func save(_ defaults: UserDefaults) { defaults.set(encoded(), forKey: Self.defaultsKey) }
}

// MARK: Empfaengerzahl beim Abgleich

extension StudIPExtras {
    static let messageMetaTable = """
        CREATE TABLE IF NOT EXISTS studip_message_meta (
            id TEXT PRIMARY KEY,               -- wie studip_messages.id
            recipients INTEGER                 -- Zahl der Empfaenger (mit einem selbst), keine Kennungen, keine Namen
        )
        """

    /// Zahl der Empfaenger je Nachricht, wenn die Liste die Beziehung `recipients` liefert (sonst fehlt der Eintrag)
    public static func parseMessageMeta(_ data: JSONValue?) -> [String: Int] {
        var out: [String: Int] = [:]
        for m in data?.array ?? [] {
            guard let id = StudIPTerms.id(m), let r = m["relationships"]?["recipients"]?["data"]?.array else { continue }
            out[StudIPMessageReply.localID(id)] = Set(r.compactMap { StudIPTerms.id($0) }).count
        }
        return out
    }

    /// Ersetzt die Empfaengerzahlen (nur Geraet, keine Python-Entsprechung)
    static func storeMessageMeta(_ c: SQLiteConnection, _ meta: [String: Int]) throws {
        try c.executeScript(messageMetaTable)
        try c.execute("DELETE FROM studip_message_meta")
        for (id, n) in meta.sorted(by: { $0.key < $1.key }) {
            try c.execute("INSERT OR REPLACE INTO studip_message_meta(id, recipients) VALUES (?, ?)", [.text(id), .integer(Int64(n))])
        }
    }

    /// Empfaengerzahlen aus der Datenbank (leer ohne Tabelle)
    static func messageMeta(_ c: SQLiteConnection) throws -> [String: Int] {
        guard try has(c, "studip_message_meta") else { return [:] }
        var out: [String: Int] = [:]
        for r in try c.rows("SELECT id, recipients FROM studip_message_meta") {
            if let id = r["id"]?.string, let n = r["recipients"]?.int { out[id] = n }
        }
        return out
    }
}
