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
                    let pages = try await ScriptSearch.pageTexts(fileID: fileID, database: ctx.database, files: ctx.files, clock: ctx.clock)
                    guard !pages.isEmpty else { throw LocalHTTPError(status: 404, detail: ["detail": "Kein Seitentext vorhanden.", "code": "no_content"]) }
                    pageText = 1 <= page && page <= pages.count ? pages[page - 1] : ""
                }
            }
            let sources = mode == "flashcards" ? [] : try await tutorSources(fileID: fileID, fileName: fileName, page: page, text: pageText,
                                                                              selection: text("selection"), question: text("question"), ctx: ctx)
            let prompt = AIPrompts.tutor(mode: mode, pageText: pageText, selection: text("selection"), question: text("question"),
                                         ownSolution: text("own_solution"), course: course, fileName: fileName, page: .int(String(page)),
                                         sources: sources.map(PyJSON.init))
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
    }

    private static let citation = PyRegex(#"\[(\d{1,2})\]"#)

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
                                                    database: ctx.database, files: ctx.files, cache: ctx.scriptIndex)
            for r in res["results"]?.array ?? [] {
                if r["file_id"]?.string == fileID, Int(r["page"]?.double ?? -1) == page { continue }
                let title = AIPrompts.truthy(r["title"].map(PyJSON.init)) ? r["title"]! : (r["name"] ?? .null)
                out.append(["n": .number(Double(out.count + 1)), "file_id": r["file_id"] ?? .null, "name": r["name"] ?? .null,
                            "title": title, "page": r["page"] ?? .null, "snippet": r["snippet"] ?? .null, "current": false])
                if out.count > limit { break }
            }
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
