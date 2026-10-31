import Foundation

/// Anfragen des Geraete-Abgleichs an den Dienst (App: `StudoraAccount`, Tests: Schein-Dienst)
public protocol DeviceSyncTransport: Sendable {
    /// `GET /api/sync/changes?<query>`
    func syncChanges(query: String) async throws -> JSONValue
    /// `POST /api/sync/push`
    func syncPush(_ body: JSONValue) async throws -> JSONValue
}

/// Ergebnis eines Laufs (wie `sync_client.run`)
public struct DeviceSyncResult: Equatable, Sendable {
    public var ok = true
    public var error: String?
    public var pulled = 0
    public var applied = 0
    public var pushed = 0
    public var deleted = 0
    public var conflicts = 0
    public var pending = 0
    public var notesMerged = 0
    /// Tarif Free: Notizen bleiben auf dem Geraet, alles andere gleicht ab
    public var planRequired = false
    public var errors: [String] = []

    public init() {}
}

/// Schema des Abgleichs (`app/sync.py::ensure_schema`, Vertrag G2). Laeuft erst beim ersten Abgleich mit einem Konto:
/// ohne Dienst bleibt die Datenbank des iPads, wie sie ist.
public enum DeviceSyncSchema {
    struct Entity {
        let name: String
        let pk: String
        /// Fremdschluessel -> Tabelle
        let fk: [(column: String, target: String)]
        var intPK: Bool { pk == "id" }
    }

    /// `ENTITIES`, Reihenfolge = Eltern vor Kindern
    static let entities: [Entity] = [
        Entity(name: "modules", pk: "id", fk: []),
        Entity(name: "folders", pk: "id", fk: [("module_id", "modules"), ("parent_id", "folders")]),
        Entity(name: "course_events", pk: "id", fk: [("module_id", "modules")]),
        Entity(name: "event_exceptions", pk: "id", fk: [("event_id", "course_events")]),
        Entity(name: "study_packages", pk: "id", fk: [("module_id", "modules")]),
        Entity(name: "study_tasks", pk: "id", fk: [("package_id", "study_packages")]),
        Entity(name: "flashcards", pk: "id", fk: []),
        Entity(name: "settings", pk: "key", fk: []),
        Entity(name: "annotations", pk: "file_id", fk: []),
    ]
    static let syncColumns: Set<String> = ["sync_version", "sync_updated_at", "sync_device"]
    static let nowSQL = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    /// Idempotent. Ohne `sync_ops`: die gibt es nur beim Dienst.
    public static func ensure(_ c: SQLiteConnection) throws {
        try c.execute("""
            CREATE TABLE IF NOT EXISTS sync_tombstones (
            entity TEXT NOT NULL, entity_id TEXT NOT NULL, deleted_at TEXT NOT NULL, device TEXT,
            PRIMARY KEY (entity, entity_id))
            """)
        try c.execute("CREATE INDEX IF NOT EXISTS idx_tombstones_time ON sync_tombstones(deleted_at)")
        for e in entities {
            let table = e.name
            let cols = Set(try c.columnNames(table))
            if cols.isEmpty { continue }
            for (col, decl) in [("sync_version", "INTEGER DEFAULT 1"), ("sync_updated_at", "TEXT"), ("sync_device", "TEXT")] where !cols.contains(col) {
                try c.execute("ALTER TABLE \(table) ADD COLUMN \(col) \(decl)")
            }
            try c.execute("""
                CREATE TRIGGER IF NOT EXISTS sync_ins_\(table) AFTER INSERT ON \(table)
                WHEN NEW.sync_updated_at IS NULL
                BEGIN UPDATE \(table) SET sync_updated_at = \(nowSQL), sync_version = COALESCE(NEW.sync_version, 1)
                      WHERE rowid = NEW.rowid; END
                """)
            try c.execute("""
                CREATE TRIGGER IF NOT EXISTS sync_upd_\(table) AFTER UPDATE ON \(table)
                WHEN NEW.sync_version IS OLD.sync_version AND NEW.sync_updated_at IS OLD.sync_updated_at
                BEGIN UPDATE \(table) SET sync_version = COALESCE(OLD.sync_version, 0) + 1, sync_updated_at = \(nowSQL),
                                          sync_device = NULL WHERE rowid = NEW.rowid; END
                """)
            try c.execute("""
                CREATE TRIGGER IF NOT EXISTS sync_del_\(table) AFTER DELETE ON \(table)
                BEGIN INSERT OR REPLACE INTO sync_tombstones(entity, entity_id, deleted_at, device)
                      VALUES ('\(table)', CAST(OLD.\(e.pk) AS TEXT), \(nowSQL), NULL); END
                """)
            try c.execute("UPDATE \(table) SET sync_updated_at = \(nowSQL), sync_version = COALESCE(sync_version, 1) WHERE sync_updated_at IS NULL")
        }
        // Zuordnung (`sync_client.ensure_tables`)
        try c.execute("""
            CREATE TABLE IF NOT EXISTS sync_link_map (
            entity TEXT NOT NULL, remote_id TEXT NOT NULL, local_id TEXT NOT NULL, remote_version INTEGER,
            local_version INTEGER, base TEXT, PRIMARY KEY (entity, remote_id))
            """)
        try c.execute("CREATE INDEX IF NOT EXISTS idx_sync_link_local ON sync_link_map(entity, local_id)")
        try c.execute("CREATE TABLE IF NOT EXISTS sync_link_state (key TEXT PRIMARY KEY, value TEXT)")
        try c.execute("""
            CREATE TABLE IF NOT EXISTS sync_link_pending (
            entity TEXT NOT NULL, remote_id TEXT NOT NULL, payload TEXT NOT NULL, reason TEXT, PRIMARY KEY (entity, remote_id))
            """)
    }
}

/// Geraete-Abgleich mit dem Studora-Konto (Vertrag G2): 1:1 nach `app/sync_client.py` (Windows-App), gleiche Regeln:
/// abrufen -> senden -> abrufen; Zuordnung in `sync_link_map`; erster Abgleich ueber fachliche Schluessel, ohne Doppelte;
/// Notizen mit `AnnotationMerge.mergeDocument`; `~dienst` markiert Angewendetes, das nie zurueckgesendet wird.
public actor DeviceSync {
    private let database: SQLiteDatabase
    private let transport: DeviceSyncTransport
    private let device: String

    public init(database: SQLiteDatabase, transport: DeviceSyncTransport, device: String) {
        self.database = database
        self.transport = transport
        self.device = device
    }

    /// Ein vollstaendiger Abgleich; wirft nie, das Ergebnis nennt den Fehler. Anderes `account`: Zuordnung und Cursor
    /// vergessen (lokale Daten bleiben).
    public func run(account: String) async -> DeviceSyncResult {
        let core = DeviceSyncCore(device: device)
        do {
            try await database.transaction { c in
                try DeviceSyncSchema.ensure(c)
                if try DeviceSyncCore.state(c, "account") != account {
                    for t in ["sync_link_map", "sync_link_state", "sync_link_pending"] { try c.execute("DELETE FROM \(t)") }
                    try DeviceSyncCore.setState(c, "account", account)
                }
            }
            try await pull(core)
            try await push(core)
            for _ in 0..<2 where core.retryNotes {
                core.retryNotes = false
                try await push(core)
            }
            try await pull(core)
        } catch let e as AccountError {
            core.stats.ok = false
            core.stats.error = e.message
        } catch {
            core.stats.ok = false
            core.stats.error = "Abgleich fehlgeschlagen: \(error.localizedDescription)"
        }
        return core.stats
    }

    private func pull(_ core: DeviceSyncCore) async throws {
        var cursor = try await database.transaction { try DeviceSyncCore.state($0, "cursor") }
        for _ in 0..<200 {
            var q = "limit=\(DeviceSyncCore.page)&device_id=\(Self.escaped(device))"
            if let cursor { q += "&since=\(Self.escaped(cursor))" }
            let d = try await transport.syncChanges(query: q)
            let before = cursor
            cursor = d["cursor"]?.string ?? before
            let next = cursor
            try await database.transaction { c in
                try core.applyPage(c, d, cursor: next)
            }
            if d["has_more"]?.bool != true { break }
        }
    }

    private func push(_ core: DeviceSyncCore) async throws {
        let (items, deletes) = try await database.transaction { try core.collect($0) }
        let mark = try await database.transaction { try DeviceSyncCore.state($0, "tomb_mark") } ?? ""
        let tombMark = (deletes.map(\.deletedAt) + [mark]).max() ?? ""
        if items.isEmpty && deletes.isEmpty {
            try await database.transaction { try core.advanceTombMark($0) }
            return
        }
        // Neue Zeilen (negative IDs) mit ihren Kindern immer in einer Sendung; nur reine Aenderungen werden geteilt
        var batches: [[DeviceSyncCore.PushItem]] = [items]
        if !items.contains(where: { $0.body["local_id"]?.double != nil }) {
            batches = stride(from: 0, to: items.count, by: DeviceSyncCore.pushBatch).map { Array(items[$0..<min($0 + DeviceSyncCore.pushBatch, items.count)]) }
            if batches.isEmpty { batches = [[]] }
        }
        for (i, batch) in batches.enumerated() {
            let last = i == batches.count - 1
            let body: JSONValue = .object(["device_id": .string(device), "items": .array(batch.map { .object($0.body) }),
                                           "deletes": .array(last ? deletes.map(\.body) : [])])
            let res = try await transport.syncPush(body)
            try await database.transaction { c in
                try core.handleResults(c, batch, last ? deletes : [], res)
            }
        }
        try await database.transaction { c in
            try DeviceSyncCore.setState(c, "tomb_mark", tombMark)
            try core.advanceTombMark(c)
        }
    }

    private static func escaped(_ s: String) -> String {
        var ok = CharacterSet.urlQueryAllowed
        ok.remove(charactersIn: "&=+")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }
}

/// Der synchrone Teil von `sync_client.Client`; nur aus `DeviceSync` (Actor) heraus, nacheinander benutzt
final class DeviceSyncCore: @unchecked Sendable {
    typealias Row = [String: JSONValue]

    struct PushItem: Sendable {
        var body: Row
        let table: String
        let local: String
    }

    struct PushDelete: Sendable {
        let body: JSONValue
        let table: String
        let id: String
        let deletedAt: String
    }

    static let appliedDevice = "~dienst"
    static let page = 2000
    static let pushBatch = 400
    static let localSettings: Set<String> = ["lan_pin", "university", "demo_content", "semester_rule_applied", "pen_input"]
    static let localColumns: [String: Set<String>] = ["study_tasks": ["test_id"]]
    /// NOT NULL in der Datenbank: ohne Elternteil wartet die Zeile
    static let requiredParents: Set<String> = ["package_id", "event_id"]

    let device: String
    var retryNotes = false
    var stats = DeviceSyncResult()
    private var keyIndex: [String: [String: String]] = [:]

    init(device: String) { self.device = device }

    // MARK: Hilfen

    static func state(_ c: SQLiteConnection, _ key: String) throws -> String? {
        try c.queryOne("SELECT value FROM sync_link_state WHERE key=?", [.text(key)])?["value"]?.string
    }

    static func setState(_ c: SQLiteConnection, _ key: String, _ value: String?) throws {
        try c.execute("INSERT INTO sync_link_state(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      [.text(key), value.map(SQLiteValue.text) ?? .null])
    }

    static func entity(_ table: String) -> DeviceSyncSchema.Entity? { DeviceSyncSchema.entities.first { $0.name == table } }

    private func meta(_ table: String) -> DeviceSyncSchema.Entity { Self.entity(table)! }

    /// `_setting_local`: nie zwischen Geraeten
    static func settingIsLocal(_ key: String) -> Bool {
        localSettings.contains(key) || key.range(of: "token|secret|passw|pin$|_path$|_dir$|service", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `str(v)` fuer IDs: Zahlen ohne Nachkommastellen
    static func text(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?: return s
        case .number(let n)?: return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b)?: return b ? "True" : "False"
        default: return nil
        }
    }

    private static func norm(_ v: JSONValue?) -> String {
        (text(v) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sql(_ v: JSONValue?) -> SQLiteValue {
        switch v {
        case nil, .null?: return .null
        case .bool(let b)?: return .integer(b ? 1 : 0)
        case .number(let n)?: return n == n.rounded() && abs(n) < 9e15 ? .integer(Int64(n)) : .real(n)
        case .string(let s)?: return .text(s)
        case .some(let other): return .text(other.jsonString())
        }
    }

    private func cols(_ c: SQLiteConnection, _ table: String) throws -> [String] {
        try c.columnNames(table).filter { !DeviceSyncSchema.syncColumns.contains($0) }
    }

    private func pkValue(_ table: String, _ local: String) -> SQLiteValue {
        meta(table).intPK ? (Int64(local).map(SQLiteValue.integer) ?? .null) : .text(local)
    }

    private func now(_ c: SQLiteConnection) throws -> String {
        try c.scalar("SELECT \(DeviceSyncSchema.nowSQL)")?.string ?? ""
    }

    private func nowISO(_ c: SQLiteConnection) throws -> String {
        try c.scalar("SELECT strftime('%Y-%m-%dT%H:%M:%S','now','localtime')")?.string ?? ""
    }

    /// `natural_key`: fachlicher Schluessel (Fremdschluessel als lokale IDs), nil = kein Abgleich ueber Inhalt
    func naturalKey(_ table: String, _ row: Row, _ fk: Row = [:]) -> String? {
        func f(_ col: String) -> JSONValue? { fk[col] ?? row[col] }
        func id(_ v: JSONValue?) -> String { Self.text(v) ?? "" }
        let parts: [String]
        switch table {
        case "modules": parts = [Self.norm(row["name"]), Self.norm(row["semester"])]
        case "folders": parts = [Self.norm(row["name"]), id(f("parent_id")), id(f("module_id"))]
        case "course_events":
            let course = Self.norm(row["course_id"])
            parts = [course.isEmpty ? Self.norm(row["title"]) : course, id(row["weekday"]), id(row["start_time"]), id(row["end_time"]),
                     Self.norm(row["date_from"]), Self.norm(row["kind"])]
        case "event_exceptions": parts = [id(f("event_id")), id(row["date"]), Self.norm(row["type"])]
        case "study_packages":
            let title = row["title"].flatMap { $0 == .null || $0 == .string("") ? nil : $0 } ?? row["subject"]
            parts = [id(row["date"]), id(f("module_id")), Self.norm(title)]
        case "study_tasks": parts = [id(f("package_id")), Self.norm(row["type"]), Self.norm(row["title"]), Self.norm(row["file_id"])]
        case "flashcards": parts = [Self.norm(row["question"]), Self.norm(row["file_id"])]
        default: return nil
        }
        return parts.joined(separator: "\u{1f}")
    }

    // MARK: Zuordnung

    private func localOf(_ c: SQLiteConnection, _ table: String, _ remote: String) throws -> String? {
        try c.queryOne("SELECT local_id FROM sync_link_map WHERE entity=? AND remote_id=?", [.text(table), .text(remote)])?["local_id"]?.string
    }

    private func map(_ c: SQLiteConnection, _ table: String, remote: String) throws -> Row? {
        try c.rows("SELECT * FROM sync_link_map WHERE entity=? AND remote_id=?", [.text(table), .text(remote)]).first
    }

    private func map(_ c: SQLiteConnection, _ table: String, local: String) throws -> Row? {
        try c.rows("SELECT * FROM sync_link_map WHERE entity=? AND local_id=? ORDER BY rowid LIMIT 1", [.text(table), .text(local)]).first
    }

    private func setMap(_ c: SQLiteConnection, _ table: String, remote: String, local: String, remoteVersion: Int?, localVersion: Int?, base: String? = nil) throws {
        try c.execute("""
            INSERT INTO sync_link_map(entity, remote_id, local_id, remote_version, local_version, base) VALUES (?,?,?,?,?,?)
            ON CONFLICT(entity, remote_id) DO UPDATE SET local_id=excluded.local_id, remote_version=excluded.remote_version,
            local_version=excluded.local_version, base=excluded.base
            """, [.text(table), .text(remote), .text(local), remoteVersion.map { .integer(Int64($0)) } ?? .null,
                  localVersion.map { .integer(Int64($0)) } ?? .null, base.map(SQLiteValue.text) ?? .null])
    }

    private func localRow(_ c: SQLiteConnection, _ table: String, _ local: String) throws -> Row? {
        try c.rows("SELECT * FROM \(table) WHERE \(meta(table).pk)=?", [pkValue(table, local)]).first
    }

    private func wait(_ c: SQLiteConnection, _ table: String, _ remote: String, _ row: Row, _ reason: String) throws {
        try c.execute("INSERT OR REPLACE INTO sync_link_pending(entity, remote_id, payload, reason) VALUES (?,?,?,?)",
                      [.text(table), .text(remote), .text(JSONValue.object(row).jsonString()), .text(reason)])
    }

    // MARK: Abrufen und anwenden

    func applyPage(_ c: SQLiteConnection, _ d: JSONValue, cursor: String?) throws {
        let mark = try now(c)
        for e in DeviceSyncSchema.entities {
            for row in d["changes"]?[e.name]?.array ?? [] {
                guard let r = row.object else { continue }
                stats.pulled += 1
                if try applyRow(c, e.name, r) == "applied" { stats.applied += 1 }
            }
        }
        for t in d["tombstones"]?.array ?? [] { try applyTombstone(c, t) }
        try retryPending(c)
        try markAppliedTombstones(c, mark)
        try Self.setState(c, "cursor", cursor)
    }

    /// `remote_fk_to_local`: (Werte, fehlender Pflicht-Elternteil oder nil)
    private func remoteFKToLocal(_ c: SQLiteConnection, _ table: String, _ row: Row) throws -> (Row, String?) {
        var out: Row = [:]
        for (col, target) in meta(table).fk {
            guard let v = Self.text(row[col]) else { continue }
            guard let lid = try localOf(c, target, v) else {
                if Self.requiredParents.contains(col) { return (out, "\(target) \(v) fehlt hier") }
                out[col] = .null
                continue
            }
            out[col] = Int64(lid).map { .number(Double($0)) } ?? .null
        }
        return (out, nil)
    }

    /// `apply_row`: applied | skipped | pending | own
    @discardableResult
    func applyRow(_ c: SQLiteConnection, _ table: String, _ row: Row) throws -> String {
        let pk = meta(table).pk
        guard let rid = Self.text(row[pk]) else { return "skipped" }
        if table == "settings" && Self.settingIsLocal(rid) { return "skipped" }
        if table == "annotations" { return try applyAnnotation(c, row) }
        let (fk, missing) = try remoteFKToLocal(c, table, row)
        if let missing {
            try wait(c, table, rid, row, missing)
            return "pending"
        }
        let skip = Self.localColumns[table] ?? []
        let columns = try cols(c, table).filter { $0 != pk && row[$0] != nil && !skip.contains($0) }
        var vals: Row = [:]
        for col in columns { vals[col] = fk[col] ?? row[col] }
        let rv = row["sync_version"]?.int ?? 1
        let stamp = try row["sync_updated_at"]?.string ?? now(c)
        var lid = try localOf(c, table, rid)
        if lid == nil, table == "settings", try localRow(c, table, rid) != nil { lid = rid }
        if lid == nil, let nk = naturalKey(table, row, fk) { lid = try findByKey(c, table, nk) }
        if let found = lid {
            let cur = try localRow(c, table, found)
            let m = try map(c, table, remote: rid)
            if let cur {
                let dirty = m != nil && cur["sync_version"]?.int != m?["local_version"]?.int
                if m == nil {
                    // erster Abgleich mit gleicher Zeile: der spaetere Stand gewinnt; bei Einstellungen schlaegt ein
                    // geaenderter Wert immer den Standardwert
                    var newerHere = (cur["sync_updated_at"]?.string ?? "") > (row["sync_updated_at"]?.string ?? "")
                    if table == "settings", let def = Migrations.defaultSettings.first(where: { $0.key == rid })?.value {
                        let remote = Self.text(row["value"]), here = Self.text(cur["value"])
                        if remote == def && here != def { newerHere = true } else if here == def && remote != def { newerHere = false }
                    }
                    if newerHere {
                        try setMap(c, table, remote: rid, local: found, remoteVersion: rv, localVersion: -1)
                        return "skipped"
                    }
                } else if dirty {
                    return "skipped"                            // lokal geaendert: der Dienst fuehrt beim Senden zusammen
                } else if m?["remote_version"]?.int == rv, row["sync_device"]?.string == device {
                    return "own"
                }
                let changed = vals.filter { (cur[$0.key] ?? .null) != $0.value }
                let nv = (cur["sync_version"]?.int ?? 1) + 1
                let names = changed.keys.sorted()
                let sets = names.map { "\($0)=?, " }.joined()
                try c.execute("UPDATE \(table) SET \(sets)sync_version=?, sync_updated_at=?, sync_device=? WHERE \(pk)=?",
                              names.map { Self.sql(changed[$0]) } + [.integer(Int64(nv)), .text(stamp), .text(Self.appliedDevice), pkValue(table, found)])
                try setMap(c, table, remote: rid, local: found, remoteVersion: rv, localVersion: nv)
                return "applied"
            }
            if m != nil { return "skipped" }                    // hier geloescht, das Senden entscheidet
        }
        // neu hier
        var data = vals
        if !meta(table).intPK { data[pk] = .string(rid) }
        data["sync_version"] = .number(1)
        data["sync_updated_at"] = .string(stamp)
        data["sync_device"] = .string(Self.appliedDevice)
        let keys = data.keys.sorted()
        try c.execute("INSERT INTO \(table)(\(keys.joined(separator: ","))) VALUES (\(keys.map { _ in "?" }.joined(separator: ",")))",
                      keys.map { Self.sql(data[$0]) })
        let newID = meta(table).intPK ? String(c.lastInsertRowID) : rid
        try setMap(c, table, remote: rid, local: newID, remoteVersion: rv, localVersion: 1)
        var stored = data
        stored[pk] = meta(table).intPK ? .number(Double(c.lastInsertRowID)) : .string(rid)
        if let nk = naturalKey(table, stored), keyIndex[table] != nil, keyIndex[table]?[nk] == nil { keyIndex[table]?[nk] = newID }
        return "applied"
    }

    private func findByKey(_ c: SQLiteConnection, _ table: String, _ nk: String) throws -> String? {
        if keyIndex[table] == nil {
            let pk = meta(table).pk
            var idx: [String: String] = [:]
            for r in try c.rows("SELECT * FROM \(table) ORDER BY \(pk)") {
                if let k = naturalKey(table, r), let id = Self.text(r[pk]), idx[k] == nil { idx[k] = id }
            }
            keyIndex[table] = idx
        }
        return keyIndex[table]?[nk]
    }

    private static func parsed(_ v: JSONValue?) -> JSONValue {
        if case .string(let s)? = v { return (try? JSONValue.parse(s)) ?? .object([:]) }
        return v ?? .object([:])
    }

    private func applyAnnotation(_ c: SQLiteConnection, _ row: Row) throws -> String {
        guard let fid = Self.text(row["file_id"]) else { return "skipped" }
        let remote = Self.parsed(row["data"])
        let rv = row["version"]?.int ?? row["sync_version"]?.int ?? 1
        guard try c.queryOne("SELECT 1 FROM files WHERE id=?", [.text(fid)]) != nil else {
            try wait(c, "annotations", fid, row, "Datei hier noch nicht geladen")
            return "pending"
        }
        let cur = try c.rows("SELECT * FROM annotations WHERE file_id=?", [.text(fid)]).first
        let m = try map(c, "annotations", remote: fid)
        let rtxt = remote.jsonString()
        let stamp = try row["sync_updated_at"]?.string ?? now(c)
        guard let cur else {
            try c.execute("INSERT INTO annotations(file_id, data, updated_at, version, sync_version, sync_updated_at, sync_device) VALUES (?,?,?,?,?,?,?)",
                          [.text(fid), .text(rtxt), .text(try nowISO(c)), .integer(1), .integer(1), .text(stamp), .text(Self.appliedDevice)])
            try setMap(c, "annotations", remote: fid, local: fid, remoteVersion: rv, localVersion: 1, base: rtxt)
            return "applied"
        }
        let dirty = m == nil || cur["sync_version"]?.int != m?["local_version"]?.int
        if m != nil, m?["remote_version"]?.int == rv, !dirty { return "own" }
        var doc = remote
        var merged = false
        if dirty {
            let base = m?["base"]?.string.flatMap { try? JSONValue.parse($0) }
            let r = AnnotationMerge.mergeDocument(base: base, local: Self.parsed(cur["data"]), server: remote)
            doc = r.doc
            merged = true
            stats.conflicts += r.conflicts
            stats.notesMerged += 1
        }
        let nv = (cur["sync_version"]?.int ?? 1) + 1
        try c.execute("UPDATE annotations SET data=?, updated_at=?, version=COALESCE(version,1)+1, sync_version=?, sync_updated_at=?, sync_device=? WHERE file_id=?",
                      [.text(doc.jsonString()), .text(try nowISO(c)), .integer(Int64(nv)), .text(stamp), .text(Self.appliedDevice), .text(fid)])
        // zusammengefuehrt: lokal noch nicht im Dienst -> beim Senden mit base_version = rv
        let unsent = merged && doc != remote
        try setMap(c, "annotations", remote: fid, local: fid, remoteVersion: rv, localVersion: unsent ? -1 : nv, base: rtxt)
        return "applied"
    }

    private func applyTombstone(_ c: SQLiteConnection, _ t: JSONValue) throws {
        guard let table = t["entity"]?.string, Self.entity(table) != nil, table != "annotations",
              let rid = Self.text(t["entity_id"]) else { return }
        let lid = try localOf(c, table, rid)
        try c.execute("DELETE FROM sync_link_pending WHERE entity=? AND remote_id=?", [.text(table), .text(rid)])
        guard let lid else { return }
        let cur = try localRow(c, table, lid)
        let m = try map(c, table, remote: rid)
        try c.execute("DELETE FROM sync_link_map WHERE entity=? AND remote_id=?", [.text(table), .text(rid)])
        let others = try c.queryOne("SELECT 1 FROM sync_link_map WHERE entity=? AND local_id=?", [.text(table), .text(lid)])
        guard let cur, others == nil else { return }
        if m != nil, cur["sync_version"]?.int != m?["local_version"]?.int { return }   // hier geaendert: wird neu gesendet
        try c.execute("DELETE FROM \(table) WHERE \(meta(table).pk)=?", [pkValue(table, lid)])
        stats.deleted += 1
    }

    private func retryPending(_ c: SQLiteConnection) throws {
        for p in try c.rows("SELECT * FROM sync_link_pending ORDER BY rowid") {
            guard let table = p["entity"]?.string, let rid = p["remote_id"]?.string, let text = p["payload"]?.string,
                  let row = (try? JSONValue.parse(text))?.object else { continue }
            try c.execute("DELETE FROM sync_link_pending WHERE entity=? AND remote_id=?", [.text(table), .text(rid)])
            if try applyRow(c, table, row) == "applied" { stats.applied += 1 }
        }
        stats.pending = try c.scalar("SELECT COUNT(*) FROM sync_link_pending")?.int ?? 0
    }

    /// Tombstones, die beim Anwenden entstanden (auch durch ON DELETE CASCADE), gehoeren dem Dienst
    private func markAppliedTombstones(_ c: SQLiteConnection, _ mark: String) throws {
        try c.execute("UPDATE sync_tombstones SET device=? WHERE device IS NULL AND deleted_at >= ?", [.text(Self.appliedDevice), .text(mark)])
    }

    // MARK: Senden

    private func fileInfo(_ c: SQLiteConnection, _ fid: String) throws -> JSONValue? {
        guard let f = try c.rows("SELECT f.id, f.name, f.mime, f.course_id, c.title AS course_title, c.semester FROM files f LEFT JOIN courses c ON c.id=f.course_id WHERE f.id=?", [.text(fid)]).first,
              f["course_id"]?.string != "__user__" else { return nil }
        let title = f["course_title"]?.string ?? ""
        return .object(["name": f["name"] ?? .null, "mime": f["mime"] ?? .null, "course_id": f["course_id"] ?? .null,
                        "course_title": title.isEmpty ? (f["course_id"] ?? .null) : .string(title), "semester": f["semester"] ?? .null])
    }

    func collect(_ c: SQLiteConnection) throws -> ([PushItem], [PushDelete]) {
        var items: [PushItem] = [], deletes: [PushDelete] = []
        var neg: [String: Int64] = [:]
        for e in DeviceSyncSchema.entities {
            let table = e.name
            let columns = try cols(c, table).filter { $0 != e.pk && !(Self.localColumns[table] ?? []).contains($0) }
            rows: for r in try c.rows("SELECT * FROM \(table)") {
                guard let lid = Self.text(r[e.pk]) else { continue }
                if table == "settings" && Self.settingIsLocal(lid) { continue }
                var file: JSONValue?
                if table == "annotations" {
                    file = try fileInfo(c, lid)
                    if file == nil { continue }                 // eigene Dokumente gleichen spaeter ab
                }
                let m = try map(c, table, local: lid)
                if let m, m["local_version"]?.int == r["sync_version"]?.int { continue }
                if m == nil, r["sync_device"]?.string == Self.appliedDevice { continue }
                var data: Row = [:]
                if table == "annotations" {
                    data = Self.parsed(r["data"]).object ?? [:]
                } else {
                    for col in columns { data[col] = r[col] ?? .null }
                    for (col, target) in e.fk {
                        guard let v = Self.text(data[col]) else { continue }
                        if let remote = try map(c, target, local: v)?["remote_id"]?.string, let id = Int64(remote) {
                            data[col] = .number(Double(id))
                        } else if let n = neg["\(target)|\(v)"] {
                            data[col] = .number(Double(n))
                        } else if Self.requiredParents.contains(col) {
                            continue rows                       // Elternteil noch nicht im Dienst: naechster Lauf
                        } else {
                            data[col] = .null
                        }
                    }
                }
                let version = Self.text(r["sync_version"]) ?? "None"
                var it: Row = ["entity": .string(table), "data": .object(data), "op_id": .string(String("\(device).\(table).\(lid).\(version)".prefix(100)))]
                it["updated_at"] = .string(try r["sync_updated_at"]?.string ?? now(c))
                if table == "annotations" {
                    it["id"] = .string(lid)
                    it["base_version"] = m?["remote_version"] ?? .null
                    it["file"] = file
                } else if let m {
                    let remote = m["remote_id"]?.string ?? ""
                    it["id"] = e.intPK ? (Int64(remote).map { .number(Double($0)) } ?? .null) : .string(remote)
                    let rv = m["remote_version"]?.int ?? 0
                    it["base_version"] = rv > 0 ? .number(Double(rv)) : .null
                } else if e.intPK, let n = Int64(lid) {
                    it["local_id"] = .number(Double(-n))
                    neg["\(table)|\(lid)"] = -n
                } else {
                    it["local_id"] = .string(lid)
                }
                items.append(PushItem(body: it, table: table, local: lid))
            }
        }
        let mark = try Self.state(c, "tomb_mark") ?? ""
        for t in try c.rows("SELECT * FROM sync_tombstones WHERE device IS NULL AND deleted_at > ? ORDER BY deleted_at", [.text(mark)]) {
            guard let table = t["entity"]?.string, let e = Self.entity(table), table != "annotations",
                  let lid = t["entity_id"]?.string, let at = t["deleted_at"]?.string else { continue }
            for m in try c.rows("SELECT remote_id FROM sync_link_map WHERE entity=? AND local_id=?", [.text(table), .text(lid)]) {
                guard let remote = m["remote_id"]?.string else { continue }
                let id: JSONValue = e.intPK ? (Int64(remote).map { .number(Double($0)) } ?? .null) : .string(remote)
                deletes.append(PushDelete(body: ["entity": .string(table), "id": id, "deleted_at": .string(at)], table: table, id: remote, deletedAt: at))
            }
        }
        return (items, deletes)
    }

    func advanceTombMark(_ c: SQLiteConnection) throws {
        let cur = try Self.state(c, "tomb_mark") ?? ""
        // Tombstones ohne Zuordnung (nie im Dienst) muessen nicht gesendet werden
        guard let top = try c.scalar("SELECT MAX(deleted_at) FROM sync_tombstones WHERE device IS NULL")?.string, top > cur else { return }
        let unsent = try c.queryOne("""
            SELECT 1 FROM sync_tombstones t JOIN sync_link_map m ON m.entity=t.entity AND m.local_id=t.entity_id
            WHERE t.device IS NULL AND t.deleted_at > ? LIMIT 1
            """, [.text(cur)])
        if unsent == nil { try Self.setState(c, "tomb_mark", top) }
    }

    func handleResults(_ c: SQLiteConnection, _ batch: [PushItem], _ deletes: [PushDelete], _ res: JSONValue) throws {
        var mapping: [String: JSONValue] = [:]
        for m in res["mapping"]?.array ?? [] {
            if let e = m["entity"]?.string, let l = Self.text(m["local_id"]) { mapping["\(e)|\(l)"] = m["id"] }
        }
        let results = res["results"]?.array ?? []
        var conflicts: [String: JSONValue] = [:]
        for x in res["conflicts"]?.array ?? [] {
            if let e = x["entity"]?.string, let i = Self.text(x["id"]) { conflicts["\(e)|\(i)"] = x }
        }
        for it in batch {
            let table = it.table, lid = it.local
            let itemLocal = Self.text(it.body["local_id"]), itemID = Self.text(it.body["id"])
            var r = results.first { v in
                guard v["entity"]?.string == table else { return false }
                if let itemLocal, Self.text(v["local_id"]) == itemLocal { return true }
                return itemID != nil && Self.text(v["id"]) == itemID && (table != "settings" || v["local_id"] == nil || v["local_id"] == .null)
            }
            if r == nil, table == "settings" {
                r = results.first { $0["entity"]?.string == "settings" && Self.text($0["id"]) == (itemLocal ?? itemID) }
            }
            guard let r else { continue }
            let st = r["status"]?.string
            let cur = try localRow(c, table, lid)
            let lv = cur?["sync_version"]?.int
            if st == "plan_required" {
                stats.planRequired = true
                continue
            }
            if table == "annotations" {
                try afterAnnotation(c, it, r, cur)
                continue
            }
            switch st {
            case "created", "applied", "resurrected":
                let remote = Self.text(r["id"]) ?? itemLocal.flatMap { Self.text(mapping["\(table)|\($0)"]) }
                guard let remote else { continue }
                try setMap(c, table, remote: remote, local: lid, remoteVersion: r["version"]?.int ?? 1, localVersion: lv)
                stats.pushed += 1
            case "conflict":
                guard let rid = Self.text(r["id"]) else { continue }
                let x = conflicts["\(table)|\(rid)"]
                stats.conflicts += 1
                try setMap(c, table, remote: rid, local: lid, remoteVersion: nil, localVersion: lv)
                // Ergebnis des Dienstes gleich hier uebernehmen (Felder, die der Dienst behalten hat)
                if cur != nil, var merged = x?["server"]?.object {
                    for f in x?["client_won"]?.array ?? [] {
                        if let name = f.string { merged[name] = x?["client"]?[name] ?? .null }
                    }
                    merged["sync_version"] = r["version"] ?? .null
                    merged[meta(table).pk] = r["id"] ?? .null
                    try applyRow(c, table, merged)
                }
            case "deleted":
                try c.execute("DELETE FROM sync_link_map WHERE entity=? AND local_id=?", [.text(table), .text(lid)])
                let mark = try now(c)
                try c.execute("DELETE FROM \(table) WHERE \(meta(table).pk)=?", [pkValue(table, lid)])
                try markAppliedTombstones(c, mark)
            case "error":
                stats.errors.append("\(table): \(Self.text(r["message"]) ?? "")")
            default: break
            }
        }
        for d in deletes {
            guard let r = results.first(where: { $0["entity"]?.string == d.table && Self.text($0["id"]) == d.id }) else { continue }
            let st = r["status"]?.string
            guard st == "deleted" || st == "edit_wins" else { continue }
            try c.execute("DELETE FROM sync_link_map WHERE entity=? AND remote_id=?", [.text(d.table), .text(d.id)])
            if st == "edit_wins", let server = conflicts["\(d.table)|\(d.id)"]?["server"]?.object {
                try applyRow(c, d.table, server)                // im Dienst geaendert: Zeile kommt zurueck
            }
        }
    }

    private func afterAnnotation(_ c: SQLiteConnection, _ it: PushItem, _ r: JSONValue, _ cur: Row?) throws {
        let fid = it.local
        let data = it.body["data"] ?? .object([:])
        switch r["status"]?.string {
        case "applied":
            try setMap(c, "annotations", remote: fid, local: fid, remoteVersion: r["version"]?.int, localVersion: cur?["sync_version"]?.int, base: data.jsonString())
            stats.pushed += 1
        case "conflict":
            guard let cur else { return }
            let base = try map(c, "annotations", remote: fid)?["base"]?.string.flatMap { try? JSONValue.parse($0) }
            let server = r["data"] ?? .object([:])
            let m = AnnotationMerge.mergeDocument(base: base, local: data, server: server)
            stats.conflicts += m.conflicts
            stats.notesMerged += 1
            let nv = (cur["sync_version"]?.int ?? 1) + 1
            try c.execute("UPDATE annotations SET data=?, updated_at=?, version=COALESCE(version,1)+1, sync_version=?, sync_device=NULL WHERE file_id=?",
                          [.text(m.doc.jsonString()), .text(try nowISO(c)), .integer(Int64(nv)), .text(fid)])
            // naechster Versuch mit der Version des Dienstes als Basis (`run` sendet im selben Lauf erneut)
            try setMap(c, "annotations", remote: fid, local: fid, remoteVersion: r["version"]?.int, localVersion: -1, base: server.jsonString())
            retryNotes = true
        case "unknown_file":
            stats.errors.append("Notizen zu \(fid): Datei im Dienst unbekannt")
        default: break
        }
    }
}
