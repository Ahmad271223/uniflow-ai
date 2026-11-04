import Foundation

/// KI-Endpunkte mit der KI des Nutzers (`LocalContext.ai`, auf dem iPad sein ChatGPT-Abo), wie app/server.py am eigenen
/// PC. Ohne verbundene KI wie bisher 404 "KI-Funktionen gibt es in dieser Version nicht" (`DroppedEndpoints.noAI`).
/// Gesendet wird nur, was der Endpunkt fuer den Prompt braucht (Seitentext, Markierung, Frage, Quellen der Skriptsuche).
enum AIEndpoints: LocalEndpointModule {
    static let name = "KI (ChatGPT des Nutzers)"

    static func register(on router: LocalRouter) {
        router.post("/api/ai/tutor") { req, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            let body = try req.pythonObjectBody()
            func text(_ key: String) -> String {
                let v = AIPrompts.or(body.value(key), .string(""))
                if case .string(let s)? = v { return s }
                return AIPrompts.str(v)
            }
            let modeValue = AIPrompts.or(body.value("mode"), .string("explain"))
            let mode = AIPrompts.str(modeValue)
            let fileValue = body.value("file_id")
            let fileID: String? = AIPrompts.truthy(fileValue) ? AIPrompts.str(fileValue) : nil
            let page = try LocalTerms.pyInt(AIPrompts.or(body.value("page"), .int("1")), field: "page")
            var pageText = text("page_text")
            var course = "", fileName = ""
            if let fileID {
                let row = try await ctx.database.queryOne(
                    "SELECT f.name, c.title AS course_title FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", [.text(fileID)])
                if let row {
                    course = row["course_title"]?.string ?? ""
                    fileName = row["name"]?.string ?? ""
                }
                if PyText.strip(pageText).isEmpty {
                    // page_text(file_id, page): ohne gespeicherten Seitentext 404 wie am PC
                    guard try await ctx.database.queryOne("SELECT 1 FROM files WHERE id=?", [.text(fileID)]) != nil else {
                        throw LocalHTTPError.notFound("Datei nicht gefunden")
                    }
                    // nur die offene Seite erkennen, wenn ihre Textebene fast leer ist
                    let pages = try await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx, ocrScope: .pages([page]))
                    guard !pages.isEmpty else { throw LocalHTTPError(status: 404, detail: ["detail": "Kein Seitentext vorhanden.", "code": "no_content"]) }
                    pageText = 1 <= page && page <= pages.count ? pages[page - 1] : ""
                }
            }
            // Kursbeschreibung und Sitzungsthemen der Woche aus Stud.IP (02.11.2026, `course_context.for_file`); Zusatz,
            // ein Fehler laesst ihn weg
            let today = LocalTimetable.today(ctx.clock)
            let studip = fileID == nil ? "" : ((try? await ctx.database.withConnection { try CourseContext.forFile($0, fileID: fileID, today: today) }) ?? "")
            let sources = mode == "flashcards" ? [] : try await tutorSources(fileID: fileID, fileName: fileName, page: page, text: pageText,
                                                                              selection: text("selection"), question: text("question"), ctx: ctx)
            let prompt = AIPrompts.tutor(mode: mode, pageText: pageText, selection: text("selection"), question: text("question"),
                                         ownSolution: text("own_solution"), course: course, fileName: fileName, page: .int(String(page)),
                                         sources: sources.map(PyJSON.init), history: AIPrompts.tutorHistory(body.value("history")),
                                         studip: studip)
            let answer: String
            do {
                answer = try await ai.answer(system: AIPromptTexts.tutorSystem, prompt: prompt)
            } catch let e as AIError {
                throw LocalHTTPError(status: e.code == "chatgpt_limit" ? 429 : 503, detail: ["detail": .string(e.message), "code": .string(e.code)])
            }
            var cards: JSONValue = .null
            if mode == "flashcards", let parsed = try? AIAnswers.parseJSON(answer) { cards = parsed.json }
            let cited = Set(citation.findAllGroups(answer).compactMap { Int($0) })
            let withCited: [JSONValue] = sources.map { s in
                var o = s.object ?? [:]
                o["cited"] = .bool(cited.contains(Int(s["n"]?.double ?? -1)))
                return .object(o)
            }
            return .json(["answer": .string(answer), "cards": cards, "sources": .array(withCited)])
        }

        router.post("/api/files/{file_id}/analyze") { req, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            return .json(try await analyze(fileID: req.param("file_id"), ai: ai, ctx: ctx))
        }

        // Karteikarten aus den Seiten eines Dokuments (03.11.2026, wie `ai_flashcards` in app/server.py):
        // {file_id, pages?: [int], count?, topic?} -> {cards, pages, count}. Nur Vorschlaege; gespeichert wird mit
        // POST /api/flashcards (source = file), nachdem der Nutzer sie durchgesehen hat.
        router.post("/api/ai/flashcards") { req, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            let body = try req.pythonObjectBody()
            guard AIPrompts.truthy(body.value("file_id")) else { throw LocalHTTPError(status: 400, message: "file_id fehlt") }
            let fileID = AIPrompts.str(body.value("file_id"))
            guard let f = try await ctx.database.queryOne(
                "SELECT f.name, c.title AS course_title FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", [.text(fileID)]) else {
                throw LocalHTTPError.notFound("Datei nicht gefunden")
            }
            let wanted = pageList(body.value("pages"), total: nil)
            let allPages: [String]
            do {
                // nur die gewuenschten Seiten erkennen (Texterkennung je Seite); ohne Angabe die ersten
                allPages = try await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx,
                                                            ocrScope: wanted.isEmpty ? .leading(flashcardPagesMax) : .pages(Set(wanted)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LocalHTTPError(status: 500, message: "Seitentext nicht lesbar")
            }
            guard !allPages.isEmpty else {
                throw LocalHTTPError(status: 404, detail: ["detail": "Kein Seitentext vorhanden.", "code": "no_content"])
            }
            let pages = pageList(body.value("pages"), total: allPages.count)
            let text = pages.map { allPages[$0 - 1] }.joined(separator: "\n\n")
            let count = AIPrompts.flashcardsCount(body.value("count"))
            let topicValue = AIPrompts.or(body.value("topic"), .string(""))
            let topic: String = { if case .string(let s)? = topicValue { return s }; return AIPrompts.str(topicValue) }()
            let prompt = AIPrompts.flashcards(course: f["course_title"]?.string ?? "", fileName: f["name"]?.string ?? "",
                                              pages: pages, text: text, count: count, topic: topic)
            let answer: String
            do {
                answer = try await ai.answer(system: AIPromptTexts.system, prompt: prompt, schema: AIPrompts.flashcardsSchema)
            } catch let e as AIError {
                throw LocalHTTPError(status: e.code == "chatgpt_limit" ? 429 : 503, detail: ["detail": .string(e.message), "code": .string(e.code)])
            }
            let cards = (try? AIAnswers.parseJSON(answer)).map(AIAnswers.checkFlashcards) ?? []
            guard !cards.isEmpty else {
                throw LocalHTTPError(status: 502, detail: ["detail": "Die KI hat keine Karteikarten geliefert. Bitte erneut versuchen.", "code": "ai_no_cards"])
            }
            return .json(["cards": .array(cards.map(\.json)), "pages": .array(pages.map { .number(Double($0)) }),
                          "count": .number(Double(count))])
        }
    }

    /// `FLASHCARD_PAGES_MAX`: hoechstens so viele Seiten je Anfrage
    static let flashcardPagesMax = 20

    /// `_page_list(raw, total)`: ganze Zahlen 1..total (ohne `total`: nur >= 1), aufsteigend ohne Doppelte, hoechstens
    /// `flashcardPagesMax`; leer oder unbrauchbar = die ersten Seiten (mit `total`), sonst leer
    static func pageList(_ raw: PyJSON?, total: Int?) -> [Int] {
        var pages: [Int] = []
        if case .array(let items)? = raw {
            for p in items {
                let v: Int?
                switch p {
                case .int(let d): v = Int(d)
                case .float(let f) where f.isFinite: v = Int(f.rounded(.towardZero))
                case .string(let s): v = PyConvert.int(s)
                case .bool(let b): v = b ? 1 : 0
                default: v = nil
                }
                guard let v, v >= 1, total.map({ v <= $0 }) ?? true, !pages.contains(v) else { continue }
                pages.append(v)
            }
        }
        let chosen = Array(pages.sorted().prefix(flashcardPagesMax))
        if !chosen.isEmpty { return chosen }
        guard let total else { return [] }
        return Array(1...max(1, min(total, flashcardPagesMax)))
    }

    private static let citation = PyRegex(#"\[(\d{1,2})\]"#)

    /// `extract.MAX_CHARS`: so viel Text der Datei geht in die Analyse
    static let analysisChars = 14000
    /// so viele Seiten ohne Textebene erkennt die Analyse hoechstens (Texterkennung, `PageOCR`)
    static let analysisOCRPages = 10

    /// `int(x or standard)` wie in `_store_analysis`; unlesbare Werte -> standard (Python wuerde scheitern)
    static func pyIntOr(_ v: PyJSON?, _ fallback: Int) -> Int {
        guard AIPrompts.truthy(v) else { return fallback }
        switch v {
        case .some(.int(let d)): return Int(d) ?? fallback
        case .some(.float(let f)) where f.isFinite: return Int(f.rounded(.towardZero))
        case .some(.string(let s)): return PyConvert.int(s) ?? fallback
        case .some(.bool(let b)): return b ? 1 : 0
        default: return fallback
        }
    }

    /// `POST /api/files/{id}/analyze` auf dem Geraet: nur **diese** Datei mit der KI des Nutzers einordnen (am PC
    /// startet der Pfad `analyze_pending` fuer bis zu 200 Dateien; das verbraeuchte hier unbemerkt das ChatGPT-Kontingent)
    /// und gleich antworten. Gespeichert wie `planner._store_analysis`; die feste Einordnung aus Ordner und Dateiname
    /// (`StudyClassify`) bleibt vorrangig, die Analyse fuellt nur Luecken.
    static func analyze(fileID: String, ai: AIProvider, ctx: LocalContext) async throws -> JSONValue {
        guard let f = try await ctx.database.queryOne(
            "SELECT f.name, c.title AS course_title FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", [.text(fileID)]) else {
            throw LocalHTTPError.notFound("Datei nicht gefunden")
        }
        // erkannt werden hoechstens die ersten Seiten (die Analyse nimmt nur den Anfang des Textes)
        let pages = (try? await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx, ocrScope: .leading(analysisOCRPages))) ?? []
        let text = PyText.slice(pages.joined(separator: "\n"), 0, analysisChars)
        let prompt = AIPrompts.analysis(course: f["course_title"]?.string ?? "", fileName: f["name"]?.string ?? "", text: text)
        let res: PyJSON
        do {
            res = try AIAnswers.parseJSON(try await ai.answer(system: AIPromptTexts.system, prompt: prompt))
        } catch let e as AIError {
            throw LocalHTTPError(status: e.code == "chatgpt_limit" ? 429 : 503, detail: ["detail": .string(e.message), "code": .string(e.code)])
        }
        guard case .object(var members) = res, AIPrompts.truthy(AIPrompts.get(res, "doc_type")) else {
            throw LocalHTTPError(status: 502, detail: ["detail": "Die KI hat keine Einordnung geliefert. Bitte erneut versuchen.", "code": "ai_no_analysis"])
        }
        members.removeAll { $0.key == "_input" }
        members.append(.init("_input", .string("text")))
        let raw = PyJSON.object(members)
        func listJSON(_ key: String) -> String {
            let v = AIPrompts.get(raw, key)
            return (AIPrompts.truthy(v) ? v! : .array([])).dumps(ensureASCII: false)
        }
        func textOrNull(_ key: String) -> SQLiteValue {
            guard let v = AIPrompts.get(raw, key), v != .null else { return .null }
            if case .string(let s) = v { return .text(s) }
            return .text(AIPrompts.str(v))
        }
        let now = ctx.clock.nowISO
        try await ctx.database.transaction { c in
            _ = try c.execute("""
                INSERT OR REPLACE INTO analysis(file_id, doc_type, title, topics, difficulty, est_minutes, summary, prerequisites, raw, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, [.text(fileID), textOrNull("doc_type"), textOrNull("title"), .text(listJSON("topics")),
                      .integer(Int64(pyIntOr(AIPrompts.get(raw, "difficulty"), 3))), .integer(Int64(pyIntOr(AIPrompts.get(raw, "est_minutes"), 45))),
                      textOrNull("summary"), .text(listJSON("prerequisites")), .text(raw.dumps(ensureASCII: false)), .text(now)])
            _ = try c.execute("UPDATE files SET text_excerpt=? WHERE id=?", [.text(PyText.slice(text, 0, 4000)), .text(fileID)])
        }
        let stored = try await ctx.database.queryOne("SELECT * FROM analysis WHERE file_id=?", [.text(fileID)])
        return ["analysis": stored.map { .object($0.json) } ?? .null]
    }

    /// `_tutor_sources`: [1] die offene Seite, dazu bis zu 4 passende Seiten aus dem Modul (Skriptsuche mit Markierung,
    /// Frage oder dem Anfang der Seite); leer ohne Datei. Fehler der Suche lassen nur die offene Seite.
    static func tutorSources(fileID: String?, fileName: String, page: Int, text: String, selection: String, question: String,
                             ctx: LocalContext, limit: Int = 4) async throws -> [JSONValue] {
        guard let fileID else { return [] }
        var out: [JSONValue] = [["n": 1, "file_id": .string(fileID), "name": .string(fileName), "title": .string(fileName),
                                 "page": .number(Double(page)), "current": true]]
        let joined = [selection, question].filter { !PyText.strip($0).isEmpty }.joined(separator: " ")
        let query = joined.isEmpty ? PyText.slice(text, 0, 700) : joined
        do {
            let module = try await ctx.database.queryOne("SELECT c.module_id FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?",
                                                         [.text(fileID)])?["module_id"]
            guard let module, LocalModules.truthy(module), !PyText.strip(query).isEmpty else { return out }
            let res = try await ScriptSearch.search(moduleID: module, query: query, exclude: nil, limit: limit + 2,
                                                    database: ctx.database, files: ctx.files, cache: ctx.scriptIndex, ocr: nil)
            // ohne OCR: die Frage wartet sonst auf die Texterkennung aller Skripte des Moduls; erkannte Seiten aus dem
            // Hintergrund (Wochentests) stehen schon in page_texts
            for r in res["results"]?.array ?? [] {
                if r["file_id"]?.string == fileID, Int(r["page"]?.double ?? -1) == page { continue }
                let title = AIPrompts.truthy(r["title"].map(PyJSON.init)) ? r["title"]! : (r["name"] ?? .null)
                out.append(["n": .number(Double(out.count + 1)), "file_id": r["file_id"] ?? .null, "name": r["name"] ?? .null,
                            "title": title, "page": r["page"] ?? .null, "snippet": r["snippet"] ?? .null, "current": false])
                if out.count > limit { break }
            }
            // dazu hoechstens zwei passende Lerntexte aus Stud.IP (Courseware, Wiki, Forum; StudIPTexts)
            let start = out.count + 1
            out += (try? await ctx.database.withConnection { try StudIPTexts.tutorSources($0, moduleID: module, query: query, start: start) }) ?? []
        } catch {
            return out                                    // Quellen sind Zusatz, der Tutor laeuft auch ohne
        }
        return out
    }
}

extension PyRegex {
    /// `re.findall(p, s)` fuer Muster mit genau einer Gruppe: die Gruppen aller Treffer
    func findAllGroups(_ s: String) -> [String] {
        regex.matches(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]) }
        }
    }
}
