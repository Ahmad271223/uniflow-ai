import Foundation
import XCTest
@testable import UniFlowCore

// Geteilte Wochenstapel und "Stapel teilen" (Entscheidung des Inhabers vom 04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md):
// Schluessel, Namen, Prompt und Klartext wie am PC (Fixture cardshare/cases.json), Verschluesselung der geteilten Stapel
// mit dem Test-Chiffre, Wochenstapel holen oder erzeugen ueber den Varianten-Dienst (uebernehmen = keine KI), eigene
// Stapel teilen, uebernehmen und zurueckziehen ueber einen Nachbau der Community, nie ueber Module hinweg.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/cardshare/cases.json")))
}

/// Nachbau der Modul-Community im Speicher (CloudKit in der App): geteilte Stapel je Kennung, Chiffrat mit dem Test-Chiffre
final class FakeCardCommunity: CardStackCommunityProvider, @unchecked Sendable {
    struct Entry { var summary: SharedCardStackSummary; var payload: String; var withdrawn = false; var likes: Set<String> = []; var reports: [String] = [] }
    private let lock = NSLock()
    var store: [String: Entry] = [:]
    var user: String? = "_user-ada"
    var failing: Error?
    let cipher = TestHMACCipher()
    private(set) var publishes = 0

    private func check() throws { if let failing { throw failing } }

    func userID() async throws -> String? { try check(); return user }

    func publish(_ draft: CardStackDraft, secret: Data) async throws -> String {
        try check()
        guard let user else { throw SolutionError.decryptionFailed }
        let id = UUID().uuidString.lowercased()
        let payload = try CardStackCrypto.seal(draft.cards, secret: secret, communityKey: draft.communityKey, id: id, cipher: cipher)
        let s = SharedCardStackSummary(id: id, communityKey: draft.communityKey, name: draft.name, kind: draft.kind, week: draft.week,
                                       cardCount: draft.cards.count, pseudonym: "Studi-" + user, createdAt: "2026-11-04T10:00:00Z", isOwn: true)
        lock.withLock { store[id] = Entry(summary: s, payload: payload); publishes += 1 }
        return id
    }

    func withdraw(id: String) async throws {
        try check()
        try lock.withLock {
            guard var e = store[id] else { throw SolutionError.decryptionFailed }
            guard e.summary.pseudonym == "Studi-" + (user ?? "") else { throw SolutionError.decryptionFailed }
            e.withdrawn = true
            store[id] = e
        }
    }

    private func view(_ e: Entry) -> SharedCardStackSummary {
        var s = e.summary
        s.isOwn = s.pseudonym == "Studi-" + (user ?? "")
        s.likes = e.likes.count
        s.likedByMe = user.map { e.likes.contains($0) } ?? false
        return s
    }

    func list(communityKey: String) async throws -> [SharedCardStackSummary] {
        try check()
        return lock.withLock { store.values.filter { !$0.withdrawn && $0.summary.communityKey == communityKey }.map(view).sorted { $0.id < $1.id } }
    }

    func summary(id: String) async throws -> SharedCardStackSummary? {
        try check()
        return lock.withLock { store[id].flatMap { $0.withdrawn ? nil : view($0) } }
    }

    func cards(id: String, communityKey: String, secret: Data) async throws -> [AIAnswers.Flashcard] {
        try check()
        guard let e = lock.withLock({ store[id] }), !e.withdrawn else { throw SolutionError.decryptionFailed }
        return try CardStackCrypto.open(e.payload, secret: secret, communityKey: communityKey, id: id, cipher: cipher)
    }

    func like(id: String, on: Bool) async throws -> Int {
        try check()
        return try lock.withLock {
            guard var e = store[id], let user else { throw SolutionError.decryptionFailed }
            if on { e.likes.insert(user) } else { e.likes.remove(user) }
            store[id] = e
            return e.likes.count
        }
    }

    func report(id: String, reason: String, note: String?) async throws {
        try check()
        lock.withLock { store[id]?.reports.append(reason) }
    }
}

/// Zaehlende Schein-KI mit Karten; die Antwort nennt den Lauf
final class CountingCardsAI: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var prompts: [String] = []
    var fail = false
    func answer(system: String, prompt: String) async throws -> String { try await answer(system: system, prompt: prompt, schema: nil) }
    func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        let n: Int = lock.withLock { calls += 1; prompts.append(prompt); return calls }
        if fail { throw AIError("ai_provider_error", "Der KI-Anbieter antwortete mit Fehler 500.") }
        return #"{"cards": [{"question": "Was ist eine Reihe? (Lauf \#(n))", "answer": "Summe einer Folge."}, {"question": "", "answer": "x"}, {"question": "Majorante?", "answer": "Vergleichsreihe ä"}]}"#
    }
}

final class CardStackShareTests: XCTestCase {
    private let hashes = [String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "c", count: 64)]

    // MARK: Reine Funktionen gegen die Fixture

    func testKeysNamesPromptAndPlaintextMatchPython() throws {
        let fx = try fixture()
        XCTAssertEqual(fx["version"]?.string, CardStackShare.version)
        XCTAssertEqual(fx["kinds"]?.array?.compactMap(\.string), CardStackShare.kinds)
        XCTAssertEqual(fx["week_cards"]?.int, CardStackShare.weekCards)
        XCTAssertEqual(fx["max_cards"]?.int, AIPrompts.flashcardsMax)
        XCTAssertEqual(fx["max_variants"]?.int, CardStackShare.maxVariants)
        for (k, v) in fx["week_doc_types"]?.object ?? [:] { XCTAssertEqual(v.array?.compactMap(\.string), CardStackShare.weekDocTypes[k], k) }
        for cs in fx["cases"]?.array ?? [] {
            let got = CardStackShare.weekKey(university: cs["university"]?.string ?? "", kind: cs["kind"]?.string ?? "",
                                             contentHashes: cs["materials"]?.array?.map(\.string) ?? [])
            XCTAssertEqual(got, cs["expected_key"]?.string, cs["name"]?.string ?? "")
        }
        for u in fx["unsafe"]?.array ?? [] {
            XCTAssertNil(CardStackShare.weekKey(university: u["university"]?.string ?? "", kind: u["kind"]?.string ?? "",
                                                contentHashes: u["materials"]?.array?.map(\.string) ?? []), u["name"]?.string ?? "")
        }
        for n in fx["stack_names"]?.array ?? [] {
            XCTAssertEqual(CardStackShare.stackName(kind: n["kind"]?.string ?? "", week: n["week"]?.int ?? 0), n["name"]?.string)
        }
        let p = try XCTUnwrap(fx["prompt"])
        let files = (p["files"]?.array ?? []).map { CardStackShare.WeekFile(name: $0["name"]?.string ?? "", text: $0["text"]?.string ?? "") }
        XCTAssertEqual(CardStackShare.weekText(files), p["week_text"]?.string)
        XCTAssertEqual(CardStackShare.prompt(module: p["module"]?.string ?? "", kind: p["kind"]?.string ?? "", week: p["week"]?.int ?? 0, files: files), p["expected"]?.string)
        let cards = (fx["plaintext"]?["cards"]?.array ?? []).map { AIAnswers.Flashcard(question: $0["question"]?.string ?? "", answer: $0["answer"]?.string ?? "") }
        let canon = CardStackShare.canonicalCards(cards)
        XCTAssertEqual(canon, fx["plaintext"]?["expected"]?.string)
        XCTAssertEqual(try CardStackShare.parseCards(Data(canon.utf8)), cards)
        for r in fx["record_names"]?.array ?? [] {
            XCTAssertEqual(WeeklyTestCrypto.recordName(key: r["key"]?.string ?? "", variant: r["variant"]?.int ?? -1), r["name"]?.string)
        }
        // Abbild beim Varianten-Dienst: Art als Pruefwert, Karten als Aufgaben
        let pool = CardStackShare.poolTest(kind: "uebung", cards: cards)
        XCTAssertEqual(pool.title, "uebung")
        XCTAssertEqual(CardStackShare.cards(from: pool, kind: "uebung"), cards)
        XCTAssertEqual(CardStackShare.cards(from: pool, kind: "vorlesung"), [], "andere Art: nichts")
        XCTAssertEqual(try SharedWeeklyTest(plaintext: pool.plaintext), pool, "Rundlauf durch den Klartext des Wochentests")
    }

    func testCommunityCipherBindsSecretKeyAndID() throws {
        let cipher = TestHMACCipher()
        let cards = [AIAnswers.Flashcard(question: "Q ä", answer: "A \"z\"\n2")]
        let secret = CommunityKeys.secret(university: "luh", moduleName: "Analysis I")
        let key = try XCTUnwrap(CommunityKeys.courseKey(university: "luh", courseName: "Analysis I"))
        let payload = try CardStackCrypto.seal(cards, secret: secret, communityKey: key, id: "ABC-1", cipher: cipher)
        XCTAssertFalse(payload.contains("Q ä"))
        XCTAssertEqual(try CardStackCrypto.open(payload, secret: secret, communityKey: key, id: "abc-1", cipher: cipher), cards, "Kennung klein wie gross")
        XCTAssertThrowsError(try CardStackCrypto.open(payload, secret: CommunityKeys.secret(university: "luh", moduleName: "Physik I"), communityKey: key, id: "abc-1", cipher: cipher))
        XCTAssertThrowsError(try CardStackCrypto.open(payload, secret: secret, communityKey: "x" + key.dropFirst(), id: "abc-1", cipher: cipher), "nicht in ein anderes Modul umhaengbar")
        XCTAssertThrowsError(try CardStackCrypto.open(payload, secret: secret, communityKey: key, id: "abc-2", cipher: cipher))
        var raw = try XCTUnwrap(Data(base64Encoded: payload))
        raw[raw.count - 1] ^= 1
        XCTAssertThrowsError(try CardStackCrypto.open(raw.base64EncodedString(), secret: secret, communityKey: key, id: "abc-1", cipher: cipher))
        XCTAssertThrowsError(try CardStackCrypto.open("kein base64", secret: secret, communityKey: key, id: "abc-1", cipher: cipher))
    }

    // MARK: Backend eines Studierenden

    /// Modul "Analysis I" (Kurs mit Modul-ID) und Dateien der Lehrwoche 5: Vorlesung und Skript (Inhalts-Hashes a, b), Blatt (c)
    private func backend(module: String = "Analysis I", files: [(id: String, name: String, type: String, hash: String?)]? = nil,
                         share: WeeklyTestShareProvider? = nil, community: CardStackCommunityProvider? = nil,
                         ai: AIProvider? = nil) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let monday = 1_793_052_000.0      // Mo 2026-10-26 (Berlin)
        let list = files ?? [("f-vl5", "VL05.pdf", "vorlesung", hashes[0]), ("f-sk5", "Skript_Kap05.pdf", "skript", hashes[1]), ("f-bl5", "Blatt05.pdf", "uebung", hashes[2])]
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at, active) VALUES (7, ?, '#123456', '2026-10-01', 1)", [.text(module)])
            _ = try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active, subject) VALUES ('k1', ?, 'vorlesung', '2026-10-01', 7, 1, ?)",
                              [.text(module + " (WS 2026/27)"), .text(module)])
            for (i, f) in list.enumerated() {
                _ = try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, local_path, text_excerpt, content_sha256) VALUES (?, 'k1', ?, ?, 'pdf', ?, ?, ?)",
                                  [.text(f.id), .text(f.name), .integer(Int64(monday) + Int64(i * 3600)), .text("k1/\(f.name)"), .text("Text von \(f.name)"),
                                   f.hash.map(SQLiteValue.text) ?? .null])
                _ = try c.execute("INSERT INTO analysis(file_id, doc_type, title, raw) VALUES (?, ?, ?, '{}')", [.text(f.id), .text(f.type), .text(f.name)])
            }
        }
        if let share { b.context.cardShare.set(share, waiting: .none) }
        b.context.cardCommunity.set(community)
        b.context.ai.set(ai)
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized()))
    }

    // MARK: Wochenstapel

    func testWeekStackIsGeneratedOnceAndAdoptedByTheNextStudent() async throws {
        let pool = FakeShareProvider()
        pool.user = "_user-ada"
        let ai = CountingCardsAI()
        let ada = try await backend(share: pool, ai: ai)
        // Stand ohne Erzeugen
        var r = await call(ada, "GET", "/api/flashcard-stacks/week/7/5/vorlesung")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json, ["stack": .null, "files": 2, "name": "Vorlesung Woche 5", "shareable": true])
        XCTAssertEqual(ai.calls, 0)
        // holen oder erzeugen: erzeugt (1 KI-Anfrage), veroeffentlicht, eigener Stapel mit Karten
        r = await call(ada, "POST", "/api/flashcard-stacks/week/7/5/vorlesung")
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let a = try XCTUnwrap(r.json)
        XCTAssertEqual(a["status"]?.string, "generated")
        XCTAssertEqual(a["of"]?.int, 3)
        XCTAssertEqual(a["variant"]?.int, TestShare.variant(userID: "_user-ada", key: a["stack"]?["source_ref"]?.string ?? "") + 1)
        let stack = try XCTUnwrap(a["stack"])
        XCTAssertEqual(stack["name"]?.string, "Vorlesung Woche 5")
        XCTAssertEqual(stack["subject"]?.string, "Analysis I")
        XCTAssertEqual(stack["kind"]?.string, "vorlesung")
        XCTAssertEqual(stack["week"]?.int, 5)
        XCTAssertEqual(stack["source"]?.string, "week")
        XCTAssertEqual(stack["cards"]?.int, 2)
        XCTAssertEqual(stack["due"]?.int, 2)
        XCTAssertEqual(stack["file_id"], .null)
        XCTAssertEqual(stack["shared_id"], .null)
        let key = try XCTUnwrap(stack["source_ref"]?.string)
        XCTAssertEqual(key, CardStackShare.weekKey(university: Migrations.defaultUniversity, kind: "vorlesung", contentHashes: [hashes[0], hashes[1]]))
        XCTAssertEqual(ai.calls, 1)
        XCTAssertTrue(ai.prompts[0].hasPrefix("Kurs: Analysis I\nDatei: Vorlesung Woche 5\n\nAUFGABE: Erstelle genau 20 Karteikarten"))
        XCTAssertTrue(ai.prompts[0].contains("### Datei: VL05.pdf\nText von VL05.pdf") && ai.prompts[0].contains("### Datei: Skript_Kap05.pdf"))
        XCTAssertFalse(ai.prompts[0].contains("Blatt05"))
        XCTAssertEqual(pool.publishes, 1)
        let cards = await call(ada, "GET", "/api/flashcards?stack_id=\(stack["id"]?.int ?? 0)&due=1").json?.array ?? []
        XCTAssertEqual(Set(cards.compactMap { $0["question"]?.string }), ["Was ist eine Reihe? (Lauf 1)", "Majorante?"])
        XCTAssertTrue(cards.allSatisfy { $0["box"]?.int == 1 && $0["subject"]?.string == "Analysis I" })
        // ein zweites Mal: der vorhandene Stapel, keine KI
        r = await call(ada, "POST", "/api/flashcard-stacks/week/7/5/vorlesung")
        XCTAssertEqual(r.json?["status"]?.string, "exists")
        XCTAssertEqual(r.json?["stack"]?["id"], stack["id"])
        do { let r_ = await call(ada, "GET", "/api/flashcard-stacks/week/7/5/vorlesung"); XCTAssertEqual(r_.json?["stack"]?["id"], stack["id"]) }
        XCTAssertEqual(ai.calls, 1)
        // Ben: dieselben Dateien, dieselbe Variante -> uebernommen ohne KI, eigener Stapel unter seinem Modulnamen
        var ben = "_user-ben"
        var i = 0
        while TestShare.variant(userID: ben, key: key) != TestShare.variant(userID: "_user-ada", key: key) { i += 1; ben = "_user-ben-\(i)" }
        pool.user = ben
        let benAI = CountingCardsAI()
        let benBackend = try await backend(module: "Analysis für alle", share: pool, ai: benAI)
        r = await call(benBackend, "POST", "/api/flashcard-stacks/week/7/5/vorlesung")
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["status"]?.string, "adopted")
        XCTAssertEqual(r.json?["variant"]?.int, a["variant"]?.int)
        XCTAssertEqual(r.json?["stack"]?["subject"]?.string, "Analysis für alle")
        XCTAssertEqual(r.json?["stack"]?["source_ref"]?.string, key)
        XCTAssertEqual(benAI.calls, 0, "uebernehmen kostet keine KI")
        let benCards = await call(benBackend, "GET", "/api/flashcards?stack_id=\(r.json?["stack"]?["id"]?.int ?? 0)").json?.array ?? []
        XCTAssertEqual(benCards.map { $0["question"]?.string ?? "" }.sorted(), ["Majorante?", "Was ist eine Reihe? (Lauf 1)"])
        // Lernstand bleibt je Person
        _ = await call(benBackend, "POST", "/api/flashcards/\(benCards[0]["id"]?.int ?? 0)/review", ["correct": true])
        let adaBoxes = await call(ada, "GET", "/api/flashcards").json?.array?.compactMap { $0["box"]?.int } ?? []
        XCTAssertEqual(adaBoxes, [1, 1])
        // Uebung derselben Woche: eigener Schluessel, erzeugt
        r = await call(benBackend, "POST", "/api/flashcard-stacks/week/7/5/uebung")
        XCTAssertEqual(r.json?["status"]?.string, "generated")
        XCTAssertEqual(r.json?["stack"]?["name"]?.string, "Übung Woche 5")
        XCTAssertNotEqual(r.json?["stack"]?["source_ref"]?.string, key)
        XCTAssertEqual(benAI.calls, 1)
        XCTAssertTrue(benAI.prompts[0].contains("### Datei: Blatt05.pdf") && !benAI.prompts[0].contains("VL05"))
        // Fehler: ohne Unterlagen 404, falsche Art und Woche 0 422, unbekanntes Modul 404; dabei keine KI
        var e = await call(ada, "POST", "/api/flashcard-stacks/week/7/6/uebung")
        XCTAssertEqual(e.status, 404)
        XCTAssertEqual(e.json?["detail"]?["code"]?.string, "no_materials")
        do { let r_ = await call(ada, "GET", "/api/flashcard-stacks/week/7/6/vorlesung"); XCTAssertEqual(r_.json, ["stack": .null, "files": 0, "name": "Vorlesung Woche 6", "shareable": false]) }
        e = await call(ada, "POST", "/api/flashcard-stacks/week/7/5/eigene")
        XCTAssertEqual(e.status, 422)
        e = await call(ada, "POST", "/api/flashcard-stacks/week/7/0/vorlesung")
        XCTAssertEqual(e.status, 422)
        e = await call(ada, "POST", "/api/flashcard-stacks/week/99/5/vorlesung")
        XCTAssertEqual(e.status, 404)
        XCTAssertEqual(ai.calls, 1)
        // scheitert die KI, bleibt kein Platz belegt und kein Stapel zurueck
        benAI.fail = true
        let cid = try await backend(module: "Analysis I", files: [("f-x", "VL06.pdf", "vorlesung", hashes[2])], share: pool, ai: benAI)
        e = await call(cid, "POST", "/api/flashcard-stacks/week/7/6/vorlesung")
        XCTAssertEqual(e.status, 503)
        do { let r_ = await call(cid, "GET", "/api/flashcard-stacks"); XCTAssertEqual(r_.json?.array?.count, 0) }
        let k6 = try XCTUnwrap(CardStackShare.weekKey(university: Migrations.defaultUniversity, kind: "vorlesung", contentHashes: [hashes[2]]))
        XCTAssertTrue(pool.store.keys.filter { $0.hasPrefix(k6) }.isEmpty, "Platz wieder frei")
    }

    func testWeekStackWithoutServiceOrHashesStaysPrivate() async throws {
        let ai = CountingCardsAI()
        let b = try await backend(files: [("f-vl5", "VL05.pdf", "vorlesung", nil)], ai: ai)
        do { let r_ = await call(b, "GET", "/api/flashcard-stacks/week/7/5/vorlesung"); XCTAssertEqual(r_.json?["shareable"]?.bool, false) }
        let r = await call(b, "POST", "/api/flashcard-stacks/week/7/5/vorlesung")
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["status"]?.string, "unshared")
        XCTAssertEqual(r.json?["variant"], .null)
        XCTAssertEqual(r.json?["stack"]?["source_ref"]?.string, "")
        XCTAssertEqual(ai.calls, 1)
        // mit Hashes, aber ohne Dienst: eigener Stapel, Variante gemerkt
        let c = try await backend(ai: ai)
        let r2 = await call(c, "POST", "/api/flashcard-stacks/week/7/5/vorlesung")
        XCTAssertEqual(r2.json?["status"]?.string, "unshared")
        XCTAssertEqual(r2.json?["variant"], .null, "ohne Nutzerkennung keine Variante")
        XCTAssertEqual(ai.calls, 2)
        // ohne KI: 404 wie die anderen KI-Endpunkte
        let d = try await backend()
        do { let r_ = await call(d, "POST", "/api/flashcard-stacks/week/7/5/vorlesung"); XCTAssertEqual(r_.status, 404) }
    }

    // MARK: Eigene Stapel teilen

    private func stack(_ b: LocalBackend, name: String, subject: String?, week: Int?, kind: String, cards: [(String, String)]) async throws -> Int {
        var body: [String: JSONValue] = ["name": .string(name), "subject": subject.map(JSONValue.string) ?? .null, "kind": .string(kind)]
        body["week"] = week.map { .number(Double($0)) } ?? .null
        let s = await call(b, "POST", "/api/flashcard-stacks", .object(body))
        let id = try XCTUnwrap(s.json?["id"]?.int)
        if !cards.isEmpty {
            _ = await call(b, "POST", "/api/flashcards", ["cards": .array(cards.map { ["question": .string($0.0), "answer": .string($0.1)] }), "stack_id": .number(Double(id))])
        }
        return id
    }

    func testShareAdoptWithdrawAndNoCrossModule() async throws {
        let cloud = FakeCardCommunity()
        let ada = try await backend(community: cloud)
        let uni = Migrations.defaultUniversity
        let key = try XCTUnwrap(CommunityKeys.courseKey(university: uni, courseName: "Analysis I"))
        let own = try await stack(ada, name: "Klausur", subject: "Analysis I", week: 5, kind: "vorlesung", cards: [("Q1", "A1"), ("Q2", "A \"2\" ä")])
        let empty = try await stack(ada, name: "Leer", subject: "Analysis I", week: nil, kind: "eigene", cards: [])
        let loose = try await stack(ada, name: "Ohne Modul", subject: nil, week: nil, kind: "eigene", cards: [("x", "y")])
        // teilen: nur mit Karten, nur mit Modul, nur einmal
        var r = await call(ada, "POST", "/api/flashcard-stacks/\(empty)/share")
        XCTAssertEqual(r.status, 422); XCTAssertEqual(r.json?["detail"]?["code"]?.string, "stack_empty")
        r = await call(ada, "POST", "/api/flashcard-stacks/\(loose)/share")
        XCTAssertEqual(r.status, 422); XCTAssertEqual(r.json?["detail"]?["code"]?.string, "no_module")
        do { let r_ = await call(ada, "POST", "/api/flashcard-stacks/9999/share"); XCTAssertEqual(r_.status, 404) }
        r = await call(ada, "POST", "/api/flashcard-stacks/\(own)/share")
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let sh = try XCTUnwrap(r.json)
        let sid = try XCTUnwrap(sh["id"]?.string)
        XCTAssertEqual(sh["name"]?.string, "Klausur"); XCTAssertEqual(sh["kind"]?.string, "vorlesung"); XCTAssertEqual(sh["week"]?.int, 5)
        XCTAssertEqual(sh["cards"]?.int, 2); XCTAssertEqual(sh["mine"]?.bool, true); XCTAssertEqual(sh["community_key"]?.string, key)
        XCTAssertEqual(sh["pseudonym"]?.string, "Studi-_user-ada"); XCTAssertEqual(sh["stack"]?["shared_id"]?.string, sid)
        r = await call(ada, "POST", "/api/flashcard-stacks/\(own)/share")
        XCTAssertEqual(r.status, 409); XCTAssertEqual(r.json?["detail"]?["code"]?.string, "already_shared")
        // beim Dienst: Chiffrat, kein Klartext, kein Modulname
        let entry = try XCTUnwrap(cloud.store[sid])
        XCTAssertFalse(entry.payload.contains("Q1") || entry.payload.contains("A1"))
        XCTAssertEqual(entry.summary.communityKey, key)
        // Ben (dasselbe Modul ueber den Kurstitel) sieht und uebernimmt; Wochenfilter; Lernstand getrennt
        cloud.user = "_user-ben"
        let ben = try await backend(module: "Analysis I", files: [])
        ben.context.cardCommunity.set(cloud)
        var list = await call(ben, "GET", "/api/community/card-stacks?module_id=7")
        XCTAssertEqual(list.status, 200, String(decoding: list.body, as: UTF8.self))
        XCTAssertEqual(list.json?["community_key"]?.string, key)
        XCTAssertEqual(list.json?["stacks"]?.array?.map { $0["id"]?.string ?? "" }, [sid])
        XCTAssertEqual(list.json?["stacks"]?.array?.first?["mine"]?.bool, false)
        XCTAssertEqual(list.json?["stacks"]?.array?.first?["adopted"]?.bool, false)
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks?module=\(key)&week=5"); XCTAssertEqual(r_.json?["stacks"]?.array?.count, 1) }
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks?module=\(key)&week=0"); XCTAssertEqual(r_.json?["stacks"]?.array?.count, 0) }
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks?module=\(key)&week=6"); XCTAssertEqual(r_.json?["stacks"]?.array?.count, 0) }
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks?module_id=99"); XCTAssertEqual(r_.status, 404) }
        let detail = await call(ben, "GET", "/api/community/card-stacks/\(sid)")
        XCTAssertEqual(detail.json?["cards_list"]?.array?.count, 2)
        r = await call(ben, "POST", "/api/community/card-stacks/\(sid)/adopt")
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let st = try XCTUnwrap(r.json?["stack"])
        XCTAssertEqual(r.json?["already"]?.bool, false); XCTAssertEqual(r.json?["count"]?.int, 2)
        XCTAssertEqual(st["name"]?.string, "Klausur"); XCTAssertEqual(st["subject"]?.string, "Analysis I"); XCTAssertEqual(st["kind"]?.string, "vorlesung")
        XCTAssertEqual(st["week"]?.int, 5); XCTAssertEqual(st["source"]?.string, "community"); XCTAssertEqual(st["source_ref"]?.string, sid); XCTAssertEqual(st["cards"]?.int, 2)
        do { let r_ = await call(ben, "POST", "/api/community/card-stacks/\(sid)/adopt"); XCTAssertEqual(r_.json?["already"]?.bool, true) }
        list = await call(ben, "GET", "/api/community/card-stacks?module=\(key)")
        XCTAssertEqual(list.json?["stacks"]?.array?.first?["adopted"]?.bool, true)
        let benCards = await call(ben, "GET", "/api/flashcards?stack_id=\(st["id"]?.int ?? 0)").json?.array ?? []
        XCTAssertEqual(Set(benCards.compactMap { $0["answer"]?.string }), ["A1", "A \"2\" ä"])
        _ = await call(ben, "POST", "/api/flashcards/\(benCards[0]["id"]?.int ?? 0)/review", ["correct": true])
        do { let r_ = await call(ada, "GET", "/api/flashcards?stack_id=\(own)"); XCTAssertEqual(r_.json?.array?.compactMap { $0["box"]?.int }, [1, 1], "Adas Karten unberuehrt") }
        // Like und Melden
        do { let r_ = await call(ben, "POST", "/api/community/card-stacks/\(sid)/like"); XCTAssertEqual(r_.json?["likes"]?.int, 1) }
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks?module=\(key)"); XCTAssertEqual(r_.json?["stacks"]?.array?.first?["liked_by_me"]?.bool, true) }
        do { let r_ = await call(ben, "DELETE", "/api/community/card-stacks/\(sid)/like"); XCTAssertEqual(r_.json?["likes"]?.int, 0) }
        do { let r_ = await call(ben, "POST", "/api/community/card-stacks/\(sid)/report", ["reason": "spam"]); XCTAssertEqual(r_.json?["reported"]?.bool, true) }
        do { let r_ = await call(ben, "POST", "/api/community/card-stacks/\(sid)/report", ["reason": "kaputt"]); XCTAssertEqual(r_.status, 400) }
        XCTAssertEqual(cloud.store[sid]?.reports, ["spam"])
        // Cid hat das Modul nicht: nichts in seiner Liste, Uebernehmen 404 module_not_here
        cloud.user = "_user-cid"
        let cid = try await backend(module: "Physik I", files: [])
        cid.context.cardCommunity.set(cloud)
        do { let r_ = await call(cid, "GET", "/api/community/card-stacks?module_id=7"); XCTAssertEqual(r_.json?["stacks"]?.array?.count, 0) }
        r = await call(cid, "POST", "/api/community/card-stacks/\(sid)/adopt")
        XCTAssertEqual(r.status, 404); XCTAssertEqual(r.json?["detail"]?["code"]?.string, "module_not_here")
        // zurueckziehen: nur der Autor; danach weg, erneut teilbar; Bens Kopie bleibt
        cloud.user = "_user-ben"
        do { let r_ = await call(ben, "DELETE", "/api/flashcard-stacks/\(st["id"]?.int ?? 0)/share"); XCTAssertEqual(r_.json?["detail"]?["code"]?.string, "not_shared") }
        cloud.user = "_user-ada"
        r = await call(ada, "DELETE", "/api/flashcard-stacks/\(own)/share")
        XCTAssertEqual(r.json?["withdrawn"]?.bool, true); XCTAssertEqual(r.json?["stack"]?["shared_id"], .null)
        do { let r_ = await call(ada, "DELETE", "/api/flashcard-stacks/\(own)/share"); XCTAssertEqual(r_.json?["detail"]?["code"]?.string, "not_shared") }
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks?module=\(key)"); XCTAssertEqual(r_.json?["stacks"]?.array?.count, 0) }
        do { let r_ = await call(ben, "GET", "/api/community/card-stacks/\(sid)"); XCTAssertEqual(r_.status, 404) }
        do { let r_ = await call(ben, "GET", "/api/flashcards?stack_id=\(st["id"]?.int ?? 0)"); XCTAssertEqual(r_.json?.array?.count, 2) }
        r = await call(ada, "POST", "/api/flashcard-stacks/\(own)/share")
        XCTAssertEqual(r.status, 200)
        XCTAssertNotEqual(r.json?["id"]?.string, sid)
        // Dienst nicht erreichbar: 503 mit Meldung; ohne Dienst 503 not_available
        cloud.failing = SolutionError.decryptionFailed
        r = await call(ben, "GET", "/api/community/card-stacks?module=\(key)")
        XCTAssertEqual(r.status, 503); XCTAssertEqual(r.json?["detail"]?["code"]?.string, "community_unavailable")
        let none = try await backend()
        r = await call(none, "GET", "/api/community/card-stacks?module=\(key)")
        XCTAssertEqual(r.status, 503); XCTAssertEqual(r.json?["detail"]?["code"]?.string, "not_available")
        do { let r_ = await call(none, "POST", "/api/flashcard-stacks/\(own)/share"); XCTAssertEqual(r_.status, 404, "Stapel aus einer anderen Datenbank") }
    }

    func testNewColumnsMigrateAndSyncNaturally() async throws {
        let b = try await backend()
        let cols = try await b.context.database.withConnection { c in try c.query("PRAGMA table_info(flashcard_stacks)").compactMap { $0["name"]?.string } }
        XCTAssertEqual(cols.suffix(3), ["source", "source_ref", "shared_id"])
    }
}
