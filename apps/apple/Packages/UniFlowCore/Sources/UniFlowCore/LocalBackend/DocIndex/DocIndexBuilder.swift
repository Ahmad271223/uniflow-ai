import Foundation

/// Anschluss des Dokument-Index an das lokale Backend (wie `LocalAI`/`LocalOCR`): die App setzt den Dienst (CloudKit),
/// die Verschluesselung (CryptoKit) und den Weg zur Bild-KI; ohne sie (Kern unter Linux, Tests) gibt es nur den
/// lokalen Zwischenspeicher und Text-Anfragen.
public final class LocalDocIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var _cloud: DocIndexCloud?
    private var _explainCloud: PageExplainCloud?
    private var _cipher: SolutionCipher?
    private var _makeAI: @Sendable (AIProvider) -> DocIndexAI = { TextDocIndexAI($0) }
    private var running: Set<String> = []

    public init() {}

    public var cloud: DocIndexCloud? { lock.withLock { _cloud } }
    /// Erklaerungsspeicher beim Dienst (CloudKit `PageExplain`); nil = Antworten bleiben auf dem Geraet
    public var explainCloud: PageExplainCloud? { lock.withLock { _explainCloud } }
    public var cipher: SolutionCipher? { lock.withLock { _cipher } }

    public func configure(cloud: DocIndexCloud?, cipher: SolutionCipher?, makeAI: (@Sendable (AIProvider) -> DocIndexAI)? = nil,
                          explainCloud: PageExplainCloud? = nil) {
        lock.withLock {
            _cloud = cloud
            _explainCloud = explainCloud
            _cipher = cipher
            if let makeAI { _makeAI = makeAI }
        }
    }

    /// Index-KI aus der KI des Backends (nil ohne verbundene KI: lesen geht trotzdem)
    public func ai(from provider: AIProvider?) -> DocIndexAI? {
        guard let provider else { return nil }
        if let direct = provider as? DocIndexAI { return direct }
        return lock.withLock { _makeAI }(provider)
    }

    /// Hoechstens ein Aufbau je Datei zugleich (Vorwaermen und Oeffnen derselben Datei)
    func begin(_ fileID: String) -> Bool { lock.withLock { running.insert(fileID).inserted } }
    func end(_ fileID: String) { lock.withLock { _ = running.remove(fileID) } }
    public var isBusy: Bool { lock.withLock { !running.isEmpty } }
}

public struct DocIndexBuildOptions: Sendable {
    /// vorhandene Eintraege neu bauen ("Neu erklaeren lassen")
    public var force = false
    /// Seiten mit Abbildungen, Tabellen, Formeln oder Scans als Text + Bild
    public var withImage = true
    /// Bild in voller Aufloesung
    public var fullImage = false
    /// sparsames Modell (Vorwaermen im Hintergrund)
    public var small = false
    /// Loesungen der Aufgaben mitliefern (nur auf ausdruecklichen Wunsch; dann ebenfalls geteilt)
    public var withSolutions = false
    /// nur diese Seiten (1-basiert); nil = alle
    public var pages: Set<Int>?

    public init(force: Bool = false, withImage: Bool = true, fullImage: Bool = false, small: Bool = false, withSolutions: Bool = false, pages: Set<Int>? = nil) {
        self.force = force; self.withImage = withImage; self.fullImage = fullImage; self.small = small; self.withSolutions = withSolutions; self.pages = pages
    }
}

/// Was ein Aufbau getan hat (fuer Antworten, Protokoll und Tests)
public struct DocIndexBuildReport: Equatable, Sendable {
    public var fileID: String
    public var fileSHA = ""
    public var fileKey = ""
    public var pageCount = 0
    /// Seiten, die schon da waren (lokal)
    public var known = 0
    /// aus der Bibliothek uebernommen (ohne KI)
    public var adopted = 0
    public var built = 0
    public var failed = 0
    /// nicht begonnen (Abbruch, zu viele Fehlversuche)
    public var skipped = 0
    public var aiCalls = 0
    /// Seiten offen, aber keine KI verbunden
    public var needsAI = false
    /// alle Seiten und die Zusammenfassung vorhanden
    public var complete = false
    public var log: [String] = []

    public init(fileID: String) { self.fileID = fileID }
}

/// Verweis von einem Element der Seite auf dasselbe Element an anderer Stelle des Moduls ("auch in Vorlesung 2, Seite 12")
public struct DocIndexCrossRef: Equatable, Sendable {
    public var order: Int
    public var fileID: String
    public var page: Int
    public var label: String
    public var title: String
    public var text: String

    public var json: JSONValue {
        ["order": .number(Double(order)), "file_id": .string(fileID), "page": .number(Double(page)), "label": .string(label),
         "title": .string(title), "text": .string(text)]
    }
}

/// Aufbau des Index einer Datei: erst "kenne ich schon?" (lokal, dann die Bibliothek nach Datei-Abdruck), dann nur die
/// fehlenden Seiten mit der KI (Text, bei Abbildungen Text + Bild), jede Antwort gegen das Schema geprueft (hoechstens
/// zwei Wiederholungen), gespeichert und verschluesselt geteilt. Eine bekannte Datei wird nie noch einmal analysiert,
/// eine bekannte Seite nie noch einmal gesendet.
public enum DocIndexBuilder {
    /// KI-Fehler, bei denen Wiederholen nichts bringt (Kontingent, Anmeldung, nicht erreichbar): der Lauf endet
    static let fatalCodes: Set<String> = ["chatgpt_limit", "chatgpt_login_needed", "chatgpt_not_enabled", "chatgpt_refresh_not_ready",
                                          "ai_provider_unreachable", "chatgpt_unreachable", "chatgpt_http_error"]

    public static func isFatal(_ e: AIError) -> Bool { fatalCodes.contains(e.code) }

    /// Lokale Datei, Datei-SHA und Seitentexte einer Datei (ohne KI); wirft 404 ohne Datei oder Seitentext
    struct Source {
        let meta: DocIndexStore.FileMeta
        let url: URL?
        let sha: String
        let key: String
        let texts: [String]
        let hashes: [String]
    }

    static func source(fileID: String, ctx: LocalContext) async throws -> Source {
        guard let meta = try await ctx.database.withConnection({ try DocIndexStore.fileMeta($0, fileID: fileID, clock: ctx.clock) }) else {
            throw LocalHTTPError.notFound("Datei nicht gefunden")
        }
        var url: URL?
        if let p = meta.localPath, let files = ctx.files, files.exists(stored: p) { url = files.url(stored: p) }
        var sha = meta.sha
        if sha == nil, let url {
            sha = ContentHash.file(url)
            if let sha {
                _ = try? await ctx.database.execute("UPDATE files SET content_sha256=? WHERE id=? AND (content_sha256 IS NULL OR content_sha256='')",
                                                    [.text(sha), .text(fileID)])
            }
        }
        guard let sha, let key = DocIndexFingerprint.fileKey(fileSHA: sha) else {
            throw LocalHTTPError(status: 404, detail: ["detail": "Die Datei liegt nicht auf diesem Gerät.", "code": "no_file"])
        }
        let texts = try await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx, ocrScope: .none)
        guard !texts.isEmpty else {
            throw LocalHTTPError(status: 404, detail: ["detail": "Kein Seitentext vorhanden.", "code": "no_content"])
        }
        let hashes = texts.enumerated().map { DocIndexFingerprint.pageHash(text: $0.element, fileSHA: sha, page: $0.offset + 1) }
        return Source(meta: meta, url: url, sha: sha, key: key, texts: texts, hashes: hashes)
    }

    /// Bild der Seite fuer die KI, wenn die Seite Abbildungen, Tabellen, Formeln oder einen Scan zeigt; sonst nil
    static func image(for src: Source, page: Int, options: DocIndexBuildOptions) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard options.withImage, let url = src.url, let probe = DocIndexPages.probe(pdf: url, page: page, text: src.texts[page - 1]),
              probe.kind == .figure else { return nil }
        return DocIndexPages.renderJPEG(pdf: url, page: page, width: options.fullImage ? DocIndexPages.fullImageWidth : DocIndexPages.imageWidth)
        #else
        return nil
        #endif
    }

    /// Eintrag beim Dienst ablegen (verschluesselt); false mit Grund, wenn das gerade nicht geht (naechster Lauf holt es nach)
    static func share(_ content: JSONValue, page: Int, pageHash: String, src: Source, cloud: DocIndexCloud?, cipher: SolutionCipher?,
                      now: String) async -> String? {
        guard let cloud, let cipher else { return "kein Dienst" }
        do {
            let payload = try DocIndexCrypto.seal(content, fileSHA: src.sha, pageHash: pageHash, fileKey: src.key, page: page, cipher: cipher)
            try await cloud.save(DocIndexRecord(fileKey: src.key, page: page, payload: payload, createdAt: now))
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Aufbau fuer eine Datei (siehe oben). `cloud`/`cipher` nil = ohne Bibliothek (nur lokal); `ai` nil = nur
    /// uebernehmen, nichts bauen. `shouldStop` beendet den Lauf zwischen zwei Seiten (Hintergrund: Zeit um).
    public static func build(fileID: String, ctx: LocalContext, cloud: DocIndexCloud?, ai: DocIndexAI?, cipher: SolutionCipher?,
                             options: DocIndexBuildOptions = DocIndexBuildOptions(),
                             shouldStop: @escaping @Sendable () -> Bool = { false }) async throws -> DocIndexBuildReport {
        var report = DocIndexBuildReport(fileID: fileID)
        guard ctx.docIndex.begin(fileID) else {
            throw LocalHTTPError(status: 409, detail: ["detail": "Diese Datei wird gerade indexiert.", "code": "busy"])
        }
        defer { ctx.docIndex.end(fileID) }
        let src = try await source(fileID: fileID, ctx: ctx)
        let n = src.texts.count
        report.fileSHA = src.sha
        report.fileKey = src.key
        report.pageCount = n
        let db = ctx.database
        var rows = Dictionary(uniqueKeysWithValues: try await db.withConnection { try DocIndexStore.rows($0, fileSHA: src.sha) }.map { ($0.page, $0) })

        // 1. kenne ich schon? Erst lokal, dann die Bibliothek nach dem Datei-Abdruck (nie nach Inhalt)
        let knownLocally = Set(rows.filter { $0.key >= 1 && $0.value.isOK }.keys)
        let localComplete = rows[0]?.isOK == true && (1...max(1, n)).allSatisfy { rows[$0]?.isOK == true }
        if localComplete, !options.force {
            report.complete = true
            report.log.append("bereits bekannt: \(src.meta.name) (lokal)")
        } else if let cloud, let cipher {
            do {
                let records = try await cloud.records(fileKey: src.key)
                if !records.isEmpty { report.log.append("Bibliothek: \(records.count) Datensätze zu \(src.meta.name)") }
                let now = ctx.clock.nowISO
                var adoptedSummary = false
                for r in records.sorted(by: { $0.page < $1.page }) where r.version == DocIndexSchema.version {
                    if r.page == 0 {
                        guard rows[0]?.isOK != true || options.force else { continue }
                        let hash = DocIndexCrypto.summaryHash(pageHashes: src.hashes)
                        if let json = try? DocIndexCrypto.open(r.payload, fileSHA: src.sha, pageHash: hash, fileKey: src.key, page: 0, cipher: cipher),
                           let summary = DocIndexFileSummary(json: json), summary.pageCount == n {
                            try await db.transaction { try DocIndexStore.store($0, fileSHA: src.sha, page: 0, pageHash: hash, content: summary.json, source: "cloud", shared: true, now: now) }
                            rows[0] = try await db.withConnection { try DocIndexStore.row($0, fileSHA: src.sha, page: 0) }
                            adoptedSummary = true
                        } else {
                            report.log.append("Zusammenfassung passt nicht zu dieser Datei (anderer Stand)")
                        }
                        continue
                    }
                    guard r.page >= 1, r.page <= n, rows[r.page]?.isOK != true || options.force else { continue }
                    let hash = src.hashes[r.page - 1]
                    guard let json = try? DocIndexCrypto.open(r.payload, fileSHA: src.sha, pageHash: hash, fileKey: src.key, page: r.page, cipher: cipher),
                          let rec = DocIndexPageRecord(json: json), rec.pageHash == hash, rec.page == r.page else {
                        report.log.append("Seite \(r.page): Eintrag passt nicht zu dieser Seite")
                        continue
                    }
                    try await db.transaction { try DocIndexStore.store($0, fileSHA: src.sha, page: r.page, pageHash: hash, content: rec.json, source: "cloud", shared: true, now: now) }
                    rows[r.page] = try await db.withConnection { try DocIndexStore.row($0, fileSHA: src.sha, page: r.page) }
                    report.adopted += 1
                    report.log.append("Seite \(r.page) bereits bekannt (Bibliothek)")
                }
                if adoptedSummary { report.log.append("bereits bekannt: \(src.meta.name) (Bibliothek)") }
            } catch {
                report.log.append("Bibliothek nicht erreichbar: \(error)")
            }
        }

        // 2. offene Seiten
        let wanted = (1...max(1, n)).filter { options.pages?.contains($0) ?? true }
        var open: [Int] = []
        for p in wanted {
            if let row = rows[p], row.isOK, !options.force {
                if knownLocally.contains(p) { report.known += 1 }   // aus der Bibliothek uebernommene zaehlen als `adopted`
                continue
            }
            if let row = rows[p], row.status == "failed", row.attempts >= DocIndexStore.maxAttempts, !options.force {
                report.skipped += 1
                report.log.append("Seite \(p): nach \(row.attempts) Fehlversuchen ausgelassen")
                continue
            }
            open.append(p)
        }
        if report.known > 0, report.known != n || options.pages != nil { report.log.append("\(report.known) Seiten bereits bekannt (lokal)") }

        // 3. bauen
        if !open.isEmpty {
            guard let ai else {
                report.needsAI = true
                report.log.append("KI nicht verbunden: \(open.count) Seiten offen")
                return try await finish(report, src: src, rows: rows, ctx: ctx, cloud: cloud, cipher: cipher, options: options)
            }
            for (i, p) in open.enumerated() {
                if shouldStop() {
                    report.skipped += open.count - i
                    report.log.append("Abbruch vor Seite \(p) (später weiter)")
                    break
                }
                let image = image(for: src, page: p, options: options)
                let prompt = DocIndexPrompts.page(course: src.meta.courseTitle, fileName: src.meta.name, page: p, pageCount: n,
                                                  text: src.texts[p - 1], withImage: image != nil, withSolutions: options.withSolutions)
                var entry: DocIndexEntry?
                var lastError = ""
                for attempt in 1...DocIndexStore.maxAttempts {
                    report.aiCalls += 1
                    do {
                        let answer = try await ai.index(system: DocIndexPrompts.system, prompt: prompt, imageJPEG: image, schema: DocIndexSchema.aiSchema,
                                                        small: options.small)
                        entry = try DocIndexEntry.parse(answer: answer)
                        break
                    } catch let e as AIError {
                        if isFatal(e) { throw e }
                        lastError = e.message
                        report.log.append("Seite \(p), Versuch \(attempt): \(e.message)")
                    }
                }
                let now = ctx.clock.nowISO
                guard let entry else {
                    let attempts = try await db.transaction { try DocIndexStore.markFailed($0, fileSHA: src.sha, page: p, pageHash: src.hashes[p - 1], now: now) }
                    report.failed += 1
                    report.log.append("Seite \(p) gescheitert (\(attempts). Lauf): \(lastError)")
                    continue
                }
                let record = DocIndexPageRecord(page: p, pageHash: src.hashes[p - 1], entry: entry, withImage: image != nil,
                                                model: await ai.modelName, createdAt: now)
                try await db.transaction { try DocIndexStore.store($0, fileSHA: src.sha, page: p, pageHash: src.hashes[p - 1], content: record.json, source: "ai", shared: false, now: now) }
                if let why = await share(record.json, page: p, pageHash: src.hashes[p - 1], src: src, cloud: cloud, cipher: cipher, now: now) {
                    if cloud != nil { report.log.append("Seite \(p): Bibliothek nicht erreichbar (\(why)), später erneut") }
                } else {
                    try await db.transaction { try DocIndexStore.markShared($0, fileSHA: src.sha, page: p) }
                }
                report.built += 1
                rows[p] = try await db.withConnection { try DocIndexStore.row($0, fileSHA: src.sha, page: p) }
            }
        }
        return try await finish(report, src: src, rows: rows, ctx: ctx, cloud: cloud, cipher: cipher, options: options)
    }

    /// Zusammenfassung (Seite 0), wenn alle Seiten da sind; noch nicht geteilte eigene Eintraege nachreichen
    static func finish(_ input: DocIndexBuildReport, src: Source, rows: [Int: DocIndexStore.Row], ctx: LocalContext, cloud: DocIndexCloud?,
                       cipher: SolutionCipher?, options: DocIndexBuildOptions) async throws -> DocIndexBuildReport {
        var report = input
        let db = ctx.database
        let n = src.texts.count
        let allPages = (1...max(1, n)).allSatisfy { rows[$0]?.isOK == true }
        var rows = rows
        if allPages, rows[0]?.isOK != true || (options.force && options.pages == nil) {
            let now = ctx.clock.nowISO
            let overview = rows[1]?.content?["entry"]?["summary"]?.string
            let catalog = try await db.withConnection { try DocIndexStore.catalog($0, meta: src.meta) }
            let summary = DocIndexFileSummary(fileName: src.meta.name, title: src.meta.title, pageCount: n, pageHashes: src.hashes, overview: overview,
                                              catalog: catalog, createdAt: now)
            let hash = DocIndexCrypto.summaryHash(pageHashes: src.hashes)
            try await db.transaction { try DocIndexStore.store($0, fileSHA: src.sha, page: 0, pageHash: hash, content: summary.json, source: "ai", shared: false, now: now) }
            if await share(summary.json, page: 0, pageHash: hash, src: src, cloud: cloud, cipher: cipher, now: now) == nil {
                try await db.transaction { try DocIndexStore.markShared($0, fileSHA: src.sha, page: 0) }
            }
            rows[0] = try await db.withConnection { try DocIndexStore.row($0, fileSHA: src.sha, page: 0) }
            report.log.append("Zusammenfassung von \(src.meta.name) gespeichert")
        }
        // eigene Eintraege, die der Dienst noch nicht hat (offline gebaut)
        if cloud != nil, cipher != nil {
            for row in rows.values.sorted(by: { $0.page < $1.page }) where row.isOK && !row.shared && row.source == "ai" {
                guard let content = row.content else { continue }
                if await share(content, page: row.page, pageHash: row.pageHash, src: src, cloud: cloud, cipher: cipher, now: ctx.clock.nowISO) == nil {
                    try await db.transaction { try DocIndexStore.markShared($0, fileSHA: src.sha, page: row.page) }
                }
            }
        }
        report.complete = allPages && rows[0]?.isOK == true
        return report
    }

    // MARK: Vorwaermen

    /// so viele Dateien je Lauf hoechstens (Vorgabe des Inhabers); ein Lauf nimmt den naechsten Stand wieder auf
    public static let prewarmFilesPerRun = 3

    public struct PrewarmReport: Equatable, Sendable {
        public var candidates = 0
        public var started: [DocIndexBuildReport] = []
        /// Stufe "Alles": Erklaerungen je Datei (Erklaerungsspeicher)
        public var explained: [PageExplainBuilder.Report] = []
        public var stopped = false
        public var log: [String] = []
        public init() {}
    }

    /// Dateien der laufenden Lehrwoche (aktive Kurse, PDF auf dem Geraet), deren Index noch nicht vollstaendig ist;
    /// neueste zuerst, dann nach Kennung (feste Reihenfolge). Stufe `full`: auch Dateien mit Index, denen noch
    /// Erklaerungen fehlen (`PageExplain.prewarmPlan`)
    static func prewarmCandidates(_ c: SQLiteConnection, ctx: LocalContext, level: DocIndexPrewarmLevel = .basic) throws -> [DocIndexStore.FileMeta] {
        let dates = try LocalModules.Dates(c, clock: ctx.clock)
        let current = StudyWeeks.dayWeek(start: dates.start, day: dates.today, today: dates.today)
        let rows = try c.query(DocIndexStore.fileSQL + """
             WHERE f.deleted_at IS NULL AND c.active=1 AND f.course_id <> '__user__' AND COALESCE(f.local_path, '') <> ''
               AND (f.mime LIKE '%pdf' OR lower(f.name) LIKE '%.pdf') ORDER BY f.chdate DESC, f.id
            """)
        var out: [DocIndexStore.FileMeta] = []
        for r in rows {
            let m = try DocIndexStore.fileMeta(c, r, dates: dates)
            guard m.week == current, let p = m.localPath, ctx.files?.exists(stored: p) == true else { continue }
            if let sha = m.sha, let summary = try DocIndexStore.row(c, fileSHA: sha, page: 0), summary.isOK {
                guard level == .full, let n = summary.content?["pageCount"]?.int, n >= 1,
                      !PageExplain.prewarmPlan(level: level, pageCount: n, pagesWithTasks: try PageExplainBuilder.pagesWithTasks(c, fileSHA: sha),
                                               have: try PageExplainStore.have(c, fileSHA: sha)).isEmpty else { continue }
            }
            out.append(m)
        }
        return out
    }

    /// Nach dem Abgleich: fuer bis zu `maxFiles` Dateien der laufenden Woche den Index bauen (Text, sparsames Modell), erst
    /// die Bibliothek fragen. Ob jetzt ein guter Zeitpunkt ist (WLAN, Laden), entscheidet der Aufrufer; `shouldStop`
    /// beendet zwischen zwei Seiten, der naechste Lauf macht dort weiter. Fehler der KI (Kontingent) beenden den Lauf.
    /// Stufe `full` mit `tutorAI` (Schalter "Vorab einordnen: Alles"): dieselben Dateien bekommen danach je Seite eine
    /// Erklaerung und fuer Seiten mit Aufgaben eine Loesung, geteilt wie die Antworten der KI-Hilfe
    /// (`PageExplainBuilder.prewarm`); `basic` aendert nichts am bisherigen Lauf.
    public static func prewarm(ctx: LocalContext, cloud: DocIndexCloud?, ai: DocIndexAI?, cipher: SolutionCipher?,
                               maxFiles: Int = prewarmFilesPerRun, level: DocIndexPrewarmLevel = .basic, tutorAI: AIProvider? = nil,
                               shouldStop: @escaping @Sendable () -> Bool = { false }) async -> PrewarmReport {
        var report = PrewarmReport()
        let full = level == .full && tutorAI != nil
        let candidates = (try? await ctx.database.withConnection { try prewarmCandidates($0, ctx: ctx, level: full ? .full : .basic) }) ?? []
        report.candidates = candidates.count
        for m in candidates.prefix(max(0, maxFiles)) {
            if shouldStop() { report.stopped = true; break }
            do {
                let r = try await build(fileID: m.fileID, ctx: ctx, cloud: cloud, ai: ai, cipher: cipher,
                                        options: DocIndexBuildOptions(withImage: false, small: true), shouldStop: shouldStop)
                report.started.append(r)
                if r.skipped > 0, shouldStop() { report.stopped = true; break }
                if full, let tutorAI {
                    let e = try await PageExplainBuilder.prewarm(fileID: m.fileID, ctx: ctx, ai: tutorAI, cloud: ctx.docIndex.explainCloud,
                                                                 cipher: cipher, shouldStop: shouldStop)
                    report.explained.append(e)
                    if e.skipped > 0, shouldStop() { report.stopped = true; break }
                }
            } catch let e as AIError {
                report.log.append("\(m.name): \(e.message)")
                if isFatal(e) { report.stopped = true; break }
            } catch {
                report.log.append("\(m.name): \(error)")
            }
        }
        return report
    }

    // MARK: Querverweise innerhalb des Moduls

    /// Woerter eines Titels fuer den Vergleich (Wortstaemme wie die Skriptsuche)
    static func titleTokens(_ s: String) -> Set<String> { Set(ScriptSearch.tokens(s)) }

    /// Gleiches Element? Gleicher normalisierter Titel, oder gleiche Art und die Titelwoerter stimmen zu 60 % ueberein
    static func sameElement(_ a: DocIndexElement, _ b: DocIndexElement) -> Bool {
        let na = DocIndexFingerprint.normalize(a.title), nb = DocIndexFingerprint.normalize(b.title)
        if !na.isEmpty, na == nb { return true }
        guard a.type == b.type else { return false }
        let ta = titleTokens(a.title), tb = titleTokens(b.title)
        guard ta.count >= 2, tb.count >= 2 else { return false }
        let inter = ta.intersection(tb).count, union = ta.union(tb).count
        return union > 0 && Double(inter) / Double(union) >= 0.6
    }

    /// Verweise fuer die Elemente einer Seite auf andere indexierte Seiten desselben Moduls (eigene Dateien, lokaler
    /// Zwischenspeicher): feste Reihenfolge (Woche, Dateiname, Seite, Element), hoechstens drei je Element
    static func crossRefs(_ c: SQLiteConnection, fileID: String, fileSHA: String, page: Int, entry: DocIndexEntry, moduleID: Int?,
                          clock: UniFlowClock, limitPerElement: Int = 3) throws -> [DocIndexCrossRef] {
        guard try DocIndexStore.hasTable(c), !entry.elements.isEmpty else { return [] }
        var sql = DocIndexStore.fileSQL + " WHERE f.deleted_at IS NULL AND f.content_sha256 IS NOT NULL AND (f.content_sha256=?"
        var params: [SQLiteValue] = [.text(fileSHA)]
        if let moduleID { sql += " OR c.module_id=?"; params.append(.integer(Int64(moduleID))) }
        sql += ") ORDER BY (f.id=?) DESC, f.name, f.id"
        params.append(.text(fileID))
        let dates = try LocalModules.Dates(c, clock: clock)
        var files: [String: DocIndexStore.FileMeta] = [:]              // eine Datei je SHA (die eigene zuerst)
        for r in try c.query(sql, params) {
            let m = try DocIndexStore.fileMeta(c, r, dates: dates)
            if let sha = m.sha, files[sha] == nil { files[sha] = m }
        }
        guard !files.isEmpty else { return [] }
        struct Other { let meta: DocIndexStore.FileMeta; let page: Int; let elements: [DocIndexElement] }
        var others: [Other] = []
        for (sha, m) in files {
            for row in try DocIndexStore.rows(c, fileSHA: sha) where row.page > 0 && row.isOK && !(sha == fileSHA && row.page == page) {
                guard let rec = row.content.flatMap(DocIndexPageRecord.init(json:)) else { continue }
                others.append(Other(meta: m, page: row.page, elements: rec.entry.elements))
            }
        }
        others.sort { a, b in
            let ka = (a.meta.week, a.meta.name, a.meta.fileID, a.page), kb = (b.meta.week, b.meta.name, b.meta.fileID, b.page)
            return ka < kb
        }
        var out: [DocIndexCrossRef] = []
        for e in entry.elements {
            var found = 0
            for o in others {
                guard found < limitPerElement, let hit = o.elements.first(where: { sameElement(e, $0) }) else { continue }
                let same = o.meta.sha == fileSHA
                let label = same ? "" : (o.meta.week >= 1 ? "\(o.meta.kind.label) \(o.meta.week)" : o.meta.displayTitle)
                let text = same ? "auch auf Seite \(o.page)" : "auch in \(label), Seite \(o.page)"
                out.append(DocIndexCrossRef(order: e.order, fileID: o.meta.fileID, page: o.page, label: label, title: hit.title, text: text))
                found += 1
            }
        }
        return out
    }
}
