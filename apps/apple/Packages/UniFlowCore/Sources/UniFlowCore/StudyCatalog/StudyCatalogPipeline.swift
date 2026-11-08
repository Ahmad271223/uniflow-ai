import Foundation

/// Antwort beim Laden einer Katalog-PDF: 200 (Daten, ETag, Last-Modified), 304, 404 oder 0 (Netzfehler)
public struct StudyCatalogFetchResult: Sendable, Equatable {
    public var status: Int
    public var data: Data
    public var etag: String?
    public var lastModified: String?
    public var error: String?

    public init(status: Int, data: Data = Data(), etag: String? = nil, lastModified: String? = nil, error: String? = nil) {
        self.status = status
        self.data = data
        self.etag = etag
        self.lastModified = lastModified
        self.error = error
    }
}

/// Laedt eine oeffentliche PDF (App: URLSession ohne Cookies; Tests: Attrappe)
public protocol StudyCatalogLoader: Sendable {
    func fetch(url: String, etag: String?, lastModified: String?) async -> StudyCatalogFetchResult
}

/// Die geteilte Bibliothek (App: CloudKit `StudyCatalog`, oeffentliche Datenbank)
public protocol StudyCatalogLibrary: Sendable {
    /// Payload-Texte der Varianten zum Schluessel, kleinste Variante zuerst; leer = keiner
    func lookup(key: String) async throws -> [String]
    /// Fakten veroeffentlichen, nie ueberschreiben (freie Variante 0...2); true = gespeichert, false = alle Plaetze belegt
    func publish(key: String, meta: StudyCatalogMeta, payload: String) async throws -> Bool
}

/// Seitentexte einer PDF (App und macOS: PDFKit, `StudyCatalogPDF.pages`); nil = keine PDF
public typealias StudyCatalogPDFText = @Sendable (Data) -> [String]?

/// Textstuecke mit Lage je Seite (Studienverlaufsplan; App und macOS: `StudyCatalogPDF.planItems`); nil = keine PDF
public typealias StudyPlanPDFText = @Sendable (Data) -> [[StudyPlanTextItem]]?

/// Ablauf der Katalogsuche, gleich fuer App und Tests (die App: `StudyCatalogSync`): Studiengang aus QIS bzw.
/// bestaetigter PO -> Schluessel -> lokal -> Grundstock der App (`StudyCatalogSeed`, 0 Downloads) -> Bibliothek
/// (uebernehmen, 0 Downloads) -> oeffentliche PDF einmal je
/// Katalogsemester laden (Primaer, dann Spiegel; ETag/304) -> lesen -> pruefen -> speichern -> Fakten in die Bibliothek.
/// Fehler werden als Stand gemeldet und erst nach 24 Stunden wiederholt. Eigener Link (`settings.study_plan.catalog_url`)
/// geht vor: einmal laden, mit dem LUH-Parser lesen oder "Format unbekannt" melden.
public enum StudyCatalogPipeline {
    public static let retryHours: Double = 24
    public static let missingDays: Double = 30

    public static let messages: [String: String] = [
        "searching": "StudiNow sucht den Modulkatalog deines Studiengangs …",
        "downloading": "Modulkatalog wird geladen …",
        "parsing": "Module werden gelesen …",
        "no_program": "Noch kein Studiengang bekannt. Verbinde QIS oder wähle deine Prüfungsordnung.",
        "not_found": "Für deinen Studiengang gibt es noch keinen Katalog.",
        "ready": "Modulkatalog geladen",
        "library": "Aus der Bibliothek übernommen",
        "seed": "Aus dem StudiNow-Grundstock",
        "error_download": "Der Modulkatalog ließ sich nicht laden. StudiNow versucht es in 24 Stunden erneut.",
        "error_parse": "Der Modulkatalog ließ sich nicht lesen. StudiNow versucht es in 24 Stunden erneut.",
        "unknown_format": "Das Format dieses Modulhandbuchs kennt StudiNow noch nicht. Der Link ist gespeichert.",
    ]

    public struct Environment: Sendable {
        public var sources: StudySources
        public var loader: StudyCatalogLoader
        public var library: StudyCatalogLibrary?
        /// Grundstock der App (Ressource StudyCatalogSeed); nil = keiner (Tests, PC)
        public var seed: StudyCatalogSeedSource?
        public var pdfText: StudyCatalogPDFText
        public var planText: StudyPlanPDFText
        public var now: @Sendable () -> Date

        public init(sources: StudySources = .bundled, loader: StudyCatalogLoader, library: StudyCatalogLibrary?,
                    seed: StudyCatalogSeedSource? = nil,
                    pdfText: @escaping StudyCatalogPDFText, planText: @escaping StudyPlanPDFText = { StudyCatalogPDF.planItems($0) },
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.sources = sources
            self.loader = loader
            self.library = library
            self.seed = seed
            self.pdfText = pdfText
            self.planText = planText
            self.now = now
        }
    }

    // MARK: Zeit

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func day(_ d: Date) -> String { String(iso(d).prefix(10)) }

    // MARK: Eingaben aus der Datenbank

    /// Aktueller QIS-Studiengang (`grades.abschluss`): nennt der Notenspiegel mehrere (Wechsel, Master nach dem
    /// Bachelor), gewinnt der mit dem juengsten Semester (Spalte, Datum oder Anmeldung im Status), dann der hoechsten
    /// PO-Version, dann der haeufigste (`StudyPlanEngine.currentAbschluss`; bis 07.11.2026 immer der haeufigste, nach
    /// einem Wechsel also der alte)
    static func qisLabel(_ c: SQLiteConnection) throws -> String? {
        let rows = try c.query("SELECT abschluss, semester, datum, status FROM grades WHERE abschluss IS NOT NULL AND trim(abschluss) <> '' ORDER BY id")
        return StudyPlanEngine.currentAbschluss(rows.map { r in
            ["abschluss": .string(r["abschluss"]?.string ?? ""), "semester": .string(r["semester"]?.string ?? ""),
             "datum": .string(r["datum"]?.string ?? ""), "status": .string(r["status"]?.string ?? "")]
        })
    }

    /// `settings.study_plan` (po, start_term, electives, catalog_url)
    static func planSettings(_ c: SQLiteConnection) throws -> JSONValue {
        guard let v = try c.queryOne("SELECT value FROM settings WHERE key='study_plan'")?["value"]?.string,
              let j = try? JSONValue.parse(v), j.object != nil else { return .object([:]) }
        return j
    }

    static func university(_ c: SQLiteConnection) throws -> String {
        try c.queryOne("SELECT value FROM settings WHERE key='university'")?["value"]?.string ?? "luh"
    }

    /// Eigener Link: nur https, hoechstens 500 Zeichen (gleich `clean_catalog_url` in app/study_catalog.py)
    public static func cleanCatalogURL(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, StudyCatalogText.length(s) <= 500,
              s.lowercased().hasPrefix("https://"), let u = URL(string: s), u.host?.isEmpty == false,
              !s.contains(where: { $0.isWhitespace }) else { return nil }
        return s
    }

    /// modkat-Link -> (Kuerzel, Semester): ".../modkat-TIBSc22-WS_2025_26.pdf", ".../modkat-full-TIBSc25-WS_2026_27.pdf"
    public static func modkatParts(_ url: String) -> (code: String, term: String)? {
        guard let m = CatalogRx.search(#"/modkat-(?:full-)?([A-Za-z0-9_-]+)-(WS_([0-9]{4})_([0-9]{2})|SS_([0-9]{4}))\.pdf$"#, url),
              let code = m[1] else { return nil }
        if let y = m[3] ?? nil, let yy = m[4] ?? nil { return (code, "WS \(y)/\(yy)") }
        if let y = m[5] ?? nil { return (code, "SS \(y)") }
        return nil
    }

    // MARK: Ablauf

    /// Ein Lauf. Ergebnis = neuer Stand (auch in `study_catalog_state.status`). `force`: auch mit lokalem Katalog bzw.
    /// vor Ablauf der 24 Stunden erneut (bedingtes Laden mit ETag).
    @discardableResult
    public static func run(db: SQLiteDatabase, env: Environment, force: Bool = false) async -> JSONValue {
        do {
            return try await perform(db: db, env: env, force: force)
        } catch {
            let state: JSONValue = ["state": "error", "error": .string(String(describing: error).prefix(200).description),
                                    "message": .string(messages["error_download"]!), "checked_at": .string(iso(env.now()))]
            _ = try? await db.transaction { try StudyCatalogStore.setState($0, "status", state) }
            return state
        }
    }

    static func save(_ db: SQLiteDatabase, _ state: JSONValue) async throws -> JSONValue {
        try await db.transaction { try StudyCatalogStore.setState($0, "status", state) }
        return state
    }

    static func merged(_ base: [String: JSONValue], _ extra: [String: JSONValue]) -> JSONValue {
        .object(base.merging(extra) { _, new in new })
    }

    static func perform(db: SQLiteDatabase, env: Environment, force: Bool) async throws -> JSONValue {
        let now = env.now()
        let (label, settings, uni) = try await db.transaction { c in (try qisLabel(c), try planSettings(c), try university(c)) }
        let inputs = try await db.transaction { try Self.inputs($0) }
        var base: [String: JSONValue] = ["checked_at": .string(iso(now)), "qis_label": label.map { .string($0) } ?? .null,
                                         "inputs": .string(inputs)]
        if let custom = cleanCatalogURL(settings["catalog_url"]?.string) {
            return try await runCustom(url: custom, db: db, env: env, base: base, university: uni, label: label, force: force)
        }
        let po = settings["po"]?.string.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        // Ein selbst gewaehlter Studiengang (Kuerzel des Registers als `po`, "Studiengang waehlen") geht vor der
        // Bezeichnung aus dem Notenspiegel; eine bestaetigte PO (Jahr) ordnet nur innerhalb des erkannten Studiengangs
        var match = po.flatMap { env.sources.match(code: $0, university: uni, qisLabel: label) }
        if match == nil { match = label.flatMap { env.sources.match(label: $0, university: uni, po: po) } }
        guard let m = match else {
            let reason = label == nil ? "no_program" : "no_source"
            return try await save(db, merged(base, ["state": "not_found", "reason": .string(reason),
                                                    "message": .string(messages[label == nil ? "no_program" : "not_found"]!)]))
        }
        base["program"] = m.program.map { .string($0) } ?? .null
        base["degree"] = m.degree.map { .string($0) } ?? .null
        base["po"] = .string(m.po)
        base["code"] = .string(m.code)
        base["needs_confirmation"] = .bool(m.needsConfirmation)
        base["suggested_po"] = .string(m.po)
        _ = try await save(db, merged(base, ["state": "searching", "message": .string(messages["searching"]!)]))

        var lastError: String?
        for term in terms(env: env, university: uni, code: m.code, today: day(now)) {
            let key = StudyCatalogText.libraryKey(university: uni, code: m.code, term: term)
            var info = base
            info["catalog_term"] = .string(term)
            info["key"] = .string(key)
            // 1. lokal
            let local = try await db.transaction { try StudyCatalogStore.catalog($0, key: key) }
            if let local, !force {
                var extra: [String: JSONValue] = ["state": "ready", "origin": "local", "message": .string(messages["ready"]!),
                                                  "modules": .number(Double(local["modules"]?.array?.count ?? 0))]
                if let plan = try await ensurePlan(db: db, env: env, key: key, university: uni, code: m.code, force: false) {
                    extra["study_plan"] = plan
                }
                return try await save(db, merged(info, extra))
            }
            // 2. Grundstock der App: gueltige Fakten uebernehmen, nichts laden und nichts teilen (alle haben ihn);
            //    Modultexte erst, wenn jemand ein Modul oeffnet (`loadTexts`)
            if local == nil, let p = env.seed?.payload(key: key), let j = validPayload(p, key: key) {
                try await db.transaction { _ = try StudyCatalogStore.store($0, payload: p, texts: nil, origin: "seed", now: iso(now)) }
                var extra: [String: JSONValue] = ["state": "seed", "origin": "seed", "message": .string(messages["seed"]!),
                                                  "modules": .number(Double(j["modules"]?.array?.count ?? 0))]
                if let plan = try await ensurePlan(db: db, env: env, key: key, university: uni, code: m.code, force: false) {
                    extra["study_plan"] = plan
                }
                return try await save(db, merged(info, extra))
            }
            // 3. Bibliothek: gueltige Fakten uebernehmen, nichts laden
            if local == nil, let lib = env.library, let payloads = try? await lib.lookup(key: key) {
                let valid = payloads.filter { validPayload($0, key: key) != nil }
                // mit Studienverlaufsplan zuerst (aeltere Varianten ohne Plan bleiben lesbar und werden hier ergaenzt)
                let withPlan = valid.first { (try? JSONValue.parse($0))?["study_plan"]?.object != nil }
                if let p = withPlan ?? valid.first, let j = try? JSONValue.parse(p) {
                    try await db.transaction { _ = try StudyCatalogStore.store($0, payload: p, texts: nil, origin: "library", now: iso(now)) }
                    var extra: [String: JSONValue] = ["state": "library", "origin": "library", "message": .string(messages["library"]!),
                                                      "modules": .number(Double(j["modules"]?.array?.count ?? 0))]
                    if let plan = try await ensurePlan(db: db, env: env, key: key, university: uni, code: m.code, force: false) {
                        extra["study_plan"] = plan
                        // ergaenzte Fakten als neue Variante teilen (nie ueberschreiben)
                        if plan["state"]?.string == "merged", let meta = env.sources.meta(university: uni, code: m.code, term: term),
                           let stored = try await db.transaction({ try StudyCatalogStore.payload($0, key: key) }) {
                            _ = try? await lib.publish(key: key, meta: meta, payload: stored.payload)
                        }
                    }
                    return try await save(db, merged(info, extra))
                }
            }
            // Kuerzel ohne Download-Quelle (nur im Grundstock, luh-grundstock): nichts laden
            let urls = env.sources.sourceURLs(university: uni, code: m.code, term: term)
            if urls.isEmpty {
                if let local {
                    return try await save(db, merged(info, ["state": "ready", "origin": "local", "message": .string(messages["ready"]!),
                                                            "modules": .number(Double(local["modules"]?.array?.count ?? 0))]))
                }
                continue
            }
            // 4. Fehlversuch in den letzten 24 Stunden: nicht erneut
            let attempt = try await db.transaction { try StudyCatalogStore.state($0, "attempt:" + key) }
            if !force, let at = date(attempt?["at"]?.string), now.timeIntervalSince(at) < retryHours * 3600, attempt?["error"] != nil {
                return try await save(db, merged(info, ["state": "error", "error": attempt?["error"] ?? .null, "message": attempt?["message"] ?? .null,
                                                        "retry_at": .string(iso(at.addingTimeInterval(retryHours * 3600)))]))
            }
            // 5. laden: Primaer, dann Spiegel
            _ = try await save(db, merged(info, ["state": "downloading", "message": .string(messages["downloading"]!)]))
            var result: StudyCatalogFetchResult?
            var used: String?
            var missing = 0
            lastError = nil
            for url in urls {
                let (miss, cache) = try await db.transaction { c in
                    (try StudyCatalogStore.state(c, "missing:" + url), try StudyCatalogStore.state(c, "http:" + url))
                }
                if let at = date(miss?["at"]?.string), now.timeIntervalSince(at) < missingDays * 86400 {
                    missing += 1
                    continue
                }
                let have = local != nil
                let r = await env.loader.fetch(url: url, etag: have ? cache?["etag"]?.string : nil,
                                               lastModified: have ? cache?["last_modified"]?.string : nil)
                if r.status == 404 {
                    try await db.transaction { try StudyCatalogStore.setState($0, "missing:" + url, ["at": .string(iso(now))]) }
                    missing += 1
                    continue
                }
                if r.status == 200 || r.status == 304 {
                    result = r
                    used = url
                    break
                }
                lastError = r.error ?? "HTTP \(r.status)"
            }
            guard let result, let used else {
                if missing > 0 && lastError == nil { continue }          // dieses Semester gibt es (noch) nicht
                let msg = messages["error_download"]!
                let err = lastError ?? "download"
                try await db.transaction { try StudyCatalogStore.setState($0, "attempt:" + key, ["at": .string(iso(now)), "error": .string(err), "message": .string(msg)]) }
                return try await save(db, merged(info, ["state": "error", "error": .string(err), "message": .string(msg),
                                                        "retry_at": .string(iso(now.addingTimeInterval(retryHours * 3600)))]))
            }
            if result.status == 304 {
                var extra: [String: JSONValue] = ["state": "ready", "origin": "local", "message": .string(messages["ready"]!)]
                if let plan = try await ensurePlan(db: db, env: env, key: key, university: uni, code: m.code, force: force) {
                    extra["study_plan"] = plan
                }
                return try await save(db, merged(info, extra))
            }
            // 6. lesen und pruefen
            _ = try await save(db, merged(info, ["state": "parsing", "message": .string(messages["parsing"]!)]))
            guard var meta = env.sources.meta(university: uni, code: m.code, term: term) else { continue }
            meta.sourceURL = used
            meta.fetchedAt = iso(now)
            meta.sha256 = SolutionSHA256.hex(result.data)
            guard let pages = env.pdfText(result.data) else {
                return try await parseError(db, key: key, info: info, error: "keine PDF", now: now)
            }
            let parsed = StudyCatalogParser.parse(pages: pages, meta: meta)
            let errors = StudyCatalogValidator.validate(parsed.catalog.json)
            guard errors.isEmpty, parsed.moduleCount > 0 else {
                return try await parseError(db, key: key, info: info, error: errors.prefix(5).joined(separator: "; ").isEmpty
                                            ? "keine Module gefunden" : errors.prefix(5).joined(separator: "; "), now: now)
            }
            // Studienverlaufsplan dazu (eigene Quelle im Register), vor dem Speichern und Teilen gemischt
            var payload = parsed.catalogDumps
            var planInfo: JSONValue?
            if let planURL = env.sources.studyPlanURL(university: uni, code: m.code) {
                let (mergedCatalog, plan) = try await attachPlan(db: db, env: env, catalog: parsed.catalog, url: planURL, force: force)
                payload = mergedCatalog.dumps(ensureASCII: false)
                planInfo = plan
            }
            try await db.transaction { c in
                _ = try StudyCatalogStore.store(c, payload: payload, texts: parsed.texts.json, origin: "download", now: iso(now))
                var http: [String: JSONValue] = [:]
                http["etag"] = result.etag.map { .string($0) } ?? .null
                http["last_modified"] = result.lastModified.map { .string($0) } ?? .null
                try StudyCatalogStore.setState(c, "http:" + used, .object(http))
            }
            // 7. Fakten teilen (ohne Modultexte); Fehler aendern den Stand nicht
            var shared: JSONValue = .bool(false)
            if let lib = env.library, let ok = try? await lib.publish(key: key, meta: meta, payload: payload) { shared = .bool(ok) }
            var extra: [String: JSONValue] = ["state": "ready", "origin": "download", "message": .string(messages["ready"]!),
                                              "modules": .number(Double(parsed.moduleCount)), "source_url": .string(used), "shared": shared]
            if let planInfo { extra["study_plan"] = planInfo }
            return try await save(db, merged(info, extra))
        }
        return try await save(db, merged(base, ["state": "not_found", "reason": "no_catalog", "message": .string(messages["not_found"]!)]))
    }

    /// Katalogsemester zum Versuchen: die des Registers (laufendes zuerst, wenn neuer) und die des Grundstocks, neueste
    /// zuerst (Kataloge ausserhalb von modkat kennen ihr Semester nur aus dem Grundstock)
    static func terms(env: Environment, university: String, code: String, today: String) -> [String] {
        var out = env.sources.candidateTerms(university: university, code: code, today: today)
        for t in env.seed?.terms(university: university, code: code) ?? [] where !out.contains(t) { out.append(t) }
        return out.enumerated().sorted {
            let a = StudyCatalogText.termNumber($0.element) ?? 0, b = StudyCatalogText.termNumber($1.element) ?? 0
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
    }

    /// Fakten aus Grundstock oder Bibliothek: gueltig, passender Schluessel, mindestens ein Modul
    static func validPayload(_ p: String, key: String) -> JSONValue? {
        guard let j = try? JSONValue.parse(p), StudyCatalogValidator.validate(j).isEmpty, StudyCatalogStore.key(of: j) == key,
              !(j["modules"]?.array ?? []).isEmpty else { return nil }
        return j
    }

    /// Studienverlaufsplan einmal laden (ohne Cookies, ETag/304, 404 wird 30 Tage gemerkt, Fehler erst nach 24 Stunden
    /// erneut), lesen, in `study_catalog_state` ablegen (`plan:<url>`) und in den Katalog mischen (`attach_study_plan`).
    /// Ergebnis: (Katalog, Stand {state: merged|missing|error, url, entries, slots, unmatched, error}).
    static func attachPlan(db: SQLiteDatabase, env: Environment, catalog: PyJSON, url: String, force: Bool) async throws -> (PyJSON, JSONValue) {
        let now = env.now()
        var info: [String: JSONValue] = ["url": .string(url)]
        let (miss, attempt, stored, cache) = try await db.transaction { c in
            (try StudyCatalogStore.state(c, "missing:" + url), try StudyCatalogStore.state(c, "plan_attempt:" + url),
             try StudyCatalogStore.state(c, "plan:" + url), try StudyCatalogStore.state(c, "http:" + url))
        }
        if let at = date(miss?["at"]?.string), now.timeIntervalSince(at) < missingDays * 86400 {
            info["state"] = "missing"
            return (catalog, .object(info))
        }
        if !force, let at = date(attempt?["at"]?.string), now.timeIntervalSince(at) < retryHours * 3600, attempt?["error"] != nil {
            info["state"] = "error"
            info["error"] = attempt?["error"] ?? .null
            return (catalog, .object(info))
        }
        func fail(_ error: String) async throws -> (PyJSON, JSONValue) {
            try await db.transaction { try StudyCatalogStore.setState($0, "plan_attempt:" + url, ["at": .string(iso(now)), "error": .string(error)]) }
            info["state"] = "error"
            info["error"] = .string(error)
            return (catalog, .object(info))
        }
        let storedPlan = stored?["plan_dumps"]?.string.flatMap { try? PyJSON.parse($0) }
        let storedSource = stored?["source"]?.object
        let have = storedPlan != nil && storedSource != nil
        let r = await env.loader.fetch(url: url, etag: have ? cache?["etag"]?.string : nil, lastModified: have ? cache?["last_modified"]?.string : nil)
        let plan: PyJSON
        let source: (url: String, fetchedAt: String?, sha256: String?)
        if r.status == 404 {
            try await db.transaction { try StudyCatalogStore.setState($0, "missing:" + url, ["at": .string(iso(now))]) }
            info["state"] = "missing"
            return (catalog, .object(info))
        } else if r.status == 304, have, let p = storedPlan, let src = storedSource {
            plan = p
            source = (src["url"]?.string ?? url, src["fetched_at"]?.string, src["sha256"]?.string)
        } else if r.status == 200 {
            plan = env.planText(r.data).map { StudyPlanSheet.parse(pages: $0) } ?? .object([])
            guard !(plan.planMember("entries")?.planArray ?? []).isEmpty else { return try await fail("keine Module im Studienverlaufsplan") }
            source = (url, iso(now), SolutionSHA256.hex(r.data))
            try await db.transaction { c in
                try StudyCatalogStore.setState(c, "plan:" + url, ["plan_dumps": .string(plan.dumps(ensureASCII: false)),
                                                                  "source": ["url": .string(url), "fetched_at": .string(iso(now)),
                                                                             "sha256": .string(source.sha256 ?? "")]])
                var http: [String: JSONValue] = [:]
                http["etag"] = r.etag.map { .string($0) } ?? .null
                http["last_modified"] = r.lastModified.map { .string($0) } ?? .null
                try StudyCatalogStore.setState(c, "http:" + url, .object(http))
            }
        } else {
            return try await fail(r.error ?? "HTTP \(r.status)")
        }
        let (mergedCatalog, unmatched) = StudyPlanSheet.merge(catalog: catalog, plan: plan, source: source)
        let errors = StudyCatalogValidator.validate(mergedCatalog.json)
        guard errors.isEmpty else { return try await fail(errors.prefix(5).joined(separator: "; ")) }
        info["state"] = "merged"
        info["entries"] = .number(Double(plan.planMember("entries")?.planArray?.count ?? 0))
        info["slots"] = .number(Double(mergedCatalog.planMember("plan_slots")?.planArray?.count ?? 0))
        info["unmatched"] = .array(unmatched.map { .string($0) })
        return (mergedCatalog, .object(info))
    }

    /// Gespeicherter Katalog ohne Verlaufsplan (aelterer Stand oder Bibliothek): Plan einmal nachladen und mischen
    static func ensurePlan(db: SQLiteDatabase, env: Environment, key: String, university: String, code: String, force: Bool) async throws -> JSONValue? {
        guard let url = env.sources.studyPlanURL(university: university, code: code),
              let row = try await db.transaction({ try StudyCatalogStore.payload($0, key: key) }),
              let catalog = try? PyJSON.parse(row.payload) else { return nil }
        if case .object? = catalog.planMember("study_plan") { return nil }
        let (mergedCatalog, info) = try await attachPlan(db: db, env: env, catalog: catalog, url: url, force: force)
        if info["state"]?.string == "merged" {
            let payload = mergedCatalog.dumps(ensureASCII: false)
            try await db.transaction { _ = try StudyCatalogStore.store($0, payload: payload, texts: nil, origin: row.origin, now: iso(env.now())) }
        }
        return info
    }

    static func parseError(_ db: SQLiteDatabase, key: String, info: [String: JSONValue], error: String, now: Date,
                           message: String = messages["error_parse"]!, reason: String? = nil) async throws -> JSONValue {
        let err = StudyCatalogText.prefix(error, 200)
        try await db.transaction { try StudyCatalogStore.setState($0, "attempt:" + key, ["at": .string(iso(now)), "error": .string(err), "message": .string(message)]) }
        var extra: [String: JSONValue] = ["state": "error", "error": .string(err), "message": .string(message),
                                          "retry_at": .string(iso(now.addingTimeInterval(retryHours * 3600)))]
        if let reason { extra["reason"] = .string(reason) }
        return try await save(db, merged(info, extra))
    }

    /// Eigener Link (`catalog_url`): einmal laden (Fehler erst nach 24 Stunden erneut), mit dem LUH-Parser lesen; liefert
    /// er keine Module, meldet der Stand "Format unbekannt". Kopf aus dem Register (modkat-Link mit bekanntem Kuerzel),
    /// sonst aus der Titelseite. Eigene Links gehen nicht in die Bibliothek.
    static func runCustom(url: String, db: SQLiteDatabase, env: Environment, base: [String: JSONValue], university: String,
                          label: String?, force: Bool) async throws -> JSONValue {
        let now = env.now()
        let parts = modkatParts(url)
        let urlKey = "url:" + url
        var info = base
        info["catalog_url"] = .string(url)
        info["origin_kind"] = "custom"
        let previous = try await db.transaction { try StudyCatalogStore.state($0, urlKey) }
        if !force, let k = previous?["key"]?.string, try await db.transaction({ try StudyCatalogStore.catalog($0, key: k) }) != nil {
            return try await save(db, merged(info, ["state": "ready", "origin": "local", "key": .string(k), "message": .string(messages["ready"]!)]))
        }
        if !force, let at = date(previous?["at"]?.string), now.timeIntervalSince(at) < retryHours * 3600, previous?["error"] != nil {
            return try await save(db, merged(info, ["state": "error", "error": previous?["error"] ?? .null, "reason": previous?["reason"] ?? .null,
                                                    "message": previous?["message"] ?? .null,
                                                    "retry_at": .string(iso(at.addingTimeInterval(retryHours * 3600)))]))
        }
        func fail(_ error: String, _ reason: String, _ msg: String) async throws -> JSONValue {
            try await db.transaction { try StudyCatalogStore.setState($0, urlKey, ["at": .string(iso(now)), "error": .string(error),
                                                                                   "reason": .string(reason), "message": .string(msg)]) }
            return try await save(db, merged(info, ["state": "error", "error": .string(error), "reason": .string(reason), "message": .string(msg),
                                                    "retry_at": .string(iso(now.addingTimeInterval(retryHours * 3600)))]))
        }
        _ = try await save(db, merged(info, ["state": "downloading", "message": .string(messages["downloading"]!)]))
        let r = await env.loader.fetch(url: url, etag: nil, lastModified: nil)
        guard r.status == 200 else { return try await fail(r.error ?? "HTTP \(r.status)", "download", messages["error_download"]!) }
        guard let pages = env.pdfText(r.data) else { return try await fail("keine PDF", "unknown_format", messages["unknown_format"]!) }
        let clean = StudyCatalogParser.cleanPages(Array(pages.prefix(1)))
        let titleTerm = StudyCatalogText.termFromTitle((clean.first ?? []).joined(separator: " "))
        var meta: StudyCatalogMeta
        if let parts, let m = env.sources.meta(university: university, code: parts.code, term: parts.term) {
            meta = m
        } else {
            let lines = clean.first ?? []
            let idx = lines.firstIndex(of: "für den Studiengang")
            let programLine = idx.flatMap { $0 + 1 < lines.count ? lines[$0 + 1] : nil } ?? "Eigener Katalog"
            let program = StudyCatalogText.strip(programLine.components(separatedBy: " - ").first ?? programLine)
            let degree = programLine.contains("Master") ? "M.Sc." : (programLine.contains("Bachelor") ? "B.Sc." : "unbekannt")
            let code = parts?.code ?? ("link-" + String(SolutionSHA256.hex(Data(url.utf8)).prefix(12)))
            let term = parts?.term ?? titleTerm ?? StudyCatalogText.currentTerm(today: day(now))
            meta = StudyCatalogMeta(university: university, program: program, degree: degree, po: "eigener Link", code: code, catalogTerm: term)
        }
        meta.sourceURL = url
        meta.fetchedAt = iso(now)
        meta.sha256 = SolutionSHA256.hex(r.data)
        let parsed = StudyCatalogParser.parse(pages: pages, meta: meta)
        guard parsed.moduleCount > 0, StudyCatalogValidator.validate(parsed.catalog.json).isEmpty else {
            return try await fail("Format unbekannt", "unknown_format", messages["unknown_format"]!)
        }
        let key = try await db.transaction { c -> String in
            let k = try StudyCatalogStore.store(c, payload: parsed.catalogDumps, texts: parsed.texts.json, origin: "download", now: iso(now))
            try StudyCatalogStore.setState(c, urlKey, ["at": .string(iso(now)), "key": .string(k)])
            return k
        }
        return try await save(db, merged(info, ["state": "ready", "origin": "download", "key": .string(key), "program": .string(meta.program),
                                                "code": .string(meta.code), "catalog_term": .string(meta.catalogTerm),
                                                "modules": .number(Double(parsed.moduleCount)), "message": .string(messages["ready"]!)]))
    }
}

// MARK: Modultexte nachladen

extension StudyCatalogPipeline {
    /// Modultexte (Inhalt, Lernziele, Literatur; nur auf dem Geraet) eines Katalogs aus Grundstock oder Bibliothek
    /// nachladen, wenn jemand ein Modul oeffnet: die oeffentliche PDF der Quelle einmal je Katalog laden (ohne Cookies,
    /// ETag), mit dem modkat-Leser lesen und nur die Texte ablegen; die Fakten bleiben, wie sie sind. Andere Formate
    /// (luh-grundstock) liest das Geraet nicht: dort bleibt es bei den Fakten. Fehler: 24 Stunden Pause, 404: 30 Tage.
    /// Ergebnis: Stand {state: loaded|have|unsupported|missing|error|none, modules?, error?}.
    @discardableResult
    public static func loadTexts(db: SQLiteDatabase, env: Environment, key: String) async -> JSONValue {
        do {
            return try await performTexts(db: db, env: env, key: key)
        } catch {
            return ["state": "error", "error": .string(String(describing: error).prefix(200).description)]
        }
    }

    static func performTexts(db: SQLiteDatabase, env: Environment, key: String) async throws -> JSONValue {
        let now = env.now()
        let stateKey = "texts:" + key
        let (row, count, prev) = try await db.transaction { c in
            (try StudyCatalogStore.payload(c, key: key), try StudyCatalogStore.textCount(c, key: key), try StudyCatalogStore.state(c, stateKey))
        }
        guard let row, let cat = try? JSONValue.parse(row.payload) else { return ["state": "none"] }
        if count > 0 { return ["state": "have", "modules": .number(Double(count))] }
        func remember(_ v: JSONValue) async throws -> JSONValue {
            try await db.transaction { try StudyCatalogStore.setState($0, stateKey, v) }
            return v
        }
        if let s = prev?["state"]?.string, ["loaded", "unsupported"].contains(s) { return prev! }
        if prev?["state"]?.string == "missing", let at = date(prev?["at"]?.string), now.timeIntervalSince(at) < missingDays * 86400 { return prev! }
        if prev?["state"]?.string == "error", let at = date(prev?["at"]?.string), now.timeIntervalSince(at) < retryHours * 3600 { return prev! }
        guard let url = cat["source"]?["url"]?.string, url.hasPrefix("https://"), modkatParts(url) != nil else {
            return try await remember(["state": "unsupported", "at": .string(iso(now))])
        }
        let cache = try await db.transaction { try StudyCatalogStore.state($0, "http:" + url) }
        let r = await env.loader.fetch(url: url, etag: cache?["etag"]?.string, lastModified: cache?["last_modified"]?.string)
        if r.status == 404 { return try await remember(["state": "missing", "at": .string(iso(now))]) }
        guard r.status == 200, let pages = env.pdfText(r.data) else {
            // 304 ohne lokale Texte (ETag aus einem frueheren Lauf): ohne Bedingung erneut erst nach 24 Stunden
            return try await remember(["state": "error", "at": .string(iso(now)), "error": .string(r.error ?? "HTTP \(r.status)")])
        }
        let meta = StudyCatalogMeta(university: cat["university"]?.string ?? "", program: cat["program"]?.string ?? "",
                                    degree: cat["degree"]?.string ?? "", po: StudySources.text(cat["po"]), code: cat["code"]?.string ?? "",
                                    catalogTerm: cat["catalog_term"]?.string ?? "", regularSemesters: cat["regular_semesters"]?.int,
                                    totalLP: cat["total_lp"]?.double, sourceURL: url)
        let parsed = StudyCatalogParser.parse(pages: pages, meta: meta)
        // Texte den gespeicherten Modulen zuordnen: gleiche id, sonst gleicher Titel
        let parsedTitles = Dictionary((parsed.catalog.json["modules"]?.array ?? []).compactMap { m -> (String, String)? in
            guard let id = m["id"]?.string, let t = m["title"]?.string else { return nil }
            return (StudyCatalogText.nameKey(t), id)
        }, uniquingKeysWith: { a, _ in a })
        let all = parsed.texts.json.object ?? [:]
        var texts: [String: JSONValue] = [:]
        for m in cat["modules"]?.array ?? [] {
            guard let id = m["id"]?.string else { continue }
            let pid = all[id] != nil ? id : parsedTitles[StudyCatalogText.nameKey(m["title"]?.string ?? "")]
            if let pid, let t = all[pid] { texts[id] = t }
        }
        guard !texts.isEmpty else { return try await remember(["state": "error", "at": .string(iso(now)), "error": "keine Modultexte"]) }
        let found = texts
        try await db.transaction { c in
            try StudyCatalogStore.storeTexts(c, key: key, texts: found)
            var http: [String: JSONValue] = [:]
            http["etag"] = r.etag.map { .string($0) } ?? .null
            http["last_modified"] = r.lastModified.map { .string($0) } ?? .null
            try StudyCatalogStore.setState(c, "http:" + url, .object(http))
        }
        return try await remember(["state": "loaded", "at": .string(iso(now)), "modules": .number(Double(texts.count)),
                                   "sha256": .string(SolutionSHA256.hex(r.data))])
    }

    /// Soll beim Oeffnen eines Moduls nachgeladen werden? Katalog ohne lokale Texte, Quelle lesbar (modkat), noch
    /// nicht geladen und keine laufende Pause
    public static func textsWanted(_ c: SQLiteConnection, key: String, now: Date) throws -> Bool {
        guard let row = try StudyCatalogStore.payload(c, key: key), try StudyCatalogStore.textCount(c, key: key) == 0,
              let cat = try? JSONValue.parse(row.payload), let url = cat["source"]?["url"]?.string, modkatParts(url) != nil else { return false }
        let prev = try StudyCatalogStore.state(c, "texts:" + key)
        switch prev?["state"]?.string {
        case "loaded"?, "unsupported"?: return false
        case "missing"?: return !(date(prev?["at"]?.string).map { now.timeIntervalSince($0) < missingDays * 86400 } ?? false)
        case "error"?: return !(date(prev?["at"]?.string).map { now.timeIntervalSince($0) < retryHours * 3600 } ?? false)
        default: return true
        }
    }
}

/// Ausloeser der Katalogsuche je Datenbank (Pfad): die App meldet hier ihren `StudyCatalogSync` an; der Kern stoesst
/// ihn an, wenn `GET /api/study-catalog/status` merkt, dass sich die Eingaben (QIS-Studiengang, bestaetigte PO,
/// eigener Link) seit dem letzten Lauf geaendert haben oder noch nie gesucht wurde. Ohne Anmeldung (PC, Tests) passiert nichts.
public enum StudyCatalogTriggers {
    public typealias Trigger = @Sendable (_ force: Bool) -> Void
    private static let lock = NSLock()
    nonisolated(unsafe) private static var triggers: [String: Trigger] = [:]

    /// Modultexte eines Katalogs nachladen (Bibliotheksschluessel); die App laedt im Hintergrund (`loadTexts`)
    public typealias TextsTrigger = @Sendable (_ key: String) -> Void
    nonisolated(unsafe) private static var textTriggers: [String: TextsTrigger] = [:]

    public static func register(databasePath: String, _ trigger: @escaping Trigger) { lock.withLock { triggers[databasePath] = trigger } }
    public static func unregister(databasePath: String) {
        lock.withLock {
            triggers.removeValue(forKey: databasePath)
            textTriggers.removeValue(forKey: databasePath)
        }
    }
    public static func registerTexts(databasePath: String, _ trigger: @escaping TextsTrigger) { lock.withLock { textTriggers[databasePath] = trigger } }

    /// true, wenn ein Ausloeser fuer Modultexte angemeldet ist (er laeuft dann im Hintergrund)
    @discardableResult
    public static func fireTexts(databasePath: String, key: String) -> Bool {
        guard let t = lock.withLock({ textTriggers[databasePath] }) else { return false }
        t(key)
        return true
    }

    /// true, wenn ein Ausloeser angemeldet ist (er laeuft dann im Hintergrund)
    @discardableResult
    public static func fire(databasePath: String, force: Bool = false) -> Bool {
        guard let t = lock.withLock({ triggers[databasePath] }) else { return false }
        t(force)
        return true
    }
}

extension StudyCatalogPipeline {
    /// Fingerabdruck der Eingaben eines Laufs: QIS-Studiengang, PO und eigener Link (steht im Stand als "inputs")
    public static func inputs(_ c: SQLiteConnection) throws -> String {
        let s = try planSettings(c)
        let parts: [JSONValue] = [try qisLabel(c).map { .string($0) } ?? .null, s["po"] ?? .null,
                                  cleanCatalogURL(s["catalog_url"]?.string).map { .string($0) } ?? .null]
        return JSONValue.array(parts).jsonString()
    }
}
