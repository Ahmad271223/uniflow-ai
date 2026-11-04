import Foundation
import UniFlowCore

// Gemeinsame Wochentests ohne eigenen Server (iPad V1, docs/GEMEINSAME-WOCHENTESTS.md, Regel des Inhabers vom
// 04.11.2026): hoechstens drei Tests je Schluessel fuer alle, die dieselben Dateien haben. Der Austausch laeuft ueber
// die oeffentliche CloudKit-Datenbank mit demselben Zugang wie die Community (`CommunityCloud`); den Ablauf (eigene
// Variante uebernehmen, warten, belegen, erzeugen, veroeffentlichen) entscheidet der Kern (`WeeklyTestShare.obtain`).
//
// Datensatz `WeeklyTest` (oeffentlich, docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md):
//   recordName       "<shareKey>#<variant>"  -> das Anlegen ist atomar und je Variante eindeutig (Wettlauf: nur einer gewinnt)
//   shareKey         String (Queryable)       Schluessel aus Hochschule, Dauer-Stufe und Inhalts-Hashes (`TestShare.shareKey`)
//   variant          Int(64)                  0..2
//   status           String                   pending (belegt, Inhalt kommt) | ready
//   payload          String                   Test verschluesselt (`WeeklyTestCrypto`, Base64); leer bei pending
//   createdAt        String                   Zeitpunkt der Belegung (ISO 8601, UTC)
//   ownerRecordName  String                   CloudKit-Nutzerkennung des Erzeugers (nur Anzeige im Dashboard)
// Keine Namen, keine E-Mail, keine Antworten. Der Schluessel des Chiffrats entsteht per HKDF aus den Inhalts-Hashes der
// Dateien und liegt nie bei CloudKit: lesen kann nur, wer dieselben Dateien hat.

enum WeeklyTestRecord {
    static let type = "WeeklyTest"
    enum Field {
        static let shareKey = "shareKey", variant = "variant", status = "status", payload = "payload"
        static let createdAt = "createdAt", owner = "ownerRecordName"
    }
    static let pending = "pending", ready = "ready"
}

/// `WeeklyTestShareProvider` ueber CloudKit. Nur mit iCloud-Konto wird geteilt (`userID` nil sonst); jeder Fehler des
/// Dienstes laesst den Kern auf einen eigenen Test ausweichen.
final class CloudKitWeeklyTestShare: WeeklyTestShareProvider, @unchecked Sendable {
    let cloud: CommunityCloud
    let cipher: SolutionCipher
    /// Datensatztyp: `WeeklyTest` (Wochentests) oder `WeekCardStack` (geteilte Wochenstapel, CardStackCloudKit.swift) -
    /// dieselben Felder, dieselbe Varianten-Regel, derselbe Schluessel aus den Inhalts-Hashes
    let recordType: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedUser: String?

    init(cloud: CommunityCloud, cipher: SolutionCipher = SolutionSharing.cipher, recordType: String = WeeklyTestRecord.type,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.cipher = cipher
        self.recordType = recordType
        self.now = now
    }

    var sourceName: String { TestShare.adoptedCloudKit }

    /// Bei jedem Aufruf der Kontostand (Abmelden von iCloud beendet das Teilen), die Kennung danach aus dem Zwischenspeicher
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

    // MARK: Zeit

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func timestamp(_ date: Date) -> String { iso.string(from: date) }

    static func seconds(_ text: String?) -> Double? { text.flatMap { iso.date(from: $0) }?.timeIntervalSince1970 }

    // MARK: Datensaetze

    static func name(_ material: WeeklyTestMaterial, _ variant: Int) -> String { WeeklyTestCrypto.recordName(key: material.key, variant: variant) }

    /// Platz aus einem Datensatz; nil, wenn er nicht zum Schluessel passt (fremde Form)
    static func slot(_ r: CommunityRecord, material: WeeklyTestMaterial, cipher: SolutionCipher, recordType: String = WeeklyTestRecord.type) -> (Int, WeeklyTestSlot)? {
        guard r.type == recordType, r[WeeklyTestRecord.Field.shareKey]?.string == material.key,
              let v = r[WeeklyTestRecord.Field.variant]?.int, (0..<TestShare.maxVariants).contains(v),
              r.name == name(material, v) else { return nil }
        switch r[WeeklyTestRecord.Field.status]?.string {
        case WeeklyTestRecord.ready?:
            guard let payload = r[WeeklyTestRecord.Field.payload]?.string, !payload.isEmpty,
                  let test = try? WeeklyTestCrypto.open(payload, material: material, variant: v, cipher: cipher) else { return (v, .broken) }
            return (v, .ready(test))
        case WeeklyTestRecord.pending?:
            return (v, .pending(since: seconds(r[WeeklyTestRecord.Field.createdAt]?.string) ?? 0))
        default:
            return (v, .broken)
        }
    }

    func slots(_ material: WeeklyTestMaterial) async throws -> [Int: WeeklyTestSlot] {
        let records = try await cloud.query(CommunityQuery(type: recordType,
                                                           equals: [WeeklyTestRecord.Field.shareKey: .string(material.key)],
                                                           limit: TestShare.maxVariants * 2), in: .publicDB)
        var out: [Int: WeeklyTestSlot] = [:]
        for r in records {
            if let (v, s) = Self.slot(r, material: material, cipher: cipher, recordType: recordType) { out[v] = s }
        }
        return out
    }

    /// Belegen: Datensatz "<Schluessel>#<Variante>" anlegen. Gibt es ihn schon, oder gewinnt beim Wettlauf ein anderer
    /// (CloudKit lehnt das zweite Anlegen desselben Namens ab, der Nachbau behaelt den ersten), ist der Platz vergeben.
    func claim(_ material: WeeklyTestMaterial, variant: Int) async throws -> Bool {
        let user = try await me()
        let name = Self.name(material, variant)
        if try await cloud.fetch(name: name, type: recordType, in: .publicDB) != nil { return false }
        var record = CommunityRecord(type: recordType, name: name)
        record[WeeklyTestRecord.Field.shareKey] = .string(material.key)
        record[WeeklyTestRecord.Field.variant] = .int(variant)
        record[WeeklyTestRecord.Field.status] = .string(WeeklyTestRecord.pending)
        record[WeeklyTestRecord.Field.payload] = .string("")
        record[WeeklyTestRecord.Field.createdAt] = .string(Self.timestamp(now()))
        record[WeeklyTestRecord.Field.owner] = .string(user)
        do {
            _ = try await cloud.save(record, in: .publicDB)
        } catch {
            // zeitgleich von einem anderen angelegt: vergeben; sonst echter Fehler (offline, Kontingent)
            if let other = try? await cloud.fetch(name: name, type: recordType, in: .publicDB), !Self.isMine(other, me: user) { return false }
            throw error
        }
        // nur der Ersteller aendert in der oeffentlichen Datenbank: steht nach dem Speichern ein fremder Datensatz da, hat er gewonnen
        guard let stored = try await cloud.fetch(name: name, type: recordType, in: .publicDB), Self.isMine(stored, me: user) else { return false }
        return true
    }

    static func isMine(_ r: CommunityRecord, me: String) -> Bool { CloudKitCommunityService.owner(r, me: me) == me }

    func publish(_ material: WeeklyTestMaterial, variant: Int, test: SharedWeeklyTest) async throws {
        let user = try await me()
        let name = Self.name(material, variant)
        guard var record = try await cloud.fetch(name: name, type: recordType, in: .publicDB), Self.isMine(record, me: user) else {
            throw CommunityCloudError.permission
        }
        record[WeeklyTestRecord.Field.status] = .string(WeeklyTestRecord.ready)
        record[WeeklyTestRecord.Field.payload] = .string(try WeeklyTestCrypto.seal(test, material: material, variant: variant, cipher: cipher))
        _ = try await cloud.save(record, in: .publicDB)
    }

    func release(_ material: WeeklyTestMaterial, variant: Int) async throws {
        let user = try await me()
        let name = Self.name(material, variant)
        guard let record = try await cloud.fetch(name: name, type: recordType, in: .publicDB), Self.isMine(record, me: user),
              record[WeeklyTestRecord.Field.status]?.string == WeeklyTestRecord.pending else { return }
        try await cloud.delete(name: name, type: recordType, in: .publicDB)
    }
}

enum WeeklyTestShareFactory {
    /// Dienst dieses Builds; nil ohne iCloud-Container (Simulator, CI, Personal Team): dann nur die eigene Variante
    static func make() -> WeeklyTestShareProvider? {
        guard let cloud = CommunityCloudFactory.make() else { return nil }
        return CloudKitWeeklyTestShare(cloud: cloud)
    }
}
