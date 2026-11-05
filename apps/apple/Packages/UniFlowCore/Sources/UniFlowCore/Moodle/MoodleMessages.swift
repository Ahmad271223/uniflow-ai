import Foundation

// Moodle-Nachrichten (Hochschule Hannover, Learnweb der Uni Hildesheim) wie die Stud.IP-Nachrichten der LUH
// (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md): Liste, Leser, Antworten, Zaehler. Gelesen ueber dieselben AJAX-Funktionen
// wie die Nachrichten-Leiste von Moodle (core_message_get_conversations, core_message_get_conversation_messages,
// core_message_get_unread_conversations_count). Das Lesen markiert in Moodle nichts als gelesen. Gespeichert in der
// Tabelle der Seite "Nachrichten" (studip_messages, Kennung "moodle-<Unterhaltung>-<Nachricht>"), nur auf dem Geraet.
// Wie bei Stud.IP keine Personennamen: Absender ist "Moodle" bzw. der Name der Gruppen-Unterhaltung; Namen liest das
// Antwortfenster live. Gesendet wird nur auf "Senden" (core_message_send_messages_to_conversation, genau ein Versuch).

public enum MoodleMessages {
    public static let idPrefix = "moodle-"
    public static let maxConversations = 30
    public static let maxPerConversation = 30

    public struct Item: Sendable, Equatable {
        public let conversationID: Int
        public let messageID: Int
        public let sender: String
        public let subject: String
        public let text: String
        public let sentAt: String
    }

    /// Kennung in der Tabelle
    public static func storedID(conversation: Int, message: Int) -> String { "\(idPrefix)\(conversation)-\(message)" }

    /// Unterhaltung einer gespeicherten Kennung ("moodle-12-345" -> 12); nil fuer andere Quellen
    public static func conversationID(_ storedID: String) -> Int? {
        guard storedID.hasPrefix(idPrefix) else { return nil }
        return storedID.dropFirst(idPrefix.count).split(separator: "-").first.flatMap { Int($0) }
    }

    /// Zeitpunkt (Unix-Sekunden) als "2026-11-05T14:30:00+01:00" (Berlin)
    public static func iso(_ seconds: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Unterhaltungen (core_message_get_conversations) -> Kennungen, Art und Name (Gruppe) der Unterhaltung
    public static func conversations(_ data: JSONValue) -> [(id: Int, group: Bool, name: String)] {
        (data["conversations"]?.array ?? []).compactMap { c in
            guard let id = c["id"]?.int else { return nil }
            let group = c["type"]?.int == 2
            return (id, group, group ? HText.collapse(c["name"]?.string ?? "") : "")
        }
    }

    /// Nachrichten einer Unterhaltung (core_message_get_conversation_messages); eigene Nachrichten nicht
    public static func items(conversation: Int, group: Bool, name: String, data: JSONValue, me: Int?) -> [Item] {
        (data["messages"]?.array ?? []).compactMap { m in
            guard let id = m["id"]?.int, let from = m["useridfrom"]?.int, from != me else { return nil }
            let text = Announcements.htmlToText(m["text"]?.string ?? "")
            let sent = iso(m["timecreated"]?.int ?? 0)
            return Item(conversationID: conversation, messageID: id, sender: group && !name.isEmpty ? name : "Moodle",
                        subject: group && !name.isEmpty ? name : "Nachricht in Moodle", text: text, sentAt: sent)
        }
    }

    static func stored(_ i: Item, base: String) -> StudIPExtras.Message {
        let posted = Announcements.postedDayOrNil(i.sentAt) ?? 0
        let dates: [JSONValue] = Announcements.datesFor(title: i.subject, text: i.text, posted: posted).map { d in
            ["date": d["date"] ?? .null, "time": d["time"] ?? .null, "kind": d["kind"] ?? .null]
        }
        return StudIPExtras.Message(id: storedID(conversation: i.conversationID, message: i.messageID), sender: i.sender,
                                    subject: i.subject, preview: PyText.slice(i.text, 0, Announcements.maxText), sentAt: i.sentAt,
                                    url: "\(base)/message/index.php?convid=\(i.conversationID)", dates: dates)
    }

    /// Text einer Antwort fuer Moodle (FORMAT_MOODLE: Zeilenumbrueche bleiben)
    public static func replyPayload(conversation: Int, text: String) -> JSONValue {
        ["conversationid": .number(Double(conversation)),
         "messages": .array([.object(["text": .string(text), "textformat": .number(0)])])]
    }
}

/// Abruf und Antworten mit der Sitzung (`MoodleWeb`)
public enum MoodleMessagesSync {
    public struct Report: Sendable, Equatable {
        public var count: Int?
        public var unread: Int?
        public var needsLogin = false
        public var message = ""
        public init(count: Int? = nil, unread: Int? = nil, needsLogin: Bool = false, message: String = "") {
            self.count = count
            self.unread = unread
            self.needsLogin = needsLogin
            self.message = message
        }
    }

    /// Unterhaltungen und ihre Nachrichten lesen und die Tabelle ersetzen (in Moodle Geloeschtes verschwindet).
    /// Nur lesend; markiert nichts als gelesen.
    public static func run(db: SQLiteDatabase, web: MoodleWeb, clock: UniFlowClock = .system) async -> Report {
        do {
            guard let me = try await web.current().userID else { throw MoodleError.unexpectedPage("Nutzerkennung") }
            let list = try await web.ajax("core_message_get_conversations",
                                          ["userid": .number(Double(me)), "limitfrom": .number(0),
                                           "limitnum": .number(Double(MoodleMessages.maxConversations)), "mergeself": .bool(true)])
            var items: [MoodleMessages.Item] = []
            for c in MoodleMessages.conversations(list) {
                try Task.checkCancellation()
                let data = try await web.ajax("core_message_get_conversation_messages",
                                              ["currentuserid": .number(Double(me)), "convid": .number(Double(c.id)),
                                               "limitfrom": .number(0), "limitnum": .number(Double(MoodleMessages.maxPerConversation)),
                                               "newest": .bool(true)])
                items += MoodleMessages.items(conversation: c.id, group: c.group, name: c.name, data: data, me: me)
            }
            let unreadData = try? await web.ajax("core_message_get_unread_conversations_count", ["useridto": .number(Double(me))])
            let unread = unreadData?.int ?? unreadData?.string.flatMap { Int($0) }
            let base = web.base, now = clock.nowISO
            let rows = items.map { MoodleMessages.stored($0, base: base) }
            try await db.transaction { try StudIPExtras.storeMessages($0, rows, fetchedAt: now) }
            return Report(count: rows.count, unread: unread,
                          message: "Nachrichten: \(rows.count)" + (unread.map { $0 > 0 ? " (\($0) ungelesen in Moodle)" : "" } ?? ""))
        } catch MoodleError.sessionExpired {
            return Report(needsLogin: true, message: "Moodle-Nachrichten: Anmeldung nötig")
        } catch is CancellationError {
            return Report(message: "")
        } catch {
            return Report(message: "Moodle-Nachrichten: \((error as? MoodleError)?.description ?? error.localizedDescription)")
        }
    }

    /// Namen der anderen Teilnehmenden einer Unterhaltung (nur fuer das Antwortfenster, nie gespeichert)
    public static func memberNames(web: MoodleWeb, conversation: Int) async throws -> [String] {
        guard let me = try await web.current().userID else { return [] }
        let data = try await web.ajax("core_message_get_conversation_messages",
                                      ["currentuserid": .number(Double(me)), "convid": .number(Double(conversation)),
                                       "limitfrom": .number(0), "limitnum": .number(1), "newest": .bool(true)])
        return (data["members"]?.array ?? []).compactMap { m in
            m["id"]?.int == me ? nil : m["fullname"]?.string.map(HText.collapse)
        }
    }

    /// Antwort in die Unterhaltung senden (genau ein Versuch). Rueckgabe: Kennung der neuen Nachricht, wenn Moodle sie nennt
    @discardableResult
    public static func reply(web: MoodleWeb, conversation: Int, text: String) async throws -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw MoodleError.unexpectedPage("leerer Text") }
        let data = try await web.ajax("core_message_send_messages_to_conversation",
                                      MoodleMessages.replyPayload(conversation: conversation, text: t), write: true)
        return data.array?.first?["id"]?.int
    }
}
