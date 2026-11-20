import Foundation
import XCTest
@testable import UniFlowCore

/// Angemeldete Pruefungen im Geraeteabgleich (Entscheidung des Inhabers 20.11.2026 "Ja, abgleichen"; Python:
/// tests/test_exam_registrations_sync.py). Der eigene Abruf fuehrt ueber den fachlichen Schluessel zusammen statt die
/// Tabelle zu ersetzen; der Abgleich bringt die Zeilen auf die anderen Geraete, ohne Pruefer, Rohtext und Abrufzeit.
/// Alle Werte erfunden.
final class ExamRegistrationSyncTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-20T09:00:00")!
    private static let privateColumns = ["pruefer", "raw", "fetched_at"]

    private func reg(_ nr: String = "4711", _ text: String = "Rechnernetze", datum: String? = "01.03.2027", room: String = "HS A",
                     status: String = "AN") -> QISRegistration {
        QISRegistration(pruefungsnr: nr, text: text, semester: "WiSe 26/27", datum: datum, time: "09:00", room: room,
                        pruefer: "Prof. Dr. Erika Beispiel", versuch: "1", status: status, form: "Klausur",
                        abschluss: "Abschluss 82 Bachelor of Science", raw: "\(nr) | \(text) | Prof. Dr. Erika Beispiel")
    }

    private func database() async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0, clock: Self.clock) }
        return db
    }

    private func table(_ db: SQLiteDatabase) async throws -> [[String: JSONValue]] {
        try await db.withConnection { try $0.rows("SELECT * FROM exam_registrations ORDER BY id") }
    }

    private func tombstones(_ db: SQLiteDatabase) async throws -> Int {
        try await db.withConnection { c in
            guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE name='sync_tombstones'") != nil else { return 0 }
            return try c.scalar("SELECT COUNT(*) FROM sync_tombstones WHERE entity='exam_registrations'")?.int ?? 0
        }
    }

    private func store(_ db: SQLiteDatabase, _ rows: [QISRegistration], at: String) async throws {
        try await db.transaction { try QISRegistrationsSync.store($0, rows, now: at) }
        // Der Schein-Dienst antwortet ohne Netz in derselben Millisekunde. Eine Loeschmarke aus genau der Millisekunde,
        // in der der Abruf beginnt, gilt als vom Dienst angewendet (`markAppliedTombstones`, `deleted_at >= mark`, wie in
        // app/sync_client.py) und ginge nie an den Dienst; mit echtem Netz liegt immer mehr als 1 ms dazwischen.
        try await Task.sleep(nanoseconds: 3_000_000)
    }

    // MARK: eigener Abruf

    func testSecondFetchChangesNothing() async throws {
        let db = try await database()
        try await store(db, [reg(), reg("4712", "Datenbanken", datum: nil)], at: "2026-11-20T10:00:00")
        let before = try await table(db)
        try await store(db, [reg(), reg("4712", "Datenbanken", datum: nil)], at: "2026-11-21T10:00:00")
        let after = try await table(db)
        XCTAssertEqual(after, before, "gleicher Abruf: nichts neu geschrieben")
        XCTAssertEqual(after.map { $0["pruefer"]?.string }, ["Prof. Dr. Erika Beispiel", "Prof. Dr. Erika Beispiel"])
    }

    func testFetchUpdatesInsertsAndDeletesOnlyWhatChanged() async throws {
        let db = try await database()
        _ = try await db.transaction { try DeviceSyncSchema.ensure($0) }               // schon mit Konto abgeglichen
        try await store(db, [reg(), reg("4712", "Datenbanken", datum: nil), reg("4713", "Physik")], at: "2026-11-20T10:00:00")
        var ids: [String: Int] = [:]
        for r in try await table(db) { ids[r["pruefungsnr"]?.string ?? ""] = r["id"]?.int }
        try await store(db, [reg(room: "HS B"), reg("4712", "Datenbanken", datum: "12.02.2027"), reg("4714", "Mathematik I")],
                        at: "2026-11-21T10:00:00")
        var rows: [String: [String: JSONValue]] = [:]
        for r in try await table(db) { rows[r["pruefungsnr"]?.string ?? ""] = r }
        XCTAssertEqual(rows.keys.sorted(), ["4711", "4712", "4714"])
        XCTAssertEqual(rows["4711"]?["id"]?.int, ids["4711"])
        XCTAssertEqual(rows["4711"]?["room"]?.string, "HS B")
        XCTAssertEqual(rows["4712"]?["id"]?.int, ids["4712"], "nachgetragenes Datum: dieselbe Zeile")
        XCTAssertEqual(rows["4712"]?["datum"]?.string, "12.02.2027")
        XCTAssertFalse(ids.values.contains(rows["4714"]?["id"]?.int ?? -1))
        let tombs = try await tombstones(db)
        XCTAssertEqual(tombs, 1, "nur Physik hinterlaesst eine Loeschmarke")
    }

    /// Gleiche Regeln wie der Dienst (packages/shared-contracts/fixtures/sync/cases.json aus app/sync.py)
    func testEntitiesAndDeviceOnlyColumnsLikePython() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let rules = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/sync/cases.json")))["rules"]
        XCTAssertEqual(DeviceSyncSchema.entities.map(\.name), rules?["entities"]?.array?.compactMap(\.string))
        for (table, cols) in rules?["device_only_columns"]?.object ?? [:] {
            XCTAssertEqual(DeviceSyncCore.localColumns[table], Set(cols.array?.compactMap(\.string) ?? []), table)
        }
        XCTAssertEqual(rules?["natural_keys"]?["exam_registrations"]?.array?.compactMap(\.string), ["pruefungsnr", "text", "semester", "datum"])
    }

    /// Ergebnis im Status (20.11.2026 "Ja, aber ohne bestanden"): gleiche Faelle wie Python (cases.json)
    func testResultStatusLikePython() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let rules = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/sync/cases.json")))["rules"]
        let examples = rules?["result_status_examples"]?.object ?? [:]
        XCTAssertGreaterThan(examples.count, 10)
        for (status, want) in examples {
            XCTAssertEqual(QISRegistrationsSync.isResultStatus(status), want.bool, status)
        }
        XCTAssertEqual(rules?["device_only_values"]?["exam_registrations"]?.array?.compactMap(\.string), DeviceSyncCore.deviceOnlyValues["exam_registrations"])
    }

    func testKeyLikePython() {
        // `sync.natural_key`: Leerraum zusammengefasst, klein; Teile mit U+001F verbunden
        XCTAssertEqual(QISRegistrationsSync.key(pruefungsnr: " 4711", text: "Rechnernetze  I ", semester: "WiSe 26/27", datum: nil),
                       ["4711", "rechnernetze i", "wise 26/27", ""].joined(separator: "\u{1f}"))
    }

    private func examRegistration(_ db: SQLiteDatabase) async throws -> JSONValue {
        let backend = try LocalBackend(database: db, clock: Self.clock)
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/exam-registration"))
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.json)
    }

    // MARK: zwei Geraete an einem Schein-Dienst

    /// Dienst im Speicher mit den Regeln von app/sync.py, soweit die Anmeldungen sie brauchen: neue Zeile mit
    /// demselben fachlichen Schluessel wie eine vorhandene -> deren ID (`_same_row`); Spalten nur des Geraets werden
    /// nie gespeichert; merkt sich, ob ein Geraet sie trotzdem geschickt hat.
    private actor Service: DeviceSyncTransport {
        private(set) var rows: [Int: [String: JSONValue]] = [:]
        private var tombs: [[String: JSONValue]] = []
        private var nextID = 100
        private var tick = 0
        private(set) var sentPrivate: [String] = []
        /// Status je Pruefungsnummer, wie die Geraete ihn geschickt haben
        private(set) var sentStatus: [String: JSONValue] = [:]

        /// ein anderes Geraet aendert eine Zeile im Dienst
        func change(_ nr: String, _ fields: [String: JSONValue]) {
            guard let id = rows.first(where: { $0.value["pruefungsnr"]?.string == nr })?.key, var r = rows[id] else { return }
            for (k, v) in fields { r[k] = v }
            r["sync_version"] = .number(Double((r["sync_version"]?.int ?? 1) + 1))
            r["sync_updated_at"] = .string(stamp())
            r["sync_device"] = "anderes"
            rows[id] = r
        }
        private(set) var deletesSeen = 0

        private func stamp() -> String {
            tick += 1
            return String(format: "2026-11-20T08:%02d:%02d.000Z", tick / 60, tick % 60)
        }

        func syncChanges(query: String) async throws -> JSONValue {
            let since = URLComponents(string: "x?" + query)?.queryItems?.first { $0.name == "since" }?.value ?? ""
            let fresh = rows.values.filter { ($0["sync_updated_at"]?.string ?? "") > since }.sorted { ($0["id"]?.int ?? 0) < ($1["id"]?.int ?? 0) }
            let gone = tombs.filter { ($0["deleted_at"]?.string ?? "") > since }
            let cursor = (fresh.compactMap { $0["sync_updated_at"]?.string } + gone.compactMap { $0["deleted_at"]?.string } + [since]).max() ?? ""
            return ["cursor": cursor.isEmpty ? .null : .string(cursor),
                    "changes": fresh.isEmpty ? .object([:]) : .object(["exam_registrations": .array(fresh.map(JSONValue.object))]),
                    "tombstones": .array(gone.map(JSONValue.object)), "has_more": false]
        }

        private static func key(_ r: [String: JSONValue]) -> String {
            QISRegistrationsSync.key(pruefungsnr: r["pruefungsnr"]?.string, text: r["text"]?.string, semester: r["semester"]?.string,
                                     datum: r["datum"]?.string)
        }

        func syncPush(_ body: JSONValue) async throws -> JSONValue {
            let device = body["device_id"] ?? .null
            var results: [JSONValue] = [], mapping: [JSONValue] = []
            for it in body["items"]?.array ?? [] {
                guard let entity = it["entity"]?.string, var data = it["data"]?.object else { continue }
                guard entity == "exam_registrations" else {
                    results.append(["entity": .string(entity), "id": it["id"] ?? it["local_id"] ?? .null, "status": "ignored"])
                    continue
                }
                if let nr = data["pruefungsnr"]?.string { sentStatus[nr] = data["status"] ?? .null }
                for col in ExamRegistrationSyncTests.privateColumns where data[col] != nil {
                    sentPrivate.append(col)
                    data[col] = nil
                }
                data["sync_updated_at"] = .string(stamp())
                data["sync_device"] = device
                if let local = it["local_id"]?.int {
                    let id: Int
                    if let same = rows.first(where: { Self.key($0.value) == Self.key(data) })?.key {
                        id = same                                   // gleichzeitiger Abruf: dieselbe Zeile
                        data["sync_version"] = .number(Double((rows[id]?["sync_version"]?.int ?? 1) + 1))
                    } else {
                        nextID += 1
                        id = nextID
                        data["sync_version"] = 1
                    }
                    data["id"] = .number(Double(id))
                    rows[id] = data
                    results.append(["entity": "exam_registrations", "local_id": .number(Double(local)), "id": .number(Double(id)),
                                    "status": "created", "version": data["sync_version"] ?? 1])
                    mapping.append(["entity": "exam_registrations", "local_id": .number(Double(local)), "id": .number(Double(id))])
                } else if let id = it["id"]?.int {
                    guard let old = rows[id] else {
                        results.append(["entity": "exam_registrations", "id": .number(Double(id)), "status": "deleted"])
                        continue
                    }
                    let version = (old["sync_version"]?.int ?? 1) + 1
                    data["id"] = .number(Double(id))
                    data["sync_version"] = .number(Double(version))
                    rows[id] = data
                    results.append(["entity": "exam_registrations", "id": .number(Double(id)), "status": "applied", "version": .number(Double(version))])
                }
            }
            for d in body["deletes"]?.array ?? [] {
                guard let id = d["id"]?.int else { continue }
                deletesSeen += 1
                if rows.removeValue(forKey: id) != nil {
                    tombs.append(["entity": "exam_registrations", "entity_id": .string(String(id)), "deleted_at": .string(stamp()), "device": device])
                }
                results.append(["entity": "exam_registrations", "id": .number(Double(id)), "status": "deleted"])
            }
            return ["results": .array(results), "mapping": .array(mapping), "conflicts": .array([])]
        }
    }

    private func run(_ sync: DeviceSync, file: StaticString = #filePath, line: UInt = #line) async -> DeviceSyncResult {
        let r = await sync.run(account: "konto-1")
        XCTAssertTrue(r.ok, r.error ?? "", file: file, line: line)
        XCTAssertEqual(r.errors, [], file: file, line: line)
        return r
    }

    /// iPad liest das QIS; der Mac (ohne gespeichertes Passwort, Tabelle gibt es dort noch nicht) zeigt die Anmeldungen.
    /// Liest der Mac spaeter selbst, entsteht keine zweite Zeile; meldet sich die Studentin ab, verschwindet sie ueberall.
    func testOtherDeviceShowsRowsWithoutExaminerAndOwnFetchMerges() async throws {
        let service = Service()
        let ipadDB = try await database(), macDB = try await database()
        let ipad = DeviceSync(database: ipadDB, transport: service, device: "ipad", clock: Self.clock)
        let mac = DeviceSync(database: macDB, transport: service, device: "mac", clock: Self.clock)

        try await store(ipadDB, [reg(), reg("4712", "Datenbanken", datum: nil)], at: "2026-11-20T10:00:00")
        _ = await run(ipad)
        let inService = await service.rows.count
        let sentPrivate = await service.sentPrivate
        XCTAssertEqual(inService, 2)
        XCTAssertEqual(sentPrivate, [], "Pruefer, Rohtext und Abrufzeit verlassen das Geraet nie")

        let hasTable = try await macDB.withConnection { try QISRegistrationsSync.hasTable($0) }
        XCTAssertFalse(hasTable, "der Mac hat das QIS nie gelesen")
        _ = await run(mac)
        let seen = try await macDB.withConnection { try QISRegistrationsSync.rows($0) }
        XCTAssertEqual(seen.map(\.text), ["Rechnernetze", "Datenbanken"])
        XCTAssertEqual(seen.first?.room, "HS A")
        XCTAssertEqual(seen.first?.isoDate, "2027-03-01")
        XCTAssertTrue(seen.allSatisfy(\.registered))
        XCTAssertEqual(seen.map(\.pruefer), [nil, nil], "der Pruefer kommt nicht ueber den Abgleich")
        // Hinweis "Stand von deinem anderen Gerät": Zeit der letzten Aenderung im Dienst, als Ortszeit
        let macView = try await examRegistration(macDB)
        XCTAssertEqual(macView["registrations_checked_at"], .null)
        let syncedAt = try XCTUnwrap(macView["registrations_synced_at"]?.string)
        XCTAssertTrue(syncedAt.hasPrefix("2026-11-20T09:00:0"), syncedAt)                // 08:00 UTC = 09:00 in Berlin
        let ipadView = try await examRegistration(ipadDB)
        XCTAssertEqual(ipadView["registrations_synced_at"], .null, "selbst abgerufen: Anzeige wie bisher")

        // der Mac liest selbst (Schreibweise leicht anders) und findet dazu eine neue Pruefung
        try await store(macDB, [reg("4711", "Rechnernetze "), reg("4712", "Datenbanken", datum: nil), reg("4714", "Mathematik I")],
                        at: "2026-11-21T10:00:00")
        let macRows = try await table(macDB)
        XCTAssertEqual(macRows.count, 3)
        XCTAssertEqual(macRows.first?["pruefer"]?.string, "Prof. Dr. Erika Beispiel", "Pruefer nur lokal ergaenzt")
        let macTombs = try await tombstones(macDB)
        XCTAssertEqual(macTombs, 0)
        let ownSynced = try await macDB.withConnection { try QISRegistrationsSync.syncedAt($0) }
        XCTAssertNil(ownSynced, "nach dem eigenen Abruf kein Hinweis mehr")
        _ = await run(mac)
        _ = await run(ipad)
        let total = await service.rows.count
        let deletes = await service.deletesSeen
        XCTAssertEqual(total, 3, "keine Doppelten im Dienst")
        XCTAssertEqual(deletes, 0)
        let ipadRows = try await table(ipadDB)
        XCTAssertEqual(ipadRows.count, 3, "die neue Pruefung kam auch aufs iPad")

        // Abmeldung: das iPad liest, 4712 fehlt -> Loeschmarke -> auf dem Mac weg
        try await store(ipadDB, [reg(), reg("4714", "Mathematik I")], at: "2026-11-22T10:00:00")
        _ = await run(ipad)
        let deletes2 = await service.deletesSeen
        XCTAssertEqual(deletes2, 1, "Loeschmarke fuer 4712 ging an den Dienst")
        _ = await run(mac)
        let after = try await macDB.withConnection { try QISRegistrationsSync.rows($0) }
        XCTAssertEqual(after.compactMap(\.pruefungsnr).sorted(), ["4711", "4714"])
        let again = await run(mac)
        XCTAssertEqual([again.pushed, again.deleted], [0, 0], "danach Ruhe")
        let stillPrivate = await service.sentPrivate
        XCTAssertEqual(stillPrivate, [])
    }

    /// Das iPad liest "BE" (bestanden): der Status geht leer an den Dienst, "AN" der anderen Pruefung geht mit. Aendert ein
    /// anderes Geraet die Zeile (Raum, Status "AN"), kommt der Raum an und das eigene Ergebnis bleibt.
    func testResultStatusStaysOnTheDevice() async throws {
        let service = Service()
        let ipadDB = try await database()
        let ipad = DeviceSync(database: ipadDB, transport: service, device: "ipad", clock: Self.clock)
        try await store(ipadDB, [reg(status: "BE"), reg("4712", "Datenbanken", status: "AN")], at: "2026-11-20T10:00:00")
        _ = await run(ipad)
        let sent = await service.sentStatus
        XCTAssertEqual(sent, ["4711": .null, "4712": "AN"])
        await service.change("4711", ["room": "HS C", "status": "AN"])
        _ = await run(ipad)
        let row = try await table(ipadDB).first { $0["pruefungsnr"]?.string == "4711" }
        XCTAssertEqual(row?["room"]?.string, "HS C", "Aenderung des anderen Geraets kommt an")
        XCTAssertEqual(row?["status"]?.string, "BE", "das eigene Ergebnis bleibt")
        // ein Ergebnis aus dem Dienst (aeltere App) wird nicht uebernommen
        await service.change("4712", ["status": "nicht bestanden"])
        _ = await run(ipad)
        let other = try await table(ipadDB).first { $0["pruefungsnr"]?.string == "4712" }
        XCTAssertEqual(other?["status"], .null)
    }

    /// Beide Geraete lesen dieselbe Pruefung, bevor sie die Zeile des anderen kennen: der Dienst ordnet die zweite der
    /// ersten zu, beide Geraete behalten eine Zeile.
    func testSimultaneousFetchOnTwoDevicesGivesOneRow() async throws {
        let service = Service()
        let ipadDB = try await database(), iphoneDB = try await database()
        let ipad = DeviceSync(database: ipadDB, transport: service, device: "ipad", clock: Self.clock)
        let iphone = DeviceSync(database: iphoneDB, transport: service, device: "iphone", clock: Self.clock)
        try await store(ipadDB, [reg()], at: "2026-11-20T10:00:00")
        try await store(iphoneDB, [reg()], at: "2026-11-20T10:00:01")
        _ = await run(ipad)
        _ = await run(iphone)
        _ = await run(ipad)
        let total = await service.rows.count
        XCTAssertEqual(total, 1)
        for db in [ipadDB, iphoneDB] {
            let n = try await table(db).count
            XCTAssertEqual(n, 1)
        }
    }
}
