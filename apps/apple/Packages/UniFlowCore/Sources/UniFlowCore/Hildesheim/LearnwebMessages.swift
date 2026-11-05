import Foundation

// Learnweb-Nachrichten (Moodle-Unterhaltungen) der Uni Hildesheim lesen und beantworten (Auftrag des Inhabers 05.11.2026,
// "uni hildesheim einbinden"; docs/HILDESHEIM-STAND-2026-11-05.md). Regeln wie app/learnweb_messages.py, gemeinsame
// Faelle in packages/shared-contracts/fixtures/learnweb/messages-cases.json (LearnwebMessagesTests).
//
// Moodle 4.4 (lib/db/services.php): core_message_get_conversations, core_message_get_conversation und
// core_message_send_messages_to_conversation sind fuer AJAX freigegeben, gehen also mit der Sitzung (sesskey) und mit
// dem Schluessel (REST). Lesen markiert nichts als gelesen; "als gelesen markieren" ruft die App nie auf.
// Gespeichert wird je Unterhaltung die neueste fremde Nachricht in derselben Tabelle wie die Stud.IP-Nachrichten
// (studip_messages; der Container der Uni Hildesheim hat kein Stud.IP), ohne Personennamen (Regel 02.11.2026).

public enum LearnwebMessages {
    public static let localPrefix = "lw-msg-"
    public static let conversationLimit = 50
    public static let memberLimit = 21
    public static let typeIndividual = 1, typeGroup = 2, typeSelf = 3
    /// Moodle FORMAT_PLAIN
    public static let formatPlain = 2
    public static let senderIndividual = "Learnweb-Kontakt"
    public static let senderGroup = "Learnweb-Gruppe"
    public static let subjectIndividual = "Nachricht im Learnweb"
    public static let subjectGroup = "Gruppenunterhaltung im Learnweb"
    public static let maxText = 20000
    public static let notice = "Wird über das Learnweb unter deinem Namen gesendet. Die Empfänger sehen deinen Namen."

    // MARK: Kennungen und Adressen

    public static func localID(conversation: Int, message: Int) -> String { "\(localPrefix)\(conversation)-\(message)" }

    /// "lw-msg-12-345" -> 12; sonst nil
    public static func conversation(of local: String) -> Int? {
        guard local.hasPrefix(localPrefix) else { return nil }
        let parts = local.dropFirst(localPrefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return Int(parts[0])
    }

    public static func isLearnweb(_ local: String) -> Bool { conversation(of: local) != nil }

    public static func webURL(base: String, conversation: Int) -> String {
        "\(trimmed(base))/message/index.php?convid=\(conversation)"
    }

    public static func inboxURL(base: String) -> String { "\(trimmed(base))/message/index.php" }

    static func trimmed(_ base: String) -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private static let userIDREs = [HText.regex(#""userId"\s*:\s*(\d+)"#), HText.regex(#"\bdata-userid\s*=\s*"(\d+)""#),
                                    HText.regex(#"[?&;]userid=(\d+)"#)]

    /// Eigene Kennung aus einer angemeldeten Seite (M.cfg.userId, sonst data-userid des Nachrichten-Menues); 1 = Gast
    public static func userID(fromPage html: String) -> Int? {
        for re in userIDREs {
            if let g = HText.match(re, html)?.groups[1], let id = Int(g), id > 1 { return id }
        }
        return nil
    }

    /// "2026-11-05T10:00:00+01:00" (Ortszeit Berlin, wie Stud.IP mkdate und Python `sent_iso`)
    public static func sentISO(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: Argumente

    public static func conversationsArgs(me: Int) -> [(String, JSONValue)] {
        [("userid", .number(Double(me))), ("limitfrom", 0), ("limitnum", .number(Double(conversationLimit))), ("mergeself", false)]
    }

    public static func conversationArgs(me: Int, conversation: Int) -> [(String, JSONValue)] {
        [("userid", .number(Double(me))), ("conversationid", .number(Double(conversation))), ("includecontactrequests", false),
         ("includeprivacyinfo", false), ("memberlimit", .number(Double(memberLimit))), ("memberoffset", 0), ("messagelimit", 1),
         ("messageoffset", 0), ("newestmessagesfirst", true)]
    }

    public static func sendArgs(conversation: Int, text: String) -> [(String, JSONValue)] {
        [("conversationid", .number(Double(conversation))),
         ("messages", .array([.object(["text": .string(text), "textformat": .number(Double(formatPlain))])]))]
    }

    /// Verschachtelte Argumente fuer REST (Formular) wie `learnweb_messages.flatten`: messages[0][text]=…, Wahrheitswerte 1/0
    public static func flatten(_ args: [(String, JSONValue)]) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ key: String, _ v: JSONValue) {
            switch v {
            case .object(let o): for (k, x) in o { walk("\(key)[\(k)]", x) }
            case .array(let a): for (i, x) in a.enumerated() { walk("\(key)[\(i)]", x) }
            case .bool(let b): out[key] = b ? "1" : "0"
            case .null: break
            case .string(let s): out[key] = s
            case .number(let d): out[key] = JSONValue.format(d)
            }
        }
        for (k, v) in args { walk(k, v) }
        return out
    }

    // MARK: Lesen

    /// `parse_conversations`: je Einzel- oder Gruppenunterhaltung die neueste Nachricht, die nicht von dir kommt;
    /// eigene Notizen (Typ 3), Unterhaltungen nur mit eigenen Nachrichten und leere fehlen. Neueste zuerst.
    public static func parseConversations(_ data: JSONValue?, me: Int, base: String, today: Int) -> [StudIPExtras.Message] {
        var out: [StudIPExtras.Message] = []
        for c in data?["conversations"]?.array ?? [] {
            guard let cid = c["id"]?.int else { continue }
            let kind = c["type"]?.int ?? 0
            guard kind == typeIndividual || kind == typeGroup else { continue }
            let mine = (c["messages"]?.array ?? []).filter { m in
                m["id"]?.int != nil && (m["useridfrom"]?.int).map { $0 != me } == true && (m["timecreated"]?.int ?? 0) != 0
            }
            guard let m = mine.max(by: { a, b in
                let ta = a["timecreated"]?.int ?? 0, tb = b["timecreated"]?.int ?? 0
                return ta != tb ? ta < tb : (a["id"]?.int ?? 0) < (b["id"]?.int ?? 0)
            }), let mid = m["id"]?.int, let ts = m["timecreated"]?.int else { continue }
            let text = PyText.slice(Announcements.htmlToText(m["text"]?.string ?? ""), 0, Announcements.maxText)
            var subject = subjectIndividual
            if kind == typeGroup {
                subject = PyText.slice(Announcements.htmlToText(c["name"]?.string ?? ""), 0, Announcements.maxTitle)
                if subject.isEmpty { subject = subjectGroup }
            }
            let sent = sentISO(ts)
            let posted = Announcements.postedDayOrNil(sent) ?? today
            let dates: [JSONValue] = Announcements.datesFor(title: subject, text: text, posted: posted).map { d in
                ["date": d["date"] ?? .null, "time": d["time"] ?? .null, "kind": d["kind"] ?? .null]
            }
            out.append(StudIPExtras.Message(id: localID(conversation: cid, message: mid),
                                            sender: kind == typeGroup ? senderGroup : senderIndividual, subject: subject,
                                            preview: text, sentAt: sent, url: webURL(base: base, conversation: cid), dates: dates))
        }
        return out.sorted { a, b in a.sentAt != b.sentAt ? PyText.less(b.sentAt, a.sentAt) : PyText.less(b.id, a.id) }
    }

    /// Mitglieder einer Unterhaltung fuer das Antwortfenster (Namen nur im Speicher)
    public struct Context: Sendable, Equatable {
        public let conversationID: Int
        public let group: Bool
        /// Gruppenname bzw. Name der anderen Person
        public let name: String
        public let memberCount: Int
        public let recipients: [StudIPPerson]
        public let replyable: Bool
        /// "self" | "not_allowed" | nil
        public let reason: String?
    }

    /// `reply_context`
    public static func context(_ conv: JSONValue?, me: Int) throws -> Context {
        guard let conv, let cid = conv["id"]?.int else { throw LearnwebMessageError.notFound }
        let kind = conv["type"]?.int ?? 0
        let members = (conv["members"]?.array ?? []).filter { x in x["id"]?.int.map { $0 != me } == true }
        if kind == typeSelf {
            return Context(conversationID: cid, group: false, name: "", memberCount: conv["membercount"]?.int ?? (members.count + 1),
                           recipients: [], replyable: false, reason: "self")
        }
        let people = members.map { StudIPPerson(id: String($0["id"]?.int ?? 0), name: $0["fullname"]?.string ?? "Learnweb-Nutzer/in") }
        let blocked = kind == typeIndividual && members.contains { $0["isblocked"]?.bool == true || $0["canmessage"]?.bool == false }
        let group = kind == typeGroup
        return Context(conversationID: cid, group: group,
                       name: group ? (conv["name"]?.string ?? "") : (people.first?.name ?? ""),
                       memberCount: conv["membercount"]?.int ?? (members.count + 1), recipients: people,
                       replyable: !people.isEmpty && !blocked, reason: blocked || people.isEmpty ? "not_allowed" : nil)
    }

    /// `send_result`: Kennung der neuen Nachricht
    public static func sentID(_ data: JSONValue?) -> Int? { data?.array?.first?["id"]?.int }

    /// `error_for`
    public static func error(code: String?) -> LearnwebMessageError {
        let c = (code ?? "").lowercased()
        if ["invalidsesskey", "servicerequireslogin", "requireloginerror", "sessionexpired", "invalidtoken"].contains(c) { return .login }
        if ["usercantbemessaged", "messagingdisabled", "nopermissions", "cannotmessageuser", "blockedbyuser"].contains(c) { return .notAllowed }
        if ["invalidrecord", "conversationdoesntexist", "invalidparameter"].contains(c) { return .notFound }
        return .http(c.isEmpty ? "Fehler" : c)
    }
}

public enum LearnwebMessageError: Error, Equatable, LocalizedError {
    case notFound, notAllowed, ownNotes, login, noUser, offline
    case http(String)

    /// Code wie `learnweb_messages.MessageError.code`
    public var code: String {
        switch self {
        case .notFound: return "not_found"
        case .notAllowed: return "not_allowed"
        case .ownNotes: return "self"
        case .login: return "login"
        case .noUser: return "no_user"
        case .offline: return "offline"
        case .http: return "http"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notFound: return "Die Unterhaltung gibt es im Learnweb nicht mehr. Antworte bitte direkt im Learnweb."
        case .notAllowed: return "Das Learnweb lässt hier keine Antwort zu (Person nimmt keine Nachrichten an oder Nachrichten sind gesperrt)."
        case .ownNotes: return "Das ist deine eigene Notiz-Unterhaltung im Learnweb."
        case .login: return "Die Learnweb-Anmeldung ist abgelaufen. Bitte neu anmelden."
        case .noUser: return "Das Learnweb hat deine Kennung nicht genannt. Antworte bitte direkt im Learnweb."
        case .offline: return "Keine Verbindung zum Learnweb. Dein Text bleibt als Entwurf."
        case .http(let c): return "Das Learnweb hat die Nachricht nicht angenommen (\(c))."
        }
    }

    public var offersWebFallback: Bool { ![.login, .offline, .ownNotes].contains(self) }
}

extension LearnwebAPI {
    /// Eigene Moodle-Kennung: mit Schluessel aus core_webservice_get_site_info, mit der Sitzung aus der Seite des sesskey
    public func ownUserID() async throws -> Int {
        switch mode {
        case .token:
            if let uid = siteUserID { return uid }               // schon beim Kursabruf dieses Laufs gelesen
            guard let uid = try await rest("core_webservice_get_site_info", [:])["userid"]?.int else { throw LearnwebMessageError.noUser }
            siteUserID = uid
            return uid
        case .session:
            _ = try await currentSesskey()
            guard let uid = pageUserID else { throw LearnwebMessageError.noUser }
            return uid
        }
    }

    /// Aufruf mit verschachtelten Argumenten: REST (flach) oder AJAX (JSON); Fehlercodes von Moodle als
    /// `LearnwebMessageError` (Sitzung abgelaufen bleibt `HildesheimError.sessionExpired`)
    func messageCall(_ function: String, _ args: [(String, JSONValue)], once: Bool = false) async throws -> JSONValue {
        do {
            switch mode {
            case .token: return try await rest(function, LearnwebMessages.flatten(args), retry: once ? UniRetry.none : nil)
            case .session:
                var o: [String: JSONValue] = [:]
                for (k, v) in args { o[k] = v }
                return try await ajax(function, .object(o), retry: once ? UniRetry.none : nil)
            }
        } catch HildesheimError.badResponse(let m) where m.hasPrefix("\(function): ") {
            throw LearnwebMessages.error(code: String(m.dropFirst(function.count + 2)))
        } catch HildesheimError.invalidToken {
            throw LearnwebMessageError.login
        }
    }

    /// Unterhaltungen lesen (nur lesend) -> Nachrichten zum Speichern
    public func messages(today: Int) async throws -> [StudIPExtras.Message] {
        let me = try await ownUserID()
        let data = try await messageCall("core_message_get_conversations", LearnwebMessages.conversationsArgs(me: me))
        return LearnwebMessages.parseConversations(data, me: me, base: base, today: today)
    }

    /// Mitglieder einer Unterhaltung (Antwortfenster)
    public func messageContext(conversation: Int) async throws -> LearnwebMessages.Context {
        let me = try await ownUserID()
        let data = try await messageCall("core_message_get_conversation", LearnwebMessages.conversationArgs(me: me, conversation: conversation))
        return try LearnwebMessages.context(data, me: me)
    }

    /// Antwort in die Unterhaltung senden: genau ein Versuch, nur auf Knopfdruck. Liefert die Kennung der neuen Nachricht.
    public func sendMessage(conversation: Int, text: String) async throws -> Int? {
        let data = try await messageCall("core_message_send_messages_to_conversation",
                                         LearnwebMessages.sendArgs(conversation: conversation, text: text), once: true)
        return LearnwebMessages.sentID(data)
    }
}
