import Foundation

/// Kommentare und Likes ohne eigenen Server (CloudKit, 03.11.2026), dieselben Regeln wie app/community.py
/// (`add_comment`, `comments`, `_anchor`, `MAX_COMMENT`, `REPORTS_TO_HIDE`). Reine Funktionen: Text und Stelle pruefen,
/// Kommentar verschluesseln und den Verlauf ordnen.
///
/// Verschluesselung: Text, Pseudonym, Seite und Stelle liegen beim Dienst nur als Chiffrat (`payload`). Schluessel aus
/// dem Community-Geheimnis (`CommunityKeys.secret`, dasselbe wie fuer die Pakete) per HKDF-SHA256 mit eigenem Salz je
/// Kommentar, AES-256-GCM ueber `SolutionCipher`; die Zusatzdaten binden das Chiffrat an Loesung und Kommentar-ID
/// (kein Umhaengen unter eine andere Loesung oder einen anderen Kommentar). Wer die Community nicht kennt (Apple,
/// Fremde), sieht nur Zeitpunkt, Status und Verweise.
public enum CommunityDiscussion {
    /// wie `MAX_COMMENT` im Dienst (Zeichen = Unicode-Skalare wie `len()` in Python)
    public static let maxComment = 2_000
    /// Seiten-Schluessel (`pages[].key`) hoechstens so lang, wie im Dienst (`_anchor`)
    public static let maxPageKey = 40
    /// so viele verschiedene Meldungen blenden einen Kommentar aus (`REPORTS_TO_HIDE`)
    public static let reportsToHide = 3
    /// Name ohne Pseudonym (leer gelassen in den Einstellungen)
    public static let anonymousName = "Anonym"
    /// Chiffrat eines Kommentars hoechstens so gross (Base64), groessere werden ungeprueft verworfen
    public static let maxPayloadChars = 64 * 1024

    static let payloadVersion: UInt8 = 1
    static let saltBytes = 32, nonceBytes = 12, tagBytes = 16
    static let format = "uniflow-community-comment"

    /// Zustand eines Kommentars beim Dienst; `hidden` setzt die Moderation (Dashboard) oder `reportsToHide`
    public enum Status: String, Sendable { case active, deleted, hidden }

    // MARK: Pruefen (wie der Dienst)

    /// Getrimmter Text ohne Steuer- und Richtungszeichen (`plain_text` im Dienst); leer oder zu lang wirft dieselben
    /// Meldungen wie der Dienst. Kommentare und Fragen liegen in CloudKit nur verschluesselt, darum bereinigt das Geraet
    /// selbst (Haertetest 13.11.2026, gemeinsame Faelle: fixtures/community/text-cases.json).
    public static func cleanText(_ text: String) throws -> String {
        let t = plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw CommunityServiceError.service("Der Kommentar ist leer.") }
        guard t.unicodeScalars.count <= maxComment else { throw CommunityServiceError.service("Höchstens \(maxComment) Zeichen.") }
        return t
    }

    /// Ohne Steuerzeichen (ausser Tab und Zeilenumbruch, also auch ohne `\r`) und ohne Unicode-Richtungszeichen
    /// (U+202A-202E, U+2066-2069), wie `_INVISIBLE` in app/community.py; Skalar fuer Skalar, damit `\r\n` als ein
    /// Zeichen nicht mitsamt dem Zeilenumbruch verschwindet.
    public static func plainText(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where !isInvisible(u.value) { out.append(u) }
        return String(out)
    }

    static func isInvisible(_ v: UInt32) -> Bool {
        (0x00...0x08).contains(v) || (0x0B...0x1F).contains(v) || (0x7F...0x9F).contains(v)
            || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
    }

    /// Seite und Stelle (`_anchor`): Seite gekuerzt, Stelle nur mit Seite und x, y in 0...1
    public static func cleanAnchor(pageKey: String?, anchor: CommunityComment.Anchor?) throws -> (String?, CommunityComment.Anchor?) {
        let pk = pageKey.map { String($0.prefix(maxPageKey)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard let a = anchor else { return (pk, nil) }
        guard a.x.isFinite, a.y.isFinite, (0...1).contains(a.x), (0...1).contains(a.y), pk != nil else {
            throw CommunityServiceError.service("Ungültige Stelle (x und y zwischen 0 und 1, dazu die Seite).")
        }
        return (pk, a)
    }

    /// Pseudonym, wie es im Kommentar steht: getrimmt und begrenzt wie beim Veroeffentlichen; leer = anonym
    public static func pseudonym(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SolutionLimits.maxDisplayName))
    }

    // MARK: Verschluesseln

    /// Inhalt eines Kommentars (nur verschluesselt beim Dienst)
    public struct Body: Equatable, Sendable {
        public var text: String
        public var pseudonym: String
        public var pageKey: String?
        public var anchor: CommunityComment.Anchor?

        public init(text: String, pseudonym: String, pageKey: String? = nil, anchor: CommunityComment.Anchor? = nil) {
            self.text = text
            self.pseudonym = pseudonym
            self.pageKey = pageKey
            self.anchor = anchor
        }

        var json: JSONValue {
            var o: [String: JSONValue] = ["text": .string(text), "pseudonym": .string(pseudonym)]
            if let pageKey { o["pageKey"] = .string(pageKey) }
            if let anchor { o["x"] = .number(anchor.x); o["y"] = .number(anchor.y) }
            return .object(o)
        }

        /// Gelesen wird nur, was auch geschrieben werden darf (fremde Datensaetze sind ungeprueft)
        init(json: JSONValue) throws {
            guard let text = json["text"]?.string, let name = json["pseudonym"]?.string,
                  name.count <= SolutionLimits.maxDisplayName else { throw SolutionError.decryptionFailed }
            let anchor = json["x"]?.double.flatMap { x in json["y"]?.double.map { CommunityComment.Anchor(x: x, y: $0) } }
            let (pk, a) = try CommunityDiscussion.cleanAnchor(pageKey: json["pageKey"]?.string, anchor: anchor)
            self.init(text: try CommunityDiscussion.cleanText(text), pseudonym: name, pageKey: pk, anchor: a)
        }
    }

    /// HKDF-Info: Format + Version + Loesungs-ID (ein Schluessel je Loesung und Salz)
    static func keyInfo(solutionID: String) -> Data { Data("\(format)/v\(payloadVersion)|\(solutionID.lowercased())".utf8) }

    /// Zusatzdaten: binden das Chiffrat an Loesung und Kommentar
    static func aad(solutionID: String, commentID: String) -> Data {
        Data("\(format)/v\(payloadVersion)|\(solutionID.lowercased())|\(commentID.lowercased())".utf8)
    }

    /// Kommentar verschluesseln: Base64 aus Version (1 Byte), Salz (32), Nonce (12) und Chiffrat mit Tag
    public static func seal(_ body: Body, commentID: String, solutionID: String, communitySecret: Data, cipher: SolutionCipher,
                            salt: Data? = nil, nonce: Data? = nil) throws -> String {
        let salt = salt ?? SolutionPackage.randomBytes(saltBytes), nonce = nonce ?? SolutionPackage.randomBytes(nonceBytes)
        guard salt.count == saltBytes, nonce.count == nonceBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        let plaintext = body.json.serialized(sortedKeys: true)
        let sealed = try cipher.seal(plaintext, keyMaterial: communitySecret, salt: salt, info: keyInfo(solutionID: solutionID),
                                     nonce: nonce, aad: aad(solutionID: solutionID, commentID: commentID))
        guard sealed.count == plaintext.count + tagBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        return (Data([payloadVersion]) + salt + nonce + sealed).base64EncodedString()
    }

    /// Kommentar entschluesseln und pruefen; falscher Schluessel, veraendertes oder umgehaengtes Chiffrat werfen
    public static func open(_ payload: String, commentID: String, solutionID: String, communitySecret: Data,
                            cipher: SolutionCipher) throws -> Body {
        guard payload.count <= maxPayloadChars, let raw = Data(base64Encoded: payload),
              raw.count > 1 + saltBytes + nonceBytes + tagBytes, raw.first == payloadVersion else { throw SolutionError.decryptionFailed }
        let bytes = [UInt8](raw)
        let salt = Data(bytes[1..<(1 + saltBytes)])
        let nonce = Data(bytes[(1 + saltBytes)..<(1 + saltBytes + nonceBytes)])
        let sealed = Data(bytes[(1 + saltBytes + nonceBytes)...])
        let plaintext: Data
        do {
            plaintext = try cipher.open(sealed, keyMaterial: communitySecret, salt: salt, info: keyInfo(solutionID: solutionID),
                                        nonce: nonce, aad: aad(solutionID: solutionID, commentID: commentID))
        } catch {
            throw SolutionError.decryptionFailed
        }
        guard let json = try? JSONValue.parse(plaintext) else { throw SolutionError.decryptionFailed }
        return try Body(json: json)
    }

    // MARK: Verlauf

    /// Ein Kommentar, wie ihn der Dienst liefert; `body` nil = nicht lesbar (geloescht oder nicht zu entschluesseln)
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var parentID: String?
        /// Nutzerkennung des Verfassers beim Dienst (Ersteller des Datensatzes)
        public var author: String
        public var status: Status
        public var createdAt: String
        public var editedAt: String?
        public var body: Body?
        /// feinere Reihenfolge bei gleicher Sekunde (Mikrosekunden des Geraets, wie `rowid` im Dienst)
        public var order: Int

        public init(id: String, parentID: String? = nil, author: String, status: Status = .active, createdAt: String,
                    editedAt: String? = nil, body: Body? = nil, order: Int = 0) {
            self.id = id
            self.parentID = parentID
            self.author = author
            self.status = status
            self.createdAt = createdAt
            self.editedAt = editedAt
            self.body = body
            self.order = order
        }
    }

    /// Kommentare in Reihenfolge wie `comments()` im Dienst: aelteste zuerst, Antworten direkt unter ihrem Kommentar
    /// (eine Ebene); ohne ausgeblendete, ohne unlesbare und ohne Kommentare gesperrter Nutzer. Geloeschte mit Antworten
    /// bleiben als "Kommentar gelöscht" stehen, geloeschte Antworten fallen weg.
    public static func thread(_ entries: [Entry], me: String, solutionAuthor: String, blocked: Set<String> = []) -> [CommunityComment] {
        let rows = entries
            .filter { $0.status != .hidden && !blocked.contains($0.author) && ($0.status != .active || $0.body != nil) }
            .sorted { ($0.createdAt, $0.order, $0.id) < ($1.createdAt, $1.order, $1.id) }
        let hasReply = Set(rows.compactMap { $0.status == .active ? $0.parentID : nil })
        func out(_ e: Entry) -> CommunityComment { comment(e, me: me, solutionAuthor: solutionAuthor) }
        var result: [CommunityComment] = []
        for top in rows where top.parentID == nil && (top.status == .active || hasReply.contains(top.id)) {
            result.append(out(top))
            result += rows.filter { $0.parentID == top.id && $0.status == .active }.map(out)
        }
        return result
    }

    /// Ein Eintrag fuer die Oberflaeche (`_comment_out`): geloeschte ohne Text und Stelle, ohne Pseudonym "Anonym"
    public static func comment(_ e: Entry, me: String, solutionAuthor: String) -> CommunityComment {
        let deleted = e.status == .deleted
        let name = e.body.map { $0.pseudonym.isEmpty ? anonymousName : $0.pseudonym } ?? anonymousName
        return CommunityComment(id: e.id, parentID: e.parentID, pseudonym: name, pageKey: deleted ? nil : e.body?.pageKey,
                                anchor: deleted ? nil : e.body?.anchor, text: deleted ? "" : (e.body?.text ?? ""), deleted: deleted,
                                createdAt: e.createdAt, edited: !deleted && !(e.editedAt ?? "").isEmpty,
                                isMine: !me.isEmpty && e.author == me, byAuthor: !solutionAuthor.isEmpty && e.author == solutionAuthor)
    }

    /// Zahl der aktiven Kommentare einer Loesung fuer die Trefferliste (wie `_summary`: aktive, auch Antworten)
    public static func activeCount(_ entries: [Entry], blocked: Set<String> = []) -> Int {
        entries.filter { $0.status == .active && !blocked.contains($0.author) }.count
    }

    /// Likes einer Loesung: ein Like je Nutzer (verschiedene Ersteller), nie der Autor selbst
    public static func likeCount(likers: [String], solutionAuthor: String, blocked: Set<String> = []) -> Int {
        Set(likers.filter { !$0.isEmpty && $0 != solutionAuthor && !blocked.contains($0) }).count
    }
}

// MARK: - Fragen und Antworten einer Community (03.11.2026)

// Reiter "Diskussion" einer Modul-Community: dieselben verschluesselten `Comment`-Datensaetze wie bei einer Loesung,
// nur mit einem Pseudo-Ziel je Community (`spaceTarget`, im Feld `solutionID`). Oberste Eintraege sind Fragen, Antworten
// haengen eine Ebene darunter (`thread`). Likes auf Fragen sind `Like`-Datensaetze mit `postLikeTarget` als Ziel – keine
// neuen Datensatztypen und keine neuen Felder beim Dienst.
extension CommunityDiscussion {
    static let spacePrefix = "space:"
    static let postLikePrefix = "post:"

    /// Ziel der Fragen einer Community (`solutionID` der Kommentar-Datensaetze, auch HKDF-Info und Zusatzdaten)
    public static func spaceTarget(_ communityKey: String) -> String { spacePrefix + communityKey.lowercased() }

    /// Community-Schluessel aus einem Ziel; nil = Ziel ist eine Loesung
    public static func spaceKey(target: String) -> String? {
        let t = target.lowercased()
        guard t.hasPrefix(spacePrefix) else { return nil }
        let key = String(t.dropFirst(spacePrefix.count))
        return key.isEmpty ? nil : key
    }

    /// Ziel eines Likes auf eine Frage (`solutionID` des `Like`-Datensatzes); nie gleich einer Loesungs-ID
    public static func postLikeTarget(_ postID: String) -> String { postLikePrefix + postID.lowercased() }

    public static func postID(likeTarget: String) -> String? {
        let t = likeTarget.lowercased()
        guard t.hasPrefix(postLikePrefix) else { return nil }
        let id = String(t.dropFirst(postLikePrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Fragen mit ihren Antworten (Reihenfolge wie `thread`: aelteste zuerst) und Likes je Frage (`likers`: Ersteller
    /// der Likes je Fragen-ID). Ein Like je Nutzer, nie der Fragesteller selbst, ohne gesperrte Nutzer.
    public static func feed(_ entries: [Entry], likers: [String: [String]], me: String, blocked: Set<String> = []) -> [CommunityPost] {
        let authors = Dictionary(entries.map { ($0.id, $0.author) }, uniquingKeysWith: { a, _ in a })
        var posts: [CommunityPost] = []
        for c in thread(entries, me: me, solutionAuthor: "", blocked: blocked) {
            if let parent = c.parentID {
                if let i = posts.indices.last, posts[i].id == parent { posts[i].replies.append(c) }
                continue
            }
            let l = likers[c.id] ?? []
            posts.append(CommunityPost(question: c, replies: [],
                                       likes: c.deleted ? 0 : likeCount(likers: l, solutionAuthor: authors[c.id] ?? "", blocked: blocked),
                                       likedByMe: !me.isEmpty && l.contains(me)))
        }
        return posts
    }

    /// Filter des Reiters: neueste zuerst; "Unbeantwortet" nur Fragen ohne Antwort (geloeschte Fragen fallen weg)
    public static func filtered(_ posts: [CommunityPost], _ filter: CommunityPostFilter) -> [CommunityPost] {
        let newest = posts.sorted { ($0.question.createdAt, $0.id) > ($1.question.createdAt, $1.id) }
        switch filter {
        case .newest: return newest
        case .unanswered: return newest.filter { !$0.answered && !$0.question.deleted }
        }
    }
}

/// Filter der Fragen einer Community
public enum CommunityPostFilter: String, CaseIterable, Sendable {
    case newest, unanswered

    public var title: String { self == .newest ? "Neueste" : "Unbeantwortet" }
}

/// Frage einer Community mit Antworten (eine Ebene) und Likes
public struct CommunityPost: Equatable, Sendable, Identifiable {
    public var question: CommunityComment
    public var replies: [CommunityComment]
    public var likes: Int
    public var likedByMe: Bool

    public var id: String { question.id }
    /// mindestens eine (nicht geloeschte) Antwort
    public var answered: Bool { replies.contains { !$0.deleted } }

    public init(question: CommunityComment, replies: [CommunityComment] = [], likes: Int = 0, likedByMe: Bool = false) {
        self.question = question
        self.replies = replies
        self.likes = likes
        self.likedByMe = likedByMe
    }
}
