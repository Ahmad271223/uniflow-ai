import Foundation

/// Erklaerungsspeicher im lokalen Backend (docs/ERKLAERUNGSSPEICHER-2026-11-04.md): Schluessel der Seite, Nachsehen
/// (eigener Zwischenspeicher, dann der Dienst ohne KI), Speichern und Teilen einer Live-Antwort (naechster freier Platz,
/// sonst nur lokal) und das Vorwaermen der Stufe "Alles" (je Seite `explain`, bei Aufgaben `steps`).
public enum PageExplainBuilder {
    /// Datei-SHA, Datei-Schluessel und Seiten-Abdruck einer Seite
    public struct Key: Equatable, Sendable {
        public var fileSHA: String
        public var fileKey: String
        public var page: Int
        public var pageHash: String
        public init(fileSHA: String, fileKey: String, page: Int, pageHash: String) {
            self.fileSHA = fileSHA; self.fileKey = fileKey; self.page = page; self.pageHash = pageHash
        }
    }

    /// Was von einer Datei gebraucht wird: Kursdaten, SHA, Schluessel und die Seitentexte ohne Texterkennung (wie
    /// der Dokument-Index, damit der Abdruck derselbe ist)
    struct Source {
        let meta: DocIndexStore.FileMeta
        let sha: String
        let key: String
        let texts: [String]

        func key(page: Int) -> Key? {
            guard page >= 1, page <= texts.count else { return nil }
            return Key(fileSHA: sha, fileKey: key, page: page, pageHash: DocIndexFingerprint.pageHash(text: texts[page - 1], fileSHA: sha, page: page))
        }
    }

    /// nil ohne Datei auf dem Geraet, ohne SHA oder ohne Seitentext (dann gibt es nichts zu teilen)
    static func source(fileID: String, ctx: LocalContext) async throws -> Source? {
        guard let meta = try await ctx.database.withConnection({ try DocIndexStore.fileMeta($0, fileID: fileID, clock: ctx.clock) }) else { return nil }
        var sha = meta.sha
        if sha == nil, let p = meta.localPath, let files = ctx.files, files.exists(stored: p), let url = files.url(stored: p) { sha = ContentHash.file(url) }
        guard let sha, let key = DocIndexFingerprint.fileKey(fileSHA: sha) else { return nil }
        let texts = try await ScriptSearch.pageTexts(fileID: fileID, ctx: ctx, ocrScope: .none)
        guard !texts.isEmpty else { return nil }
        return Source(meta: meta, sha: sha, key: key, texts: texts)
    }

    /// Schluessel einer Seite; nil, wenn die Datei nicht auf dem Geraet liegt oder die Seite keinen Text hat
    public static func key(fileID: String, page: Int, ctx: LocalContext) async throws -> Key? {
        try await source(fileID: fileID, ctx: ctx)?.key(page: page)
    }

    /// Eine gespeicherte Antwort fuer die KI-Hilfe
    public struct Stored: Equatable, Sendable {
        public var text: String
        /// local (selbst gefragt, eigener Zwischenspeicher) | cloud (von jemand anderem, sofort da)
        public var source: String
        public var variant: Int
        public var createdAt: String

        public var json: JSONValue {
            ["stored": true, "source": .string(source), "variant": .number(Double(variant)), "created_at": .string(createdAt)]
        }
    }

    /// Nachsehen ohne KI: erst der eigene Zwischenspeicher, dann der Dienst (niedrigste lesbare Variante, wird lokal
    /// uebernommen). nil = nichts da, live fragen.
    public static func stored(key: Key, mode: String, ctx: LocalContext, cloud: PageExplainCloud?, cipher: SolutionCipher?) async -> Stored? {
        let local = (try? await ctx.database.withConnection { try PageExplainStore.rows($0, fileSHA: key.fileSHA, page: key.page, mode: mode) }) ?? []
        if case .local(let i) = PageExplain.choose(local: local.map(\.entry), cloud: []) {
            let r = local[i]
            return Stored(text: r.text, source: r.source == "cloud" ? "cloud" : "local", variant: r.variant, createdAt: r.createdAt)
        }
        guard let cloud, let cipher, let records = try? await cloud.records(fileKey: key.fileKey, page: key.page, mode: mode) else { return nil }
        for r in records.sorted(by: { $0.variant < $1.variant }) where r.version == PageExplain.version {
            guard let content = try? PageExplainCrypto.open(r.payload, fileSHA: key.fileSHA, pageHash: key.pageHash, fileKey: key.fileKey, page: key.page,
                                                            mode: mode, variant: r.variant, cipher: cipher) else { continue }
            let now = ctx.clock.nowISO
            try? await ctx.database.transaction {
                try PageExplainStore.store($0, fileSHA: key.fileSHA, page: key.page, mode: mode, variant: r.variant, text: content.text, source: "cloud",
                                           shared: true, model: content.model, now: now)
            }
            return Stored(text: content.text, source: "cloud", variant: r.variant, createdAt: content.createdAt)
        }
        return nil
    }

    /// Ergebnis des Speicherns einer Live-Antwort
    public struct Saved: Equatable, Sendable {
        public var variant: Int
        public var shared: Bool
        public var json: JSONValue { ["stored": false, "variant": .number(Double(variant)), "shared": .bool(shared)] }
    }

    /// Live-Antwort lokal merken und teilen: naechster freier Platz (1...3), bei einem Wettlauf der naechste; sind alle
    /// belegt, ist der Dienst nicht erreichbar oder die Antwort zu lang, bleibt sie lokal (Variante 0). Quellenmarken
    /// werden vorher entfernt. Ein fremder Datensatz wird nie ueberschrieben.
    @discardableResult
    public static func store(answer: String, key: Key, mode: String, model: String?, ctx: LocalContext, cloud: PageExplainCloud?,
                             cipher: SolutionCipher?) async -> Saved {
        let text = PageExplain.shareableText(answer)
        let now = ctx.clock.nowISO
        var variant = PageExplain.localOnlyVariant, shared = false
        if !text.isEmpty, text.count <= PageExplain.maxTextChars, let cloud, let cipher,
           let existing = try? await cloud.records(fileKey: key.fileKey, page: key.page, mode: mode) {
            for v in PageExplain.freeVariants(existing: Set(existing.map(\.variant))) {
                let content = PageExplainContent(page: key.page, pageHash: key.pageHash, mode: mode, variant: v, text: text, model: model, createdAt: now)
                guard let payload = try? PageExplainCrypto.seal(content, fileSHA: key.fileSHA, pageHash: key.pageHash, fileKey: key.fileKey, cipher: cipher),
                      let ok = try? await cloud.save(PageExplainRecord(fileKey: key.fileKey, page: key.page, mode: mode, variant: v, payload: payload, createdAt: now))
                else { break }                                   // Dienst nicht erreichbar: lokal lassen
                if ok { variant = v; shared = true; break }      // Platz inzwischen belegt: den naechsten versuchen
            }
        }
        let saved = Saved(variant: variant, shared: shared)
        guard !text.isEmpty else { return saved }
        try? await ctx.database.transaction {
            try PageExplainStore.store($0, fileSHA: key.fileSHA, page: key.page, mode: mode, variant: saved.variant, text: text, source: "ai",
                                       shared: saved.shared, model: model, now: now)
        }
        return saved
    }

    /// Einordnung der Seite aus der Bibliothek (`page_index`) fuer den Prompt einer eigenen Frage; leer ohne Eintrag
    static func indexContext(_ c: SQLiteConnection, key: Key) throws -> String {
        guard let row = try DocIndexStore.row(c, fileSHA: key.fileSHA, page: key.page), row.isOK,
              let rec = row.content.flatMap(DocIndexPageRecord.init(json:)) else { return "" }
        return PageExplain.indexContext(rec.entry)
    }

    // MARK: Vorwaermen (Stufe "Alles")

    public struct Report: Equatable, Sendable {
        public var fileID: String
        public var planned = 0
        /// aus dem eigenen Zwischenspeicher oder vom Dienst (keine KI)
        public var adopted = 0
        public var built = 0
        public var shared = 0
        public var skipped = 0
        public var aiCalls = 0
        public var log: [String] = []
        public init(fileID: String) { self.fileID = fileID }
    }

    /// Seiten mit Aufgaben laut Dokument-Index (nur Seiten mit Eintrag)
    static func pagesWithTasks(_ c: SQLiteConnection, fileSHA: String) throws -> Set<Int> {
        Set(try DocIndexStore.rows(c, fileSHA: fileSHA).compactMap { row -> Int? in
            guard row.page >= 1, row.isOK, let rec = row.content.flatMap(DocIndexPageRecord.init(json:)), !rec.entry.tasks.isEmpty else { return nil }
            return row.page
        })
    }

    /// Was fuer diese Datei noch fehlt (leer = fertig oder Stufe `basic`)
    static func plan(_ c: SQLiteConnection, source: Source, level: DocIndexPrewarmLevel) throws -> [PageExplain.PlanItem] {
        PageExplain.prewarmPlan(level: level, pageCount: source.texts.count, pagesWithTasks: try pagesWithTasks(c, fileSHA: source.sha),
                                have: try PageExplainStore.have(c, fileSHA: source.sha))
    }

    /// Fuer eine Datei alle fehlenden Erklaerungen erzeugen und teilen: je Punkt erst nachsehen (lokal, Dienst), dann
    /// live mit dem Prompt der KI-Hilfe (nur Kurs, Datei, Seite und Seitentext - keine Quellen, kein Stud.IP, damit die
    /// Antwort fuer alle passt). `shouldStop` beendet zwischen zwei Punkten; Fehler der KI, bei denen Wiederholen nichts
    /// bringt, beenden den Lauf (`DocIndexBuilder.isFatal`).
    public static func prewarm(fileID: String, ctx: LocalContext, ai: AIProvider, cloud: PageExplainCloud?, cipher: SolutionCipher?,
                               shouldStop: @escaping @Sendable () -> Bool = { false }) async throws -> Report {
        var report = Report(fileID: fileID)
        guard let src = try await source(fileID: fileID, ctx: ctx) else { return report }
        let items = try await ctx.database.withConnection { try plan($0, source: src, level: .full) }
        report.planned = items.count
        for (i, item) in items.enumerated() {
            if shouldStop() {
                report.skipped += items.count - i
                report.log.append("Abbruch vor Seite \(item.page) (\(item.mode)), später weiter")
                break
            }
            guard let key = src.key(page: item.page) else { continue }
            if await stored(key: key, mode: item.mode, ctx: ctx, cloud: cloud, cipher: cipher) != nil {
                report.adopted += 1
                continue
            }
            let prompt = AIPrompts.tutor(mode: item.mode, pageText: src.texts[item.page - 1], course: src.meta.courseTitle, fileName: src.meta.name,
                                         page: .int(String(item.page)))
            report.aiCalls += 1
            let answer: String
            do {
                answer = try await ai.answer(system: AIPromptTexts.tutorSystem, prompt: prompt)
            } catch let e as AIError {
                report.log.append("Seite \(item.page) (\(item.mode)): \(e.message)")
                if DocIndexBuilder.isFatal(e) { throw e }
                continue
            }
            let saved = await store(answer: answer, key: key, mode: item.mode, model: nil, ctx: ctx, cloud: cloud, cipher: cipher)
            report.built += 1
            if saved.shared { report.shared += 1 }
        }
        return report
    }
}
