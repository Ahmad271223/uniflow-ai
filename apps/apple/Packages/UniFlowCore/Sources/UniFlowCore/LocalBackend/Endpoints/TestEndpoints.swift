import Foundation

/// Hintergrundauftrag wie `_run_bg` und `GET /api/bg` in app/server.py: hoechstens einer gleichzeitig; die Oberflaeche
/// fragt `/api/bg` ab, bis er fertig ist ("<Name>: fertig (…)" bzw. "<Name>: FEHLER …").
public actor LocalBackgroundJob {
    private var running = false
    private var task: String?
    private var message = ""

    public init() {}

    public var state: JSONValue {
        ["running": .bool(running), "task": task.map(JSONValue.string) ?? .null, "message": .string(message)]
    }

    /// Startet `op` im Hintergrund; laeuft schon einer, 409 wie am PC
    func start(_ name: String, _ op: @escaping @Sendable () async throws -> String?) throws -> JSONValue {
        if running { throw LocalHTTPError(status: 409, message: "Es laeuft bereits: \(task ?? "")") }
        running = true
        task = name
        message = ""
        Task {
            var text: String
            do {
                let out = try await op()
                text = "\(name): fertig" + ((out?.isEmpty ?? true) ? "" : " (\(out!))")
            } catch let e as AIError {
                text = "\(name): FEHLER \(e.message)"
            } catch let e as LocalHTTPError {
                text = "\(name): FEHLER \(e.detail["detail"]?.string ?? e.detail.string ?? "")"
            } catch {
                text = "\(name): FEHLER \(error)"
            }
            self.finish(text)
        }
        return ["started": .string(name)]
    }

    private func finish(_ text: String) {
        message = text
        running = false
        task = nil
    }
}

/// Wochentests mit der KI des Nutzers wie app/planner.py (`create_test`, `create_weekly_tests`, `grade`) und die
/// Endpunkte aus app/server.py. Regel vom 29.10.2026: genau 15 Aufgaben (4 leicht, 6 mittel, 5 schwer) aus allen
/// Folien der Woche, mit Altklausur eine schwere Aufgabe im Klausurstil; falsche Form einmal neu anfordern, sonst
/// Fehler statt eines falschen Tests. Auf dem Geraet nur der Textweg (die PDF-Seiten liest am PC nur Claude).
/// Ohne KI: Liste, Ansehen und Loeschen wie bisher, Erzeugen und Bewerten 404 "Wochentests gibt es in dieser Version
/// nicht" (`DroppedEndpoints.noTests`).
enum TestEndpoints: LocalEndpointModule {
    static let name = "Wochentests (KI des Nutzers)"
    /// `HISTORY_BASIC`: ohne erweiterten Verlauf (Pro) die letzten 10 Tests
    static let historyBasic = 10

    static func register(on router: LocalRouter) {
        router.get("/api/tests") { _, ctx in
            let rows = try await ctx.database.rows("""
                SELECT id, subject, week_start, title, duration_min, created_at, started_at, submitted_at,
                       score, max_score, module_id, week_no, auto, def_id, questions FROM tests WHERE COALESCE(user_id,'local')='local'
                ORDER BY created_at DESC LIMIT \(historyBasic)
                """)
            return .json(.array(rows.map { r in
                var o = r
                let qs = o.removeValue(forKey: "questions")
                o["question_count"] = (qs?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) }?.array.map { .number(Double($0.count)) } ?? .null
                return .object(o)
            }))
        }

        router.get("/api/tests/{test_id:int}") { req, ctx in
            let id = Int64(req.param("test_id")) ?? 0
            let now = ctx.clock.nowISO
            guard var t = try await ctx.database.transaction({ c -> [String: JSONValue]? in
                guard var t = try c.queryOne("SELECT * FROM tests WHERE id=?", [.integer(id)])?.json else { return nil }
                if !LocalModules.truthy(t["started_at"]) {
                    _ = try c.execute("UPDATE tests SET started_at=? WHERE id=?", [.text(now), .integer(id)])
                    t["started_at"] = .string(now)
                }
                return t
            }) else { throw LocalHTTPError.notFound() }
            var questions = (t["questions"]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) }?.array ?? []
            if !LocalModules.truthy(t["submitted_at"]) {
                questions = questions.map { q in                       // Loesung, Loesungsweg und Quellen erst nach Abgabe sichtbar
                    guard var o = q.object else { return q }
                    for k in ["answer", "steps", "rubric", "refs", "from_exam", "exam_mode"] { o[k] = nil }
                    return .object(o)
                }
            }
            t["questions"] = .array(questions)
            t["answers"] = (t["answers"]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .object([:])
            t["feedback"] = (t["feedback"]?.string).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .null
            return .json(.object(t))
        }

        router.post("/api/tests/generate") { req, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noTests) }
            let body = try req.pythonObjectBody()
            let duration = AIPrompts.truthy(body.value("duration_min")) ? try LocalTerms.pyInt(body.value("duration_min"), field: "duration_min") : nil
            if AIPrompts.truthy(body.value("module_id")) {
                let mid = try LocalTerms.pyInt(body.value("module_id"), field: "module_id")
                guard let name = try await ctx.database.queryOne("SELECT name FROM modules WHERE id=?", [.integer(Int64(mid))])?["name"]?.string else {
                    throw LocalHTTPError.notFound("Modul nicht gefunden")
                }
                return .json(try await ctx.jobs.start("Test") {
                    String(try await WeekTests.create(ctx: ctx, ai: ai, subject: name, duration: duration, moduleID: Int64(mid), weekNo: nil, auto: false))
                })
            }
            guard case .string(let subject)? = body.value("subject"), !subject.isEmpty else { throw LocalHTTPError(status: 400, message: "subject fehlt") }
            return .json(try await ctx.jobs.start("Test") {
                String(try await WeekTests.create(ctx: ctx, ai: ai, subject: subject, duration: duration, moduleID: nil, weekNo: nil, auto: false))
            })
        }

        router.post("/api/tests/generate-week") { _, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noTests) }
            return .json(try await ctx.jobs.start("Wochentests") {
                let n = try await WeekTests.createWeekly(ctx: ctx, ai: ai).count
                let published = try await Weekly.tick(ctx)["published"]?.array?.count ?? 0
                return "\(n) klassisch, \(published) mit Seitenmarker"
            })
        }

        router.post("/api/tests/{test_id:int}/submit") { req, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noTests) }
            let body = try req.pythonObjectBody()
            var answers: [PyJSON.Member] = []
            if case .object(let m)? = body.value("answers") { answers = m.map { .init($0.key, $0.value) } }
            do {
                return .json(try await WeekTests.grade(ctx: ctx, ai: ai, testID: Int64(req.param("test_id")) ?? 0, answers: answers))
            } catch let e as AIError {
                throw LocalHTTPError(status: e.code == "chatgpt_limit" ? 429 : 500, detail: ["detail": .string(e.message), "code": .string(e.code)])
            }
        }

        router.delete("/api/tests/{test_id:int}") { req, ctx in
            let id = Int64(req.param("test_id")) ?? 0
            let now = ctx.clock.nowISO
            try await ctx.database.transaction { c in
                guard let t = try c.queryOne("SELECT auto, module_id, week_no, def_id, submitted_at FROM tests WHERE id=?", [.integer(id)]) else {
                    throw LocalHTTPError.notFound("Test nicht gefunden")
                }
                // abgegebene gemeinsame Wochentests (app/weekly.py) bleiben fuer Rangliste und Lernverlauf
                if LocalModules.truthy(t["def_id"]), LocalModules.truthy(t["submitted_at"]) {
                    throw LocalHTTPError(status: 400, message: "Abgegebene gemeinsame Tests bleiben für Rangliste und Lernverlauf erhalten.")
                }
                // sonst legt "Wochentests erstellen" denselben Wochentest sofort wieder an
                if LocalModules.truthy(t["auto"]), let m = t["module_id"], m != .null, let w = t["week_no"], w != .null {
                    _ = try c.execute("INSERT OR IGNORE INTO dismissed_tests(module_id, week_no, dismissed_at) VALUES (?,?,?)", [m, w, .text(now)])
                }
                _ = try c.execute("UPDATE plan_items SET test_id=NULL WHERE test_id=?", [.integer(id)])
                _ = try c.execute("UPDATE study_tasks SET test_id=NULL WHERE test_id=?", [.integer(id)])
                _ = try c.execute("DELETE FROM tests WHERE id=?", [.integer(id)])
            }
            return .json(["ok": true])
        }

        router.post("/api/tasks/{task_id:int}/start-test") { req, ctx in
            let taskID = Int64(req.param("task_id")) ?? 0
            // Fach mit Vorlesungs-Markern: der gemeinsame Wochentest (app/weekly.py), ohne KI; noch nicht veroeffentlicht -> 409
            let nowISO = ctx.clock.nowISO, hasAI = ctx.ai.provider != nil
            let marker: Int64? = try await ctx.database.transaction { c in
                guard let t = try c.queryOne("""
                    SELECT t.*, p.week_no, p.module_id FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?
                    """, [.integer(taskID)]), t["type"]?.string == "test" else {
                    // ohne KI wie bisher: Wochentests gibt es dann nicht (die Aufgabe fehlt oder ist keine Testaufgabe)
                    throw LocalHTTPError.notFound(hasAI ? "Testaufgabe nicht gefunden" : DroppedEndpoints.noTests)
                }
                if let tid = t["test_id"]?.int64, LocalModules.truthy(t["test_id"]) { return tid }
                guard LocalModules.truthy(t["module_id"]), LocalModules.truthy(t["week_no"]) else { return nil }
                let wid: Int?
                do { wid = try Weekly.taskTest(c, moduleID: t["module_id"]!, weekNo: t["week_no"]!, nowISO: nowISO) } catch let e as Weekly.Failure {
                    throw LocalHTTPError(status: 409, message: e.message)
                }
                guard let wid else { return nil }
                _ = try c.execute("UPDATE study_tasks SET test_id=?, status=CASE WHEN status='geplant' THEN 'in_bearbeitung' ELSE status END WHERE id=?",
                                  [.integer(Int64(wid)), .integer(taskID)])
                return Int64(wid)
            }
            if let marker { return .json(["test_id": .number(Double(marker))]) }
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noTests) }
            enum Found { case test(Int64), create(subject: String, minutes: Int, module: Int64?, week: Int?) }
            let found: Found = try await ctx.database.transaction { c in
                guard let t = try c.queryOne("""
                    SELECT t.*, p.subject, p.week_no, p.module_id FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?
                    """, [.integer(taskID)]), t["type"]?.string == "test" else { throw LocalHTTPError.notFound("Testaufgabe nicht gefunden") }
                if let tid = t["test_id"]?.int64, LocalModules.truthy(t["test_id"]) { return .test(tid) }
                let module = t["module_id"]?.int64, week = t["week_no"]?.int
                if LocalModules.truthy(t["module_id"]), LocalModules.truthy(t["week_no"]),
                   let ex = try c.queryOne("SELECT id FROM tests WHERE module_id=? AND week_no=? AND auto=1", [t["module_id"]!, t["week_no"]!])?["id"]?.int64 {
                    _ = try c.execute("UPDATE study_tasks SET test_id=? WHERE id=?", [.integer(ex), .integer(taskID)])
                    return .test(ex)
                }
                let est = t["est_minutes"]?.int ?? 0
                return .create(subject: t["subject"]?.string ?? "", minutes: est != 0 ? est : try WeekTests.settingsMinutes(c),
                               module: LocalModules.truthy(t["module_id"]) ? module : nil, week: LocalModules.truthy(t["week_no"]) ? week : nil)
            }
            switch found {
            case .test(let id):
                return .json(["test_id": .number(Double(id))])
            case .create(let subject, let minutes, let module, let week):
                let tid: Int
                do {
                    tid = try await WeekTests.create(ctx: ctx, ai: ai, subject: subject, duration: minutes, moduleID: module, weekNo: week, auto: true)
                } catch let e as AIError {
                    throw LocalHTTPError(status: 500, message: "Test konnte nicht erstellt werden: \(e.message)")
                }
                try await ctx.database.transaction { c in
                    _ = try c.execute("UPDATE study_tasks SET test_id=?, status=CASE WHEN status='geplant' THEN 'in_bearbeitung' ELSE status END WHERE id=?",
                                      [.integer(Int64(tid)), .integer(taskID)])
                }
                return .json(["test_id": .number(Double(tid))])
            }
        }
    }
}

/// Wochentests wie app/planner.py
enum WeekTests {
    /// `s["test_minutes"]`
    static func settingsMinutes(_ c: SQLiteConnection) throws -> Int {
        let v = try c.scalar("SELECT value FROM settings WHERE key='test_minutes'")
        return v?.string.flatMap { Int($0) } ?? v?.int ?? 45
    }

    /// Text einer Datei: Auszug aus der Datenbank, sonst die gespeicherten Seitentexte (hoechstens 3500 Zeichen)
    static func text(ctx: LocalContext, fileID: String, excerpt: JSONValue?) async -> String {
        if let e = excerpt?.string, !e.isEmpty { return e }
        let pages = (try? await ScriptSearch.pageTexts(fileID: fileID, database: ctx.database, files: ctx.files, clock: ctx.clock)) ?? []
        return PyText.slice(pages.joined(separator: "\n"), 0, 3500)
    }

    /// `_materials_for_test`: bei Modul und Lehrwoche alle Vorlesungen und Uebungen dieser Woche (hoechstens 10, Vorlesung,
    /// Skript, Uebung, Loesung), sonst die neuesten 8 Dateien des Fachs
    static func materials(ctx: LocalContext, subject: String, moduleID: Int64?, weekNo: Int?) async throws -> [[String: JSONValue]] {
        var rows: [[String: JSONValue]] = try await ctx.database.withConnection { c in
            if let moduleID, let weekNo {
                let dates = try LocalModules.Dates(c, clock: ctx.clock)
                let order = ["vorlesung": 0, "skript": 1, "uebung": 2, "loesung": 3]
                let files = try LocalModules.fileRows(c, moduleID: .integer(moduleID)).filter {
                    try LocalModules.week($0, dates: dates) == weekNo && StudyClassify.lectureWeekTypes.contains($0.docType ?? "")
                }.enumerated().sorted { a, b in
                    let ka = order[a.element.docType ?? ""] ?? 4, kb = order[b.element.docType ?? ""] ?? 4
                    if ka != kb { return ka < kb }
                    let ca = a.element.chdate.double ?? 0, cb = b.element.chdate.double ?? 0
                    return ca != cb ? ca < cb : a.offset < b.offset
                }.map(\.element).prefix(10)
                if !files.isEmpty {
                    return try files.map { f in
                        let p = try c.queryOne("SELECT text_excerpt, content_sha256 FROM files WHERE id=?", [SQLiteValue(json: f.id) ?? .null])
                        return ["id": f.id, "name": f.json["name"] ?? .null, "title": f.json["ai_title"] ?? .null, "doc_type": f.json["doc_type"] ?? .null,
                                "difficulty": f.json["difficulty"] ?? .null, "text": p?["text_excerpt"]?.json ?? .null,
                                "content_sha256": p?["content_sha256"]?.json ?? .null]
                    }
                }
            }
            return try c.rows("""
                SELECT f.id, f.name, f.text_excerpt AS text, f.content_sha256, a.title, a.doc_type, a.difficulty
                FROM files f JOIN courses c ON c.id = f.course_id
                LEFT JOIN analysis a ON a.file_id = f.id
                WHERE (c.subject = ? OR c.module_id = ?) AND c.active = 1 AND f.local_path IS NOT NULL
                  AND COALESCE(a.doc_type,'') NOT IN ('organisatorisch')
                ORDER BY f.chdate DESC LIMIT 8
                """, [.text(subject), .integer(moduleID ?? -1)])
        }
        for i in rows.indices {
            rows[i]["text"] = .string(await text(ctx: ctx, fileID: rows[i]["id"]?.string ?? "", excerpt: rows[i]["text"]))
        }
        return rows
    }

    /// `_exam_for_test`: neueste Altklausur des Moduls (Analyse `klausur`)
    static func exam(ctx: LocalContext, moduleID: Int64?) async throws -> [String: JSONValue]? {
        guard let moduleID else { return nil }
        guard var e: [String: JSONValue] = try await ctx.database.withConnection({ c in
            guard let f = try LocalModules.fileRows(c, moduleID: .integer(moduleID)).filter({ $0.docType == "klausur" }).last else { return nil }
            let p = try c.queryOne("SELECT text_excerpt, content_sha256 FROM files WHERE id=?", [SQLiteValue(json: f.id) ?? .null])
            return ["id": f.id, "name": f.json["name"] ?? .null, "title": f.json["ai_title"] ?? .null,
                    "text": p?["text_excerpt"]?.json ?? .null, "content_sha256": p?["content_sha256"]?.json ?? .null]
        }) else { return nil }
        e["text"] = .string(await text(ctx: ctx, fileID: e["id"]?.string ?? "", excerpt: e["text"]))
        return e
    }

    /// `ai.generate_test` (Textweg): hoechstens zwei Versuche, jede Antwort muss `check_week_test` bestehen
    static func generate(ai: AIProvider, subject: String, duration: Int, materials: [[String: JSONValue]], exam: [String: JSONValue]?) async throws -> PyJSON {
        let block = AIPrompts.testTextBlock(materials.map { PyJSON(.object($0)) })
        let examBlock = AIPrompts.examTextBlock(exam.map { PyJSON(.object($0)) })
        let prompt = AIPrompts.weekTest(subject: subject, durationMin: duration, materialsBlock: block, examBlock: examBlock)
        var why: String?
        for _ in 0..<2 {
            let res = try AIAnswers.parseJSON(try await ai.answer(system: AIPromptTexts.system, prompt: prompt))
            why = AIAnswers.checkWeekTest(res, exam: !examBlock.isEmpty)
            if why == nil { return res }
        }
        throw AIError("ai_week_test_form", "Die KI hat den Wochentest zweimal nicht in der geforderten Form geliefert (\(why ?? "")). Bitte spaeter erneut versuchen.")
    }

    /// `planning_week`: Mo–Do die laufende Woche, ab Freitag die naechste
    static func planningWeek(_ clock: UniFlowClock) -> String {
        guard let today = AIPrompts.Day(iso: clock.today) else { return clock.today }
        let monday = today.adding(-today.weekday)
        return (today.weekday >= 4 ? monday.adding(7) : monday).iso
    }

    private static let weekPrefix = PyRegex(#"^Lehrwoche \d+:\s*"#)

    /// `create_test`: Test anlegen; `auto` = gemeinsamer Wochentest des Moduls fuer die Lehrwoche (hoechstens einer)
    static func create(ctx: LocalContext, ai: AIProvider, subject: String, duration: Int?, moduleID: Int64?, weekNo: Int?, auto: Bool) async throws -> Int {
        let ws = planningWeek(ctx.clock)
        var module = moduleID
        let pre: (existing: Int?, minutes: Int, university: String) = try await ctx.database.withConnection { c in
            if module == nil { module = try c.queryOne("SELECT id FROM modules WHERE name=?", [.text(subject)])?["id"]?.int64 }
            if auto, let m = module, let w = weekNo,
               let ex = try c.queryOne("SELECT id FROM tests WHERE module_id=? AND week_no=? AND auto=1", [.integer(m), .integer(Int64(w))])?["id"]?.int {
                return (ex, 0, "")
            }
            var minutes = duration ?? 0
            if duration == nil {
                let m = try module.flatMap { try c.queryOne("SELECT test_minutes FROM modules WHERE id=?", [.integer($0)])?["test_minutes"]?.int }
                minutes = (m ?? 0) != 0 ? m! : try settingsMinutes(c)
            }
            let uni = try c.scalar("SELECT value FROM settings WHERE key='university'")?.string ?? Migrations.defaultUniversity
            return (nil, minutes, uni)
        }
        if let existing = pre.existing { return existing }
        let mats = try await materials(ctx: ctx, subject: subject, moduleID: module, weekNo: weekNo)
        let ex = try await exam(ctx: ctx, moduleID: module)
        // gemeinsamer Wochentest: gleiche Materialien (Inhalt) und Dauer -> derselbe Test ohne neue KI-Anfrage
        let key = auto && !mats.isEmpty
            ? TestShare.shareKey(university: pre.university, minutes: pre.minutes, contentHashes: (mats + (ex.map { [$0] } ?? [])).map { $0["content_sha256"]?.string })
            : nil
        guard !mats.isEmpty else { throw AIError("no_materials", "Keine Materialien fuer \(subject)") }
        var title: String
        var questions: PyJSON
        if let key, let shared = try await ctx.database.queryOne("SELECT title, questions FROM tests WHERE share_key=? ORDER BY id LIMIT 1", [.text(key)]) {
            title = weekPrefix.sub(shared["title"]?.string ?? "")
            questions = (try? PyJSON.parse(shared["questions"]?.string ?? "[]")) ?? .array([])
        } else {
            let res = try await generate(ai: ai, subject: subject, duration: pre.minutes, materials: mats, exam: ex)
            title = AIPrompts.truthy(AIPrompts.get(res, "title")) ? AIPrompts.str(AIPrompts.get(res, "title")) : "Wochentest \(subject)"
            questions = AIPrompts.get(res, "questions") ?? .array([])
        }
        if title.isEmpty { title = "Wochentest \(subject)" }
        if let weekNo {
            title = "Lehrwoche \(weekNo): " + PyText.strip(title.replacingOccurrences(of: "Wochentest \(subject)", with: ""), chars: " –-:")
        }
        let now = ctx.clock.nowISO
        let finalTitle = title, json = questions.dumps(ensureASCII: false)
        return try await ctx.database.transaction { c in
            do {
                _ = try c.execute("""
                    INSERT INTO tests(subject, week_start, title, duration_min, questions, created_at, module_id, week_no, auto, share_key)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, [.text(subject), .text(ws), .text(finalTitle), .integer(Int64(pre.minutes)), .text(json), .text(now),
                          module.map(SQLiteValue.integer) ?? .null, weekNo.map { .integer(Int64($0)) } ?? .null, .integer(auto ? 1 : 0),
                          key.map(SQLiteValue.text) ?? .null])
            } catch {
                // eindeutiger Index: parallel entstandener Wochentest
                if let m = module, let w = weekNo,
                   let ex = try c.queryOne("SELECT id FROM tests WHERE module_id=? AND week_no=? AND auto=1", [.integer(m), .integer(Int64(w))])?["id"]?.int {
                    return ex
                }
                throw error
            }
            let id = c.lastInsertRowID
            _ = try c.execute("UPDATE plan_items SET test_id=? WHERE week_start=? AND subject=? AND kind='test' AND test_id IS NULL",
                              [.integer(id), .text(ws), .text(subject)])
            if auto, let m = module, let w = weekNo {
                _ = try c.execute("""
                    UPDATE study_tasks SET test_id=? WHERE test_id IS NULL AND type='test' AND package_id IN
                    (SELECT id FROM study_packages WHERE module_id=? AND week_no=?)
                    """, [.integer(id), .integer(m), .integer(Int64(w))])
            }
            return Int(id)
        }
    }

    /// `create_weekly_tests`: je aktivem Modul mit Wochentest die beiden juengsten Lehrwochen mit Vorlesung oder Uebung,
    /// ohne vorhandenen oder vom Nutzer geloeschten Test
    static func createWeekly(ctx: LocalContext, ai: AIProvider) async throws -> [Int] {
        let todo: [(name: String, id: Int64, minutes: Int, week: Int)] = try await ctx.database.withConnection { c in
            let dates = try LocalModules.Dates(c, clock: ctx.clock)
            let fallback = try settingsMinutes(c)
            var out: [(String, Int64, Int, Int)] = []
            for m in try c.rows("SELECT * FROM modules WHERE active=1 AND weekly_test=1") {
                guard let mid = m["id"]?.int64 else { continue }
                // Module mit Vorlesungs-Seitenmarkern laufen ueber Weekly (Stoff nur bis zum Marker)
                if try c.queryOne("SELECT 1 FROM lecture_markers WHERE module_id=? AND deleted_at IS NULL", [.integer(mid)]) != nil { continue }
                var weeks = Set<Int>()
                for f in try LocalModules.fileRows(c, moduleID: .integer(mid)) where ["vorlesung", "uebung"].contains(f.docType ?? "") {
                    let w = try LocalModules.week(f, dates: dates)
                    if w >= 1 { weeks.insert(w) }
                }
                for w in weeks.sorted().suffix(2) {
                    if try c.queryOne("SELECT 1 FROM tests WHERE module_id=? AND week_no=? AND auto=1", [.integer(mid), .integer(Int64(w))]) != nil { continue }
                    if try c.queryOne("SELECT 1 FROM dismissed_tests WHERE module_id=? AND week_no=?", [.integer(mid), .integer(Int64(w))]) != nil { continue }
                    let minutes = m["test_minutes"]?.int ?? 0
                    out.append((m["name"]?.string ?? "", mid, minutes != 0 ? minutes : fallback, w))
                }
            }
            return out
        }
        var ids: [Int] = []
        for t in todo {
            // ein Modul ohne Materialien oder mit falscher KI-Antwort haelt die anderen nicht auf (wie am PC)
            if let id = try? await create(ctx: ctx, ai: ai, subject: t.name, duration: t.minutes, moduleID: t.id, weekNo: t.week, auto: true) {
                ids.append(id)
            }
        }
        return ids
    }

    /// `grade`: Antworten von der KI bewerten lassen und speichern
    static func grade(ctx: LocalContext, ai: AIProvider, testID: Int64, answers: [PyJSON.Member]) async throws -> JSONValue {
        guard let t = try await ctx.database.queryOne("SELECT * FROM tests WHERE id=?", [.integer(testID)]) else {
            throw LocalHTTPError(status: 500, message: "Test nicht gefunden")
        }
        let questionsValue = (try? PyJSON.parse(t["questions"]?.string ?? "[]")) ?? .array([])
        guard case .array(let questions) = questionsValue else { throw LocalHTTPError(status: 500, message: "Test ohne Aufgaben") }
        let shared = LocalModules.truthy(t["def_id"])
        if shared, LocalModules.truthy(t["submitted_at"]) {
            throw LocalHTTPError(status: 500, message: "Dieser gemeinsame Test wurde bereits abgegeben und wird nicht neu bewertet.")
        }
        let answersValue = PyJSON.object(answers.map { .init(PyText.str(.string($0.key)), $0.value) })
        var res = try AIAnswers.parseJSON(try await ai.answer(system: AIPromptTexts.system,
                                                              prompt: AIPrompts.grade(subject: t["subject"]?.string ?? "", questions: questions, answers: answersValue)))
        // gemeinsamer Wochentest: Multiple Choice ohne KI, Punkte begrenzt -> gleiche Kriterien fuer alle
        if shared { res = Weekly.gradeConsistent(questions, answers, res) }
        var duration: SQLiteValue = .null
        if let started = t["started_at"]?.string, !started.isEmpty, let a = Weekly.seconds(started), let b = Weekly.seconds(ctx.clock.nowISO) {
            duration = .integer(Int64(b - a))
        }
        func number(_ v: PyJSON?) -> Double? {
            switch v { case .some(.int(let d)): return Double(d); case .some(.float(let f)): return f; default: return nil }
        }
        let total = AIPrompts.truthy(AIPrompts.get(res, "total")) ? number(AIPrompts.get(res, "total")) ?? 0 : 0
        let maxScore = AIPrompts.truthy(AIPrompts.get(res, "max")) ? number(AIPrompts.get(res, "max")) ?? 0
            : PyMath.sum(questions.map { number(AIPrompts.get($0, "points")) ?? 0 })
        let now = ctx.clock.nowISO
        try await ctx.database.transaction { c in
            _ = try c.execute("UPDATE tests SET submitted_at=?, answers=?, score=?, max_score=?, feedback=?, duration_sec=? WHERE id=?",
                              [.text(now), .text(answersValue.dumps(ensureASCII: false)), .real(total), .real(maxScore),
                               .text(res.dumps(ensureASCII: false)), duration, .integer(testID)])
            _ = try c.execute("UPDATE plan_items SET done=1 WHERE test_id=?", [.integer(testID)])
        }
        return res.json
    }
}

private extension JSONValue {
    /// ganze Zahl einer Datenbankzeile
    var int64: Int64? { double.flatMap { $0 == $0.rounded() ? Int64($0) : nil } }
}
