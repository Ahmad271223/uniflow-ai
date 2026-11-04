import Foundation
import UniFlowCore

// Geteilte Karteikarten-Stapel ohne eigenen Server (iPad V1, Entscheidung des Inhabers vom 04.11.2026,
// docs/KARTEIKARTEN-STAPEL-2026-11-04.md), ueber die oeffentliche CloudKit-Datenbank mit demselben Zugang wie die
// Community (`CommunityCloud`). Was geteilt, geschluesselt und gewaehlt wird, entscheidet der Kern
// (`CardStackShare`, `CardStackEndpoints`, `WeeklyTestShare.obtain`).
//
// Datensatz `WeekCardStack` (oeffentlich): geteilte Wochenstapel, erzeugt EINMAL je Modul, Woche und Art fuer alle mit
// denselben Dateien - dieselben Felder und Regeln wie `WeeklyTest` (WeeklyTestCloudKit.swift, `CloudKitWeeklyTestShare`
// mit `recordType`):
//   recordName       "<shareKey>#<variant>"  -> Anlegen atomar und je Variante eindeutig (Wettlauf: nur einer gewinnt)
//   shareKey         String (Queryable)       `CardStackShare.weekKey` aus Hochschule, Art und Inhalts-Hashes ("cs1:…")
//   variant          Int(64)                  0..2 (hoechstens drei je Schluessel)
//   status           String                   pending (belegt, Inhalt kommt) | ready
//   payload          String                   Karten verschluesselt (`WeeklyTestCrypto`: HKDF aus den Inhalts-Hashes, AES-256-GCM);
//                                             Klartext = SharedWeeklyTest mit title = Art, questions = Karten; leer bei pending
//   createdAt        String                   Zeitpunkt der Belegung (ISO 8601, UTC)
//   ownerRecordName  String                   CloudKit-Nutzerkennung des Erzeugers (nur Anzeige im Dashboard)
// Rechte wie `WeeklyTest`: Lesen fuer alle, Erstellen fuer angemeldete Nutzer, Aendern/Loeschen nur fuer den Ersteller.
//
// Datensatz `CardStackShare` (oeffentlich): eigene Stapel in der Modul-Community ("Stapel teilen"):
//   recordName       UUID (klein)             Kennung des geteilten Stapels (`flashcard_stacks.shared_id` beim Autor,
//                                             `source_ref` bei allen, die ihn uebernommen haben)
//   communityKey     String (Queryable)       Modul-Schluessel (`CommunityKeys.moduleKey`), nie der Modulname
//   kind             String                   vorlesung | uebung | eigene
//   week             Int(64)                  Lehrwoche, 0 = Allgemein
//   name             String                   Name des Stapels
//   cardCount        Int(64)                  Zahl der Karten
//   displayName      String                   Pseudonym (leer = anonym), wie bei Loesungen
//   payload          String                   Karten verschluesselt (`CardStackCrypto`: HKDF aus dem Modul-Geheimnis
//                                             `CommunityKeys.secret(university:moduleName:)`, AES-256-GCM, Zusatzdaten
//                                             binden an communityKey und Kennung); leer nach dem Zurueckziehen
//   createdAt        String                   ISO 8601, UTC
//   ownerRecordName  String                   CloudKit-Nutzerkennung des Autors (Zurueckziehen, Sperren)
//   withdrawn        Int(64)                  1 = zurueckgezogen (die App filtert sofort)
// Rechte wie `Solution`: Lesen fuer alle, Erstellen fuer angemeldete Nutzer, Aendern nur fuer den Ersteller; Moderation
// im Dashboard (`withdrawn` = 1 und `payload` leeren, `Ban` des Autors). Likes und Meldungen brauchen keinen neuen Typ:
// `Like` und `Report` mit `solutionID = "cards:<Kennung>"` (wie Fragen mit `post:<ID>`).
// Keine Namen, keine E-Mail, kein Modulname, kein Lernstand. Lesen kann nur, wer das Modul kennt (Geheimnis aus dem
// Modulnamen, wie Community-Pakete) - der Modulname ist kein Geheimnis vor dem Dienst, die Sichtbarkeit regelt die App.

enum CardStackShareRecord {
    static let type = "CardStackShare"
    /// Wochenstapel: Felder wie `WeeklyTestRecord.Field`
    static let weekType = "WeekCardStack"
    enum Field {
        static let communityKey = "communityKey", kind = "kind", week = "week", name = "name", cardCount = "cardCount"
        static let displayName = "displayName", payload = "payload", createdAt = "createdAt", owner = "ownerRecordName", withdrawn = "withdrawn"
        /// `Like`/`Report`: Ziel und Felder wie in der Community
        static let solutionID = "solutionID", reason = "reason", note = "note", reporter = "reporterRecordName"
    }
    /// hoechstens so viele geteilte Stapel je Modul in einer Abfrage
    static let listLimit = 400
    static let maxNote = 500

    /// Ziel eines Likes bzw. einer Meldung zu einem geteilten Stapel
    static func likeTarget(_ id: String) -> String { "cards:" + id.lowercased() }
}

/// `CardStackCommunityProvider` ueber CloudKit. Lesen geht ohne iCloud-Konto; Teilen, Zurueckziehen, Liken und Melden
/// brauchen es. Jeder Fehler des Dienstes geht als Fehler nach oben (der Kern antwortet 503).
final class CloudKitCardStackCommunity: CardStackCommunityProvider, @unchecked Sendable {
    let cloud: CommunityCloud
    let cipher: SolutionCipher
    /// Pseudonym des Nutzers (leer = anonym), je Container wie bei Loesungen
    let pseudonym: @Sendable () -> String
    /// eigene Sperrliste (Nutzerkennungen), deren Stapel nie angezeigt werden
    let blocked: @Sendable () -> Set<String>
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedUser: String?

    init(cloud: CommunityCloud, cipher: SolutionCipher = SolutionSharing.cipher, pseudonym: @escaping @Sendable () -> String = { "" },
         blocked: @escaping @Sendable () -> Set<String> = { [] }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.cipher = cipher
        self.pseudonym = pseudonym
        self.blocked = blocked
        self.now = now
    }

    func userID() async throws -> String? {
        guard try await cloud.accountStatus() == .available else { return nil }
        if let u = lock.withLock({ cachedUser }) { return u }
        let u = try await cloud.userRecordName()
        lock.withLock { cachedUser = u }
        return u
    }

    private func me() async throws -> String {
        guard let u = try await userID() else { throw CommunityCloudError.notSignedIn }
        return u
    }

    /// Besitzer wie in der Community: der Ersteller, den der Dienst setzt (eigene = `__defaultOwner__`)
    static func owner(_ r: CommunityRecord, me: String) -> String { CloudKitCommunityService.owner(r, me: me) }

    /// Kopfdaten aus einem Datensatz; nil bei fremder Form oder zurueckgezogen
    static func summary(_ r: CommunityRecord, me: String, likes: [String] = []) -> SharedCardStackSummary? {
        guard r.type == CardStackShareRecord.type, let key = r[CardStackShareRecord.Field.communityKey]?.string, !key.isEmpty,
              (r[CardStackShareRecord.Field.withdrawn]?.int ?? 0) == 0 else { return nil }
        let week = r[CardStackShareRecord.Field.week]?.int ?? 0
        let owner = owner(r, me: me)
        let display = r[CardStackShareRecord.Field.displayName]?.string ?? ""
        return SharedCardStackSummary(id: r.name.lowercased(), communityKey: key, name: r[CardStackShareRecord.Field.name]?.string ?? "",
                                      kind: r[CardStackShareRecord.Field.kind]?.string ?? "eigene", week: week > 0 ? week : nil,
                                      cardCount: r[CardStackShareRecord.Field.cardCount]?.int ?? 0,
                                      pseudonym: display.isEmpty ? "Anonym" : display, createdAt: r[CardStackShareRecord.Field.createdAt]?.string ?? "",
                                      likes: likes.filter { $0 != owner }.count, likedByMe: !me.isEmpty && likes.contains(me),
                                      isOwn: !me.isEmpty && owner == me)
    }

    private func ownerName() async -> String {
        if let u = lock.withLock({ cachedUser }) { return u }
        guard let u = try? await cloud.userRecordName() else { return "" }
        lock.withLock { cachedUser = u }
        return u
    }

    private func banned() async -> Set<String> {
        guard let records = try? await cloud.query(CommunityQuery(type: CommunityRecordType.ban, equals: [:]), in: .publicDB) else { return [] }
        return Set(records.compactMap { $0[CardStackShareRecord.Field.owner]?.string }.filter { !$0.isEmpty })
    }

    // MARK: CardStackCommunityProvider

    func publish(_ draft: CardStackDraft, secret: Data) async throws -> String {
        let user = try await me()
        let id = UUID().uuidString.lowercased()
        var r = CommunityRecord(type: CardStackShareRecord.type, name: id)
        r[CardStackShareRecord.Field.communityKey] = .string(draft.communityKey)
        r[CardStackShareRecord.Field.kind] = .string(draft.kind)
        r[CardStackShareRecord.Field.week] = .int(draft.week ?? 0)
        r[CardStackShareRecord.Field.name] = .string(String(draft.name.prefix(120)))
        r[CardStackShareRecord.Field.cardCount] = .int(draft.cards.count)
        r[CardStackShareRecord.Field.displayName] = .string(pseudonym().trimmingCharacters(in: .whitespacesAndNewlines))
        r[CardStackShareRecord.Field.payload] = .string(try CardStackCrypto.seal(draft.cards, secret: secret, communityKey: draft.communityKey, id: id, cipher: cipher))
        r[CardStackShareRecord.Field.createdAt] = .string(CloudKitWeeklyTestShare.timestamp(now()))
        r[CardStackShareRecord.Field.owner] = .string(user)
        r[CardStackShareRecord.Field.withdrawn] = .int(0)
        _ = try await cloud.save(r, in: .publicDB)
        return id
    }

    func withdraw(id: String) async throws {
        let user = try await me()
        guard var r = try await cloud.fetch(name: id.lowercased(), type: CardStackShareRecord.type, in: .publicDB) else { throw CommunityCloudError.notFound }
        guard Self.owner(r, me: user) == user else { throw CommunityCloudError.permission }
        r[CardStackShareRecord.Field.withdrawn] = .int(1)
        r[CardStackShareRecord.Field.payload] = .string("")
        _ = try await cloud.save(r, in: .publicDB)
    }

    func list(communityKey: String) async throws -> [SharedCardStackSummary] {
        let records = try await cloud.query(CommunityQuery(type: CardStackShareRecord.type,
                                                           equals: [CardStackShareRecord.Field.communityKey: .string(communityKey)],
                                                           limit: CardStackShareRecord.listLimit), in: .publicDB)
        let me = await ownerName()
        let hidden = blocked().union(await banned())
        let visible = records.filter { !hidden.contains(Self.owner($0, me: me)) }
        let likes = await likers(for: visible.map { CardStackShareRecord.likeTarget($0.name) }, me: me)
        return visible.compactMap { Self.summary($0, me: me, likes: likes[CardStackShareRecord.likeTarget($0.name)] ?? []) }
            .sorted { ($0.likes, $0.createdAt) > ($1.likes, $1.createdAt) }
    }

    /// Nutzerkennungen der Likes je Ziel (Beiwerk: scheitert die Abfrage, bleiben sie leer)
    private func likers(for targets: [String], me: String) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        var start = 0
        while start < targets.count {
            let chunk = Array(targets[start..<min(start + 50, targets.count)])
            start += chunk.count
            guard let records = try? await cloud.query(CommunityQuery(type: CommunityRecordType.like, equals: [:], limit: 2000,
                                                                      anyOf: [CardStackShareRecord.Field.solutionID: chunk]), in: .publicDB) else { continue }
            for r in records {
                if let t = r[CardStackShareRecord.Field.solutionID]?.string { out[t, default: []].append(Self.owner(r, me: me)) }
            }
        }
        return out
    }

    func summary(id: String) async throws -> SharedCardStackSummary? {
        guard let r = try await cloud.fetch(name: id.lowercased(), type: CardStackShareRecord.type, in: .publicDB) else { return nil }
        let me = await ownerName()
        let hidden = blocked().union(await banned())
        guard !hidden.contains(Self.owner(r, me: me)) else { return nil }
        let likes = await likers(for: [CardStackShareRecord.likeTarget(r.name)], me: me)
        return Self.summary(r, me: me, likes: likes[CardStackShareRecord.likeTarget(r.name)] ?? [])
    }

    func cards(id: String, communityKey: String, secret: Data) async throws -> [AIAnswers.Flashcard] {
        guard let r = try await cloud.fetch(name: id.lowercased(), type: CardStackShareRecord.type, in: .publicDB),
              r[CardStackShareRecord.Field.communityKey]?.string == communityKey, (r[CardStackShareRecord.Field.withdrawn]?.int ?? 0) == 0,
              let payload = r[CardStackShareRecord.Field.payload]?.string, !payload.isEmpty else { throw CommunityCloudError.notFound }
        return try CardStackCrypto.open(payload, secret: secret, communityKey: communityKey, id: id, cipher: cipher)
    }

    func like(id: String, on: Bool) async throws -> Int {
        let user = try await me()
        let target = CardStackShareRecord.likeTarget(id)
        let records = try await cloud.query(CommunityQuery(type: CommunityRecordType.like, equals: [CardStackShareRecord.Field.solutionID: .string(target)],
                                                           limit: 2000), in: .publicDB)
        let mine = records.filter { Self.owner($0, me: user) == user }
        let others = records.map { Self.owner($0, me: user) }.filter { $0 != user }
        if on, mine.isEmpty {
            var r = CommunityRecord(type: CommunityRecordType.like, name: "like-" + UUID().uuidString.lowercased())
            r[CardStackShareRecord.Field.solutionID] = .string(target)
            r[CardStackShareRecord.Field.owner] = .string(user)
            r[CardStackShareRecord.Field.createdAt] = .string(CloudKitWeeklyTestShare.timestamp(now()))
            _ = try await cloud.save(r, in: .publicDB)
        } else if !on {
            for r in mine { try await cloud.delete(name: r.name, type: CommunityRecordType.like, in: .publicDB) }
        }
        return Set(others).count + (on ? 1 : 0)
    }

    func report(id: String, reason: String, note: String?) async throws {
        let user = try await me()
        var r = CommunityRecord(type: CommunityRecordType.report, name: "report-" + UUID().uuidString.lowercased())
        r[CardStackShareRecord.Field.solutionID] = .string(CardStackShareRecord.likeTarget(id))
        r[CardStackShareRecord.Field.reason] = .string(reason)
        r[CardStackShareRecord.Field.note] = .string(String((note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(CardStackShareRecord.maxNote)))
        r[CardStackShareRecord.Field.reporter] = .string(user)
        r[CardStackShareRecord.Field.createdAt] = .string(CloudKitWeeklyTestShare.timestamp(now()))
        _ = try await cloud.save(r, in: .publicDB)
    }
}

enum CardStackCloudFactory {
    /// Varianten-Dienst der Wochenstapel (`WeekCardStack`); nil ohne iCloud-Container (Simulator, CI, Personal Team):
    /// dann entsteht ein eigener Stapel mit der KI des Nutzers
    static func makeWeek() -> WeeklyTestShareProvider? {
        guard let cloud = CommunityCloudFactory.make() else { return nil }
        return CloudKitWeeklyTestShare(cloud: cloud, recordType: CardStackShareRecord.weekType)
    }

    /// Modul-Community fuer eigene Stapel (`CardStackShare`); nil ohne Container: "Stapel teilen" ist dann nicht verfuegbar.
    /// Pseudonym und Sperrliste kommen vom aktiven Container (wie bei Loesungen).
    static func makeCommunity() -> CardStackCommunityProvider? {
        guard let cloud = CommunityCloudFactory.make() else { return nil }
        return CloudKitCardStackCommunity(cloud: cloud, pseudonym: { SolutionDisplayName.load() },
                                          blocked: { ActiveContainer.current?.membership.blocked() ?? [] })
    }
}
