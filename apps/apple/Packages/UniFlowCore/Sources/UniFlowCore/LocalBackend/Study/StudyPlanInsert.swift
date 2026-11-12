import Foundation

/// Neue Dokumente in den bestehenden Lernplan einordnen (Entscheidung des Inhabers vom 08.11.2026): Der Lernplan wird
/// nach einem Abgleich nicht mehr neu geplant. Nur Dokumente, die der Planer noch nicht kennt (neue Vorlesungsfolien,
/// neue Uebungsblaetter), kommen als eigene Eintraege in freie Luecken; alles, was schon im Plan steht (auch verschoben,
/// nachgeholt oder erledigt), bleibt unveraendert: dieselbe ID, derselbe Tag, dieselbe Uhrzeit, derselbe Status.
///
/// Welche Dateien der Planer kennt, steht in `study_plan_seen_files` (nur auf diesem Geraet). Dieselbe Datei wird so
/// hoechstens einmal eingeordnet, egal wie oft ein Abgleich sie meldet, und ein Hintergrundabgleich, nach dem nicht
/// eingeordnet wurde, wird beim naechsten Oeffnen der App nachgeholt. Vorher (`autoPlanWeek`, bleibt fuer den
/// Python-Vergleich): jeder Abgleich mit neuen Dateien und jede neue Woche planten die laufende Woche neu und ersetzten
/// dabei alle automatisch erstellten, nicht begonnenen Pakete (neue IDs, neue Uhrzeiten).
extension StudyPlan {
    /// Tage ab heute, in denen ein neues Dokument ohne Klausurtermin des Moduls einen Platz sucht
    static let insertHorizon = 28
    /// Lerntage mit freier Zeit, unter denen der erste mit genug freien Lernminuten gewaehlt wird
    static let insertCandidates = 14

    static func ensureSeenTable(_ c: SQLiteConnection) throws {
        try c.execute("CREATE TABLE IF NOT EXISTS study_plan_seen_files (file_id TEXT PRIMARY KEY, seen_at TEXT)")
    }

    /// Alle vorhandenen Dateien als bekannt merken (ohne zu planen)
    static func markAllSeen(_ c: SQLiteConnection, clock: UniFlowClock) throws {
        try ensureSeenTable(c)
        try c.execute("INSERT OR IGNORE INTO study_plan_seen_files(file_id, seen_at) SELECT id, ? FROM files", [.text(clock.nowISO)])
    }

    /// Neue Dokumente einordnen; nil = am Plan nichts geaendert (aus, keine neuen Dokumente, kein passender Tag).
    ///
    /// - Erster Lauf auf diesem Geraet (noch nichts bekannt): ohne jedes Lernpaket die laufende Woche wie bisher
    ///   planen (erster Abgleich nach der Einrichtung), mit bestehendem Plan nur die vorhandenen Dateien merken.
    /// - Sonst je neues Dokument (Vorlesung oder Uebung eines aktiven Moduls, Lehrwoche ab 1, nicht erledigt, nicht im
    ///   Papierkorb, noch in keiner Aufgabe) ein Paket mit einer Aufgabe (`insertDay`); Uhrzeit nur fuer dieses Paket.
    /// - `auto_plan` aus: nur merken, damit spaeteres Einschalten nicht alles Alte auf einmal einplant.
    static func insertNewFiles(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue? {
        try ensureSeenTable(c)
        let firstRun = try c.queryOne("SELECT 1 FROM study_plan_seen_files LIMIT 1") == nil
        guard try LocalSettings.read(c)["auto_plan"]?.bool == true else {
            try markAllSeen(c, clock: clock)
            return nil
        }
        // Lernziele in Stunden (Smart Planner 2.0): neue Dokumente kommen ueber den Stundenplaner in dessen Bloecke
        if try SmartGoals.active(c) {
            try markAllSeen(c, clock: clock)
            return nil
        }
        let t0 = T.today(clock)
        if firstRun {
            var result: JSONValue? = nil
            if try c.queryOne("SELECT 1 FROM study_packages LIMIT 1") == nil, try c.queryOne("SELECT 1 FROM files LIMIT 1") != nil {
                let sunday = StudyWeeks.monday(t0) + 6
                result = try generatePackages(c, start: t0, days: sunday - t0 + 1, replace: false, clock: clock)
            }
            try markAllSeen(c, clock: clock)
            return result
        }
        let seen = Set(try c.query("SELECT file_id FROM study_plan_seen_files").compactMap { $0[0].string })
        let unseen = try c.query("SELECT id FROM files ORDER BY id").compactMap { $0[0].string }.filter { !seen.contains($0) }
        if unseen.isEmpty { return nil }
        let fresh = Set(unseen)

        try LocalModules.ensureModules(c, clock: clock)
        let s = try Settings(c)
        let dates = try LocalModules.Dates(c, clock: clock)
        let trashed = Set(try c.query("SELECT id FROM files WHERE deleted_at IS NOT NULL").compactMap { $0[0].string })
        var planned = try plannedFiles(c)
        let limit = t0 + 180
        let free = StudIPTerms.freeDays(from: t0, to: limit, university: try Holidays.university(c), studip: try StudIPTerms.load(c))
        var days: [Int] = []
        for m in try c.query("SELECT * FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort") {
            guard let mid = m["id"]?.int64 else { continue }
            var exam: Int?
            if LocalModules.truthy(m["exam_date"]), let text = m["exam_date"]?.string, let e = BerlinClock.parseISODate(text), e > t0 { exam = e }
            for f in try LocalModules.fileRows(c, moduleID: .integer(mid)) {
                guard let id = f.id.string, fresh.contains(id), !trashed.contains(id), !planned.contains(id),
                      f.json["status"]?.string != "erledigt", let kind = f.docType, kind == "vorlesung" || kind == "uebung" else { continue }
                let w = try LocalModules.week(f, dates: dates)
                if w < 1 { continue }                    // aeltere Unterlagen und Klausuren nicht automatisch
                let est = try est(f)
                guard let day = try insertDay(c, week: w, est: est, from: t0, exam: exam, limit: limit, free: free,
                                              semesterStart: dates.start, settings: s) else { continue }
                let unit = Unit(week: w, label: dates.label(w), topic: try LocalModules.weekTopic([f]),
                                lectures: kind == "vorlesung" ? [f] : [], exercises: kind == "uebung" ? [f] : [])
                let task = NewTask(type: .text(kind), fileID: try T.bind(f.id, "file_id"),
                                   title: try T.bind(T.or(f.json["ai_title"], f.json["name"] ?? .null), "title"), est: est)
                let pid = try insertPackage(c, day: day, module: m, tasks: [task], unit: unit, clock: clock)
                try assignSlots(c, day: day, onlyUnset: true, packageID: .integer(pid))
                planned.insert(id)
                days.append(day)
            }
        }
        for id in unseen {
            try c.execute("INSERT OR IGNORE INTO study_plan_seen_files(file_id, seen_at) VALUES (?,?)", [.text(id), .text(clock.nowISO)])
        }
        if days.isEmpty { return nil }
        return ["created": .number(Double(days.count)),
                "message": .string(days.count == 1 ? "1 neues Dokument eingeplant" : "\(days.count) neue Dokumente eingeplant"),
                "dates": .array(Set(days).sorted().map { .string(iso($0)) })]
    }

    /// Tag fuer ein neues Dokument der Lehrwoche `week`: Lerntage ab morgen mit freier Zeit (heute laeuft schon, die
    /// freien Fenster kennen die Uhrzeit nicht: ein Abgleich am Abend legte sonst einen Block auf den Vormittag), nicht
    /// vor der Lehrwoche (Stoff einer vergangenen Woche ab morgen, nie in die Vergangenheit) und vor der Klausur des Moduls; ohne Klausur
    /// bis `insertHorizon` Tage ab heute, mindestens bis zum Ende der Lehrwoche. Unter den ersten `insertCandidates`
    /// der erste mit genug freien Lernminuten (`StudyReschedule.capacity`), sonst der erste; nil ohne passenden Tag.
    static func insertDay(_ c: SQLiteConnection, week: Int, est: Int, from t0: Int, exam: Int?, limit: Int, free: Set<Int>,
                          semesterStart: Int, settings s: Settings) throws -> Int? {
        let end = min(limit, exam ?? max(t0 + insertHorizon, semesterStart + week * 7))
        var candidates: [Int] = []
        var d = t0 + 1
        while d < end && candidates.count < insertCandidates {
            if StudIPTerms.lectureWeek(semesterStart: semesterStart, day: d, today: t0, free: free) >= week, s.isLearnDay(d),
               try !LocalFreeWindows.compute(c, day: d, settings: s.raw).isEmpty {
                candidates.append(d)
            }
            d += 1
        }
        for day in candidates where try StudyReschedule.capacity(c, day: day, settings: s) >= Double(est) { return day }
        return candidates.first
    }
}
