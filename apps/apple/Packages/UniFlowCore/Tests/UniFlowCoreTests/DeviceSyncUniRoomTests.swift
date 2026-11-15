import Foundation
import XCTest
@testable import UniFlowCore

/// Raum je Uni-Konto im Geraete-Abgleich (14.11.2026, `UniAccountKey`, docs/ABGLEICH-UNI-KONTO-2026-11-14.md).
///
/// Befund am echten iPhone, hier mit erfundenen Daten nachgestellt: 15 Faecher, 7 eigene (mit Kursen und Dateien) und 8
/// leere, die ueber den Abgleich von einem Geraet mit einem anderen Uni-Konto kamen. Erwartet: das Geraet meldet seinen
/// Schluessel, ruft einmal alles neu ab, und was der Dienst als fremd nennt, verschwindet hier ohne Loeschmarke -
/// aber nur, wenn nichts Eigenes daran haengt. Schein-Dienst, kein Netz; gegen den echten Dienst: tests/
/// test_sync_rooms_cleanup.py (gleiche Regeln in app/sync_client.py) und `DeviceSyncLiveTests`.
final class DeviceSyncUniRoomTests: XCTestCase {
    private static let own = (1...7).map { "Ada-Fach \($0)" }
    private static let foreign = (1...8).map { "Bob-Fach \($0)" }
    private static let stamp = "2026-11-11T19:03:50.556Z"

    /// Antwortet je Abruf mit der naechsten vorbereiteten Seite (danach leer) und merkt sich alles
    private actor FakeService: DeviceSyncTransport {
        var queries: [String] = []
        var pushes: [JSONValue] = []
        private var pages: [JSONValue]
        private var results: [JSONValue]

        init(pages: [JSONValue], results: [JSONValue] = []) {
            self.pages = pages
            self.results = results
        }

        func add(page: JSONValue) { pages.append(page) }
        func add(result: JSONValue) { results.append(result) }

        func syncChanges(query: String) async throws -> JSONValue {
            queries.append(query)
            if pages.isEmpty { return ["cursor": "2026-11-14T20:00:00.000Z", "changes": .object([:]), "tombstones": .array([]), "has_more": false] }
            return pages.removeFirst()
        }

        func syncPush(_ body: JSONValue) async throws -> JSONValue {
            pushes.append(body)
            if !results.isEmpty { return results.removeFirst() }
            // jede neue Zeile bekommt eine Nummer im Dienst
            var out: [JSONValue] = [], mapping: [JSONValue] = [], next = 500
            for it in body["items"]?.array ?? [] {
                guard let entity = it["entity"]?.string else { continue }
                if let local = it["local_id"], local != .null {
                    next += 1
                    let id: JSONValue = entity == "settings" ? local : .number(Double(next))
                    out.append(["entity": .string(entity), "local_id": local, "id": id, "status": entity == "settings" ? "applied" : "created", "version": 1])
                    if entity != "settings" { mapping.append(["entity": .string(entity), "local_id": local, "id": id]) }
                } else {
                    out.append(["entity": .string(entity), "id": it["id"] ?? .null, "status": "applied", "version": 2])
                }
            }
            return ["results": .array(out), "mapping": .array(mapping), "conflicts": .array([])]
        }
    }

    private static func module(_ id: Int, _ name: String) -> JSONValue {
        ["id": .number(Double(id)), "name": .string(name), "semester": "WiSe 2026/27", "sync_version": 1,
         "sync_updated_at": .string(stamp), "sync_device": "ipad-anderes"]
    }

    /// Alles, was vor den Raeumen im Konto lag: Faecher 1-7 von Ada, 8-15 von Bob, dazu Bobs Stundenplan
    private static var mixedPage: JSONValue {
        let modules = own.enumerated().map { module($0.offset + 1, $0.element) } + foreign.enumerated().map { module($0.offset + 8, $0.element) }
        let events: [JSONValue] = [0, 2].enumerated().map { i, day in
            ["id": .number(Double(30 + i)), "module_id": 8, "course_id": "bob-1", "title": "Bob-Vorlesung", "weekday": .number(Double(day)),
             "start_time": "08:15", "end_time": "09:45", "kind": "vorlesung", "sync_version": 1, "sync_updated_at": .string(stamp), "sync_device": "ipad-anderes"]
        }
        let exceptions: [JSONValue] = (0..<2).map { i in
            ["id": .number(Double(40 + i)), "event_id": .number(Double(30 + i)), "date": "2026-12-24", "type": "skip", "sync_version": 1,
             "sync_updated_at": .string(stamp), "sync_device": "ipad-anderes"]
        }
        return ["cursor": .string(stamp), "changes": ["modules": .array(modules), "course_events": .array(events), "event_exceptions": .array(exceptions)],
                "tombstones": .array([]), "has_more": false]
    }

    /// Abruf mit Schluessel: nur Adas Raum, und der Dienst nennt Bobs Zeilen als fremd
    private static var roomPage: JSONValue {
        let modules = own.enumerated().map { module($0.offset + 1, $0.element) }
        var foreignRows: [JSONValue] = (8...15).map { ["entity": "modules", "id": .number(Double($0))] }
        foreignRows += [30, 31].map { ["entity": "course_events", "id": .number(Double($0))] }
        foreignRows += [40, 41].map { ["entity": "event_exceptions", "id": .number(Double($0))] }
        return ["cursor": "2026-11-14T19:30:00.000Z", "changes": ["modules": .array(modules)], "tombstones": .array([]), "has_more": false,
                "foreign": .array(foreignRows), "uni": ["rooms": 2, "room": true]]
    }

    /// Das iPhone nach der Vermischung: alles aus dem Dienst uebernommen, danach der eigene Stud.IP-Abgleich
    private func mixedPhone(_ service: FakeService) async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        let first = await DeviceSync(database: db, transport: service, device: "iphone-ada").run(account: "konto-1")
        XCTAssertTrue(first.ok, first.error ?? "")
        try await db.transaction { c in
            try StudIPUserMark.store(c, StudIPUserMark.hash(userID: "ada-123"))
            for (i, name) in Self.own.enumerated() {
                let id = try XCTUnwrap(c.scalar("SELECT id FROM modules WHERE name=?", [.text(name)])?.int)
                try c.execute("INSERT INTO courses(id, title, semester, subject, kind, module_id) VALUES (?,?,?,?, 'vorlesung', ?)",
                              [.text("ada-\(i)"), .text(name), .text("WiSe 2026/27"), .text(name), .integer(Int64(id))])
                try c.execute("INSERT INTO files(id, course_id, name, status) VALUES (?,?, 'Skript.pdf', 'neu')", [.text("ada-\(i)-f"), .text("ada-\(i)")])
            }
        }
        return db
    }

    private func names(_ db: SQLiteDatabase) async throws -> [String] {
        try await db.withConnection { try $0.rows("SELECT name FROM modules ORDER BY name").compactMap { $0["name"]?.string } }
    }

    private func count(_ db: SQLiteDatabase, _ table: String) async throws -> Int {
        try await db.withConnection { try $0.scalar("SELECT COUNT(*) FROM \(table)")?.int ?? 0 }
    }

    // MARK: Schluessel

    func testKeyIsAHashOverAccountUniversityAndIdentityAndEqualOnEveryPlatform() async throws {
        let identity = StudIPUserMark.hash(userID: "ada-123")
        XCTAssertEqual(identity, "60fab9dfa5becd800791b629c996b414601dd13a510e4d7320424b338339900b")
        // derselbe Wert wie app/sync_client.py::uni_key (tests/test_sync_rooms_cleanup.py)
        XCTAssertEqual(UniAccountKey.key(account: "konto-1", university: "luh", identity: identity),
                       "08121804954ac42166e68cc347ca2ce43306ca68c56bfee60b2672717fe92586")
        XCTAssertNotEqual(UniAccountKey.key(account: "konto-2", university: "luh", identity: identity),
                          UniAccountKey.key(account: "konto-1", university: "luh", identity: identity), "je StudiNow-Konto ein anderer Wert")
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        let before = try await db.withConnection { try UniAccountKey.current($0, account: "konto-1") }
        XCTAssertNil(before, "vor der Uni-Anmeldung gibt es keinen Schluessel")
        try await db.transaction { try StudIPUserMark.store($0, identity) }
        let after = try await db.withConnection { try UniAccountKey.current($0, account: "konto-1", university: "luh") }
        XCTAssertEqual(after, "08121804954ac42166e68cc347ca2ce43306ca68c56bfee60b2672717fe92586")
        XCTAssertTrue(UniAccountKey.available(university: "luh"))
        XCTAssertFalse(UniAccountKey.available(university: "hildesheim"), "Learnweb-Kennung gilt nur je Semester-Instanz")
        XCTAssertEqual(StudoraAccount.capabilities, "device_limit, uni_room")
    }

    func testKeyGoesWithEveryRequestAndTheFirstKeyedSyncPullsEverythingOnce() async throws {
        let service = FakeService(pages: [Self.mixedPage])
        let db = try await mixedPhone(service)
        let sync = DeviceSync(database: db, transport: service, device: "iphone-ada")
        _ = await sync.run(account: "konto-1", university: "luh")
        _ = await sync.run(account: "konto-1", university: "luh")
        let key = "08121804954ac42166e68cc347ca2ce43306ca68c56bfee60b2672717fe92586"
        let queries = await service.queries
        // Lauf 1 (vor der Uni-Anmeldung): zwei Abrufe ohne Schluessel
        XCTAssertFalse(queries[0].contains("uni_key") || queries[1].contains("uni_key"))
        XCTAssertTrue(queries[1].contains("since="))
        // Lauf 2: Schluessel dabei, der erste Abruf beginnt von vorn
        XCTAssertTrue(queries[2].contains("uni_key=\(key)") && queries[2].contains("studip_user="), queries[2])
        XCTAssertFalse(queries[2].contains("since="), "einmal alles neu abrufen")
        XCTAssertTrue(queries[3].contains("since="))
        // Lauf 3: derselbe Schluessel, kein Neuanfang
        XCTAssertTrue(queries[4].contains("uni_key=\(key)") && queries[4].contains("since="), queries[4])
        let pushes = await service.pushes
        XCTAssertTrue(pushes.dropFirst(1).allSatisfy { $0["uni_key"]?.string == key })
    }

    // MARK: Aufraeumen

    func testTheEightForeignEmptySubjectsGoAndTheSevenOwnStay() async throws {
        let service = FakeService(pages: [Self.mixedPage])
        let db = try await mixedPhone(service)
        // der Fehler: 15 Faecher, Bobs Termine im Stundenplan
        let mixed = try await names(db)
        XCTAssertEqual(mixed, (Self.own + Self.foreign).sorted())
        let mixedEvents = try await count(db, "course_events")
        XCTAssertEqual(mixedEvents, 2)
        let pushesBefore = await service.pushes.count

        await service.add(page: Self.roomPage)
        let r = await DeviceSync(database: db, transport: service, device: "iphone-ada", requireUniAccount: true).run(account: "konto-1", university: "luh")
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertEqual(r.foreignRemoved, 8 + 2 + 2)
        XCTAssertTrue(r.otherUniAccount)
        XCTAssertEqual(r.deleted, 0)
        let left = try await names(db)
        XCTAssertEqual(left, Self.own, "die 7 eigenen bleiben, die 8 fremden gehen")
        let events = try await count(db, "course_events"), exceptions = try await count(db, "event_exceptions")
        XCTAssertEqual([events, exceptions], [0, 0], "Bobs Stundenplan ist weg")
        let courses = try await db.withConnection { try $0.scalar("SELECT COUNT(*) FROM courses WHERE module_id IS NOT NULL")?.int }
        let files = try await count(db, "files")
        XCTAssertEqual([courses, files], [7, 7], "eigene Kurse und Dateien unberuehrt")
        // keine Loeschmarke, die sich fortpflanzt: nichts gesendet, alle Marken gehoeren dem Dienst, keine Zuordnung mehr
        let pushes = await service.pushes
        for p in pushes.dropFirst(pushesBefore) {
            XCTAssertEqual(p["deletes"]?.array?.count ?? 0, 0, p.jsonString())
            XCTAssertFalse((p["items"]?.array ?? []).contains { ["modules", "course_events", "event_exceptions"].contains($0["entity"]?.string ?? "") })
        }
        let open = try await db.withConnection { try $0.scalar("SELECT COUNT(*) FROM sync_tombstones WHERE device IS NULL")?.int }
        XCTAssertEqual(open, 0)
        let mapped = try await db.withConnection { try $0.scalar("SELECT COUNT(*) FROM sync_link_map WHERE entity='modules'")?.int }
        XCTAssertEqual(mapped, 7)
        // ein weiterer Lauf aendert nichts mehr
        let again = await DeviceSync(database: db, transport: service, device: "iphone-ada", requireUniAccount: true).run(account: "konto-1", university: "luh")
        XCTAssertEqual(again.foreignRemoved, 0)
        let still = try await names(db)
        XCTAssertEqual(still, Self.own)
    }

    func testForeignRowsWithOwnContentAreKeptAndBecomeOwnRows() async throws {
        let service = FakeService(pages: [Self.mixedPage])
        let db = try await mixedPhone(service)
        try await db.transaction { c in
            func id(_ name: String) throws -> Int64 { Int64(try XCTUnwrap(c.scalar("SELECT id FROM modules WHERE name=?", [.text(name)])?.int)) }
            // eigenes Lernpaket an einem fremden Fach, ein hier umbenanntes Fach, Karteikarten zum Fach (ueber den Namen),
            // ein eigener Kurs an einem fremden Fach
            try c.execute("INSERT INTO study_packages(date, module_id, subject, title) VALUES ('2026-11-20', ?, ?, 'Eigenes Paket')",
                          [.integer(try id("Bob-Fach 3")), .text("Bob-Fach 3")])
            try c.execute("UPDATE modules SET name='Selbst umbenannt' WHERE name='Bob-Fach 4'")
            try c.execute("INSERT INTO flashcard_stacks(name, subject) VALUES ('Karten', 'Bob-Fach 5')")
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, module_id) VALUES ('eigen-6', 'K', 'WiSe 2026/27', 'K', 'vorlesung', ?)",
                          [.integer(try id("Bob-Fach 6"))])
        }
        await service.add(page: Self.roomPage)
        let pushesBefore = await service.pushes.count
        let r = await DeviceSync(database: db, transport: service, device: "iphone-ada").run(account: "konto-1", university: "luh")
        XCTAssertTrue(r.ok, r.error ?? "")
        let kept = ["Bob-Fach 3", "Bob-Fach 5", "Bob-Fach 6", "Selbst umbenannt"]
        let left = try await names(db)
        XCTAssertEqual(left, (Self.own + kept).sorted(), "im Zweifel behalten")
        XCTAssertEqual(r.foreignRemoved, 4 + 2 + 2)
        // die behaltenen Faecher gehen als neue Zeilen in den eigenen Raum, das Lernpaket haengt am neuen Fach
        let sent = (await service.pushes).dropFirst(pushesBefore).flatMap { $0["items"]?.array ?? [] }
        let sentModules = sent.filter { $0["entity"]?.string == "modules" }
        XCTAssertEqual(sentModules.compactMap { $0["data"]?["name"]?.string }.sorted(), kept)
        XCTAssertTrue(sentModules.allSatisfy { ($0["local_id"]?.int ?? 0) < 0 && $0["id"] == nil }, "neue Zeilen, keine Aenderung an Bobs Zeilen")
        let package = try XCTUnwrap(sent.first { $0["entity"]?.string == "study_packages" })
        XCTAssertLessThan(package["data"]?["module_id"]?.int ?? 0, 0, "verweist auf das neu gesendete Fach")
        let deletes = (await service.pushes).dropFirst(pushesBefore).flatMap { $0["deletes"]?.array ?? [] }
        XCTAssertTrue(deletes.isEmpty)
    }

    func testWithoutProofFromTheServiceNothingIsRemoved() async throws {
        // das andere Geraet hat sich noch nicht gemeldet: der Dienst nennt nichts als fremd
        let service = FakeService(pages: [Self.mixedPage])
        let db = try await mixedPhone(service)
        await service.add(page: ["cursor": "2026-11-14T19:30:00.000Z", "changes": .object([:]), "tombstones": .array([]), "has_more": false,
                                 "foreign": .array([]), "uni": ["rooms": 1, "room": true]])
        let r = await DeviceSync(database: db, transport: service, device: "iphone-ada").run(account: "konto-1", university: "luh")
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.foreignRemoved, 0)
        XCTAssertFalse(r.otherUniAccount)
        let left = try await names(db)
        XCTAssertEqual(left.count, 15)
    }

    // MARK: Senden

    /// `room_pending`: die Zeile im Dienst stammt von einem Geraet, dessen Uni-Konto der Dienst noch nicht kennt. Hier
    /// bleibt alles, wie es ist, und Aenderung wie Loeschung gehen beim naechsten Abgleich noch einmal mit - nichts
    /// geht verloren, nichts wird doppelt angelegt.
    func testPendingAnswersKeepTheChangeAndTheDeleteForTheNextSync() async throws {
        let service = FakeService(pages: [Self.mixedPage])
        let db = try await mixedPhone(service)
        try await db.transaction { c in
            try c.execute("UPDATE modules SET color='#123456' WHERE name='Ada-Fach 1'")
            try c.execute("UPDATE courses SET module_id=NULL WHERE module_id=(SELECT id FROM modules WHERE name='Ada-Fach 2')")
            try c.execute("DELETE FROM modules WHERE name='Ada-Fach 2'")
        }
        // die Loeschung liegt nicht in derselben Millisekunde wie der folgende Abruf (dessen Marken gehoeren dem Dienst)
        try await Task.sleep(nanoseconds: 5_000_000)
        let pending: JSONValue = ["results": [["entity": "modules", "id": 1, "status": "room_pending"], ["entity": "modules", "id": 2, "status": "room_pending"]],
                                  "mapping": .array([]), "conflicts": .array([])]
        await service.add(result: pending)
        let before = await service.pushes.count
        let sync = DeviceSync(database: db, transport: service, device: "iphone-ada")
        let first = await sync.run(account: "konto-1", university: "luh")
        XCTAssertTrue(first.ok, first.error ?? "")
        XCTAssertEqual(first.pushed, 0)
        XCTAssertEqual(first.errors, [])
        // zweiter Lauf: dieselbe Aenderung (mit der Nummer im Dienst, keine neue Zeile) und dieselbe Loeschung noch einmal
        let second = await sync.run(account: "konto-1", university: "luh")
        XCTAssertEqual(second.pushed, 1, "jetzt angenommen (Schein-Dienst antwortet applied)")
        let pushes = Array((await service.pushes).dropFirst(before))
        XCTAssertEqual(pushes.count, 2)
        for p in pushes {
            let modules = (p["items"]?.array ?? []).filter { $0["entity"]?.string == "modules" }
            XCTAssertEqual(modules.map { $0["id"]?.int }, [1], p.jsonString())
            XCTAssertEqual((p["deletes"]?.array ?? []).map { $0["id"]?.int }, [2])
        }
        let left = try await names(db)
        XCTAssertEqual(left.count, 14)
        XCTAssertFalse(left.contains("Ada-Fach 2"))
    }

    func testOtherRoomAnswersNeverDeleteAndNeverRepeatForever() async throws {
        let service = FakeService(pages: [Self.mixedPage])
        let db = try await mixedPhone(service)
        // hier: ein fremdes Fach geaendert, ein fremdes geloescht, eine Einstellung geaendert
        try await db.transaction { c in
            try c.execute("UPDATE modules SET color='#123456' WHERE name='Bob-Fach 1'")
            try c.execute("DELETE FROM modules WHERE name='Bob-Fach 2'")
            try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('lieblingsfarbe', 'rot')")
        }
        await service.add(result: ["results": [["entity": "modules", "id": 8, "status": "other_room", "room": "other"],
                                               ["entity": "settings", "id": "lieblingsfarbe", "status": "other_room", "room": "other"],
                                               ["entity": "modules", "id": 9, "status": "other_room", "room": "other"]],
                                   "mapping": .array([]), "conflicts": .array([])])
        let core = DeviceSyncCore(device: "iphone-ada")
        let (items, deletes) = try await db.transaction { try core.collect($0) }
        XCTAssertEqual(deletes.map(\.id), ["9"])
        let wanted = items.filter { ($0.table == "modules" && $0.local != "") || $0.local == "lieblingsfarbe" }
        let res = try await service.syncPush(.object(["items": .array(wanted.map { .object($0.body) }), "deletes": .array(deletes.map(\.body))]))
        try await db.transaction { try core.handleResults($0, wanted, deletes, res) }
        let left = try await names(db)
        XCTAssertTrue(left.contains("Bob-Fach 1"), "die hier geaenderte Zeile bleibt")
        XCTAssertFalse(left.contains("Bob-Fach 2"), "hier geloescht bleibt hier geloescht")
        // naechstes Sammeln: das geaenderte Fach geht als neue Zeile, die Loeschung und die Einstellung nicht noch einmal
        let (next, nextDeletes) = try await db.transaction { try DeviceSyncCore(device: "iphone-ada").collect($0) }
        XCTAssertTrue(nextDeletes.isEmpty)
        let again = try XCTUnwrap(next.first { $0.table == "modules" })
        XCTAssertEqual(again.body["data"]?["name"]?.string, "Bob-Fach 1")
        XCTAssertNil(again.body["id"])
        XCTAssertFalse(next.contains { $0.local == "lieblingsfarbe" })
    }

    // MARK: Regel je Hochschule

    /// LUH (sichere Kennung): vor dem ersten Stud.IP-Abgleich gibt es keinen Schluessel, die App gleicht nicht ab
    func testAtTheLUHWithoutAUniAccountTheAppDoesNotSyncAndLeavesTheDatabaseAlone() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        try await db.transaction { try $0.execute("INSERT INTO modules(name) VALUES ('Eigenes Fach')") }
        let service = FakeService(pages: [Self.mixedPage])
        let r = await DeviceSync(database: db, transport: service, device: "iphone-neu", requireUniAccount: true).run(account: "konto-1", university: "luh")
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.noUniAccount)
        let queries = await service.queries, pushes = await service.pushes
        XCTAssertTrue(queries.isEmpty && pushes.isEmpty, "nichts abgerufen, nichts gesendet")
        let cols = try await db.withConnection { try $0.columnNames("modules") }
        XCTAssertFalse(cols.contains("sync_version"), "die Datenbank bleibt, wie sie ist")
        let left = try await names(db)
        XCTAssertEqual(left, ["Eigenes Fach"])
        // Hinweise in den Konto-Einstellungen
        XCTAssertEqual(UniAccountKey.hint(r, university: "luh"), UniAccountKey.signInFirstText)
        var other = DeviceSyncResult()
        XCTAssertNil(UniAccountKey.hint(other, university: "luh"))
        other.otherUniAccount = true
        XCTAssertEqual(UniAccountKey.hint(other, university: "luh"), UniAccountKey.otherAccountText)
        XCTAssertNil(UniAccountKey.hint(nil, university: "luh"))
    }

    /// Hildesheim und HsH (keine sichere Kennung; Entscheidung des Inhabers vom 14.11.2026): der Abgleich laeuft wie in
    /// 1.0.4 weiter, auch Notizen, ohne Hinweis. Die App schickt einen Schluessel nur aus StudiNow-Konto und Hochschule:
    /// gleich auf allen Hildesheimer Geraeten des Kontos, anders als jeder LUH-Schluessel.
    func testWithoutASecureIdentityTheSyncRunsAsBeforeWithAKeyFromAccountAndUniversity() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { c in
            try Migrations.migrate(c)
            try c.execute("INSERT INTO courses(id, title, semester) VALUES ('lw-1', 'Paedagogik', 'WiSe 2026/27')")
            try c.execute("INSERT INTO files(id, course_id, name, mime, status) VALUES ('lw-datei', 'lw-1', 'Skript.pdf', 'application/pdf', 'neu')")
            try c.execute("INSERT INTO modules(name) VALUES ('Paedagogik')")
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES ('lw-datei', '{\"note\":\"meine\"}', 1)")
        }
        // derselbe Wert wie sync.university_key im Dienst (tests/test_sync_rooms.py)
        let key = "843b8a58247bab16a76c4b05dbff067e9f9e7b65a5ef7c036b94458cfbe0cf6b"
        XCTAssertEqual(UniAccountKey.key(account: "konto-1", university: "hildesheim", identity: UniAccountKey.universityOnly), key)
        let current = try await db.withConnection { try UniAccountKey.current($0, account: "konto-1", university: "hildesheim") }
        XCTAssertEqual(current, key)
        let hsh = try await db.withConnection { try UniAccountKey.current($0, account: "konto-1", university: "hsh") }
        XCTAssertNotNil(hsh)
        XCTAssertNotEqual(hsh, key, "je Hochschule ein anderer Schluessel")
        let luh = try await db.withConnection { try UniAccountKey.current($0, account: "konto-1", university: "luh") }
        XCTAssertNil(luh, "LUH ohne Stud.IP-Abgleich: kein Schluessel")
        XCTAssertNotEqual(UniAccountKey.key(account: "konto-1", university: "luh", identity: StudIPUserMark.hash(userID: "ada-123")), key)

        let service = FakeService(pages: [Self.mixedPage])
        let r = await DeviceSync(database: db, transport: service, device: "ipad-hi", requireUniAccount: true).run(account: "konto-1", university: "hildesheim")
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertFalse(r.noUniAccount)
        XCTAssertGreaterThan(r.applied, 0, "holt wie bisher")
        let queries = await service.queries
        XCTAssertFalse(queries.isEmpty)
        XCTAssertTrue(queries.allSatisfy { $0.contains("uni_key=\(key)") && !$0.contains("studip_user") }, queries.description)
        let pushes = await service.pushes
        XCTAssertEqual(pushes.first?["uni_key"]?.string, key)
        XCTAssertNil(pushes.first?["studip_user"])
        let sent = pushes.flatMap { $0["items"]?.array ?? [] }
        XCTAssertTrue(sent.contains { $0["entity"]?.string == "modules" && $0["data"]?["name"]?.string == "Paedagogik" }, "sendet wie bisher")
        XCTAssertTrue(sent.contains { $0["entity"]?.string == "annotations" && $0["id"]?.string == "lw-datei" }, "auch Notizen")
        // kein Hinweis in den Konto-Einstellungen, auch nicht bei einem zweiten Raum im Konto
        XCTAssertNil(UniAccountKey.hint(r, university: "hildesheim"))
        var other = r
        other.otherUniAccount = true
        XCTAssertNil(UniAccountKey.hint(other, university: "hildesheim"))
        XCTAssertNil(UniAccountKey.hint(other, university: "hsh"))
    }
}
