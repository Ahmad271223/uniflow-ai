import Foundation

// MARK: - Schnittstelle zum Server

public protocol AnnotationTransport: Sendable {
    func fetch(documentID: String) async throws -> ServerSnapshot
    /// Speichert den ganzen Stand. Antwortet der Server mit 409, kommt `.conflict` mit dem neueren Serverstand.
    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome
    /// Wie oben; `snapshot` (`?snapshot=true`, beim Schliessen und nach einem Konflikt): der ersetzte und der neue
    /// Stand stehen danach im Versionsverlauf (sonst legt der Server hoechstens alle 5 Minuten eine an, Editor-Schritt 4).
    func put(documentID: String, root: JSONValue, baseVersion: Int, snapshot: Bool) async throws -> PutOutcome
}

extension AnnotationTransport {
    /// Ohne Versionsverlauf (Testtransporte): wie ein normales Speichern
    public func put(documentID: String, root: JSONValue, baseVersion: Int, snapshot: Bool) async throws -> PutOutcome {
        try await put(documentID: documentID, root: root, baseVersion: baseVersion)
    }
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
    /// Beide Geraete haben die Seiten verschieden umsortiert; die Reihenfolge dieses Geraets gilt (Vertrag
    /// `mergeDocument`, Web: gleicher Status). Zaehlt auch in `konflikteZusammengefuehrt`.
    case seitenreihenfolge
    /// 409 ohne neueren Stand: Die Datenquelle kann nicht speichern, z. B. das lokale Backend fuer ein Dokument, das
    /// es in seiner Datenbank nicht gibt. Keine
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
        case .seitenreihenfolge: return "Seitenreihenfolge auf beiden Geräten geändert – die Reihenfolge dieses Geräts gilt"
        case .nichtVerfuegbar(let m): return m
        }
    }
}

public struct SyncStats: Equatable, Sendable {
    public var puts = 0
    public var conflicts = 0
    public var mergedConflicts = 0
    public var localWriteFailures = 0
    /// Seiten, die ins Journal geschrieben wurden (fuer Messungen der Obergrenze beim Sichern)
    public var pageWrites = 0
}

/// Warum ein Dokument nur zum Ansehen offen ist. Dann schreibt die SyncEngine nichts ins Journal und laedt nichts
/// hoch (`newerFormatOnServer`: nur nichts hoch).
public enum NotesViewOnlyReason: Equatable, Sendable {
    /// Journal nicht lesbar (Ordner), angezeigt wird der Serverstand
    case journalUnreadable
    /// Notizen in einer neueren Formatversion (`AnnotationDocument.supportedVersion`): nur lesen, nie speichern
    case newerFormat(Int)
    /// Dasselbe Dokument ist schon in einem anderen Fenster offen (zwei Schreiber auf einem Journal)
    case openElsewhere
    /// Waehrend das Dokument offen war, hat ein anderes Geraet eine neuere Formatversion gespeichert: nichts mehr
    /// hochladen; schon Geschriebenes bleibt im Journal (geht mit einer neueren App wieder mit)
    case newerFormatOnServer(Int)
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
/// - Beschaedigtes Journal (`JournalSnapshot.damaged`): Seiten mit unlesbarer Datei, fehlende oder unlesbare
///   Wurzelfelder und Dateien, die aelter sind als ihre Bestaetigung, gelten als unbekannt. Hochgeladen wird erst, wenn
///   der Serverstand geholt und eingearbeitet ist (sonst ersetzte der Upload Seiten, Seitenliste, Lesezeichen und
///   Papierkorb auf dem Server durch leere Vorgaben). Unlesbare Bestaetigungen werden aus den Basisdateien hergeleitet
///   (Basis vorhanden = ungesendet), damit im Browser Geloeschtes nicht zurueckkommt.
/// - Laesst sich das Journal gar nicht lesen (Ordner), wird nichts hineingeschrieben und nichts hochgeladen: der
///   Serverstand ist nur zum Ansehen da (`OpenResult.journalUnreadable`), bis das Dokument neu geoeffnet wird.
/// - Nur ansehen auch bei Notizen in einer neueren Formatversion und wenn dasselbe Dokument schon in einem anderen
///   Fenster offen ist (`open(pdfPageCount:openElsewhere:)`): nichts ins Journal, nichts hochladen
///   (`OpenResult.viewOnly`). Kommt die neuere Version erst waehrend der Sitzung vom Server, wird nur nicht mehr
///   hochgeladen (`viewOnlyHandler`).
/// - Obergrenze beim Sichern (Editor schreibt ohne Pause): `updatePage(_:_:derivedFrom:holdUpload: true)` sichert ins
///   Journal, startet aber keine neue Upload-Runde, bis `releaseUploadHold`, `requestUpload` oder `syncNow` kommt oder
///   eine Aenderung ohne Halten eintrifft. So laufen bei Dauerschreiben keine Runden mit dem ganzen Dokument hintereinander.
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
    /// Basen bestaetigter Seiten, deren Datei erst nach der gesicherten Bestaetigung geht (`removeDroppedBaseFiles`)
    private var droppedBaseFiles: Set<String> = []
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
    private var orderConflict = false                     // Seitenreihenfolge auf beiden Geraeten geaendert (bis "Verstanden")
    private var debounceTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var unresolvedConflict: String?
    private var isShutDown = false
    /// Seiten, deren Datei im Journal beschaedigt war: lokaler Stand unbekannt, bis der Serverstand eingearbeitet ist
    private var unknownPages: Set<String> = []
    /// Wurzelfelder unbekannt (meta.json fehlt neben Seiten oder ist beschaedigt): erst vom Server, bis dahin weder
    /// hochladen noch aendern
    private var metaUnknown = false
    /// Bestaetigungen (acks.json) beschaedigt und hergeleitet: Serverversion unbekannt
    private var acksUnknown = false
    /// Journal nicht lesbar: nichts schreiben, nichts hochladen (nur ansehen)
    private var journalUnreadable = false
    /// Nur ansehen aus einem anderen Grund (neueres Format, anderes Fenster): nichts schreiben, nichts hochladen
    private var viewOnly: NotesViewOnlyReason?
    /// Neueres Format kam waehrend der Sitzung vom Server: nichts mehr hochladen (Journal bleibt beschreibbar)
    private var uploadsStopped: NotesViewOnlyReason?
    /// Editor schreibt ohne Pause: keine neue Upload-Runde beginnen (siehe `updatePage(...holdUpload:)`)
    private var uploadHeld = false
    /// Naechste Runde mit `snapshot` (Schliessen); bleibt bis zu einem erfolgreichen Speichern
    private var snapshotRequested = false
    /// Seit dem letzten Snapshot gespeichert (der Stand steht vielleicht nicht im Versionsverlauf)
    private var savedSinceSnapshot = false
    private var viewOnlyHandler: (@Sendable (NotesViewOnlyReason) -> Void)?
    /// Weder Journal noch Upload
    private var writesBlocked: Bool { journalUnreadable || viewOnly != nil }
    /// Kein Upload
    private var uploadsBlocked: Bool { writesBlocked || uploadsStopped != nil }
    /// Seiten mit Konflikten seit dem letzten "Verstanden" (Anzeige: welche Seiten betroffen sind)
    private var conflictPages: Set<String> = []

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

    /// `onRemoteChange`: nach dem Zusammenfuehren mit einem neueren Serverstand die Seiten, deren Inhalt sich geaendert
    /// hat; auch mit leerer Liste, wenn sich nur die Wurzel geaendert hat (Seitenliste, Lesezeichen, Herkunftsstempel
    /// einer neuen Original-Fassung)
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

    /// Meldet, wenn das Dokument waehrend der Sitzung nur noch zum Ansehen ist (neueres Format vom Server).
    public func setViewOnlyHandler(_ handler: (@Sendable (NotesViewOnlyReason) -> Void)?) {
        viewOnlyHandler = handler
    }

    /// Ab jetzt nur ansehen (ein anderes Fenster hat das Dokument uebernommen): nichts mehr ins Journal, keine Uploads,
    /// keine Bestaetigungen. Eine laufende Runde endet; was sie bestaetigt, wird nicht mehr gesichert (der neue Schreiber
    /// sendet es erneut, der Server fuehrt gleiche Staende ohne Konflikt zusammen).
    public func enterViewOnly(_ reason: NotesViewOnlyReason) {
        if viewOnly == nil { viewOnly = reason }
        uploadHeld = false
        debounceTask?.cancel()
        debounceTask = nil
        serverRetryScheduled = false
    }

    /// Grund, warum nichts geschrieben oder hochgeladen wird; nil = normal
    public var viewOnlyReason: NotesViewOnlyReason? {
        if journalUnreadable { return .journalUnreadable }
        return viewOnly ?? uploadsStopped
    }

    /// Hinweis "Konflikte zusammengefuehrt" gesehen: zuruecksetzen.
    public func acknowledgeMergedConflicts() {
        mergedConflictCount = 0
        orderConflict = false
        conflictPages = []
        refreshStatus()
    }

    /// Seiten, auf denen seit dem letzten "Verstanden" Objekte zusammengefuehrt werden mussten (beide Geraete hatten
    /// dasselbe Objekt geaendert, oder eines hatte geloescht, was das andere aenderte)
    public var conflictPageKeys: [String] { conflictPages.sorted() }

    /// Wurzelfelder (Seitenliste, Lesezeichen) bekannt und aenderbar? Nach beschaedigtem oder fehlendem meta.json erst,
    /// wenn der Serverstand geholt ist.
    public var rootMetaKnown: Bool { !metaUnknown && !writesBlocked }

    // MARK: Oeffnen

    public struct OpenResult: Sendable {
        public var document: AnnotationDocument
        public var serverReachable: Bool
        public var restoredUnsentPages: Int
        public var damagedFiles: [String]
        /// Journal nicht lesbar: angezeigt wird der Serverstand, nur zum Ansehen; nichts wird geschrieben oder
        /// hochgeladen (erneut oeffnen versucht es wieder)
        public var journalUnreadable = false
        /// Nur zum Ansehen geoeffnet (Grund); nil = normal
        public var viewOnly: NotesViewOnlyReason?
    }

    /// Laedt das lokale Journal, holt den Serverstand und fuehrt beides zusammen. Ungesendete lokale Aenderungen
    /// haben Vorrang vor einem aelteren Serverstand und werden danach hochgeladen.
    /// - Parameter openElsewhere: dasselbe Dokument ist schon in einem anderen Fenster offen: nur ansehen (Journal und
    ///   Serverstand werden gelesen und im Speicher zusammengefuehrt, nichts wird geschrieben oder hochgeladen).
    ///   Notizen in einer neueren Formatversion (im Journal oder auf dem Server) oeffnen ebenso nur zum Ansehen.
    public func open(pdfPageCount: Int, openElsewhere: Bool = false) async -> OpenResult {
        self.pdfPageCount = pdfPageCount
        if openElsewhere { viewOnly = .openElsewhere }
        var snapshot: JournalSnapshot?
        do {
            snapshot = try journal.load()
        } catch {
            // nie den Serverstand ueber ein Journal schreiben, das sich nur gerade nicht lesen laesst (darin koennen
            // ungesendete Seiten stehen): nur ansehen, bis das Dokument neu geoeffnet wird
            journalUnreadable = true
            recordWriteError("Lokale Notizen nicht lesbar – nur ansehen. Dokument schließen und erneut öffnen.")
        }
        if let snapshot {
            // neueres Format schon im Journal (z. B. nach dem Zurueckspielen einer aelteren App): vor jedem Schreiben
            if viewOnly == nil, let v = AnnotationDocument.newerVersion(snapshot.rootMeta) { viewOnly = .newerFormat(v) }
            adopt(snapshot)
        }
        let restored = dirtyPageKeys.count
        var reachable = false
        do {
            let server = try await transport.fetch(documentID: documentID)
            reachable = true
            noteReachable()
            if viewOnly == nil, let v = AnnotationDocument.newerVersion(server.root) { viewOnly = .newerFormat(v) }
            if journalUnreadable {
                adoptServer(server, persist: false)
            } else if snapshot == nil {
                adoptServer(server)
            } else if server.version != serverVersion || hasStalePages || needsServerState {
                merge(with: server)
            }
        } catch {
            noteTransportFailure(SyncIssue.classify(error))
        }
        refreshStatus()
        if blockedBy == nil, !uploadsBlocked {
            if hasDirty || needsServerState { scheduleUpload(after: 0) }
            else if serverErrorStatus != nil { scheduleServerRetry() }   // 5xx beim Oeffnen: spaeter erneut abrufen
        }
        return OpenResult(document: currentDocument(), serverReachable: reachable,
                          restoredUnsentPages: restored, damagedFiles: snapshot?.damaged ?? [],
                          journalUnreadable: journalUnreadable, viewOnly: viewOnlyReason)
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

    /// Neuer Stand einer Seite (vom Editor). Wird sofort lokal gesichert, Upload nach kurzer Pause. Nur zum Ansehen
    /// geoeffnet (`OpenResult.viewOnly`): nicht angenommen.
    /// - Parameter holdUpload: der Editor schreibt noch (Obergrenze beim Sichern): sichern, aber keine Upload-Runde
    ///   anstossen und keine neue beginnen, bis eine Aenderung ohne Halten, `releaseUploadHold`, `requestUpload` oder
    ///   `syncNow` kommt. Eine schon laufende Runde endet normal.
    public func updatePage(_ key: String, _ page: JSONValue, holdUpload: Bool = false) {
        guard !writesBlocked else { return }
        retryFailedWrites()
        let old = pages[key]
        guard old?.page != page else { return }
        if !isDirty(key) { setBase(key, old?.page) }          // erste Aenderung seit der Bestaetigung: Basis sichern
        let rev = max(old?.localRev ?? 0, acked[key] ?? 0) + 1
        pages[key] = JournalPage(page: page, localRev: rev)
        persistPage(key)
        refreshStatus()
        if holdUpload {
            uploadHeld = true
        } else {
            uploadHeld = false
            scheduleUploadAfterEdit()
        }
    }

    /// Neuer Stand einer Seite, den der Editor aus `previous` berechnet hat. Hat sich die Seite inzwischen geaendert
    /// (Zusammenfuehrung mit dem Server waehrend der Umrechnung), wird drei-Wege zusammengefuehrt (Basis =
    /// `previous`), statt den neueren Stand zu ueberschreiben: im Browser Geloeschtes kommt nicht zurueck, im Browser
    /// Ergaenztes bleibt.
    /// - Returns: `true`, wenn das Ergebnis vom uebergebenen Stand abweicht (Anzeige neu laden).
    @discardableResult
    public func updatePage(_ key: String, _ page: JSONValue, derivedFrom previous: JSONValue?, holdUpload: Bool = false) -> Bool {
        guard !writesBlocked else { return false }
        let current = pages[key]?.page
        guard current != previous else {
            updatePage(key, page, holdUpload: holdUpload)
            return false
        }
        let result = AnnotationMerge.mergePage(base: previous, local: page, server: current)
        if result.conflicts > 0 {
            stats.mergedConflicts += result.conflicts
            mergedConflictCount += result.conflicts
            conflictPages.insert(key)
        }
        let merged = result.page ?? page
        updatePage(key, merged, holdUpload: holdUpload)
        refreshStatus()
        return merged != page
    }

    /// Neue Wurzelfelder (Seitenreihenfolge, Lesezeichen ...), ohne `pages`. false, solange die Wurzelfelder unbekannt
    /// sind (`rootMetaKnown`): eine Aenderung auf der leeren Vorgabe ersetzte sonst die echte Seitenliste.
    @discardableResult
    public func updateRootMeta(_ meta: JSONValue) -> Bool {
        guard rootMetaKnown else { return false }
        var m = meta
        m["pages"] = nil
        guard m != rootMeta else { return true }
        if !isMetaDirty { baseRootMeta = rootMeta }
        rootMeta = m
        metaRev = max(metaRev, metaAckedRev) + 1
        persistMeta()
        refreshStatus()
        uploadHeld = false
        scheduleUploadAfterEdit()
        return true
    }

    /// Der Editor hat eine Schreibpause erkannt: gehaltene Uploads freigeben (Runde nach der ueblichen kurzen Pause).
    public func releaseUploadHold() {
        guard uploadHeld else { return }
        uploadHeld = false
        if hasDirty { scheduleUploadAfterEdit() }
    }

    // MARK: Hochladen

    /// Upload anstossen, ohne darauf zu warten (hebt ein Halten auf).
    public func requestUpload() {
        uploadHeld = false
        scheduleUpload(after: 0)
    }

    /// Beendet geplante Uploads und Wiederholungen (Dokument geschlossen). Ungesendetes bleibt im Journal und wird
    /// beim naechsten Oeffnen hochgeladen.
    public func shutdown() {
        isShutDown = true
        debounceTask?.cancel()
        debounceTask = nil
        serverRetryScheduled = false
    }

    /// Sofort hochladen und warten, bis nichts mehr aussteht oder der Server nicht erreichbar ist. `snapshot`
    /// (Schliessen): der hochgeladene Stand kommt sicher in den Versionsverlauf; ist nichts mehr offen, wurde seit
    /// dem letzten Snapshot aber gespeichert, wird der Stand dafuer noch einmal gesendet.
    public func syncNow(snapshot: Bool = false) async {
        if snapshot { snapshotRequested = true }
        uploadHeld = false
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
        guard !uploading, !isShutDown, !uploadsBlocked, !uploadHeld else { return }
        // eigener Task: eine neue Aenderung bricht einen laufenden Upload nie ab
        Task { await self.uploadLoop() }
    }

    private func uploadLoop() async {
        if uploading || uploadsBlocked {
            if !uploading { resumeIdleWaiters() }
            return
        }
        uploading = true
        if needsServerState || (!hasDirty && (serverErrorStatus != nil || blockedBy != nil || networkDown)) {
            // nichts zu senden, der letzte Versuch scheiterte aber: leichter Abruf, ob der Server wieder antwortet.
            // Unbekannter lokaler Stand (beschaedigte oder veraltete Dateien): erst den Serverstand einarbeiten
            do {
                let server = try await transport.fetch(documentID: documentID)
                noteReachable()
                retryDelay = 2
                serverRetryDelay = 2
                if stopUploadsIfNewerFormat(server) {
                    finishUploadLoop()
                    return
                }
                if server.version != serverVersion || hasStalePages || needsServerState { merge(with: server) }
            } catch {
                handleTransportError(error)
                return
            }
        }
        var conflictsInRow = 0
        rounds: while true {
            retryFailedWrites()
            let snapshotOnly = !hasDirty && snapshotRequested && savedSinceSnapshot
            guard hasDirty || snapshotOnly else {
                if !hasDirty && !savedSinceSnapshot { snapshotRequested = false }   // Stand steht schon im Verlauf
                break
            }
            // Editor schreibt noch (Obergrenze beim Sichern): keine weitere Runde mit dem ganzen Dokument
            guard !uploadHeld, !uploadsBlocked else { break }
            let sentPages = pages
            let sentMeta = rootMeta
            let sentMetaRev = metaRev
            let root = buildRoot(meta: sentMeta, pages: sentPages)
            refreshStatus()
            stats.puts += 1
            let outcome: PutOutcome
            let snapshot = snapshotRequested
            do {
                outcome = try await transport.put(documentID: documentID, root: root, baseVersion: serverVersion, snapshot: snapshot)
            } catch {
                handleTransportError(error)
                return
            }
            noteReachable()
            switch outcome {
            case .saved(let version):
                serverVersion = version
                if snapshot { snapshotRequested = false; savedSinceSnapshot = false } else { savedSinceSnapshot = true }
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
                snapshotRequested = true          // die naechste Runde ersetzt den fremden Stand: er bleibt im Verlauf
                if stopUploadsIfNewerFormat(server) { break rounds }
                conflictsInRow += 1
                if conflictsInRow > 5 {
                    unresolvedConflict = "Der Server ändert sich ständig – neuer Versuch folgt. Änderungen sind lokal gesichert."
                    break rounds
                }
                merge(with: server)
            }
        }
        finishUploadLoop()
        // vorher blieb es bei der Meldung, bis wieder geschrieben wurde: spaeter erneut, mit wachsendem Abstand
        if unresolvedConflict != nil, !uploadsBlocked { scheduleServerRetry() }
    }

    private func finishUploadLoop() {
        uploading = false
        refreshStatus()
        resumeIdleWaiters()
    }

    /// Serverstand in einer neueren Formatversion (ein anderes Geraet mit neuerer App hat gespeichert): nie
    /// zusammenfuehren und nie darueber speichern. Ungesendetes bleibt im Journal.
    /// - Returns: true, wenn ab jetzt nichts mehr hochgeladen wird
    private func stopUploadsIfNewerFormat(_ server: ServerSnapshot) -> Bool {
        guard let v = AnnotationDocument.newerVersion(server.root) else { return false }
        if uploadsStopped == nil, viewOnly == nil {
            uploadsStopped = .newerFormatOnServer(v)
            debounceTask?.cancel()
            viewOnlyHandler?(.newerFormatOnServer(v))
        }
        return true
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
        unknownPages = Set(s.damagedPageKeys).subtracting(s.pages.keys)
        metaUnknown = s.metaUnknown
        if s.acksDamaged {
            // Bestaetigungen herleiten: eine Seite mit Basisdatei war ungesendet (die Basis entsteht mit der ersten
            // Aenderung und geht erst mit der Bestaetigung), eine ohne war bestaetigt. Vorher galt jede Seite als
            // ungesendet ohne Basis: die Zusammenfuehrung holte im Browser Geloeschtes zurueck.
            acksUnknown = true
            serverVersion = 0
            acked = [:]
            for (key, p) in pages { acked[key] = bases[key] == nil ? p.localRev : 0 }
            metaAckedRev = baseRootMeta == nil ? metaRev : 0
        }
    }

    /// `persist: false` bei nicht lesbarem Journal: nur im Speicher (nichts ueber die lokalen Dateien schreiben)
    private func adoptServer(_ server: ServerSnapshot, persist: Bool = true) {
        let doc = AnnotationDocument(root: server.root)
        serverVersion = server.version
        rootMeta = doc.rootMeta
        baseRootMeta = nil
        metaRev = 0
        metaAckedRev = 0
        pages = [:]
        acked = [:]
        bases = [:]
        unknownPages = []
        metaUnknown = false
        acksUnknown = false
        for (k, p) in doc.pages {
            pages[k] = JournalPage(page: p, localRev: 0)
            acked[k] = 0
            if persist { persistPage(k) }
        }
        if persist {
            persistMeta()
            persistAcks()
        }
    }

    private func merge(with server: ServerSnapshot) {
        let doc = AnnotationDocument(root: server.root)
        let serverPages = doc.pages
        let metaBefore = rootMeta
        // Stand dieses Geraets und Basis vor dem Seitenabgleich: `mergeRootMeta` entscheidet damit, welche Seiten in
        // der Reihenfolge bleiben (geloescht gegen unveraendert -> weg, gegen geaendert -> bleibt)
        var localPages: [String: JSONValue] = [:], basePages: [String: JSONValue] = [:]
        for (key, p) in pages {
            localPages[key] = p.page
            if isDirty(key) {
                if let b = bases[key], b != .null { basePages[key] = b }
            } else {
                basePages[key] = p.page                                // unveraendert: Basis = dieser Stand
            }
        }
        var changed: [String] = []
        var conflicts = 0
        for key in Set(pages.keys).union(serverPages.keys).union(unknownPages) {
            let local = pages[key]
            let theirs = serverPages[key]
            let stale = (local?.localRev ?? 0) < (acked[key] ?? 0)
            let unknown = unknownPages.contains(key)
            if !isDirty(key) || stale {
                // hier nichts Ungesendetes (oder lokale Datei veraltet bzw. beschaedigt): Serverstand gilt
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
                } else if unknown {
                    persistPage(key)                                   // beschaedigte Datei ersetzen bzw. entfernen
                }
                dropBase(key)
                continue
            }
            let stored = bases[key]
            let base: JSONValue? = (stored == nil || stored == .null) ? nil : stored
            let result = AnnotationMerge.mergePage(base: base, local: local?.page, server: theirs)
            conflicts += result.conflicts
            if result.conflicts > 0 { conflictPages.insert(key) }
            if result.page != local?.page { changed.append(key) }
            let rev = (local?.localRev ?? 0) + 1
            if let merged = result.page {
                pages[key] = JournalPage(page: merged, localRev: rev)
            } else {
                pages.removeValue(forKey: key)
                acked.removeValue(forKey: key)
            }
            // erst die Seite, dann die neue Basis: endet der Prozess dazwischen, passt die alte Basis zur neuen Seite
            // (umgekehrt gaelte der alte Seitenstand gegen die neue Basis als hier geaendert und gewaenne)
            persistPage(key)
            if let merged = result.page, merged != theirs {
                setBase(key, theirs)                                   // neue Basis = aktueller Serverstand
            } else {
                if result.page != nil { acked[key] = rev }             // identisch mit dem Server: nichts zu senden
                dropBase(key)
            }
        }
        unknownPages = []
        let serverMeta = doc.rootMeta
        if !isMetaDirty || metaUnknown {
            // unbekannt (beschaedigt) oder veraltet (meta.json aelter als die Bestaetigung): Stand des Servers
            rootMeta = serverMeta
            baseRootMeta = nil
            if metaUnknown || hasStaleMeta {
                metaRev = max(metaRev, metaAckedRev)
                metaAckedRev = metaRev
            }
            metaUnknown = false
        } else {
            func withPages(_ meta: JSONValue, _ p: [String: JSONValue]) -> JSONValue {
                var o = meta.object ?? [:]
                o["pages"] = .object(p)
                return .object(o)
            }
            let (m, c, order) = AnnotationMerge.mergeRootMeta(base: withPages(baseRootMeta ?? rootMeta, basePages),
                                                              local: withPages(rootMeta, localPages), server: server.root)
            conflicts += c
            if order { orderConflict = true }
            rootMeta = m
            metaRev += 1
            if m == serverMeta { metaAckedRev = metaRev; baseRootMeta = nil } else { baseRootMeta = serverMeta }
        }
        persistMeta()
        serverVersion = server.version
        acksUnknown = false
        persistAcks()
        stats.mergedConflicts += conflicts
        mergedConflictCount += conflicts
        if !changed.isEmpty || rootMeta != metaBefore { remoteChangeHandler?(changed.sorted()) }
    }

    // MARK: Zustand

    private func isDirty(_ key: String) -> Bool { (pages[key]?.localRev ?? 0) > (acked[key] ?? 0) }
    private var dirtyPageKeys: [String] { pages.keys.filter { isDirty($0) } }
    private var isMetaDirty: Bool { metaRev > metaAckedRev }
    private var hasDirty: Bool { isMetaDirty || pages.keys.contains { isDirty($0) } }
    private var dirtyCount: Int { dirtyPageKeys.count + (isMetaDirty ? 1 : 0) }
    private var hasStalePages: Bool { pages.contains { $0.value.localRev < (acked[$0.key] ?? 0) } }
    /// meta.json aelter als die Bestaetigung (Schreiben scheiterte, die Bestaetigung nicht): Serverstand gilt
    private var hasStaleMeta: Bool { metaRev < metaAckedRev }
    /// Vor dem naechsten Hochladen muss der Serverstand eingearbeitet werden (lokaler Stand teils unbekannt/veraltet)
    private var needsServerState: Bool {
        !unknownPages.isEmpty || metaUnknown || acksUnknown || hasStalePages || hasStaleMeta
    }

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
        else if orderConflict { nextIssue = .seitenreihenfolge }
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
        guard !writesBlocked else { return }
        do {
            if let p = pages[key] { try journal.writePage(key, p) } else { try journal.removePage(key) }
            stats.pageWrites += 1
            failedPageWrites.remove(key)
            clearWriteErrorIfRecovered()
        } catch {
            failedPageWrites.insert(key)
            recordWriteError("Seite konnte nicht lokal gesichert werden (\(error))")
        }
    }

    private func setBase(_ key: String, _ page: JSONValue?) {
        bases[key] = page ?? .null
        guard !writesBlocked else { return }
        do {
            try journal.writeBase(key, page)
            failedBaseWrites.remove(key)
            clearWriteErrorIfRecovered()
        } catch {
            failedBaseWrites.insert(key)
            recordWriteError("Vergleichsstand konnte nicht gesichert werden (\(error))")
        }
    }

    /// Basis nicht mehr noetig (Seite bestaetigt oder vom Server uebernommen). Die Datei geht erst, wenn die Bestaetigung
    /// gesichert ist (`persistAcks`): endete der Prozess dazwischen, gaelte die Seite sonst als ungesendet ohne Basis,
    /// und die Zusammenfuehrung holte im Browser Geloeschtes zurueck. Eine uebrig gebliebene Basisdatei ist harmlos
    /// (wird vor Gebrauch ersetzt bzw. beim naechsten Abgleich entfernt).
    private func dropBase(_ key: String) {
        failedBaseWrites.remove(key)
        guard bases.removeValue(forKey: key) != nil else { return }
        droppedBaseFiles.insert(key)
    }

    private func removeDroppedBaseFiles() {
        for key in droppedBaseFiles where bases[key] == nil { try? journal.removeBase(key) }
        droppedBaseFiles = []
    }

    private func persistMeta() {
        // unbekannt: die beschaedigte bzw. fehlende Datei bleibt, bis der Serverstand da ist (sonst gaelte die leere
        // Vorgabe nach einem Neustart als echter Stand)
        guard !writesBlocked, !metaUnknown else { return }
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
        guard !writesBlocked else { return }
        do {
            try journal.writeAcks(serverVersion: serverVersion, acked: acked, metaAckedRev: metaAckedRev)
            failedAcksWrite = false
            clearWriteErrorIfRecovered()
            removeDroppedBaseFiles()
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
