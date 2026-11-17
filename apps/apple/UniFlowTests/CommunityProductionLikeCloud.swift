import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// CloudKit-Nachbau, der sich wie die oeffentliche Datenbank in Production verhaelt (17.11.2026, Auftrag des Inhabers:
/// "prüfe das Kommentare schreiben, ob das wirklich geht, und Diskussion starten und Like und Antworten").
///
/// Anders als `CommunityCloudKitTests.FakeCommunityCloud` nimmt er nichts hin, was Production ablehnen wuerde. Die Regeln
/// liest er aus `apps/apple/Config/cloudkit-schema.ckdb` (dieselbe Datei, die in die CloudKit-Konsole importiert wird):
/// - Schreiben nur in Typen und Felder, die im Schema stehen, mit dem richtigen Feldtyp (Production legt nichts selbst an)
/// - Suchen nur ueber Felder mit `QUERYABLE`; "alle Datensaetze eines Typs" nur mit abfragbarem `recordName`
/// - Rechte: Anlegen nur mit iCloud-Konto und `GRANT CREATE TO "_icloud"`, Aendern und Loeschen nur der Ersteller,
///   Lesen fuer alle nur mit `GRANT READ TO "_world"` (sonst sieht jeder nur seine eigenen Datensaetze)
/// - der Ersteller eigener Datensaetze heisst wie bei CloudKit `__defaultOwner__`
/// - Anlegen eines Namens, den es schon gibt, scheitert (`serverRecordChanged`)
/// - auf Wunsch kennt die Suche frisch angelegte Datensaetze noch nicht (`indexDelay`, der Index von CloudKit folgt
///   verzoegert); Holen ueber den Namen geht sofort
/// Jedes Geraet bekommt einen eigenen Zugang (`device`), alle teilen die Datenbank. Nur im Speicher, kein Netz.
final class ProductionLikeStore: @unchecked Sendable {
    struct Field: Equatable { let kind: String; let queryable: Bool }
    struct RecordType: Equatable {
        var fields: [String: Field] = [:]
        var recordNameQueryable = false
        /// Rolle (`_world`, `_icloud`, `_creator`) -> Rechte (`READ`, `CREATE`, `WRITE`)
        var rights: [String: Set<String>] = [:]
        func allows(_ right: String, _ role: String) -> Bool { rights[role]?.contains(right) == true }
    }

    struct Rejected: Equatable { let op: String; let reason: String }

    let types: [String: RecordType]
    let assetDir: URL
    private let lock = NSLock()
    private var records: [String: CommunityRecord] = [:]
    private var notIndexed = Set<String>()
    private var _log: [String] = []
    private var _rejected: [Rejected] = []
    private var _failure: CommunityCloudError?
    private var _indexDelay = false

    /// naechste Aufrufe scheitern damit (offline, Kontingent …)
    var failure: CommunityCloudError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    /// frisch Angelegtes fehlt in der Suche, bis `catchUp()` laeuft
    var indexDelay: Bool {
        get { lock.withLock { _indexDelay } }
        set { lock.withLock { _indexDelay = newValue } }
    }
    /// alle Aufrufe in Reihenfolge ("create Comment", "query Like" …)
    var log: [String] { lock.withLock { _log } }
    /// was Production abgelehnt haette (Schema, Index, Rechte) – in einem gruenen Lauf leer
    var rejected: [Rejected] { lock.withLock { _rejected } }

    init(schema: String, assetDir: URL) {
        types = Self.parse(schema)
        self.assetDir = assetDir
    }

    /// Schema der App aus dem Repo (neben dem Testordner: apps/apple/Config/cloudkit-schema.ckdb)
    static func schemaFromRepo(file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/cloudkit-schema.ckdb")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Schema fuer die Tests: die Datei aus dem Repo; ist sie nicht lesbar (Mac "Designed for iPad": der Testwirt laeuft
    /// in der Sandbox), die Kopie der Community-Typen unten. `CommunityVierAktionenAppTests` prueft im Simulator, dass
    /// die Kopie der Datei gleicht.
    static func schema() -> String { (try? schemaFromRepo()) ?? communitySchemaCopy }

    /// Typen der Community aus Config/cloudkit-schema.ckdb (Stand 04.11.2026), ohne die Systemfelder ausser `___recordID`
    static let communitySchemaCopy = """
        RECORD TYPE Solution (
            "___recordID"    REFERENCE QUERYABLE,
            solutionID       STRING,
            fingerprint      STRING QUERYABLE,
            university       STRING QUERYABLE,
            courseKey        STRING QUERYABLE,
            visibility       STRING,
            groupKey         STRING,
            displayName      STRING,
            title            STRING,
            pageCount        INT64,
            week             INT64,
            createdAt        STRING,
            package          ASSET,
            ownerRecordName  STRING,
            withdrawn        INT64,
            GRANT WRITE TO "_creator",
            GRANT CREATE TO "_icloud",
            GRANT READ TO "_world"
        );
        RECORD TYPE Report (
            "___recordID"       REFERENCE QUERYABLE,
            solutionID          STRING QUERYABLE,
            reason              STRING,
            note                STRING,
            reporterRecordName  STRING,
            commentID           STRING,
            createdAt           STRING QUERYABLE SORTABLE,
            GRANT WRITE TO "_creator",
            GRANT READ TO "_creator",
            GRANT CREATE TO "_icloud"
        );
        RECORD TYPE StudyGroup (
            "___recordID"    REFERENCE QUERYABLE,
            groupKey         STRING,
            name             STRING,
            university       STRING,
            ownerRecordName  STRING,
            createdAt        STRING,
            GRANT WRITE TO "_creator",
            GRANT CREATE TO "_icloud",
            GRANT READ TO "_world"
        );
        RECORD TYPE Block (
            "___recordID"    REFERENCE QUERYABLE,
            ownerRecordName  STRING,
            createdAt        STRING,
            GRANT WRITE TO "_creator",
            GRANT CREATE TO "_icloud",
            GRANT READ TO "_world"
        );
        RECORD TYPE Ban (
            "___recordID"    REFERENCE QUERYABLE,
            ownerRecordName  STRING,
            GRANT WRITE TO "_creator",
            GRANT READ TO "_world"
        );
        RECORD TYPE Comment (
            "___recordID"    REFERENCE QUERYABLE,
            solutionID       STRING QUERYABLE,
            parentID         STRING,
            status           STRING,
            createdAt        STRING,
            editedAt         STRING,
            payload          STRING,
            ownerRecordName  STRING,
            removedID        STRING,
            createdOrder     INT64,
            GRANT WRITE TO "_creator",
            GRANT CREATE TO "_icloud",
            GRANT READ TO "_world"
        );
        RECORD TYPE Like (
            "___recordID"    REFERENCE QUERYABLE,
            solutionID       STRING QUERYABLE,
            ownerRecordName  STRING,
            createdAt        STRING,
            GRANT WRITE TO "_creator",
            GRANT CREATE TO "_icloud",
            GRANT READ TO "_world"
        );
        RECORD TYPE Correction (
            "___recordID"    REFERENCE QUERYABLE,
            solutionID       STRING QUERYABLE,
            solutionOwner    STRING QUERYABLE,
            payload          STRING,
            createdAt        STRING,
            ownerRecordName  STRING,
            createdOrder     INT64,
            GRANT WRITE TO "_creator",
            GRANT CREATE TO "_icloud",
            GRANT READ TO "_world"
        );
        """

    /// Liest `RECORD TYPE Name ( feld TYP [QUERYABLE] …, GRANT RECHT TO "rolle", … );`
    static func parse(_ text: String) -> [String: RecordType] {
        var out: [String: RecordType] = [:]
        var name: String?
        var current = RecordType()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.isEmpty { continue }
            if line.hasPrefix("RECORD TYPE ") {
                name = line.dropFirst("RECORD TYPE ".count).split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init)
                current = RecordType()
                continue
            }
            guard let n = name else { continue }
            if line.hasPrefix(");") {
                out[n] = current
                name = nil
                continue
            }
            let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: ",")).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.first == "GRANT", let to = parts.firstIndex(of: "TO"), to + 1 < parts.count {
                let role = parts[to + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                for right in parts[1..<to] { current.rights[role, default: []].insert(right.trimmingCharacters(in: CharacterSet(charactersIn: ","))) }
                continue
            }
            guard parts.count >= 2 else { continue }
            let field = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let queryable = parts.dropFirst(2).contains("QUERYABLE")
            if field == "___recordID" { current.recordNameQueryable = queryable; continue }
            if field.hasPrefix("___") { continue }
            current.fields[field] = Field(kind: parts[1], queryable: queryable)
        }
        return out
    }

    /// Zugang eines Geraets; `user` nil = kein iCloud-Konto auf dem Geraet
    func device(_ user: String?) -> Device { Device(store: self, user: user) }

    /// die Suche holt auf (alles Angelegte ist jetzt auffindbar)
    func catchUp() { lock.withLock { notIndexed = [] } }

    /// Datensaetze eines Typs in der oeffentlichen Datenbank, mit dem echten Ersteller
    func all(_ type: String) -> [CommunityRecord] {
        lock.withLock { records.filter { $0.key.hasPrefix("pub|") && $0.value.type == type }.map(\.value).sorted { $0.name < $1.name } }
    }

    /// Datensatz von aussen aendern (Moderation im Dashboard)
    func moderate(name: String, _ change: (inout CommunityRecord) -> Void) {
        lock.withLock {
            guard var r = records["pub|" + name] else { return }
            change(&r)
            records["pub|" + name] = r
        }
    }

    final class Device: CommunityCloud, @unchecked Sendable {
        let store: ProductionLikeStore
        let user: String?

        init(store: ProductionLikeStore, user: String?) {
            self.store = store
            self.user = user
        }

        func accountStatus() async throws -> CommunityAccountStatus {
            try store.begin("accountStatus")
            return user == nil ? .noAccount : .available
        }

        func userRecordName() async throws -> String {
            try store.begin("userRecordName")
            guard let user else { throw CommunityCloudError.notSignedIn }
            return user
        }

        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord {
            try store.write(record, scope: scope, user: user, mayReplace: true)
        }

        func create(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord {
            try store.write(record, scope: scope, user: user, mayReplace: false)
        }

        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? {
            try store.fetch(name: name, type: type, scope: scope, user: user)
        }

        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] {
            try store.query(q, scope: scope, user: user)
        }

        func delete(name: String, type: String, in scope: CommunityScope) async throws {
            try store.delete(name: name, type: type, scope: scope, user: user)
        }
    }

    // MARK: Regeln

    private func key(_ scope: CommunityScope, _ user: String?, _ name: String) -> String {
        scope == .publicDB ? "pub|" + name : "priv|\(user ?? "")|" + name
    }

    fileprivate func begin(_ op: String) throws {
        try lock.withLock {
            _log.append(op)
            if let f = _failure { throw f }
        }
    }

    private func reject(_ op: String, _ reason: String, _ error: CommunityCloudError) -> CommunityCloudError {
        lock.withLock { _rejected.append(Rejected(op: op, reason: reason)) }
        return error
    }

    /// wie der Dienst es zurueckgibt: eigener Ersteller heisst `__defaultOwner__`
    private func out(_ r: CommunityRecord, user: String?) -> CommunityRecord {
        var r = r
        if let user, r.creator == user { r.creator = CloudKitCommunityService.defaultOwner }
        return r
    }

    private func readable(_ r: CommunityRecord, scope: CommunityScope, user: String?) -> Bool {
        guard scope == .publicDB, let t = types[r.type] else { return true }
        if t.allows("READ", "_world") { return true }
        return t.allows("READ", "_creator") && user != nil && r.creator == user
    }

    fileprivate func write(_ record: CommunityRecord, scope: CommunityScope, user: String?, mayReplace: Bool) throws -> CommunityRecord {
        let op = "\(mayReplace ? "save" : "create") \(record.type)"
        try begin(op)
        guard let user else { throw CommunityCloudError.notSignedIn }
        guard let t = types[record.type] else {
            throw reject(op, "Typ \(record.type) steht nicht im Schema", .other("Cannot create new type \(record.type) in production schema"))
        }
        for (k, v) in record.fields {
            guard let f = t.fields[k] else {
                throw reject(op, "Feld \(record.type).\(k) steht nicht im Schema", .other("Cannot create or modify field '\(k)' in record '\(record.type)' in production schema"))
            }
            let kind: String
            switch v {
            case .string: kind = "STRING"
            case .int: kind = "INT64"
            case .asset: kind = "ASSET"
            }
            guard f.kind == kind else {
                throw reject(op, "Feld \(record.type).\(k) ist \(f.kind), geschrieben wird \(kind)", .other("invalid attempt to set value type \(kind) for field '\(k)'"))
            }
        }
        var r = record
        for (k, v) in r.fields {
            // wie CloudKit: die Datei wird hochgeladen; beim Lesen kommt eine eigene Kopie zurueck
            if case .asset(let url) = v {
                let copy = assetDir.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: url, to: copy)
                r.fields[k] = .asset(copy)
            }
        }
        let k = key(scope, user, r.name)
        let existing = lock.withLock { records[k] }
        if let existing {
            guard mayReplace else { throw CommunityCloudError.changedElsewhere }          // serverRecordChanged
            guard existing.type == r.type else { throw CommunityCloudError.other("record type mismatch") }
            if scope == .publicDB {
                guard existing.creator == user, t.allows("WRITE", "_creator") else {
                    throw reject(op, "\(record.type) aendert nur der Ersteller", .permission)
                }
            }
            r.creator = existing.creator
        } else {
            if scope == .publicDB, !(t.allows("CREATE", "_icloud") || t.allows("CREATE", "_world")) {
                throw reject(op, "\(record.type): angemeldete Nutzer duerfen nicht anlegen (GRANT CREATE TO \"_icloud\" fehlt)", .permission)
            }
            r.creator = user
        }
        lock.withLock {
            records[k] = r
            if _indexDelay, existing == nil { notIndexed.insert(k) }
        }
        return out(r, user: user)
    }

    fileprivate func fetch(name: String, type: String, scope: CommunityScope, user: String?) throws -> CommunityRecord? {
        try begin("fetch \(type)")
        guard let r = lock.withLock({ records[key(scope, user, name)] }), r.type == type else { return nil }
        guard readable(r, scope: scope, user: user) else { throw reject("fetch \(type)", "\(type) ist fuer andere nicht lesbar", .permission) }
        return out(r, user: user)
    }

    fileprivate func query(_ q: CommunityQuery, scope: CommunityScope, user: String?) throws -> [CommunityRecord] {
        let op = "query \(q.type)"
        try begin(op)
        guard let t = types[q.type] else {
            throw reject(op, "Typ \(q.type) steht nicht im Schema", .other("Did not find record type: \(q.type)"))
        }
        for field in Array(q.equals.keys) + Array(q.anyOf.keys) {
            guard t.fields[field]?.queryable == true else {
                throw reject(op, "Feld \(q.type).\(field) ist nicht QUERYABLE", .other("Field '\(field)' is not marked queryable"))
            }
        }
        if q.equals.isEmpty, q.anyOf.isEmpty, !t.recordNameQueryable {
            throw reject(op, "\(q.type): recordName ist nicht QUERYABLE", .other("Field 'recordName' is not marked queryable"))
        }
        let prefix = scope == .publicDB ? "pub|" : "priv|\(user ?? "")|"
        return lock.withLock {
            records.filter { k, r in
                k.hasPrefix(prefix) && r.type == q.type && !notIndexed.contains(k)
                    && q.equals.allSatisfy { r.fields[$0.key] == $0.value }
                    && q.anyOf.allSatisfy { f, values in r.fields[f]?.string.map(values.contains) ?? false }
            }
            .map(\.value)
        }
        .filter { readable($0, scope: scope, user: user) }
        .sorted { $0.name < $1.name }
        .prefix(q.limit)
        .map { out($0, user: user) }
    }

    fileprivate func delete(name: String, type: String, scope: CommunityScope, user: String?) throws {
        let op = "delete \(type)"
        try begin(op)
        guard let user else { throw CommunityCloudError.notSignedIn }
        let k = key(scope, user, name)
        guard let r = lock.withLock({ records[k] }) else { return }                      // unknownItem: kein Fehler (wie CKCommunityCloud)
        if scope == .publicDB {
            guard r.creator == user, types[r.type]?.allows("WRITE", "_creator") == true else {
                throw reject(op, "\(r.type) loescht nur der Ersteller", .permission)
            }
        }
        lock.withLock {
            records[k] = nil
            notIndexed.remove(k)
        }
    }
}
