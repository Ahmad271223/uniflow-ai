import CloudKit
import Foundation
import UniFlowCore

// Zugang zu CloudKit fuer die Community (docs/LOESUNGEN-TEILEN.md, Abschnitt 7), nur in der App: der Kern bleibt
// ohne CloudKit. `CommunityCloud` ist die schmale Schnittstelle ueber den Datensatz-Operationen (speichern, holen,
// suchen, loeschen) in der oeffentlichen und der privaten Datenbank; `CKCommunityCloud` setzt sie mit CloudKit um,
// die Tests mit einem Nachbau im Speicher. Ohne iCloud-Container im Build (kein bezahltes Team, `UFCloudKitContainer`
// in der Info.plist leer) gibt es keinen Zugang – der Dienst meldet "nicht verfügbar" statt abzustuerzen
// (`CKContainer(identifier:)` ohne Berechtigung bricht die App ab).

/// Datensatztypen beim Dienst
enum CommunityRecordType {
    static let solution = "Solution"
    static let report = "Report"
    static let block = "Block"
    static let studyGroup = "StudyGroup"
    /// vom Inhaber im Dashboard gesperrte Nutzer (nur lesen; Anlegen im Dashboard auf die Rolle des Inhabers beschraenken)
    static let ban = "Ban"
}

/// Feldwert eines Datensatzes (nur die Typen, die die Community braucht)
enum CommunityFieldValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    /// Datei (Paket): beim Speichern eine lokale Datei, nach dem Holen die heruntergeladene Datei
    case asset(URL)

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var int: Int? { if case .int(let i) = self { return i } else { return nil } }
    var asset: URL? { if case .asset(let u) = self { return u } else { return nil } }
}

/// Ein Datensatz, unabhaengig von CloudKit (Nachbau in Tests)
struct CommunityRecord: Equatable, Sendable {
    var type: String
    /// Datensatzname (eindeutig je Typ): Loesungs-ID, Gruppen-Schluessel …
    var name: String
    var fields: [String: CommunityFieldValue]
    /// Nutzerkennung des Erstellers beim Dienst (setzt die Datenbank)
    var creator: String?

    init(type: String, name: String, fields: [String: CommunityFieldValue] = [:], creator: String? = nil) {
        self.type = type
        self.name = name
        self.fields = fields
        self.creator = creator
    }

    subscript(key: String) -> CommunityFieldValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }
}

/// Suche: Typ und Gleichheitsbedingungen (UND), hoechstens `limit` Treffer
struct CommunityQuery: Equatable, Sendable {
    var type: String
    var equals: [String: CommunityFieldValue]
    var limit: Int = 200
}

enum CommunityScope: Sendable { case publicDB, privateDB }

enum CommunityAccountStatus: Sendable { case available, noAccount, restricted, unknown }

/// Fehler der Datenbank, schon auf die Faelle der Oberflaeche abgebildet
enum CommunityCloudError: Error, Equatable {
    case notSignedIn
    case offline
    case quota
    case notFound
    case permission
    case other(String)

    var serviceError: CommunityServiceError {
        switch self {
        case .notSignedIn: return .notSignedIn
        case .offline: return .offline
        case .quota: return .quota
        case .notFound: return .notFound
        case .permission: return .notOwner
        case .other(let m): return .server(m)
        }
    }
}

protocol CommunityCloud: Sendable {
    func accountStatus() async throws -> CommunityAccountStatus
    /// Nutzerkennung beim Dienst (CloudKit-Record-Name des Nutzers), nie Apple-ID oder E-Mail
    func userRecordName() async throws -> String
    /// Speichern (neu oder geaendert); Ergebnis mit Ersteller
    @discardableResult
    func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord
    /// Datensatz holen; nil, wenn es ihn nicht gibt
    func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord?
    func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord]
    func delete(name: String, type: String, in scope: CommunityScope) async throws
}

/// Woher der iCloud-Container kommt: Build-Einstellung `UF_CLOUDKIT_CONTAINER` (nur in Config/Team.xcconfig gesetzt)
/// -> Info.plist `UFCloudKitContainer`. Leer = kein Container in diesem Build.
enum CommunityCloudFactory {
    static let infoKey = "UFCloudKitContainer"

    static func containerIdentifier(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let raw = info?[infoKey] as? String else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // nicht ersetzte Build-Variable oder leer: kein Container
        guard !id.isEmpty, !id.hasPrefix("$("), id.hasPrefix("iCloud.") else { return nil }
        return id
    }

    /// CloudKit-Zugang dieses Builds; nil ohne Container (Simulator, CI, Personal Team)
    static func make() -> CommunityCloud? {
        guard let id = containerIdentifier() else { return nil }
        return CKCommunityCloud(container: CKContainer(identifier: id))
    }
}

/// CloudKit-Umsetzung (oeffentliche und private Datenbank des Containers)
final class CKCommunityCloud: CommunityCloud, @unchecked Sendable {
    private let container: CKContainer

    init(container: CKContainer) { self.container = container }

    private func database(_ scope: CommunityScope) -> CKDatabase {
        scope == .publicDB ? container.publicCloudDatabase : container.privateCloudDatabase
    }

    func accountStatus() async throws -> CommunityAccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            default: return .unknown
            }
        } catch {
            throw Self.map(error)
        }
    }

    func userRecordName() async throws -> String {
        do { return try await container.userRecordID().recordName } catch { throw Self.map(error) }
    }

    @discardableResult
    func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord {
        let db = database(scope)
        let id = CKRecord.ID(recordName: record.name)
        do {
            // vorhandenen Datensatz aendern (Zurueckziehen), sonst neu anlegen
            let ck: CKRecord
            if let existing = try? await db.record(for: id), existing.recordType == record.type {
                ck = existing
                for key in ck.allKeys() where record.fields[key] == nil { ck[key] = nil }
            } else {
                ck = CKRecord(recordType: record.type, recordID: id)
            }
            for (key, value) in record.fields {
                switch value {
                case .string(let s): ck[key] = s as CKRecordValue
                case .int(let i): ck[key] = Int64(i) as CKRecordValue
                case .asset(let url): ck[key] = CKAsset(fileURL: url)
                }
            }
            let saved = try await db.save(ck)
            return Self.record(saved)
        } catch {
            throw Self.map(error)
        }
    }

    func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? {
        do {
            let ck = try await database(scope).record(for: CKRecord.ID(recordName: name))
            return ck.recordType == type ? Self.record(ck) : nil
        } catch let e as CKError where e.code == .unknownItem {
            return nil
        } catch {
            throw Self.map(error)
        }
    }

    func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] {
        let predicates = q.equals.sorted { $0.key < $1.key }.map { key, value -> NSPredicate in
            switch value {
            case .string(let s): return NSPredicate(format: "%K == %@", key, s)
            case .int(let i): return NSPredicate(format: "%K == %d", key, i)
            case .asset: return NSPredicate(value: false)
            }
        }
        let query = CKQuery(recordType: q.type, predicate: predicates.isEmpty ? NSPredicate(value: true) : NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
        do {
            var out: [CommunityRecord] = []
            var (matches, cursor) = try await database(scope).records(matching: query, resultsLimit: q.limit)
            while true {
                for (_, result) in matches {
                    if case .success(let ck) = result { out.append(Self.record(ck)) }
                }
                guard let c = cursor, out.count < q.limit else { break }
                (matches, cursor) = try await database(scope).records(continuingMatchFrom: c, resultsLimit: q.limit - out.count)
            }
            return out
        } catch {
            throw Self.map(error)
        }
    }

    func delete(name: String, type: String, in scope: CommunityScope) async throws {
        do { _ = try await database(scope).deleteRecord(withID: CKRecord.ID(recordName: name)) } catch let e as CKError where e.code == .unknownItem {
            return
        } catch {
            throw Self.map(error)
        }
    }

    static func record(_ ck: CKRecord) -> CommunityRecord {
        var fields: [String: CommunityFieldValue] = [:]
        for key in ck.allKeys() {
            if let s = ck[key] as? String { fields[key] = .string(s) }
            else if let n = ck[key] as? NSNumber { fields[key] = .int(n.intValue) }
            else if let a = ck[key] as? CKAsset, let url = a.fileURL { fields[key] = .asset(url) }
        }
        return CommunityRecord(type: ck.recordType, name: ck.recordID.recordName, fields: fields,
                               creator: ck.creatorUserRecordID?.recordName)
    }

    /// CloudKit-Fehler auf die Faelle der Oberflaeche abbilden
    static func map(_ error: Error) -> CommunityCloudError {
        guard let e = error as? CKError else {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain { return .offline }
            return .other(error.localizedDescription)
        }
        switch e.code {
        case .notAuthenticated: return .notSignedIn
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy: return .offline
        case .quotaExceeded: return .quota
        case .unknownItem: return .notFound
        case .permissionFailure: return .permission
        case .partialFailure:
            if let inner = e.partialErrorsByItemID?.values.first { return map(inner) }
            return .other(e.localizedDescription)
        default: return .other(e.localizedDescription)
        }
    }
}
