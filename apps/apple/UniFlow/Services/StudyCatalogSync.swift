import Foundation
import UniFlowCore

// Katalogsuche auf dem iPad (docs/STUDIENVERLAUF-2026-11-04.md): die duenne Schicht ueber dem Kern
// (`StudyCatalogPipeline`): nach einem QIS-Abruf (QISConnection) oder wenn die Seite Studienverlauf neue Eingaben
// meldet (bestaetigte PO, eigener Link; `GET /api/study-catalog/status` stoesst ueber `StudyCatalogTriggers` an):
// Schluessel -> lokal -> Grundstock der App (Ressource StudyCatalogSeed, tools/build-luh-seed.py; ohne Download, Stand
// `seed`) -> Bibliothek (CloudKit, uebernehmen ohne Download) -> oeffentliche PDF einmal laden (URLSession ohne Cookies,
// ETag/304) -> mit PDFKit lesen -> speichern -> Fakten teilen. Modultexte zu Katalogen aus Grundstock oder Bibliothek
// laedt die App erst, wenn jemand ein Modul oeffnet (`GET /api/study-plan/module/{id}` stoesst `loadTexts` an; einmal
// je Katalog, ETag). Laeuft nie auf dem Hauptthread und blockiert keine Ansicht; Fehler stehen im Stand und werden
// nach 24 Stunden erneut versucht (Kern).

/// Laden einer oeffentlichen Katalog-PDF wie ein Browser ohne Anmeldung: nur https, keine Cookies, kein Cache,
/// bedingt mit If-None-Match/If-Modified-Since, hoechstens 40 MB
struct URLSessionStudyCatalogLoader: StudyCatalogLoader {
    static let maxBytes = 40 * 1024 * 1024
    static let userAgent = "StudiNow-Modulkatalog/1.0 (support@studinow.app)"
    let session: URLSession

    init(session: URLSession = URLSessionStudyCatalogLoader.makeSession()) { self.session = session }

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 180
        return URLSession(configuration: c)
    }

    static func request(url: URL, etag: String?, lastModified: String?) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        r.httpShouldHandleCookies = false
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { r.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        return r
    }

    func fetch(url: String, etag: String?, lastModified: String?) async -> StudyCatalogFetchResult {
        guard let u = URL(string: url), u.scheme?.lowercased() == "https" else { return StudyCatalogFetchResult(status: 0, error: "nur https") }
        do {
            let (data, response) = try await session.data(for: Self.request(url: u, etag: etag, lastModified: lastModified))
            guard let http = response as? HTTPURLResponse else { return StudyCatalogFetchResult(status: 0, error: "keine HTTP-Antwort") }
            if http.statusCode == 200 && data.count > Self.maxBytes { return StudyCatalogFetchResult(status: 0, error: "Datei zu groß") }
            return StudyCatalogFetchResult(status: http.statusCode, data: http.statusCode == 200 ? data : Data(),
                                           etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                           error: http.statusCode == 200 || http.statusCode == 304 ? nil : "HTTP \(http.statusCode)")
        } catch {
            return StudyCatalogFetchResult(status: 0, error: String(error.localizedDescription.prefix(200)))
        }
    }
}

/// Katalogsuche eines Containers (je Datenbank eine Instanz). `start` kehrt sofort zurueck; `run` wartet auf das Ende
/// (Tests). Zwei Laeufe zugleich gibt es nicht.
@MainActor
final class StudyCatalogSync {
    typealias LibraryFactory = @Sendable () -> StudyCatalogLibrary?
    typealias SeedFactory = @Sendable () -> StudyCatalogSeedSource?

    /// Grundstock dieses Builds (einmal gelesen; die Kataloge entpackt er erst beim ersten Treffer)
    nonisolated static let bundledSeed: StudyCatalogSeed? = StudyCatalogSeed.bundled(.main)

    private static var instances: [String: StudyCatalogSync] = [:]

    let host: LocalBackendHost
    private let loader: StudyCatalogLoader
    private let library: LibraryFactory
    private let seed: SeedFactory
    private let now: @Sendable () -> Date
    private(set) var isRunning = false
    private var textsRunning: Set<String> = []
    private(set) var lastTexts: JSONValue?
    private(set) var lastState: JSONValue?
    private(set) var runs = 0

    init(host: LocalBackendHost, loader: StudyCatalogLoader = URLSessionStudyCatalogLoader(),
         library: @escaping LibraryFactory = { StudyCatalogLibraryFactory.make() },
         seed: @escaping SeedFactory = { StudyCatalogSync.bundledSeed },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.loader = loader
        self.library = library
        self.seed = seed
        self.now = now
    }

    /// Instanz je Container; meldet den Ausloeser fuer `GET /api/study-catalog/status` an (nicht unter XCTest)
    static func attach(host: LocalBackendHost) {
        guard StudIPSync.automaticRunAllowed() else { return }
        _ = shared(for: host)
    }

    static func shared(for host: LocalBackendHost) -> StudyCatalogSync {
        let path = host.databaseURL.path
        if let s = instances[path], s.host === host { return s }
        let s = StudyCatalogSync(host: host)
        instances[path] = s
        StudyCatalogTriggers.register(databasePath: path) { [weak s] force in
            Task { @MainActor in s?.start(force: force) }
        }
        StudyCatalogTriggers.registerTexts(databasePath: path) { [weak s] key in
            Task { @MainActor in await s?.loadTexts(key: key) }
        }
        return s
    }

    /// Nach einem QIS-Abruf mit Leistungen: Suche im Hintergrund (Ergebnis nur im Stand)
    static func trigger(host: LocalBackendHost, force: Bool = false) {
        guard StudIPSync.automaticRunAllowed() else { return }
        shared(for: host).start(force: force)
    }

    /// Container wird geloescht oder gewechselt: Ausloeser abmelden
    static func detach(host: LocalBackendHost) {
        let path = host.databaseURL.path
        instances[path] = nil
        StudyCatalogTriggers.unregister(databasePath: path)
    }

    func start(force: Bool = false) {
        guard !isRunning else { return }
        Task { await run(force: force) }
    }

    /// Ein Lauf; nil, wenn schon einer laeuft oder kein Backend offen ist
    @discardableResult
    func run(force: Bool = false) async -> JSONValue? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        guard let backend = try? await host.backend() else { return nil }
        let db = backend.context.database
        // Demo-Inhalte: nie zur Hochschule; Stand mit den Eingaben merken, damit die Seite nicht immer neu anstoesst
        if await host.demoActive() {
            let state = try? await db.transaction { c -> JSONValue in
                let s: JSONValue = ["state": "idle", "message": "In der Demo lädt StudiNow keinen Modulkatalog.",
                                    "inputs": .string(try StudyCatalogPipeline.inputs(c))]
                try StudyCatalogStore.setState(c, "status", s)
                return s
            }
            lastState = state
            return state
        }
        let env = StudyCatalogPipeline.Environment(loader: loader, library: library(), seed: seed(), pdfText: { StudyCatalogPDF.pages($0) }, now: now)
        // Kern im Hintergrund (nicht auf dem Hauptthread): Laden, PDFKit und Parser
        let task = Task.detached(priority: .utility) { await StudyCatalogPipeline.run(db: db, env: env, force: force) }
        let state = await task.value
        lastState = state
        runs += 1
        return state
    }

    /// Modultexte eines Katalogs (Bibliotheksschluessel) nachladen: einmal je Katalog und gleichzeitig nur einmal;
    /// nil, wenn schon einer laeuft, kein Backend offen ist oder die Demo laeuft
    @discardableResult
    func loadTexts(key: String) async -> JSONValue? {
        guard !textsRunning.contains(key), let backend = try? await host.backend(), !(await host.demoActive()) else { return nil }
        textsRunning.insert(key)
        defer { textsRunning.remove(key) }
        let db = backend.context.database
        let env = StudyCatalogPipeline.Environment(loader: loader, library: nil, pdfText: { StudyCatalogPDF.pages($0) }, now: now)
        let state = await Task.detached(priority: .utility) { await StudyCatalogPipeline.loadTexts(db: db, env: env, key: key) }.value
        lastTexts = state
        return state
    }
}
