import CryptoKit
import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gemeinsame Wochentests ueber CloudKit (WeeklyTestCloudKit.swift, Regel des Inhabers vom 04.11.2026: hoechstens drei
/// Tests je Schluessel) gegen ein nachgebildetes CloudKit im Speicher: echte Verschluesselung (AES-256-GCM, HKDF aus
/// den Inhalts-Hashes), atomares Belegen, vier Studierende mit drei Tests, Wettlauf zweier Studierender mit derselben
/// Variante (einer erzeugt, der andere wartet und uebernimmt), Fabrik ohne Container. Kein echtes CloudKit, kein Netz.
final class WeeklyTestCloudKitTests: XCTestCase {
    /// Gemeinsamer Speicher mehrerer "Geraete" (je Geraet ein `FakeWeeklyCloud` mit eigenem Nutzer)
    final class Store: @unchecked Sendable {
        let lock = NSLock()
        var records: [String: CommunityRecord] = [:]
        var queries = 0
    }

    /// Nachbau von CloudKit wie `CKCommunityCloud`: neuer Datensatz mit vorhandenem Namen eines anderen -> Fehler
    /// (serverRecordChanged), fremden Datensatz aendern -> permission, Ersteller setzt der Dienst
    final class FakeWeeklyCloud: CommunityCloud, @unchecked Sendable {
        let store: Store
        var user: String
        var status: CommunityAccountStatus = .available
        var failure: CommunityCloudError?
        /// laeuft vor jedem Speichern (ein anderes Geraet kommt dazwischen)
        var beforeSave: (@Sendable (FakeWeeklyCloud, CommunityRecord) -> Void)?

        init(store: Store, user: String) {
            self.store = store
            self.user = user
        }

        private func key(_ scope: CommunityScope, _ type: String, _ name: String) -> String { "\(scope == .publicDB ? "pub" : "priv")|\(type)|\(name)" }
        private func check() throws { if let failure { throw failure } }

        func accountStatus() async throws -> CommunityAccountStatus { try check(); return status }

        func userRecordName() async throws -> String {
            try check()
            guard status == .available else { throw CommunityCloudError.notSignedIn }
            return user
        }

        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord {
            try check()
            guard status == .available else { throw CommunityCloudError.notSignedIn }
            beforeSave?(self, record)
            return try store.lock.withLock {
                var r = record
                if let existing = store.records[key(scope, r.type, r.name)] {
                    guard existing.creator == user else { throw CommunityCloudError.other("serverRecordChanged") }
                }
                r.creator = user
                store.records[key(scope, r.type, r.name)] = r
                return r
            }
        }

        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? {
            try check()
            return store.lock.withLock { store.records[key(scope, type, name)] }
        }

        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] {
            try check()
            return store.lock.withLock {
                store.queries += 1
                return store.records.filter { entry in
                    entry.key == key(scope, q.type, entry.value.name) && q.equals.allSatisfy { k, v in entry.value.fields[k] == v }
                }.map(\.value).sorted { $0.name < $1.name }
            }
        }

        func delete(name: String, type: String, in scope: CommunityScope) async throws {
            try check()
            try store.lock.withLock {
                guard let existing = store.records[key(scope, type, name)] else { return }
                guard existing.creator == user else { throw CommunityCloudError.permission }
                store.records[key(scope, type, name)] = nil
            }
        }

        func all() -> [CommunityRecord] { store.lock.withLock { Array(store.records.values) } }
    }

    /// Zaehlende Schein-KI mit gueltigem Wochentest (15 Aufgaben 4/6/5); `gate` haelt die Antwort zurueck, bis es oeffnet
    final class CountingAI: AIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        let title: String
        var gate: (@Sendable () async -> Void)?
        init(title: String = "Wochentest Testmathe – Reihen") { self.title = title }
        func answer(system: String, prompt: String) async throws -> String {
            lock.withLock { calls += 1 }
            await gate?()
            return WeeklyTestCloudKitTests.validTest(title: title)
        }
    }

    static func validTest(title: String) -> String {
        let diffs = Array(repeating: "leicht", count: 4) + Array(repeating: "mittel", count: 6) + Array(repeating: "schwer", count: 5)
        let qs: [JSONValue] = diffs.enumerated().map { i, d in
            ["nr": .number(Double(i + 1)), "type": i == 0 ? "mc" : "calc", "difficulty": .string(d), "question": .string("Aufgabe \(i + 1) (\(title))"),
             "options": i == 0 ? ["A 1", "B 2"] : .null, "answer": i == 0 ? "B" : "1", "explanation": "Weil es so ist.",
             "points": .number(i < 10 ? 6 : 8)]
        }
        return JSONValue.object(["title": .string(title), "questions": .array(qs)]).jsonString()
    }

    // MARK: Hilfen

    private let hashes = [String(repeating: "0", count: 64), String(repeating: "1", count: 64)]
    private var material: WeeklyTestMaterial { WeeklyTestMaterial(university: Migrations.defaultUniversity, minutes: 45, contentHashes: hashes)! }

    private func sample(_ n: Int) -> SharedWeeklyTest {
        SharedWeeklyTest(title: "Reihen \(n)", questions: try! PyJSON.parse(#"[{"nr": 1, "question": "Aufgabe \#(n)", "answer": "ä", "points": 6}]"#))
    }

    /// Backend eines Studierenden: Modul mit Vorlesung und Uebung derselben Woche (Inhalts-Hashes wie `hashes`)
    private func backend(cloud: FakeWeeklyCloud?, waiting: WeeklyTestShare.Waiting = .none) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let monday = 1_793_052_000.0      // Mo 2026-10-26 (Berlin)
        try await b.context.database.transaction { c in
            _ = try c.execute("UPDATE settings SET value='45' WHERE key='test_minutes'")
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at, active, weekly_test) VALUES (7, 'Testmathe', '#123456', '2026-10-01', 1, 1)")
            _ = try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active, subject) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1, 'Testmathe')")
            for (i, f) in [("f1", "vl01.pdf", "vorlesung", "Folgen und Reihen"), ("f2", "blatt01.pdf", "uebung", "Aufgabe 1")].enumerated() {
                _ = try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, local_path, text_excerpt, content_sha256) VALUES (?, 'k1', ?, ?, 'pdf', ?, ?, ?)",
                                  [.text(f.0), .text(f.1), .integer(Int64(monday) + Int64(i * 3600)), .text("k1/\(f.1)"), .text(f.3), .text(String(repeating: String(i), count: 64))])
                _ = try c.execute("INSERT INTO analysis(file_id, doc_type, title, raw) VALUES (?, ?, ?, '{}')", [.text(f.0), .text(f.2), .text("Titel \(f.1)")])
            }
        }
        // Zeit des Dienstes aus der Uhr des Backends (wie in der App beide die Systemuhr): Belegungen sind nie verwaist
        let clock = b.context.clock
        if let cloud { b.context.testShare.set(CloudKitWeeklyTestShare(cloud: cloud, now: { clock.now }), waiting: waiting) }
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized()))
    }

    private func waitForJob(_ b: LocalBackend) async throws -> String {
        for _ in 0..<1_000 {
            let bg = await call(b, "GET", "/api/bg").json
            if bg?["running"] == false { return bg?["message"]?.string ?? "" }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Hintergrundauftrag endet nicht")
        return ""
    }

    private func row(_ b: LocalBackend) async throws -> [String: JSONValue] {
        let rows = try await b.context.database.rows("SELECT share_key, share_variant, adopted_from, title, questions FROM tests")
        return try XCTUnwrap(rows.first)
    }

    /// Nutzerkennungen mit vorgegebener Variante fuer den Schluessel des Seeds
    private func users(variant: Int, count: Int, key: String, except: Set<String> = []) -> [String] {
        var out: [String] = []
        var i = 0
        while out.count < count {
            let u = "_user-\(i)"; i += 1
            if TestShare.variant(userID: u, key: key) == variant, !except.contains(u) { out.append(u) }
        }
        return out
    }

    // MARK: Datensatz und Verschluesselung

    func testRecordHoldsOnlyCiphertextAndOnlyTheSameFilesCanRead() async throws {
        let store = Store()
        let ada = CloudKitWeeklyTestShare(cloud: FakeWeeklyCloud(store: store, user: "_user-ada"), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let m = material
        let v = TestShare.variant(userID: "_user-ada", key: m.key)
        let adaID = try await ada.userID()
        XCTAssertEqual(adaID, "_user-ada")
        let claimed = try await ada.claim(m, variant: v)
        XCTAssertTrue(claimed)
        let pending = try await ada.slots(m)
        XCTAssertEqual(pending, [v: .pending(since: 1_800_000_000)])
        try await ada.publish(m, variant: v, test: sample(1))

        // Datensatz wie dokumentiert (docs/CLOUDKIT-SCHEMA-PRODUCTION-2026-11-03.md), ohne Klartext und ohne Namen
        let records = (ada.cloud as! FakeWeeklyCloud).all()
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.type, "WeeklyTest")
        XCTAssertEqual(r.name, "\(m.key)#\(v)")
        XCTAssertEqual(r["shareKey"]?.string, m.key)
        XCTAssertEqual(r["variant"]?.int, v)
        XCTAssertEqual(r["status"]?.string, "ready")
        XCTAssertEqual(r["createdAt"]?.string, "2027-01-15T08:00:00Z")
        XCTAssertEqual(r["ownerRecordName"]?.string, "_user-ada")
        XCTAssertEqual(Set(r.fields.keys), ["shareKey", "variant", "status", "payload", "createdAt", "ownerRecordName"])
        let payload = try XCTUnwrap(r["payload"]?.string)
        XCTAssertFalse(payload.contains("Aufgabe") || payload.contains("Reihen"), "nur Chiffrat")
        XCTAssertEqual(Data(base64Encoded: payload)?.first, 1, "Version 1")
        for h in hashes { XCTAssertFalse(payload.contains(h), "Inhalts-Hashes nie beim Dienst") }

        // dieselben Dateien (anderes Geraet): lesbar, byte-gleich; AES-256-GCM aus CryptoKit
        let ben = CloudKitWeeklyTestShare(cloud: FakeWeeklyCloud(store: store, user: "_user-ben"))
        let benSlots = try await ben.slots(m)
        XCTAssertEqual(benSlots, [v: .ready(sample(1))])
        XCTAssertEqual(try WeeklyTestCrypto.open(payload, material: m, variant: v, cipher: CryptoKitSolutionCipher()), sample(1))
        // andere Dateien (anderes Blatt), aber derselbe Schluessel-Text: nicht lesbar, zaehlt als belegt
        let other = WeeklyTestMaterial(key: m.key, contentHashes: [String(repeating: "2", count: 64), hashes[0]])
        let otherSlots = try await ben.slots(other)
        XCTAssertEqual(otherSlots, [v: .broken])
        XCTAssertThrowsError(try WeeklyTestCrypto.open(payload, material: other, variant: v, cipher: CryptoKitSolutionCipher()))
        XCTAssertThrowsError(try WeeklyTestCrypto.open(payload, material: m, variant: (v + 1) % 3, cipher: CryptoKitSolutionCipher()), "nicht umhaengbar")
        // der Schluessel ist HKDF ueber die sortierten Hashes mit dem Salz des Datensatzes: ohne Material kein Schluessel
        let raw = try XCTUnwrap(Data(base64Encoded: payload))
        let salt = raw.subdata(in: 1..<33)
        let derived = CryptoKitSolutionCipher.deriveKey(WeeklyTestCrypto.keyMaterial(contentHashes: m.contentHashes), salt: salt, info: Data("uniflow-weekly-test/v1|\(m.key)".utf8))
        let reference = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data((hashes.sorted().joined(separator: "\n")).utf8)), salt: salt,
                                               info: Data("uniflow-weekly-test/v1|\(m.key)".utf8), outputByteCount: 32)
        XCTAssertEqual(derived.withUnsafeBytes { Data($0) }, reference.withUnsafeBytes { Data($0) })
    }

    func testClaimIsAtomicPublishAndReleaseOnlyOwn() async throws {
        let store = Store()
        let adaCloud = FakeWeeklyCloud(store: store, user: "_user-ada"), benCloud = FakeWeeklyCloud(store: store, user: "_user-ben")
        let ada = CloudKitWeeklyTestShare(cloud: adaCloud), ben = CloudKitWeeklyTestShare(cloud: benCloud)
        let m = material
        let c1 = try await ada.claim(m, variant: 0)
        XCTAssertTrue(c1)
        let c2 = try await ben.claim(m, variant: 0)
        XCTAssertFalse(c2, "vergeben")
        let c3 = try await ada.claim(m, variant: 0)
        XCTAssertFalse(c3, "auch der eigene Platz ist nur einmal zu belegen")
        // Wettlauf zwischen Nachsehen und Anlegen: Ben legt denselben Namen zuerst an -> Ada verliert, nichts ueberschrieben
        benCloud.beforeSave = nil
        adaCloud.beforeSave = { cloud, record in
            if record.name.hasSuffix("#1"), cloud.store.lock.withLock({ cloud.store.records["pub|WeeklyTest|\(record.name)"] == nil }) {
                var r = record
                r[WeeklyTestRecord.Field.owner] = .string("_user-ben")
                r.creator = "_user-ben"
                cloud.store.lock.withLock { cloud.store.records["pub|WeeklyTest|\(record.name)"] = r }
            }
        }
        let lost = try await ada.claim(m, variant: 1)
        XCTAssertFalse(lost)
        XCTAssertEqual(adaCloud.all().first { $0.name.hasSuffix("#1") }?.creator, "_user-ben")
        adaCloud.beforeSave = nil
        // veroeffentlichen nur in den eigenen Platz
        do {
            try await ben.publish(m, variant: 0, test: sample(1))
            XCTFail("fremder Platz")
        } catch {}
        try await ada.publish(m, variant: 0, test: sample(1))
        let s1 = try await ben.slots(m)
        XCTAssertEqual(s1[0], .ready(sample(1)))
        // freigeben: fremde und fertige Plaetze bleiben
        try await ben.release(m, variant: 0)
        try await ada.release(m, variant: 0)
        let s2 = try await ben.slots(m)
        XCTAssertEqual(s2[0], .ready(sample(1)))
        let c4 = try await ben.claim(m, variant: 2)
        XCTAssertTrue(c4)
        try await ben.release(m, variant: 2)
        let s3 = try await ada.slots(m)
        XCTAssertNil(s3[2], "eigener leerer Platz freigegeben")
        // ohne iCloud-Konto wird nicht geteilt
        benCloud.status = .noAccount
        let anonymous = try await ben.userID()
        XCTAssertNil(anonymous)
    }

    // MARK: Vier Studierende, drei Tests

    func testFourStudentsShareThreeTestsOverCloudKit() async throws {
        let store = Store()
        let key = material.key
        var students: [String] = []
        for v in 0..<TestShare.maxVariants { students += users(variant: v, count: 1, key: key, except: Set(students)) }
        students += users(variant: TestShare.variant(userID: students[1], key: key), count: 1, key: key, except: Set(students))
        var ais: [CountingAI] = [], backends: [LocalBackend] = []
        for s in students {
            let b = try await backend(cloud: FakeWeeklyCloud(store: store, user: s))
            let ai = CountingAI(title: "Wochentest Testmathe – von \(s)")
            b.context.ai.set(ai)
            _ = await call(b, "POST", "/api/tests/generate-week")
            let message = try await waitForJob(b)
            XCTAssertEqual(message, "Wochentests: fertig (1 klassisch, 0 mit Seitenmarker)", s)
            ais.append(ai); backends.append(b)
        }
        XCTAssertEqual(ais.map(\.calls), [1, 1, 1, 0], "genau drei Tests, der vierte uebernimmt")
        XCTAssertEqual(store.records.count, 3)
        for (i, s) in students.enumerated() {
            let r = try await row(backends[i])
            XCTAssertEqual(r["share_key"]?.string, key)
            XCTAssertEqual(r["share_variant"]?.int, TestShare.variant(userID: s, key: key))
            XCTAssertEqual(r["adopted_from"], i == 3 ? "cloudkit" : .null, s)
        }
        // der vierte hat den Test des zweiten (gleiche Variante), Aufgaben byte-gleich, eigener Titel ohne fremde Lehrwoche
        let second = try await row(backends[1]), fourth = try await row(backends[3])
        XCTAssertEqual(fourth["questions"], second["questions"])
        XCTAssertEqual(fourth["title"]?.string, "Lehrwoche 1: von \(students[1])")
        let list = await call(backends[3], "GET", "/api/tests").json?.array?.first
        XCTAssertEqual(list?["shared"], ["variant": .number(Double(TestShare.variant(userID: students[3], key: key) + 1)), "of": 3, "adopted": true])
        let own = await call(backends[0], "GET", "/api/tests").json?.array?.first
        XCTAssertEqual(own?["shared"]?["adopted"], false)
        // ein fuenfter Studierender, egal welche Variante: nie ein vierter Test
        for v in 0..<TestShare.maxVariants {
            let s = users(variant: v, count: 1, key: key, except: Set(students))[0]
            let b = try await backend(cloud: FakeWeeklyCloud(store: store, user: s))
            let ai = CountingAI()
            b.context.ai.set(ai)
            _ = await call(b, "POST", "/api/tests/generate-week")
            _ = try await waitForJob(b)
            XCTAssertEqual(ai.calls, 0, "Variante \(v) uebernommen")
            let fifth = try await row(b)
            XCTAssertEqual(fifth["adopted_from"]?.string, "cloudkit")
        }
        XCTAssertEqual(store.records.count, 3)
    }

    // MARK: Wettlauf: gleiche Variante, einer erzeugt, der andere uebernimmt

    func testRaceSameVariantOneGeneratesTheOtherWaitsAndAdopts() async throws {
        let store = Store()
        let key = material.key
        let pair = users(variant: 1, count: 2, key: key)
        let benCloud = FakeWeeklyCloud(store: store, user: pair[0]), adaCloud = FakeWeeklyCloud(store: store, user: pair[1])
        let ben = try await backend(cloud: benCloud)
        let ada = try await backend(cloud: adaCloud, waiting: WeeklyTestShare.Waiting(pollSeconds: 0.02, maxWaitSeconds: 20))
        // Ben belegt den Platz und erzeugt; seine KI antwortet erst, wenn Ada mindestens zweimal nachgesehen hat (wartet)
        let benAI = CountingAI(title: "Wochentest Testmathe – von Ben")
        benAI.gate = { [store] in
            while store.lock.withLock({ store.queries }) < 3 { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        ben.context.ai.set(benAI)
        let adaAI = CountingAI(title: "Wochentest Testmathe – von Ada")
        ada.context.ai.set(adaAI)
        _ = await call(ben, "POST", "/api/tests/generate-week")
        // bis Ben belegt hat
        for _ in 0..<500 where store.lock.withLock({ store.records.isEmpty }) { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(store.lock.withLock { store.records.values.first?["status"]?.string }, "pending")
        _ = await call(ada, "POST", "/api/tests/generate-week")
        let adaMessage = try await waitForJob(ada)
        let benMessage = try await waitForJob(ben)
        XCTAssertEqual(adaMessage, "Wochentests: fertig (1 klassisch, 0 mit Seitenmarker)")
        XCTAssertEqual(benMessage, "Wochentests: fertig (1 klassisch, 0 mit Seitenmarker)")
        XCTAssertEqual(benAI.calls, 1)
        XCTAssertEqual(adaAI.calls, 0, "Ada hat gewartet und uebernommen")
        XCTAssertEqual(store.records.count, 1, "ein Test fuer beide")
        let b = try await row(ben), a = try await row(ada)
        XCTAssertEqual(b["adopted_from"], .null)
        XCTAssertEqual(a["adopted_from"]?.string, "cloudkit")
        XCTAssertEqual(a["share_variant"]?.int, 1)
        XCTAssertEqual(b["share_variant"]?.int, 1)
        XCTAssertEqual(a["questions"], b["questions"])
        XCTAssertEqual(a["title"]?.string, "Lehrwoche 1: von Ben")
    }

    // MARK: Fabrik und Anbindung

    func testFactoryAndHostHookFollowTheContainerSetting() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-wt-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let backend = try await host.backend()
        if CommunityCloudFactory.containerIdentifier() == nil {
            XCTAssertNil(WeeklyTestShareFactory.make(), "ohne Container kein Dienst")
            XCTAssertNil(backend.context.testShare.provider)
        } else {
            XCTAssertTrue(WeeklyTestShareFactory.make() is CloudKitWeeklyTestShare)
            XCTAssertTrue(backend.context.testShare.provider is CloudKitWeeklyTestShare)
        }
        XCTAssertEqual(backend.context.testShare.waiting.maxWaitSeconds, 120)
        XCTAssertEqual(backend.context.testShare.waiting.pollSeconds, 5)
        XCTAssertEqual(CloudKitWeeklyTestShare(cloud: FakeWeeklyCloud(store: Store(), user: "x")).sourceName, "cloudkit")
    }
}
