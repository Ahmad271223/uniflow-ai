import Foundation

/// Was die Uni-Mail-Oberflaeche von einem Postfach braucht. SOGo (LUH, Uni Hildesheim) und IMAP/SMTP (Uni Goettingen)
/// liefern dieselben JSON-Formen (`SOGo.folderListing`, `SOGo.headers`, `SOGo.message`, `SOGo.draft`), damit Liste,
/// Lesen, Antworten und Senden in der App gleich bleiben.
public protocol UniMailBackend: AnyObject, Sendable {
    func mailboxes() async throws -> [JSONValue]
    func folder(_ path: String, query: String) async throws -> JSONValue
    func headers(_ path: String, uids: [Int]) async throws -> [JSONValue]
    func message(_ path: String, uid: Int) async throws -> JSONValue
    func unseen(_ path: String) async throws -> Int?
    func download(_ attachmentPath: String, to destination: URL) async throws
    func markRead(_ path: String, uid: Int, read: Bool) async throws
    func flag(_ path: String, uid: Int, flagged: Bool) async throws
    func trash(_ path: String, uids: [Int]) async throws
    func move(_ path: String, uids: [Int], to target: String) async throws
    func newDraft(_ action: String, folder: String, uid: Int?) async throws -> JSONValue
    @discardableResult func save(_ d: JSONValue, body: JSONValue) async throws -> Int?
    func attach(_ d: JSONValue, name: String, data: Data, mime: String) async throws -> JSONValue
    func send(_ d: JSONValue, body: JSONValue) async throws -> (ok: Bool, message: String)
}

extension SOGoClient: UniMailBackend {}

/// Fehler der IMAP-Uni-Mail (Texte fuer die Oberflaeche)
public enum IMAPMailError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Hochschule hat Benutzername/Passwort abgelehnt: nie ein zweites Mal senden
    case rejected(String)
    case offline
    case server(String)

    public var description: String {
        switch self {
        case .rejected: return "Benutzername oder Passwort wurden vom Mail-Rechner der Hochschule abgelehnt. Bitte melde dich bei Uni-Mail neu an."
        case .offline: return "Keine Verbindung zu Uni-Mail (Mail-Rechner der Hochschule)."
        case .server(let s): return "Uni-Mail: \(s)"
        }
    }

    public var errorDescription: String? { description }
}

/// Uni-Mail ueber IMAP (lesen, Ordner, markieren, verschieben, Entwuerfe) und SMTP (senden). Eine Verbindung bleibt
/// offen und wird bei Bedarf neu aufgebaut; lesende Befehle wiederholen nach einer getrennten Verbindung genau einmal,
/// schreibende nie. Nie endgueltig loeschen: "Papierkorb" verschiebt (MOVE bzw. COPY + UID EXPUNGE nur dieser UIDs mit
/// UIDPLUS; ohne UIDPLUS lehnt es ab). Gesendet wird nur aus `send` (Knopf "Senden" mit Rueckfrage), genau einmal.
public actor IMAPMailClient: UniMailBackend {
    public typealias Credential = @Sendable () async -> (username: String, password: String)?

    public let site: IMAPMailSite
    /// Absender-Adresse (<kennung>@stud.uni-goettingen.de)
    public let address: String
    let opener: MailStreamOpener
    let credential: Credential
    let now: @Sendable () -> Date
    private var session: IMAPSession?
    private var lastUse = Date.distantPast
    private var boxes: [JSONValue] = []
    /// zuletzt gelesene Nachrichten roh (Antworten, Anhaenge ohne zweiten Abruf)
    private var raw: [(key: String, data: Data)] = []
    private var drafts: [String: DraftState] = [:]
    /// Zahl der SMTP-Sendungen (Tests: nie mehr als Knopfdruecke)
    public private(set) var smtpSends = 0
    /// Zahl der Verbindungen (Tests)
    public private(set) var connects = 0

    struct DraftState {
        var attachments: [MailCompose.Attachment] = []
        var inReplyTo: String?
        var references: String?
        var source: (folder: String, uid: Int)?
        var action = "compose"
        var savedUID: Int?
    }

    public init(site: IMAPMailSite, address: String, opener: MailStreamOpener, now: @escaping @Sendable () -> Date = { Date() },
                credential: @escaping Credential) {
        self.site = site
        self.address = address
        self.opener = opener
        self.now = now
        self.credential = credential
    }

    // MARK: Verbindung

    /// Verbindung pruefen (Anmelden in der App): einmal anmelden, Ordner lesen
    public func verify() async throws {
        _ = try await mailboxes()
    }

    private func open() async throws -> IMAPSession {
        if let s = session, await !s.closed { return s }
        session = nil
        guard let c = await credential() else { throw SOGoError.needsLogin }
        let s: IMAPSession
        do {
            s = try await IMAPSession.connect(opener, site: site)
        } catch let e as MailStreamError {
            throw e == .notAllowed(site.imapHost) ? IMAPMailError.server(e.description) : IMAPMailError.offline
        }
        connects += 1
        do {
            try await s.login(user: site.loginName(c.username), password: c.password)
        } catch IMAPError.authenticationFailed(let t) {
            await s.abandon()
            throw IMAPMailError.rejected(t)
        } catch is MailStreamError {
            await s.abandon()
            throw IMAPMailError.offline
        }
        session = s
        return s
    }

    /// Abmelden: Verbindung schliessen, Zwischenspeicher leeren
    public func close() async {
        if let s = session { await s.logout() }
        session = nil
        raw = []
        drafts = [:]
        boxes = []
    }

    /// Lesender Ablauf: getrennte Verbindung -> einmal neu verbinden und wiederholen
    private func reading<T>(_ op: (IMAPSession) async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            let s = try await open()
            do {
                let r = try await op(s)
                lastUse = now()
                return r
            } catch let e as MailStreamError {
                await s.abandon()
                session = nil
                if attempt == 1 || e == .tooLarge { throw e == .tooLarge ? IMAPMailError.server(e.description) : IMAPMailError.offline }
            } catch let e as IMAPError {
                throw Self.map(e)
            }
        }
        throw IMAPMailError.offline
    }

    /// Schreibender Ablauf: genau ein Versuch; eine lange unbenutzte Verbindung vorher mit NOOP pruefen
    private func writing<T>(_ op: (IMAPSession) async throws -> T) async throws -> T {
        if now().timeIntervalSince(lastUse) > 60 { _ = try await reading { try await $0.run("NOOP") } }
        let s = try await open()
        do {
            let r = try await op(s)
            lastUse = now()
            return r
        } catch is MailStreamError {
            await s.abandon()
            session = nil
            throw IMAPMailError.offline
        } catch let e as IMAPError {
            throw Self.map(e)
        }
    }

    static func map(_ e: IMAPError) -> Error {
        switch e {
        case .authenticationFailed(let t): return IMAPMailError.rejected(t)
        case .rejected(let t): return IMAPMailError.server(IMAPSession.clean(t))
        case .protocolError(let t): return IMAPMailError.server("unerwartete Antwort (\(IMAPSession.clean(t)))")
        case .unsupported(let t): return IMAPMailError.server("Der Mail-Rechner kann das nicht (\(t)).")
        }
    }

    // MARK: Ordner

    static let hiddenFolders: Set<String> = ["calendar", "kalender", "contacts", "kontakte", "tasks", "aufgaben", "journal", "notes", "notizen",
                                            "outbox", "postausgang", "sync issues", "synchronisierungsprobleme", "conversation history",
                                            "unterhaltungsverlauf", "rss feeds", "rss-feeds", "rss-abonnements", "suggested contacts",
                                            "vorgeschlagene kontakte", "files", "dateien", "social activity notifications", "yammer root"]

    static let typeNames: [String: Set<String>] = [
        "draft": ["drafts", "entwürfe", "entwuerfe", "draft"],
        "sent": ["sent items", "sent", "sent messages", "gesendete elemente", "gesendet", "gesendete objekte"],
        "trash": ["deleted items", "trash", "deleted messages", "gelöschte elemente", "gelöschte objekte", "papierkorb"],
        "junk": ["junk email", "junk e-mail", "junk-e-mail", "junk", "spam", "junk-mail"],
    ]

    static let typeFlags: [String: String] = ["\\drafts": "draft", "\\sent": "sent", "\\trash": "trash", "\\junk": "junk"]

    /// Ordner aus LIST in der Form von `SOGo.mailboxes` (feste zuerst, ohne \Noselect, ohne Kalender/Kontakte von Exchange)
    public static func mailboxes(_ list: [IMAP.Mailbox]) -> [JSONValue] {
        var found: [JSONValue] = [], taken = Set<String>()
        for m in list.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) where m.selectable {
            let delim = m.delimiter ?? "/"
            let parts = delim.isEmpty ? [m.raw] : m.raw.components(separatedBy: delim)
            let top = IMAP.decodeMailbox(parts.first ?? m.raw).lowercased()
            if hiddenFolders.contains(top) { continue }
            let display = IMAP.decodeMailbox(parts.last ?? m.raw)
            var typ = "folder"
            if m.raw.uppercased() == "INBOX" { typ = "inbox" } else if let f = m.flags.compactMap({ typeFlags[$0.lowercased()] }).first {
                typ = f
            } else if parts.count == 1, let t = typeNames.first(where: { $0.value.contains(display.lowercased()) })?.key {
                typ = t
            }
            if typ != "folder" { if taken.contains(typ) { typ = "folder" } else { taken.insert(typ) } }
            let name = typ == "folder" ? display : (SOGo.folderNames[typ] ?? display)
            found.append(["path": .string(m.raw), "name": .string(name), "type": .string(typ), "id": .string(m.raw), "level": .number(Double(parts.count - 1))])
        }
        var special: [JSONValue] = []
        for t in SOGo.folderOrder {
            if var hit = found.first(where: { $0["type"]?.string == t }) {
                hit["level"] = 0
                special.append(hit)
            }
        }
        let used = Set(special.compactMap { $0["path"]?.string })
        return special + found.filter { !used.contains($0["path"]?.string ?? "") }
    }

    public func mailboxes() async throws -> [JSONValue] {
        let r = try await reading { try await $0.run([.raw("LIST"), .string(""), .string("*")]) }
        boxes = Self.mailboxes(r.untagged.compactMap(IMAP.listEntry))
        return boxes
    }

    private func knownBoxes() async throws -> [JSONValue] {
        if boxes.isEmpty { _ = try await mailboxes() }
        return boxes
    }

    private func folderPath(_ type: String, fallback: String) async throws -> String {
        SOGo.folder(ofType: type, in: try await knownBoxes(), fallback: fallback)
    }

    // MARK: Liste

    public func unseen(_ path: String) async throws -> Int? {
        let r = try await reading { try await $0.run([.raw("STATUS"), .string(path), .raw("(UNSEEN)")]) }
        return r.untagged.map(IMAP.statusEntry).first { $0["UNSEEN"] != nil }?["UNSEEN"]
    }

    /// Ordner neu lesen: alle UIDs (neueste zuerst), erste Seite, ungelesene; mit Suchtext Betreff oder Absender
    public func folder(_ path: String, query: String) async throws -> JSONValue {
        let q = SOGo.scalars(SOGo.squash(query), 200)
        let unseen = try await self.unseen(path)
        let uids: [Int] = try await reading { s in
            await s.unselect()
            try await s.select(path)
            var args: [IMAPArg] = [.raw("UID"), .raw("SEARCH")]
            if q.isEmpty {
                args.append(.raw("ALL"))
            } else {
                if !MailCompose.isASCII(q) { args += [.raw("CHARSET"), .raw("UTF-8")] }
                args += [.raw("OR"), .raw("SUBJECT"), .string(q), .raw("FROM"), .string(q)]
            }
            let r = try await s.run(args)
            return Array(Set(r.untagged.compactMap(IMAP.searchEntry).flatMap { $0 })).sorted(by: >)
        }
        let first = SOGo.pageUIDs(uids, page: 0)
        let messages = try await headers(path, uids: first)
        return ["folder": .string(path), "uids": .array(uids.map { .number(Double($0)) }), "total": .number(Double(uids.count)), "page": 0,
                "pages": .number(Double((uids.count + SOGo.pageSize - 1) / SOGo.pageSize)), "messages": .array(messages),
                "unseen": unseen.map { .number(Double($0)) } ?? .null, "sync_token": .null]
    }

    static let headerFields = "BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE CONTENT-TYPE)]"

    /// Kopfzeilen einer Seite in der Reihenfolge der UIDs
    public func headers(_ path: String, uids: [Int]) async throws -> [JSONValue] {
        guard !uids.isEmpty else { return [] }
        let r = try await reading { s in
            try await s.select(path)
            return try await s.run([.raw("UID"), .raw("FETCH"), .raw(IMAP.uidSet(uids)), .raw("(UID FLAGS RFC822.SIZE INTERNALDATE \(Self.headerFields))")])
        }
        let now = self.now()
        let rows = r.untagged.compactMap(IMAP.fetchEntry).compactMap { Self.headerRow($0, now: now) }
        return SOGo.ordered(rows, uids)
    }

    /// Eine Zeile der Liste in der Form von `SOGo.headers`
    static func headerRow(_ f: [String: IMAPValue], now: Date) -> JSONValue? {
        guard let uid = f["UID"]?.int, uid > 0 else { return nil }
        let flags = (f["FLAGS"]?.list ?? []).compactMap(\.text).map { $0.lowercased() }
        let h = MailMIME.headers(f["BODY[HEADER]"]?.data ?? Data())
        let from = MailMIME.addresses(MailMIME.header(h, "from")), to = MailMIME.addresses(MailMIME.header(h, "to"))
        let ct = MailMIME.parameters(MailMIME.header(h, "content-type")).value
        let date = MailMIME.date(MailMIME.header(h, "date")) ?? MailMIME.internalDate(f["INTERNALDATE"]?.text)
        let labels: [JSONValue] = flags.filter { !$0.hasPrefix("\\") && !["$forwarded", "nonjunk", "junk", "$mdnsent"].contains($0) }.map { .string($0) }
        return ["uid": .number(Double(uid)), "subject": .string(HText.collapse(MailMIME.decodeWords(MailMIME.header(h, "subject") ?? ""))),
                "from": .array(from), "to": .array(to), "sender": .string(SOGo.addressText(from.first)),
                "date": .string(date.map { relativeDate($0, now: now) } ?? ""), "size": .string(size(f["RFC822.SIZE"]?.int ?? 0)),
                "read": .bool(flags.contains("\\seen")), "flagged": .bool(flags.contains("\\flagged")), "answered": .bool(flags.contains("\\answered")),
                "forwarded": .bool(flags.contains("$forwarded")), "attachment": .bool(ct == "multipart/mixed" || ct.hasPrefix("application/")),
                "labels": .array(labels)]
    }

    // MARK: Anzeige von Datum und Groesse (wie SOGo: "10:42", "Gestern", "05.11.2026")

    static func berlin(_ d: Date) -> (day: Int, minutes: Int) {
        let utc = Int(d.timeIntervalSince1970)
        let local = utc + (BerlinClock.isSummerTime(utc: utc) ? 7200 : 3600)
        let day = BerlinClock.floorDiv(local, 86400)
        return (day, (local - day * 86400) / 60)
    }

    static func dmy(_ day: Int) -> String {
        let c = BerlinClock.civil(day)
        return String(format: "%02d.%02d.%04d", c.day, c.month, c.year)
    }

    static func hm(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    public static func relativeDate(_ d: Date, now: Date) -> String {
        let a = berlin(d), n = berlin(now)
        if a.day == n.day { return hm(a.minutes) }
        if a.day == n.day - 1 { return "Gestern" }
        return dmy(a.day)
    }

    public static func fullDate(_ d: Date) -> String {
        let a = berlin(d)
        return "\(dmy(a.day)) \(hm(a.minutes))"
    }

    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return bytes <= 0 ? "" : "1 KB" }
        if bytes < 1024 * 1024 { return "\((bytes + 1023) / 1024) KB" }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Lesen

    private func remember(_ key: String, _ d: Data) {
        raw.removeAll { $0.key == key }
        raw.append((key, d))
        if raw.count > 3 { raw.removeFirst() }
    }

    private func rawMessage(_ path: String, uid: Int, markSeen: Bool) async throws -> (data: Data, flags: [String]) {
        let key = path + "\u{0}\(uid)"
        let item = markSeen ? "BODY[]" : "BODY.PEEK[]"
        if !markSeen, let hit = raw.first(where: { $0.key == key }) { return (hit.data, []) }
        let r = try await reading { s in
            try await s.select(path)
            return try await s.run([.raw("UID"), .raw("FETCH"), .raw("\(uid)"), .raw("(UID FLAGS \(item))")])
        }
        guard let f = r.untagged.compactMap(IMAP.fetchEntry).first(where: { $0["UID"]?.int == uid }), let body = f["BODY[]"]?.data else {
            throw IMAPMailError.server("Die E-Mail gibt es in diesem Ordner nicht mehr.")
        }
        remember(key, body)
        return (body, (f["FLAGS"]?.list ?? []).compactMap(\.text).map { $0.lowercased() })
    }

    /// Anhang-Adresse "imap:<ordner base64url>/<uid>/<teil>"
    static func attachmentPath(folder: String, uid: Int, part: String) -> String {
        let f = Data(folder.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "imap:\(f)/\(uid)/\(part)"
    }

    static func parseAttachmentPath(_ p: String) -> (folder: String, uid: Int, part: String)? {
        guard p.hasPrefix("imap:") else { return nil }
        let x = p.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        guard x.count == 3, let uid = Int(x[1]), uid > 0, x[2].allSatisfy({ $0.isNumber || $0 == "." }), !x[2].isEmpty else { return nil }
        var b = x[0].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let folder = String(data: d, encoding: .utf8) else { return nil }
        return (folder, uid, String(x[2]))
    }

    /// Nachricht in der Form von `SOGo.message` (HTML bereinigt mit `SOGo.sanitize`)
    static func messageJSON(_ data: Data, folder: String, uid: Int, flags: [String]) -> JSONValue {
        let root = MailMIME.parse(data)
        let h = root.headers
        let c = MailMIME.contents(root)
        let rawHTML = c.html.joined(separator: "\n")
        let clean = SOGo.sanitize(rawHTML)
        let text = c.text.isEmpty ? SOGo.htmlToText(rawHTML) : c.text.joined(separator: "\n").replacingOccurrences(of: "\r\n", with: "\n")
        var files: [JSONValue] = []
        for p in c.attachments {
            var name = p.filename ?? ""
            if name.isEmpty, p.contentType.type == "message/rfc822" {
                let sub = MailMIME.decodeWords(MailMIME.header(MailMIME.headers(MailMIME.split(p.body).header), "subject") ?? "")
                name = (sub.isEmpty ? "Nachricht" : SOGo.cleanFilename(sub)) + ".eml"
            }
            files.append(["index": .number(Double(files.count)), "name": .string(name.isEmpty ? "Anhang" : SOGo.cleanFilename(name)),
                          "size": .string(size(p.body.count)), "type": .string(p.contentType.type),
                          "path": .string(attachmentPath(folder: folder, uid: uid, part: p.id))])
        }
        let date = MailMIME.date(MailMIME.header(h, "date"))
        return ["folder": .string(folder), "uid": .number(Double(uid)),
                "subject": .string(HText.collapse(MailMIME.decodeWords(MailMIME.header(h, "subject") ?? ""))),
                "date": .string(date.map(fullDate) ?? ""), "from": .array(MailMIME.addresses(MailMIME.header(h, "from"))),
                "to": .array(MailMIME.addresses(MailMIME.header(h, "to"))), "cc": .array(MailMIME.addresses(MailMIME.header(h, "cc"))),
                "reply_to": .array(MailMIME.addresses(MailMIME.header(h, "reply-to"))), "read": true, "draft": .bool(flags.contains("\\draft")),
                "html": .string(clean.html), "remote_blocked": .bool(clean.remoteBlocked), "text": .string(text), "attachments": .array(files)]
    }

    /// Nachricht lesen (markiert sie dabei als gelesen, wie SOGo)
    public func message(_ path: String, uid: Int) async throws -> JSONValue {
        let m = try await rawMessage(path, uid: uid, markSeen: true)
        return Self.messageJSON(m.data, folder: path, uid: uid, flags: m.flags)
    }

    public func download(_ attachmentPath: String, to destination: URL) async throws {
        guard let p = Self.parseAttachmentPath(attachmentPath) else { throw SOGoError.bad("Anhang nicht aus dem Postfach") }
        let m = try await rawMessage(p.folder, uid: p.uid, markSeen: false)
        guard let part = MailMIME.find(MailMIME.parse(m.data), id: p.part) else { throw IMAPMailError.server("Anhang nicht gefunden.") }
        guard part.body.count <= SOGo.maxAttachment else { throw SOGoError.bad("Anhang zu groß") }
        try part.body.write(to: destination, options: .atomic)
    }

    // MARK: Markieren, Verschieben (je genau ein Befehl)

    private func store(_ path: String, uids: [Int], flag: String, on: Bool) async throws {
        try await writing { s in
            try await s.select(path)
            try await s.run([.raw("UID"), .raw("STORE"), .raw(IMAP.uidSet(uids)), .raw(on ? "+FLAGS.SILENT" : "-FLAGS.SILENT"), .raw("(\(flag))")])
        }
    }

    public func markRead(_ path: String, uid: Int, read: Bool) async throws { try await store(path, uids: [uid], flag: "\\Seen", on: read) }

    public func flag(_ path: String, uid: Int, flagged: Bool) async throws { try await store(path, uids: [uid], flag: "\\Flagged", on: flagged) }

    /// In den Papierkorb verschieben (nie endgueltig loeschen)
    public func trash(_ path: String, uids: [Int]) async throws {
        let target = try await folderPath("trash", fallback: "Deleted Items")
        guard target != path else { throw SOGoError.input("Die E-Mail liegt schon im Papierkorb.") }
        try await move(path, uids: uids, to: target)
    }

    public func move(_ path: String, uids: [Int], to target: String) async throws {
        let set = IMAP.uidSet(uids)
        guard !set.isEmpty, target != path else { return }
        try await writing { s in
            try await s.select(path)
            if await s.has("MOVE") {
                try await s.run([.raw("UID"), .raw("MOVE"), .raw(set), .string(target)])
                return
            }
            // ohne MOVE: kopieren, dann genau diese UIDs entfernen (UIDPLUS). Ohne UIDPLUS nie EXPUNGE (wuerde auch
            // fremde, als geloescht markierte Nachrichten endgueltig entfernen)
            guard await s.has("UIDPLUS") else { throw IMAPError.unsupported("Verschieben") }
            try await s.run([.raw("UID"), .raw("COPY"), .raw(set), .string(target)])
            try await s.run([.raw("UID"), .raw("STORE"), .raw(set), .raw("+FLAGS.SILENT"), .raw("(\\Deleted)")])
            try await s.run([.raw("UID"), .raw("EXPUNGE"), .raw(set)])
        }
        raw.removeAll { $0.key.hasPrefix(path + "\u{0}") }
    }

    // MARK: Schreiben

    /// Neuer Entwurf ("compose") oder Antwort/Weiterleitung; sendet nichts und legt nichts im Postfach an
    public func newDraft(_ action: String, folder: String, uid: Int?) async throws -> JSONValue {
        var st = DraftState(action: action)
        var to: [String] = [], cc: [String] = [], subject = "", text = ""
        var source: JSONValue = .null
        switch action {
        case "compose": break
        case "reply", "replyall", "forward":
            guard let uid else { throw SOGoError.input("Nachricht fehlt") }
            let m = try await rawMessage(folder, uid: uid, markSeen: false)
            let root = MailMIME.parse(m.data)
            let h = root.headers
            let msg = Self.messageJSON(m.data, folder: folder, uid: uid, flags: [])
            let from = msg["from"]?.array ?? [], replyTo = msg["reply_to"]?.array ?? []
            let origSubject = msg["subject"]?.string ?? ""
            let body = msg["text"]?.string ?? ""
            let when = MailMIME.date(MailMIME.header(h, "date"))
            let mid = MailMIME.header(h, "message-id")?.trimmingCharacters(in: .whitespaces)
            source = ["folder": .string(folder), "uid": .number(Double(uid))]
            st.source = (folder, uid)
            if action == "forward" {
                subject = MailCompose.subject(origSubject, prefix: "Fwd: ")
                var head = ["---------- Weitergeleitete Nachricht ----------"]
                head.append("Von: " + from.map(SOGo.addressLine).joined(separator: ", "))
                if let when { head.append("Datum: " + Self.fullDate(when)) }
                head.append("Betreff: " + origSubject)
                let toList = (msg["to"]?.array ?? []).map(SOGo.addressLine)
                if !toList.isEmpty { head.append("An: " + toList.joined(separator: ", ")) }
                text = "\n\n" + head.joined(separator: "\n") + "\n\n" + body
                for p in MailMIME.contents(root).attachments {
                    st.attachments.append(.init(name: p.filename ?? "Anhang", mime: p.contentType.type, data: p.body))
                }
            } else {
                subject = MailCompose.subject(origSubject, prefix: "Re: ")
                let primary = replyTo.isEmpty ? from : replyTo
                to = primary.map(SOGo.addressLine)
                let me = address.lowercased()
                if action == "replyall" {
                    let known = Set(to.compactMap { SOGo.emailOf($0)?.lowercased() } + [me])
                    for a in msg["to"]?.array ?? [] where !known.contains((a["email"]?.string ?? "").lowercased()) { to.append(SOGo.addressLine(a)) }
                    let afterTo = Set(to.compactMap { SOGo.emailOf($0)?.lowercased() } + [me])
                    cc = (msg["cc"]?.array ?? []).filter { !afterTo.contains(($0["email"]?.string ?? "").lowercased()) }.map(SOGo.addressLine)
                }
                let who = from.first.map(SOGo.addressText) ?? ""
                let intro = when.map { "Am \(Self.dmy(Self.berlin($0).day)) um \(Self.hm(Self.berlin($0).minutes)) schrieb \(who):" } ?? "\(who) schrieb:"
                text = MailCompose.quote(body, intro: intro)
                st.inReplyTo = mid
                let refs = MailMIME.header(h, "references").map { HText.collapse($0) } ?? ""
                st.references = [refs, mid ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            }
        default:
            throw SOGoError.input("Unbekannte Aktion")
        }
        let id = UUID().uuidString
        drafts[id] = st
        let draftsBox = (try? await folderPath("draft", fallback: "Drafts")) ?? "Drafts"
        let created: JSONValue = ["account": "imap", "mailbox_path": .string(draftsBox), "draft_id": .string(id)]
        let edit: JSONValue = ["from": .string(address), "to": .array(to.map(JSONValue.string)), "cc": .array(cc.map(JSONValue.string)),
                               "subject": .string(subject), "text": .string(text), "isHTML": false,
                               "attachmentAttrs": .array(st.attachments.map { ["filename": .string($0.name), "size": .string(Self.size($0.data.count))] })]
        return SOGo.draft(created: created, edit: edit, action: action, source: source)
    }

    private func state(_ d: JSONValue) throws -> (String, DraftState) {
        let id = d["draft_id"]?.string ?? ""
        guard let st = drafts[id] else { throw SOGoError.input("Der Entwurf ist nicht mehr offen. Bitte die E-Mail neu beginnen.") }
        return (id, st)
    }

    public func attach(_ d: JSONValue, name: String, data: Data, mime: String) async throws -> JSONValue {
        guard data.count <= SOGo.maxAttachment else { throw SOGoError.input("Der Anhang ist größer als 20 MB.") }
        var (id, st) = try state(d)
        let total = st.attachments.reduce(data.count) { $0 + $1.data.count }
        guard total <= 25 * 1024 * 1024 else { throw SOGoError.input("Alle Anhänge zusammen sind größer als 25 MB.") }
        let n = SOGo.cleanFilename(name)
        st.attachments.append(.init(name: n, mime: mime, data: data))
        drafts[id] = st
        return ["name": .string(n), "size": .string(Self.size(data.count))]
    }

    func compose(_ st: DraftState, body: JSONValue) -> MailCompose.Message {
        var m = MailCompose.Message(from: body["from"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? address,
                                    messageID: "\(UUID().uuidString.lowercased())@studinow.app")
        m.to = (body["to"]?.array ?? []).compactMap(\.string)
        m.cc = (body["cc"]?.array ?? []).compactMap(\.string)
        m.bcc = (body["bcc"]?.array ?? []).compactMap(\.string)
        m.subject = body["subject"]?.string ?? ""
        m.text = body["text"]?.string ?? ""
        m.inReplyTo = st.inReplyTo
        m.references = st.references
        m.attachments = st.attachments
        m.date = now()
        return m
    }

    /// Nachricht in einen Ordner legen (APPEND); Rueckgabe: neue UID (mit UIDPLUS)
    private func append(_ data: Data, to box: String, flags: String) async throws -> Int? {
        try await writing { s in
            await s.unselect()
            let r = try await s.run([.raw("APPEND"), .string(box), .raw("(\(flags))"), .literal(data)])
            return IMAP.appendUID(r.code)
        }
    }

    /// Eigene fruehere Fassung eines Entwurfs entfernen (nur die eine UID, nur mit UIDPLUS)
    private func dropDraft(_ uid: Int, in box: String) async {
        _ = try? await writing { s in
            guard await s.has("UIDPLUS") else { return }
            try await s.select(box)
            try await s.run([.raw("UID"), .raw("STORE"), .raw("\(uid)"), .raw("+FLAGS.SILENT"), .raw("(\\Deleted)")])
            try await s.run([.raw("UID"), .raw("EXPUNGE"), .raw("\(uid)")])
        }
    }

    /// Als Entwurf speichern (Knopf "Als Entwurf speichern"); die vorige eigene Fassung ersetzt es
    @discardableResult
    public func save(_ d: JSONValue, body: JSONValue) async throws -> Int? {
        var (id, st) = try state(d)
        let box = d["mailbox_path"]?.string ?? "Drafts"
        let data = MailCompose.render(compose(st, body: body), includeBcc: true)
        let uid = try await append(data, to: box, flags: "\\Draft \\Seen")
        if let old = st.savedUID { await dropDraft(old, in: box) }
        st.savedUID = uid
        drafts[id] = st
        return uid
    }

    /// Senden: genau eine SMTP-Sendung, nur nach dem Knopf "Senden". Eingabefehler werfen vor jeder Verbindung. Danach
    /// (ohne Einfluss auf "gesendet"): Kopie in "Gesendet", Quelle als beantwortet markieren, gespeicherten Entwurf weg.
    public func send(_ d: JSONValue, body: JSONValue) async throws -> (ok: Bool, message: String) {
        if let err = SOGo.checkSend(body) { throw SOGoError.input(err) }
        let (id, st) = try state(d)
        guard let c = await credential() else { throw SOGoError.needsLogin }
        let m = compose(st, body: body)
        let data = MailCompose.render(m)
        smtpSends += 1
        do {
            try await SMTPClient(site: site, opener: opener).send(user: site.loginName(c.username), password: c.password, from: address,
                                                                 recipients: m.recipients, message: data)
        } catch let e as SMTPError {
            return (false, e.description)
        } catch is MailStreamError {
            throw IMAPMailError.offline
        }
        var note = ""
        if site.appendsSent {
            do {
                _ = try await append(data, to: try await folderPath("sent", fallback: "Sent Items"), flags: "\\Seen")
            } catch {
                note = " Die Kopie in „Gesendet“ konnte nicht abgelegt werden."
            }
        }
        if let src = st.source, st.action != "compose" {
            try? await store(src.folder, uids: [src.uid], flag: st.action == "forward" ? "$Forwarded" : "\\Answered", on: true)
        }
        if let old = st.savedUID { await dropDraft(old, in: d["mailbox_path"]?.string ?? "Drafts") }
        drafts[id] = nil
        return (true, "Gesendet." + note)
    }
}
