import Foundation
import XCTest
@testable import UniFlowCore

/// Zwei Geraete eines Kontos planen dieselbe Woche: die automatischen Lernpakete gibt es danach nur einmal
/// (`StudyPlanMerge`, app/plan_merge.py, docs/PLANER-KEINE-DOPPELPLANUNG.md). Fehler vom echten iPhone vom 14.11.2026:
/// an einem Tag vier Pakete, dieselbe Datei in zwei Paketen, ein Teil lokal erzeugt, ein Teil ueber den Abgleich gekommen.
///
/// - Regeln an der gemeinsamen Abgleichsdatei plan-merge.json (tools/gen-plan-merge-fixture.py, Python: tests/test_plan_merge.py)
/// - Ursache und Loesung mit zwei simulierten Geraeten an einem Schein-Dienst (gleiches Protokoll wie der Dienst:
///   neue Zeilen bekommen eine Nummer, Aenderungen eine Version, Loeschungen eine Loeschmarke). Alle Werte erfunden.
final class StudyPlanMergeTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-16T09:00:00")!      // Montag
    private static let wed = "2026-11-18", thu = "2026-11-19"
    private static let file = "studip-datei-0001"

    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/plan-merge.json")))
    }

    private static let packagesSQL = """
        SELECT id, date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time,
        source, locked, manual FROM study_packages ORDER BY id
        """
    private static let tasksSQL = """
        SELECT id, package_id, type, file_id, title, sort, est_minutes, actual_minutes, status, done_at, moved_from, start_time, end_time,
        page_from, page_to, steps_done FROM study_tasks ORDER BY id
        """

    private func tables(_ c: SQLiteConnection) throws -> (JSONValue, JSONValue, JSONValue) {
        let tomb = try c.query("SELECT entity, entity_id FROM sync_tombstones ORDER BY entity, CAST(entity_id AS INTEGER)")
            .map { JSONValue.array([.string($0["entity"]?.string ?? ""), .string($0["entity_id"]?.string ?? "")]) }
        return (.array(try c.rows(Self.packagesSQL).map(JSONValue.object)), .array(try c.rows(Self.tasksSQL).map(JSONValue.object)), .array(tomb))
    }

    // MARK: gemeinsame Abgleichsdatei

    /// Jeder Fall: dieselben Zeilen wie in Python anlegen, zusammenfuehren, Ergebnis und Tabellen exakt gleich; ein zweiter
    /// Lauf aendert nichts
    func testEveryCaseMatchesPython() async throws {
        let fx = try fixture()
        let cases = fx["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 17)
        let today = try XCTUnwrap(BerlinClock.parseISODate(XCTUnwrap(fx["today"]?.string)))
        let setup = (fx["setup"]?.array ?? []).compactMap(\.string)
        for x in cases {
            let name = x["name"]?.string ?? "?"
            let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
            let seed = setup + (x["seed"]?.array ?? []).compactMap(\.string)
            try await db.withConnection { try Migrations.migrate($0) }
            let (first, after, again, same) = try await db.transaction { c -> (JSONValue, (JSONValue, JSONValue, JSONValue), JSONValue, Bool) in
                try DeviceSyncSchema.ensure(c)
                for sql in seed { try c.execute(sql) }
                let first = try StudyPlanMerge.afterPull(c, today: today).json
                let after = try self.tables(c)
                let again = try StudyPlanMerge.afterPull(c, today: today).json
                let second = try self.tables(c)
                return (first, after, again, after.0 == second.0 && after.1 == second.1 && after.2 == second.2)
            }
            XCTAssertNil(jsonDiff(first, x["result"]), "\(name): Ergebnis \(jsonDiff(first, x["result"]) ?? "")")
            XCTAssertNil(jsonDiff(after.0, x["study_packages"]), "\(name): Pakete \(jsonDiff(after.0, x["study_packages"]) ?? "")")
            XCTAssertNil(jsonDiff(after.1, x["study_tasks"]), "\(name): Aufgaben \(jsonDiff(after.1, x["study_tasks"]) ?? "")")
            XCTAssertNil(jsonDiff(after.2, x["tombstones"]), "\(name): Loeschmarken \(jsonDiff(after.2, x["tombstones"]) ?? "")")
            XCTAssertNil(jsonDiff(again, x["again"]), "\(name): zweiter Lauf \(jsonDiff(again, x["again"]) ?? "")")
            XCTAssertTrue(same, "\(name): der zweite Lauf aendert nichts")
        }
    }

    func testSlotsAndMaterialRulesLikePython() {
        typealias M = StudyPlanMerge
        let whole = M.slot(title: "Skript.pdf", pageFrom: nil, pageTo: nil)
        let part = M.slot(title: "Skript.pdf (Teil 2/3)", pageFrom: nil, pageTo: nil)
        let rest = M.slot(title: "Skript.pdf · S. 30–60", pageFrom: nil, pageTo: nil)
        let sec = M.slot(title: "1 Signale · S. 4–9", pageFrom: 4, pageTo: 9)
        XCTAssertEqual(whole, M.Slot())
        XCTAssertEqual(part, M.Slot(part: 2, parts: 3))
        XCTAssertEqual(rest, M.Slot(from: 30, to: 60))
        XCTAssertEqual(sec, M.Slot(from: 4, to: 9, outline: true))
        XCTAssertEqual(M.slot(title: "Skript.pdf · S. 30–60 (Teil 1/2)", pageFrom: nil, pageTo: nil), M.Slot(from: 30, to: 60, part: 1, parts: 2))
        XCTAssertEqual(M.slot(title: "Blatt · S. 7", pageFrom: nil, pageTo: nil), M.Slot(from: 7, to: 7))
        XCTAssertTrue(M.sameMaterial(whole, whole) && M.sameMaterial(whole, sec) && M.sameMaterial(part, whole))
        XCTAssertFalse(M.sameMaterial(part, M.slot(title: "x (Teil 1/3)", pageFrom: nil, pageTo: nil)))
        XCTAssertTrue(M.sameMaterial(part, M.slot(title: "x (Teil 2/2)", pageFrom: nil, pageTo: nil)))
        XCTAssertFalse(M.sameMaterial(sec, M.slot(title: "2 · S. 9–20", pageFrom: 9, pageTo: 20)), "Abschnitte teilen sich eine Seite: bleiben")
        XCTAssertFalse(M.sameMaterial(whole, rest), "ganze Datei und Skriptrest nach dem Marker: eine Planung")
        XCTAssertTrue(M.samePlanned((4, whole), (6, whole)))
        XCTAssertFalse(M.samePlanned((4, whole), (6, sec)))
        XCTAssertTrue(M.samePlanned((4, rest), (6, rest)))
    }

    // MARK: zwei Geraete an einem Schein-Dienst

    /// Dienst im Speicher mit den Regeln des echten (app/sync.py), soweit der Lernplan sie braucht
    private actor MiniService: DeviceSyncTransport {
        private var rows: [String: [Int: [String: JSONValue]]] = [:]
        private var tombs: [[String: JSONValue]] = []
        private var nextID = 100
        private var tick = 0
        private static let parents: [String: [String: String]] = ["study_packages": ["module_id": "modules"], "study_tasks": ["package_id": "study_packages"]]

        private func stamp() -> String {
            tick += 1
            return String(format: "2026-11-16T08:%02d:%02d.000Z", tick / 60, tick % 60)
        }

        func count(_ entity: String) -> Int { rows[entity]?.count ?? 0 }
        func all(_ entity: String) -> [[String: JSONValue]] { (rows[entity] ?? [:]).sorted { $0.key < $1.key }.map(\.value) }
        func tombstones(_ entity: String) -> Int { tombs.filter { $0["entity"]?.string == entity }.count }

        func syncChanges(query: String) async throws -> JSONValue {
            let since = URLComponents(string: "x?" + query)?.queryItems?.first { $0.name == "since" }?.value ?? ""
            var changes: [String: JSONValue] = [:]
            var cursor = since
            for (entity, table) in rows {
                let fresh = table.values.filter { ($0["sync_updated_at"]?.string ?? "") > since }.sorted { ($0["id"]?.int ?? 0) < ($1["id"]?.int ?? 0) }
                if !fresh.isEmpty { changes[entity] = .array(fresh.map(JSONValue.object)) }
                cursor = max(cursor, fresh.compactMap { $0["sync_updated_at"]?.string }.max() ?? "")
            }
            let gone = tombs.filter { ($0["deleted_at"]?.string ?? "") > since }
            cursor = max(cursor, gone.compactMap { $0["deleted_at"]?.string }.max() ?? "")
            return ["cursor": cursor.isEmpty ? .null : .string(cursor), "changes": .object(changes), "tombstones": .array(gone.map(JSONValue.object)), "has_more": false]
        }

        func syncPush(_ body: JSONValue) async throws -> JSONValue {
            let device = body["device_id"] ?? .null
            var results: [JSONValue] = [], mapping: [JSONValue] = [], fresh: [String: Int] = [:]
            for it in body["items"]?.array ?? [] {
                guard let entity = it["entity"]?.string, var data = it["data"]?.object else { continue }
                if entity == "settings" || entity == "annotations" {
                    results.append(["entity": .string(entity), "id": it["id"] ?? it["local_id"] ?? .null, "status": "ignored"])
                    continue
                }
                for (col, target) in Self.parents[entity] ?? [:] {
                    if let v = data[col]?.int, v < 0, let id = fresh["\(target)|\(v)"] { data[col] = .number(Double(id)) }
                }
                data["sync_updated_at"] = .string(stamp())
                data["sync_device"] = device
                if let local = it["local_id"]?.int {
                    nextID += 1
                    data["id"] = .number(Double(nextID))
                    data["sync_version"] = 1
                    rows[entity, default: [:]][nextID] = data
                    fresh["\(entity)|\(local)"] = nextID
                    results.append(["entity": .string(entity), "local_id": .number(Double(local)), "id": .number(Double(nextID)), "status": "created", "version": 1])
                    mapping.append(["entity": .string(entity), "local_id": .number(Double(local)), "id": .number(Double(nextID))])
                } else if let id = it["id"]?.int {
                    guard let old = rows[entity]?[id] else {
                        results.append(["entity": .string(entity), "id": .number(Double(id)), "status": "deleted", "deleted_at": .string(stamp())])
                        continue
                    }
                    let version = (old["sync_version"]?.int ?? 1) + 1
                    data["id"] = .number(Double(id))
                    data["sync_version"] = .number(Double(version))
                    rows[entity]?[id] = data
                    results.append(["entity": .string(entity), "id": .number(Double(id)), "status": "applied", "version": .number(Double(version))])
                }
            }
            for d in body["deletes"]?.array ?? [] {
                guard let entity = d["entity"]?.string, let id = d["id"]?.int else { continue }
                if rows[entity]?.removeValue(forKey: id) != nil {
                    tombs.append(["entity": .string(entity), "entity_id": .string(String(id)), "deleted_at": .string(stamp()), "device": device])
                    if entity == "study_packages" {                    // ON DELETE CASCADE wie im Dienst
                        for (tid, t) in rows["study_tasks"] ?? [:] where t["package_id"]?.int == id {
                            rows["study_tasks"]?[tid] = nil
                            tombs.append(["entity": "study_tasks", "entity_id": .string(String(tid)), "deleted_at": .string(stamp()), "device": device])
                        }
                    }
                }
                results.append(["entity": .string(entity), "id": .number(Double(id)), "status": "deleted"])
            }
            return ["results": .array(results), "mapping": .array(mapping), "conflicts": .array([])]
        }
    }

    private struct Device {
        let name: String
        let db: SQLiteDatabase
        let sync: DeviceSync

        /// (Tag, Uhrzeit, Status) der Pakete, die die Datei enthalten
        func plan() async throws -> [String] {
            try await db.withConnection { c in
                try c.query("""
                    SELECT p.date, p.status FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.file_id=? ORDER BY p.date, p.id
                    """, [.text(StudyPlanMergeTests.file)]).map { "\($0["date"]?.string ?? "") \($0["status"]?.string ?? "")" }
            }
        }

        func packages() async throws -> Int { try await db.withConnection { try $0.scalar("SELECT COUNT(*) FROM study_packages")?.int ?? 0 } }
    }

    /// Geraet, das die Datei selbst auf `day` eingeplant hat (wie `StudyPlan.insertPackage`); `current: false` = App bis
    /// Build 42 (fuehrt nichts zusammen)
    private func device(_ name: String, _ service: MiniService, day: String, plannedAt: String, current: Bool = true) async throws -> Device {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        try await db.transaction { c in
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Mathe I', 'WiSe 26/27')")
            let mid = c.lastInsertRowID
            try c.execute("INSERT INTO courses(id, title, semester, module_id) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27', ?)", [.integer(mid)])
            try c.execute("INSERT INTO files(id, course_id, name, status) VALUES (?, 'kurs-1', 'Blatt1.pdf', 'neu')", [.text(Self.file)])
            try c.execute("""
                INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time)
                VALUES (?, ?, 'Mathe I', 'Woche 5 · 16.11. – 22.11.', 5, 60, 'geplant', 0, 1, ?, '08:00', '09:00')
                """, [.text(day), .integer(mid), .text(plannedAt)])
            try c.execute("""
                INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at, start_time, end_time)
                VALUES (?, 'uebung', ?, 'Blatt1.pdf', 0, 60, 'geplant', ?, '08:00', '09:00')
                """, [.integer(c.lastInsertRowID), .text(Self.file), .text(plannedAt)])
        }
        return Device(name: name, db: db, sync: DeviceSync(database: db, transport: service, device: name, clock: Self.clock, mergePlans: current))
    }

    private func run(_ d: Device, file: StaticString = #filePath, line: UInt = #line) async -> DeviceSyncResult {
        let r = await d.sync.run(account: "konto-1")
        XCTAssertTrue(r.ok, r.error ?? "", file: file, line: line)
        XCTAssertEqual(r.errors, [], file: file, line: line)
        return r
    }

    /// Die Ursache (Stand bis Build 42): Beide Geraete planen dieselbe Datei, bevor der Abgleich die Planung des anderen
    /// gebracht hat. Der Abgleich erkennt ein Paket nur an Tag + Fach + Titel als dasselbe; an verschiedenen Tagen legt
    /// er beide nebeneinander - auf jedem Geraet und im Konto steht die Datei danach zweimal.
    func testCauseBothDevicesPlanAndTheSyncPutsBothPlansSideBySide() async throws {
        let service = MiniService()
        let ipad = try await device("ipad", service, day: Self.wed, plannedAt: "2026-11-14T16:25:40", current: false)
        let iphone = try await device("iphone", service, day: Self.thu, plannedAt: "2026-11-15T15:30:30", current: false)
        _ = await run(ipad)
        _ = await run(iphone)
        _ = await run(ipad)
        let a = try await ipad.plan(), b = try await iphone.plan()
        XCTAssertEqual(a, ["\(Self.wed) geplant", "\(Self.thu) geplant"], "iPad: dieselbe Datei an zwei Tagen")
        XCTAssertEqual(b, a, "iPhone: genauso")
        let inAccount = await service.count("study_packages")
        XCTAssertEqual(inAccount, 2, "und beide Planungen stehen im Konto")
    }

    /// Neue App auf beiden Geraeten: Kommt vom Konto schon eine Planung, uebernimmt das Geraet sie. Die eigene, noch
    /// nicht gesendete geht gar nicht erst ins Konto: keine zweite Zeile, keine Loeschmarke.
    func testSecondDeviceAdoptsThePlanOfTheAccount() async throws {
        let service = MiniService()
        let ipad = try await device("ipad", service, day: Self.wed, plannedAt: "2026-11-15T15:30:30")
        let iphone = try await device("iphone", service, day: Self.thu, plannedAt: "2026-11-14T16:25:40")      // sogar frueher geplant
        _ = await run(ipad)
        let r = await run(iphone)
        XCTAssertEqual(r.planMerged, 1)
        _ = await run(ipad)
        for d in [ipad, iphone] {
            let plan = try await d.plan(), n = try await d.packages()
            XCTAssertEqual(plan, ["\(Self.wed) geplant"])
            XCTAssertEqual(n, 1)
        }
        let (packages, tasks, tombs) = (await service.count("study_packages"), await service.count("study_tasks"), await service.tombstones("study_packages"))
        XCTAssertEqual([packages, tasks, tombs], [1, 1, 0], "im Konto genau eine Planung, nichts wurde dort je geloescht")
        let again = await run(iphone)
        XCTAssertEqual([again.pushed, again.deleted, again.planMerged], [0, 0, 0], "danach Ruhe")
    }

    /// Aeltere App (Build 42) neben der neuen, in beiden Reihenfolgen: Die aeltere legt ihre Planung weiter daneben, die
    /// neue fuehrt wieder zusammen; die aeltere uebernimmt die Loeschmarke. Am Ende ueberall dieselbe eine Planung, und
    /// weitere Abgleiche aendern nichts mehr (kein Hin und Her).
    func testOlderAppNextToTheNewOneEndsWithOnePlanEverywhere() async throws {
        // die neue App war zuerst im Konto
        var service = MiniService()
        var new = try await device("ipad-neu", service, day: Self.wed, plannedAt: "2026-11-14T16:25:40")
        var old = try await device("iphone-alt", service, day: Self.thu, plannedAt: "2026-11-15T15:30:30", current: false)
        _ = await run(new)
        _ = await run(old)
        var doubled = await service.count("study_packages")
        XCTAssertEqual(doubled, 2, "die aeltere App hat ihr Doppel gesendet")
        let cleaned = await run(new)
        XCTAssertEqual(cleaned.planMerged, 1)
        _ = await run(old)
        for d in [new, old] {
            let plan = try await d.plan()
            XCTAssertEqual(plan, ["\(Self.wed) geplant"], "die frueher geplante bleibt, auf beiden Geraeten")
        }
        var left = await service.all("study_packages").compactMap { $0["date"]?.string }
        XCTAssertEqual(left, [Self.wed])
        for d in [new, old, new, old] {
            let r = await run(d)
            XCTAssertEqual([r.pushed, r.deleted, r.planMerged, r.applied], [0, 0, 0, 0], "kein Hin und Her")
        }
        // die aeltere App war zuerst im Konto: die neue uebernimmt deren Planung und sendet die eigene nie
        service = MiniService()
        old = try await device("iphone-alt", service, day: Self.thu, plannedAt: "2026-11-15T15:30:30", current: false)
        new = try await device("ipad-neu", service, day: Self.wed, plannedAt: "2026-11-14T16:25:40")
        _ = await run(old)
        _ = await run(new)
        _ = await run(old)
        for d in [new, old] {
            let plan = try await d.plan()
            XCTAssertEqual(plan, ["\(Self.thu) geplant"])
        }
        doubled = await service.count("study_packages")
        left = await service.all("study_packages").compactMap { $0["date"]?.string }
        XCTAssertEqual(doubled, 1)
        XCTAssertEqual(left, [Self.thu])
    }

    /// Begonnenes bleibt immer: Die aeltere App hat ihre (spaeter geplante) Aufgabe schon erledigt. Die neue App
    /// entfernt dann ihr eigenes unberuehrtes Paket, nie das erledigte.
    func testStartedOrDoneWorkIsNeverRemoved() async throws {
        let service = MiniService()
        let new = try await device("ipad-neu", service, day: Self.wed, plannedAt: "2026-11-14T16:25:40")
        let old = try await device("iphone-alt", service, day: Self.thu, plannedAt: "2026-11-15T15:30:30", current: false)
        _ = await run(new)
        try await old.db.transaction { c in
            try c.execute("UPDATE study_tasks SET status='erledigt', done_at='2026-11-16T08:30:00', actual_minutes=55")
            try c.execute("UPDATE study_packages SET status='erledigt'")
        }
        _ = await run(old)                                   // holt die Planung des iPads, sendet die eigene erledigte
        _ = await run(new)                                   // sieht beide: die erledigte bleibt, die eigene unberuehrte geht
        _ = await run(old)
        for d in [new, old] {
            let plan = try await d.plan()
            XCTAssertEqual(plan, ["\(Self.thu) erledigt"])
        }
        let left = await service.all("study_tasks").map { "\($0["status"]?.string ?? "") \($0["actual_minutes"]?.int ?? 0)" }
        XCTAssertEqual(left, ["erledigt 55"])
    }

    /// Drei Geraete (iPad, iPhone, Mac) haben alle selbst geplant und gleichzeitig gesendet: Jedes sieht dieselben drei
    /// Zeilen und laesst dieselbe stehen. Kein Geraet loescht, was ein anderes behaelt.
    func testThreeDevicesAgreeOnTheSameRow() async throws {
        let service = MiniService()
        let devices = [try await device("ipad", service, day: Self.thu, plannedAt: "2026-11-15T15:30:30", current: false),
                       try await device("iphone", service, day: Self.wed, plannedAt: "2026-11-14T16:25:40", current: false),
                       try await device("mac", service, day: "2026-11-20", plannedAt: "2026-11-15T15:30:31", current: false)]
        for d in devices { _ = await run(d) }                // Stand bis Build 42: drei Planungen im Konto
        let before = await service.count("study_packages")
        XCTAssertEqual(before, 3)
        // Update auf allen dreien; jedes gleicht zweimal ab, in beliebiger Reihenfolge
        let updated = devices.map { Device(name: $0.name, db: $0.db, sync: DeviceSync(database: $0.db, transport: service, device: $0.name, clock: Self.clock)) }
        for d in [updated[2], updated[0], updated[1], updated[1], updated[2], updated[0]] { _ = await run(d) }
        for d in updated {
            let plan = try await d.plan()
            XCTAssertEqual(plan, ["\(Self.wed) geplant"], "die zuerst geplante bleibt")
        }
        let left = await service.all("study_packages").compactMap { $0["date"]?.string }
        XCTAssertEqual(left, [Self.wed], "im Konto genau eine, und zwar dieselbe")
    }

    // MARK: Kopie einer echten Datenbank (nur lokal)

    /// Nur mit STUDY_PLAN_MERGE_COPY=<Pfad einer Kopie>: wie die App nach dem Update (Schema, dann Zusammenfuehren) auf
    /// einer weiteren Kopie; gibt nur Zahlen aus (Pakete je Tag vorher und nachher), keine Namen. Nie im Repository.
    func testRealCopyIfGiven() async throws {
        guard let source = ProcessInfo.processInfo.environment["STUDY_PLAN_MERGE_COPY"] else { throw XCTSkip("STUDY_PLAN_MERGE_COPY fehlt") }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("plan-merge-\(UUID().uuidString).sqlite").path
        try FileManager.default.copyItem(atPath: source, toPath: copy)
        defer { try? FileManager.default.removeItem(atPath: copy) }
        let db = try SQLiteDatabase(path: copy)
        try await db.withConnection { try Migrations.migrate($0) }
        let today = try XCTUnwrap(BerlinClock.parseISODate(ProcessInfo.processInfo.environment["STUDY_PLAN_MERGE_TODAY"] ?? Self.clock.today))
        func days(_ c: SQLiteConnection) throws -> [String] {
            try c.query("SELECT date, COUNT(*) n, SUM(status NOT IN ('verschoben','uebersprungen')) open FROM study_packages GROUP BY date ORDER BY date")
                .map { "\($0["date"]?.string ?? ""): \($0["n"]?.int ?? 0) (\($0["open"]?.int ?? 0) offen)" }
        }
        let (before, result, after, again, files) = try await db.transaction { c -> ([String], JSONValue, [String], JSONValue, Int) in
            try DeviceSyncSchema.ensure(c)
            let before = try days(c)
            let result = try StudyPlanMerge.afterPull(c, today: today).json
            let after = try days(c)
            let again = try StudyPlanMerge.afterPull(c, today: today).json
            let twice = try c.scalar("""
                SELECT COUNT(*) FROM (SELECT file_id FROM study_tasks WHERE file_id IS NOT NULL AND status IN ('geplant','in_bearbeitung','erledigt','nachholen')
                GROUP BY file_id HAVING COUNT(*) > 1)
                """)?.int ?? -1
            return (before, result, after, again, twice)
        }
        print("PLAN-MERGE vorher \(before)\nPLAN-MERGE Ergebnis \(result.jsonString())\nPLAN-MERGE nachher \(after)\nPLAN-MERGE noch doppelte Dateien \(files)")
        XCTAssertEqual(again, StudyPlanMerge.Result().json, "ein zweiter Lauf aendert nichts")
    }
}
