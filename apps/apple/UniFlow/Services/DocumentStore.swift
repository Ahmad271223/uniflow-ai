import Foundation
import Network
import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Ordner im App-Container.
enum AppPaths {
    /// Datenordner des aktiven Containers (Apple-Nutzer, Hochschule; `ContainerManager`). Vor der Anmeldung und
    /// Hochschulwahl ein leerer Ort im Temp-Ordner, an dem nichts Dauerhaftes entsteht. Wer Dateien eines Containers
    /// schreibt, haelt seinen Ordner ab der Erzeugung fest (z. B. `DocumentStore`), damit ein Wechsel nichts vermischt.
    static var support: URL { ActiveContainer.current?.layout.root ?? ContainerPaths.none }

    /// Ort ohne Container aus der Zeit vor der Hochschulwahl (Application Support/UniFlow); nur fuer den Umzug
    static var legacySupport: URL { ContainerPaths.legacy.support }

    /// Journal aller Dokumente (Seiten, Revisionen, Basis fuer Konflikte), darin je Datenquelle `spaces/<id>/docs`.
    static var journal: URL { DataContainerLayout.Folder.journal.url(in: support) }

    /// Original-PDF einer Datei im Zwischenspeicher ihrer Datenquelle (die eine Stelle fuer diesen Pfad). Der
    /// Zwischenspeicher (wie die Vorschaubilder) kommt nicht ins iCloud-Backup: Stud.IP-Dateien bleiben nur auf dem
    /// Geraet (Entscheidung 6 in docs/IPAD-OHNE-PC.md), und alles darin laesst sich aus der Datenquelle neu laden.
    static func pdf(_ fileID: String, namespace: DataSourceNamespace, root: URL = support) -> URL {
        DataContainerLayout.pdfDirectory(namespace, in: root).appendingPathComponent(LocalJournalName.safe(fileID) + ".pdf")
    }

    /// Kopien eines endgueltig geloeschten Dokuments auf dem Geraet entfernen: Original-PDF im Zwischenspeicher,
    /// Journal (Notizen, im iCloud-Backup) und Vorschaubilder der Bibliothek, nur fuer diese Datenquelle. Ohne das
    /// blieben sie fuer immer liegen (die Kennung kommt nie wieder).
    static func removeDocumentCopies(fileID: String, namespace: DataSourceNamespace, root: URL = support) {
        let fm = FileManager.default
        try? fm.removeItem(at: pdf(fileID, namespace: namespace, root: root))
        let journal = DataContainerLayout.Folder.journal.url(in: root)
            .appendingPathComponent(LocalJournal.directory(documentID: fileID, namespace: namespace), isDirectory: true)
        try? fm.removeItem(at: journal)
        removeThumbnails(fileIDs: [fileID], namespace: namespace, root: root)
    }

    /// Vorschaubilder der Bibliothek (`thumbs`, alle Bearbeitungsstaende) zu diesen Dateien einer Datenquelle
    static func removeThumbnails(fileIDs: [String], namespace: DataSourceNamespace, root: URL = support) {
        guard !fileIDs.isEmpty else { return }
        let fm = FileManager.default
        let thumbs = DataContainerLayout.Folder.thumbs.url(in: root)
        let prefixes = fileIDs.map { UFThumbnails.fileNamePrefix(fileID: $0, namespace: namespace) }
        for name in (try? fm.contentsOfDirectory(atPath: thumbs.path)) ?? [] where prefixes.contains(where: { name.hasPrefix($0) }) {
            try? fm.removeItem(at: thumbs.appendingPathComponent(name))
        }
    }
}

/// Einmaliger Umzug in die Namensraeume je Datenquelle (S2): Journale und PDF-Zwischenspeicher aus der Zeit vor dem
/// lokalen Backend gehoeren zum eigenen Server, mit dem sie entstanden sind (zuletzt gespeicherte Adresse). Laeuft
/// beim Start vor dem ersten Dokument; ein zweiter Lauf tut nichts. Nichts wird geloescht oder ueberschrieben.
enum DataSourceMigration {
    /// Eigentuemer der alten Daten: der gespeicherte Server, ohne Adresse der allgemeine Server-Namensraum
    static func legacyOwner(savedServerURL: String?) -> DataSourceNamespace {
        if let s = savedServerURL, let url = URL(string: s), url.host != nil { return DataSourceNamespace(base: url) }
        return .server(host: nil, port: nil)
    }

    /// Laeuft am alten Ort (vor dem Umzug in die Container, `LegacyDataMigration`).
    @discardableResult
    static func run(support: URL = AppPaths.legacySupport, savedServerURL: String? = UserDefaults.standard.string(forKey: Session.urlKey))
        -> (journal: JournalNamespaceMigration.Report, pdf: JournalNamespaceMigration.Report)? {
        let owner = legacyOwner(savedServerURL: savedServerURL)
        do {
            let journal = try JournalNamespaceMigration.run(root: DataContainerLayout.Folder.journal.url(in: support), owner: owner)
            let pdf = try JournalNamespaceMigration.moveEntries(from: support.appendingPathComponent("pdf", isDirectory: true),
                                                                to: DataContainerLayout.pdfDirectory(owner, in: support))
            return (journal, pdf)
        } catch {
            // nichts verloren: was nicht umzog, liegt am alten Ort; der naechste Start versucht es erneut
            return nil
        }
    }
}

enum LocalJournalName {
    static func safe(_ s: String) -> String {
        let ok = s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        return ok && !s.isEmpty ? s : SolutionSHA256.hexString(Array(s.utf8))
    }
}

/// Umrechnung PencilKit <-> Seiten-JSON abseits des Hauptthreads, mit gemerkter Strich-Identitaet je Seite.
actor InkProcessor {
    private var states: [String: InkPageState] = [:]

    /// Zeichnung zum Neuladen. Der bisherige Zustand bleibt fuer die alte Canvas gueltig (`carryingOver`): ob und
    /// wann die neue Zeichnung wirklich angezeigt wird, entscheidet der Editor (nicht waehrend eines Strichs).
    func drawing(key: String, page: JSONValue?) -> DrawingBox {
        let older = states[key]
        let (d, fresh) = StrokeConverter.drawing(fromPage: page, avoiding: older?.creationSlots ?? [])
        states[key] = older.map { fresh.carryingOver($0) } ?? fresh
        return DrawingBox(drawing: d, unrenderable: fresh.unrenderable)
    }

    /// Neuer Seitenstand aus der Zeichnung (drei-Wege gegen `previous`, siehe `StrokeConverter.update`).
    func page(key: String, drawing: DrawingBox, previous: JSONValue?) -> InkPageUpdate {
        let state: InkPageState
        if let s = states[key] { state = s } else { state = StrokeConverter.drawing(fromPage: previous).1 }
        let update = StrokeConverter.update(from: drawing.drawing, previous: previous, state: state)
        states[key] = update.state
        return update
    }
}

/// Notizen ueber `HTTPAnnotationTransport` mit austauschbarem `APIClient`: nach einer neuen PIN geht das schon
/// geoeffnete Dokument ueber die neue Verbindung, ohne neu geoeffnet zu werden.
final class SwitchableAnnotationTransport: AnnotationTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var current: HTTPAnnotationTransport

    init(api: APIClient) { current = HTTPAnnotationTransport(api: api) }

    func use(_ api: APIClient) {
        lock.lock()
        current = HTTPAnnotationTransport(api: api)
        lock.unlock()
    }

    private var transport: HTTPAnnotationTransport {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func fetch(documentID: String) async throws -> ServerSnapshot {
        try await transport.fetch(documentID: documentID)
    }

    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        try await transport.put(documentID: documentID, root: root, baseVersion: baseVersion)
    }
}

/// Lesezeichen (gleiches Feld `bookmarks` wie im Web-Editor).
struct Bookmark: Identifiable, Equatable {
    let key: String
    let title: String
    var id: String { key }
}

/// Suchtreffer im PDF.
struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: String
    let selection: PDFSelection
}

/// Kennzahlen fuer die Dokumentinformation.
struct DocumentInfo {
    var title: String
    var fileName: String
    var subject: String?
    var folder: String?
    var displayPages: Int
    var pdfPages: Int
    var insertedPages: Int
    var removedPDFPages: [Int]
    var bookmarks: Int
    var unsentPages: Int
    var serverVersion: Int
    var status: String
}

/// Zustand eines geoeffneten Dokuments.
///
/// Ablauf beim Schreiben: Strich fertig -> `canvasChanged` merkt nur die neueste Zeichnung (Hauptthread, sofort
/// zurueck) -> nach 0,25 s Pause Umrechnung im `InkProcessor` -> `SyncEngine.updatePage` sichert lokal und laedt hoch.
/// Eingabe, Umrechnung, lokales Sichern und Upload laufen dadurch getrennt; ein Upload unterbricht nie einen Strich.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var layout: DisplayLayout?
    @Published private(set) var layoutVersion = 0
    @Published private(set) var status: SyncStatus = .loading
    /// Warum nicht hochgeladen wird (offline, PIN fehlt, Zugriff verweigert, Serverfehler) oder dass Konflikte
    /// zusammengefuehrt wurden; `nil` = nichts zu melden. Fuer die Anzeige neben `status`.
    @Published private(set) var syncIssue: SyncIssue?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var insertedPages = 0
    @Published private(set) var removedPDFPages: [Int] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    /// Alte Original-Fassungen dieser Datei (S7, lokales Backend; am PC-Server keine), neueste zuerst
    @Published var versions: [FileVersionInfo] = []
    /// Hinweis "Neue Fassung aus Stud.IP – Notizen übernommen": neueste alte Fassung, solange nicht gesehen
    @Published var versionNotice: FileVersionInfo?
    /// Waehrend das Dokument offen war, kam eine neue Fassung an: die Notizen gehoeren jetzt zu ihr, angezeigt ist noch
    /// die alte PDF. Bis zum erneuten Oeffnen nur ansehen.
    @Published private(set) var outdatedByNewVersion = false
    /// Das lokale Journal liess sich beim Oeffnen nicht lesen: der Serverstand ist nur zum Ansehen da, nichts wird
    /// geschrieben (`SyncEngine.OpenResult.journalUnreadable`), bis das Dokument erneut geoeffnet wird
    @Published private(set) var journalUnreadable = false
    /// Je Seite: Strich-Objekte, die sich nicht darstellen lassen (bleiben unveraendert gespeichert)
    @Published private(set) var hiddenStrokes: [String: Int] = [:]
    /// Seiten (1-basiert) mit zusammengefuehrten Konflikten seit dem letzten "Verstanden"
    @Published private(set) var conflictPages: [Int] = []

    var pdf: PDFDocument? { layout?.pdf }

    let file: LibFile
    /// Datenquelle (lokal oder Server-Host): bestimmt Journal und PDF-Zwischenspeicher, aendert sich nie
    let namespace: DataSourceNamespace
    private(set) var api: APIClient
    private let transport: SwitchableAnnotationTransport
    private let engine: SyncEngine
    private let ink = InkProcessor()
    private var original: PDFDocument?
    private var document = AnnotationDocument.empty()
    private var structure = ""
    private var pendingDrawings: [String: DrawingBox] = [:]
    /// Zaehlt je Seite jede Canvas-Aenderung: erkennt beim Neuladen, dass inzwischen geschrieben wurde.
    private var canvasEdits: [String: Int] = [:]
    private var processing = false
    /// Seite, deren Zeichnung gerade umgerechnet wird (aus `pendingDrawings` genommen, noch nicht gesichert).
    private var processingKey: String?
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []
    private var processTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lifecycle: [NSObjectProtocol] = []
    private(set) var images: [String: UIImage] = [:]
    private var loadingImages: Set<String> = []

    /// Seiten (Schluessel), deren Inhalt sich durch den Server, eine Zusammenfuehrung oder eine Aktion geaendert hat.
    /// Schluessel statt Anzeige-Indizes: nach Einfuegen/Drehen von Seiten verschieben sich die Indizes.
    var onPagesChanged: (([String]) -> Void)?
    private var loadStarted = false
    /// Datei, aus der die Original-PDF geladen wird (unveraenderte Bytes, Grundlage des Loesungs-Fingerabdrucks).
    let originalPDFURL: URL
    private var fingerprintCache: String?
    /// "Meine Notizen" ausgeblendet = nur ansehen: Aktionen, die ins eigene Dokument schreiben (Text, Leerseite,
    /// Drehen, Papierkorb, Wiederherstellen, Lesezeichen), tun dann nichts. Ausstehende Striche von vorher werden
    /// weiter gesichert.
    var ownNotesReadOnly = false
    /// Tarif erlaubt Schreiben (Plus, `UFFeatureMatrix.notes(plan:).canEdit`). Ohne (Free, nach dem Herabstufen):
    /// nur ansehen wie bei ausgeblendeten Notizen, dazu nimmt der Store keine neuen Zeichnungen an. Die eigenen
    /// Notizen bleiben sichtbar und exportierbar; was vorher gezeichnet wurde und noch aussteht, wird gesichert.
    var canEdit = true
    /// Schreibende Aktionen erlaubt (Notizen eingeblendet, Tarif mit Schreiben, keine neue Fassung seit dem Oeffnen,
    /// lokales Journal lesbar)
    var isWritable: Bool { canEdit && !ownNotesReadOnly && !outdatedByNewVersion && !journalUnreadable }

    /// Hinweis auf Striche, die sich nicht anzeigen lassen (beschaedigte oder fremde Daten); sie bleiben gespeichert
    var inkNotice: String? {
        let n = hiddenStrokes.values.reduce(0, +)
        guard n > 0 else { return nil }
        return n == 1 ? "1 Strich lässt sich hier nicht anzeigen – er bleibt unverändert gespeichert."
            : "\(n) Striche lassen sich hier nicht anzeigen – sie bleiben unverändert gespeichert."
    }

    /// Schreibrecht in den Container der Datei (entzogen, sobald "Daten dieser Hochschule löschen" ihn loescht)
    private let lease: ContainerLease?

    /// - Parameter root: Ordner fuer Journal und PDF-Zwischenspeicher (Standard: App-Container; Tests: Temp-Ordner).
    /// - Parameter lease: Schreibrecht dieses Containers (Standard: das des aktiven); nach dem Loeschen des Containers
    ///   schreibt das Dokument nichts mehr hinein, auch kein spaeter Upload oder Sichern beim Schliessen (sonst legte es
    ///   den Ordner neu an bzw. landete im leer neu geoeffneten Container mit demselben Schluessel).
    init(file: LibFile, api: APIClient, root: URL = AppPaths.support, lease: ContainerLease? = ActiveContainer.current?.lease) {
        self.file = file
        self.api = api
        self.namespace = api.namespace
        self.lease = lease
        self.originalPDFURL = AppPaths.pdf(file.id, namespace: api.namespace, root: root)
        let transport = SwitchableAnnotationTransport(api: api)
        self.transport = transport
        let journal = LocalJournal(store: FileBlobStore(root: DataContainerLayout.Folder.journal.url(in: root),
                                                        canWrite: lease.map { l in { l.isValid } }),
                                   documentID: file.id, namespace: api.namespace)
        self.engine = SyncEngine(documentID: file.id, transport: transport, journal: journal)
    }

    // MARK: Laden

    /// Notizbuch oder Whiteboard: keine Datei, nur Seiten aus `pageOrder` (Leerseiten mit Vorlage)
    var isNotebook: Bool { ["notebook", "whiteboard"].contains(file.kind ?? "") }

    func load() async {
        guard !loadStarted else { return }          // .task laeuft bei jedem Erscheinen erneut (z. B. Tabwechsel)
        loadStarted = true
        do {
            let pdfDocument: PDFDocument
            if isNotebook {
                // ohne Original-PDF: die Anzeige besteht nur aus den Seiten des Modells (DisplayLayout, wie im
                // Web-Editor). Vorher verlangte der Editor /content und zeigte "Not Found" (Pruefbericht K3)
                pdfDocument = PDFDocument()
            } else {
                pdfDocument = try await loadOriginal()
            }
            original = pdfDocument
            await engine.setHandlers(
                onStatus: { [weak self] s in Task { @MainActor in self?.status = s } },
                onRemoteChange: { [weak self] keys in Task { @MainActor in await self?.remoteChanged(keys) } })
            await engine.setIssueHandler { [weak self] issue in
                Task { @MainActor in
                    self?.syncIssue = issue
                    await self?.refreshConflictPages()
                }
            }
            let opened = await engine.open(pdfPageCount: pdfDocument.pageCount)
            journalUnreadable = opened.journalUnreadable
            apply(document: opened.document, forceLayout: true)
            if opened.journalUnreadable {
                notice = "Lokale Notizen lassen sich gerade nicht lesen – nur ansehen. Schließe das Dokument und öffne es erneut."
            } else if !opened.damagedFiles.isEmpty {
                notice = "\(opened.damagedFiles.count) lokale Datei(en) beschädigt – Serverstand verwendet, wo möglich."
            } else if opened.restoredUnsentPages > 0 {
                notice = "\(opened.restoredUnsentPages) ungesendete Seite(n) wiederhergestellt."
            }
            startMonitoring()
            await checkOrigin(opened.document)
            await loadVersions()
            indexPageTexts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Original-PDF in den Zwischenspeicher des Editors legen und oeffnen. Der Zwischenspeicher ist der feste Stand der
    /// angezeigten Fassung fuer die ganze Sitzung (legt der Abgleich waehrenddessen eine neue Fassung ab, bleiben Anzeige
    /// und Fingerabdruck der Loesungen bei der alten, S7). Lokal ein Klon der Datei im Container (auf APFS ohne
    /// zusaetzlichen Platz; vorher eine zweite Kopie ueber /content), am eigenen Server ein Download von /content.
    /// Neue Fassung seit dem Zwischenspeichern: Stand laut Quelle (`stamp`); ohne Antwort gilt der Zwischenspeicher.
    private func loadOriginal() async throws -> PDFDocument {
        let url = originalPDFURL
        let meta = isOldVersion ? nil : try? await api.value("/api/files/\(file.id)")
        let stamp = meta.map(Self.stamp)
        if let stamp, FileManager.default.fileExists(atPath: url.path), (try? String(contentsOf: stampURL, encoding: .utf8)) != stamp {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            // Container inzwischen geloescht: nichts mehr hineinlegen (der Ordner entstuende sonst neu)
            guard lease?.isValid ?? true else { throw APIError(status: 0, message: "", text: "Die Daten dieser Hochschule wurden gelöscht.") }
            let stampURL = self.stampURL
            if let source = containerFile(meta) {
                guard Self.startsAsPDF(source) else { throw APIError(status: 200, message: "", text: DocumentOpenText.notPDF) }
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? DataContainerLayout.setExcludedFromBackup(url.deletingLastPathComponent())
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: source, to: url)
                    if let stamp { try? stamp.write(to: stampURL, atomically: true, encoding: .utf8) }
                }.value
            } else {
                let (data, http) = try await api.data("/api/files/\(file.id)/content")
                guard http.statusCode == 200, data.starts(with: Array("%PDF".utf8)) else {
                    throw APIError(status: http.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self),
                                   text: DocumentOpenText.problem(status: http.statusCode))
                }
                // grosse Skripte: Schreiben nicht auf dem Hauptthread (die Oberflaeche bliebe so lange stehen)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? DataContainerLayout.setExcludedFromBackup(url.deletingLastPathComponent())
                    try data.write(to: url, options: .atomic)
                    if let stamp { try? stamp.write(to: stampURL, atomically: true, encoding: .utf8) }
                }.value
            }
        }
        guard let pdfDocument = PDFDocument(url: url) else {
            throw APIError(status: 0, message: "", text: "Die PDF lässt sich nicht öffnen.")
        }
        return pdfDocument
    }

    /// Datei im Container (lokales Backend, `local_path` laut Datenbank); nil am eigenen Server oder ohne Datei
    private func containerFile(_ meta: JSONValue?) -> URL? {
        guard api.isLocal, let path = meta?.s("local_path"), let files = (api.transport as? LocalTransport)?.host.files,
              files.exists(stored: path) else { return nil }
        return files.url(stored: path)
    }

    /// Beginnt die Datei wie eine PDF ("%PDF")?
    nonisolated static func startsAsPDF(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data("%PDF".utf8)
    }

    /// Neuen Modellstand uebernehmen; Anzeige-PDF nur neu aufbauen, wenn sich die Seitenstruktur geaendert hat.
    private func apply(document doc: AnnotationDocument, forceLayout: Bool = false) {
        document = doc
        insertedPages = doc.insertedPageCount
        bookmarks = (doc.root["bookmarks"]?.array ?? []).compactMap { b in
            guard let k = b["key"]?.string else { return nil }
            return Bookmark(key: k, title: b["title"]?.string ?? "Lesezeichen")
        }
        guard let original else { return }
        removedPDFPages = doc.removedPDFIndices(pdfPageCount: original.pageCount)
        let sig = DisplayLayout.structureSignature(doc)
        if forceLayout || sig != structure || layout == nil {
            structure = sig
            layout = DisplayLayout.build(original: original, document: doc)
            layoutVersion += 1
        }
    }

    // MARK: Seiten und Zeichnungen

    func pageKey(forPageIndex index: Int) -> String? { layout?.key(at: index) }

    func entry(forPageIndex index: Int) -> DisplayLayout.Entry? { layout?.entry(at: index) }

    func entry(forKey key: String) -> DisplayLayout.Entry? { layout?.entries.first { $0.key == key } }

    /// Zeichnung einer Seite. Wird im Hintergrund aufgebaut. Wird waehrenddessen auf der Seite geschrieben, kommt
    /// die neueste Zeichnung der Canvas zurueck (der Editor setzt das Ergebnis sofort, ein gerade beendeter Strich
    /// darf dabei nicht verschwinden); neu geladen wird dann nach deren Umrechnung.
    func drawing(forPageKey key: String) async -> PKDrawing {
        while true {
            if let pending = pendingDrawings[key] { return pending.drawing }  // noch nicht verarbeitet: neuester Stand
            if processingKey == key {                                         // Umrechnung laeuft: deren Ergebnis abwarten
                await waitForProcessing()
                continue
            }
            let edits = canvasEdits[key, default: 0]
            let page = await engine.page(key)
            let box = await ink.drawing(key: key, page: page)
            if hiddenStrokes[key, default: 0] != box.unrenderable { hiddenStrokes[key] = box.unrenderable == 0 ? nil : box.unrenderable }
            if canvasEdits[key, default: 0] == edits && processingKey != key { return box.drawing }
        }
    }

    private func waitForProcessing() async {
        guard processing else { return }
        await withCheckedContinuation { processingWaiters.append($0) }
    }

    /// Text, Formen, Bilder einer Seite.
    func objects(forPageKey key: String) async -> [JSONValue] {
        (await engine.page(key))?["objects"]?.array ?? []
    }

    /// Bild eines Bildobjekts laden (ueber den Server, mit PIN). Ruft `done` auf, sobald es da ist.
    func loadImage(_ src: String, done: @escaping () -> Void) {
        guard images[src] == nil, !loadingImages.contains(src), src.hasPrefix("/") else { return }
        loadingImages.insert(src)
        Task {
            defer { loadingImages.remove(src) }
            guard let (data, http) = try? await api.data(src), http.statusCode == 200, let img = UIImage(data: data) else { return }
            images[src] = img
            done()
        }
    }

    /// Vom Editor nach jeder Aenderung einer Canvas. Kehrt sofort zurueck. Der Schluessel stammt aus dem
    /// Seitenaufbau, mit dem die Canvas angelegt wurde (bleibt richtig, auch wenn sich die Reihenfolge aendert).
    func canvasChanged(pageKey key: String, drawing: PKDrawing) {
        // ohne Schreiben im Tarif keine neuen Zeichnungen (auch nicht ueber Rueckgaengig); Ausstehendes bleibt
        guard !key.isEmpty, canEdit, !outdatedByNewVersion, !journalUnreadable else { return }
        pendingDrawings[key] = DrawingBox(drawing: drawing)
        canvasEdits[key, default: 0] += 1
        processTask?.cancel()
        processTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.processPending()
        }
    }

    /// Alles Ausstehende sofort verarbeiten (vor dem Schliessen, beim Wechsel in den Hintergrund, vor Export und
    /// Teilen). Laeuft schon eine Umrechnung, wird auf sie gewartet: danach ist jeder Strich gesichert, auch einer,
    /// der waehrenddessen dazukam.
    func flush() async {
        await settlePending()
        await engine.requestUpload()
    }

    private func processPending() async {
        guard !processing else { return }
        processing = true
        defer {
            processing = false
            processingKey = nil
            let waiters = processingWaiters
            processingWaiters = []
            waiters.forEach { $0.resume() }
        }
        var outdated: [String] = []
        while let (key, box) = pendingDrawings.first {
            pendingDrawings.removeValue(forKey: key)
            processingKey = key
            let previous = await engine.page(key)
            let update = await ink.page(key: key, drawing: box, previous: previous)
            // hat eine Zusammenfuehrung die Seite waehrend der Umrechnung geaendert, wird zusammengefuehrt statt
            // ueberschrieben (im Browser Geloeschtes kommt nicht zurueck)
            let merged = await engine.updatePage(key, update.page, derivedFrom: previous)
            if update.canvasOutdated || merged { outdated.append(key) }
        }
        processingKey = nil
        // Canvas zeigt anderswo geloeschte oder geaenderte Striche: aus dem gespeicherten Stand neu laden
        let reload = outdated.filter { pendingDrawings[$0] == nil }
        if !reload.isEmpty { onPagesChanged?(reload) }
    }

    /// Hinweis "Konflikte zusammengefuehrt" gesehen.
    func acknowledgeSyncNotice() async {
        await engine.acknowledgeMergedConflicts()
        await refreshConflictPages()
    }

    /// Seiten mit zusammengefuehrten Konflikten als Seitenzahlen der Anzeige (Schluessel ohne Seite der Anzeige, z. B.
    /// im Papierkorb, fallen weg)
    private func refreshConflictPages() async {
        let keys = await engine.conflictPageKeys
        let numbers = keys.compactMap { layout?.index(ofKey: $0) }.map { $0 + 1 }.sorted()
        if numbers != conflictPages { conflictPages = numbers }
    }

    /// Erneut versuchen; bei 401/403 wird sonst nicht automatisch wiederholt. Ist nichts ungesendet, prueft ein
    /// leichter Abruf die Verbindung (der Hinweis verschwindet, spaetere Striche gehen wieder automatisch hoch).
    /// Nach einer neuen PIN stattdessen `updateAPI` aufrufen, sonst geht die alte PIN mit.
    func retrySync() async {
        await engine.requestUpload()
    }

    /// Neue Verbindung (z. B. korrigierte PIN, neuer `Session.api`): Laden und Speichern laufen ab sofort darueber,
    /// danach wird sofort erneut versucht.
    func updateAPI(_ api: APIClient) async {
        // andere Datenquelle (Wechsel lokal <-> Server): nie gegen deren Stand hochladen; das Dokument bleibt bei
        // seiner Quelle. LibraryView gibt DocumentView die Identitaet "Quelle/Datei", dadurch entsteht beim Wechsel
        // ein neuer Store fuer die neue Quelle
        guard api !== self.api, api.namespace == namespace else { return }
        self.api = api
        transport.use(api)
        await engine.requestUpload()
    }

    private func remoteChanged(_ keys: [String]) async {
        let doc = await engine.currentDocument()
        // zuerst der Herkunftsstempel (S7): gehoeren die Notizen inzwischen zu einer neuen Fassung, passt ihre
        // Seitenliste nicht zur angezeigten PDF (Notizen stuenden auf falschen Folien, Seiten ueber die alte Seitenzahl
        // hinaus fehlten). Dann bleibt die Anzeige, wie sie ist, nur zum Ansehen, bis das Dokument neu geoeffnet wird.
        await checkOrigin(doc)
        guard !outdatedByNewVersion else { return }
        apply(document: doc)
        if !keys.isEmpty { onPagesChanged?(keys) }
    }

    /// Gehoeren die Notizen zu einer anderen Original-PDF als der angezeigten (Herkunftsstempel `origin` einer neuen
    /// Fassung, S7)? Dann nur noch ansehen, bis das Dokument neu geoeffnet ist.
    private func checkOrigin(_ doc: AnnotationDocument) async {
        guard !outdatedByNewVersion, let sha = doc.root["origin"]?["sha256"]?.string,
              let fp = await originalFingerprint(), fp != sha else { return }
        outdatedByNewVersion = true
    }

    // MARK: Bearbeiten der Struktur (gleiches Format wie der Web-Editor)

    /// Seitenliste/Lesezeichen unbekannt (beschaedigte meta.json, Serverstand noch nicht da): sagen statt still nichts tun
    private func rootMetaWritable() async -> Bool {
        guard await engine.rootMetaKnown else {
            notice = "Seitenliste und Lesezeichen lassen sich erst nach dem nächsten Abgleich ändern."
            return false
        }
        return true
    }

    private func updateMeta(_ change: (inout [String: JSONValue]) -> Void) async {
        guard await rootMetaWritable() else { return }
        await processPending()
        var doc = await engine.currentDocument()
        var meta = doc.rootMeta.object ?? [:]
        change(&meta)
        await engine.updateRootMeta(.object(meta))
        doc = await engine.currentDocument()
        apply(document: doc)
    }

    func isBookmarked(pageKey key: String?) -> Bool {
        guard let key else { return false }
        return bookmarks.contains { $0.key == key }
    }

    func toggleBookmark(pageKey key: String, title: String) async {
        guard isWritable else { return }
        await updateMeta { meta in
            var list = meta["bookmarks"]?.array ?? []
            if let i = list.firstIndex(where: { $0["key"]?.string == key }) { list.remove(at: i) }
            else { list.append(.object(["key": .string(key), "title": .string(title)])) }
            meta["bookmarks"] = .array(list)
        }
    }

    /// Leere Seite nach der angegebenen Seite einfuegen (Vorlage: blank, lined, grid, dotted, mm, cornell). `size`:
    /// gewaehltes Format (`PageFormats.validSize`), sonst die angezeigte Groesse der Seite davor.
    func addBlankPage(afterKey: String?, template: String, size chosen: CGSize? = nil) async {
        guard isWritable, await rootMetaWritable() else { return }
        let index = afterKey.flatMap { layout?.index(ofKey: $0) }
        let format = chosen.flatMap { PageFormats.validSize(Double($0.width), Double($0.height)) ? $0 : nil }
        let size = format ?? index.flatMap { layout?.pdf.page(at: $0) }.map { PageGeometry(boxSize: $0.bounds(for: .cropBox).size, rotation: $0.rotation).pageSize }
            ?? CGSize(width: 595, height: 842)
        let key = "b" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11).lowercased()
        await engine.updatePage(key, .object(["objects": .array([]), "template": .string(template)]))
        await updateMeta { meta in
            var order = meta["pageOrder"]?.array ?? []
            let entry: JSONValue = .object(["key": .string(key), "type": "blank", "template": .string(template),
                                            "w": .number(Double(size.width)), "h": .number(Double(size.height))])
            if let afterKey, let i = order.firstIndex(where: { $0["key"]?.string == afterKey }) { order.insert(entry, at: i + 1) }
            else { order.append(entry) }
            meta["pageOrder"] = .array(order)
        }
    }

    /// Seite um 90 Grad drehen (wie "Drehen" im Web-Editor; Notizen behalten ihre Koordinaten).
    func rotatePage(key: String) async {
        guard isWritable else { return }
        await updateMeta { meta in
            var order = meta["pageOrder"]?.array ?? []
            guard let i = order.firstIndex(where: { $0["key"]?.string == key }) else { return }
            let r = (order[i]["rotation"]?.int ?? 0) + 90
            order[i]["rotation"] = .number(Double(DisplayLayout.normalized(r)))
            meta["pageOrder"] = .array(order)
        }
    }

    /// Textfeld auf der Seite anlegen (im Web-Editor bearbeitbar).
    func addText(_ text: String, pageKey key: String) async {
        guard !text.isEmpty, isWritable else { return }
        await processPending()
        var page = (await engine.page(key)) ?? .object(["objects": .array([])])
        var objects = page["objects"]?.array ?? []
        objects.append(.object([
            "id": .string(StrokeConverter.newID()), "type": "text", "text": .string(text),
            "x": 40, "y": .number(40 + Double(objects.filter { $0["type"]?.string == "text" }.count % 10) * 30),
            "fontFamily": "Arial", "fontSize": 14, "fill": "#1d2130", "bold": false, "italic": false, "underline": false,
            "align": "left", "bg": "", "opacity": 1, "width": 220, "lineHeight": 1.25,
            "rotation": 0, "scaleX": 1, "scaleY": 1, "source": "ipad",
        ]))
        page["objects"] = .array(objects)
        await engine.updatePage(key, page)
        onPagesChanged?([key])
    }

    // MARK: Suche, Export, Information

    func search(_ query: String) -> [SearchHit] {
        guard let pdf = layout?.pdf, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]).prefix(200).compactMap { sel in
            guard let page = sel.pages.first else { return nil }
            let index = pdf.index(for: page)
            let context = sel.copy() as? PDFSelection ?? sel
            context.extendForLineBoundaries()
            let text = (context.string ?? sel.string ?? "").replacingOccurrences(of: "\n", with: " ")
            return SearchHit(pageIndex: index, snippet: String(text.prefix(160)), selection: sel)
        }
    }

    // Export und Teilen der PDF mit Notizen: ShareExport (sharePayload, writeFile); einen zweiten Weg gibt es nicht

    /// Unveraenderte Bytes der Original-PDF (die Datei, aus der der Editor sie laedt; nie `dataRepresentation()`).
    func originalPDFData() throws -> Data {
        guard original != nil else { throw ShareExportError.notLoaded }
        return try Data(contentsOf: originalPDFURL, options: .mappedIfSafe)
    }

    /// SHA-256 der Original-PDF-Datei (Zuordnung geteilter Loesungen, Herkunft der Notizen), einmal je Dokument
    /// berechnet; derselbe Weg wie `content_sha256` beim Download (`ContentHash.file`, in Bloecken statt der ganzen
    /// Datei im Speicher).
    func originalFingerprint() async -> String? {
        if let fingerprintCache { return fingerprintCache }
        guard original != nil else { return nil }
        let url = originalPDFURL
        let fp = await Task.detached(priority: .userInitiated) { ContentHash.file(url) }.value
        fingerprintCache = fp
        return fp
    }

    /// Original-PDF wie geladen (Seitengroessen und eigene Drehung fuer die Zuordnung der Loesungen).
    var originalPDF: PDFDocument? { original }

    func info() async -> DocumentInfo {
        let unsent = await engine.unsentPageKeys.count
        let version = await engine.confirmedServerVersion
        return DocumentInfo(title: file.displayTitle, fileName: file.name, subject: file.subject, folder: file.studip_folder,
                            displayPages: layout?.pdf.pageCount ?? 0, pdfPages: original?.pageCount ?? 0,
                            insertedPages: insertedPages, removedPDFPages: removedPDFPages, bookmarks: bookmarks.count,
                            unsentPages: unsent, serverVersion: version, status: status.label)
    }

    // MARK: Netz und App-Lebenszyklus

    private func startMonitoring() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.engine.requestUpload() }
        }
        m.start(queue: DispatchQueue(label: "uniflow.network"))
        monitor = m
        let center = NotificationCenter.default
        lifecycle.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.flushInBackground() }
        })
        lifecycle.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.engine.requestUpload() }
        })
    }

    private func flushInBackground() async {
        // Kennung in einer Box, damit der Ablauf-Handler den spaeter gesetzten Wert sieht
        final class TaskBox: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let box = TaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "UniFlow speichern") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        await settlePending()
        await engine.syncNow()
        if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
    }

    /// Ansicht verdeckt (Tabwechsel, anderes Dokument): Ausstehendes sichern und hochladen, Synchronisierung laeuft weiter.
    func pause() async {
        await flush()
        await engine.syncNow()
    }

    deinit {
        // Dokument endgueltig geschlossen: Wiederholungen beenden (Ungesendetes bleibt im Journal).
        let engine = self.engine
        Task { await engine.shutdown() }
        monitor?.cancel()
        lifecycle.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Dokument schliessen: Ausstehendes sichern, Wiederholungen beenden (Ungesendetes bleibt im Journal).
    func close() async {
        await flush()
        await engine.syncNow()
        await engine.shutdown()
        monitor?.cancel()
        lifecycle.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycle = []
    }
}

// MARK: Seitenstruktur (Papierkorb, Wiederherstellen, Einfuegen ueber PageOrder)

extension DocumentStore: PageStructureEditing {
    func pageStructureDocument() async -> AnnotationDocument {
        await settlePending()
        return await engine.currentDocument()
    }

    func applyPageStructure(_ change: (inout AnnotationDocument) -> PageOrder.Change?) async -> PageOrder.Change? {
        guard isWritable else { return nil }                // nur ansehen
        guard await rootMetaWritable() else { return nil }
        await settlePending()
        var doc = await engine.currentDocument()
        guard let result = change(&doc) else { return nil }
        for key in result.changedPageKeys {
            if let page = doc.page(key) { await engine.updatePage(key, page) }
        }
        await engine.updateRootMeta(doc.rootMeta)
        apply(document: await engine.currentDocument())
        if !result.changedPageKeys.isEmpty { onPagesChanged?(result.changedPageKeys) }
        return result
    }

    /// Ausstehende Striche vollstaendig verarbeiten. `processPending` kehrt sofort zurueck, wenn schon eine
    /// Verarbeitung laeuft; dann auf deren Ende warten, bis nichts mehr aussteht (sonst landen veraltete Objekte
    /// im Papierkorb, Wiederherstellen schreibt diesen Stand zurueck, und Export oder Teilen kaemen ohne die
    /// gerade umgerechneten Striche).
    private func settlePending() async {
        processTask?.cancel()
        while true {
            if processing {
                await withCheckedContinuation { processingWaiters.append($0) }
            } else if !pendingDrawings.isEmpty {
                await processPending()
            } else {
                return
            }
        }
    }
}
