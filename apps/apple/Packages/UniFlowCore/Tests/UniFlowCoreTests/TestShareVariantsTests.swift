import Foundation
import XCTest
@testable import UniFlowCore

// Varianten gemeinsamer Wochentests (Regel des Inhabers vom 04.11.2026, docs/GEMEINSAME-WOCHENTESTS.md): hoechstens
// drei Tests je Schluessel, feste Variante je Nutzer, uebernehmen statt erzeugen. Dieselben Erwartungen wie
// tests/test_testshare.py am PC (Fixture testshare/cases.json), der Ablauf `WeeklyTestShare.obtain` gegen einen
// Nachbau des Dienstes, die Verschluesselung mit dem Test-Chiffre (AES-GCM nur in der App) und die Anbindung im
// Wochentest-Endpunkt samt Migration der neuen Spalten.

/// Nachbau des Dienstes im Speicher (CloudKit in der App): Plaetze je Schluessel und Variante, Nutzer wechselbar,
/// Haken fuer Wettlaeufe
class FakeShareProvider: WeeklyTestShareProvider, @unchecked Sendable {
    struct Slot { var owner: String; var test: SharedWeeklyTest?; var since: Double }
    private let lock = NSLock()
    var store: [String: Slot] = [:]
    var user: String? = "_user-ada"
    var now: Double = 1_000
    var failing: Error?
    private(set) var claims = 0, publishes = 0, releases = 0, lookups = 0
    /// laeuft vor jedem Belegen (ein anderer Nutzer kommt dazwischen)
    var beforeClaim: (@Sendable (FakeShareProvider, String, Int) -> Void)?
    /// laeuft nach jedem Lesen der Plaetze (z. B. der andere wird fertig)
    var afterLookup: (@Sendable (FakeShareProvider, Int) -> Void)?

    var sourceName: String { "fake" }

    private func name(_ key: String, _ v: Int) -> String { "\(key)#\(v)" }
    private func check() throws { if let failing { throw failing } }

    func userID() async throws -> String? { try check(); return user }

    func slots(_ material: WeeklyTestMaterial) async throws -> [Int: WeeklyTestSlot] {
        try check()
        let n: Int = lock.withLock { lookups += 1; return lookups }
        afterLookup?(self, n)
        return lock.withLock {
            var out: [Int: WeeklyTestSlot] = [:]
            for v in 0..<TestShare.maxVariants {
                guard let s = store[name(material.key, v)] else { continue }
                out[v] = s.test.map { .ready($0) } ?? .pending(since: s.since)
            }
            return out
        }
    }

    func claim(_ material: WeeklyTestMaterial, variant: Int) async throws -> Bool {
        try check()
        beforeClaim?(self, material.key, variant)
        return lock.withLock {
            claims += 1
            guard store[name(material.key, variant)] == nil, let user else { return false }
            store[name(material.key, variant)] = Slot(owner: user, test: nil, since: now)
            return true
        }
    }

    /// wie ein anderer Nutzer von aussen (Wettlauf im Test)
    func plant(_ key: String, _ variant: Int, owner: String, test: SharedWeeklyTest?, since: Double? = nil) {
        lock.withLock { store[name(key, variant)] = Slot(owner: owner, test: test, since: since ?? now) }
    }

    func publish(_ material: WeeklyTestMaterial, variant: Int, test: SharedWeeklyTest) async throws {
        try check()
        try lock.withLock {
            publishes += 1
            guard var s = store[name(material.key, variant)], s.owner == user else { throw SolutionError.decryptionFailed }
            s.test = test
            store[name(material.key, variant)] = s
        }
    }

    func release(_ material: WeeklyTestMaterial, variant: Int) async throws {
        try check()
        lock.withLock {
            releases += 1
            if let s = store[name(material.key, variant)], s.owner == user, s.test == nil { store[name(material.key, variant)] = nil }
        }
    }

    var readyCount: Int { lock.withLock { store.values.filter { $0.test != nil }.count } }
}

final class TestShareVariantsTests: XCTestCase {
    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private let material = WeeklyTestMaterial(key: "wt2:" + String(repeating: "ab", count: 32), contentHashes: [String(repeating: "1", count: 64), String(repeating: "0", count: 64)])

    private func test(_ n: Int) -> SharedWeeklyTest {
        SharedWeeklyTest(title: "Reihen \(n)", questions: try! PyJSON.parse(#"[{"nr": 1, "question": "Aufgabe \#(n)", "points": 6.5, "answer": "ä"}]"#))
    }

    // MARK: Regel (rein, wie am PC)

    func testVariantAndPickMatchPythonFixture() throws {
        let doc = try JSONValue.parse(repo("packages/shared-contracts/fixtures/testshare/cases.json"))
        XCTAssertEqual(doc["max_variants"]?.int, TestShare.maxVariants)
        let variants = try XCTUnwrap(doc["variants"]?.array)
        XCTAssertFalse(variants.isEmpty)
        for c in variants {
            XCTAssertEqual(TestShare.variant(userID: c["user_id"]?.string ?? "", key: c["key"]?.string ?? ""), c["expected"]?.int, c["user_id"]?.string ?? "")
        }
        for c in try XCTUnwrap(doc["pick_cases"]?.array) {
            let ready = Set((c["ready"]?.array ?? []).compactMap { $0.int }), pending = Set((c["pending"]?.array ?? []).compactMap { $0.int })
            let got = TestShare.pick(ready: ready, assigned: c["assigned"]?.int ?? 0, pending: pending)
            XCTAssertEqual(got.action.rawValue, c["action"]?.string, "\(c)")
            XCTAssertEqual(got.variant, c["variant"]?.int, "\(c)")
        }
    }

    func testVariantIsStableAndEvenlyDistributedOver10000Users() {
        let key = material.key
        var counts = [Int](repeating: 0, count: TestShare.maxVariants)
        for i in 0..<10_000 {
            let v = TestShare.variant(userID: "_user-\(i)", key: key)
            XCTAssertEqual(v, TestShare.variant(userID: "_user-\(i)", key: key), "deterministisch")
            counts[v] += 1
        }
        for (v, n) in counts.enumerated() {
            XCTAssertTrue((3_000...3_600).contains(n), "Variante \(v): \(n) von 10000 (30-36 %)")
        }
        XCTAssertNotEqual(TestShare.variant(userID: "_user-1", key: key), TestShare.variant(userID: "_user-1", key: "wt2:" + String(repeating: "cd", count: 32)), "andere Schluessel verteilen anders")
    }

    func testPickRule() {
        XCTAssertEqual(TestShare.pick(ready: [], assigned: 2).action, .generate)
        XCTAssertEqual(TestShare.pick(ready: [], assigned: 2).variant, 2)
        XCTAssertEqual(TestShare.pick(ready: [2], assigned: 2).action, .adopt)
        XCTAssertEqual(TestShare.pick(ready: [2, 0], assigned: 2).variant, 2, "eigene fertig -> uebernehmen")
        XCTAssertEqual(TestShare.pick(ready: [2], assigned: 1).variant, 1, "eigene frei")
        XCTAssertEqual(TestShare.pick(ready: [], assigned: 1, pending: [1]).variant, 2, "eigene in Arbeit (Wettlauf): die naechste freie")
        XCTAssertEqual(TestShare.pick(ready: [0], assigned: 1, pending: [1]).variant, 2)
        XCTAssertEqual(TestShare.pick(ready: [0, 2], assigned: 1, pending: [1]).action, .adopt, "drei belegt: nie erzeugen")
        XCTAssertEqual(TestShare.pick(ready: [0, 2], assigned: 1, pending: [1]).variant, 2, "die naechste fertige, zyklisch")
        XCTAssertEqual(TestShare.pick(ready: [0], assigned: 1, pending: [1, 2]).variant, 0)
        XCTAssertEqual(TestShare.pick(ready: [0, 1, 2], assigned: 1).action, .adopt)
        XCTAssertEqual(TestShare.pick(ready: [], assigned: 1, pending: [0, 1, 2]).action, .none, "alle belegt, keine fertig")
        XCTAssertNil(TestShare.pick(ready: [], assigned: 1, pending: [0, 1, 2]).variant)
        XCTAssertEqual(TestShare.pick(ready: [7], assigned: 1, pending: [1]).variant, 2, "fremde Zahlen zaehlen nicht")
    }

    func testSharedInfoForTheViews() {
        XCTAssertEqual(TestShare.sharedInfo(variant: 1, adoptedFrom: "cloudkit"), ["variant": 2, "of": 3, "adopted": true])
        XCTAssertEqual(TestShare.sharedInfo(variant: 0, adoptedFrom: .null), ["variant": 1, "of": 3, "adopted": false])
        XCTAssertEqual(TestShare.sharedInfo(variant: nil, adoptedFrom: nil), .null)
        XCTAssertEqual(TestShare.sharedInfo(variant: .null, adoptedFrom: "x"), .null)
    }

    // MARK: Ablauf gegen den Nachbau

    private func obtain(_ fake: FakeShareProvider?, waiting: WeeklyTestShare.Waiting = .none, calls: UnsafeMutablePointer<Int>? = nil,
                        generate: @escaping @Sendable () async throws -> SharedWeeklyTest) async throws -> WeeklyTestShare.Outcome {
        let now = fake?.now ?? 0
        return try await WeeklyTestShare.obtain(material, provider: fake, waiting: waiting, now: { now }, generate: generate)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.withLock { n += 1; return n } }
        var count: Int { lock.withLock { n } }
    }

    func testFourStudentsThreeTestsTheFourthAdoptsAndNeverGenerates() async throws {
        let fake = FakeShareProvider()
        let ai = Counter()
        var outcomes: [String: WeeklyTestShare.Outcome] = [:]
        // vier Nutzer, deren Varianten 0, 1, 2 und wieder eine davon sind
        var users: [String] = []
        var seen = Set<Int>()
        var i = 0
        while seen.count < TestShare.maxVariants {
            let u = "_user-\(i)"; i += 1
            let v = TestShare.variant(userID: u, key: material.key)
            if seen.insert(v).inserted { users.append(u) }
        }
        users.append("_user-\(i)")
        for u in users {
            fake.user = u
            outcomes[u] = try await obtain(fake) { [ai] in SharedWeeklyTest(title: "T\(ai.bump())", questions: .array([])) }
        }
        XCTAssertEqual(ai.count, 3, "genau drei Tests fuer vier Studierende")
        XCTAssertEqual(fake.readyCount, 3)
        for u in users.prefix(3) {
            guard case .generated(let v, _, let published)? = outcomes[u] else { return XCTFail("\(u) erzeugt: \(String(describing: outcomes[u]))") }
            XCTAssertEqual(v, TestShare.variant(userID: u, key: material.key))
            XCTAssertTrue(published)
        }
        guard case .adopted(let v, let t, let from)? = outcomes[users[3]] else { return XCTFail("vierter uebernimmt") }
        XCTAssertEqual(v, TestShare.variant(userID: users[3], key: material.key))
        XCTAssertEqual(t, fake.store["\(material.key)#\(v)"]?.test)
        XCTAssertEqual(from, "fake")
        XCTAssertEqual(outcomes[users[3]]?.columns.adoptedFrom, "fake")
        // ein fuenfter mit derselben Variante wie der erste: uebernimmt den Test des ersten
        fake.user = users[0]
        guard case .adopted(_, let again, _) = try await obtain(fake, generate: { XCTFail("keine KI"); return SharedWeeklyTest(title: "x", questions: .array([])) }) else { return XCTFail() }
        XCTAssertEqual(again.title, outcomes[users[0]]?.test.title)
        XCTAssertEqual(ai.count, 3)
    }

    func testRaceTwoStudentsSameVariantOneGeneratesTheOtherWaitsAndAdopts() async throws {
        let fake = FakeShareProvider()
        let ada = "_user-ada", v = TestShare.variant(userID: ada, key: material.key)
        // Ben (gleiche Variante) hat gerade belegt und erzeugt noch: Ada sieht den Platz in Arbeit und wartet
        fake.plant(material.key, v, owner: "_user-ben", test: nil)
        let ready = test(7), key = material.key
        let polls = Counter()
        fake.afterLookup = { [ready] f, n in
            if n >= 3 { f.plant(key, v, owner: "_user-ben", test: ready) }       // Ben wird beim dritten Nachsehen fertig
        }
        let waiting = WeeklyTestShare.Waiting(pollSeconds: 1, maxWaitSeconds: 30, sleep: { [polls] _ in _ = polls.bump() })
        let outcome = try await obtain(fake, waiting: waiting) { XCTFail("Ada erzeugt nicht"); return SharedWeeklyTest(title: "x", questions: .array([])) }
        guard case .adopted(let got, let t, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(got, v)
        XCTAssertEqual(t, ready)
        XCTAssertEqual(fake.claims, 0)
        XCTAssertGreaterThanOrEqual(polls.count, 1, "gewartet statt doppelt erzeugt")
    }

    func testLostClaimRaceLooksAgainAdoptsTheWinnerOrTakesTheNextFreeVariant() async throws {
        let fake = FakeShareProvider()
        let ada = "_user-ada", v = TestShare.variant(userID: ada, key: material.key)
        let other = test(1)
        // zwischen Lesen und Belegen gewinnt ein anderer genau diesen Platz, und zwar schon fertig
        fake.beforeClaim = { [other] f, key, variant in
            if f.claims == 0 { f.plant(key, variant, owner: "_user-ben", test: other) }
        }
        let outcome = try await obtain(fake) { SharedWeeklyTest(title: "mine", questions: .array([])) }
        // nach dem verlorenen Wettlauf ist die eigene Variante fertig: uebernehmen statt erzeugen
        guard case .adopted(let got, let t, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(got, v)
        XCTAssertEqual(t, other)
        XCTAssertEqual(fake.claims, 1)

        // der Gewinner ist noch nicht fertig und es wird nicht gewartet (kein Zeitbudget): die naechste freie Variante
        let fake2 = FakeShareProvider()
        fake2.beforeClaim = { f, key, variant in
            if f.claims == 0 { f.plant(key, variant, owner: "_user-ben", test: nil) }
        }
        let second = try await obtain(fake2) { SharedWeeklyTest(title: "mine", questions: .array([])) }
        guard case .generated(let next, _, let published) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(next, (v + 1) % TestShare.maxVariants)
        XCTAssertTrue(published)
        XCTAssertEqual(fake2.claims, 2)
    }

    func testWaitTimesOutThenGeneratesTheNextFreeVariant() async throws {
        let fake = FakeShareProvider()
        let v = TestShare.variant(userID: "_user-ada", key: material.key)
        fake.plant(material.key, v, owner: "_user-ben", test: nil)
        let waiting = WeeklyTestShare.Waiting(pollSeconds: 1, maxWaitSeconds: 2, sleep: { _ in })
        let outcome = try await obtain(fake, waiting: waiting) { SharedWeeklyTest(title: "mine", questions: .array([])) }
        guard case .generated(let got, _, let published) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(got, (v + 1) % TestShare.maxVariants, "naechste freie, der andere behaelt seinen Platz")
        XCTAssertTrue(published)
        XCTAssertEqual(fake.readyCount, 1)
    }

    func testStalePendingOfAnotherIsNotWaitedForAndNeverOverwritten() async throws {
        let fake = FakeShareProvider()
        let v = TestShare.variant(userID: "_user-ada", key: material.key)
        fake.plant(material.key, v, owner: "_user-ben", test: nil, since: fake.now - 3_600)       // verwaist (Geraet weg)
        let outcome = try await obtain(fake, waiting: WeeklyTestShare.Waiting(pollSeconds: 1, maxWaitSeconds: 30, sleep: { _ in XCTFail("nicht warten") })) {
            SharedWeeklyTest(title: "mine", questions: .array([]))
        }
        guard case .generated(let got, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotEqual(got, v)
        XCTAssertNil(fake.store["\(material.key)#\(v)"]?.test, "fremder Platz bleibt")
    }

    func testAllThreeTakenNoneReadyGivesAnOwnTestWithoutPublishing() async throws {
        let fake = FakeShareProvider()
        for v in 0..<TestShare.maxVariants { fake.plant(material.key, v, owner: "_user-\(v)", test: nil, since: fake.now - 3_600) }
        let outcome = try await obtain(fake) { SharedWeeklyTest(title: "mine", questions: .array([])) }
        guard case .unshared(let v, let t) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(v, TestShare.variant(userID: "_user-ada", key: material.key))
        XCTAssertEqual(t.title, "mine")
        XCTAssertEqual(fake.claims, 0)
        XCTAssertEqual(fake.readyCount, 0)
    }

    func testThreeReadyAdoptsTheNearestOtherWhenOwnIsBroken() async throws {
        let fake = FakeShareProvider()
        let v = TestShare.variant(userID: "_user-ada", key: material.key)
        for i in 0..<TestShare.maxVariants where i != v { fake.plant(material.key, i, owner: "_user-\(i)", test: test(i)) }
        fake.plant(material.key, v, owner: "_user-x", test: nil, since: fake.now - 3_600)
        let outcome = try await obtain(fake) { XCTFail("nie erzeugen"); return SharedWeeklyTest(title: "x", questions: .array([])) }
        guard case .adopted(let got, let t, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(got, (v + 1) % TestShare.maxVariants)
        XCTAssertEqual(t, test(got))
    }

    func testGenerationFailureReleasesTheClaimAndRethrows() async throws {
        let fake = FakeShareProvider()
        struct Boom: Error {}
        do {
            _ = try await obtain(fake) { throw Boom() }
            XCTFail("wirft")
        } catch is Boom {}
        XCTAssertEqual(fake.claims, 1)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertTrue(fake.store.isEmpty, "Platz wieder frei")
    }

    func testPublishFailureKeepsTheTestLocally() async throws {
        final class NoPublish: FakeShareProvider {
            override func publish(_ material: WeeklyTestMaterial, variant: Int, test: SharedWeeklyTest) async throws { throw SolutionError.decryptionFailed }
        }
        let fake = NoPublish()
        let outcome = try await obtain(fake) { SharedWeeklyTest(title: "mine", questions: .array([])) }
        guard case .generated(_, let t, let published) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(published)
        XCTAssertEqual(t.title, "mine")
        XCTAssertEqual(fake.releases, 1)
    }

    func testWithoutProviderOrSignInOrServiceTheOwnTestIsUsed() async throws {
        let none = try await obtain(nil) { SharedWeeklyTest(title: "own", questions: .array([])) }
        XCTAssertEqual(none, .unshared(variant: nil, SharedWeeklyTest(title: "own", questions: .array([]))))
        let fake = FakeShareProvider()
        fake.user = nil                                                       // kein iCloud-Konto
        let anon = try await obtain(fake) { SharedWeeklyTest(title: "own", questions: .array([])) }
        XCTAssertEqual(anon.columns.variant, nil)
        XCTAssertEqual(fake.claims, 0)
        fake.user = "_user-ada"
        fake.failing = SolutionError.decryptionFailed                         // Dienst nicht erreichbar
        let offline = try await obtain(fake) { SharedWeeklyTest(title: "own", questions: .array([])) }
        guard case .unshared(let v, _) = offline else { return XCTFail("\(offline)") }
        XCTAssertNil(v, "ohne Nutzerkennung keine Variante")
    }

    // MARK: Verschluesselung (Format wie in der App, hier mit dem Test-Chiffre)

    func testPayloadRoundTripAndWrongFilesCannotDecrypt() throws {
        let cipher = TestHMACCipher()
        let t = test(3)
        let payload = try WeeklyTestCrypto.seal(t, material: material, variant: 1, cipher: cipher)
        XCTAssertEqual(try WeeklyTestCrypto.open(payload, material: material, variant: 1, cipher: cipher), t)
        XCTAssertFalse(payload.contains("Aufgabe"), "nur Chiffrat")
        // andere Dateien (anderes Blatt): gleicher Schluessel-Text, anderes Material -> nicht lesbar
        let other = WeeklyTestMaterial(key: material.key, contentHashes: [String(repeating: "2", count: 64)])
        XCTAssertThrowsError(try WeeklyTestCrypto.open(payload, material: other, variant: 1, cipher: cipher))
        // andere Variante oder anderer Schluessel (Zusatzdaten): nicht umhaengbar
        XCTAssertThrowsError(try WeeklyTestCrypto.open(payload, material: material, variant: 2, cipher: cipher))
        XCTAssertThrowsError(try WeeklyTestCrypto.open(payload, material: WeeklyTestMaterial(key: "wt2:" + String(repeating: "ef", count: 32), contentHashes: material.contentHashes), variant: 1, cipher: cipher))
        // veraendert
        var bytes = Data(base64Encoded: payload)!
        bytes[bytes.count - 1] ^= 1
        XCTAssertThrowsError(try WeeklyTestCrypto.open(bytes.base64EncodedString(), material: material, variant: 1, cipher: cipher))
        XCTAssertThrowsError(try WeeklyTestCrypto.open("nicht base64 ###", material: material, variant: 1, cipher: cipher))
        // Schluesselmaterial: sortierte, eindeutige Hashes, Reihenfolge egal
        XCTAssertEqual(WeeklyTestCrypto.keyMaterial(contentHashes: ["b", "a", "b"]), Data("a\nb".utf8))
        XCTAssertEqual(WeeklyTestCrypto.recordName(key: "wt2:x", variant: 2), "wt2:x#2")
    }

    func testPlaintextKeepsPythonJSONBytes() throws {
        let t = test(5)
        XCTAssertEqual(String(decoding: t.plaintext, as: UTF8.self), #"{"questions": [{"nr": 1, "question": "Aufgabe 5", "points": 6.5, "answer": "ä"}], "title": "Reihen 5"}"#)
        XCTAssertEqual(try SharedWeeklyTest(plaintext: t.plaintext), t)
        XCTAssertThrowsError(try SharedWeeklyTest(plaintext: Data(#"{"title": 1, "questions": []}"#.utf8)))
        XCTAssertThrowsError(try SharedWeeklyTest(plaintext: Data(#"{"title": "x"}"#.utf8)))
    }

    // MARK: Anbindung im Wochentest-Endpunkt und Migration

    private func backend() async throws -> LocalBackend {
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
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized()))
    }

    private func waitForJob(_ b: LocalBackend) async throws -> String {
        for _ in 0..<300 {
            let bg = await call(b, "GET", "/api/bg").json
            if bg?["running"] == false { return bg?["message"]?.string ?? "" }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Hintergrundauftrag endet nicht")
        return ""
    }

    func testWeeklyTestAdoptsFromTheServiceAndMarksTheRow() async throws {
        let b = try await backend()
        let fake = FakeShareProvider()
        b.context.testShare.set(fake, waiting: .none)
        let ai = ScriptedAI([TestEndpointsTests.validTest(title: "Wochentest Testmathe – Reihen")])
        b.context.ai.set(ai)
        // Schluessel wie der Endpunkt ihn rechnet (Uni der Datenbank, 45 min, beide Dateien), Variante des Nutzers
        let key = try XCTUnwrap(TestShare.shareKey(university: Migrations.defaultUniversity, minutes: 45,
                                                   contentHashes: [String(repeating: "0", count: 64), String(repeating: "1", count: 64)]))
        let v = TestShare.variant(userID: "_user-ada", key: key)
        let planted = SharedWeeklyTest(title: "Wochentest Testmathe – Reihen (geteilt)",
                                       questions: AIPrompts.get(try PyJSON.parse(TestEndpointsTests.validTest()), "questions") ?? .array([]))
        fake.plant(key, v, owner: "_user-ben", test: planted)
        _ = await call(b, "POST", "/api/tests/generate-week")
        let message = try await waitForJob(b)
        XCTAssertEqual(message, "Wochentests: fertig (1 klassisch, 0 mit Seitenmarker)")
        XCTAssertEqual(ai.calls, 0, "uebernommen, keine KI")
        let r1 = try await b.context.database.queryOne("SELECT share_key, share_variant, adopted_from, title, questions FROM tests")
        let row = try XCTUnwrap(r1)
        XCTAssertEqual(row["share_key"]?.string, key)
        XCTAssertEqual(row["share_variant"]?.int, v)
        XCTAssertEqual(row["adopted_from"]?.string, "fake")
        XCTAssertEqual(row["title"]?.string, "Lehrwoche 1: Reihen (geteilt)")
        XCTAssertEqual(row["questions"]?.string, planted.questions.dumps(ensureASCII: false), "Aufgaben byte-gleich")
        // JSON fuer die Ansichten: shared {variant 1-basiert, of, adopted}
        let l1 = await call(b, "GET", "/api/tests").json?.array?.first
        let list = try XCTUnwrap(l1)
        XCTAssertEqual(list["shared"], ["variant": .number(Double(v + 1)), "of": 3, "adopted": true])
        XCTAssertNil(list["share_variant"])
        let id = Int(list["id"]?.double ?? 0)
        let d1 = await call(b, "GET", "/api/tests/\(id)").json
        let detail = try XCTUnwrap(d1)
        XCTAssertEqual(detail["shared"], ["variant": .number(Double(v + 1)), "of": 3, "adopted": true])
        XCTAssertEqual(detail["share_variant"]?.int, v)
    }

    func testWeeklyTestGeneratesPublishesAndReportsThePhase() async throws {
        let b = try await backend()
        let fake = FakeShareProvider()
        let seen = NSMutableArray()
        b.context.testShare.set(fake, waiting: .none)
        final class PhaseAI: AIProvider, @unchecked Sendable {
            let jobs: LocalBackgroundJob, seen: NSMutableArray
            init(jobs: LocalBackgroundJob, seen: NSMutableArray) { self.jobs = jobs; self.seen = seen }
            func answer(system: String, prompt: String) async throws -> String {
                seen.add(await jobs.state["phase"]?.string ?? "-")
                return TestEndpointsTests.validTest()
            }
        }
        b.context.ai.set(PhaseAI(jobs: b.context.jobs, seen: seen))
        _ = await call(b, "POST", "/api/tests/generate-week")
        _ = try await waitForJob(b)
        XCTAssertEqual(seen as? [String], ["generate"], "waehrend der KI: Phase generate; vorher shared_lookup")
        XCTAssertEqual(fake.publishes, 1)
        let r2 = try await b.context.database.queryOne("SELECT share_variant, adopted_from FROM tests")
        let row = try XCTUnwrap(r2)
        XCTAssertEqual(row["adopted_from"], .null)
        XCTAssertNotNil(row["share_variant"]?.int)
        XCTAssertEqual(fake.readyCount, 1, "veroeffentlicht")
        let bg1 = await call(b, "GET", "/api/bg").json
        let bg = try XCTUnwrap(bg1)
        XCTAssertNil(bg["phase"], "nach dem Auftrag wie am PC")
        let d2 = await call(b, "GET", "/api/tests").json?.array?.first
        let detail = try XCTUnwrap(d2)
        XCTAssertEqual(detail["shared"]?["adopted"], false)
        XCTAssertEqual(detail["shared"]?["of"], 3)
    }

    func testWithoutServiceTheOwnVariantIsRememberedWithoutAdoption() async throws {
        let b = try await backend()
        XCTAssertNil(b.context.testShare.provider)
        b.context.ai.set(ScriptedAI([TestEndpointsTests.validTest()]))
        _ = await call(b, "POST", "/api/tests/generate-week")
        _ = try await waitForJob(b)
        let r3 = try await b.context.database.queryOne("SELECT share_variant, adopted_from FROM tests")
        let row = try XCTUnwrap(r3)
        XCTAssertEqual(row["share_variant"], .null, "ohne Dienst keine Nutzerkennung, keine Variante")
        XCTAssertEqual(row["adopted_from"], .null)
        let l2 = await call(b, "GET", "/api/tests").json?.array?.first
        let list = try XCTUnwrap(l2)
        XCTAssertEqual(list["shared"], .null)
    }

    func testMigrationAddsShareVariantAndAdoptedFromToOldDatabases() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { c in
            try c.execute("""
                CREATE TABLE tests (id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, week_start TEXT, title TEXT,
                                    duration_min INTEGER, questions TEXT NOT NULL, created_at TEXT, started_at TEXT, submitted_at TEXT,
                                    answers TEXT, score REAL, max_score REAL, feedback TEXT)
                """)
            try c.execute("INSERT INTO tests(subject, questions) VALUES ('Algebra', '[]')")
            XCTAssertFalse(try c.columnNames("tests").contains("share_variant"))
            try Migrations.migrate(c, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
            let cols = try c.columnNames("tests")
            let i = try XCTUnwrap(cols.firstIndex(of: "share_key"))
            XCTAssertEqual(Array(cols[i...i + 2]), ["share_key", "share_variant", "adopted_from"], "direkt hinter share_key wie in app/db.py")
            XCTAssertEqual(try c.queryOne("SELECT share_variant, adopted_from FROM tests")?["share_variant"], .null)
            try Migrations.migrate(c, clock: .fixed(berlin: "2026-11-04T10:00:00")!)        // idempotent
            XCTAssertEqual(try c.columnNames("tests").filter { $0 == "share_variant" }.count, 1)
        }
    }
}
