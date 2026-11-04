import Foundation

/// Geteilte Wochenstapel und "Stapel teilen" wie app/server.py (`week_stack_status`, `week_stack_get_or_generate`) und
/// app/community_cards_api.py (04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md), fuer das iPad ueber die Dienste
/// der App (`LocalContext.cardShare` = Varianten-Dienst der Wochenstapel, `LocalContext.cardCommunity` = Modul-Community):
///
/// - `GET|POST /api/flashcard-stacks/week/{module_id}/{week}/{kind}`: Stand bzw. holen-oder-erzeugen (uebernehmen = 0 KI)
/// - `POST|DELETE /api/flashcard-stacks/{id}/share`: eigenen Stapel teilen bzw. zurueckziehen
/// - `GET /api/community/card-stacks?module=|module_id=&week=`, `GET …/{id}`, `POST …/{id}/adopt`, `POST|DELETE …/{id}/like`,
///   `POST …/{id}/report`
/// Ohne Dienst (kein iCloud-Container, nicht angemeldet) antworten die Community-Pfade mit 503 `not_available`; der
/// Wochenstapel entsteht dann als eigener Stapel mit der KI des Nutzers (status `unshared`).
enum CardStackEndpoints: LocalEndpointModule {
    static let name = "Geteilte Stapel"

    static let notAvailable = LocalHTTPError(status: 503, detail: ["detail": "Geteilte Stapel gibt es nur mit iCloud-Konto in einem Build mit iCloud-Container.",
                                                                   "code": "not_available"])

    static func register(on router: LocalRouter) {
        // MARK: Wochenstapel

        router.get("/api/flashcard-stacks/week/{module_id:int}/{week:int}/{kind}") { req, ctx in
            let kind = try kindValue(req.param("kind"))
            let week = try weekValue(req.intParam("week"))
            let moduleID = Int64(req.intParam("module_id"))
            let today = ctx.clock.today
            let (module, files, existing) = try await ctx.database.withConnection { c -> (String, [WeekMaterial], JSONValue?) in
                let m = try module(c, moduleID)
                let files = try weekFiles(c, moduleID: moduleID, week: week, kind: kind, clock: ctx.clock)
                return (m, files, try weekStack(c, subject: m, week: week, kind: kind, today: today))
            }
            let uni = try await university(ctx)
            _ = module
            return .json(["stack": existing ?? .null, "files": .number(Double(files.count)), "name": .string(CardStackShare.stackName(kind: kind, week: week)),
                          "shareable": .bool(CardStackShare.weekKey(university: uni, kind: kind, contentHashes: files.map(\.contentHash)) != nil)])
        }

        router.post("/api/flashcard-stacks/week/{module_id:int}/{week:int}/{kind}") { req, ctx in
            let kind = try kindValue(req.param("kind"))
            let week = try weekValue(req.intParam("week"))
            let moduleID = Int64(req.intParam("module_id"))
            let today = ctx.clock.today, now = ctx.clock.nowISO
            let (module, files, existing) = try await ctx.database.withConnection { c -> (String, [WeekMaterial], JSONValue?) in
                let m = try module(c, moduleID)
                let files = try weekFiles(c, moduleID: moduleID, week: week, kind: kind, clock: ctx.clock)
                return (m, files, try weekStack(c, subject: m, week: week, kind: kind, today: today))
            }
            if let existing {
                return .json(["stack": existing, "status": "exists", "variant": .null, "of": .number(Double(CardStackShare.maxVariants)), "credits": .null])
            }
            guard !files.isEmpty else {
                let what = kind == "vorlesung" ? "Vorlesungsunterlagen" : "Übungsblätter"
                throw LocalHTTPError(status: 404, detail: ["detail": .string("Für Woche \(week) gibt es keine \(what) in diesem Modul."), "code": "no_materials"])
            }
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            var texts: [CardStackShare.WeekFile] = []
            for f in files {
                texts.append(.init(name: f.name, text: await WeekTests.text(ctx: ctx, fileID: f.id, excerpt: f.excerpt)))
            }
            let prompt = CardStackShare.prompt(module: module, kind: kind, week: week, files: texts)
            let generate: @Sendable () async throws -> [AIAnswers.Flashcard] = {
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
                return cards
            }
            let uni = try await university(ctx)
            let cards: [AIAnswers.Flashcard]
            var status = "unshared"
            var variant: Int?
            var key = ""
            if let k = CardStackShare.weekKey(university: uni, kind: kind, contentHashes: files.map(\.contentHash)) {
                key = k
                let material = WeeklyTestMaterial(key: k, contentHashes: files.compactMap(\.contentHash))
                let share = ctx.cardShare, clock = ctx.clock
                let outcome = try await WeeklyTestShare.obtain(material, provider: share.provider, waiting: share.waiting,
                                                               now: { Double(clock.utcSeconds) }) {
                    CardStackShare.poolTest(kind: kind, cards: try await generate())
                }
                switch outcome {
                case .adopted(let v, let t, _):
                    let got = CardStackShare.cards(from: t, kind: kind)
                    guard !got.isEmpty else {
                        throw LocalHTTPError(status: 502, detail: ["detail": "Der geteilte Stapel ist unbrauchbar. Bitte erneut versuchen.", "code": "shared_unusable"])
                    }
                    cards = got
                    status = "adopted"
                    variant = v
                case .generated(let v, let t, let published):
                    cards = CardStackShare.cards(from: t, kind: kind)
                    status = published ? "generated" : "unshared"
                    variant = v
                case .unshared(let v, let t):
                    cards = CardStackShare.cards(from: t, kind: kind)
                    variant = v
                }
            } else {
                cards = try await generate()
            }
            let finalStatus = status, finalVariant = variant, finalKey = key, finalCards = cards
            return .json(try await ctx.database.transaction { c -> JSONValue in
                if let ex = try weekStack(c, subject: module, week: week, kind: kind, today: today) {       // parallel entstanden
                    return ["stack": ex, "status": "exists", "variant": .null, "of": .number(Double(CardStackShare.maxVariants)), "credits": .null]
                }
                let sid = try insertStack(c, name: CardStackShare.stackName(kind: kind, week: week), subject: module, kind: kind, week: week,
                                          source: CardStackShare.sourceWeek, ref: finalKey, cards: finalCards, now: now, today: today)
                return ["stack": try FlashcardEndpoints.stackRow(c, .integer(sid), today) ?? .null, "status": .string(finalStatus),
                        "variant": finalVariant.map { .number(Double($0 + 1)) } ?? .null, "of": .number(Double(CardStackShare.maxVariants)), "credits": .null]
            })
        }

        // MARK: Eigenen Stapel teilen

        router.post("/api/flashcard-stacks/{stack_id:int}/share") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("stack_id")))
            let today = ctx.clock.today
            let uni = try await university(ctx)
            let (stack, moduleName, cards) = try await ctx.database.withConnection { c -> (JSONValue, String, [AIAnswers.Flashcard]) in
                guard let s = try FlashcardEndpoints.stackRow(c, id, today) else { throw LocalHTTPError.notFound("Stapel nicht gefunden") }
                if let shared = s["shared_id"]?.string, !shared.isEmpty {
                    throw LocalHTTPError(status: 409, detail: ["detail": "Dieser Stapel ist schon geteilt.", "code": "already_shared"])
                }
                guard let subject = s["subject"]?.string, !subject.isEmpty,
                      try c.queryOne("SELECT id FROM modules WHERE name=?", [.text(subject)]) != nil else {
                    throw LocalHTTPError(status: 422, detail: ["detail": "Nur Stapel eines Moduls lassen sich teilen.", "code": "no_module"])
                }
                let rows = try c.query("SELECT question, answer FROM flashcards WHERE stack_id=? ORDER BY id", [id])
                return (s, subject, rows.map { AIAnswers.Flashcard(question: $0["question"]?.string ?? "", answer: $0["answer"]?.string ?? "") })
            }
            guard !cards.isEmpty else { throw LocalHTTPError(status: 422, detail: ["detail": "Der Stapel hat keine Karten.", "code": "stack_empty"]) }
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            guard let key = CommunityKeys.courseKey(university: uni, courseName: moduleName) else {
                throw LocalHTTPError(status: 422, detail: ["detail": "Nur Stapel eines Moduls lassen sich teilen.", "code": "no_module"])
            }
            let draft = CardStackDraft(communityKey: key, name: stack["name"]?.string ?? "", kind: stack["kind"]?.string ?? "eigene",
                                       week: stack["week"]?.int, cards: cards)
            let sharedID: String
            do { sharedID = try await provider.publish(draft, secret: CommunityKeys.secret(university: uni, moduleName: moduleName)) } catch { throw serviceError(error) }
            let summary = (try? await provider.summary(id: sharedID))
                ?? SharedCardStackSummary(id: sharedID, communityKey: key, name: draft.name, kind: draft.kind, week: draft.week, cardCount: cards.count,
                                          pseudonym: "", createdAt: ctx.clock.nowISO, isOwn: true)
            return .json(try await ctx.database.transaction { c -> JSONValue in
                _ = try c.execute("UPDATE flashcard_stacks SET shared_id=? WHERE id=?", [.text(sharedID), id])
                var out = summary.json(adopted: false)
                out["stack"] = try FlashcardEndpoints.stackRow(c, id, today) ?? .null
                return out
            })
        }

        router.delete("/api/flashcard-stacks/{stack_id:int}/share") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("stack_id")))
            let today = ctx.clock.today
            let sharedID: String = try await ctx.database.withConnection { c in
                guard let s = try FlashcardEndpoints.stackRow(c, id, today) else { throw LocalHTTPError.notFound("Stapel nicht gefunden") }
                guard let shared = s["shared_id"]?.string, !shared.isEmpty else {
                    throw LocalHTTPError(status: 404, detail: ["detail": "Dieser Stapel ist nicht geteilt.", "code": "not_shared"])
                }
                return shared
            }
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            do { try await provider.withdraw(id: sharedID) } catch { throw serviceError(error) }
            return .json(try await ctx.database.transaction { c -> JSONValue in
                _ = try c.execute("UPDATE flashcard_stacks SET shared_id=NULL WHERE id=?", [id])
                return ["withdrawn": true, "already": false, "stack": try FlashcardEndpoints.stackRow(c, id, today) ?? .null]
            })
        }

        // MARK: Geteilte Stapel des Moduls

        router.get("/api/community/card-stacks") { req, ctx in
            let week = try WeeklyEndpoints.intQuery(req, "week")
            let moduleID = try WeeklyEndpoints.intQuery(req, "module_id")
            let uni = try await university(ctx)
            let given = req.query("module") ?? ""
            let (key, adopted): (String, Set<String>) = try await ctx.database.withConnection { c in
                var key = given
                if let moduleID {
                    guard let name = try c.queryOne("SELECT name FROM modules WHERE id=?", [.integer(Int64(moduleID))])?["name"]?.string,
                          let k = CommunityKeys.courseKey(university: uni, courseName: name) else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
                    key = k
                }
                return (key, try adoptedIDs(c))
            }
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            let list: [SharedCardStackSummary]
            do { list = try await provider.list(communityKey: key) } catch { throw serviceError(error) }
            let shown = list.filter { s in
                guard let week else { return true }
                return week == 0 ? s.week == nil : s.week == week
            }
            return .json(["community_key": .string(key), "stacks": .array(shown.map { $0.json(adopted: adopted.contains($0.id)) })])
        }

        router.get("/api/community/card-stacks/{id}") { req, ctx in
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            let uni = try await university(ctx)
            let (summary, module) = try await shared(req.param("id"), provider: provider, ctx: ctx, university: uni)
            let cards: [AIAnswers.Flashcard]
            do {
                cards = try await provider.cards(id: summary.id, communityKey: summary.communityKey, secret: CommunityKeys.secret(university: uni, moduleName: module))
            } catch { throw serviceError(error) }
            let adopted = try await ctx.database.withConnection { try adoptedIDs($0) }
            var out = summary.json(adopted: adopted.contains(summary.id))
            out["cards_list"] = .array(cards.map(\.json))
            return .json(out)
        }

        router.post("/api/community/card-stacks/{id}/adopt") { req, ctx in
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            let uni = try await university(ctx)
            let today = ctx.clock.today, now = ctx.clock.nowISO
            let (summary, module) = try await shared(req.param("id"), provider: provider, ctx: ctx, university: uni)
            if let ex = try await ctx.database.withConnection({ c -> JSONValue? in
                guard let r = try c.queryOne("SELECT id FROM flashcard_stacks WHERE source=? AND source_ref=?",
                                             [.text(CardStackShare.sourceCommunity), .text(summary.id)]), let id = r["id"] else { return nil }
                return try FlashcardEndpoints.stackRow(c, id, today)
            }) {
                return .json(["stack": ex, "already": true, "count": 0])
            }
            let cards: [AIAnswers.Flashcard]
            do {
                cards = try await provider.cards(id: summary.id, communityKey: summary.communityKey, secret: CommunityKeys.secret(university: uni, moduleName: module))
            } catch { throw serviceError(error) }
            return .json(try await ctx.database.transaction { c -> JSONValue in
                let sid = try insertStack(c, name: summary.name, subject: module, kind: summary.kind, week: summary.week,
                                          source: CardStackShare.sourceCommunity, ref: summary.id, cards: cards, now: now, today: today)
                return ["stack": try FlashcardEndpoints.stackRow(c, .integer(sid), today) ?? .null, "already": false, "count": .number(Double(cards.count))]
            })
        }

        router.post("/api/community/card-stacks/{id}/like") { req, ctx in
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            let id = req.param("id").lowercased()
            do { return .json(["id": .string(id), "liked": true, "likes": .number(Double(try await provider.like(id: id, on: true)))]) } catch { throw serviceError(error) }
        }

        router.delete("/api/community/card-stacks/{id}/like") { req, ctx in
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            let id = req.param("id").lowercased()
            do { return .json(["id": .string(id), "liked": false, "likes": .number(Double(try await provider.like(id: id, on: false)))]) } catch { throw serviceError(error) }
        }

        router.post("/api/community/card-stacks/{id}/report") { req, ctx in
            guard let provider = ctx.cardCommunity.provider else { throw notAvailable }
            let body = try req.pythonObjectBody()
            guard case .string(let reason)? = body.value("reason"), reportReasons.contains(reason) else {
                throw LocalHTTPError(status: 400, detail: ["detail": "Unbekannter Meldegrund.", "code": "reason_invalid"])
            }
            let note: String? = { if case .string(let s)? = body.value("note") { return s }; return nil }()
            do { try await provider.report(id: req.param("id").lowercased(), reason: reason, note: note) } catch { throw serviceError(error) }
            return .json(["reported": true, "hidden": false, "reports": 1])
        }
    }

    // MARK: Helfer

    /// `community.REPORT_REASONS`
    static let reportReasons = ["foreignMaterial", "gradedSubmission", "offensive", "spam", "other"]

    struct WeekMaterial: Sendable {
        let id: String
        let name: String
        let excerpt: JSONValue?
        let contentHash: String?
    }

    static func kindValue(_ v: String) throws -> String {
        guard CardStackShare.kinds.contains(v) else { throw LocalHTTPError(status: 422, message: "kind: vorlesung oder uebung erwartet") }
        return v
    }

    static func weekValue(_ v: Int) throws -> Int {
        guard v >= 1 else { throw LocalHTTPError(status: 422, message: "week: ganze Zahl ab 1 erwartet") }
        return v
    }

    static func module(_ c: SQLiteConnection, _ id: Int64) throws -> String {
        guard let m = try c.queryOne("SELECT id, name FROM modules WHERE id=?", [.integer(id)]), let name = m["name"]?.string else {
            throw LocalHTTPError.notFound("Modul nicht gefunden")
        }
        return name
    }

    static func university(_ ctx: LocalContext) async throws -> String {
        try await ctx.database.withConnection { c in
            try c.scalar("SELECT value FROM settings WHERE key='university'")?.string ?? Migrations.defaultUniversity
        }
    }

    /// `_week_files`: Dateien der Lehrwoche des Moduls fuer die Art (`weekDocTypes`), aelteste zuerst, hoechstens `weekFilesMax`
    static func weekFiles(_ c: SQLiteConnection, moduleID: Int64, week: Int, kind: String, clock: UniFlowClock) throws -> [WeekMaterial] {
        let dates = try LocalModules.Dates(c, clock: clock)
        let types = CardStackShare.weekDocTypes[kind] ?? []
        let files = try LocalModules.fileRows(c, moduleID: .integer(moduleID)).filter {
            try LocalModules.week($0, dates: dates) == week && types.contains($0.docType ?? "")
        }.prefix(CardStackShare.weekFilesMax)
        return try files.map { f in
            let id = f.id.string ?? PyText.str(PyJSON(f.id))
            let p = try c.queryOne("SELECT text_excerpt, content_sha256 FROM files WHERE id=?", [SQLiteValue(json: f.id) ?? .null])
            return WeekMaterial(id: id, name: f.json["name"]?.string ?? "", excerpt: p?["text_excerpt"]?.json,
                                contentHash: p?["content_sha256"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// `_week_stack`: vorhandener uebernommener Wochenstapel des Moduls (source = week)
    static func weekStack(_ c: SQLiteConnection, subject: String, week: Int, kind: String, today: String) throws -> JSONValue? {
        guard let r = try c.queryOne("SELECT id FROM flashcard_stacks WHERE source=? AND subject=? AND week=? AND kind=? ORDER BY id LIMIT 1",
                                     [.text(CardStackShare.sourceWeek), .text(subject), .integer(Int64(week)), .text(kind)]), let id = r["id"] else { return nil }
        return try FlashcardEndpoints.stackRow(c, id, today)
    }

    /// Neuer Stapel mit Karten (Fach 1, heute faellig, Fach des Moduls) wie Python
    static func insertStack(_ c: SQLiteConnection, name: String, subject: String, kind: String, week: Int?, source: String, ref: String,
                            cards: [AIAnswers.Flashcard], now: String, today: String) throws -> Int64 {
        _ = try c.execute("INSERT INTO flashcard_stacks(name, subject, file_id, created_at, kind, week, source, source_ref) VALUES (?,?,?,?,?,?,?,?)",
                          [.text(name), .text(subject), .null, .text(now), .text(kind), week.map { .integer(Int64($0)) } ?? .null, .text(source), .text(ref)])
        let sid = c.lastInsertRowID
        for card in cards {
            _ = try c.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, stack_id) VALUES (NULL,?,?,?,?,1,?,?)",
                              [.text(subject), .text(card.question), .text(card.answer), .text(now), .text(today), .integer(sid)])
        }
        return sid
    }

    static func adoptedIDs(_ c: SQLiteConnection) throws -> Set<String> {
        Set(try c.query("SELECT source_ref FROM flashcard_stacks WHERE source=? AND source_ref IS NOT NULL", [.text(CardStackShare.sourceCommunity)])
            .compactMap { $0["source_ref"]?.string })
    }

    /// Kopfdaten eines geteilten Stapels und das lokale Modul zu seinem Community-Schluessel (Modulname oder Kurstitel);
    /// 404 `module_not_here`, wenn es das Modul auf diesem Geraet nicht gibt (kein Teilen ueber Module hinweg)
    static func shared(_ rawID: String, provider: CardStackCommunityProvider, ctx: LocalContext, university: String) async throws -> (SharedCardStackSummary, String) {
        let summary: SharedCardStackSummary?
        do { summary = try await provider.summary(id: rawID.lowercased()) } catch { throw serviceError(error) }
        guard let summary else { throw LocalHTTPError(status: 404, detail: ["detail": "Geteilter Stapel nicht gefunden.", "code": "not_found"]) }
        let module: String? = try await ctx.database.withConnection { c in
            for m in try c.query("SELECT id, name FROM modules ORDER BY id") {
                guard let name = m["name"]?.string, !name.isEmpty else { continue }
                if CommunityKeys.courseKey(university: university, courseName: name) == summary.communityKey { return name }
            }
            for r in try c.query("SELECT c.title, m.name FROM courses c JOIN modules m ON m.id=c.module_id WHERE c.id<>'__user__'") {
                if let t = r["title"]?.string, CommunityKeys.moduleKey(university: university, courseTitle: t) == summary.communityKey,
                   let name = r["name"]?.string { return name }
            }
            return nil
        }
        guard let module else {
            throw LocalHTTPError(status: 404, detail: ["detail": "Dieses Modul gibt es auf diesem Gerät nicht.", "code": "module_not_here"])
        }
        return (summary, module)
    }

    /// Fehler des Dienstes verstaendlich: 503 mit Meldung, nie Kennungen
    static func serviceError(_ error: Error) -> LocalHTTPError {
        if let e = error as? LocalHTTPError { return e }
        return LocalHTTPError(status: 503, detail: ["detail": .string("Die Community ist gerade nicht erreichbar: \(error.localizedDescription)"), "code": "community_unavailable"])
    }
}
