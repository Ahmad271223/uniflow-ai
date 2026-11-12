import Foundation

/// KI-Lernplan (07.11.2026, AIStudyPlan.swift): `POST /api/calendar/ai-suggest` {start?, days?} sammelt Module,
/// offene Lehrwochen, Klausurtermine, Lernzeit und freie Zeit je Tag, fragt die KI des Nutzers (`LocalContext.ai`:
/// eigenes ChatGPT bzw. eigener OpenAI-Schluessel in jedem Tarif, sonst die StudiNow-KI mit Credits, Aufgabe
/// `study_plan`) und liefert nur den geprueften Vorschlag. `POST /api/calendar/ai-apply` {blocks} legt die vom Nutzer
/// gewaehlten Bloecke als Lernpakete an (wie "Lernplan erstellen": generated=1, Zeitslots in den freien Fenstern).
/// Ohne KI 404 wie die uebrigen KI-Endpunkte.
enum AIPlanEndpoints: LocalEndpointModule {
    static let name = "KI-Lernplan"
    typealias T = LocalTimetable

    /// hoechstens so viele Tage je Vorschlag
    static let maxDays = 28

    static func register(on router: LocalRouter) {
        router.post("/api/calendar/ai-suggest") { req, ctx in
            guard let ai = ctx.ai.provider else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            let b = try req.objectBody(orEmpty: true)
            let clock = ctx.clock
            let start: Int? = LocalModules.truthy(b["start"]) ? try StudyEndpoints.day(b["start"], "start") : nil
            let days = min(maxDays, try T.span(try T.int(T.or(b["days"], 7), "days")))
            let input = try await ctx.database.transaction { c in try gather(c, start: start, days: days, clock: clock) }
            guard !input.modules.isEmpty else {
                return .json(["blocks": [], "days": .array(input.days.map(dayJSON)), "message": StudyPlan.nothingToPlan["message"] ?? .null, "credits": .null])
            }
            guard !input.days.isEmpty else {
                return .json(["blocks": [], "days": [], "message": "In diesem Zeitraum gibt es keine Lerntage (Lerntage in „Meinen Lernplan konfigurieren“).", "credits": .null])
            }
            let prompt = AIStudyPlan.prompt(input)
            let answer: String
            var credits: JSONValue = .null
            do {
                let r = try await AIRelayTask.run(AIRelayTask("study_plan")) {
                    try await ai.answer(system: AIPromptTexts.system, prompt: prompt, schema: AIStudyPlan.schema)
                }
                answer = r.value
                credits = r.credits
            } catch let e as AIError {
                throw LocalHTTPError(status: ["chatgpt_limit", "openai_quota"].contains(e.code) ? 429 : 503,
                                     detail: ["detail": .string(e.message), "code": .string(e.code)])
            }
            let parsed = (try? AIAnswers.parseJSON(answer))?.json ?? .null
            let blocks = AIStudyPlan.check(parsed, input: input)
            guard !blocks.isEmpty else {
                throw LocalHTTPError(status: 502, detail: ["detail": "Die KI hat keinen brauchbaren Lernplan geliefert. Bitte erneut versuchen.", "code": "ai_no_plan"])
            }
            return .json(["blocks": .array(blocks.map(\.json)), "days": .array(input.days.map(dayJSON)),
                          "message": .string("\(blocks.count) Lernblöcke vorgeschlagen"), "credits": credits])
        }

        router.post("/api/calendar/ai-apply") { req, ctx in
            let b = try req.objectBody()
            let blocks = AIStudyPlan.blocks(fromApply: b["blocks"])
            guard !blocks.isEmpty else { throw LocalHTTPError(status: 400, message: "Keine Lernblöcke gewählt.") }
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c in try apply(c, blocks: blocks, clock: clock) })
        }
    }

    static func dayJSON(_ d: AIStudyPlan.DayInput) -> JSONValue {
        ["date": .string(d.date), "week": .number(Double(d.week)), "free_minutes": .number(Double(d.freeMinutes)),
         "planned": .array(d.planned.map(JSONValue.string))]
    }

    /// Eingabe fuer die KI aus der Datenbank: Lerntage ab `start` (nicht vor heute) mit Lehrwoche, freier Zeit und
    /// schon geplanten Paketen; aktive Module mit offenen Lehrwochen (ohne schon eingeplante und erledigte Dateien),
    /// Prioritaet und Klausurtermin. Nur Titel, Namen, Arten, Dauern und Zeiten (AIStudyPlan).
    static func gather(_ c: SQLiteConnection, start: Int?, days: Int, clock: UniFlowClock) throws -> AIStudyPlan.Input {
        try LocalModules.ensureModules(c, clock: clock)
        let today = T.today(clock)
        try StudyPlan.refreshStatuses(c, today: today)
        let s = try StudyPlan.Settings(c)
        let first = max(start ?? today, today)
        let end = first + days - 1
        let dates = try LocalModules.Dates(c, clock: clock)
        let free = StudIPTerms.freeDays(from: first, to: end, university: try Holidays.university(c), studip: try StudIPTerms.load(c))
        var dayInputs: [AIStudyPlan.DayInput] = []
        for d in first...max(first, end) where s.isLearnDay(d) {
            let iso = StudyPlan.iso(d)
            let planned = try c.query("SELECT subject, title, planned_minutes FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen','erledigt') ORDER BY sort, id", [.text(iso)])
                .map { "\(T.text($0["subject"]?.json)) · \(T.text($0["title"]?.json)) · \($0["planned_minutes"]?.int ?? 0) min" }
            let windows = (try? LocalFreeWindows.compute(c, day: d, settings: s.raw)) ?? []
            let freeMinutes = windows.reduce(0) { $0 + Int($1["minutes"]?.double ?? 0) }
            dayInputs.append(.init(date: iso, week: StudIPTerms.lectureWeek(semesterStart: dates.start, day: d, today: today, free: free),
                                   freeMinutes: freeMinutes, planned: planned))
        }
        let plannedFiles = try StudyPlan.plannedFiles(c)
        var modules: [AIStudyPlan.ModuleInput] = []
        for m in try StudyPlanModules.plannedModules(c) {
            guard let id = m["id"]?.int64 else { continue }
            let units = try StudyPlan.units(c, moduleID: .integer(id), exclude: plannedFiles, dates: dates)
            guard !units.isEmpty else { continue }
            let unitInputs = units.prefix(AIStudyPlan.unitsPerModule).map { u in
                AIStudyPlan.UnitInput(week: u.week, label: u.label, topic: u.topic,
                                      files: (u.lectures + u.exercises).prefix(AIStudyPlan.filesPerUnit).compactMap { f in
                                          guard let fid = f.id.string else { return nil }
                                          let name = T.text(T.or(f.json["ai_title"], f.json["name"] ?? .null))
                                          return AIStudyPlan.FileInput(id: fid, name: name, kind: f.docType ?? "sonstiges", minutes: (try? StudyPlan.est(f)) ?? 45)
                                      })
            }
            let priority = LocalModules.truthy(m["priority"]) ? Int((try? StudyPlan.number(m["priority"], "priority")) ?? 2) : 2
            let exam = m["exam_date"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            modules.append(.init(id: id, name: T.text(m["name"]?.json), priority: priority, examDate: exam, units: unitInputs))
        }
        return AIStudyPlan.Input(today: StudyPlan.iso(today), minutesPerDay: s.minutesPerDay, subjectsPerDay: s.subjectsPerDay,
                                 days: dayInputs, modules: modules)
    }

    /// Gewaehlte Bloecke anlegen: Modul muss es geben, Dateien nur aus dem Modul (sonst freie Aufgabe), Tage nicht vor
    /// heute; danach Zeitslots in den freien Fenstern der betroffenen Tage
    static func apply(_ c: SQLiteConnection, blocks: [AIStudyPlan.Block], clock: UniFlowClock) throws -> JSONValue {
        let today = T.today(clock)
        var created = 0
        var touched = Set<Int>()
        for b in blocks {
            guard let day = BerlinClock.parseISODate(b.date), day >= today,
                  let m = try c.queryOne("SELECT * FROM modules WHERE id=?", [.integer(b.moduleID)]) else { continue }
            var tasks: [StudyPlan.NewTask] = []
            for t in b.tasks {
                var fileID: SQLiteValue = .null
                var type = t.type
                if let f = t.fileID, !f.isEmpty,
                   try c.queryOne("SELECT 1 FROM files f JOIN courses co ON co.id=f.course_id WHERE f.id=? AND co.module_id=?",
                                  [.text(f), .integer(b.moduleID)]) != nil {
                    fileID = .text(f)
                } else if ["vorlesung", "uebung", "skript", "loesung"].contains(type) {
                    type = "frei"
                }
                tasks.append(StudyPlan.NewTask(type: .text(type), fileID: fileID, title: .text(t.title), est: t.minutes))
            }
            guard !tasks.isEmpty else { continue }
            let title: SQLiteValue = b.title.isEmpty ? (m["name"] ?? .null) : .text(b.title)
            _ = try StudyPlan.insertPackage(c, day: day, moduleID: m["id"] ?? .null, subject: m["name"] ?? .null, title: title,
                                            weekNo: b.week.map { .integer(Int64($0)) } ?? .null, tasks: tasks, clock: clock)
            created += 1
            touched.insert(day)
        }
        for d in touched.sorted() { try StudyPlan.assignSlots(c, day: d) }
        try StudyPlan.refreshStatuses(c, today: today)
        return ["created": .number(Double(created)), "message": .string(created == 1 ? "1 Lernblock übernommen" : "\(created) Lernblöcke übernommen")]
    }
}
