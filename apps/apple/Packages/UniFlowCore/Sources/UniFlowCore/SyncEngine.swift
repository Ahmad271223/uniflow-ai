import Foundation

// MARK: - Schnittstelle zum Server

public protocol AnnotationTransport: Sendable {
    func fetch(documentID: String) async throws -> ServerSnapshot
    /// Speichert den ganzen Stand. Antwortet der Server mit 409, kommt `.conflict` mit dem neueren Serverstand.
    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome
}

public struct ServerSnapshot: Equatable, Sendable {
    public var version: Int
    public var root: JSONValue

    public init(version: Int, root: JSONValue) {
        self.version = version
        self.root = root
    }
}

public enum PutOutcome: Equatable, Sendable {
    case saved(version: Int)
    case conflict(ServerSnapshot)
}

/// Fehler des Transports mit HTTP-Status (z. B. `APIError` der App). Fehler ohne Status gelten als Netzfehler.
public protocol HTTPStatusError: Error {
    var httpStatus: Int { get }
    /// Text aus "detail" der Antwort, falls vorhanden
    var httpDetail: String? { get }
}

extension HTTPStatusError {
    public var httpDetail: String? { nil }
}

// MARK: - Status

public enum SyncStatus: Equatable, Sendable {
    case loading
    case saved
    case pending(pages: Int)
    case uploading(pages: Int)
    case offline(pages: Int)
    case localSaveFailed(String)
    case conflictUnresolved(String)

    /// Alle Aenderungen liegen mindestens lokal sicher.
    public var isSafeLocally: Bool {
        switch self {
        case .loading, .localSaveFailed: return false
        default: return true
        }
    }

    public var label: String {
        switch self {
        case .loading: return "Lädt…"
        case .saved: return "Gespeichert"
        case .pending(let n): return "Lokal gesichert · \(n) \(n == 1 ? "Seite wartet" : "Seiten warten")"
        case .uploading: return "Speichert…"
        case .offline(let n): return "Offline · \(n) \(n == 1 ? "Seite" : "Seiten") lokal gesichert"
        case .localSaveFailed(let m): return "Nicht gesichert: \(m)"
        case .conflictUnresolved(let m): return "Konflikt: \(m)"
        }
    }
}

/// Zusaetzlicher Zustand fuer die Oberflaeche (neben `SyncStatus`): warum nicht hochgeladen wird bzw. dass
/// zusammengefuehrt wurde. Lokal gesichert ist in allen Faellen alles.
public enum SyncIssue: Equatable, Sendable {
    /// Server nicht erreichbar (echter Netzfehler); Wiederholung mit wachsendem Abstand (2 s … 60 s).
    case offline
    /// 401: PIN fehlt oder ist falsch. Keine automatische Wiederholung.
    case pinFehlt
    /// 403: Zugriff verweigert (z. B. nicht aus dem eigenen Netz). Keine automatische Wiederholung.
    case zugriffVerweigert
    /// 5xx oder andere unerwartete Antwort; Wiederholung mit wachsendem Abstand (2 s … 5 min).
    case serverfehler(Int)
    /// Bei der Zusammenfuehrung mit dem Server mussten so viele Objekte entschieden werden.
    case konflikteZusammengefuehrt(Int)
    /// 409 ohne neueren Stand: Die Datenquelle kann (noch) nicht speichern, z. B. das lokale Backend vor S3. Keine
    /// automatische Wiederholung; die Meldung kommt aus "detail".
    case nichtVerfuegbar(String)

    /// Einordnung eines Transportfehlers: 401/403 sind nie "Offline", nur Fehler ohne HTTP-Antwort sind es.
    public static func classify(_ error: Error) -> SyncIssue {
        guard let e = error as? HTTPStatusError, e.httpStatus > 0 else { return .offline }
        switch e.httpStatus {
        case 401: return .pinFehlt
        case 403: return .zugriffVerweigert
        case 409: return .nichtVerfuegbar(e.httpDetail ?? "Speichern ist hier noch nicht möglich")
        default: return .serverfehler(e.httpStatus)
        }
    }

    /// Wird erst nach einer ausdruecklichen Anfrage (`requestUpload`, `syncNow`) erneut versucht.
    public var needsUserAction: Bool {
        switch self {
        case .pinFehlt, .zugriffVerweigert, .nichtVerfuegbar: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .offline: return "Offline – Änderungen sind lokal gesichert"
        case .pinFehlt: return "PIN fehlt oder ist falsch – Änderungen sind lokal gesichert"
        case .zugriffVerweigert: return "Zugriff verweigert – Änderungen sind lokal gesichert"
        case .serverfehler(let code): return "Serverfehler (\(code)) – neuer Versuch folgt"
        case .konflikteZusammengefuehrt(let n): return n == 1 ? "1 Konflikt zusammengeführt" : "\(n) Konflikte zusammengeführt"
        case .nichtVerfuegbar(let m): return m
        }
    }
}

public struct SyncStats: Equatable, Sendable {
    public var puts = 0
    public var conflicts = 0
    public var mergedConflicts = 0
    public var localWriteFailures = 0
}

// MARK: - Synchronisierung

/// Lokales Sichern und Hochladen eines Notizdokuments, getrennt von der Stifteingabe.
///
/// - Jede Aenderung einer Seite bekommt eine neue Revision und wird sofort im Journal gesichert. Schlaegt das
///   Schreiben fehl, meldet der Status `.localSaveFailed` (nie "Gespeichert").
/// - Hochgeladen wird hoechstens ein Stand gleichzeitig. Bestaetigt werden genau die gesendeten Revisionen;
///   was waehrend des Uploads entsteht, bleibt ungesendet und geht mit der naechsten Runde.
/// - Bei 409 wird objektweise mit dem Serverstand zusammengefuehrt (Basis = letzter bestaetigter Stand) und
///   erneut gesendet. Striche beider Geraete bleiben erhalten.
/// - Ohne Netz: Wiederholung mit wachsendem Abstand (2 s … 60 s), lokale Daten bleiben ungesendet markiert.
/// - 401/403 (PIN, Zugriff) und 409 ohne neueren Stand (Quelle kann noch nicht speichern): keine automatische
///   Wiederholung, erst wieder nach `requestUpload`/`syncNow`.
///   5xx: Wiederholung mit wachsendem Abstand (2 s … 5 min), auch wenn der Fehler schon beim Oeffnen kam. Den Grund
///   meldet `issue` (nie "Offline").
/// - Ist nach einem Fehler nichts zu senden, prueft ein leichter Abruf, ob der Server wieder antwortet (und holt
///   dabei neuere Staende). So bleibt kein Fehlerzustand stehen, der spaetere Striche lokal festhaelt.
public actor SyncEngine {
    public typealias Sleeper = @Sendable (Double) async -> Void

    public nonisolated let documentID: String
    private let transport: AnnotationTransport
    private let journal: LocalJournal
    private let sleeper: Sleeper
    private let uploadDelay: Double

    private var statusHandler: (@Sendable (SyncStatus) -> Void)?
    private var remoteChangeHandler: (@Sendable ([String]) -> Void)?
    private var issueHandler: (@Sendable (SyncIssue?) -> Void)?

    private var pdfPageCount = 0
    private var serverVersion = 0
    private var rootMeta: JSONValue = AnnotationDocument.empty().rootMeta
    private var baseRootMeta: JSONValue?
    private var metaRev = 0
    private var metaAckedRev = 0
    private var pages: [String: JournalPage] = [:]
    private var acked: [String: Int] = [:]
    private var bases: [String: JSONValue] = [:]          // .null = Seite gab es in der Basis nicht

    private var failedPageWrites: Set<String> = []
    private var failedBaseWrites: Set<String> = []
    private var failedMetaWrite = false
    private var failedAcksWrite = false
    private var lastWriteError: String?

    private var uploading = false
    private var networkDown = false
    private var retryDelay = 2.0
    private var blockedBy: SyncIssue?                     // 401/403/409: wartet auf ausdrueckliche Anfrage
    private var serverErrorStatus: Int?
    private var serverRetryDelay = 2.0
    private var serverRetryScheduled = false              // Wiederholung nach 5xx steht aus (nicht verkuerzen)
    private var scheduleToken = 0
    private var mergedConflictCount = 0
    private var debounceTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var unresolvedConflict: String?
    private var isShutDown = false

    public private(set) var status: SyncStatus = .loading
    public private(set) var issue: SyncIssue?
    public private(set) var stats = SyncStats()

    public init(documentID: String, transport: AnnotationTransport, journal: LocalJournal,
                uploadDelay: Double = 1.2, sleeper: Sleeper? = nil) {
        self.documentID = documentID
        self.transport = transport
        self.journal = journal
        self.uploadDelay = uploadDelay
        self.sleeper = sleeper ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }

    public func setHandlers(onStatus: (@Sendable (SyncStatus) -> Void)?, onRemoteChange: (@Sendable ([String]) -> Void)?) {
        statusHandler = onStatus
        remoteChangeHandler = onRemoteChange
        onStatus?(status)
    }

    /// Meldet jede Aenderung von `issue` (auch sofort den aktuellen Wert).
    public func setIssueHandler(_ handler: (@Sendable (SyncIssue?) -> Void)?) {
        issueHandler = handler
        handler?(issue)
    }

    /// Hinweis "Konflikte zusammengefuehrt" gesehen: zuruecksetzen.
    public func acknowledgeMergedConflicts() {
        mergedConflictCount = 0
        refreshStatus()
    }

    // MARK: Oeffnen

    public struct OpenResult: Sendable {
        public var document: AnnotationDocument
        public var serverReachable: Bool
        public var restoredUnsentPages: Int
        public var damagedFiles: [String]
    }

    /// Laedt das lokale Journal, holt den Serverstand und fuehrt beides zusammen. Ungesendete lokale Aenderungen
    /// haben Vorrang vor einem aelteren Serverstand und werden danach hochgeladen.
    public func open(pdfPageCount: Int) async -> OpenResult {
        self.pdfPageCount = pdfPageCount
        var snapshot: JournalSnapshot?
        do {
            snapshot = try journal.load()
        } catch {
            recordWriteError("Lokale Notizen nicht lesbar (\(error))")
        }
        if let snapshot { adopt(snapshot) }
        let restored = dirtyPageKeys.count
        var reachable = false
        do {
            let server = try await transport.fetch(documentID: documentID)
            reachable = true
            noteReachable()
            if snapshot == nil {
                adoptServer(server)
            } else if server.version != serverVersion || hasStalePages {
                merge(with: server)
            }
        } catch {
            noteTransportFailure(SyncIssue.classify(error))
        }
        refreshStatus()
        if blockedBy == nil {
            if hasDirty { scheduleUpload(after: 0) }
            else if serverErrorStatus != nil { scheduleServerRetry() }   // 5xx beim Oeffnen: spaeter erneut abrufen
        }
        return OpenResult(document: currentDocument(), serverReachable: reachable,
                          restoredUnsentPages: restored, damagedFiles: snapshot?.damaged ?? [])
    }

    // MARK: Lesen

    public func currentDocument() -> AnnotationDocument {
        var doc = AnnotationDocument(rootMeta: rootMeta, pages: pages.mapValues { $0.page })
        doc.ensurePDFPages(count: pdfPageCount)
        return doc
    }

    public func page(_ key: String) -> JSONValue? { pages[key]?.page }

    public var unsentPageKeys: [String] { dirtyPageKeys.sorted() }

    public var confirmedServerVersion: Int { serverVersion }

    // MARK: Lokale Aenderungen

    /// Neuer Stand einer Seite (vom Editor). Wird sofort lokal gesichert, Upload nach kurzer Pause.
    public func updatePage(_ key: String, _ page: JSONValue) {
        retryFailedWrites()
        let old = pages[key]
        guard old?.page != page else { return }
        if !isDirty(key) { setBase(key, old?.page) }          // erste Aenderung seit der Bestaetigung: Basis sichern
        let rev = max(old?.localRev ?? 0, acked[key] ?? 0) + 1
        pages[key] = JournalPage(page: page, localRev: rev)
        persistPage(key)
        refreshStatus()
        scheduleUploadAfterEdit()
    }

    /// Neuer Stand einer Seite, den der Editor aus `previous` berechnet hat. Hat sich die Seite inzwischen geaendert
    /// (Zusammenfuehrung mit dem Server waehrend der Umrechnung), wird drei-Wege zusammengefuehrt (Basis =
    /// `previous`), statt den neueren Stand zu ueberschreiben: im Browser Geloeschtes kommt nicht zurueck, im Browser
    /// Ergaenztes bleibt.
    /// - Returns: `true`, wenn das Ergebnis vom uebergebenen Stand abweicht (Anzeige neu laden).
    @discardableResult
    public func updatePage(_ key: String, _ page: JSONValue, derivedFrom previous: JSONValue?) -> Bool {
        let current = pages[key]?.page
        guard current != previous else {
            updatePage(key, page)
            return false
        }
        let result = AnnotationMerge.mergePage(base: previous, local: page, server: current)
        if result.conflicts > 0 {
            stats.mergedConflicts += result.conflicts
            mergedConflictCount += result.conflicts
        }
        let merged = result.page ?? page
        updatePage(key, merged)
        refreshStatus()
        return merged != page
    }

    /// Neue Wurzelfelder (Seitenreihenfolge, Lesezeichen ...), ohne `pages`.
    public func updateRootMeta(_ meta: JSONValue) {
        var m = meta
        m["pages"] = nil
        guard m != rootMeta else { return }
        if !isMetaDirty { baseRootMeta = rootMeta }
        rootMeta = m
        metaRev = max(metaRev, metaAckedRev) + 1
        persistMeta()
        refreshStatus()
        scheduleUploadAfterEdit()
    }

    // MARK: Hochladen

    /// Upload anstossen, ohne darauf zu warten.
    public func requestUpload() { scheduleUpload(after: 0) }

    /// Beendet geplante Uploads und Wiederholungen (Dokument geschlossen). Ungesendetes bleibt im Journal und wird
    /// beim naechsten Oeffnen hochgeladen.
    public func shutdown() {
        isShutDown = true
        debounceTask?.cancel()
        debounceTask = nil
        serverRetryScheduled = false
    }

    /// Sofort hochladen und warten, bis nichts mehr aussteht oder der Server nicht erreichbar ist.
    public func syncNow() async {
        debounceTask?.cancel()
        if uploading {
            await withCheckedContinuation { idleWaiters.append($0) }
            return
        }
        await uploadLoop()
    }

    /// Nach einer Aenderung: kurz warten und hochladen. Bei 401/403 nicht (wartet auf ausdrueckliche Anfrage). Bei
    /// einem Serverfehler bleibt eine geplante Wiederholung mit wachsendem Abstand bestehen; ist keine geplant (z. B.
    /// 5xx beim Oeffnen ohne ungesendete Seiten), wird eine geplant.
    private func scheduleUploadAfterEdit() {
        guard blockedBy == nil else { return }
        guard serverErrorStatus == nil else {
            if !serverRetryScheduled && !uploading { scheduleServerRetry() }   // laufender Versuch plant selbst neu
            return
        }
        scheduleUpload(after: uploadDelay)
    }

    /// Naechster Versuch nach einem Serverfehler, Abstand waechst (2 s … 5 min).
    private func scheduleServerRetry() {
        let wait = serverRetryDelay
        serverRetryDelay = min(serverRetryDelay * 2, 300)
        scheduleUpload(after: wait)
        serverRetryScheduled = !isShutDown
    }

    private func scheduleUpload(after delay: Double) {
        debounceTask?.cancel()
        serverRetryScheduled = false
        scheduleToken += 1
        guard !isShutDown else { return }
        let sleeper = self.sleeper
        let token = scheduleToken
        debounceTask = Task { [weak self] in
            if delay > 0 { await sleeper(delay) }
            if Task.isCancelled { return }
            await self?.startScheduledUpload(token)
        }
    }

    private func startScheduledUpload(_ token: Int) {
        if token == scheduleToken { serverRetryScheduled = false }       // sonst inzwischen neu geplant
        startUploadLoop()
    }

    private func startUploadLoop() {
        guard !uploading, !isShutDown else { return }
        // eigener Task: eine neue Aenderung bricht einen laufenden Upload nie ab
        Task { await self.uploadLoop() }
    }

    private func uploadLoop() async {
        if uploading { return }
        uploading = true
        if !hasDirty && (serverErrorStatus != nil || blockedBy != nil || networkDown) {
            // nichts zu senden, der letzte Versuch scheiterte aber: leichter Abruf, ob der Server wieder antwortet
            do {
                let server = try await transport.fetch(documentID: documentID)
                noteReachable()
                retryDelay = 2
                serverRetryDelay = 2
                if server.version != serverVersion || hasStalePages { merge(with: server) }
            } catch {
                handleTransportError(error)
                return
            }
        }
        var conflictsInRow = 0
        rounds: while true {
            retryFailedWrites()
            guard hasDirty else { break }
            let sentPages = pages
            let sentMeta = rootMeta
            let sentMetaRev = metaRev
            let root = buildRoot(meta: sentMeta, pages: sentPages)
            refreshStatus()
            stats.puts += 1
            let outcome: PutOutcome
            do {
                outcome = try await transport.put(documentID: documentID, root: root, baseVersion: serverVersion)
            } catch {
                handleTransportError(error)
                return
            }
            noteReachable()
            switch outcome {
            case .saved(let version):
                serverVersion = version
                retryDelay = 2
                serverRetryDelay = 2
                conflictsInRow = 0
                unresolvedConflict = nil
                for (key, sent) in sentPages {
                    guard sent.localRev > (acked[key] ?? 0) else { continue }   // war schon bestaetigt
                    acked[key] = sent.localRev
                    if isDirty(key) { setBase(key, sent.page) }                // waehrend des Uploads weiter geaendert
                    else { dropBase(key) }
                }
                if sentMetaRev > metaAckedRev { metaAckedRev = sentMetaRev }
                baseRootMeta = isMetaDirty ? sentMeta : nil
                persistMeta()
                persistAcks()
            case .conflict(let server):
                stats.conflicts += 1
                conflictsInRow += 1
                if conflictsInRow > 5 {
                    unresolvedConflict = "Der Server ändert sich ständig. Bitte später erneut versuchen."
                    break rounds
                }
                merge(with: server)
            }
        }
        uploading = false
        refreshStatus()
        resumeIdleWaiters()
    }

    /// Fehlgeschlagener Versuch (Abruf oder Speichern): Grund merken, Wiederholung planen, Wartende freigeben.
    private func handleTransportError(_ error: Error) {
        let failure = SyncIssue.classify(error)
        noteTransportFailure(failure)
        uploading = false
        refreshStatus()
        switch failure {
        case .pinFehlt, .zugriffVerweigert, .nichtVerfuegbar:
            break                                       // keine Wiederholung ohne ausdrueckliche Anfrage
        case .serverfehler:
            scheduleServerRetry()
        default:
            let wait = retryDelay
            retryDelay = min(retryDelay * 2, 60)
            scheduleUpload(after: wait)
        }
        resumeIdleWaiters()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }

    private func buildRoot(meta: JSONValue, pages: [String: JournalPage]) -> JSONValue {
        var doc = AnnotationDocument(rootMeta: meta, pages: pages.mapValues { $0.page })
        doc.ensurePDFPages(count: pdfPageCount)
        var ps = doc.pages
        for p in doc.pageOrder {
            if let k = p["key"]?.string, ps[k] == nil { ps[k] = .object(["objects": .array([])]) }
        }
        doc.pages = ps
        return doc.root
    }

    // MARK: Zusammenfuehren

    private func adopt(_ s: JournalSnapshot) {
        serverVersion = s.serverVersion
        rootMeta = s.rootMeta
        baseRootMeta = s.baseRootMeta
        metaRev = s.metaRev
        metaAckedRev = s.metaAckedRev
        pages = s.pages
        acked = s.acked
        bases = s.bases
    }

    private func adoptServer(_ server: ServerSnapshot) {
        let doc = AnnotationDocument(root: server.root)
        serverVersion = server.version
        rootMeta = doc.rootMeta
        baseRootMeta = nil
        metaRev = 0
        metaAckedRev = 0
        pages = [:]
        acked = [:]
        bases = [:]
        for (k, p) in doc.pages {
            pages[k] = JournalPage(page: p, localRev: 0)
            acked[k] = 0
            persistPage(k)
        }
        persistMeta()
        persistAcks()
    }

    private func merge(with server: ServerSnapshot) {
        let doc = AnnotationDocument(root: server.root)
        let serverPages = doc.pages
        var changed: [String] = []
        var conflicts = 0
        for key in Set(pages.keys).union(serverPages.keys) {
            let local = pages[key]
            let theirs = serverPages[key]
            let stale = (local?.localRev ?? 0) < (acked[key] ?? 0)
            if !isDirty(key) || stale {
                // hier nichts Ungesendetes (oder lokale Datei veraltet): Serverstand gilt
                if local?.page != theirs {
                    if let theirs {
                        let rev = max(local?.localRev ?? 0, acked[key] ?? 0)
                        pages[key] = JournalPage(page: theirs, localRev: rev)
                        acked[key] = rev
                    } else {
                        pages.removeValue(forKey: key)
                        acked.removeValue(forKey: key)
                    }
                    persistPage(key)
                    changed.append(key)
                }
                dropBase(key)
                continue
            }
            let stored = bases[key]
            let base: JSONValue? = (stored == nil || stored == .null) ? nil : stored
            let result = AnnotationMerge.mergePage(base: base, local: local?.page, server: theirs)
            conflicts += result.conflicts
            if result.page != local?.page { changed.append(key) }
            let rev = (local?.localRev ?? 0) + 1
            if let merged = result.page {
                pages[key] = JournalPage(page: merged, localRev: rev)
                if merged == theirs {
                    acked[key] = rev                                   // identisch mit dem Server: nichts zu senden
                    dropBase(key)
                } else {
                    setBase(key, theirs)                               // neue Basis = aktueller Serverstand
                }
            } else {
                pages.removeValue(forKey: key)
                acked.removeValue(forKey: key)
                dropBase(key)
            }
            persistPage(key)
        }
        let serverMeta = doc.rootMeta
        if !isMetaDirty {
            rootMeta = serverMeta
            baseRootMeta = nil
        } else {
            let (m, c) = AnnotationMerge.mergeRootMeta(base: baseRootMeta ?? rootMeta, local: rootMeta, server: serverMeta)
            conflicts += c
            rootMeta = m
            metaRev += 1
            if m == serverMeta { metaAckedRev = metaRev; baseRootMeta = nil } else { baseRootMeta = serverMeta }
        }
        persistMeta()
        serverVersion = server.version
        persistAcks()
        stats.mergedConflicts += conflicts
        mergedConflictCount += conflicts
        if !changed.isEmpty { remoteChangeHandler?(changed.sorted()) }
    }

    // MARK: Zustand

    private func isDirty(_ key: String) -> Bool { (pages[key]?.localRev ?? 0) > (acked[key] ?? 0) }
    private var dirtyPageKeys: [String] { pages.keys.filter { isDirty($0) } }
    private var isMetaDirty: Bool { metaRev > metaAckedRev }
    private var hasDirty: Bool { isMetaDirty || pages.keys.contains { isDirty($0) } }
    private var dirtyCount: Int { dirtyPageKeys.count + (isMetaDirty ? 1 : 0) }
    private var hasStalePages: Bool { pages.contains { $0.value.localRev < (acked[$0.key] ?? 0) } }

    /// Antwort vom Server erhalten (auch 409): Netz und Server sind wieder in Ordnung.
    private func noteReachable() {
        networkDown = false
        blockedBy = nil
        serverErrorStatus = nil
    }

    private func noteTransportFailure(_ failure: SyncIssue) {
        switch failure {
        case .pinFehlt, .zugriffVerweigert, .nichtVerfuegbar:
            blockedBy = failure
            networkDown = false
            serverErrorStatus = nil
        case .serverfehler(let code):
            serverErrorStatus = code
            networkDown = false
            blockedBy = nil
        default:
            networkDown = true
            blockedBy = nil
            serverErrorStatus = nil
        }
    }

    private func refreshStatus() {
        let next: SyncStatus
        if let e = lastWriteError { next = .localSaveFailed(e) }
        else if let c = unresolvedConflict { next = .conflictUnresolved(c) }
        else if uploading { next = .uploading(pages: dirtyCount) }
        else if !hasDirty { next = .saved }
        else if networkDown { next = .offline(pages: dirtyCount) }
        else { next = .pending(pages: dirtyCount) }       // auch bei 401/403/5xx: nicht "Offline", Grund in `issue`
        if next != status {
            status = next
            statusHandler?(next)
        }
        let nextIssue: SyncIssue?
        if let blockedBy { nextIssue = blockedBy }
        else if let code = serverErrorStatus { nextIssue = .serverfehler(code) }
        else if networkDown { nextIssue = .offline }
        else if mergedConflictCount > 0 { nextIssue = .konflikteZusammengefuehrt(mergedConflictCount) }
        else { nextIssue = nil }
        if nextIssue != issue {
            issue = nextIssue
            issueHandler?(nextIssue)
        }
    }

    // MARK: Journal (Fehler werden gemeldet und wiederholt)

    private func recordWriteError(_ message: String) {
        stats.localWriteFailures += 1
        lastWriteError = message
    }

    private func clearWriteErrorIfRecovered() {
        if failedPageWrites.isEmpty && failedBaseWrites.isEmpty && !failedMetaWrite && !failedAcksWrite { lastWriteError = nil }
    }

    private func persistPage(_ key: String) {
        do {
            if let p = pages[key] { try journal.writePage(key, p) } else { try journal.removePage(key) }
            failedPageWrites.remove(key)
            clearWriteErrorIfRecovered()
        } catch {
            failedPageWrites.insert(key)
            recordWriteError("Seite konnte nicht lokal gesichert werden (\(error))")
        }
    }

    private func setBase(_ key: String, _ page: JSONValue?) {
        bases[key] = page ?? .null
        do {
            try journal.writeBase(key, page)
            failedBaseWrites.remove(key)
            clearWriteErrorIfRecovered()
        } catch {
            failedBaseWrites.insert(key)
            recordWriteError("Vergleichsstand konnte nicht gesichert werden (\(error))")
        }
    }

    private func dropBase(_ key: String) {
        failedBaseWrites.remove(key)
        guard bases.removeValue(forKey: key) != nil else { return }
        try? journal.removeBase(key)          // uebrig gebliebene Basisdatei ist harmlos (wird vor Gebrauch ersetzt)
    }

    private func persistMeta() {
        do {
            try journal.writeMeta(rootMeta: rootMeta, metaRev: metaRev, baseRootMeta: baseRootMeta)
            failedMetaWrite = false
            clearWriteErrorIfRecovered()
        } catch {
            failedMetaWrite = true
            recordWriteError("Seitenliste konnte nicht lokal gesichert werden (\(error))")
        }
    }

    private func persistAcks() {
        do {
            try journal.writeAcks(serverVersion: serverVersion, acked: acked, metaAckedRev: metaAckedRev)
            failedAcksWrite = false
            clearWriteErrorIfRecovered()
        } catch {
            failedAcksWrite = true
            recordWriteError("Bestätigung konnte nicht lokal gesichert werden (\(error))")
        }
    }

    private func retryFailedWrites() {
        for key in failedPageWrites { persistPage(key) }
        for key in failedBaseWrites { setBase(key, bases[key].flatMap { $0 == .null ? nil : $0 }) }
        if failedMetaWrite { persistMeta() }
        if failedAcksWrite { persistAcks() }
        refreshStatus()
    }
}
