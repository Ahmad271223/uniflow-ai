import Foundation
import UniFlowCore

// Bibliothek der Modulkataloge (docs/STUDIENVERLAUF-2026-11-04.md): ein Katalog wird einmal gebaut und geteilt. Nur die
// Fakten je Modul (study-catalog.schema.json, ohne Inhalt/Lernziele/Literatur) liegen oeffentlich in CloudKit; den
// vollen Modultext liest jedes Geraet selbst aus der oeffentlichen PDF. Derselbe Zugang wie Community und Wochentests
// (`CommunityCloud`); wie beim Wochentest hoechstens drei Varianten je Schluessel, falls zwei Geraete zugleich bauen.
//
// Datensatz `StudyCatalog` (oeffentliche Datenbank, Lesen fuer alle, Anlegen fuer iCloud-Nutzer, Schreiben nur der Ersteller):
//   recordName       "<catalogKey>#<variant>"  Anlegen atomar je Variante, nie ueberschreiben
//   catalogKey       String (Queryable)        sha256("luh|TIBSc22|WS 2025/26")
//   variant          Int(64)                   0..2
//   payload          String                    Fakten als JSON (Validator muss leer sein)
//   version          Int(64)                   Formatversion (v im JSON, jetzt 1)
//   createdAt        String                    ISO 8601, UTC
//   ownerRecordName  String                    CloudKit-Nutzerkennung des Erstellers (nur Anzeige im Dashboard)
// Keine Namen, keine Noten, kein persoenlicher Stand.

enum StudyCatalogRecord {
    static let type = "StudyCatalog"
    static let maxVariants = 3
    enum Field {
        static let catalogKey = "catalogKey", variant = "variant", payload = "payload", version = "version"
        static let createdAt = "createdAt", owner = "ownerRecordName"
    }

    static func name(key: String, variant: Int) -> String { "\(key)#\(variant)" }
}

/// `StudyCatalogLibrary` ueber CloudKit. Lesen geht ohne iCloud-Konto; veroeffentlichen nur mit Konto.
final class CloudKitStudyCatalogLibrary: StudyCatalogLibrary, @unchecked Sendable {
    let cloud: CommunityCloud
    private let now: @Sendable () -> Date

    init(cloud: CommunityCloud, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.now = now
    }

    /// Varianten zum Schluessel, kleinste zuerst; nur Datensaetze in der erwarteten Form
    func lookup(key: String) async throws -> [String] {
        let records = try await cloud.query(CommunityQuery(type: StudyCatalogRecord.type, equals: [StudyCatalogRecord.Field.catalogKey: .string(key)],
                                                           limit: StudyCatalogRecord.maxVariants * 2), in: .publicDB)
        return records.compactMap { r -> (Int, String)? in
            guard r.type == StudyCatalogRecord.type, r[StudyCatalogRecord.Field.catalogKey]?.string == key,
                  let v = r[StudyCatalogRecord.Field.variant]?.int, (0..<StudyCatalogRecord.maxVariants).contains(v),
                  r.name == StudyCatalogRecord.name(key: key, variant: v),
                  let p = r[StudyCatalogRecord.Field.payload]?.string, !p.isEmpty else { return nil }
            return (v, p)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Erste freie Variante anlegen; vorhandene werden nie geaendert. Gewinnt beim Wettlauf ein anderer (CloudKit lehnt
    /// das zweite Anlegen ab), geht es mit der naechsten Variante weiter. false = alle drei belegt.
    func publish(key: String, meta: StudyCatalogMeta, payload: String) async throws -> Bool {
        guard try await cloud.accountStatus() == .available else { throw CommunityCloudError.notSignedIn }
        let user = try await cloud.userRecordName()
        for v in 0..<StudyCatalogRecord.maxVariants {
            let name = StudyCatalogRecord.name(key: key, variant: v)
            if let existing = try await cloud.fetch(name: name, type: StudyCatalogRecord.type, in: .publicDB) {
                if existing[StudyCatalogRecord.Field.payload]?.string == payload { return true }     // derselbe Inhalt liegt schon da
                continue
            }
            var r = CommunityRecord(type: StudyCatalogRecord.type, name: name)
            r[StudyCatalogRecord.Field.catalogKey] = .string(key)
            r[StudyCatalogRecord.Field.variant] = .int(v)
            r[StudyCatalogRecord.Field.payload] = .string(payload)
            r[StudyCatalogRecord.Field.version] = .int(1)
            r[StudyCatalogRecord.Field.createdAt] = .string(CloudKitWeeklyTestShare.timestamp(now()))
            r[StudyCatalogRecord.Field.owner] = .string(user)
            do {
                _ = try await cloud.save(r, in: .publicDB)
            } catch {
                // zeitgleich von einem anderen angelegt: naechste Variante; sonst echter Fehler (offline, Kontingent)
                if let other = try? await cloud.fetch(name: name, type: StudyCatalogRecord.type, in: .publicDB),
                   CloudKitCommunityService.owner(other, me: user) != user { continue }
                throw error
            }
            guard let stored = try await cloud.fetch(name: name, type: StudyCatalogRecord.type, in: .publicDB) else { continue }
            if CloudKitCommunityService.owner(stored, me: user) == user { return true }
        }
        return false
    }
}

enum StudyCatalogLibraryFactory {
    /// Bibliothek dieses Builds; nil ohne iCloud-Container (Simulator, CI): dann nur lokal und Download
    static func make() -> StudyCatalogLibrary? {
        guard let cloud = CommunityCloudFactory.make() else { return nil }
        return CloudKitStudyCatalogLibrary(cloud: cloud)
    }
}
