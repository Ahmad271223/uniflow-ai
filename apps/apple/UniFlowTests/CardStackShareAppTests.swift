import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Geteilte Wochenstapel und "Stapel teilen" auf dem iPad (Entscheidung des Inhabers vom 04.11.2026,
/// docs/KARTEIKARTEN-STAPEL-2026-11-04.md) gegen den Nachbau von CloudKit aus WeeklyTestCloudKitTests: Datensaetze
/// `WeekCardStack` und `CardStackShare` (Felder, nur Chiffrat, Besitzer vom Dienst), Likes und Meldungen als `Like`/`Report`
/// mit `cards:<Kennung>`, Fabriken ohne Container, und der Stand der Karteikarten-Seite (FlashcardDeck): Karten fuer eine
/// Woche holen (erzeugt, dann uebernommen ohne KI), "Woche n komplett" in der Reihenfolge Vorlesung, Uebung, geteilte
/// Stapel sichtbar, Übernehmen, Zurueckziehen. Kein echtes CloudKit, kein Netz.
@MainActor
final class CardStackShareAppTests: XCTestCase {
    typealias Store = WeeklyTestCloudKitTests.Store
    typealias FakeCloud = WeeklyTestCloudKitTests.FakeWeeklyCloud

    /// Zaehlende Schein-KI mit Karten
    final class CardsAI: AIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func answer(system: String, prompt: String) async throws -> String { try await answer(system: system, prompt: prompt, schema: nil) }
        func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
            let n: Int = lock.withLock { calls += 1; return calls }
            let kind = prompt.contains("Datei: Übung") ? "Übung" : "Vorlesung"
            return #"{"cards": [{"question": "\#(kind) Frage 1 (Lauf \#(n))", "answer": "Antwort 1"}, {"question": "\#(kind) Frage 2 (Lauf \#(n))", "answer": "Antwort ä"}]}"#
        }
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-11-04T10:00:00")!
    private let hashes = [String(repeating: "a", count: 64), String(repeating: "b", count: 64), String(repeating: "c", count: 64)]
    private let secret = CommunityKeys.secret(university: "luh", moduleName: "Analysis I")
    private var key: String { CommunityKeys.courseKey(university: "luh", courseName: "Analysis I")! }

    /// Community und Uebernehmen ab Plus (05.11.2026): die Seite liest den Tarif aus `Entitlements.shared`; jeder Test
    /// zaehlt das Kontingent in eigenen UserDefaults
    private var planBefore: UFPlan = .free

    override func setUp() async throws {
        try await super.setUp()
        planBefore = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
    }

    override func tearDown() async throws {
        Entitlements.shared.setPlanForTesting(planBefore)
        try await super.tearDown()
    }

    private func quota() throws -> UFAdoptQuota {
        let name = "uf-adopt-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        // iCloud-Schluessel-Wert-Speicher je Test im Speicher (P43-06, 08.11.2026), nie der echte
        return UFAdoptQuota(defaults: d, now: { self.clock.now }, cloud: CommunityEntscheidungenAppTests.MemoryAdoptCloud())
    }

    private func deck(_ api: APIClient) throws -> FlashcardDeck {
        let d = FlashcardDeck(api: api)
        d.adoptQuota = try quota()
        return d
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-stapel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Backend eines Studierenden: Modul 7 "Analysis I" (oder anderer Name) mit Vorlesung, Skript und Blatt der Lehrwoche 5
    private func host(module: String = "Analysis I", files: Bool = true, share: WeeklyTestShareProvider? = nil,
                      community: CardStackCommunityProvider? = nil, ai: AIProvider? = nil) async throws -> (LocalBackendHost, APIClient) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true), clock: clock)
        let backend = try await host.backend()
        let monday = 1_793_052_000.0
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at, active) VALUES (7, ?, '#123456', '2026-10-01', 1)", [.text(module)])
            try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active, subject) VALUES ('k1', ?, 'vorlesung', '2026-10-01', 7, 1, ?)",
                          [.text(module + " (WS 2026/27)"), .text(module)])
            if files {
                for (i, f) in [("f-vl5", "VL05.pdf", "vorlesung", hashes[0]), ("f-sk5", "Skript_Kap05.pdf", "skript", hashes[1]), ("f-bl5", "Blatt05.pdf", "uebung", hashes[2])].enumerated() {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, local_path, text_excerpt, content_sha256) VALUES (?, 'k1', ?, ?, 'pdf', ?, ?, ?)",
                                  [.text(f.0), .text(f.1), .integer(Int64(monday) + Int64(i * 3600)), .text("k1/\(f.1)"), .text("Text von \(f.1)"), .text(f.3)])
                    try c.execute("INSERT INTO analysis(file_id, doc_type, title, raw) VALUES (?, ?, ?, '{}')", [.text(f.0), .text(f.2), .text(f.1)])
                }
            }
        }
        if let share { backend.context.cardShare.set(share, waiting: .none) }
        backend.context.cardCommunity.set(community)
        backend.context.ai.set(ai)
        return (host, APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    // MARK: Datensaetze

    func testWeekCardStackRecordMirrorsWeeklyTestWithItsOwnType() async throws {
        let store = Store()
        let ada = CloudKitWeeklyTestShare(cloud: FakeCloud(store: store, user: "_user-ada"), recordType: CardStackShareRecord.weekType,
                                          now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let k = try XCTUnwrap(CardStackShare.weekKey(university: "luh", kind: "vorlesung", contentHashes: [hashes[0], hashes[1]]))
        let m = WeeklyTestMaterial(key: k, contentHashes: [hashes[0], hashes[1]])
        let v = TestShare.variant(userID: "_user-ada", key: k)
        let got1 = try await ada.claim(m, variant: v)
        XCTAssertTrue(got1)
        let cards = [AIAnswers.Flashcard(question: "Was ist eine Reihe?", answer: "Summe einer Folge ä")]
        try await ada.publish(m, variant: v, test: CardStackShare.poolTest(kind: "vorlesung", cards: cards))
        let records = (ada.cloud as! FakeCloud).all()
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.type, "WeekCardStack")
        XCTAssertEqual(r.name, "\(k)#\(v)")
        XCTAssertEqual(r["shareKey"]?.string, k)
        XCTAssertEqual(r["variant"]?.int, v)
        XCTAssertEqual(r["status"]?.string, "ready")
        XCTAssertEqual(r["ownerRecordName"]?.string, "_user-ada")
        XCTAssertEqual(Set(r.fields.keys), ["shareKey", "variant", "status", "payload", "createdAt", "ownerRecordName"])
        let payload = try XCTUnwrap(r["payload"]?.string)
        XCTAssertFalse(payload.contains("Reihe") || payload.contains("Summe"), "nur Chiffrat")
        for h in hashes { XCTAssertFalse(payload.contains(h), "Inhalts-Hashes nie beim Dienst") }
        // dieselben Dateien (anderes Geraet): lesbar; ein Wochentest-Dienst sieht den Datensatz nicht (anderer Typ)
        let ben = CloudKitWeeklyTestShare(cloud: FakeCloud(store: store, user: "_user-ben"), recordType: CardStackShareRecord.weekType)
        let slots = try await ben.slots(m)
        guard case .ready(let t)? = slots[v] else { return XCTFail("\(slots)") }
        XCTAssertEqual(CardStackShare.cards(from: t, kind: "vorlesung"), cards)
        XCTAssertEqual(CardStackShare.cards(from: t, kind: "uebung"), [])
        let weekly = CloudKitWeeklyTestShare(cloud: FakeCloud(store: store, user: "_user-ben"))
        let got2 = try await weekly.slots(m)
        XCTAssertEqual(got2, [:])
        // andere Dateien: nicht lesbar, zaehlt als belegt
        let other = WeeklyTestMaterial(key: k, contentHashes: [hashes[2], hashes[0]])
        let got3 = try await ben.slots(other)
        XCTAssertEqual(got3, [v: .broken])
    }

    func testCardStackShareRecordHoldsOnlyCiphertextAndModuleKey() async throws {
        let store = Store()
        let adaCloud = FakeCloud(store: store, user: "_user-ada")
        let ada = CloudKitCardStackCommunity(cloud: adaCloud, pseudonym: { "Ada" }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let cards = [AIAnswers.Flashcard(question: "Q1", answer: "A1"), AIAnswers.Flashcard(question: "Q2 ä", answer: "A \"2\"")]
        let draft = CardStackDraft(communityKey: key, name: "Klausur", kind: "vorlesung", week: 5, cards: cards)
        let id = try await ada.publish(draft, secret: secret)
        XCTAssertEqual(id, id.lowercased())
        let r = try XCTUnwrap(adaCloud.all().first)
        XCTAssertEqual(r.type, "CardStackShare")
        XCTAssertEqual(r.name, id)
        XCTAssertEqual(r["communityKey"]?.string, key)
        XCTAssertEqual(r["kind"]?.string, "vorlesung")
        XCTAssertEqual(r["week"]?.int, 5)
        XCTAssertEqual(r["name"]?.string, "Klausur")
        XCTAssertEqual(r["cardCount"]?.int, 2)
        XCTAssertEqual(r["displayName"]?.string, "Ada")
        XCTAssertEqual(r["createdAt"]?.string, "2027-01-15T08:00:00Z")
        XCTAssertEqual(r["ownerRecordName"]?.string, "_user-ada")
        XCTAssertEqual(r["withdrawn"]?.int, 0)
        XCTAssertEqual(Set(r.fields.keys), ["communityKey", "kind", "week", "name", "cardCount", "displayName", "payload", "createdAt", "ownerRecordName", "withdrawn"])
        let payload = try XCTUnwrap(r["payload"]?.string)
        // Base64 aus Zufallsbytes enthaelt kurze Folgen wie "Q1"/"A1" zufaellig (machte den Test wacklig): geprueft wird,
        // dass weder der Modulname noch die Kartentexte im Klartext stehen, auch nicht nach dem Base64-Dekodieren
        XCTAssertFalse(payload.contains("Analysis"), "nur Chiffrat, kein Modulname")
        let raw = try XCTUnwrap(Data(base64Encoded: payload), "Chiffrat ist Base64")
        XCTAssertNil(raw.range(of: Data("Analysis".utf8)), "kein Modulname in den Bytes")
        XCTAssertNil(raw.range(of: Data("\"question\"".utf8)), "keine Karten im Klartext")
        XCTAssertNil(try? JSONSerialization.jsonObject(with: raw), "kein lesbares JSON")
        // Ben liest: Kopfdaten mit Pseudonym, Karten nur mit dem Modul-Geheimnis (AES-256-GCM aus CryptoKit)
        let benCloud = FakeCloud(store: store, user: "_user-ben")
        let ben = CloudKitCardStackCommunity(cloud: benCloud)
        let list = try await ben.list(communityKey: key)
        XCTAssertEqual(list.map(\.id), [id])
        XCTAssertEqual(list.first?.pseudonym, "Ada")
        XCTAssertEqual(list.first?.isOwn, false)
        XCTAssertEqual(list.first?.week, 5)
        XCTAssertEqual(list.first?.cardCount, 2)
        let got4 = try await ben.list(communityKey: "f" + key.dropFirst())
        XCTAssertEqual(got4, [], "anderes Modul: nichts")
        let got5 = try await ben.cards(id: id, communityKey: key, secret: secret)
        XCTAssertEqual(got5, cards)
        do {
            _ = try await ben.cards(id: id, communityKey: key, secret: CommunityKeys.secret(university: "luh", moduleName: "Physik I"))
            XCTFail("anderes Modul darf nicht lesen")
        } catch {}
        let got6 = try await ada.summary(id: id)?.isOwn
        XCTAssertEqual(got6, true)
        // Like und Melden: Datensaetze Like/Report mit "cards:<Kennung>"; der eigene Like zaehlt nicht fuer den Autor
        let got7 = try await ben.like(id: id, on: true)
        XCTAssertEqual(got7, 1)
        let got8 = try await ben.list(communityKey: key).first?.likedByMe
        XCTAssertEqual(got8, true)
        let got9 = try await ben.list(communityKey: key).first?.likes
        XCTAssertEqual(got9, 1)
        let like = try XCTUnwrap(benCloud.all().first { $0.type == "Like" })
        XCTAssertEqual(like["solutionID"]?.string, "cards:\(id)")
        let got10 = try await ben.like(id: id, on: false)
        XCTAssertEqual(got10, 0)
        try await ben.report(id: id, reason: "spam", note: "  Werbung  ")
        let report = try XCTUnwrap(benCloud.all().first { $0.type == "Report" })
        XCTAssertEqual(report["solutionID"]?.string, "cards:\(id)")
        XCTAssertEqual(report["reason"]?.string, "spam")
        XCTAssertEqual(report["note"]?.string, "Werbung")
        XCTAssertEqual(report["reporterRecordName"]?.string, "_user-ben")
        // Sperrliste und Bann blenden aus
        let blocking = CloudKitCardStackCommunity(cloud: benCloud, blocked: { ["_user-ada"] })
        let got11 = try await blocking.list(communityKey: key)
        XCTAssertEqual(got11, [])
        let got12 = try await blocking.summary(id: id)
        XCTAssertNil(got12)
        var ban = CommunityRecord(type: CommunityRecordType.ban, name: "ban-ada")
        ban["ownerRecordName"] = .string("_user-ada")
        _ = try await FakeCloud(store: store, user: "_owner").save(ban, in: .publicDB)
        let got13 = try await ben.list(communityKey: key)
        XCTAssertEqual(got13, [])
        _ = try await FakeCloud(store: store, user: "_owner").delete(name: "ban-ada", type: CommunityRecordType.ban, in: .publicDB)
        // Zurueckziehen: nur der Autor; danach weg (Chiffrat geleert), Kopfdaten nil
        do { try await ben.withdraw(id: id); XCTFail("nur der Autor") } catch {}
        try await ada.withdraw(id: id)
        let got14 = try await ben.list(communityKey: key)
        XCTAssertEqual(got14, [])
        let got15 = try await ben.summary(id: id)
        XCTAssertNil(got15)
        XCTAssertEqual(adaCloud.all().first { $0.type == "CardStackShare" }?["payload"]?.string, "")
        do { _ = try await ben.cards(id: id, communityKey: key, secret: secret); XCTFail("zurueckgezogen") } catch {}
        // ohne iCloud-Konto: lesen geht, schreiben nicht
        benCloud.status = .noAccount
        let got16 = try await ben.userID()
        XCTAssertNil(got16)
        do { _ = try await ben.publish(draft, secret: secret); XCTFail("ohne Konto kein Teilen") } catch {}
    }

    /// Fabriken folgen dem Container im Build (wie WeeklyTestShareFactory): ohne Container nil, sonst die CloudKit-Dienste
    func testFactoriesFollowTheContainer() {
        XCTAssertNil(CommunityCloudFactory.containerIdentifier(info: [:]))
        if CommunityCloudFactory.containerIdentifier() == nil {
            XCTAssertNil(CardStackCloudFactory.makeWeek(), "ohne Container kein Varianten-Dienst")
            XCTAssertNil(CardStackCloudFactory.makeCommunity(), "ohne Container kein Teilen")
        } else {
            let week = CardStackCloudFactory.makeWeek() as? CloudKitWeeklyTestShare
            XCTAssertEqual(week?.recordType, "WeekCardStack")
            XCTAssertTrue(CardStackCloudFactory.makeCommunity() is CloudKitCardStackCommunity)
        }
    }

    // MARK: Stand der Seite

    func testDeckFetchesWeekStacksAdoptsWithoutAIAndPracticesTheWeekComplete() async throws {
        let store = Store()
        let ai = CardsAI()
        let adaShare = CloudKitWeeklyTestShare(cloud: FakeCloud(store: store, user: "_user-ada"), recordType: CardStackShareRecord.weekType, now: { self.clock.now })
        let (_, adaAPI) = try await host(share: adaShare, ai: ai)
        let ada = try deck(adaAPI)
        try await ada.load()
        XCTAssertNil(ada.weekStack(subject: "Analysis I", week: 5, kind: "vorlesung"))
        XCTAssertFalse(ada.hasCompleteWeek(subject: "Analysis I", week: 5))
        let got = try await ada.fetchWeek(moduleID: 7, week: 5)
        XCTAssertEqual(got.map(\.status), ["generated", "generated"])
        XCTAssertEqual(got.map(\.cards), [2, 2])
        XCTAssertTrue(got[0].message.hasPrefix("Vorlesung: neu erzeugt und geteilt · 2 Karten"), got[0].message)
        XCTAssertEqual(ai.calls, 2)
        XCTAssertEqual(ada.stacks.count, 2)
        XCTAssertEqual(ada.weekStack(subject: "Analysis I", week: 5, kind: "vorlesung")?.s("name"), "Vorlesung Woche 5")
        XCTAssertEqual(ada.weekStack(subject: "Analysis I", week: 5, kind: "uebung")?.s("name"), "Übung Woche 5")
        XCTAssertTrue(ada.hasCompleteWeek(subject: "Analysis I", week: 5))
        XCTAssertEqual(ada.weeks, [5])
        XCTAssertEqual(FlashcardDeck.badge(ada.weekStack(subject: "Analysis I", week: 5, kind: "uebung")!), "Übung · W5 · gemeinsam")
        // "Woche 5 komplett": erst die Vorlesungskarten, dann die Uebungskarten, je in der Reihenfolge des Anlegens
        let complete = ada.weekCompleteCards(subject: "Analysis I", week: 5).map { $0.s("question") ?? "" }
        XCTAssertEqual(complete, ["Vorlesung Frage 1 (Lauf 1)", "Vorlesung Frage 2 (Lauf 1)", "Übung Frage 1 (Lauf 2)", "Übung Frage 2 (Lauf 2)"])
        XCTAssertEqual(ada.weekCompleteCards(subject: "Analysis I", week: 6), [])
        // noch einmal holen: vorhanden, keine KI
        let again = try await ada.fetchWeek(moduleID: 7, week: 5)
        XCTAssertEqual(again.map(\.status), ["exists", "exists"])
        XCTAssertEqual(ai.calls, 2)
        // Woche ohne Unterlagen: Ergebnis je Art, kein Fehler
        let none = try await ada.fetchWeek(moduleID: 7, week: 6)
        XCTAssertEqual(none.map(\.status), ["no_materials", "no_materials"])
        XCTAssertEqual(none[1].message, "Übung: keine Unterlagen in dieser Woche")
        XCTAssertEqual(ai.calls, 2)
        // Ben mit denselben Dateien und derselben Variante: uebernimmt ohne KI, Lernstand getrennt
        let k = try XCTUnwrap(ada.weekStack(subject: "Analysis I", week: 5, kind: "vorlesung")?.s("source_ref"))
        var benName = "_user-ben"
        var i = 0
        while TestShare.variant(userID: benName, key: k) != TestShare.variant(userID: "_user-ada", key: k) { i += 1; benName = "_user-ben-\(i)" }
        let benShare = CloudKitWeeklyTestShare(cloud: FakeCloud(store: store, user: benName), recordType: CardStackShareRecord.weekType, now: { self.clock.now })
        let benAI = CardsAI()
        let (_, benAPI) = try await host(module: "Analysis für alle", share: benShare, ai: benAI)
        let ben = try deck(benAPI)
        try await ben.load()
        let adopted = try await ben.fetchWeek(moduleID: 7, week: 5)
        XCTAssertEqual(adopted[0].status, "adopted")
        XCTAssertTrue(adopted[0].message.hasPrefix("Vorlesung: übernommen · 2 Karten · 0 Credits · Variante "), adopted[0].message)
        XCTAssertEqual(benAI.calls, 0, "uebernehmen kostet keine KI")
        XCTAssertEqual(ben.weekCompleteCards(subject: "Analysis für alle", week: 5).map { $0.s("question") ?? "" }.prefix(2), ["Vorlesung Frage 1 (Lauf 1)", "Vorlesung Frage 2 (Lauf 1)"])
        ben.select(ben.weekStack(subject: "Analysis für alle", week: 5, kind: "vorlesung")?.i("id"))
        ben.startReview()
        ben.reveal()
        let got17 = try await ben.rate(correct: true)
        XCTAssertTrue(got17)
        try await ada.load()
        XCTAssertTrue(ada.all.allSatisfy { $0.i("box") == 1 }, "Adas Lernstand bleibt ihrer")
    }

    func testDeckSharesAdoptsAndWithdrawsStacksInTheModuleCommunity() async throws {
        let store = Store()
        let adaCommunity = CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ada"), pseudonym: { "Ada" })
        let (_, adaAPI) = try await host(community: adaCommunity)
        let ada = try deck(adaAPI)
        try await ada.load()
        let sid = try await ada.createStack(name: "Klausur", subject: "Analysis I", week: .some(5), kind: "vorlesung")
        try await ada.create(question: "Q1", answer: "A1", fileID: nil, stackID: sid)
        try await ada.create(question: "Q2", answer: "A2", fileID: nil, stackID: sid)
        await ada.loadShared()
        XCTAssertTrue(ada.sharingAvailable)
        XCTAssertEqual(ada.shared(module: 7, week: nil), [])
        let own = try XCTUnwrap(ada.stacks.first { $0.i("id") == sid })
        XCTAssertEqual(own["shared_id"], .null)
        let shared = try await ada.share(own)
        XCTAssertEqual(shared.s("pseudonym"), "Ada")
        XCTAssertEqual(shared["mine"]?.bool, true)
        let sharedID = try XCTUnwrap(shared.s("id"))
        XCTAssertEqual(ada.stacks.first { $0.i("id") == sid }?.s("shared_id"), sharedID)
        XCTAssertEqual(FlashcardDeck.badge(ada.stacks.first { $0.i("id") == sid }!), "Vorlesung · W5 · geteilt")
        XCTAssertEqual(ada.shared(module: 7, week: 5).map { $0.s("id") ?? "" }, [sharedID])
        XCTAssertEqual(ada.shared(module: 7, week: FlashcardDeck.generalWeek), [])
        XCTAssertEqual(FlashcardDeck.sharedLine(ada.shared(module: 7, week: nil)[0]), "von Ada · 2 Karten · 0 Likes · dein Stapel")
        // Ben: dasselbe Modul ueber den Kurstitel, sieht den Stapel, uebernimmt (eigener Stapel, Lernstand getrennt), liked
        let benCommunity = CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ben"))
        let (_, benAPI) = try await host(files: false, community: benCommunity)
        let ben = try deck(benAPI)
        try await ben.load()
        await ben.loadShared()
        let seen = try XCTUnwrap(ben.shared(module: 7, week: nil).first)
        XCTAssertEqual(seen.s("id"), sharedID)
        XCTAssertEqual(seen["mine"]?.bool, false)
        XCTAssertEqual(seen["adopted"]?.bool, false)
        XCTAssertEqual(FlashcardDeck.sharedLine(seen), "von Ada · 2 Karten · 0 Likes")
        let (copy, already) = try await ben.adopt(seen)
        XCTAssertFalse(already)
        XCTAssertEqual(copy.s("name"), "Klausur")
        XCTAssertEqual(copy.s("source"), "community")
        XCTAssertEqual(copy.s("source_ref"), sharedID)
        XCTAssertEqual(copy.s("subject"), "Analysis I")
        XCTAssertEqual(ben.stacks.count, 1)
        XCTAssertEqual(Set(ben.all.compactMap { $0.s("question") }), ["Q1", "Q2"])
        XCTAssertEqual(FlashcardDeck.badge(ben.stacks[0]), "Vorlesung · W5 · übernommen")
        XCTAssertEqual(ben.shared(module: 7, week: nil).first?["adopted"]?.bool, true)
        let got18 = try await ben.adopt(seen).already
        XCTAssertTrue(got18)
        XCTAssertEqual(ben.stacks.count, 1, "zweimal uebernehmen legt keinen zweiten Stapel an")
        try await ben.like(seen)
        XCTAssertEqual(ben.shared(module: 7, week: nil).first?["liked_by_me"]?.bool, true)
        XCTAssertEqual(ben.shared(module: 7, week: nil).first?.i("likes"), 1)
        try await ben.report(seen, reason: "spam", note: "")
        XCTAssertEqual(ben.shared(module: 7, week: nil).first?["reported_by_me"]?.bool, false, "CloudKit kennt keine eigene Meldungsliste")
        // Ada zieht zurueck: aus der Community weg, Bens Kopie bleibt
        try await ada.unshare(ada.stacks.first { $0.i("id") == sid }!)
        XCTAssertEqual(ada.stacks.first { $0.i("id") == sid }?["shared_id"], .null)
        XCTAssertEqual(ada.shared(module: 7, week: nil), [])
        await ben.loadShared()
        XCTAssertEqual(ben.shared(module: 7, week: nil), [])
        try await ben.load()
        XCTAssertEqual(ben.all.count, 2)
        // ohne Dienst: nicht verfuegbar, Teilen bleibt weg
        let (_, noAPI) = try await host(files: false)
        let none = try deck(noAPI)
        try await none.load()
        await none.loadShared()
        XCTAssertFalse(none.sharingAvailable)
        XCTAssertEqual(none.shared, [:])
    }

    // MARK: Tarif (05.11.2026)

    /// Free ohne Dienst liest keine geteilten Stapel aus CloudKit (Community ab Plus)
    func testFreeReadsNoSharedStacksWithoutService() async throws {
        let store = Store()
        let adaCommunity = CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ada"), pseudonym: { "Ada" })
        let (_, adaAPI) = try await host(community: adaCommunity)
        let ada = try deck(adaAPI)
        try await ada.load()
        let sid = try await ada.createStack(name: "Klausur", subject: "Analysis I", week: .some(5), kind: "vorlesung")
        try await ada.create(question: "Q1", answer: "A1", fileID: nil, stackID: sid)
        _ = try await ada.share(try XCTUnwrap(ada.stacks.first { $0.i("id") == sid }))
        let ben = try deck(try await host(files: false, community: CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ben"))).1)
        try await ben.load()
        Entitlements.shared.setPlanForTesting(.free)
        await ben.loadShared()
        XCTAssertEqual(ben.shared, [:], "Free: keine Abfrage der Community")
        Entitlements.shared.setPlanForTesting(.plus)
        await ben.loadShared()
        XCTAssertEqual(ben.shared(module: 7, week: nil).count, 1)
    }

    /// Kontingent "Karteikarten-Stapel von StudiNow" auf dem Geraet: Plus 4 je Monat, derselbe Stapel einmal, Pro AI
    /// unbegrenzt, neuer Monat neu
    func testAdoptQuotaCountsPlusFourPerMonth() throws {
        let q = try quota()
        XCTAssertEqual(UFAdoptQuota.limit(.free), 0)
        XCTAssertEqual(UFAdoptQuota.limit(.plus), 4)
        XCTAssertNil(UFAdoptQuota.limit(.proAI))
        XCTAssertFalse(q.allows("a", plan: .free))
        for id in ["a", "b", "c", "d"] {
            XCTAssertTrue(q.allows(id, plan: .plus), id)
            q.record(id)
        }
        q.record("a")
        XCTAssertEqual(q.used.count, 4, "derselbe Stapel zaehlt einmal")
        XCTAssertTrue(q.allows("a", plan: .plus), "schon gezaehlt")
        XCTAssertFalse(q.allows("e", plan: .plus))
        XCTAssertTrue(q.allows("e", plan: .proAI))
        XCTAssertEqual(q.error(plan: .plus).errorDescription,
                       "Karteikarten-Stapel von StudiNow: Kontingent für diesen Monat aufgebraucht (4 von 4).")
        let december = UFAdoptQuota(defaults: q.defaults, now: { UniFlowClock.fixed(berlin: "2026-12-01T10:00:00")!.now }, cloud: q.cloud)
        XCTAssertTrue(december.allows("e", plan: .plus), "neuer Monat, neues Kontingent")
    }

    /// Uebernehmen eines geteilten Stapels: der fuenfte im Monat wird mit Plus abgewiesen, mit Pro AI nicht
    func testAdoptStopsAfterFourForPlus() async throws {
        let store = Store()
        let adaCommunity = CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ada"), pseudonym: { "Ada" })
        let (_, adaAPI) = try await host(community: adaCommunity)
        let ada = try deck(adaAPI)
        try await ada.load()
        for n in 1...5 {
            let sid = try await ada.createStack(name: "Stapel \(n)", subject: "Analysis I", week: .some(n), kind: "vorlesung")
            try await ada.create(question: "Q\(n)", answer: "A\(n)", fileID: nil, stackID: sid)
            _ = try await ada.share(try XCTUnwrap(ada.stacks.first { $0.i("id") == sid }))
        }
        let ben = try deck(try await host(files: false, community: CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ben"))).1)
        try await ben.load()
        await ben.loadShared()
        let seen = ben.shared(module: 7, week: nil)
        XCTAssertEqual(seen.count, 5)
        for sh in seen.prefix(4) { _ = try await ben.adopt(sh) }
        do {
            _ = try await ben.adopt(seen[4])
            XCTFail("fuenfter Stapel im Monat mit Plus")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "quota_exhausted")
            XCTAssertEqual(e.errorDescription, "Karteikarten-Stapel von StudiNow: Kontingent für diesen Monat aufgebraucht (4 von 4).")
        }
        XCTAssertEqual(ben.stacks.count, 4)
        let again = try await ben.adopt(seen[0]).already
        XCTAssertTrue(again, "schon uebernommen geht weiter")
        Entitlements.shared.setPlanForTesting(.proAI)
        _ = try await ben.adopt(seen[4])
        XCTAssertEqual(ben.stacks.count, 5, "Pro AI unbegrenzt")
    }

    /// P43-06 (08.11.2026): mit StudiNow-Konto fragt "Übernehmen" vorher den Dienst (Kontingent des Kontos ueber alle
    /// Geraete); sagt er "aufgebraucht", bleibt es beim bisherigen Text und es entsteht kein Stapel
    func testP43_06AdoptWithStudiNowAccountCountsInTheService() async throws {
        let store = Store()
        let adaCommunity = CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ada"), pseudonym: { "Ada" })
        let ada = try deck(try await host(community: adaCommunity).1)
        try await ada.load()
        for n in 1...2 {
            let sid = try await ada.createStack(name: "Stapel \(n)", subject: "Analysis I", week: .some(n), kind: "vorlesung")
            try await ada.create(question: "Q\(n)", answer: "A\(n)", fileID: nil, stackID: sid)
            _ = try await ada.share(try XCTUnwrap(ada.stacks.first { $0.i("id") == sid }))
        }
        let ben = try deck(try await host(files: false, community: CloudKitCardStackCommunity(cloud: FakeCloud(store: store, user: "_user-ben"))).1)
        let service = CommunityEntscheidungenAppTests.FakeAdoptService()
        ben.adoptService = { service }
        try await ben.load()
        await ben.loadShared()
        let seen = ben.shared(module: 7, week: nil)
        XCTAssertEqual(seen.count, 2)
        _ = try await ben.adopt(seen[0])
        XCTAssertEqual(service.counted, ["community:\(try XCTUnwrap(seen[0].s("id")))"])
        service.answer = StudoraAccount.AdoptQuota(ok: false, counted: false, used: 4, limit: 4)
        do {
            _ = try await ben.adopt(seen[1])
            XCTFail("Kontingent des Kontos aufgebraucht")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "quota_exhausted")
            XCTAssertEqual(e.errorDescription, "Karteikarten-Stapel von StudiNow: Kontingent für diesen Monat aufgebraucht (4 von 4).")
        }
        XCTAssertEqual(ben.stacks.count, 1)
    }
}
