import Foundation
import XCTest
@testable import UniFlowCore

// Erklaerungsspeicher ("Einmal erklaeren, alle profitieren", docs/ERKLAERUNGSSPEICHER-2026-11-04.md): Datensatznamen,
// Verschluesselung (Rundlauf; andere Datei, anderer Modus, andere Variante lesen nichts), Vorrang lokal -> Dienst -> KI,
// Platzwahl bei 0/1/3 belegten Varianten, Prompt mit Einordnung nur wenn vorhanden, Plan des Vorwaermens je Stufe,
// und der Endpunkt /api/ai/tutor mit Fake-KI und Fake-Dienst: der erste fragt live und teilt, der zweite mit derselben
// Datei bekommt die Antwort ohne KI, "Neu erklaeren lassen" belegt den naechsten Platz, Markierungen bleiben live und
// ungeteilt. Kein Netz, keine echte KI.

/// Dienst im Speicher: ein Datensatz je Name, nie ueberschreiben
final class FakeExplainCloud: PageExplainCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: PageExplainRecord] = [:]
    var failure: Error?
    private(set) var saves = 0

    var all: [PageExplainRecord] { lock.withLock { store.values.sorted { $0.recordName < $1.recordName } } }

    func records(fileKey: String, page: Int, mode: String) async throws -> [PageExplainRecord] {
        if let failure { throw failure }
        return lock.withLock { store.values.filter { $0.fileKey == fileKey && $0.page == page && $0.mode == mode }.sorted { $0.variant < $1.variant } }
    }

    func save(_ record: PageExplainRecord) async throws -> Bool {
        if let failure { throw failure }
        return lock.withLock {
            if store[record.recordName] != nil { return false }
            store[record.recordName] = record
            saves += 1
            return true
        }
    }
}

final class PageExplainTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-10-28T09:00:00")!
    private let cipher = TestHMACCipher()
    private let sha = String(repeating: "7", count: 64)

    // MARK: Reine Funktionen

    func testRecordNameAndParse() throws {
        let key = try XCTUnwrap(DocIndexFingerprint.fileKey(fileSHA: sha))
        let name = PageExplain.recordName(fileKey: key, page: 4, mode: "steps", variant: 2)
        XCTAssertEqual(name, "\(key)#4#steps#2")
        let parsed = try XCTUnwrap(PageExplain.parse(recordName: name))
        XCTAssertEqual(parsed.fileKey, key)
        XCTAssertEqual(parsed.page, 4)
        XCTAssertEqual(parsed.mode, "steps")
        XCTAssertEqual(parsed.variant, 2)
        XCTAssertNil(PageExplain.parse(recordName: "\(key)#0#explain#1"), "Seite 0 gibt es nicht")
        XCTAssertNil(PageExplain.parse(recordName: "\(key)#4#ask#1"), "Fragen werden nicht geteilt")
        XCTAssertNil(PageExplain.parse(recordName: "\(key)#4#explain#4"), "hoechstens drei Varianten")
        XCTAssertNil(PageExplain.parse(recordName: "\(key)#4#explain#0"), "0 = nur lokal, nie beim Dienst")
        XCTAssertNil(PageExplain.parse(recordName: "kurz#4#explain#1"))
        XCTAssertEqual(PageExplainRecord(fileKey: key, page: 1, mode: "explain", variant: 1, payload: "x", createdAt: "").recordName, "\(key)#1#explain#1")
    }

    func testShareableOnlyForWholePageModesWithoutSelectionOrQuestion() {
        for m in ["explain", "explain_simple", "summary", "terms", "steps", "hints"] {
            XCTAssertTrue(PageExplain.isShareable(mode: m, selection: "", question: "  "), m)
            XCTAssertFalse(PageExplain.isShareable(mode: m, selection: "x = 2", question: ""), "\(m) mit Markierung")
            XCTAssertFalse(PageExplain.isShareable(mode: m, selection: "", question: "Warum?"), "\(m) mit Frage")
        }
        for m in ["ask", "check", "similar", "flashcards", "unbekannt"] {
            XCTAssertFalse(PageExplain.isShareable(mode: m, selection: "", question: ""), m)
        }
    }

    func testCryptoRoundTripAndWrongFileModeOrVariantCannotRead() throws {
        let other = String(repeating: "8", count: 64)
        let key = try XCTUnwrap(DocIndexFingerprint.fileKey(fileSHA: sha)), otherKey = try XCTUnwrap(DocIndexFingerprint.fileKey(fileSHA: other))
        let hash = DocIndexFingerprint.pageHash(text: "Konvergenz von Folgen und Reihen, Grenzwertsaetze und Beispiele", fileSHA: sha, page: 4)
        let content = PageExplainContent(page: 4, pageHash: hash, mode: "explain", variant: 1, text: "**Konvergenz** heißt …", model: "m", createdAt: "2026-11-04T08:00:00Z")
        let payload = try PageExplainCrypto.seal(content, fileSHA: sha, pageHash: hash, fileKey: key, cipher: cipher)
        XCTAssertFalse(payload.contains("Konvergenz"))
        XCTAssertEqual(try PageExplainCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, mode: "explain", variant: 1, cipher: cipher), content)
        XCTAssertThrowsError(try PageExplainCrypto.open(payload, fileSHA: other, pageHash: hash, fileKey: otherKey, page: 4, mode: "explain", variant: 1, cipher: cipher), "andere Datei")
        XCTAssertThrowsError(try PageExplainCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, mode: "summary", variant: 1, cipher: cipher), "anderer Modus")
        XCTAssertThrowsError(try PageExplainCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, mode: "explain", variant: 2, cipher: cipher), "andere Variante")
        XCTAssertThrowsError(try PageExplainCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 5, mode: "explain", variant: 1, cipher: cipher), "andere Seite")
        XCTAssertThrowsError(try PageExplainCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, mode: "explain", variant: 1, cipher: cipher, version: 2), "andere Fassung")
        // Dokument-Index und Erklaerungsspeicher lesen sich nicht gegenseitig (eigener Namensraum)
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, cipher: cipher))
        var raw = try XCTUnwrap(Data(base64Encoded: payload))
        raw[raw.count - 2] ^= 0x01
        XCTAssertThrowsError(try PageExplainCrypto.open(raw.base64EncodedString(), fileSHA: sha, pageHash: hash, fileKey: key, page: 4, mode: "explain", variant: 1, cipher: cipher), "veraendert")
        // Inhalt, der nicht zum Datensatz passt (umgehaengt): Variante im Inhalt 2, Datensatz 1
        let wrong = PageExplainContent(page: 4, pageHash: hash, mode: "explain", variant: 2, text: "x", createdAt: "")
        let p2 = try DocIndexCrypto.sealRaw(wrong.json.serialized(sortedKeys: true), keyMaterial: DocIndexCrypto.keyMaterial(fileSHA: sha, pageHash: hash),
                                           info: PageExplainCrypto.keyInfo(page: 4, mode: "explain"),
                                           aad: PageExplainCrypto.aad(fileKey: key, page: 4, mode: "explain", variant: 1, version: 1), cipher: cipher)
        XCTAssertThrowsError(try PageExplainCrypto.open(p2, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, mode: "explain", variant: 1, cipher: cipher))
    }

    func testChoiceLocalBeforeCloudBeforeAI() {
        XCTAssertEqual(PageExplain.choose(local: [], cloud: []), .ai)
        XCTAssertEqual(PageExplain.choose(local: [], cloud: [3, 2]), .cloud(2), "niedrigste Variante des Dienstes")
        XCTAssertEqual(PageExplain.choose(local: [], cloud: [0, 7]), .ai, "nur 1...3 zaehlen")
        let a = PageExplain.LocalEntry(variant: 1, source: "cloud", createdAt: "2026-11-01T10:00:00Z")
        let b = PageExplain.LocalEntry(variant: 0, source: "ai", createdAt: "2026-11-03T10:00:00Z")
        let c = PageExplain.LocalEntry(variant: 2, source: "ai", createdAt: "2026-11-03T10:00:00Z")
        XCTAssertEqual(PageExplain.choose(local: [a, b], cloud: [1]), .local(1), "lokal vor Dienst, die juengste Antwort")
        XCTAssertEqual(PageExplain.choose(local: [c, b, a], cloud: []), .local(0), "gleich jung: die zuerst genannte (zuletzt gespeichert)")
        XCTAssertEqual(PageExplain.choose(local: [a, c, b], cloud: []), .local(1))
        XCTAssertEqual(PageExplain.preferredVariant(existing: [2, 3]), 2)
        XCTAssertNil(PageExplain.preferredVariant(existing: []))
    }

    func testVariantSlotWithZeroOneOrThreeExisting() {
        XCTAssertEqual(PageExplain.freeVariants(existing: []), [1, 2, 3])
        XCTAssertEqual(PageExplain.nextVariant(existing: []), 1)
        XCTAssertEqual(PageExplain.nextVariant(existing: [1]), 2)
        XCTAssertEqual(PageExplain.freeVariants(existing: [2]), [1, 3])
        XCTAssertNil(PageExplain.nextVariant(existing: [1, 2, 3]), "alle belegt: nur lokal")
        XCTAssertEqual(PageExplain.freeVariants(existing: [1, 2, 3]), [])
        XCTAssertEqual(PageExplain.maxVariants, TestShare.maxVariants, "wie die Wochentests")
    }

    func testPromptCarriesIndexContextOnlyWhenPresent() {
        let plain = AIPrompts.tutor(mode: "ask", pageText: "Seitentext", question: "Was ist λ?", course: "Analysis", fileName: "vl.pdf", page: .int("3"))
        XCTAssertEqual(plain, AIPrompts.tutor(mode: "ask", pageText: "Seitentext", question: "Was ist λ?", course: "Analysis", fileName: "vl.pdf", page: .int("3"), pageIndex: "  "),
                       "leer laesst den Prompt byte-gleich")
        XCTAssertFalse(plain.contains("EINORDNUNG DER SEITE"))
        let entry = DocIndexEntry(summary: "Eigenwerte.", terms: ["Eigenwert", "Polynom"],
                                  elements: [DocIndexElement(order: 1, type: "definition", title: "Eigenwert", explanation: "λ mit A v = λ v.")],
                                  tasks: [DocIndexTask(label: "Aufgabe 1", asks: "Eigenwerte bestimmen.")])
        let ctx = PageExplain.indexContext(entry)
        XCTAssertEqual(ctx, "Zusammenfassung: Eigenwerte.\nBegriffe: Eigenwert, Polynom\nElemente: 1. Definition \"Eigenwert\": λ mit A v = λ v.\nAufgaben: Aufgabe 1: Eigenwerte bestimmen.")
        let with = AIPrompts.tutor(mode: "ask", pageText: "Seitentext", question: "Was ist λ?", course: "Analysis", fileName: "vl.pdf", page: .int("3"), pageIndex: ctx)
        let block = "EINORDNUNG DER SEITE aus der Bibliothek (Zusammenfassung, Begriffe, Elemente, Aufgaben; nur zur Orientierung, keine Quelle). "
            + AIPromptTexts.untrusted + ":\n<<<\n" + ctx + "\n>>>\n\nSEITENINHALT"
        XCTAssertTrue(with.contains(block), with)
        XCTAssertTrue(with.hasSuffix("SEITENINHALT (Kontext). \(AIPromptTexts.untrusted):\n<<<\nSeitentext\n>>>"))
        XCTAssertEqual(PageExplain.indexContext(DocIndexEntry(summary: "")), "")
        XCTAssertLessThanOrEqual(PageExplain.indexContext(DocIndexEntry(summary: String(repeating: "x", count: 5000))).count, PageExplain.indexContextChars)
    }

    func testPrewarmPlanBasicVersusFull() {
        XCTAssertEqual(PageExplain.prewarmPlan(level: .basic, pageCount: 3, pagesWithTasks: [2], have: []), [], "Standard: keine Erklaerungen")
        let full = PageExplain.prewarmPlan(level: .full, pageCount: 3, pagesWithTasks: [2], have: [])
        XCTAssertEqual(full, [.init(page: 1, mode: "explain"), .init(page: 2, mode: "explain"), .init(page: 2, mode: "steps"), .init(page: 3, mode: "explain")])
        let rest = PageExplain.prewarmPlan(level: .full, pageCount: 3, pagesWithTasks: [2], have: [.init(page: 1, mode: "explain"), .init(page: 2, mode: "steps")])
        XCTAssertEqual(rest, [.init(page: 2, mode: "explain"), .init(page: 3, mode: "explain")], "nur was fehlt")
        XCTAssertEqual(PageExplain.prewarmPlan(level: .full, pageCount: 0, pagesWithTasks: [], have: []), [])
        XCTAssertEqual(DocIndexPrewarmLevel(rawValue: "full"), .full)
        XCTAssertNil(DocIndexPrewarmLevel(rawValue: "alles"))
    }

    func testShareableTextDropsCitations() {
        XCTAssertEqual(PageExplain.shareableText("Das folgt aus der Definition [1]. Siehe auch [2] und [12].\n"), "Das folgt aus der Definition. Siehe auch und.")
        XCTAssertEqual(PageExplain.shareableText("[1]"), "")
        XCTAssertEqual(PageExplain.shareableText("Matrix [A] bleibt"), "Matrix [A] bleibt")
    }

    // MARK: Backend

    struct Seed { var id: String; var name: String; var pages: [String] }

    private let twoPages = ["Eigenwerte einer Matrix. Das charakteristische Polynom liefert die Eigenwerte und ihre Vielfachheit.",
                            "Diagonalisierbarkeit: eine Matrix ist diagonalisierbar, wenn eine Basis aus Eigenvektoren existiert."]

    /// Backend im Speicher mit einem Kurs und Dateien auf der Platte (wie DocIndexTests); Seitentexte nach Dateiname
    private func seeded(_ seeds: [Seed], container: URL? = nil, chdate: String = "2026-10-26T10:00:00") async throws -> (LocalBackend, URL) {
        let dir = try container ?? tempContainer(self)
        let tools = TextTools(Dictionary(uniqueKeysWithValues: seeds.map { ($0.name, $0.pages) }))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: dir, dataDirectory: "", tools: tools))
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, semester, color, sort, created_at) VALUES (7, 'Analysis I', 'WiSe 2026/27', '#123456', 0, ?)", [.text(self.clock.nowISO)])
            try c.execute("INSERT INTO courses(id, title, kind, active, module_id, semester, created_at) VALUES ('c-ana', 'Analysis I', 'vorlesung', 1, 7, 'WiSe 2026/27', ?)",
                          [.text(self.clock.nowISO)])
            for s in seeds {
                let path = "StudIP/\(s.name)"
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { try Data("%PDF-1.4 fake \(s.name)".utf8).write(to: url) }
                let sha = ContentHash.file(url)!
                try c.execute("""
                    INSERT INTO files(id, course_id, name, mime, chdate, local_path, downloaded_at, kind, status, content_sha256, studip_folder, download_url, page_count)
                    VALUES (?, 'c-ana', ?, 'application/pdf', ?, ?, ?, 'pdf', 'neu', ?, 'Vorlesung', 'https://studip.example/file', ?)
                    """, [.text(s.id), .text(s.name), .integer(Int64(BerlinClock.utcSeconds(localISO: chdate)!)), .text(path),
                          .text(self.clock.nowISO), .text(sha), .integer(Int64(s.pages.count))])
            }
        }
        return (backend, dir)
    }

    private func tutor(_ b: LocalBackend, _ body: JSONValue) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                            headers: ["Content-Type": "application/json"], body: body.serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        return try JSONValue.parse(r.body)
    }

    func testTutorSharesWholePageAnswersAndSecondDeviceGetsThemWithoutAI() async throws {
        let (first, dir) = try await seeded([Seed(id: "f-vl1", name: "VL01 Eigenwerte.pdf", pages: twoPages)])
        let cloud = FakeExplainCloud()
        let ai = FakeAI("Die **Eigenwerte** sind die Nullstellen [1] des charakteristischen Polynoms [2].")
        first.context.ai.set(ai)
        first.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: cloud)

        // 1. der erste fragt live: Antwort unveraendert (mit Quellen), gespeichert und als Variante 1 geteilt
        let r1 = try await tutor(first, ["file_id": "f-vl1", "page": 1, "mode": "explain"])
        XCTAssertEqual(r1["answer"]?.string, "Die **Eigenwerte** sind die Nullstellen [1] des charakteristischen Polynoms [2].")
        XCTAssertEqual(r1["explain"]?["stored"]?.bool, false)
        XCTAssertEqual(r1["explain"]?["variant"]?.int, 1)
        XCTAssertEqual(r1["explain"]?["shared"]?.bool, true)
        XCTAssertEqual(ai.prompts.count, 1)
        XCTAssertFalse(ai.prompts[0].prompt.contains("EINORDNUNG DER SEITE"), "ohne Index-Eintrag kein Zusatz")
        let sha = try await first.context.database.scalar("SELECT content_sha256 FROM files WHERE id='f-vl1'")?.string ?? ""
        let key = try XCTUnwrap(DocIndexFingerprint.fileKey(fileSHA: sha))
        let records = cloud.all
        XCTAssertEqual(records.map(\.recordName), ["\(key)#1#explain#1"])
        XCTAssertEqual(records[0].version, 1)
        XCTAssertFalse(records[0].payload.contains("Eigenwerte"))
        let hash = DocIndexFingerprint.pageHash(text: twoPages[0], fileSHA: sha, page: 1)
        let content = try PageExplainCrypto.open(records[0].payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 1, mode: "explain", variant: 1, cipher: cipher)
        XCTAssertEqual(content.text, "Die **Eigenwerte** sind die Nullstellen des charakteristischen Polynoms.", "Quellenmarken entfernt")
        XCTAssertEqual(content.createdAt, clock.nowISO)

        // 2. derselbe Nutzer noch einmal: aus dem eigenen Zwischenspeicher, keine KI
        let r2 = try await tutor(first, ["file_id": "f-vl1", "page": 1, "mode": "explain"])
        XCTAssertEqual(r2["explain"]?["stored"]?.bool, true)
        XCTAssertEqual(r2["explain"]?["source"]?.string, "local")
        XCTAssertEqual(r2["answer"]?.string, content.text)
        XCTAssertEqual(ai.prompts.count, 1)

        // 3. zweiter Nutzer mit derselben Datei: sofort da, 0 Credits, nichts erneut gespeichert
        let (second, _) = try await seeded([Seed(id: "f-x", name: "VL01 Eigenwerte.pdf", pages: twoPages)], container: dir)
        let ai2 = FakeAI("sollte nicht gefragt werden")
        second.context.ai.set(ai2)
        second.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: cloud)
        let r3 = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain"])
        XCTAssertEqual(r3["explain"]?["stored"]?.bool, true)
        XCTAssertEqual(r3["explain"]?["source"]?.string, "cloud")
        XCTAssertEqual(r3["explain"]?["variant"]?.int, 1)
        XCTAssertEqual(r3["answer"]?.string, content.text)
        XCTAssertEqual(ai2.prompts.count, 0, "0 Credits")
        XCTAssertEqual(cloud.saves, 1)
        let rows = try await second.context.database.withConnection { try PageExplainStore.rows($0, fileSHA: sha, page: 1, mode: "explain") }
        XCTAssertEqual(rows.map { ($0.variant, $0.source, $0.shared) }.map { "\($0.0)/\($0.1)/\($0.2)" }, ["1/cloud/true"])
        // beim naechsten Mal direkt aus dem Zwischenspeicher, Herkunft bleibt "cloud"
        let r4 = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain"])
        XCTAssertEqual(r4["explain"]?["source"]?.string, "cloud")

        // 4. "Neu erklaeren lassen": live, naechster Platz (2); danach gilt lokal die juengste Antwort
        ai2.reply = "Zweite Erklärung."
        let r5 = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain", "force": true])
        XCTAssertEqual(r5["answer"]?.string, "Zweite Erklärung.")
        XCTAssertEqual(r5["explain"]?["stored"]?.bool, false)
        XCTAssertEqual(r5["explain"]?["variant"]?.int, 2)
        XCTAssertEqual(ai2.prompts.count, 1)
        XCTAssertEqual(cloud.all.map(\.variant), [1, 2])
        let r6 = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain"])
        XCTAssertEqual(r6["answer"]?.string, "Zweite Erklärung.")
        XCTAssertEqual(r6["explain"]?["source"]?.string, "local")

        // 5. Platz 3, dann sind alle belegt: die naechste Antwort bleibt lokal (Variante 0), nichts beim Dienst
        _ = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain", "force": true])
        XCTAssertEqual(cloud.all.map(\.variant), [1, 2, 3])
        ai2.reply = "Vierte Erklärung."
        let r7 = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain", "force": true])
        XCTAssertEqual(r7["explain"]?["variant"]?.int, 0)
        XCTAssertEqual(r7["explain"]?["shared"]?.bool, false)
        XCTAssertEqual(cloud.all.count, 3, "nie ueberschreiben")
        let r8 = try await tutor(second, ["file_id": "f-x", "page": 1, "mode": "explain"])
        XCTAssertEqual(r8["answer"]?.string, "Vierte Erklärung.")

        // 6. Markierung, Frage, pruefen, Karteikarten: live und ungeteilt
        let before = cloud.all.count
        for body in [["file_id": "f-x", "page": 2, "mode": "explain", "selection": "det(A − λI) = 0"],
                     ["file_id": "f-x", "page": 2, "mode": "summary", "question": "Warum?"],
                     ["file_id": "f-x", "page": 2, "mode": "ask", "question": "Was ist λ?"],
                     ["file_id": "f-x", "page": 2, "mode": "check", "own_solution": "λ = 2"]] as [JSONValue] {
            let r = try await tutor(second, body)
            XCTAssertTrue(r["explain"]?.isNull ?? true, "\(body)")
        }
        XCTAssertEqual(cloud.all.count, before)
        let none = try await second.context.database.withConnection { try PageExplainStore.rows($0, fileSHA: sha, page: 2, mode: "explain") }
        XCTAssertEqual(none, [])
        // eine andere Datei liest den Datensatz nicht (anderer Schluessel, andere Zusatzdaten)
        let (third, _) = try await seeded([Seed(id: "f-other", name: "VL02 Fremd.pdf", pages: twoPages)], container: dir)
        let otherSHA = try await third.context.database.scalar("SELECT content_sha256 FROM files WHERE id='f-other'")?.string ?? ""
        XCTAssertThrowsError(try PageExplainCrypto.open(records[0].payload, fileSHA: otherSHA, pageHash: hash, fileKey: key, page: 1, mode: "explain", variant: 1, cipher: cipher))
    }

    /// Eigene Notizen zur Seite (`own_notes`, 05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md) stehen im Prompt und
    /// machen die Anfrage persoenlich: kein Nachsehen im geteilten Speicher, nichts hinein
    func testOwnNotesGoIntoThePromptAndNeverIntoTheSharedStore() async throws {
        let (b, _) = try await seeded([Seed(id: "f-vl1", name: "VL01 Eigenwerte.pdf", pages: twoPages)])
        let cloud = FakeExplainCloud()
        let ai = FakeAI("Deine Notiz stimmt.")
        b.context.ai.set(ai)
        b.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: cloud)
        let r = try await tutor(b, ["file_id": "f-vl1", "page": 1, "mode": "explain", "own_notes": "[Blatt daneben 1]\nλ = 2"])
        XCTAssertEqual(r["answer"]?.string, "Deine Notiz stimmt.")
        XCTAssertTrue(r["explain"]?.isNull ?? true)
        XCTAssertTrue(ai.prompts[0].prompt.contains(AIPrompts.ownNotesHeading + "\n<<<\n[Blatt daneben 1]\nλ = 2\n>>>"))
        XCTAssertEqual(cloud.all.count, 0, "nichts geteilt")
        // dieselbe Seite ohne Notizen danach: live und geteilt wie immer (die Notiz-Antwort lag nicht im Speicher)
        let plain = try await tutor(b, ["file_id": "f-vl1", "page": 1, "mode": "explain"])
        XCTAssertEqual(plain["explain"]?["stored"]?.bool, false)
        XCTAssertEqual(ai.prompts.count, 2)
        XCTAssertFalse(ai.prompts[1].prompt.contains("MEINE NOTIZEN"))
    }

    func testOwnQuestionGetsIndexContextWhenPagePresentInLibrary() async throws {
        let (b, _) = try await seeded([Seed(id: "f-vl1", name: "VL01 Eigenwerte.pdf", pages: twoPages)])
        let ai = FakeAI("Antwort")
        b.context.ai.set(ai)
        b.context.docIndex.configure(cloud: nil, cipher: cipher)
        // Dokument-Index der Datei (Fake-KI des Index), dann eine eigene Frage
        _ = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: b.context, cloud: nil, ai: FakeDocIndexAI(), cipher: cipher)
        _ = try await tutor(b, ["file_id": "f-vl1", "page": 1, "mode": "ask", "question": "Was ist ein Eigenwert?"])
        let prompt = try XCTUnwrap(ai.prompts.last?.prompt)
        XCTAssertTrue(prompt.contains("EINORDNUNG DER SEITE aus der Bibliothek"), prompt)
        XCTAssertTrue(prompt.contains("Zusammenfassung: Seite 1: Eigenwerte und das charakteristische Polynom."), prompt)
        XCTAssertTrue(prompt.contains("Aufgaben: Aufgabe 1: Eigenwerte bestimmen."), prompt)
        XCTAssertTrue(prompt.contains("MEINE FRAGE: Was ist ein Eigenwert?"))
        // erklaeren der ganzen Seite bekommt keinen Zusatz (die Antwort wird geteilt und bleibt klein)
        _ = try await tutor(b, ["file_id": "f-vl1", "page": 1, "mode": "explain"])
        XCTAssertFalse(try XCTUnwrap(ai.prompts.last?.prompt).contains("EINORDNUNG DER SEITE"))
    }

    func testPrewarmFullExplainsPagesAndSolvesTasksOnceForAll() async throws {
        let (b, dir) = try await seeded([Seed(id: "f-vl1", name: "VL01 Eigenwerte.pdf", pages: twoPages)])
        let index = FakeDocIndexCloud(), explain = FakeExplainCloud(), indexAI = FakeDocIndexAI(), tutorAI = FakeAI("Erklärung [1] fertig.")
        b.context.ai.set(tutorAI)
        b.context.docIndex.configure(cloud: index, cipher: cipher, explainCloud: explain)
        // Standard: nur der Index, keine Erklaerungen
        let basic = await DocIndexBuilder.prewarm(ctx: b.context, cloud: index, ai: indexAI, cipher: cipher, level: .basic, tutorAI: tutorAI)
        XCTAssertEqual(basic.started.count, 1)
        XCTAssertEqual(basic.explained, [])
        XCTAssertEqual(tutorAI.prompts.count, 0)
        XCTAssertEqual(explain.all, [])
        // "Alles": die Datei ist wieder dran (Index fertig, Erklaerungen fehlen): je Seite explain, je Seite mit Aufgabe steps
        let full = await DocIndexBuilder.prewarm(ctx: b.context, cloud: index, ai: indexAI, cipher: cipher, level: .full, tutorAI: tutorAI)
        XCTAssertEqual(full.candidates, 1)
        XCTAssertEqual(full.explained.count, 1)
        let e = try XCTUnwrap(full.explained.first)
        XCTAssertEqual(e.planned, 4, "2 Seiten x (explain + steps, jede Seite hat laut Fake-Index eine Aufgabe)")
        XCTAssertEqual(e.built, 4)
        XCTAssertEqual(e.shared, 4)
        XCTAssertEqual(e.aiCalls, 4)
        XCTAssertEqual(indexAI.calls.count, 2, "Index nur einmal")
        XCTAssertEqual(explain.all.map { "\($0.page)#\($0.mode)#\($0.variant)" }.sorted(), ["1#explain#1", "1#steps#1", "2#explain#1", "2#steps#1"])
        XCTAssertTrue(tutorAI.prompts.allSatisfy { !$0.prompt.contains("QUELLEN") && !$0.prompt.contains("AUS STUD.IP") }, "nur Seite, Kurs, Datei")
        XCTAssertTrue(tutorAI.prompts.contains { $0.prompt.contains("AUFGABE: Loese die Aufgabe") })
        // noch einmal: nichts mehr zu tun
        let again = await DocIndexBuilder.prewarm(ctx: b.context, cloud: index, ai: indexAI, cipher: cipher, level: .full, tutorAI: tutorAI)
        XCTAssertEqual(again.candidates, 0)
        XCTAssertEqual(tutorAI.prompts.count, 4)
        // ein zweites Geraet mit derselben Datei uebernimmt alles ohne KI (auch im Vorwaermen)
        let (second, _) = try await seeded([Seed(id: "f-x", name: "VL01 Eigenwerte.pdf", pages: twoPages)], container: dir)
        let ai2 = FakeAI("nie")
        second.context.ai.set(ai2)
        second.context.docIndex.configure(cloud: index, cipher: cipher, explainCloud: explain)
        let adopted = await DocIndexBuilder.prewarm(ctx: second.context, cloud: index, ai: indexAI, cipher: cipher, level: .full, tutorAI: ai2)
        XCTAssertEqual(adopted.explained.first?.adopted, 4)
        XCTAssertEqual(adopted.explained.first?.aiCalls, 0)
        XCTAssertEqual(ai2.prompts.count, 0)
        XCTAssertEqual(indexAI.calls.count, 2)
        let r = try await tutor(second, ["file_id": "f-x", "page": 2, "mode": "steps"])
        XCTAssertEqual(r["explain"]?["source"]?.string, "cloud")
        XCTAssertEqual(r["answer"]?.string, "Erklärung fertig.")
        // Abbruch zwischen zwei Punkten: der Rest bleibt offen, der naechste Lauf macht weiter
        let (third, _) = try await seeded([Seed(id: "f-neu", name: "Folien Neu.pdf", pages: twoPages)])
        let ai3 = FakeAI("Erklärung.")
        third.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: nil)
        let stopAfter = 1
        let stopped = await DocIndexBuilder.prewarm(ctx: third.context, cloud: nil, ai: indexAI, cipher: cipher, level: .full, tutorAI: ai3,
                                                    shouldStop: { ai3.prompts.count >= stopAfter })
        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.explained.first?.built, 1)
        XCTAssertEqual(stopped.explained.first?.skipped, 3)
        XCTAssertEqual(stopped.explained.first?.shared, 0, "ohne Dienst nur lokal")
        let rest = await DocIndexBuilder.prewarm(ctx: third.context, cloud: nil, ai: indexAI, cipher: cipher, level: .full, tutorAI: ai3)
        XCTAssertEqual(rest.explained.first?.planned, 3)
        XCTAssertEqual(rest.explained.first?.built, 3)
        let status = try JSONValue.parse(await third.handle(LocalRequest(method: "GET", path: "/api/index/status")).body)
        XCTAssertEqual(status["explanations"]?.int, 4)
        XCTAssertEqual(status["explanations_shared"]?.int, 0)
        XCTAssertEqual(status["explain_library"]?.bool, false)
    }
}
