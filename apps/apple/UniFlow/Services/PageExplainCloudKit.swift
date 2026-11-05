import Foundation
import UniFlowCore

// Erklaerungsspeicher ohne eigenen Server (iPad V1, docs/ERKLAERUNGSSPEICHER-2026-11-04.md): die Antworten der KI-Hilfe
// fuer ganze Seiten (erklaeren, einfach erklaeren, zusammenfassen, Fachbegriffe, Aufgabe loesen, Hinweise) einmal fuer
// alle, ueber die oeffentliche CloudKit-Datenbank mit demselben Zugang wie der Dokument-Index. Was geteilt, verschluesselt
// und gewaehlt wird, entscheidet der Kern (`PageExplain`, `PageExplainBuilder`).
//
// Datensatz `PageExplain` (oeffentlich, docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md):
//   recordName       "<fileKey>#<page>#<mode>#<variant>"   (`PageExplain.recordName`)
//   fileKey          String (Queryable)    HMAC des Datei-SHA (`DocIndexFingerprint.fileKey`), nie der SHA selbst
//   page             Int(64)               1 = erste Seite
//   mode             String                explain | explain_simple | summary | terms | steps | hints
//   variant          Int(64)               1...3, nie ueberschrieben
//   payload          String                Antwort verschluesselt (`PageExplainCrypto`, Base64)
//   version          Int(64)               Fassung des Formats
//   createdAt        String                ISO 8601, UTC
//   ownerRecordName  String                CloudKit-Nutzerkennung des Erstellers (nur Moderation)
// Kein Seitentext, kein Bild, keine Namen. Lesen kann nur, wer dieselbe Datei hat (Schluessel aus Datei-SHA und
// Seiten-Abdruck, liegt nie bei CloudKit).

enum PageExplainCloudRecord {
    static let type = "PageExplain"
    enum Field {
        static let fileKey = "fileKey", page = "page", mode = "mode", variant = "variant", payload = "payload", version = "version"
        static let createdAt = "createdAt", owner = "ownerRecordName"
    }
    /// so viele Datensaetze je Datei hoechstens in einer Abfrage (Seiten x Modi x Varianten)
    static let queryLimit = 900
}

/// `PageExplainCloud` ueber CloudKit; `save` ueberschreibt nie (auch keinen eigenen Datensatz)
final class CloudKitPageExplain: PageExplainCloud, @unchecked Sendable {
    let cloud: CommunityCloud

    init(cloud: CommunityCloud) { self.cloud = cloud }

    static func record(_ r: CommunityRecord) -> PageExplainRecord? {
        guard r.type == PageExplainCloudRecord.type,
              let key = r[PageExplainCloudRecord.Field.fileKey]?.string, !key.isEmpty,
              let page = r[PageExplainCloudRecord.Field.page]?.int, page >= 1,
              let mode = r[PageExplainCloudRecord.Field.mode]?.string, PageExplain.isStoredMode(mode),
              let variant = r[PageExplainCloudRecord.Field.variant]?.int, (1...PageExplain.maxVariants).contains(variant),
              let payload = r[PageExplainCloudRecord.Field.payload]?.string, !payload.isEmpty,
              payload.count <= DocIndexCrypto.maxPayloadChars else { return nil }
        let rec = PageExplainRecord(fileKey: key, page: page, mode: mode, variant: variant, payload: payload,
                                    version: r[PageExplainCloudRecord.Field.version]?.int ?? 0,
                                    createdAt: r[PageExplainCloudRecord.Field.createdAt]?.string ?? "",
                                    ownerRecordName: r[PageExplainCloudRecord.Field.owner]?.string ?? "")
        // Name und Inhalt muessen zusammenpassen (fremde Form verwerfen)
        return r.name == rec.recordName ? rec : nil
    }

    func records(fileKey: String, page: Int, mode: String) async throws -> [PageExplainRecord] {
        // nur `fileKey` ist abfragbar; Seite und Modus filtert das Geraet
        let found = try await cloud.query(CommunityQuery(type: PageExplainCloudRecord.type,
                                                         equals: [PageExplainCloudRecord.Field.fileKey: .string(fileKey)],
                                                         limit: PageExplainCloudRecord.queryLimit), in: .publicDB)
        return found.compactMap(Self.record).filter { $0.fileKey == fileKey && $0.page == page && $0.mode == mode }.sorted { $0.variant < $1.variant }
    }

    func save(_ record: PageExplainRecord) async throws -> Bool {
        guard try await cloud.accountStatus() == .available else { throw CommunityCloudError.notSignedIn }
        let me = try await cloud.userRecordName()
        if try await cloud.fetch(name: record.recordName, type: PageExplainCloudRecord.type, in: .publicDB) != nil {
            return false   // Platz belegt: nie ueberschreiben
        }
        var r = CommunityRecord(type: PageExplainCloudRecord.type, name: record.recordName)
        r[PageExplainCloudRecord.Field.fileKey] = .string(record.fileKey)
        r[PageExplainCloudRecord.Field.page] = .int(record.page)
        r[PageExplainCloudRecord.Field.mode] = .string(record.mode)
        r[PageExplainCloudRecord.Field.variant] = .int(record.variant)
        r[PageExplainCloudRecord.Field.payload] = .string(record.payload)
        r[PageExplainCloudRecord.Field.version] = .int(record.version)
        r[PageExplainCloudRecord.Field.createdAt] = .string(record.createdAt)
        r[PageExplainCloudRecord.Field.owner] = .string(me)
        do {
            _ = try await cloud.save(r, in: .publicDB)
            return true
        } catch CommunityCloudError.other(let text) where text.contains("serverRecordChanged") {
            return false   // Wettlauf: jemand anderes war schneller
        }
    }
}

enum PageExplainCloudFactory {
    /// Dienst dieses Builds; nil ohne iCloud-Container (Simulator, CI, Personal Team): dann bleiben Antworten lokal
    static func make() -> PageExplainCloud? { CommunityCloudFactory.make().map { CloudKitPageExplain(cloud: $0) } }
}

/// Einstellung "Vorab einordnen" (Schalter des Inhabers, 04.11.2026): `basic` = Zusammenfassung und Begriffe (Standard),
/// `full` = dazu Erklaerungen und Loesungen fuer alle - kostet je Seite ein Vielfaches. UserDefaults
/// `uniflow.docIndexPrewarmLevel`, Werte "basic" | "full"; alles andere gilt als `basic`.
enum DocIndexPrewarmSetting {
    static let key = "uniflow.docIndexPrewarmLevel"
    static let defaultRaw = DocIndexPrewarmLevel.basic.rawValue

    static func level(raw: String?) -> DocIndexPrewarmLevel {
        raw.flatMap(DocIndexPrewarmLevel.init(rawValue:)) ?? .basic
    }

    static func level(_ defaults: UserDefaults = .standard) -> DocIndexPrewarmLevel { level(raw: defaults.string(forKey: key)) }

    static func set(_ level: DocIndexPrewarmLevel, _ defaults: UserDefaults = .standard) { defaults.set(level.rawValue, forKey: key) }

    /// Beschriftungen der Auswahl in den Einstellungen
    static func label(_ level: DocIndexPrewarmLevel) -> String {
        switch level {
        case .basic: return "Zusammenfassung und Begriffe (Standard)"
        case .full: return "Alles (auch Erklärungen und Lösungen)"
        }
    }

    static let costNote = "Alles vorab kostet je Seite ein Vielfaches und löst Übungsaufgaben für alle, bevor jemand fragt."
}
