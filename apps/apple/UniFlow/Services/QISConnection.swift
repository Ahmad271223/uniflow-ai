import Foundation
import UniFlowCore
import WebKit

// Noten aus dem QIS der LUH auf dem iPad (F4): die duenne Schicht ueber dem Kern (`QISClient`, `QISGradesSync`),
// wie `HildesheimConnection` fuer das LSF. Die Anmeldung passiert in der Webansicht des Containers (QISLoginView,
// nur vorausgefuellt); der Abruf laeuft mit den Cookies dieser Webansicht ueber `URLSessionUniTransport`, nur auf dem
// Rechner des QIS. Der Sitzungsparameter asi und die Stammdaten der Seiten werden nie gespeichert (Kern).

/// Verbindung zum QIS fuer einen Container (Apple-Nutzer, LUH). Der `ContainerManager` baut je offenem LUH-Container
/// eine; sie haelt ihren Container fest. Abgerufen wird hoechstens alle 20 Stunden von selbst (beim Oeffnen der App,
/// `runIfDue`) und auf Knopfdruck sofort (`run(force: true)`). Ein leerer Notenspiegel ist kein Fehler.
@MainActor
final class QISConnection: ObservableObject {
    enum State: Equatable {
        case notConnected
        /// angemeldet, noch kein Abruf bekannt
        case connected
        case running
        /// letzter erfolgreicher Abruf
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var state: State = .notConnected
    @Published private(set) var isRunning = false
    /// Meldung des letzten Abrufs ("2 Leistungen", Fehler) fuer Uni & Noten und den Erstabgleich
    @Published private(set) var lastMessage: String?
    /// Zahl der Leistungen des letzten erfolgreichen Abrufs; nil, solange keiner gelang
    @Published private(set) var lastCount: Int?
    /// Zahl der beendeten Abrufe; offene Seiten laden danach neu (`ufReload`)
    @Published private(set) var finishedRuns = 0

    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    /// Datenspeicher der Anmelde-Webansichten dieses Containers (Cookies der QIS-Sitzung)
    let websiteDataStore: WKWebsiteDataStore
    let credentials: UniversityCredentialStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    /// nach einer Anmeldung sofort abrufen (Tests schalten das ab)
    var syncsAfterSignIn = true
    private var current: Task<QISGradesSync.Report?, Never>?
    private(set) var stopped = false

    /// Rechner des QIS aus dem Profil (nur dorthin gehen Anfragen)
    static var qisDomains: [String] { [UniversityProfile.luhQISStart.host?.lowercased() ?? "qis.verwaltung.uni-hannover.de"] }

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = UniRetry()) {
        key = c.key
        host = c.host
        defaults = c.defaults
        credentials = c.credentials
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store, allowedDomains: QISConnection.qisDomains) }
        lastMessage = defaults.string(forKey: Keys.message)
        lastCount = defaults.object(forKey: Keys.count) as? Int
        state = storedState()
    }

    // MARK: Einstellungen des Containers (UserDefaults-Suite, gehen mit "Daten dieser Hochschule löschen")

    enum Keys {
        static let connected = "uniflow.qis.connected"
        static let lastRun = "uniflow.qis.lastRun"
        static let login = "uniflow.qis.login"
        static let message = "uniflow.qis.message"
        static let count = "uniflow.qis.count"
        static let all = [connected, lastRun, login, message, count]
    }

    /// Noten hoechstens alle 20 Stunden von selbst (wie am PC und beim LSF)
    static let interval: TimeInterval = 20 * 3600

    var isConnected: Bool { defaults.bool(forKey: Keys.connected) }
    var lastRun: Date? { defaults.object(forKey: Keys.lastRun) as? Date }

    /// Karte "QIS verbinden" bzw. "Erneut anmelden" zeigen
    var needsAttention: Bool { state == .notConnected || state == .needsLogin }

    private func storedState() -> State {
        guard isConnected else { return .notConnected }
        if defaults.bool(forKey: Keys.login) { return .needsLogin }
        return lastRun.map(State.ok) ?? .connected
    }

    private func set(_ s: State) {
        state = s
        switch s {
        case .ok(let d):
            defaults.set(d, forKey: Keys.lastRun)
            defaults.removeObject(forKey: Keys.login)
        case .needsLogin:
            defaults.set(true, forKey: Keys.login)
        case .connected, .notConnected:
            defaults.removeObject(forKey: Keys.login)
        case .running, .failed:
            break
        }
    }

    // MARK: Anmeldung (aus QISLoginView)

    /// Die Webansicht zeigt eine angemeldete QIS-Seite: verbunden, danach gleich abrufen
    func signedIn() {
        defaults.set(true, forKey: Keys.connected)
        set(.connected)
        guard syncsAfterSignIn, !isRunning else { return }
        Task { await run(force: true) }
    }

    /// Abmelden: Verbindung, Stand und die QIS-Cookies der Webansicht (Stud.IP bleibt angemeldet); die gemerkten
    /// QIS-Zugangsdaten gehen mit, Noten in der Datenbank bleiben
    func signOut() async {
        for k in Keys.all { defaults.removeObject(forKey: k) }
        credentials.delete(.luh, service: "qis")
        lastMessage = nil
        lastCount = nil
        set(.notConnected)
        let store = websiteDataStore.httpCookieStore
        for c in await store.allCookies() where Self.qisDomains.contains(where: { c.domain.lowercased().hasSuffix($0) }) {
            await store.deleteCookie(c)
        }
    }

    // MARK: Abruf

    private var due: Bool {
        guard let last = lastRun else { return true }
        return clock.now.timeIntervalSince(last) >= Self.interval
    }

    /// Beim Oeffnen der App: hoechstens alle 20 Stunden, nur verbunden; nie automatisch unter XCTest oder mit
    /// Startargumenten fuer Bildvergleiche (dieselbe Regel wie der Stud.IP-Abgleich)
    func runIfDue() {
        guard StudIPSync.automaticRunAllowed(), isConnected, !isRunning, state != .needsLogin, due else { return }
        Task { await run() }
    }

    /// Ein Abruf; `force`: auch vor Ablauf der 20 Stunden (Knopf "Noten abrufen")
    @discardableResult
    func run(force: Bool = false) async -> QISGradesSync.Report? {
        guard !isRunning, !stopped, isConnected, force || due else { return nil }
        // Demo-Inhalte aktiv: nie zur Hochschule, keine Anfrage (DemoContent); erst nach "Entfernen" wieder
        if await host.demoActive() { return nil }
        guard !isRunning, !stopped else { return nil }
        isRunning = true
        let before = state
        set(.running)
        let task = Task { await self.perform() }
        current = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        apply(report, before: before)
        isRunning = false
        finishedRuns += 1
        return report
    }

    /// Anhalten vor dem Loeschen des Containers (ContainerSync)
    func stop() async {
        stopped = true
        guard let task = current else { return }
        task.cancel()
        _ = await task.value
    }

    private func perform() async -> QISGradesSync.Report? {
        let transport = await makeTransport(websiteDataStore)
        do {
            let db = try await host.backend().context.database
            return await QISGradesSync.run(db: db, transport: transport, clock: clock, retry: retry)
        } catch {
            return QISGradesSync.Report(message: LocalBackendHost.message(for: error))
        }
    }

    private func apply(_ r: QISGradesSync.Report?, before: State) {
        guard let r else { set(.failed("Abruf nicht möglich.")); return }
        if r.cancelled {
            set(before == .running ? .connected : before)
            return
        }
        lastMessage = r.message
        defaults.set(r.message, forKey: Keys.message)
        if let n = r.grades {
            lastCount = n
            defaults.set(n, forKey: Keys.count)
            set(.ok(clock.now))
        } else if r.needsLogin {
            set(.needsLogin)
        } else {
            set(.failed(r.message))
        }
    }

    // MARK: Anzeige

    /// "QIS: 16:30 ok", "QIS: Anmeldung nötig" (Uhrzeit in Berlin; nicht von heute mit Datum)
    static func statusText(_ state: State, now: Date = Date()) -> String {
        switch state {
        case .notConnected: return "QIS: nicht verbunden"
        case .connected: return "QIS: verbunden"
        case .running: return "QIS: ruft ab …"
        case .ok(let d): return "QIS: \(HildesheimConnection.time(d, now: now)) ok"
        case .needsLogin: return "QIS: Anmeldung nötig"
        case .failed: return "QIS: Fehler"
        }
    }

    /// Text unter dem Notenspiegel, wenn er leer ist: ehrlich je nach Stand (nicht verbunden, Anmeldung noetig, Abruf
    /// gelungen ohne Leistungen, noch kein Abruf)
    static func emptyText(_ state: State, lastCount: Int?) -> String {
        switch state {
        case .notConnected: return "Verbinde QIS, damit UniFlow deinen Notenspiegel holt."
        case .needsLogin: return "Die QIS-Anmeldung ist abgelaufen. Melde dich erneut an, dann holt UniFlow deinen Notenspiegel."
        case .running: return "Der Notenspiegel wird gerade abgerufen …"
        case .ok, .failed, .connected:
            if lastCount == 0 { return QISGradesSync.emptyNotice + " Sobald eine Note eingetragen ist, erscheint sie hier nach dem nächsten Abruf." }
            return "Noch keine Leistungen geladen. Nach dem nächsten Abruf erscheinen hier alle Prüfungsleistungen aus deinem QIS-Notenspiegel."
        }
    }
}

extension QISConnection: ContainerSync {}
