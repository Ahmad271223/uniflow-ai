import Foundation

/// KI-Hilfe fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md) im lokalen Backend, wie
/// app/doc_explain_api.py: `POST /api/ai/document/plan` (ohne KI: Absicht, Umfang, Schritte, was schon erklaert ist,
/// Kostenzeile) und `POST /api/ai/document/step` (ein Schritt; Bloecke mit Seiten). Seitentext zuerst, Texterkennung nur
/// fuer Seiten ohne Textebene im Umfang (auf dem Geraet, kostenlos); Seiten ohne Text aus dem Dokument-Index. Jeder
/// Schritt liegt im Erklaerungsspeicher (`page_explain`, CloudKit `PageExplain`, Modus `doc1_<art>_<n>_<bis>`, Abdruck =
/// Schluessel des Schritts): wer dieselbe Datei hat, bekommt ihn sofort und mit 0 Credits. Die KI ist das ChatGPT des
/// Nutzers (`LocalContext.ai`); ohne KI gehen Plan und schon erklaerte Schritte, ein neuer Schritt nicht.
enum DocExplainEndpoints: LocalEndpointModule {
    static let name = "KI fuer das ganze Dokument"

    static func register(on router: LocalRouter) {
        router.post("/api/ai/document/plan") { req, ctx in
            var body = try req.objectBody()
            if (body["mode"]?.string ?? "").isEmpty {
                guard let intent = DocExplain.parseIntent(body["question"]?.string ?? "") else { return .json(["intent": false]) }
                body["mode"] = .string(intent.mode)
                body["scope"] = intent.scope.json
            }
            let run = try await build(body, ctx: ctx)
            var have = Set<String>()
            for s in run.plan.steps where await stored(run, s, ctx: ctx) != nil { have.insert(s.id) }
            let todo = run.plan.steps.filter { !have.contains($0.id) }.count
            let est = DocExplain.estimateMessage(way: "chatgpt", calls: todo, cached: run.plan.steps.count - todo)
            let title = (run.mode == "lecture" ? "Ganze Vorlesung erklären" : "Alle Aufgaben erklären") + " · " + run.scope.label
            return .json([
                "intent": true, "mode": .string(run.mode), "scope": run.scope.json, "title": .string(title),
                "pages": .number(Double(run.scope.to - run.scope.from + 1)),
                "steps": .array(run.plan.steps.map { $0.publicJSON(cached: have.contains($0.id)) }),
                "calls": .number(Double(todo)), "cached": .number(Double(run.plan.steps.count - todo)),
                "estimate": ["way": "chatgpt", "credits": .null, "calls": .number(Double(todo))], "balance": .null,
                "skipped_pages": .array(run.plan.skippedPages.map { .number(Double($0)) }),
                "message": .string(est.message), "confirm": .bool(est.confirm), "enough": .bool(est.enough),
            ])
        }

        router.post("/api/ai/document/step") { req, ctx in
            let body = try req.objectBody()
            let run = try await build(body, ctx: ctx)
            let sid = body["step"]?.string ?? ""
            guard let step = run.plan.steps.first(where: { $0.id == sid }) else {
                throw LocalHTTPError(status: 404, detail: ["detail": "Diesen Teil gibt es im Dokument nicht mehr. Bitte neu starten.", "code": "step_not_found"])
            }
            let force = body["force"]?.bool == true
            if !force, let hit = await stored(run, step, ctx: ctx) {
                return .json(["step": .string(sid), "blocks": .array(DocExplain.parseBlocks(hit.text, step: step).map(\.json)),
                              "stored": hit.json, "credits": .null])
            }
            var sections: [DocExplain.Block] = []
            if step.kind == "overview" {
                for s in run.plan.steps where s.kind == "lecture" {
                    guard let prev = await stored(run, s, ctx: ctx) else {
                        throw LocalHTTPError(status: 409, detail: ["detail": "Erst die Abschnitte erklären lassen, dann den Überblick.", "code": "sections_missing"])
                    }
                    sections += DocExplain.parseBlocks(prev.text, step: s)
                }
            }
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            let answer: String
            do {
                answer = try await ai.answer(system: DocExplain.system, prompt: DocExplain.prompt(step, pageCount: run.texts.count, sections: sections))
            } catch let e as AIError {
                throw LocalHTTPError(status: e.code == "chatgpt_limit" ? 429 : 503, detail: ["detail": .string(e.message), "code": .string(e.code)])
            }
            var saved: JSONValue = ["stored": false, "variant": 0, "shared": false]
            if let key = key(run, step) {
                saved = await PageExplainBuilder.store(answer: answer, key: key, mode: step.storeMode, model: nil, ctx: ctx,
                                                       cloud: ctx.docIndex.explainCloud, cipher: ctx.docIndex.cipher).json
            }
            return .json(["step": .string(sid), "blocks": .array(DocExplain.parseBlocks(answer, step: step).map(\.json)), "stored": saved,
                          "credits": .null])
        }
    }

    /// Ein aufgeloester Lauf: Modus, Umfang, Seitentexte, Plan und (wenn die Datei auf dem Geraet liegt) Datei-SHA und -Schluessel
    struct Run {
        let mode: String
        let scope: DocExplain.ResolvedScope
        let texts: [String]
        let plan: DocExplain.Plan
        let sha: String?
        let fileKey: String?
    }

    static func failure(_ e: DocExplain.Failure) -> LocalHTTPError {
        LocalHTTPError(status: e.status, detail: ["detail": .string(e.message), "code": .string(e.code)])
    }

    static func build(_ body: [String: JSONValue], ctx: LocalContext) async throws -> Run {
        let fileID = body["file_id"]?.string ?? ""
        guard !fileID.isEmpty else { throw LocalHTTPError(status: 400, detail: ["detail": "file_id fehlt", "code": "bad_request"]) }
        let mode = body["mode"]?.string ?? ""
        guard DocExplain.modes.contains(mode) else {
            throw LocalHTTPError(status: 400, detail: ["detail": "mode muss lecture oder tasks sein.", "code": "bad_mode"])
        }
        let meta = try await ctx.database.withConnection { try DocIndexStore.fileMeta($0, fileID: fileID, clock: ctx.clock) }
        guard try await ctx.database.queryOne("SELECT 1 FROM files WHERE id=?", [.text(fileID)]) != nil else {
            throw LocalHTTPError(status: 404, detail: ["detail": "Datei nicht gefunden.", "code": "not_found"])
        }
        var texts = try await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx, ocrScope: .none)
        guard !texts.isEmpty else { throw LocalHTTPError(status: 404, detail: ["detail": "Kein Seitentext vorhanden.", "code": "no_content"]) }
        let page = body["page"]?.int ?? 1
        let scope: DocExplain.ResolvedScope
        do {
            scope = try DocExplain.resolveScope(body["scope"], pageCount: texts.count, current: page, texts: texts)
        } catch let e as DocExplain.Failure { throw failure(e) }
        // Texterkennung nur fuer Seiten ohne Textebene im Umfang (einmal je Seite, auf dem Geraet)
        let bare = Set((scope.from...scope.to).filter { !DocExplain.readable(texts[$0 - 1]) })
        if !bare.isEmpty, ctx.ocr.provider != nil {
            let read = try await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx, ocrScope: .pages(bare))
            if read.count == texts.count { texts = read }
        }
        var sha = meta?.sha
        if sha == nil, let p = meta?.localPath, let files = ctx.files, files.exists(stored: p), let url = files.url(stored: p) { sha = ContentHash.file(url) }
        // Dokument-Index: Zusammenfassung fuer Seiten ohne Text, Aufgaben, wenn keine erkannt werden (0 Credits)
        var summaries: [Int: String] = [:]
        var indexTasks: [(page: Int, label: String)] = []
        if let sha {
            let rows = (try? await ctx.database.withConnection { try DocIndexStore.rows($0, fileSHA: sha) }) ?? []
            for r in rows where r.page >= 1 && r.isOK {
                guard let rec = r.content.flatMap(DocIndexPageRecord.init(json:)) else { continue }
                if !rec.entry.summary.isEmpty { summaries[r.page] = rec.entry.summary }
                indexTasks += rec.entry.tasks.map { (r.page, $0.label) }
            }
        }
        let plan: DocExplain.Plan
        do {
            plan = try DocExplain.planSteps(mode: mode, texts: texts, from: scope.from, to: scope.to, indexSummaries: summaries, indexTasks: indexTasks)
        } catch let e as DocExplain.Failure { throw failure(e) }
        return Run(mode: mode, scope: scope, texts: texts, plan: plan, sha: sha, fileKey: sha.flatMap { DocIndexFingerprint.fileKey(fileSHA: $0) })
    }

    /// Schluessel eines Schritts im Erklaerungsspeicher: Seite = von, Abdruck = Schluessel des Schritts
    static func key(_ run: Run, _ step: DocExplain.Step) -> PageExplainBuilder.Key? {
        guard let sha = run.sha, let fileKey = run.fileKey else { return nil }
        return PageExplainBuilder.Key(fileSHA: sha, fileKey: fileKey, page: step.from, pageHash: step.hash)
    }

    /// Schon erklaert? Eigener Zwischenspeicher, dann der Dienst (wird uebernommen); nil = live fragen
    static func stored(_ run: Run, _ step: DocExplain.Step, ctx: LocalContext) async -> PageExplainBuilder.Stored? {
        guard let key = key(run, step) else { return nil }
        return await PageExplainBuilder.stored(key: key, mode: step.storeMode, ctx: ctx, cloud: ctx.docIndex.explainCloud, cipher: ctx.docIndex.cipher)
    }
}
