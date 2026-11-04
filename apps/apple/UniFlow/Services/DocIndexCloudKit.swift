import Foundation
import Network
import UIKit
import UniFlowCore

// Gemeinsamer Dokument-Index ("Bibliothek", docs/DOKUMENT-INDEX-2026-11-04.md) ohne eigenen Server (iPad V1): eine
// Datei wird einmal fuer alle analysiert, jeder mit derselben Datei uebernimmt den Eintrag ohne KI. Austausch ueber die
// oeffentliche CloudKit-Datenbank mit demselben Zugang wie die Community (`CommunityCloud`); was gebaut, geprueft und
// verschluesselt wird, entscheidet der Kern (`DocIndexBuilder`).
//
// Datensatz `DocIndex` (oeffentlich, docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md):
//   recordName       "<fileKey>#<page>"   (`DocIndexFingerprint.recordName`), Seite 0 = Zusammenfassung der Datei
//   fileKey          String (Queryable)    HMAC des Datei-SHA (`DocIndexFingerprint.fileKey`), nie der SHA selbst
//   page             Int(64)
//   payload          String                Eintrag verschluesselt (`DocIndexCrypto`, Base64)
//   version          Int(64)               Fassung des Schemas
//   createdAt        String                ISO 8601, UTC
//   ownerRecordName  String                CloudKit-Nutzerkennung des Erstellers (nur Anzeige/Moderation)
// Kein Seitentext, kein Bild, keine Namen. Der Schluessel des Chiffrats entsteht per HKDF aus Datei-SHA und
// Seiten-Abdruck und liegt nie bei CloudKit: lesen kann nur, wer dieselbe Datei hat.

enum DocIndexCloudRecord {
    static let type = "DocIndex"
    enum Field {
        static let fileKey = "fileKey", page = "page", payload = "payload", version = "version"
        static let createdAt = "createdAt", owner = "ownerRecordName"
    }
}

/// `DocIndexCloud` ueber CloudKit. Lesen geht ohne iCloud-Konto nicht (CloudKit verlangt fuer Abfragen keines, die App
/// aber fuer das Speichern); `save` ueberschreibt nie einen fremden Datensatz.
final class CloudKitDocIndex: DocIndexCloud, @unchecked Sendable {
    let cloud: CommunityCloud

    init(cloud: CommunityCloud) { self.cloud = cloud }

    static func record(_ r: CommunityRecord) -> DocIndexRecord? {
        guard r.type == DocIndexCloudRecord.type,
              let key = r[DocIndexCloudRecord.Field.fileKey]?.string, !key.isEmpty,
              let page = r[DocIndexCloudRecord.Field.page]?.int, page >= 0,
              let payload = r[DocIndexCloudRecord.Field.payload]?.string, !payload.isEmpty,
              payload.count <= DocIndexCrypto.maxPayloadChars else { return nil }
        let rec = DocIndexRecord(fileKey: key, page: page, payload: payload,
                                 version: r[DocIndexCloudRecord.Field.version]?.int ?? 0,
                                 createdAt: r[DocIndexCloudRecord.Field.createdAt]?.string ?? "",
                                 ownerRecordName: r[DocIndexCloudRecord.Field.owner]?.string ?? "")
        // Name und Inhalt muessen zusammenpassen (fremde Form verwerfen)
        return r.name == rec.recordName ? rec : nil
    }

    func records(fileKey: String) async throws -> [DocIndexRecord] {
        let found = try await cloud.query(CommunityQuery(type: DocIndexCloudRecord.type,
                                                         equals: [DocIndexCloudRecord.Field.fileKey: .string(fileKey)],
                                                         limit: 400), in: .publicDB)
        return found.compactMap(Self.record).filter { $0.fileKey == fileKey }.sorted { $0.page < $1.page }
    }

    func record(fileKey: String, page: Int) async throws -> DocIndexRecord? {
        let name = DocIndexFingerprint.recordName(fileKey: fileKey, page: page)
        return try await cloud.fetch(name: name, type: DocIndexCloudRecord.type, in: .publicDB).flatMap(Self.record)
    }

    func save(_ record: DocIndexRecord) async throws {
        guard try await cloud.accountStatus() == .available else { throw CommunityCloudError.notSignedIn }
        let me = try await cloud.userRecordName()
        if let existing = try await cloud.fetch(name: record.recordName, type: DocIndexCloudRecord.type, in: .publicDB),
           CloudKitCommunityService.owner(existing, me: me) != me {
            return   // schon von jemand anderem geteilt: nichts zu tun
        }
        var r = CommunityRecord(type: DocIndexCloudRecord.type, name: record.recordName)
        r[DocIndexCloudRecord.Field.fileKey] = .string(record.fileKey)
        r[DocIndexCloudRecord.Field.page] = .int(record.page)
        r[DocIndexCloudRecord.Field.payload] = .string(record.payload)
        r[DocIndexCloudRecord.Field.version] = .int(record.version)
        r[DocIndexCloudRecord.Field.createdAt] = .string(record.createdAt)
        r[DocIndexCloudRecord.Field.owner] = .string(me)
        _ = try await cloud.save(r, in: .publicDB)
    }
}

enum DocIndexCloudFactory {
    /// Dienst dieses Builds; nil ohne iCloud-Container (Simulator, CI, Personal Team): dann nur der lokale Zwischenspeicher
    static func make() -> DocIndexCloud? { CommunityCloudFactory.make().map { CloudKitDocIndex(cloud: $0) } }

    /// Index-KI: mit dem eigenen ChatGPT auch Seiten mit Bild, sonst nur Text
    static func makeAI(_ provider: AIProvider) -> DocIndexAI {
        if let session = provider as? ChatGPTSession { return ChatGPTVisionAI(session: session, http: URLSessionAITransport()) }
        return TextDocIndexAI(provider)
    }
}

/// Vorwaermen nach dem Abgleich (Regel des Inhabers): nur im WLAN (kein teures, kein eingeschraenktes Netz) und beim
/// Laden; hoechstens `DocIndexBuilder.prewarmFilesPerRun` Dateien der laufenden Woche, der naechste Lauf macht weiter.
enum DocIndexPrewarm {
    @MainActor static func charging() -> Bool {
        let device = UIDevice.current
        let was = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = was }
        return device.batteryState == .charging || device.batteryState == .full
    }

    /// Aktueller Netzweg: WLAN/Kabel ohne Kosten und ohne Datensparmodus
    static func onWiFi() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.take() else { return }
                monitor.cancel()
                c.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained
                         && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)))
            }
            monitor.start(queue: DispatchQueue(label: "docindex.prewarm.path"))
        }
    }

    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    /// Stufe aus der Einstellung "Vorab einordnen" (`DocIndexPrewarmSetting`): `full` erzeugt und teilt dazu je Seite
    /// eine Erklaerung und fuer Seiten mit Aufgaben eine Loesung (Erklaerungsspeicher), mit denselben Grenzen
    static func run(_ ctx: LocalContext, level: DocIndexPrewarmLevel = DocIndexPrewarmSetting.level()) async {
        guard let provider = ctx.ai.provider, await charging(), await onWiFi() else { return }
        let ai = ctx.docIndex.ai(from: provider)
        _ = await DocIndexBuilder.prewarm(ctx: ctx, cloud: ctx.docIndex.cloud, ai: ai, cipher: ctx.docIndex.cipher,
                                          level: level, tutorAI: level == .full ? provider : nil, shouldStop: { Task.isCancelled })
    }
}
