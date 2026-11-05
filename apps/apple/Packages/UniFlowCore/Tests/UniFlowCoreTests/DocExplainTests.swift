import Foundation
import XCTest
@testable import UniFlowCore

// KI-Hilfe fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md): Erwartungswerte aus Python
// (fixtures/doc-explain/cases.json: Absicht, Kapitel, Umfang, Aufgaben, Schritte mit Schluessel und Prompt, Bloecke,
// Kostenzeilen) und die Endpunkte /api/ai/document/plan und /step mit Fake-KI und Fake-Dienst: der erste erklaert die
// ganze Vorlesung Schritt fuer Schritt und teilt jeden Teil, der zweite mit derselben Datei bekommt alles ohne KI.

private func contractsDir() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("packages/shared-contracts")
}

/// KI-Attrappe mit Antwort je Prompt
final class PromptAI: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    let reply: @Sendable (String) -> String
    init(_ reply: @escaping @Sendable (String) -> String) { self.reply = reply }
    var prompts: [String] { lock.withLock { seen } }
    func answer(system: String, prompt: String) async throws -> String {
        lock.withLock { seen.append(prompt) }
        return reply(prompt)
    }
}

final class DocExplainTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-05T09:00:00")!
    private let cipher = TestHMACCipher()

    private func cases() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: contractsDir().appendingPathComponent("fixtures/doc-explain/cases.json")))
    }

    static func lecture(pages: Int, chars: Int, tag: String) -> [String] {
        (1...pages).map { p in
            let body = "Folie \(p) – \(tag): Eigenwerte, Matrizen, Abbildungen (ä ö ü ß, ∑ x²). "
            return PyText.slice(String(repeating: body, count: chars / PyText.length(body) + 1), 0, chars)
        }
    }

    private func strings(_ v: JSONValue?) -> [String] { v?.array?.compactMap(\.string) ?? [] }

    // MARK: Erwartungswerte aus Python

    func testConstantsAndSystemMatchPython() throws {
        let c = try cases()
        let k = c["constants"] ?? .null
        XCTAssertEqual(k["version"]?.int, DocExplain.version)
        XCTAssertEqual(k["lang"]?.string, DocExplain.lang)
        XCTAssertEqual(k["max_pages"]?.int, DocExplain.maxPages)
        XCTAssertEqual(k["page_chars_max"]?.int, DocExplain.pageCharsMax)
        XCTAssertEqual(k["lecture_step_chars"]?.int, DocExplain.lectureStepChars)
        XCTAssertEqual(k["task_step_chars"]?.int, DocExplain.taskStepChars)
        XCTAssertEqual(k["tasks_per_step"]?.int, DocExplain.tasksPerStep)
        XCTAssertEqual(k["task_chars_max"]?.int, DocExplain.taskCharsMax)
        XCTAssertEqual(k["confirm_above"]?.int, DocExplain.confirmAbove)
        XCTAssertEqual(k["overview_section_chars"]?.int, DocExplain.overviewSectionChars)
        XCTAssertEqual(k["overview_chars"]?.int, DocExplain.overviewChars)
        XCTAssertEqual(c["system"]?.string, DocExplain.system)
        for l in c["labels"]?.array ?? [] {
            XCTAssertEqual(DocExplain.pagesLabel(l["from"]?.int ?? 0, l["to"]?.int ?? 0), l["short"]?.string)
            XCTAssertEqual(DocExplain.rangeWords(l["from"]?.int ?? 0, l["to"]?.int ?? 0), l["words"]?.string)
        }
        for m in c["store_modes"]?.array ?? [] {
            XCTAssertEqual(DocExplain.isStoreMode(m["mode"]?.string ?? ""), m["ok"]?.bool, m["mode"]?.string ?? "")
            XCTAssertEqual(PageExplain.isStoredMode(m["mode"]?.string ?? ""), m["ok"]?.bool == true || m["mode"]?.string == "explain")
        }
    }

    func testIntentsMatchPython() throws {
        for c in try cases()["intents"]?.array ?? [] {
            let q = c["q"]?.string ?? ""
            let got = DocExplain.parseIntent(q)
            guard let out = c["out"], !out.isNull else { XCTAssertNil(got, q); continue }
            XCTAssertEqual(got?.mode, out["mode"]?.string, q)
            XCTAssertEqual(got?.scope.json, out["scope"], q)
        }
    }

    func testChaptersAndScopesMatchPython() throws {
        let c = try cases()
        let texts = strings(c["chapters"]?["texts"])
        for (n, v) in c["chapters"]?["found"]?.object ?? [:] {
            let want = v.array?.compactMap(\.int) ?? []
            let got = DocExplain.findChapter(texts, Int(n)!)
            XCTAssertEqual(got.map { [$0.0, $0.1] } ?? [], want, "Kapitel \(n)")
        }
        for s in c["scopes"]?.array ?? [] {
            let out = s["out"] ?? .null
            do {
                let r = try DocExplain.resolveScope(s["scope"]?.isNull == true ? nil : s["scope"], pageCount: s["pages"]?.int ?? 0,
                                                    current: s["current"]?.int ?? 1, texts: texts)
                XCTAssertNil(out["error"], "\(s)")
                XCTAssertEqual(r.json, out, "\(s)")
            } catch let e as DocExplain.Failure {
                XCTAssertEqual(e.code, out["error"]?.string, "\(s)")
            }
        }
    }

    func testTasksMatchPython() throws {
        let c = try cases()
        let got = DocExplain.detectTasks(strings(c["tasks"]?["texts"]), 1, 4)
        let want = c["tasks"]?["out"]?.array ?? []
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.label, w["label"]?.string)
            XCTAssertEqual(g.from, w["from"]?.int, g.label)
            XCTAssertEqual(g.to, w["to"]?.int, g.label)
            XCTAssertTrue(g.text.unicodeScalars.elementsEqual((w["text"]?.string ?? "").unicodeScalars), g.label)
        }
    }

    private func planTexts(_ p: JSONValue) -> [String] {
        if let g = p["generate"], !g.isNull {
            return Self.lecture(pages: g["pages"]?.int ?? 0, chars: g["chars"]?.int ?? 0, tag: g["tag"]?.string ?? "")
        }
        return strings(p["texts"])
    }

    private func plan(_ p: JSONValue) throws -> DocExplain.Plan {
        var summaries: [Int: String] = [:]
        for (k, v) in p["index_summaries"]?.object ?? [:] { summaries[Int(k)!] = v.string }
        let tasks = (p["index_tasks"]?.array ?? []).map { (page: $0.array?[0].int ?? 0, label: $0.array?[1].string ?? "") }
        return try DocExplain.planSteps(mode: p["mode"]?.string ?? "", texts: planTexts(p), from: p["from"]?.int ?? 1, to: p["to"]?.int ?? 1,
                                        indexSummaries: summaries, indexTasks: tasks)
    }

    func testPlansHashesAndPromptsMatchPython() throws {
        let c = try cases()
        var plans: [String: DocExplain.Plan] = [:]
        for p in c["plans"]?.array ?? [] {
            let name = p["name"]?.string ?? ""
            let got = try plan(p)
            plans[name] = got
            let pageCount = planTexts(p).count
            let want = p["steps"]?.array ?? []
            XCTAssertEqual(got.steps.count, want.count, name)
            XCTAssertEqual(got.skippedPages, p["skipped_pages"]?.array?.compactMap(\.int), name)
            for (s, w) in zip(got.steps, want) {
                XCTAssertEqual(s.id, w["id"]?.string, name)
                XCTAssertEqual(s.n, w["n"]?.int, name)
                XCTAssertEqual(s.title, w["title"]?.string, name)
                XCTAssertEqual(JSONValue.array(s.tasks.map(\.json)), w["tasks"], name)
                XCTAssertEqual(s.hash, w["hash"]?.string, "\(name) \(s.id)")
                XCTAssertEqual(s.storeMode, w["store_mode"]?.string, name)
                let prompt = DocExplain.prompt(s, pageCount: pageCount)
                XCTAssertEqual(PyText.length(prompt), w["prompt_chars"]?.int, "\(name) \(s.id)")
                XCTAssertEqual(SolutionSHA256.hex(Data(prompt.utf8)), w["prompt_sha"]?.string, "\(name) \(s.id)")
            }
        }
        for p in c["prompts"]?.array ?? [] {
            let name = p["plan"]?.string ?? ""
            let planJSON = (c["plans"]?.array ?? []).first { $0["name"]?.string == name }!
            let step = try XCTUnwrap(plans[name]?.steps[p["step"]?.int ?? 0])
            let sections = (p["sections"]?.array ?? []).compactMap(DocExplain.Block.init(json:))
            let pageCount = name == "no_tasks" ? 4 : planTexts(planJSON).count
            let got = DocExplain.prompt(step, pageCount: pageCount, sections: sections)
            XCTAssertTrue(got.unicodeScalars.elementsEqual((p["prompt"]?.string ?? "").unicodeScalars), "Prompt \(name)")
        }
    }

    func testBlocksAndEstimatesMatchPython() throws {
        let c = try cases()
        for b in c["blocks"]?.array ?? [] {
            let s = b["step"] ?? .null
            let tasks = (s["tasks"]?.array ?? []).map { DocExplain.TaskRef(label: $0["label"]?.string ?? "", from: $0["from"]?.int ?? 0, to: $0["to"]?.int ?? 0, text: "") }
            let step = DocExplain.Step(id: "x", n: 1, kind: s["kind"]?.string ?? "", from: s["from"]?.int ?? 0, to: s["to"]?.int ?? 0,
                                       title: s["title"]?.string ?? "", tasks: tasks, parts: [], labels: tasks.map(\.label), hash: "")
            XCTAssertEqual(JSONValue.array(DocExplain.parseBlocks(b["answer"]?.string ?? "", step: step).map(\.json)), b["out"], b["name"]?.string ?? "")
        }
        for e in c["estimates"]?.array ?? [] {
            let i = e["in"] ?? .null
            let r = DocExplain.estimateMessage(way: i["way"]?.string ?? "", calls: i["calls"]?.int ?? 0, cached: i["cached"]?.int ?? 0,
                                               credits: i["credits"]?.int, remaining: i["remaining"]?.int)
            XCTAssertEqual(r.message, e["out"]?["message"]?.string)
            XCTAssertEqual(r.confirm, e["out"]?["confirm"]?.bool, r.message)
            XCTAssertEqual(r.enough, e["out"]?["enough"]?.bool, r.message)
        }
        XCTAssertEqual(DocExplain.estimateMessage(way: "credits", calls: 6, cached: 0, credits: 6, remaining: 74).message, "Kostet etwa 6 Credits, du hast 74.")
    }

    // MARK: Endpunkte

    private func seeded(_ files: [(id: String, name: String, pages: [String])], container: URL? = nil) async throws -> (LocalBackend, URL) {
        let dir = try container ?? tempContainer(self)
        let tools = TextTools(Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.pages) }))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: dir, dataDirectory: "", tools: tools))
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('c-la', 'Lineare Algebra', 'vorlesung', 1, ?)", [.text(self.clock.nowISO)])
            for f in files {
                let path = "StudIP/\(f.name)"
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { try Data("%PDF-1.4 fake \(f.name)".utf8).write(to: url) }
                try c.execute("""
                    INSERT INTO files(id, course_id, name, mime, chdate, local_path, downloaded_at, kind, status, content_sha256, page_count)
                    VALUES (?, 'c-la', ?, 'application/pdf', 1761469200, ?, ?, 'pdf', 'neu', ?, ?)
                    """, [.text(f.id), .text(f.name), .text(path), .text(self.clock.nowISO), .text(ContentHash.file(url)!), .integer(Int64(f.pages.count))])
            }
        }
        return (backend, dir)
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue, status: Int = 200) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                            headers: ["Content-Type": "application/json"], body: body.serialized()))
        XCTAssertEqual(r.status, status, String(decoding: r.body, as: UTF8.self))
        return try JSONValue.parse(r.body)
    }

    private static let lectureReply: @Sendable (String) -> String = { prompt in
        if prompt.contains("Genau zwei Abschnitte") { return "## Überblick [S. 1–40]\nRote Linie.\n## Prüfungsrelevant [S. 1–40]\n- Polynom (S. 12)" }
        let from = prompt.components(separatedBy: "(Seiten ")[1].components(separatedBy: "–")[0]
        return "## Abschnitt ab \(from) [S. \(from)]\nKernideen.\nPrüfungsrelevant: Eigenwerte."
    }

    func testWholeLectureRunsStepByStepAndTheNextStudentPaysNothing() async throws {
        let pages = Self.lecture(pages: 40, chars: 1500, tag: "Lineare Algebra")
        let (first, dir) = try await seeded([("f-vl", "VL05 Eigenwerte.pdf", pages)])
        let cloud = FakeExplainCloud()
        let ai = PromptAI(Self.lectureReply)
        first.context.ai.set(ai)
        first.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: cloud)

        let normal = try await post(first, "/api/ai/document/plan", ["file_id": "f-vl", "question": "Was ist ein Eigenwert?"])
        XCTAssertEqual(normal, ["intent": false])
        let plan = try await post(first, "/api/ai/document/plan", ["file_id": "f-vl", "page": 3, "question": "nimm dem dokument erkläre ganze vorlesung"])
        XCTAssertEqual(plan["mode"]?.string, "lecture")
        XCTAssertEqual(plan["title"]?.string, "Ganze Vorlesung erklären · Ganzes Dokument (Seiten 1–40)")
        let steps = plan["steps"]?.array ?? []
        XCTAssertEqual(steps.compactMap { $0["kind"]?.string }, ["lecture", "lecture", "lecture", "overview"])
        XCTAssertEqual(plan["message"]?.string, "4 Anfragen über dein ChatGPT · 0 Credits.")
        XCTAssertEqual(plan["confirm"]?.bool, true)
        let body: [String: JSONValue] = ["file_id": "f-vl", "page": 3, "mode": "lecture", "scope": ["kind": "all"]]
        var overviewFirst = body
        overviewFirst["step"] = steps[3]["id"]
        let early = try await post(first, "/api/ai/document/step", .object(overviewFirst), status: 409)
        XCTAssertEqual(early["detail"]?["code"]?.string, "sections_missing")

        var blocks: [JSONValue] = []
        for s in steps {
            var b = body
            b["step"] = s["id"]
            let r = try await post(first, "/api/ai/document/step", .object(b))
            XCTAssertEqual(r["stored"]?["shared"]?.bool, true)
            blocks += r["blocks"]?.array ?? []
        }
        XCTAssertEqual(ai.prompts.count, 4)
        XCTAssertTrue(ai.prompts[3].contains("## Abschnitt ab 1 [S. 1]"), "Ueberblick aus den Abschnitten")
        XCTAssertEqual(blocks.compactMap { $0["kind"]?.string }, ["section", "section", "section", "overview", "overview"])
        XCTAssertEqual(blocks.first?["from"]?.int, 1)
        XCTAssertEqual(Set(cloud.all.map(\.mode)).count, 4)
        XCTAssertTrue(cloud.all.allSatisfy { DocExplain.isStoreMode($0.mode) && !$0.payload.contains("Kernideen") })

        // zweites Geraet, dieselbe Datei: alles schon erklaert, keine KI
        let (second, _) = try await seeded([("f-x", "VL05 Eigenwerte.pdf", pages)], container: dir)
        let ai2 = PromptAI { _ in "sollte nicht gefragt werden" }
        second.context.ai.set(ai2)
        second.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: cloud)
        var body2 = body
        body2["file_id"] = "f-x"
        let plan2 = try await post(second, "/api/ai/document/plan", .object(body2))
        XCTAssertEqual(plan2["message"]?.string, "Schon erklärt · 0 Credits")
        XCTAssertEqual(plan2["calls"]?.int, 0)
        XCTAssertEqual(plan2["confirm"]?.bool, false)
        for s in plan2["steps"]?.array ?? [] {
            var b = body2
            b["step"] = s["id"]
            let r = try await post(second, "/api/ai/document/step", .object(b))
            XCTAssertEqual(r["stored"]?["stored"]?.bool, true)
            XCTAssertEqual(r["stored"]?["source"]?.string, "cloud")
        }
        XCTAssertEqual(ai2.prompts.count, 0, "0 Credits")
        XCTAssertEqual(cloud.saves, 4)
    }

    func testAllTasksOneBlockPerTaskAndScopeErrors() async throws {
        let sheet = ["Übungsblatt 3\nAufgabe 1 (4 Punkte)\nBerechne die Determinante.\nAufgabe 2\na) Zeige, dass A invertierbar ist.",
                     "b) Folgere daraus.\nAufgabe 3a\nLöse das LGS.\nAufgabe 3b\nInterpretiere."]
        let (b, _) = try await seeded([("f-blatt", "Blatt 3.pdf", sheet)])
        b.context.ai.set(PromptAI { _ in "Gern!\n## Aufgabe 1 [S. 1]\nA\n## Aufgabe 2 [S. 1–2]\nB\n## Aufgabe 3a [S. 7]\nC\n## Aufgabe 3b\nD" })
        b.context.docIndex.configure(cloud: nil, cipher: cipher, explainCloud: FakeExplainCloud())
        let plan = try await post(b, "/api/ai/document/plan", ["file_id": "f-blatt", "question": "Löse alle Aufgaben"])
        XCTAssertEqual(plan["mode"]?.string, "tasks")
        XCTAssertEqual(plan["message"]?.string, "1 Anfrage über dein ChatGPT · 0 Credits.")
        XCTAssertEqual(plan["confirm"]?.bool, false)
        let step = try XCTUnwrap(plan["steps"]?.array?.first)
        XCTAssertEqual(step["tasks"]?.array?.count, 4)
        let r = try await post(b, "/api/ai/document/step", ["file_id": "f-blatt", "mode": "tasks", "scope": plan["scope"] ?? .null, "step": step["id"] ?? .null])
        let got = (r["blocks"]?.array ?? []).map { "\($0["title"]?.string ?? "") \($0["from"]?.int ?? 0)-\($0["to"]?.int ?? 0)" }
        XCTAssertEqual(got, ["Aufgabe 1 1-1", "Aufgabe 2 1-2", "Aufgabe 3a 2-2", "Aufgabe 3b 2-2"])
        // Kapitel, das es nicht gibt; Seiten jenseits des Dokuments; unbekannter Schritt
        let ch = try await post(b, "/api/ai/document/plan", ["file_id": "f-blatt", "question": "Fasse Kapitel 9 zusammen"], status: 422)
        XCTAssertEqual(ch["detail"]?["code"]?.string, "chapter_not_found")
        let far = try await post(b, "/api/ai/document/plan", ["file_id": "f-blatt", "question": "Erkläre Seiten 5 bis 9"], status: 422)
        XCTAssertEqual(far["detail"]?["code"]?.string, "bad_scope")
        let gone = try await post(b, "/api/ai/document/step", ["file_id": "f-blatt", "mode": "tasks", "scope": ["kind": "all"], "step": "7:tasks:1-2"], status: 404)
        XCTAssertEqual(gone["detail"]?["code"]?.string, "step_not_found")
        // ohne verbundene KI: Plan geht, ein neuer Schritt nicht
        b.context.ai.set(nil)
        _ = try await post(b, "/api/ai/document/plan", ["file_id": "f-blatt", "mode": "lecture", "scope": ["kind": "page"], "page": 2])
        _ = try await post(b, "/api/ai/document/step", ["file_id": "f-blatt", "mode": "lecture", "scope": ["kind": "page"], "page": 2, "step": "1:full:2-2"],
                           status: 404)
    }
}
