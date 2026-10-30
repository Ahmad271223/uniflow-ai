import Foundation

/// Nie zwei KI-Laeufe fuer denselben Stoff gleichzeitig (`_GEN_LOCK`)
actor WeeklyGate {
    static let shared = WeeklyGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}

// MARK: - Plaene (Zeitplan)

extension Weekly {
    static func now(_ ctx: LocalContext) -> Int { seconds(ctx.clock.nowISO) ?? 0 }
    static func today(_ now: Int) -> Int { Int((Double(now) / 86_400).rounded(.down)) }

    /// `_expected(conn, module_id)`: erwartete Quellen laut Moduleinstellung
    static func expected(_ c: SQLiteConnection, _ moduleID: Int) throws -> [String] {
        let raw = try c.scalar("SELECT expected_materials FROM modules WHERE id=?", [.integer(Int64(moduleID))])?.string ?? ""
        let list = (try? JSONValue.parse(raw.isEmpty ? "[]" : raw))?.array ?? []
        return list.compactMap(\.string).filter { expectable.contains($0) }
    }

    static func pages(_ segs: [JSONValue]) -> Set<PageKey> {
        var out = Set<PageKey>()
        for sg in segs.map(Segment.init) where sg.to >= sg.from { for p in sg.from...sg.to { out.insert(PageKey(file: sg.fileID, page: p)) } }
        return out
    }

    /// `refresh_plans(conn, module_id, user_id, now)`: je Lehrwoche mit neu markiertem Stoff ein Plan
    @discardableResult
    static func refreshPlans(_ c: SQLiteConnection, _ moduleID: Int, user: String = localUser, now: Int) throws -> [[String: JSONValue]] {
        let st = try settings(c)
        let full = try coverage(c, moduleID: moduleID, user: user)
        let weeks = Set(full.segments.compactMap { $0.week == 0 ? nil : $0.week }).sorted()
        let mid = SQLiteValue.integer(Int64(moduleID))
        var out: [[String: JSONValue]] = []
        for w in weeks {
            let cov = try coverage(c, moduleID: moduleID, uptoWeek: w, user: user, scope: full.scope)
            let weekSegs = cov.segments.filter { $0.week == w }
            let published = try c.rows("SELECT * FROM wt_plans WHERE module_id=? AND week_no=? AND status='veroeffentlicht' AND scope=? ORDER BY part",
                                       [mid, .integer(Int64(w)), .text(full.scope)])
            var done = Set<PageKey>()
            for p in published { done.formUnion(pages((try? JSONValue.parse(p["coverage"]?.string ?? ""))?["new"]?.array ?? [])) }
            var new: [Segment] = []
            for sg in weekSegs where sg.to >= sg.from {
                let pg = (sg.from...sg.to).filter { !done.contains(PageKey(file: sg.fileID, page: $0)) }
                if let first = pg.first, let last = pg.last { var x = sg; x.from = first; x.to = last; new.append(x) }
            }
            if new.isEmpty { continue }
            let key = scopeKey(cov.segments) + (published.isEmpty ? "" : "-t\(published.count + 1)")
            if let existing = try c.rows("SELECT * FROM wt_plans WHERE module_id=? AND week_no=? AND scope_key=?", [mid, .integer(Int64(w)), .text(key)]).first {
                out.append(existing)
                continue
            }
            // unveroeffentlichte Plaene mit altem Stoffumfang dieser Woche werden ersetzt (nie veroeffentlichte)
            try c.execute("UPDATE wt_plans SET status='ersetzt' WHERE module_id=? AND week_no=? AND scope=? AND status IN ('geplant','wartet','fehlgeschlagen')",
                          [mid, .integer(Int64(w)), .text(full.scope)])
            let end = new.map(\.lectureEnd).max { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) } ?? ""
            let pub = (seconds(end) ?? now) + Int((st.publishHours * 3600).rounded())
            let dl = pub + Int((st.maxDelayHours * 3600).rounded())
            let covj = PyJSON.object([.init("new", .array(new.map(\.py))), .init("prior", .array(cov.segments.filter { ($0.week ?? 0) < w }.map(\.py))),
                                      .init("blocked", .array(cov.blocked))])
            do {
                try c.execute("""
                    INSERT INTO wt_plans(module_id, week_no, part, scope, scope_key, user_id, coverage, lecture_end, publish_at, deadline_at,
                    status, expected, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [mid, .integer(Int64(w)), .integer(Int64(published.count + 1)), .text(full.scope), .text(key),
                          full.scope == "personal" ? .text(user) : .null, .text(covj.dumps(ensureASCII: false)), .text(end), .text(iso(pub)),
                          .text(iso(dl)), .text("geplant"), .text(PyJSON.array(try expected(c, moduleID).map(PyJSON.string)).dumps), .text(iso(now))])
                out.append(try c.rows("SELECT * FROM wt_plans WHERE id=?", [.integer(c.lastInsertRowID)]).first ?? [:])
            } catch {
                out.append(try c.rows("SELECT * FROM wt_plans WHERE module_id=? AND week_no=? AND scope_key=?", [mid, .integer(Int64(w)), .text(key)]).first ?? [:])
            }
        }
        return out
    }

    /// `_claim`: Plan fuer 20 Minuten belegen (ein Lauf je Plan)
    static func claim(_ c: SQLiteConnection, _ planID: Int64, now: Int, minutes: Int = 20) throws -> String? {
        let tok = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let n = try c.execute("""
            UPDATE wt_plans SET lock_token=?, lock_until=? WHERE id=? AND status IN ('geplant','wartet','fehlgeschlagen')
            AND (lock_until IS NULL OR lock_until < ?)
            """, [.text(tok), .text(iso(now + minutes * 60)), .integer(planID), .text(iso(now))])
        return n == 1 ? tok : nil
    }

    static func release(_ c: SQLiteConnection, _ planID: Int64, _ tok: String) throws {
        try c.execute("UPDATE wt_plans SET lock_token=NULL, lock_until=NULL WHERE id=? AND lock_token=?", [.integer(planID), .text(tok)])
    }

    /// Seitentexte und Suchindex eines Moduls fuer die synchronen Schritte
    static func prepare(_ moduleID: Int, _ ctx: LocalContext) async throws -> ScriptSearch.Index {
        try await ensurePages(try await moduleFileIDs(moduleID, ctx), ctx)
        return try await ScriptSearch.index(moduleID: .integer(Int64(moduleID)), database: ctx.database, files: ctx.files, cache: ctx.scriptIndex)
    }

    /// `tick(now)`: indexieren, Plaene aktualisieren, faellige Tests erzeugen und veroeffentlichen, Nachtraege anbieten
    static func tick(_ ctx: LocalContext, now: Int? = nil, user: String = localUser) async throws -> JSONValue {
        let now = now ?? Weekly.now(ctx)
        var published: [JSONValue] = [], waitingList: [JSONValue] = [], failed: [JSONValue] = [], nachtraege: [JSONValue] = []
        let mods: [Int] = try await ctx.database.withConnection { c in
            try c.query("""
                SELECT DISTINCT l.module_id FROM lecture_markers l JOIN modules m ON m.id=l.module_id
                WHERE l.deleted_at IS NULL AND COALESCE(m.weekly_test,1)=1 AND COALESCE(m.active,1)=1
                """).compactMap { $0["module_id"]?.int }
        }
        var indexes: [Int: ScriptSearch.Index] = [:]
        for mid in mods {
            let marked: [String] = try await ctx.database.withConnection { c in
                try c.query("SELECT DISTINCT file_id FROM lecture_markers WHERE module_id=? AND deleted_at IS NULL", [.integer(Int64(mid))]).compactMap { $0["file_id"]?.string }
            }
            try await ensurePages(marked, ctx)
            let idx = try await prepare(mid, ctx)
            indexes[mid] = idx
            try await ctx.database.transaction { c in
                for fid in marked.sorted() { try revalidateMarkers(c, fileID: fid, now: now) }
                try indexModule(c, mid, index: idx, now: now)
                try refreshPlans(c, mid, user: user, now: now)
            }
        }
        let due: [Int64] = try await ctx.database.withConnection { c in
            try c.query("""
                SELECT id FROM wt_plans WHERE status IN ('geplant','wartet','fehlgeschlagen') AND publish_at <= ? AND attempts < 3
                ORDER BY publish_at
                """, [.text(iso(now))]).compactMap { $0["id"]?.int.map(Int64.init) }
        }
        for id in due {
            guard let r = try await processPlan(ctx, id, now: now, indexes: &indexes) else { continue }
            switch r["result"]?.string {
            case "published": published.append(r)
            case "waiting": waitingList.append(r)
            default: failed.append(r)
            }
        }
        let pubs: [Int64] = try await ctx.database.withConnection { c in
            try c.query("SELECT id FROM wt_plans WHERE status='veroeffentlicht'").compactMap { $0["id"]?.int.map(Int64.init) }
        }
        for id in pubs {
            if let n = try? await offerNachtrag(ctx, id, now: now, indexes: &indexes) { nachtraege.append(n) }
        }
        return ["published": .array(published), "waiting": .array(waitingList), "failed": .array(failed), "nachtraege": .array(nachtraege)]
    }

    static func index(_ moduleID: Int, _ ctx: LocalContext, _ cache: inout [Int: ScriptSearch.Index]) async throws -> ScriptSearch.Index {
        if let i = cache[moduleID] { return i }
        let i = try await prepare(moduleID, ctx)
        cache[moduleID] = i
        return i
    }

    /// `process_plan(plan_id, now)`
    static func processPlan(_ ctx: LocalContext, _ planID: Int64, now: Int, indexes: inout [Int: ScriptSearch.Index]) async throws -> JSONValue? {
        let claimed: (String, [String: JSONValue])? = try await ctx.database.transaction { c in
            guard let tok = try claim(c, planID, now: now), let plan = try c.rows("SELECT * FROM wt_plans WHERE id=?", [.integer(planID)]).first else { return nil }
            return (tok, plan)
        }
        guard let (tok, plan) = claimed else { return nil }
        let result = await processClaimed(ctx, planID, plan, now: now, indexes: &indexes)
        try? await ctx.database.transaction { c in try release(c, planID, tok) }          // wie `finally` in Python
        return result
    }

    private static func processClaimed(_ ctx: LocalContext, _ planID: Int64, _ plan: [String: JSONValue], now: Int,
                                       indexes: inout [Int: ScriptSearch.Index]) async -> JSONValue {
        let moduleID = plan["module_id"]?.int ?? 0
        do {
            let idx = try await index(moduleID, ctx, &indexes)
            enum Step { case waiting(JSONValue), reuse([String: JSONValue], [String]), generate(Context) }
            let step: Step = try await ctx.database.transaction { c in
                let covj = (try? JSONValue.parse(plan["coverage"]?.string ?? "")) ?? .object([:])
                let newPages = pages(covj["new"]?.array ?? [])
                let covered = newPages.union(pages(covj["prior"]?.array ?? []))
                let cands = try candidates(c, moduleID, index: idx, covered: covered, newPages: newPages)
                let expectedList = (try? JSONValue.parse(plan["expected"]?.string ?? "[]"))?.array?.compactMap(\.string) ?? []
                let have = Set(cands.ok.filter(\.isNewWeek).map(\.source))
                let missing = expectedList.filter { !have.contains($0) }
                try c.execute("UPDATE wt_plans SET last_check=?, missing=? WHERE id=?",
                              [.text(iso(now)), .text(PyJSON.array(missing.map(PyJSON.string)).dumps), .integer(planID)])
                if !missing.isEmpty, now < (seconds(plan["deadline_at"]?.string ?? "") ?? 0) {
                    try c.execute("UPDATE wt_plans SET status='wartet' WHERE id=?", [.integer(planID)])
                    return .waiting(["result": "waiting", "plan_id": .number(Double(planID)), "missing": .array(missing.map(JSONValue.string))])
                }
                let st = try settings(c)
                let todayN = try c.scalar("SELECT COUNT(*) AS n FROM wt_defs WHERE substr(created_at,1,10)=?", [.text(BerlinClock.isoDate(today(now)))])?.int ?? 0
                let reuse = try c.rows("""
                    SELECT * FROM wt_defs WHERE kind='wochentest' AND module_id=? AND scope_key=? AND status IN ('geprueft','veroeffentlicht')
                    ORDER BY id DESC LIMIT 1
                    """, [.integer(Int64(moduleID)), v(plan["scope_key"])]).first
                if let reuse { return .reuse(reuse, missing) }
                if todayN >= st.dailyLimit {
                    try c.execute("UPDATE wt_plans SET last_error=? WHERE id=?",
                                  [.text("Tageslimit für KI-Tests erreicht (\(st.dailyLimit)), nächster Versuch beim nächsten Lauf."), .integer(planID)])
                    return .waiting(["result": "waiting", "plan_id": .number(Double(planID)), "missing": ["ki-limit"]])
                }
                return .generate(try buildContext(c, plan: plan, ok: cands.ok, excluded: cands.excluded, missing: missing))
            }
            var d: [String: JSONValue], missing: [String]
            switch step {
            case .waiting(let r): return r
            case .reuse(let def, let m): d = def; missing = m
            case .generate(let context): d = try await generateWeekly(ctx, context, now: now); missing = context.missing
            }
            let defID = Int64(d["id"]?.int ?? 0)
            try await ctx.database.transaction { c in try publish(c, planID, defID, now: now, nowISO: ctx.clock.nowISO) }
            return ["result": "published", "plan_id": .number(Double(planID)), "def_id": .number(Double(defID)),
                    "missing": .array(missing.map(JSONValue.string))]
        } catch {
            let message = String("\(error)".unicodeScalars.prefix(800))
            try? await ctx.database.transaction { c in
                try c.execute("UPDATE wt_plans SET status='fehlgeschlagen', last_error=?, attempts=attempts+1 WHERE id=?", [.text(message), .integer(planID)])
            }
            return ["result": "failed", "plan_id": .number(Double(planID)), "error": .string(String(message.unicodeScalars.prefix(300)))]
        }
    }
}

// MARK: - Material fuer die KI

extension Weekly {
    struct Lecture { var id: String, fileID: String, page: Int, new: Bool, text: String }
    struct TaskRef {
        var id: String, taskID: Int, source: String, label: String, isNewWeek: Bool, examTerm: String?, points: Double?
        var difficulty: Int?, text: String, solution: String, fileID: String, pageFrom: Int
    }

    struct Context {
        var plan: [String: JSONValue]
        var module: [String: JSONValue]?
        var lecture: [Lecture], prior: [Lecture], tasks: [TaskRef]
        var missing: [String], topic: String, excluded: [PyJSON], n: Int, examReuse: String, materialHash: String
        var moduleName: String { module?["name"]?.string ?? "None" }
    }

    /// `_page_text(conn, file_id, page)`
    static func pageText(_ c: SQLiteConnection, _ fileID: String, _ page: Int) throws -> String {
        let p = try pageTexts(c, fileID)
        return page > 0 && page <= p.count ? ScriptSearch.normalize(p[page - 1]) : ""
    }

    static let blankLines = PyRegex(#"\n{2,}"#)
    static let tabsSpaces = PyRegex(#"[ \t]+"#)

    /// `_short(t, n)`: Leerraum verdichten, nach `n` Zeichen am Wort kuerzen
    static func short(_ t: String, _ n: Int) -> String {
        let s = PyText.strip(tabsSpaces.sub(blankLines.sub(t, "\n"), " "))
        let u = Array(s.unicodeScalars)
        if u.count <= n { return s }
        var head = String(String.UnicodeScalarView(u[0..<n]))
        if let r = head.range(of: " ", options: .backwards) { head = String(head[..<r.lowerBound]) }
        return head + " …"
    }

    static func joinedTopics(_ topics: [String?]) -> String {
        var seen = Set<String>(), out: [String] = []
        for t in topics { if let t, !t.isEmpty, seen.insert(t).inserted { out.append(t) } }
        return out.joined(separator: " · ")
    }

    /// `build_context(conn, plan, cands, missing, n_questions)`
    static func buildContext(_ c: SQLiteConnection, plan: [String: JSONValue], ok: [Candidate], excluded: [PyJSON], missing: [String],
                             questions: Int? = nil) throws -> Context {
        let covj = (try? JSONValue.parse(plan["coverage"]?.string ?? "")) ?? .object([:])
        let module = try c.rows("SELECT * FROM modules WHERE id=?", [v(plan["module_id"])]).first
        let st = try settings(c)
        var pagesNew: [(String, Int)] = []
        let newSegs = (covj["new"]?.array ?? []).map(Segment.init)
        for sg in newSegs where sg.to >= sg.from { for p in sg.from...sg.to { pagesNew.append((sg.fileID, p)) } }
        if pagesNew.count > 60 {                             // sehr viel Stoff (Probeklausur): gleichmaessig auswaehlen
            let step = Double(pagesNew.count) / 60
            pagesNew = (0..<60).map { pagesNew[Int(Double($0) * step)] }
        }
        let perPage = max(250, min(900, 15000 / max(1, pagesNew.count)))
        var lec: [Lecture] = []
        for (fid, p) in pagesNew {
            let t = try pageText(c, fid, p)
            if len(norm(t)) >= 15 { lec.append(Lecture(id: "L\(lec.count + 1)", fileID: fid, page: p, new: true, text: short(t, perPage))) }
        }
        var prior: [Lecture] = []
        for sg in (covj["prior"]?.array ?? []).suffix(12).map(Segment.init) {
            prior.append(Lecture(id: "L\(lec.count + prior.count + 1)", fileID: sg.fileID, page: sg.to, new: false,
                                 text: "Bereits behandelt (Vorwissen): \(sg.topic ?? "") – Seiten \(sg.from)–\(sg.to): " + short(try pageText(c, sg.fileID, sg.from), 160)))
        }
        // Aufgaben: zuerst neuer Stoff, je Quelle die besten; Altklausur getrennt
        let sortedOK = ok.enumerated().sorted { a, b in
            let x = (a.element.isNewWeek ? 0 : 1, -(a.element.refs.first?.score ?? 0)), y = (b.element.isNewWeek ? 0 : 1, -(b.element.refs.first?.score ?? 0))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        var picked: [Candidate] = [], perSource: [String: Int] = [:]
        for cand in sortedOK {
            let lim = cand.source == "altklausur" ? 4 : 5
            if perSource[cand.source, default: 0] >= lim { continue }
            perSource[cand.source, default: 0] += 1
            picked.append(cand)
        }
        let tasks = picked.enumerated().map { i, cand -> TaskRef in
            let r = cand.row
            return TaskRef(id: "A\(i + 1)", taskID: cand.id, source: cand.source, label: r["label"]?.string ?? "", isNewWeek: cand.isNewWeek,
                           examTerm: r["exam_term"]?.string, points: r["points"]?.double, difficulty: r["difficulty"]?.int,
                           text: short(r["text"]?.string ?? "", 1400), solution: short(r["solution_text"]?.string ?? "", 900),
                           fileID: r["file_id"]?.string ?? "", pageFrom: r["page_from"]?.int ?? 0)
        }
        let topic = String(joinedTopics(newSegs.map(\.topic)).unicodeScalars.prefix(160))
        let hash = h(.array(lec.map { .array([.string($0.fileID), i($0.page)]) }), .array(tasks.map(\.taskID).sorted().map(i)),
                     .array(tasks.map { .string($0.text) }))
        let reuse = module?["exam_reuse"].flatMap { LocalModules.truthy(v($0)) ? $0.string : nil } ?? "paraphrase"
        return Context(plan: plan, module: module, lecture: lec, prior: prior, tasks: tasks, missing: missing, topic: topic,
                       excluded: Array(excluded.prefix(50)), n: questions ?? st.questions, examReuse: reuse, materialHash: hash)
    }

    static let system = "Du erstellst Pruefungsaufgaben fuer ein Ingenieur-/Informatikstudium an der Leibniz Universitaet Hannover. Antworte ausschliesslich mit gueltigem JSON ohne Markdown-Zaeune. Formeln als Text."

    /// `str(x)` wie Python fuer Zahlen in Texten (`(3.0 P.)`, `Aufgabe 2`)
    static func pyStr(_ v: PyJSON?) -> String {
        switch v {
        case .none, .some(.null): return "None"
        case .some(.bool(let b)): return b ? "True" : "False"
        case .some(.int(let s)): return s
        case .some(.float(let d)): return PyJSON.repr(d)
        case .some(.string(let s)): return s
        case .some(let x): return x.dumps(ensureASCII: false)
        }
    }

    /// `_materials_block(ctx)`
    static func materialsBlock(_ ctx: Context) -> String {
        var lines = ["NEUER STOFF DIESER WOCHE (nur bis zum Seitenmarker):"]
        lines += ctx.lecture.filter(\.new).map { "[\($0.id)] Seite \($0.page): \($0.text)" }
        if !ctx.prior.isEmpty {
            lines += ["", "VORWISSEN (frueher behandelt, darf vorausgesetzt werden):"]
            lines += ctx.prior.map { "[\($0.id)] \($0.text)" }
        }
        if !ctx.tasks.isEmpty {
            lines += ["", "PASSENDE UEBUNGS- UND KLAUSURAUFGABEN (bereits geprueft: nur behandelter Stoff):"]
            for t in ctx.tasks {
                var l = "[\(t.id)] \(sourceText[t.source] ?? t.source)"
                if let e = t.examTerm, !e.isEmpty { l += " " + e }
                if let p = t.points, p != 0 { l += " (" + PyJSON.repr(p) + " P.)" }
                l += ": " + t.text
                if !t.solution.isEmpty { l += "\n    Musterloesung: " + t.solution }
                lines.append(l)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func examIDs(_ ctx: Context) -> [String] { ctx.tasks.filter { $0.source == "altklausur" }.map(\.id) }

    /// `_rule_lines(ctx, kind, ex, reuse)`: Regel des Inhabers 4/6/5 fuer den Wochentest mit 15 Aufgaben
    static func ruleLines(_ ctx: Context, kind: String, ex: [String], reuse: String) -> String {
        let n = ctx.n
        if kind == "WOCHENTEST", n == AIPromptTexts.weekTestTotal {
            let lines = "- Genau 4 leichte (level \"leicht\"), genau 6 mittlere (level \"mittel\") und genau 5 schwere Aufgaben (level \"schwer\", klausurnah)."
            let exam = ex.isEmpty ? "- Es gibt keine passenden Altklausuraufgaben: nur neue Uebungsaufgaben (from_exam immer null)."
                : "- Genau EINE der 5 schweren Aufgaben ist an eine dieser Altklausuraufgaben angelehnt: \(ex.joined(separator: ", ")) (from_exam setzen, sie zaehlt zu den \(n) Aufgaben). \(reuse)"
            return lines + "\n" + exam
        }
        let easy = max(1, pyRound(Double(n) / 3))
        let lines = "- Etwa \(easy) leichte Grundlagenaufgaben (level \"leicht\"), der Rest mittel bis anspruchsvoll (level \"mittel\" oder \"schwer\")."
        let exam = ex.isEmpty ? "- Es gibt keine passenden Altklausuraufgaben: nur neue Uebungsaufgaben."
            : "- Baue 1–2 der Altklausuraufgaben \(ex.joined(separator: ", ")) ein (sie zaehlen zu den \(n) Aufgaben). \(reuse)"
        return lines + "\n" + exam
    }

    /// `round(x)` wie Python (Banker's Rounding)
    static func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

    /// `_gen_prompt(ctx, kind, extra)`
    static func genPrompt(_ ctx: Context, kind: String = "WOCHENTEST", extra: String = "") -> String {
        let reuse = ctx.examReuse == "original" ? "Altklausuraufgaben duerfen woertlich uebernommen werden (Quelle angeben)."
            : "Altklausuraufgaben NICHT woertlich uebernehmen: erstelle thematisch vergleichbare NEUE Aufgaben im gleichen Stil (andere Zahlen, anderer Kontext) und gib die Altklausur als Quelle an."
        let week = pyStr(ctx.plan["week_no"].map(PyJSON.init))
        return """
            ### AUFTRAG: \(kind)
            Modul: \(ctx.moduleName) · Lehrwoche \(week)\(ctx.topic.isEmpty ? "" : " · Thema: " + ctx.topic)

            Erstelle GENAU \(ctx.n) Aufgaben:
            \(ruleLines(ctx, kind: kind, ex: examIDs(ctx), reuse: reuse))
            - Decke ALLE neuen Themen dieser Woche ausgewogen ab. Jede Aufgabe muss NUR mit dem Material unten loesbar sein.
            - NIEMALS Inhalte abfragen, die nicht im Material stehen (spaetere Kapitel sind noch nicht behandelt).
            - Die Aufgabenstellung darf die Loesung nicht verraten.
            - Jede Aufgabe: eindeutige Stellung, Thema, Schwierigkeit 1-5, ueberpruefte Musterloesung, nachvollziehbarer Loesungsweg, Bewertungskriterien mit Teilpunkten.
            - "refs": IDs des Materials (z. B. "L3", "A2"), auf dem die Aufgabe beruht. Nur IDs aus der Liste unten.
            - Punkte gesamt = 100.
            \(extra)
            \(materialsBlock(ctx))

            Antworte als JSON:
            {"title": "kurzer Titel", "questions": [{"nr": 1, "level": "leicht"|"mittel"|"schwer", "type": "mc"|"short"|"calc",
              "topic": "...", "difficulty": 1-5, "question": "...", "options": ["A ...","B ...","C ...","D ..."] (nur mc),
              "answer": "Musterloesung (bei mc die exakte Option)", "steps": ["Schritt 1", "..."],
              "rubric": [{"criterion": "...", "points": Zahl}], "points": Zahl, "refs": ["L1","A2"],
              "from_exam": "A-ID oder null", "exam_mode": "original"|"angelehnt"|null}]}
            """
    }

    /// `_review_prompt(ctx, qs)`
    static func reviewPrompt(_ ctx: Context, _ qs: [PyJSON]) -> String {
        """
        ### AUFTRAG: PRUEFUNG
        Du bist Fachpruefer. Pruefe jede Aufgabe streng:
        1. Ist sie allein mit dem angegebenen Material loesbar (kein Stoff spaeterer Kapitel)?
        2. Ist die Musterloesung fachlich korrekt und vollstaendig, der Loesungsweg nachvollziehbar?
        3. Ist die Aufgabenstellung eindeutig und verraet sie die Loesung nicht?
        Rechne Rechenaufgaben selbst nach.

        \(materialsBlock(ctx))

        AUFGABEN:
        \(PyJSON.array(qs).dumps(ensureASCII: false))

        Antworte als JSON: {"results": [{"nr": 1, "ok": true|false, "solvable": true|false, "solution_correct": true|false, "issue": "..."}]}
        """
    }

    /// `_sim(a, b)`: Token-Jaccard
    static func sim(_ a: String, _ b: String) -> Double {
        let ta = Set(ScriptSearch.tokens(a)), tb = Set(ScriptSearch.tokens(b))
        return Double(ta.intersection(tb).count) / Double(max(1, ta.union(tb).count))
    }

    static func field(_ q: PyJSON, _ k: String) -> PyJSON? {
        if case .object(let m) = q { return m.first { $0.key == k }?.value }
        return nil
    }

    static func truthy(_ v: PyJSON?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.int(let s)): return s != "0"
        case .some(.float(let d)): return d != 0
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array(let a)): return !a.isEmpty
        case .some(.object(let m)): return !m.isEmpty
        }
    }

    /// `repr(list_of_str)` fuer Meldungen (`['L999']`)
    static func reprList(_ xs: [PyJSON]) -> String {
        "[" + xs.map { x -> String in
            if case .string(let s) = x { return s.contains("'") && !s.contains("\"") ? "\"\(s)\"" : "'\(s)'" }
            return pyStr(x)
        }.joined(separator: ", ") + "]"
    }

    /// `validate(ctx, qs, kind)`: feste Regeln, unabhaengig von der KI; leer = bestanden
    static func validate(_ ctx: Context, _ qsRaw: PyJSON?, kind: String = "wochentest") -> [String] {
        var probs: [String] = []
        let allowed = Set(ctx.lecture.map(\.id) + ctx.prior.map(\.id) + ctx.tasks.map(\.id))
        let newIDs = Set(ctx.lecture.filter(\.new).map(\.id) + ctx.tasks.filter(\.isNewWeek).map(\.id))
        let exam = Set(examIDs(ctx))
        let tasks = Dictionary(uniqueKeysWithValues: ctx.tasks.map { ($0.id, $0) })
        guard case .array(let qs)? = qsRaw, !qs.isEmpty else { return ["keine Aufgaben"] }
        let n = ctx.n
        if ["wochentest", "probeklausur"].contains(kind), qs.count != n { probs.append("\(qs.count) statt \(n) Aufgaben") }
        func level(_ q: PyJSON) -> String? {
            let l = field(q, "level")
            if case .string(let s)? = l { return s == "kurz" ? "leicht" : s }
            return nil
        }
        let fromExam = qs.filter { truthy(field($0, "from_exam")) }
        if kind == "wochentest", n == AIPromptTexts.weekTestTotal {
            let counts = ["leicht", "mittel", "schwer"].map { k in qs.filter { level($0) == k }.count }
            if counts != [4, 6, 5] {
                probs.append("Verteilung \(counts[0]) leicht, \(counts[1]) mittel, \(counts[2]) schwer statt 4 leicht, 6 mittel, 5 schwer")
            }
            if !exam.isEmpty, fromExam.count != 1 || level(fromExam[0]) != "schwer" {
                probs.append("\(fromExam.count) Altklausuraufgaben (erwartet genau eine schwere)")
            }
            if exam.isEmpty, !fromExam.isEmpty { probs.append("Altklausuraufgabe angegeben, obwohl keine passende vorhanden ist") }
        } else if kind == "wochentest", n >= 15 {
            if !exam.isEmpty, !(1...2).contains(fromExam.count) { probs.append("\(fromExam.count) Altklausuraufgaben (erwartet 1–2)") }
        }
        var hitNew = 0
        for (i, q) in qs.enumerated() {
            let nr = pyStr(field(q, "nr") ?? .int(String(i + 1)))
            for f in ["question", "answer", "topic"] where PyText.strip(truthy(field(q, f)) ? pyStr(field(q, f)) : "").isEmpty {
                probs.append("Aufgabe \(nr): Feld '\(f)' fehlt")
            }
            if !truthy(field(q, "steps")) { probs.append("Aufgabe \(nr): Lösungsweg fehlt") }
            switch number(field(q, "points"), integer: false) {
            case .some(let p): if p <= 0 { probs.append("Aufgabe \(nr): keine Punkte") }
            case .none: probs.append("Aufgabe \(nr): Punkte ungültig")
            }
            switch number(field(q, "difficulty"), integer: true) {
            case .some(let d): if !(1...5).contains(Int(d)) { probs.append("Aufgabe \(nr): Schwierigkeit fehlt") }
            case .none: probs.append("Aufgabe \(nr): Schwierigkeit ungültig")
            }
            let refs: [PyJSON] = truthy(field(q, "refs")) ? (field(q, "refs").flatMap { if case .array(let a) = $0 { return a } else { return nil } } ?? []) : []
            if refs.isEmpty { probs.append("Aufgabe \(nr): kein Themenbezug (refs)") }
            let bad = refs.filter { if case .string(let s) = $0 { return !allowed.contains(s) } else { return true } }
            if !bad.isEmpty { probs.append("Aufgabe \(nr): Bezug auf nicht freigegebenes Material \(reprList(bad))") }
            if refs.contains(where: { if case .string(let s) = $0 { return newIDs.contains(s) } else { return false } }) { hitNew += 1 }
            if case .string("mc")? = field(q, "type") {
                let opts: [PyJSON] = truthy(field(q, "options")) ? (field(q, "options").flatMap { if case .array(let a) = $0 { return a } else { return nil } } ?? []) : []
                if opts.count < 3 || !opts.contains(field(q, "answer") ?? .null) { probs.append("Aufgabe \(nr): Multiple-Choice-Optionen/Lösung passen nicht") }
            } else {
                let a = norm(truthy(field(q, "answer")) ? pyStr(field(q, "answer")) : "")
                if len(a) >= 8, norm(truthy(field(q, "question")) ? pyStr(field(q, "question")) : "").contains(a) {
                    probs.append("Aufgabe \(nr): Lösung steht in der Aufgabenstellung")
                }
            }
            let fe = field(q, "from_exam")
            if truthy(fe) {
                let id = pyStr(fe)
                if case .string(let s)? = fe, exam.contains(s) {
                    if ctx.examReuse != "original", sim(pyStr(field(q, "question") ?? .string("")), tasks[s]?.text ?? "") > 0.6 {
                        probs.append("Aufgabe \(nr): zu nah an der Original-Altklausur (Nutzungsrechte: nur angelehnte Aufgabe erlaubt)")
                    }
                } else {
                    probs.append("Aufgabe \(nr): from_exam \(id) ist keine freigegebene Altklausuraufgabe")
                }
            }
        }
        if kind == "wochentest", !ctx.lecture.isEmpty, hitNew < max(1, Int(0.6 * Double(qs.count))) {
            probs.append("nur \(hitNew) Aufgaben behandeln den neuen Stoff dieser Woche")
        }
        if kind == "wochentest" {
            let newFiles = Set(ctx.lecture.filter(\.new).map(\.fileID))
            var used = Set<String>()
            for q in qs {
                guard case .array(let rs)? = field(q, "refs") else { continue }
                for r in rs { if case .string(let s) = r, let x = ctx.lecture.first(where: { $0.id == s }) { used.insert(x.fileID) } }
            }
            for fid in newFiles.subtracting(used).sorted() { probs.append("neuer Stoff aus Dokument \(fid) wird von keiner Aufgabe abgedeckt") }
        }
        return probs
    }

    /// `float(x or 0)` bzw. `int(x or 0)` wie Python; nil bei TypeError/ValueError
    static func number(_ v: PyJSON?, integer: Bool) -> Double? {
        switch v {
        case .none, .some(.null): return 0
        case .some(.bool(let b)): return b ? 1 : 0
        case .some(.int(let s)): return Double(s)
        case .some(.float(let d)): return integer ? d.rounded(.towardZero) : d
        case .some(.string(let s)):
            if s.isEmpty { return 0 }
            return integer ? PyConvert.int(s).map(Double.init) : PyConvert.float(s)
        case .some(.array(let a)): return a.isEmpty ? 0 : nil
        case .some(.object(let m)): return m.isEmpty ? 0 : nil
        }
    }
}

// MARK: - KI-Erzeugung, Speichern, Veroeffentlichen

extension Weekly {
    static func ask(_ ctx: LocalContext, _ prompt: String) async throws -> PyJSON {
        guard let ai = ctx.ai.provider else { throw Failure("Keine KI verbunden (Einstellungen → Erweitert → KI über mein ChatGPT).") }
        return try AIAnswers.parseJSON(try await ai.answer(system: system, prompt: prompt))
    }

    static func set(_ q: PyJSON, _ k: String, _ value: PyJSON) -> PyJSON {
        guard case .object(var m) = q else { return q }
        if let i = m.firstIndex(where: { $0.key == k }) { m[i].value = value } else { m.append(.init(k, value)) }
        return .object(m)
    }

    static func questions(of res: PyJSON) -> PyJSON? { field(res, "questions") }

    static func rejected(_ rv: PyJSON) -> [PyJSON] {
        guard case .array(let rs)? = field(rv, "results") else { return [] }
        return rs.filter { r in
            !(truthy(field(r, "ok")) && (field(r, "solvable").map(truthy) ?? true) && (field(r, "solution_correct").map(truthy) ?? true))
        }
    }

    /// `_run_ai_pipeline(ctx, kind_tag, kind)`: Entwurf -> Regeln -> Fachpruefung -> hoechstens eine Reparatur
    static func runPipeline(_ app: LocalContext, _ ctx: Context, tag: String, kind: String) async throws -> (PyJSON, PyJSON) {
        var rounds: [PyJSON] = []
        var res: PyJSON
        do { res = try await ask(app, genPrompt(ctx, kind: tag)) } catch { throw Failure("KI-Entwurf unbrauchbar: \(error)") }
        var qs = questions(of: res)
        for rnd in 0..<2 {
            let probs = validate(ctx, qs, kind: kind)
            var review: [PyJSON] = []
            if probs.isEmpty, case .array(let list)? = qs {
                do {
                    let rv = try await ask(app, reviewPrompt(ctx, list))
                    review = rejected(rv)
                    let n = { () -> Int in if case .array(let a)? = field(rv, "results") { return a.count } else { return 0 } }()
                    if n < list.count { review.append(.object([.init("nr", .null), .init("issue", .string("Fachprüfung unvollständig"))])) }
                } catch {
                    review = [.object([.init("nr", .null), .init("issue", .string("Fachprüfung fehlgeschlagen: \(error)"))])]
                }
            }
            rounds.append(.object([.init("rules", .array(probs.map(PyJSON.string))), .init("review", .array(review))]))
            if probs.isEmpty, review.isEmpty {
                return (set(res, "questions", qs ?? .array([])), .object([.init("rounds", .array(rounds)), .init("passed", .bool(true))]))
            }
            if rnd == 1 { break }
            let fix = (probs + review.map { "Aufgabe \(pyStr(field($0, "nr"))): \(pyStr(field($0, "issue")))" }).joined(separator: "\n")
            do {
                res = try await ask(app, genPrompt(ctx, kind: tag, extra: "\nKORREKTUR NOETIG. Behebe diese Probleme vollstaendig:\n\(fix)\n"))
                qs = questions(of: res)
            } catch {
                rounds.append(.object([.init("rules", .array([.string("Reparatur unbrauchbar: \(error)")])), .init("review", .array([]))]))
                break
            }
        }
        let last = rounds.last
        let rules: [String] = { if case .array(let a)? = last.flatMap({ field($0, "rules") }) { return a.map { pyStr($0) } } else { return [] } }()
        let rev: [String] = { if case .array(let a)? = last.flatMap({ field($0, "review") }) { return a.map { pyStr(field($0, "issue")) } } else { return [] } }()
        throw Failure("Test nicht freigegeben (Prüfung nicht bestanden): " + (rules + rev).prefix(6).joined(separator: "; "))
    }

    /// `_sources_of(ctx, qs)`: Quellen je Aufgabe, verwendete Materialien, ausgeschlossene Aufgaben
    static func sourcesOf(_ ctx: Context, _ qs: [PyJSON]) -> PyJSON {
        let lec = Dictionary(uniqueKeysWithValues: (ctx.lecture + ctx.prior).map { ($0.id, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: ctx.tasks.map { ($0.id, $0) })
        var perQ: [PyJSON] = []
        var used = Set<[String]>()
        for q in qs {
            var r: [PyJSON] = []
            let refs: [String] = { if case .array(let a)? = field(q, "refs"), truthy(field(q, "refs")) { return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } } } else { return [] } }()
            for ref in refs {
                if let l = lec[ref] {
                    r.append(.object([.init("type", .string("vorlesung")), .init("file_id", .string(l.fileID)), .init("page", i(l.page)), .init("new", .bool(l.new))]))
                } else if let t = tasks[ref] {
                    r.append(.object([.init("type", .string(t.source)), .init("task_id", i(t.taskID)), .init("file_id", .string(t.fileID)),
                                      .init("label", .string(t.label)), .init("page", i(t.pageFrom))]))
                }
            }
            let fe: String? = { if case .string(let s)? = field(q, "from_exam") { return s } else { return nil } }()
            perQ.append(.object([.init("nr", field(q, "nr") ?? .null), .init("refs", .array(r)),
                                 .init("from_exam", fe.flatMap { tasks[$0] }.map { i($0.taskID) } ?? .null)]))
            for t in ctx.tasks where refs.contains(t.id) || fe == t.id { used.insert([sourceText[t.source] ?? t.source, t.label]) }
        }
        let usedSorted = used.sorted { a, b in a[0] != b[0] ? a[0].unicodeScalars.lexicographicallyPrecedes(b[0].unicodeScalars)
                                                            : a[1].unicodeScalars.lexicographicallyPrecedes(b[1].unicodeScalars) }
        return .object([
            .init("per_question", .array(perQ)), .init("candidates", .array(ctx.tasks.map { i($0.taskID) })),
            .init("lecture_pages", .array(ctx.lecture.map { .array([.string($0.fileID), i($0.page)]) })),
            .init("missing", .array(ctx.missing.map(PyJSON.string))), .init("excluded", .array(ctx.excluded)),
            .init("exam_candidates", i(examIDs(ctx).count)), .init("used", .array(usedSorted.map { .array($0.map(PyJSON.string)) })),
        ])
    }

    /// `_store_def(ctx, res, qa, kind, now, parent_id)`
    static func storeDef(_ c: SQLiteConnection, _ ctx: Context, _ res: PyJSON, _ qa: PyJSON, kind: String, now: Int,
                         parent: Int64? = nil) throws -> [String: JSONValue] {
        let plan = ctx.plan
        var qs: [PyJSON] = { if case .array(let a)? = field(res, "questions") { return a } else { return [] } }()
        qs = qs.enumerated().map { set($0.element, "nr", i($0.offset + 1)) }
        let mid = v(plan["module_id"]), key = v(plan["scope_key"])
        if let ex = try c.rows("SELECT * FROM wt_defs WHERE kind=? AND module_id=? AND scope_key=? AND material_hash=?",
                               [.text(kind), mid, key, .text(ctx.materialHash)]).first { return ex }
        let ver = (try c.scalar("SELECT MAX(version) AS v FROM wt_defs WHERE module_id=? AND scope_key=?", [mid, key])?.int ?? 0) + 1
        let title = truthy(field(res, "title")) ? pyStr(field(res, "title")) : (kind == "wochentest" ? "Wochentest" : "Nachtrag")
        let modMin = ctx.module?["test_minutes"].flatMap { LocalModules.truthy(v($0)) ? $0.int : nil }
        let fallback = kind == "probeklausur" ? 90 : kind == "wochentest" ? 60 : 20
        let dur = truthy(field(res, "duration_min")) ? Int(number(field(res, "duration_min"), integer: true) ?? Double(fallback)) : (modMin ?? fallback)
        try c.execute("""
            INSERT INTO wt_defs(kind, plan_id, parent_id, module_id, week_no, scope_key, material_hash, version, title, topic, duration_min,
            questions, sources, coverage, qa, status, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(kind), v(plan["id"]), parent.map { .integer($0) } ?? .null, mid, v(plan["week_no"]), key, .text(ctx.materialHash),
                  .integer(Int64(ver)), .text(title), .text(ctx.topic), .integer(Int64(dur)), .text(PyJSON.array(qs).dumps(ensureASCII: false)),
                  .text(sourcesOf(ctx, qs).dumps(ensureASCII: false)), v(plan["coverage"]), .text(qa.dumps(ensureASCII: false)),
                  .text("geprueft"), .text(iso(now))])
        return try c.rows("SELECT * FROM wt_defs WHERE id=?", [.integer(c.lastInsertRowID)]).first ?? [:]
    }

    /// `generate_weekly(ctx, now)`
    static func generateWeekly(_ app: LocalContext, _ ctx: Context, now: Int) async throws -> [String: JSONValue] {
        if ctx.lecture.isEmpty { throw Failure("Kein Text auf den markierten Vorlesungsseiten – Test kann nicht sicher erzeugt werden.") }
        return try await WeeklyGate.shared.run {
            let mid = v(ctx.plan["module_id"]), key = v(ctx.plan["scope_key"])
            if let ex = try await app.database.withConnection({ c in
                try c.rows("SELECT * FROM wt_defs WHERE kind='wochentest' AND module_id=? AND scope_key=? AND status IN ('geprueft','veroeffentlicht')", [mid, key]).first
            }) { return ex }
            let (res, qa) = try await runPipeline(app, ctx, tag: "WOCHENTEST", kind: "wochentest")
            return try await app.database.transaction { c in try storeDef(c, ctx, res, qa, kind: "wochentest", now: now) }
        }
    }

    /// `publish(conn, plan_id, def_id, now)`
    static func publish(_ c: SQLiteConnection, _ planID: Int64, _ defID: Int64, now: Int, nowISO: String) throws {
        guard let d = try c.rows("SELECT * FROM wt_defs WHERE id=?", [.integer(defID)]).first,
              ["geprueft", "veroeffentlicht"].contains(d["status"]?.string ?? "") else { throw Failure("Nur geprüfte Testversionen dürfen veröffentlicht werden.") }
        let qa = (try? JSONValue.parse(d["qa"]?.string ?? "{}")) ?? .object([:])
        guard qa["passed"]?.bool == true else { throw Failure("Prüfprotokoll fehlt – keine Veröffentlichung.") }
        if d["status"]?.string != "veroeffentlicht" {
            try c.execute("UPDATE wt_defs SET status='veroeffentlicht', published_at=? WHERE id=?", [.text(iso(now)), .integer(defID)])
        }
        try c.execute("UPDATE wt_plans SET status='veroeffentlicht', def_id=?, last_error=NULL WHERE id=?", [.integer(defID), .integer(planID)])
        let plan = try c.rows("SELECT * FROM wt_plans WHERE id=?", [.integer(planID)]).first ?? [:]
        let user = plan["user_id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? localUser
        _ = try attemptFor(c, defID, user: user, nowISO: nowISO)
        if d["kind"]?.string == "wochentest" {
            let tid = try c.scalar("SELECT id FROM tests WHERE def_id=? AND user_id=?", [.integer(defID), .text(user)]) ?? .null
            try c.execute("""
                UPDATE study_tasks SET test_id=? WHERE test_id IS NULL AND type='test' AND package_id IN
                (SELECT id FROM study_packages WHERE module_id=? AND week_no=?)
                """, [tid, v(plan["module_id"]), v(plan["week_no"])])
        }
    }

    /// `attempt_for(conn, def_id, user_id)`: Bearbeitungsversuch (Kopie der unveraenderlichen Testversion in `tests`)
    /// `task_test(conn, module_id, week_no)`: Testaufgabe des Lernplans ("Gemeinsamer Wochentest Lehrwoche N") in
    /// einem Fach mit Markern: der Versuch am veroeffentlichten gemeinsamen Wochentest dieser Lehrwoche (erster Teil),
    /// statt daneben einen klassischen Test zu erzeugen. nil = Fach ohne Marker (klassischer Wochentest). Vorher
    /// `Failure` mit dem Grund (noch nicht veroeffentlicht, wird geplant, kein Stoff markiert).
    static func taskTest(_ c: SQLiteConnection, moduleID: SQLiteValue, weekNo: SQLiteValue, user: String = localUser, nowISO: String) throws -> Int? {
        guard try c.queryOne("SELECT 1 FROM lecture_markers WHERE module_id=? AND deleted_at IS NULL", [moduleID]) != nil else { return nil }
        let mine = "module_id=? AND week_no=? AND (user_id=? OR scope='course')"
        let args: [SQLiteValue] = [moduleID, weekNo, .text(user)]
        if let d = try c.queryOne("SELECT def_id FROM wt_plans WHERE \(mine) AND status='veroeffentlicht' AND def_id IS NOT NULL ORDER BY part, id LIMIT 1", args)?["def_id"]?.int64 {
            return try attemptFor(c, d, user: user, nowISO: nowISO)
        }
        let week = weekNo.int.map(String.init) ?? pyStr(weekNo.json.map(PyJSON.init))
        if let at = try c.queryOne("SELECT publish_at FROM wt_plans WHERE \(mine) AND status IN ('geplant','wartet','fehlgeschlagen') ORDER BY part, id LIMIT 1",
                                   args)?["publish_at"]?.string {
            let ch = Array(at)
            let day = ch.count >= 16 ? "\(String(ch[8..<10])).\(String(ch[5..<7]))." : at, time = ch.count >= 16 ? String(ch[11..<16]) : ""
            throw Failure("Der gemeinsame Wochentest der Lehrwoche \(week) erscheint voraussichtlich am \(day) um \(time) Uhr.")
        }
        if try c.queryOne("SELECT 1 FROM lecture_markers WHERE module_id=? AND week_no=? AND deleted_at IS NULL", [moduleID, weekNo]) != nil {
            throw Failure("Der gemeinsame Wochentest der Lehrwoche \(week) wird gerade geplant. Bitte später erneut versuchen.")
        }
        throw Failure("Für die Lehrwoche \(week) ist noch kein Vorlesungsstoff markiert („Vorlesung bis hier“ im Skript setzen).")
    }

    static func attemptFor(_ c: SQLiteConnection, _ defID: Int64, user: String = localUser, nowISO: String) throws -> Int {
        if let ex = try c.scalar("SELECT id FROM tests WHERE def_id=? AND user_id=?", [.integer(defID), .text(user)])?.int { return ex }
        guard let d = try c.rows("SELECT * FROM wt_defs WHERE id=?", [.integer(defID)]).first, d["status"]?.string == "veroeffentlicht" else {
            throw Failure("Testversion ist nicht veröffentlicht.")
        }
        let name = try c.scalar("SELECT name FROM modules WHERE id=?", [v(d["module_id"])])?.string
        let week = pyStr(d["week_no"].map(PyJSON.init))
        let label = ["wochentest": "Lehrwoche \(week): ", "nachtrag": "Nachtrag Lehrwoche \(week): ", "probeklausur": "Probeklausur: "][d["kind"]?.string ?? ""] ?? ""
        try c.execute("""
            INSERT INTO tests(subject, week_start, title, duration_min, questions, created_at, module_id, week_no, auto, def_id, user_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(name.flatMap { $0.isEmpty ? nil : $0 } ?? "Modul"), .null, .text(label + (d["title"]?.string ?? "")), v(d["duration_min"]),
                  v(d["questions"]), .text(nowISO), v(d["module_id"]),
                  d["kind"]?.string != "probeklausur" ? v(d["week_no"]) : .null, .integer(0), .integer(defID), .text(user)])
        return Int(c.lastInsertRowID)
    }

    /// `grade_consistent(questions, answers, ai_result)`: Multiple Choice fuer alle gleich und ohne KI, KI-Punkte begrenzt
    static func gradeConsistent(_ questions: [PyJSON], _ answers: [PyJSON.Member], _ aiResult: PyJSON) -> PyJSON {
        var per: [String: PyJSON] = [:]
        if case .array(let a)? = field(aiResult, "per_question") { for p in a { per[pyStr(field(p, "nr"))] = p } }
        var out: [PyJSON] = [], total = 0.0, maxSum = 0.0
        for q in questions {
            let nr = pyStr(field(q, "nr"))
            let mx = number(field(q, "points"), integer: false) ?? 0
            var p = per[nr] ?? .object([.init("nr", field(q, "nr") ?? .null), .init("feedback", .string(""))])
            var pts: Double
            if case .string("mc")? = field(q, "type") {
                let given = answers.last { $0.key == nr }.map { pyStr($0.value) } ?? ""
                let right = PyText.strip(given) == PyText.strip(pyStr(field(q, "answer") ?? .string("")))
                pts = right ? mx : 0
                p = set(p, "points", .float(pts))
                p = set(p, "feedback", truthy(field(p, "feedback")) ? field(p, "feedback")! : .string(right ? "richtig" : "falsch"))
            } else {
                pts = max(0, min(mx, number(field(p, "points"), integer: false) ?? 0))
                p = set(p, "points", .float(pts))
            }
            p = set(p, "max", .float(mx))
            total += pts; maxSum += mx
            out.append(p)
        }
        var r = set(aiResult, "per_question", .array(out))
        r = set(r, "total", .float(round2(total)))
        r = set(r, "max", .float(round2(maxSum)))
        return r
    }

    /// `ranking(conn, def_id)`
    static func ranking(_ c: SQLiteConnection, _ defID: Int64) throws -> [JSONValue] {
        guard try c.queryOne("SELECT kind FROM wt_defs WHERE id=?", [.integer(defID)]) != nil else { return [] }
        return try c.rows("""
            SELECT user_id, score, max_score, duration_sec, submitted_at FROM tests
            WHERE def_id=? AND submitted_at IS NOT NULL ORDER BY score DESC, COALESCE(duration_sec, 1e9) ASC, submitted_at ASC
            """, [.integer(defID)]).enumerated().map { i, r in
            var r = r
            r["rank"] = .number(Double(i + 1))
            let mx = r["max_score"]?.double ?? 0
            r["percent"] = mx != 0 ? .number(Double(pyRound(100 * (r["score"]?.double ?? 0) / mx))) : .null
            return .object(r)
        }
    }

    /// `module_ranking(conn, module_id, week_no)`: nur Original-Wochentests, nie Nachtraege
    static func moduleRanking(_ c: SQLiteConnection, _ moduleID: Int, week: Int?) throws -> [JSONValue] {
        var sql = """
            SELECT t.user_id, SUM(t.score) AS score, SUM(t.max_score) AS max_score, SUM(COALESCE(t.duration_sec,0)) AS duration_sec, COUNT(*) AS tests
            FROM tests t JOIN wt_defs d ON d.id=t.def_id WHERE d.kind='wochentest' AND d.module_id=? AND t.submitted_at IS NOT NULL
            """
        var p: [SQLiteValue] = [.integer(Int64(moduleID))]
        if let week { sql += " AND d.week_no=?"; p.append(.integer(Int64(week))) }
        return try c.rows(sql + " GROUP BY t.user_id ORDER BY score DESC, duration_sec ASC", p).enumerated().map { i, r in
            var r = r
            r["rank"] = .number(Double(i + 1))
            return .object(r)
        }
    }
}
