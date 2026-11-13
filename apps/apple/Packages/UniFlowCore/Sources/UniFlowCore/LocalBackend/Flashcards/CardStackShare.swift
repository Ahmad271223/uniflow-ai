import Foundation

// Geteilte Karteikarten-Stapel (Entscheidung des Inhabers vom 04.11.2026, "Einmal erzeugen, alle profitieren",
// docs/KARTEIKARTEN-STAPEL-2026-11-04.md), reine Funktionen wie app/cardshare.py und app/community_cards.py:
//
// 1. Geteilte Wochenstapel: je Modul und Lehrwoche zwei erzeugte Stapel, Art `vorlesung` (Vorlesungsunterlagen der
//    Woche) und `uebung` (Uebungsblaetter der Woche), EINMAL je Schluessel erzeugt und geteilt. Der Schluessel haengt
//    wie bei den Wochentests nur an Hochschule, Art und den Inhalts-Hashes der Dateien; Varianten, Platz belegen und
//    uebernehmen statt erzeugen laufen ueber dieselbe Maschine (`WeeklyTestShare.obtain` mit einem zweiten Dienst
//    `LocalContext.cardShare`, Datensatz `WeekCardStack` bei CloudKit). Der Inhalt beim Dienst ist ein
//    `SharedWeeklyTest` mit `title` = Art und `questions` = Karten (`WeeklyTestCrypto`, Schluessel aus den Inhalts-Hashes).
// 2. Eigene Stapel teilen: je Stapel eine Kopie der Karten in der Modul-Community (`CommunityKeys.moduleKey`), Inhalt
//    verschluesselt mit dem Modul-Geheimnis (`CardStackCrypto`), Autor als Pseudonym; andere uebernehmen, liken, melden.
//    Die App setzt dafuer `CardStackCommunityProvider` (CloudKit); der Dienst (Python) kennt dieselben Endpunkte.
public enum CardStackShare {
    public static let version = "cs1"
    /// Arten der erzeugten Wochenstapel und die Dokumentarten, aus denen sie entstehen (`cardshare.WEEK_DOC_TYPES`)
    public static let kinds = ["vorlesung", "uebung"]
    public static let weekDocTypes: [String: [String]] = ["vorlesung": ["vorlesung", "skript"], "uebung": ["uebung", "loesung"]]
    /// so viele Karten verlangt ein Wochenstapel von der KI (Deckel je Satz: `AIPrompts.flashcardsMax` = 30)
    public static let weekCards = 20
    public static let weekFilesMax = 10
    public static let weekTextChars = 3500
    public static let maxVariants = TestShare.maxVariants
    /// Herkunft eines uebernommenen Stapels (`flashcard_stacks.source`)
    public static let sourceWeek = "week", sourceCommunity = "community"

    /// `cardshare.stack_name`: "Vorlesung Woche 5" / "Übung Woche 5"
    public static func stackName(kind: String, week: Int) -> String {
        (kind == "vorlesung" ? "Vorlesung" : "Übung") + " Woche \(week)"
    }

    /// `cardshare.week_key`: Schluessel oder nil, wenn eine Datei keinen Inhalts-Hash hat oder die Art unbekannt ist.
    /// Kanonisch wie `json.dumps({"kind", "materials", "uni", "v"}, sort_keys=True, separators=(",", ":"))`.
    public static func weekKey(university: String, kind: String, contentHashes: [String?]) -> String? {
        guard kinds.contains(kind), !contentHashes.isEmpty, contentHashes.allSatisfy({ $0 != nil && !$0!.isEmpty }) else { return nil }
        let prints = Set(contentHashes.compactMap { $0 }).sorted()
        let canon = "{\"kind\":\"\(kind)\",\"materials\":[" + prints.map { "\"\($0)\"" }.joined(separator: ",") + "],\"uni\":\""
            + TestShare.jsonEscape(university) + "\",\"v\":\"\(version)\"}"
        return "\(version):" + SolutionSHA256.hex(Data(canon.utf8))
    }

    /// Eine Datei der Woche fuer den Prompt
    public struct WeekFile: Equatable, Sendable {
        public var name: String
        public var text: String
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    /// `cardshare.week_text`: je Datei eine Ueberschrift und der Textauszug (hoechstens `weekTextChars` Zeichen)
    public static func weekText(_ files: [WeekFile]) -> String {
        files.map { "### Datei: \($0.name)\n" + PyText.slice(PyText.strip($0.text), 0, weekTextChars) }.joined(separator: "\n\n")
    }

    /// `cardshare.prompt`: der Karteikarten-Prompt mit dem Modul als Kurs, dem Stapelnamen als Datei und dem Text
    /// aller Dateien der Woche (byte-gleich mit Python, Fixture cardshare/cases.json)
    public static func prompt(module: String, kind: String, week: Int, files: [WeekFile]) -> String {
        AIPrompts.flashcards(course: module, fileName: stackName(kind: kind, week: week), pages: [], text: weekText(files), count: weekCards)
    }

    /// `cardshare.canonical_cards`: Klartext eines geteilten Stapels, nur Frage und Antwort, sortierte Schluessel,
    /// `{"cards":[{"answer":"…","question":"…"}]}` ohne Leerzeichen, Zeichen ausserhalb von ASCII bleiben stehen
    public static func canonicalCards(_ cards: [AIAnswers.Flashcard]) -> String {
        var out = "{\"cards\":["
        for (i, c) in cards.enumerated() {
            if i > 0 { out += "," }
            out += "{\"answer\":"
            PyJSON.writeString(c.answer, ascii: false, into: &out)
            out += ",\"question\":"
            PyJSON.writeString(c.question, ascii: false, into: &out)
            out += "}"
        }
        return out + "]}"
    }

    /// Karten aus dem Klartext (`canonicalCards` oder `{"cards": [...]}` in anderer Form); leer, wenn keine Karte
    /// Frage und Antwort hat
    public static func parseCards(_ plaintext: Data) throws -> [AIAnswers.Flashcard] {
        AIAnswers.checkFlashcards(try PyJSON.parse(plaintext), quality: false)
    }

    // MARK: Wochenstapel beim Dienst (Abbild als SharedWeeklyTest)

    /// Inhalt eines Wochenstapels fuer den Varianten-Dienst: `title` = Art (Pruefwert), `questions` = Karten
    public static func poolTest(kind: String, cards: [AIAnswers.Flashcard]) -> SharedWeeklyTest {
        SharedWeeklyTest(title: kind, questions: .array(cards.map { .object([.init("question", .string($0.question)), .init("answer", .string($0.answer))]) }))
    }

    /// Karten aus einem uebernommenen Wochenstapel; leer, wenn die Art nicht passt oder keine Karte brauchbar ist
    public static func cards(from test: SharedWeeklyTest, kind: String) -> [AIAnswers.Flashcard] {
        guard test.title == kind else { return [] }
        return AIAnswers.checkFlashcards(test.questions, quality: false)
    }
}

// MARK: - Eigene Stapel in der Modul-Community

/// Ein geteilter Stapel, wie ihn der Dienst auflistet (Kopfdaten ohne Karten; `cardshare`-Antwort `GET /api/community/card-stacks`)
public struct SharedCardStackSummary: Equatable, Sendable {
    public var id: String
    public var communityKey: String
    public var name: String
    public var kind: String
    /// nil = Allgemein
    public var week: Int?
    public var cardCount: Int
    public var pseudonym: String
    public var createdAt: String
    public var likes: Int
    public var likedByMe: Bool
    public var isOwn: Bool
    public var reportedByMe: Bool

    public init(id: String, communityKey: String, name: String, kind: String, week: Int?, cardCount: Int, pseudonym: String,
                createdAt: String, likes: Int = 0, likedByMe: Bool = false, isOwn: Bool = false, reportedByMe: Bool = false) {
        self.id = id
        self.communityKey = communityKey
        self.name = name
        self.kind = kind
        self.week = week
        self.cardCount = cardCount
        self.pseudonym = pseudonym
        self.createdAt = createdAt
        self.likes = likes
        self.likedByMe = likedByMe
        self.isOwn = isOwn
        self.reportedByMe = reportedByMe
    }

    /// Antwort wie der Python-Dienst (`community_cards._summary`); `adopted` setzt der Endpunkt aus der lokalen Datenbank
    public func json(adopted: Bool) -> JSONValue {
        ["id": .string(id), "community_key": .string(communityKey), "name": .string(name), "kind": .string(kind),
         "week": week.map { .number(Double($0)) } ?? .null, "cards": .number(Double(cardCount)), "pseudonym": .string(pseudonym),
         "created_at": .string(createdAt), "status": "active", "mine": .bool(isOwn), "reported_by_me": .bool(reportedByMe),
         "adopted": .bool(adopted), "adopt_count": 0, "likes": .number(Double(likes)), "liked_by_me": .bool(likedByMe)]
    }
}

/// Was ein eigener Stapel beim Teilen mitbringt (die Karten verschluesselt der Dienst mit `secret`)
public struct CardStackDraft: Equatable, Sendable {
    public var communityKey: String
    public var name: String
    public var kind: String
    public var week: Int?
    public var cards: [AIAnswers.Flashcard]

    public init(communityKey: String, name: String, kind: String, week: Int?, cards: [AIAnswers.Flashcard]) {
        self.communityKey = communityKey
        self.name = name
        self.kind = kind
        self.week = week
        self.cards = cards
    }
}

/// Dienst fuer geteilte Stapel (CloudKit in der App; Python-Dienst fuer Web und Windows). Alle Aufrufe duerfen werfen
/// (offline, nicht angemeldet); die Endpunkte melden das als 503. `secret` ist das Modul-Geheimnis
/// (`CommunityKeys.secret(university:moduleName:)`), es bleibt auf dem Geraet.
public protocol CardStackCommunityProvider: Sendable {
    /// Nutzerkennung; nil = nicht angemeldet (Lesen geht trotzdem)
    func userID() async throws -> String?
    /// Kopie veroeffentlichen (Pseudonym waehlt der Dienst); liefert die Kennung des geteilten Stapels
    func publish(_ draft: CardStackDraft, secret: Data) async throws -> String
    /// Zurueckziehen (nur der eigene)
    func withdraw(id: String) async throws
    /// Geteilte Stapel eines Moduls (ohne zurueckgezogene, gesperrte und gebannte)
    func list(communityKey: String) async throws -> [SharedCardStackSummary]
    /// Kopfdaten eines geteilten Stapels; nil, wenn es ihn nicht (mehr) gibt
    func summary(id: String) async throws -> SharedCardStackSummary?
    /// Karten eines geteilten Stapels (entschluesselt mit dem Modul-Geheimnis)
    func cards(id: String, communityKey: String, secret: Data) async throws -> [AIAnswers.Flashcard]
    /// Gefaellt mir setzen oder entfernen; liefert die Zahl der Likes
    func like(id: String, on: Bool) async throws -> Int
    func report(id: String, reason: String, note: String?) async throws
}

/// Halter des Dienstes im `LocalContext` (wie `LocalTestShare`), von der App gesetzt
public final class LocalCardCommunity: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CardStackCommunityProvider?

    public init() {}

    public var provider: CardStackCommunityProvider? { lock.withLock { current } }

    public func set(_ provider: CardStackCommunityProvider?) { lock.withLock { current = provider } }
}

/// Verschluesselung eines geteilten Stapels beim Dienst (CloudKit `CardStackShare.payload`): Schluessel per HKDF-SHA256
/// aus dem Modul-Geheimnis (`CommunityKeys.secret(university:moduleName:)`) mit Salz je Datensatz, AES-256-GCM ueber
/// `SolutionCipher`; Zusatzdaten binden das Chiffrat an Community-Schluessel und Kennung (kein Umhaengen).
public enum CardStackCrypto {
    static let format = "uniflow-card-stack"
    static let payloadVersion: UInt8 = 1
    static let saltBytes = 32, nonceBytes = 12, tagBytes = 16
    public static let maxPayloadChars = 2 * 1024 * 1024

    static func keyInfo(id: String) -> Data { Data("\(format)/v\(payloadVersion)|\(id.lowercased())".utf8) }
    static func aad(communityKey: String, id: String) -> Data { Data("\(format)/v\(payloadVersion)|\(communityKey)|\(id.lowercased())".utf8) }

    /// Klartext: `canonicalCards` der Karten
    public static func seal(_ cards: [AIAnswers.Flashcard], secret: Data, communityKey: String, id: String, cipher: SolutionCipher,
                            salt: Data? = nil, nonce: Data? = nil) throws -> String {
        let salt = salt ?? SolutionPackage.randomBytes(saltBytes), nonce = nonce ?? SolutionPackage.randomBytes(nonceBytes)
        guard salt.count == saltBytes, nonce.count == nonceBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        let plaintext = Data(CardStackShare.canonicalCards(cards).utf8)
        let sealed = try cipher.seal(plaintext, keyMaterial: secret, salt: salt, info: keyInfo(id: id), nonce: nonce,
                                     aad: aad(communityKey: communityKey, id: id))
        guard sealed.count == plaintext.count + tagBytes else { throw SolutionError.invalidContent("Verschlüsselung") }
        return (Data([payloadVersion]) + salt + nonce + sealed).base64EncodedString()
    }

    /// Karten entschluesseln; falsches Geheimnis (anderes Modul), veraendertes oder umgehaengtes Chiffrat werfen
    public static func open(_ payload: String, secret: Data, communityKey: String, id: String, cipher: SolutionCipher) throws -> [AIAnswers.Flashcard] {
        guard payload.count <= maxPayloadChars, let raw = Data(base64Encoded: payload),
              raw.count > 1 + saltBytes + nonceBytes + tagBytes, raw[raw.startIndex] == payloadVersion else {
            throw SolutionError.decryptionFailed
        }
        let salt = raw.subdata(in: 1..<(1 + saltBytes)), nonce = raw.subdata(in: (1 + saltBytes)..<(1 + saltBytes + nonceBytes))
        let sealed = raw.subdata(in: (1 + saltBytes + nonceBytes)..<raw.count)
        let plaintext: Data
        do {
            plaintext = try cipher.open(sealed, keyMaterial: secret, salt: salt, info: keyInfo(id: id), nonce: nonce,
                                        aad: aad(communityKey: communityKey, id: id))
        } catch {
            throw SolutionError.decryptionFailed
        }
        let cards = try CardStackShare.parseCards(plaintext)
        guard !cards.isEmpty else { throw SolutionError.decryptionFailed }
        return cards
    }
}
