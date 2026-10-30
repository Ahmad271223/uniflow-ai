import Foundation

// Nachtraege, Probeklausur, Uebersicht und Testdetails wie app/weekly.py
extension Weekly {
    /// `offer_nachtrag(plan_id, now)`: neue passende Aufgaben nach der Veroeffentlichung als gemeinsamer Nachtrag
    static func offerNachtrag(_ app: LocalContext, _ planID: Int64, now: Int, indexes: inout [Int: ScriptSearch.Index]) async throws -> JSONValue? {
        guard let plan = try await app.database.withConnection({ c in try c.rows("SELECT * FROM wt_plans WHERE id=?", [.integer(planID)]).first }),
              let defID = plan["def_id"]?.weeklyInt64 else { return nil }
        let moduleID = plan["module_id"]?.int ?? 0
        let idx = try await index(moduleID, app, &indexes)
        let prepared: (Context, [String: JSONValue], Int)? = try await app.database.withConnection { c in
            guard let base = try c.rows("SELECT * FROM wt_defs WHERE id=?", [.integer(defID)]).first else { return nil }
            let covj = (try? JSONValue.parse(plan["coverage"]?.string ?? "")) ?? .object([:])
            let newPages = pages(covj["new"]?.array ?? [])
            let covered = newPages.union(pages(covj["prior"]?.array ?? []))
            let cands = try candidates(c, moduleID, index: idx, covered: covered, newPages: newPages)
            var known = Set(((try? JSONValue.parse(base["sources"]?.string ?? "{}"))?["candidates"]?.array ?? []).compactMap(\.int))
            for n in try c.rows("SELECT sources FROM wt_defs WHERE parent_id=? AND kind='nachtrag'", [.integer(defID)]) {
                known.formUnion(((try? JSONValue.parse(n["sources"]?.string ?? "{}"))?["candidates"]?.array ?? []).compactMap(\.int))
            }
            let published = base["published_at"]?.string ?? ""
            let fresh = cands.ok.filter { !known.contains($0.id) && $0.isNewWeek && ($0.row["indexed_at"]?.string ?? "") > published }
            if fresh.isEmpty { return nil }
            var ctx = try buildContext(c, plan: plan, ok: fresh, excluded: [], missing: [], questions: min(5, max(2, fresh.count)))
            ctx.materialHash = h(.string("nachtrag"), i(Int(defID)), .array(fresh.map(\.id).sorted().map(i)))
            return (ctx, base, fresh.count)
        }
        guard let (ctx, base, freshCount) = prepared else { return nil }
        let stored: ([String: JSONValue], Int)? = try await WeeklyGate.shared.run {
            if try await app.database.withConnection({ c in
                try c.queryOne("SELECT 1 FROM wt_defs WHERE kind='nachtrag' AND module_id=? AND scope_key=? AND material_hash=?",
                               [v(plan["module_id"]), v(plan["scope_key"]), .text(ctx.materialHash)]) != nil
            }) { return nil }
            let (res, qa) = try await runPipeline(app, ctx, tag: "NACHTRAG", kind: "nachtrag")
            let d = try await app.database.transaction { c in try storeDef(c, ctx, res, qa, kind: "nachtrag", now: now, parent: defID) }
            let n: Int = { if case .array(let a)? = field(res, "questions") { return a.count } else { return 0 } }()
            return (d, n)
        }
        guard let (d, _) = stored else { return nil }
        let id = Int64(d["id"]?.int ?? 0)
        try await app.database.transaction { c in
            if d["status"]?.string != "veroeffentlicht" {
                try c.execute("UPDATE wt_defs SET status='veroeffentlicht', published_at=? WHERE id=?", [.text(iso(now)), .integer(id)])
            }
            _ = try attemptFor(c, id, user: plan["user_id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? localUser, nowISO: app.clock.nowISO)
        }
        return ["plan_id": .number(Double(planID)), "def_id": .number(Double(id)), "parent_id": base["id"] ?? .null,
                "new_tasks": .number(Double(freshCount))]
    }

    // MARK: Probeklausur

    static let examDuration = PyRegex(#"(?:Bearbeitungszeit|Dauer|Zeit)\s*[:=]?\s*(\d{2,3})\s*(?:Minuten|min)"#, ignoreCase: true)

    struct Blueprint {
        var exams: Int, tasks: Int, points: Int, durationMin: Int
        var py: PyJSON {
            .object([.init("exams", Weekly.i(exams)), .init("tasks", Weekly.i(tasks)), .init("points", Weekly.i(points)),
                     .init("duration_min", Weekly.i(durationMin))])
        }
    }

    /// `exam_blueprint(conn, module_id)`: Aufbau der echten Altklausuren
    static func examBlueprint(_ c: SQLiteConnection, _ moduleID: Int) throws -> Blueprint {
        let rows = try c.rows("SELECT file_id, nr, points, text FROM task_index WHERE module_id=? AND source='altklausur'", [.integer(Int64(moduleID))])
        var order: [String] = [], per: [String: [[String: JSONValue]]] = [:]
        for r in rows {
            let f = r["file_id"]?.string ?? ""
            if per[f] == nil { order.append(f) }
            per[f, default: []].append(r)
        }
        let counts = order.compactMap { f -> Int? in
            let v = per[f]!
            return v.allSatisfy { ($0["nr"]?.string ?? "").hasPrefix("S") } ? nil : v.count
        }
        let pts = order.map { f in per[f]!.reduce(0.0) { $0 + ($1["points"]?.double ?? 0) } }
        var dur: [Int] = []
        for f in order {
            let t = try pageTexts(c, f).prefix(2).joined(separator: " ")
            if let m = examDuration.search(t), let x = m.group(1).flatMap({ Int($0) }) { dur.append(x) }
        }
        func med<T: Comparable>(_ xs: [T], _ d: T) -> T { xs.isEmpty ? d : xs.sorted()[xs.count / 2] }
        return Blueprint(exams: order.count, tasks: max(4, min(10, med(counts, 6))), points: Int(med(pts.filter { $0 != 0 }, 100)),
                         durationMin: med(dur, 90))
    }

    /// `create_mock_exam(module_id, full)`: Probeklausur im Stil der Altklausuren, nur freigegebener Stoff
    static func createMockExam(_ app: LocalContext, moduleID: Int, full: Bool, user: String = localUser, now: Int? = nil) async throws -> JSONValue {
        let now = now ?? Weekly.now(app)
        let idx = try await prepare(moduleID, app)
        enum Prepared { case reused(JSONValue), build(Context, Blueprint) }
        let prepared: Prepared = try await app.database.transaction { c in
            try indexModule(c, moduleID, index: idx, now: now)
            let cov = try coverage(c, moduleID: moduleID, user: user)
            if cov.segments.isEmpty { throw Failure("Noch kein Vorlesungsstoff markiert – Probeklausur nicht möglich.") }
            if full {
                let lec = try LocalModules.fileRows(c, moduleID: .integer(Int64(moduleID))).map(\.json)
                    .filter { lectureTypes.contains($0["doc_type"]?.string ?? "") && isPDF($0) }
                var open: [String] = []
                for f in lec {
                    let fid = f["id"]?.string ?? ""
                    let n = try pageTexts(c, fid).count
                    if !cov.segments.contains(where: { $0.fileID == fid && $0.to >= n }) { open.append(f["name"]?.string ?? "") }
                }
                if !open.isEmpty { throw Failure("Abschlussprobeklausur erst, wenn der gesamte Stoff markiert ist. Noch offen: " + open.prefix(5).joined(separator: ", ")) }
            }
            let bp = try examBlueprint(c, moduleID)
            let key = scopeKey(cov.segments)
            let weeks = Set(cov.segments.compactMap(\.week)).sorted()
            let covText = PyJSON.object([.init("new", .array(cov.segments.map(\.py))), .init("prior", .array([])),
                                         .init("blocked", .array(cov.blocked))]).dumps(ensureASCII: false)
            let plan: [String: JSONValue] = ["id": .null, "module_id": .number(Double(moduleID)), "week_no": weeks.last.map { .number(Double($0)) } ?? .null,
                                             "scope_key": .string(key), "user_id": .string(user), "coverage": .string(covText)]
            let cands = try candidates(c, moduleID, index: idx, covered: cov.pages, newPages: cov.pages)
            var ctx = try buildContext(c, plan: plan, ok: cands.ok, excluded: cands.excluded, missing: [], questions: bp.tasks)
            ctx.topic = String(joinedTopics(cov.segments.map(\.topic)).unicodeScalars.prefix(200))
            ctx.materialHash = h(.string("probe"), .bool(full), .string(ctx.materialHash), bp.py)
            if let ex = try c.rows("""
                SELECT * FROM wt_defs WHERE kind='probeklausur' AND module_id=? AND scope_key=? AND material_hash=? AND status='veroeffentlicht'
                """, [.integer(Int64(moduleID)), .text(key), .text(ctx.materialHash)]).first {
                let tid = try attemptFor(c, Int64(ex["id"]?.int ?? 0), user: user, nowISO: app.clock.nowISO)
                return .reused(["def": .object(ex), "test_id": .number(Double(tid)), "blueprint": bp.py.json, "reused": true])
            }
            return .build(ctx, bp)
        }
        guard case .build(let ctx, let bp) = prepared else {
            if case .reused(let r) = prepared { return r }
            return .null
        }
        var extra = "\nDies ist eine PROBEKLAUSUR (\(full ? "Abschluss" : "Lernstand")). Orientiere dich am Aufbau der echten Klausuren: "
            + "\(bp.tasks) Aufgaben, zusammen \(bp.points) Punkte, Bearbeitungszeit \(bp.durationMin) Minuten. "
            + "Mische Themen aus allen behandelten Wochen. Gib 'duration_min' im JSON an.\n"
        let d: [String: JSONValue] = try await WeeklyGate.shared.run {
            var promptCtx = ctx
            promptCtx.n = bp.tasks
            var rounds: [PyJSON] = [], passed = false
            var res: PyJSON = .null
            for _ in 0..<2 {
                do { res = try await ask(app, genPrompt(promptCtx, kind: "PROBEKLAUSUR", extra: extra)) } catch {
                    rounds.append(.object([.init("rules", .array([.string("KI-Entwurf unbrauchbar: \(error)")])), .init("review", .array([]))]))
                    continue
                }
                let qs = questions(of: res) ?? .array([])
                let probs = validate(promptCtx, truthy(qs) ? qs : .array([]), kind: "probeklausur")
                var review: [PyJSON] = []
                if probs.isEmpty, case .array(let list) = qs {
                    do { review = rejected(try await ask(app, reviewPrompt(promptCtx, list))) } catch {
                        review = [.object([.init("issue", .string("Fachprüfung fehlgeschlagen: \(error)"))])]
                    }
                }
                rounds.append(.object([.init("rules", .array(probs.map(PyJSON.string))), .init("review", .array(review))]))
                if probs.isEmpty, review.isEmpty { passed = true; break }
                extra += "\nKORREKTUR NOETIG: " + (probs + review.map { pyStr(field($0, "issue")) }).joined(separator: "; ")
            }
            if !passed { throw Failure("Probeklausur nicht freigegeben (Prüfung nicht bestanden).") }
            if !truthy(field(res, "duration_min")) { res = set(res, "duration_min", i(bp.durationMin)) }
            let qa = PyJSON.object([.init("rounds", .array(rounds)), .init("passed", .bool(true))])
            return try await app.database.transaction { c in try storeDef(c, promptCtx, res, qa, kind: "probeklausur", now: now) }
        }
        return try await app.database.transaction { c in
            let id = Int64(d["id"]?.int ?? 0)
            if d["status"]?.string != "veroeffentlicht" {
                try c.execute("UPDATE wt_defs SET status='veroeffentlicht', published_at=? WHERE id=?", [.text(iso(now)), .integer(id)])
            }
            let tid = try attemptFor(c, id, user: user, nowISO: app.clock.nowISO)
            let def = try c.rows("SELECT * FROM wt_defs WHERE id=?", [.integer(id)]).first ?? [:]
            return ["def": .object(def), "test_id": .number(Double(tid)), "blueprint": bp.py.json, "reused": false]
        }
    }

    // MARK: Uebersicht fuer die Oberflaeche

    static let statusText = ["geplant": "wird vorbereitet", "wartet": "wartet auf Übungen", "veroeffentlicht": "Test verfügbar",
                             "fehlgeschlagen": "Erstellung fehlgeschlagen", "ersetzt": "ersetzt"]

    static func testRow(_ c: SQLiteConnection, _ defID: JSONValue?, user: String) throws -> JSONValue {
        guard let defID, defID != .null else { return .null }
        return try c.rows("SELECT id, submitted_at, score, max_score FROM tests WHERE def_id=? AND user_id=?", [v(defID), .text(user)]).first
            .map(JSONValue.object) ?? .null
    }

    /// `module_overview(conn, module_id)`: Wochen mit Markern, Plaenen, Tests und Nachtraegen, Probeklausuren, Einstellungen
    static func moduleOverview(_ c: SQLiteConnection, _ moduleID: Int, user: String = localUser, now: Int) throws -> JSONValue {
        let markers = try listMarkers(c, moduleID: moduleID, fileID: nil, user: user)
        let plans = try c.rows("SELECT * FROM wt_plans WHERE module_id=? AND status!='ersetzt' ORDER BY week_no, part", [.integer(Int64(moduleID))])
        var weekOrder: [Int?] = [], weeks: [Int?: (plans: [JSONValue], markers: [JSONValue])] = [:]
        func touch(_ w: Int?) { if weeks[w] == nil { weeks[w] = ([], []); weekOrder.append(w) } }
        for m in markers {
            let w = m["week_no"]?.int
            touch(w)
            var e: [String: JSONValue] = [:]
            for k in ["id", "file_id", "page", "page_range", "topic", "lecture_date", "needs_review", "review_note", "scope"] { e[k] = m[k] ?? .null }
            weeks[w]!.markers.append(.object(e))
        }
        for p in plans {
            let cj = (try? JSONValue.parse(p["coverage"]?.string ?? "")) ?? .object([:])
            let defID = p["def_id"].flatMap { $0 == .null ? nil : $0 }
            let d = try defID.flatMap { try c.rows("SELECT id, title, topic, published_at, questions, sources FROM wt_defs WHERE id=?", [v($0)]).first }
            var nach: [JSONValue] = []
            if let defID {
                for n in try c.rows("SELECT id, title, published_at FROM wt_defs WHERE parent_id=? AND kind='nachtrag' ORDER BY id", [v(defID)]) {
                    var n = n
                    n["test"] = try testRow(c, n["id"], user: user)
                    nach.append(.object(n))
                }
            }
            let newSegs = (cj["new"]?.array ?? []).map(Segment.init)
            let st = p["status"]?.string ?? ""
            let entry: [String: JSONValue] = [
                "id": p["id"] ?? .null, "part": p["part"] ?? .null, "status": .string(st), "status_text": .string(statusText[st] ?? st),
                "publish_at": p["publish_at"] ?? .null, "deadline_at": p["deadline_at"] ?? .null,
                "missing": (try? JSONValue.parse(p["missing"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "[]")) ?? .array([]),
                "error": p["last_error"] ?? .null,
                "pages": .array(newSegs.map { ["file_id": .string($0.fileID), "from": .number(Double($0.from)), "to": .number(Double($0.to))] }),
                "topic": .string(joinedTopics(newSegs.map(\.topic))), "def_id": defID ?? .null, "test": try testRow(c, defID, user: user),
                "nachtraege": .array(nach),
                "question_count": d.flatMap { ($0["questions"]?.string).flatMap { try? JSONValue.parse($0) }?.array.map { .number(Double($0.count)) } } ?? .null,
            ]
            let w = p["week_no"]?.int
            touch(w)
            weeks[w]!.plans.append(.object(entry))
        }
        var out: [JSONValue] = []
        for w in weekOrder.compactMap({ $0 }).sorted() {
            let x = weeks[w]!
            let st = x.plans.last?["status_text"]?.string ?? (x.markers.isEmpty ? "Noch keine Vorlesung markiert" : "Marker gesetzt")
            let planTopic = x.plans.compactMap { $0["topic"]?.string }.first { !$0.isEmpty }
            let topic = planTopic ?? joinedTopics(x.markers.map { $0["topic"]?.string })
            out.append(["week": .number(Double(w)), "status": .string(st), "plans": .array(x.plans), "markers": .array(x.markers), "topic": .string(topic)])
        }
        let cur = try lectureWeek(c, today(now), today: today(now))
        if !out.contains(where: { $0["week"]?.int == cur }) {
            out.append(["week": .number(Double(cur)), "status": "Noch keine Vorlesung markiert", "plans": [], "markers": [], "topic": .null])
        }
        out.sort { ($0["week"]?.int ?? 0) < ($1["week"]?.int ?? 0) }
        var mocks: [JSONValue] = []
        for mk in try c.rows("""
            SELECT id, title, created_at, duration_min FROM wt_defs WHERE module_id=? AND kind='probeklausur' AND status='veroeffentlicht'
            ORDER BY id DESC LIMIT 5
            """, [.integer(Int64(moduleID))]) {
            var mk = mk
            mk["test"] = try testRow(c, mk["id"], user: user)
            mocks.append(.object(mk))
        }
        let mod = try c.rows("SELECT expected_materials, exam_reuse FROM modules WHERE id=?", [.integer(Int64(moduleID))]).first ?? [:]
        var settingsJSON = try settings(c).json.json.object ?? [:]
        settingsJSON["expected_materials"] = (try? JSONValue.parse(mod["expected_materials"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "[]")) ?? .array([])
        settingsJSON["exam_reuse"] = mod["exam_reuse"].flatMap { LocalModules.truthy(v($0)) ? $0 : nil } ?? "paraphrase"
        return ["weeks": .array(out), "current_week": .number(Double(cur)), "mock_exams": .array(mocks),
                "needs_review": .array(markers.filter { LocalModules.truthy(v($0["needs_review"])) }.map(JSONValue.object)),
                "settings": .object(settingsJSON)]
    }

    /// `def_details(conn, def_id)`
    static func defDetails(_ c: SQLiteConnection, _ defID: Int64, user: String = localUser) throws -> JSONValue {
        guard let d = try c.rows("SELECT * FROM wt_defs WHERE id=?", [.integer(defID)]).first else { throw Failure("Test nicht gefunden.") }
        let qs = (try? JSONValue.parse(d["questions"]?.string ?? "[]"))?.array ?? []
        let src = (try? JSONValue.parse(d["sources"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "{}")) ?? .object([:])
        let cj = (try? JSONValue.parse(d["coverage"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "{}")) ?? .object([:])
        var names: [String: JSONValue] = [:]
        for r in try c.rows("SELECT f.id, f.name, f.title, a.title AS ai_title FROM files f LEFT JOIN analysis a ON a.file_id=f.id") {
            let n = [r["title"], r["ai_title"], r["name"]].first { $0.map { LocalModules.truthy(v($0)) } ?? false } ?? r["name"]
            names[r["id"]?.string ?? ""] = n ?? .null
        }
        func pagesOf(_ k: String) -> JSONValue {
            .array((cj[k]?.array ?? []).map { s in
                ["file_id": s["file_id"] ?? .null, "name": names[s["file_id"]?.string ?? ""] ?? .null, "from": s["from"] ?? .null, "to": s["to"] ?? .null]
            })
        }
        let plan = try d["plan_id"].flatMap { $0 == .null ? nil : $0 }.flatMap { try c.rows("SELECT status, publish_at, missing FROM wt_plans WHERE id=?", [v($0)]).first }
        let test = try c.rows("SELECT id, started_at, submitted_at, score, max_score FROM tests WHERE def_id=? AND user_id=?", [.integer(defID), .text(user)]).first
        var levels: [String: JSONValue] = [:]
        for q in qs {
            let k = q["level"].map { $0.string ?? $0.jsonString() } ?? "null"
            levels[k] = .number((levels[k]?.double ?? 0) + 1)
        }
        let srcMissing = src["missing"].flatMap { ($0.array?.isEmpty ?? true) ? nil : $0 }
        let missing = srcMissing ?? plan.flatMap { (try? JSONValue.parse($0["missing"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "[]")) } ?? .array([])
        return [
            "id": d["id"] ?? .null, "kind": d["kind"] ?? .null, "title": d["title"] ?? .null, "topic": d["topic"] ?? .null, "week_no": d["week_no"] ?? .null,
            "version": d["version"] ?? .null, "status": d["status"] ?? .null, "published_at": d["published_at"] ?? .null,
            "duration_min": d["duration_min"] ?? .null, "question_count": .number(Double(qs.count)), "levels": .object(levels),
            "pages": pagesOf("new"), "prior_pages": pagesOf("prior"),
            "used_materials": .array((src["used"]?.array ?? []).map { ["type": $0.array?.first ?? .null, "label": $0.array?.dropFirst().first ?? .null] }),
            "exam_questions": .number(Double((src["per_question"]?.array ?? []).filter { q in q["from_exam"].map { $0 != .null } ?? false }.count)),
            "exam_candidates": src["exam_candidates"] ?? 0, "missing": missing,
            "excluded_count": .number(Double(src["excluded"]?.array?.count ?? 0)), "test": test.map(JSONValue.object) ?? .null,
            "ranking": d["kind"]?.string == "wochentest" ? .array(try ranking(c, defID)) : .array([]),
            "nachtraege": .array(try c.rows("SELECT id, title, published_at FROM wt_defs WHERE parent_id=? AND kind='nachtrag'", [.integer(defID)]).map(JSONValue.object)),
        ]
    }
}
