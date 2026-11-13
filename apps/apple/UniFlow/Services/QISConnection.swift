import Foundation
import UniFlowCore
import WebKit

// Noten aus dem QIS der LUH auf dem iPad (F4): die duenne Schicht ueber dem Kern (`QISClient`, `QISGradesSync`),
// wie `HildesheimConnection` fuer das LSF. Die Anmeldung passiert in der Webansicht des Containers (QISLoginView; das
// Passwort tippt der Mensch, gespeichert hoechstens von iOS, nie von der App); der Abruf laeuft mit den Cookies dieser Webansicht ueber `URLSessionUniTransport`, nur auf dem
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
    /// "Angemeldete Prüfungen abrufen" laeuft (Pruefungsanmeldung, nur lesend)
    @Published private(set) var registrationsRunning = false
    /// Meldung des letzten Abrufs der angemeldeten Pruefungen ("2 angemeldete Prüfungen gelesen.", Fehler)
    @Published private(set) var registrationsMessage: String?

    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    /// Datenspeicher der Anmelde-Webansichten dieses Containers (Cookies der QIS-Sitzung)
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    /// nach einer Anmeldung sofort abrufen (Tests schalten das ab)
    var syncsAfterSignIn = true
    private var current: Task<QISGradesSync.Report?, Never>?
    private(set) var stopped = false
    /// zaehlt jedes Abmelden: ein Abruf, der vorher begann und noch auf die Demo-Pruefung wartete, beginnt danach nicht
    /// mehr (er setzte sonst nach dem Abmelden wieder seinen Stand, Pruefpunkt 362)
    private var signOuts = 0
    /// Offene In-App-Browser auf dem QIS (`beginBrowser`/`endBrowser`, 13.11.2026). Solange einer offen ist, ruft die App
    /// nichts selbst im QIS ab und meldet sich nicht still neu an: der Abruf benutzt dieselbe Sitzung des Servers (asi,
    /// Zustand des Anmeldebaums), und eine stille Neuanmeldung schreibt ein neues Sitzungs-Cookie in den gemeinsamen
    /// Datenspeicher. Beides machte die Seite im Browser ungueltig: "mal angemeldet, mal abgemeldet" und "nur noch dieses
    /// eine Modul" (Meldung des Inhabers 13.11.2026). Nach dem Schliessen ruft `ExamRegistrationAutoFetch` einmal ab.
    private(set) var browserUses = 0
    var browserOpen: Bool { browserUses > 0 }

    /// Rueckfrage vor dem Abmelden (Einstellungen, Uni & Noten)
    static let signOutMessage = "Die QIS-Anmeldung in der Webansicht wird gelöscht, ebenso ein in StudiNow gemerktes Passwort der LUH. Die geladenen Noten bleiben; Stud.IP bleibt angemeldet. Ein Passwort, das iOS gesichert hat, bleibt unter „Passwörter“."

    /// Rechner des QIS aus dem Profil (nur dorthin gehen Anfragen)
    static var qisDomains: [String] { [UniversityProfile.luhQISStart.host?.lowercased() ?? "qis.verwaltung.uni-hannover.de"] }

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = .qisPages) {
        key = c.key
        host = c.host
        defaults = c.defaults
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store, allowedDomains: QISConnection.qisDomains) }
        lastMessage = defaults.string(forKey: Keys.message)
        lastCount = defaults.object(forKey: Keys.count) as? Int
        state = storedState()
        StudyCatalogSync.attach(host: host)      // Modulkatalog: Ausloeser fuer die Seite Studienverlauf
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

    /// Die Webansicht zeigt eine angemeldete QIS-Seite: verbunden, danach gleich abrufen. `fetch: false`: der Aufrufer
    /// liest selbst (Abgleich aller Portale, `runRenewingSession`), kein zweiter, losgeloester Abruf.
    func signedIn(fetch: Bool = true) {
        defaults.set(true, forKey: Keys.connected)
        set(.connected)
        let store = websiteDataStore
        UniAutoLogin.clearSignedOut(.qis, store: store)        // angemeldet: die Abmelden-Sperre faellt
        UniAutoLogin.signedIn(store, portal: .qis)             // mitgelesenes Passwort jetzt merken (falls zugelassen)
        Task { await UniWebSessions.save(store) }              // QIS-Sitzung ueber Neustarts merken (`UniWebSessions`)
        guard fetch, syncsAfterSignIn, !isRunning else { return }
        Task { await run(force: true) }
    }

    /// Abmelden: Verbindung, Stand und die QIS-Cookies der Webansicht (Stud.IP bleibt angemeldet); Noten in der
    /// Datenbank bleiben. Ein gemerktes Passwort der LUH (`UniAutoLogin`) geht mit.
    func signOut() async {
        signOuts += 1
        // laufenden Abruf zuerst anhalten und abwarten (er schriebe danach seinen Stand zurueck)
        if let task = current {
            task.cancel()
            _ = await task.value
        }
        for k in Keys.all { defaults.removeObject(forKey: k) }
        UniAutoLogin.forget(websiteDataStore)                  // gemerktes Passwort der LUH (Schluesselbund)
        UniAutoLogin.markSignedOut(.qis, store: websiteDataStore)   // bewusst abgemeldet: nie still wieder verbinden
        lastMessage = nil
        lastCount = nil
        set(.notConnected)
        await UniWebSessions.ready(websiteDataStore)           // erst die zurueckgesetzte Anmeldung, dann loeschen
        let store = websiteDataStore.httpCookieStore
        for c in await store.allCookies() where Self.qisDomains.contains(where: { c.domain.lowercased().hasSuffix($0) }) {
            await store.deleteCookie(c)
        }
        // Gemerktes ohne die QIS-Cookies neu schreiben (die Anmeldung fuer Stud.IP bleibt)
        await UniWebSessions.save(websiteDataStore)
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

    /// Ein Abruf; `force`: auch vor Ablauf der 20 Stunden (Knopf "Noten abrufen"). `renewsSession`: meldet das QIS
    /// "abgelaufen", startet `apply` die stille Anmeldung losgeloest (Vorgabe); der Abgleich aller Portale schaltet das ab
    /// und wartet sie selbst ab (`runRenewingSession`), damit nie zwei Anmeldungen bzw. Abrufe nebeneinander laufen.
    @discardableResult
    func run(force: Bool = false, renewsSession: Bool = true) async -> QISGradesSync.Report? {
        guard !isRunning, !stopped, !browserOpen, isConnected, force || due else { return nil }
        let signOutsBefore = signOuts
        // Demo-Inhalte aktiv: nie zur Hochschule, keine Anfrage (DemoContent); erst nach "Entfernen" wieder
        if await host.demoActive() { return nil }
        // waehrend der Pruefung angehalten, schon ein Abruf oder abgemeldet
        guard !isRunning, !stopped, !browserOpen, signOuts == signOutsBefore, isConnected else { return nil }
        isRunning = true
        let before = state
        set(.running)
        let task = Task { await self.perform() }
        current = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        apply(report, before: before, renewsSession: renewsSession)
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
            let report = await QISGradesSync.run(db: db, transport: transport, clock: clock, retry: retry)
            // Pruefungsanmeldung: im selben Abruf auch "Info über angemeldete Prüfungen" lesen (nur lesend; ein Fehler
            // dort aendert den Stand der Noten nicht, er steht in settings.exam_registration_run)
            if report.ok, !Task.isCancelled {
                let r = await QISRegistrationsSync.run(db: db, transport: transport, clock: clock, retry: retry)
                if !r.cancelled { registrationsMessage = r.message }
            }
            return report
        } catch {
            return QISGradesSync.Report(message: LocalBackendHost.message(for: error))
        }
    }

    /// Knopf "Angemeldete Prüfungen abrufen" (Pruefungsanmeldung): liest nur "Info über angemeldete Prüfungen" mit der
    /// Sitzung der Webansicht. Meldet nie an oder ab. nil ohne Verbindung, waehrend eines Abrufs oder mit Demo-Inhalten
    @discardableResult
    func fetchRegistrations() async -> QISRegistrationsSync.Report? {
        guard isConnected, !stopped, !browserOpen, !isRunning, !registrationsRunning else { return nil }
        if await host.demoActive() { return nil }
        guard isConnected, !stopped, !registrationsRunning else { return nil }
        registrationsRunning = true
        defer { registrationsRunning = false }
        let transport = await makeTransport(websiteDataStore)
        let r: QISRegistrationsSync.Report
        do {
            let db = try await host.backend().context.database
            r = await QISRegistrationsSync.run(db: db, transport: transport, clock: clock, retry: retry)
        } catch {
            r = QISRegistrationsSync.Report(message: LocalBackendHost.message(for: error))
        }
        if !r.cancelled { registrationsMessage = r.message }
        if r.needsLogin {
            set(.needsLogin)
            Task { await self.autoLogin() }
        }
        finishedRuns += 1                                       // offene Seiten laden neu (Haken)
        return r
    }

    /// Knopf "Diese Seite auslesen" (`QISPageReaderView`, 12.11.2026): die in der Webansicht angezeigte QIS-Seite
    /// (Notenspiegel bzw. "Info über angemeldete Prüfungen") mit demselben Leser wie der Abruf lesen
    /// (`QISPageImport`). Nur Seiten des QIS ueber HTTPS; nie mit Demo-Inhalten, nie waehrend eines Abrufs.
    @discardableResult
    func readDisplayedPage(html: String, url: URL) async -> QISPageImport.Report {
        guard QISPageImport.accepts(url, allowedHosts: Self.qisDomains) else {
            return .init(result: .nothing, message: "Nur Seiten des QIS der LUH können ausgelesen werden.")
        }
        guard !isRunning, !stopped else { return .init(result: .nothing, message: "Gerade läuft ein Abruf. Bitte gleich noch einmal.") }
        if await host.demoActive() { return .init(result: .nothing, message: "Mit Demo-Inhalten wird nichts aus dem QIS gelesen.") }
        let r: QISPageImport.Report
        do {
            let db = try await host.backend().context.database
            r = await QISPageImport.read(db: db, html: html, url: url, clock: clock)
        } catch {
            return .init(result: .nothing, message: LocalBackendHost.message(for: error))
        }
        switch r.result {
        case .grades(let n):
            if !isConnected { defaults.set(true, forKey: Keys.connected) }
            lastMessage = r.message
            lastCount = n
            defaults.set(r.message, forKey: Keys.message)
            defaults.set(n, forKey: Keys.count)
            set(.ok(clock.now))
            StudyCatalogSync.trigger(host: host)
        case .registrations:
            registrationsMessage = r.message
        case .loginPage, .nothing:
            break
        }
        finishedRuns += 1                                       // offene Seiten laden neu
        return r
    }

    private func apply(_ r: QISGradesSync.Report?, before: State, renewsSession: Bool) {
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
            // die Sitzung traegt (auch nach einer stillen Anmeldung): Fehlschlaege und "neuer Versuch laeuft" zurueck,
            // wie bei Uni-Mail (11.11.2026; vorher blieb die Zustandsmaschine nach jeder stillen Anmeldung "im Versuch")
            UniAutoLogin.succeeded(portal: "qis", store: websiteDataStore)
            StudyCatalogSync.trigger(host: host)     // Studiengang aus dem Notenspiegel -> Modulkatalog suchen (Hintergrund)
        } else if r.needsLogin {
            set(.needsLogin)
            if renewsSession { Task { await self.autoLogin() } }   // still mit dem gespeicherten Passwort, dann einmal neu
        } else {
            set(.failed(r.message))
        }
    }

    // MARK: Automatisch anmelden (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md)

    /// Abgelaufen: unsichtbar mit dem gespeicherten Passwort (nur mit Zustimmung, nur dieses Geraet) auf der QIS-Seite
    /// anmelden, dann genau einmal neu abrufen (`signedIn`). Scheitert es (falsches Passwort), bleibt "Anmeldung nötig".
    /// Nie waehrend des Abmeldens, nie im Hintergrund, nie in einer Schleife (`UniAutoLoginMachine`).
    /// `fetch: false`: nur anmelden, nicht losgeloest abrufen (der Aufrufer liest selbst, `runRenewingSession`).
    @discardableResult
    func autoLogin(userAction: Bool = false, fetch: Bool = true) async -> Bool {
        guard !browserOpen, await renewSession(userAction: userAction) else { return false }
        let before = signOuts
        for _ in 0..<300 where isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }   // Abruf von eben zu Ende
        guard signOuts == before, isConnected, !stopped else { return false }
        signedIn(fetch: fetch)                                  // verbunden, ruft gleich (einmal) ab
        return true
    }

    /// Stille Anmeldung mit dem gespeicherten Zugang (`UniAutoLogin.handleExpiry`), ohne danach abzurufen; true: angemeldet
    private func renewSession(userAction: Bool) async -> Bool {
        guard isConnected, state == .needsLogin, !stopped else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "qis", store: websiteDataStore, entry: QISClient.startURL,
                                                userAction: userAction) { url, html in QISConnection.isSignedInPage(url, html: html) }
        return d == .retryOnce && signOuts == before && isConnected && !stopped
    }

    /// Abgleich aller Portale (OpenSync, 11.11.2026): ein Abruf wie `run`; meldet das QIS dabei "abgelaufen", wartet er
    /// die stille Anmeldung ab (`autoLogin`, nur mit Zustimmung und gespeichertem Zugang, `UniAutoLoginMachine`) und
    /// liest danach im selben Lauf genau einmal neu. Vorher endete der Sync hier mit "QIS: Anmeldung nötig", die
    /// Anmeldung lief losgeloest weiter, Noten und Pruefungen kamen erst spaeter und Bescheinigungen gar nicht.
    @discardableResult
    func runRenewingSession(force: Bool, userAction: Bool) async -> QISGradesSync.Report? {
        let first = await run(force: force, renewsSession: false)
        guard let first, first.needsLogin, state == .needsLogin else { return first }
        guard await autoLogin(userAction: userAction, fetch: false) else { return first }
        return await run(force: true, renewsSession: false) ?? first
    }

    /// wie `QISLoginPane.isSignedIn`: Seite des QIS mit Abmelden-Link, ohne Anmeldeformular
    static func isSignedInPage(_ url: URL, html: String) -> Bool {
        guard url.scheme?.lowercased() == "https", qisDomains.contains(url.host?.lowercased() ?? "") else { return false }
        let page = QISPage.parse(html: html, url: url)
        return page.isLoggedIn && !page.hasLoginForm
    }

    /// Uni-Zugang einmal speichern (10.11.2026): noch nie verbunden -> mit dem gespeicherten Zugang zum ersten Mal
    /// anmelden (unsichtbar, nur im Vordergrund, `UniAutoLogin.handleExpiry`), dann verbunden und gleich abrufen.
    /// Nie nach bewusstem Abmelden (`UniAutoLogin.signedOut`), nie mit einem abgelehnten Passwort.
    @discardableResult
    func connectWithStoredLogin(userAction: Bool = false) async -> Bool {
        guard !isConnected, !stopped, !browserOpen, !UniAutoLogin.signedOut(.qis, store: websiteDataStore) else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "qis", store: websiteDataStore, entry: QISClient.startURL,
                                                userAction: userAction) { url, html in QISConnection.isSignedInPage(url, html: html) }
        guard d == .retryOnce, signOuts == before, !isConnected, !stopped else { return false }
        signedIn()                                              // verbunden, ruft gleich (einmal) ab
        return true
    }

    // MARK: In-App-Browser (13.11.2026)

    /// Ein In-App-Browser zeigt das QIS: ab jetzt kein eigener Abruf, keine stille Neuanmeldung (`browserUses`)
    func beginBrowser() { browserUses += 1 }

    /// Browser geschlossen (nach dem Merken seiner Cookies)
    func endBrowser() { browserUses = max(0, browserUses - 1) }

    /// Vor dem ersten Laden im Browser: einen laufenden Abruf abwarten (nie zwei Nutzer derselben Sitzung), dann die
    /// Sitzung pruefen und, wenn sie abgelaufen ist, still mit dem gespeicherten Zugang erneuern (wie beim Sync; nur mit
    /// Zustimmung und gespeichertem Zugang, `UniAutoLogin`). Vorher zeigte der Browser je nach Alter der Sitzung mal die
    /// angemeldete Seite, mal die Anmeldeseite. Rueckgabe: Sitzung traegt (false: der Mensch meldet sich im Browser an).
    @discardableResult
    func prepareBrowserSession(probe: ((UniTransport) async -> Bool?)? = nil) async -> Bool {
        for _ in 0..<300 where isRunning || registrationsRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard isConnected, !stopped, !UniAutoLogin.signedOut(.qis, store: websiteDataStore) else { return false }
        if await host.demoActive() { return false }
        await UniWebSessions.ready(websiteDataStore)
        let transport = await makeTransport(websiteDataStore)
        let alive = await (probe ?? Self.sessionAlive)(transport)
        // unbekannt (Netz): nichts tun, der Browser zeigt, was das QIS sagt
        guard alive == false else { return alive ?? false }
        set(.needsLogin)
        guard await renewSession(userAction: true) else { return false }
        set(.connected)
        await UniWebSessions.save(websiteDataStore)
        return true
    }

    /// Startseite des QIS mit den Cookies des Containers: true angemeldet, false Anmeldeseite, nil unbekannt (Netz)
    static func sessionAlive(_ transport: UniTransport) async -> Bool? {
        guard let r = try? await transport.send(UniRequest(url: QISClient.startURL, timeout: 15)), r.status == 200 else { return nil }
        let url = r.finalURL ?? QISClient.startURL
        let html = String(decoding: r.body, as: UTF8.self)
        if isSignedInPage(url, html: html) { return true }
        return QISPage.parse(html: html, url: url).hasLoginForm ? false : nil
    }

    /// Im Browser selbst angemeldet (angemeldete QIS-Seite nach "Anmeldung nötig" bzw. ohne Verbindung): verbunden,
    /// mitgelesenes Passwort merken (falls zugelassen), Sitzung merken. Ruft nicht ab (der Browser ist offen).
    func browserSignedIn() {
        guard !stopped, !isConnected || state == .needsLogin || state == .notConnected else { return }
        signedIn(fetch: false)
    }

    // MARK: Hintergrund (Version 1.3/1.4, docs/BENACHRICHTIGUNGEN-1-3.md)

    /// Im Hintergrund hoechstens so oft den Notenspiegel abrufen (der Abruf beim Oeffnen bleibt bei 20 Stunden)
    static let backgroundInterval: TimeInterval = 3600

    /// Hintergrundlauf: abgelaufene QIS-Anmeldung still mit dem gespeicherten Uni-Zugang erneuern (nur dieses Geraet,
    /// unsichtbar ohne Fenster). Anders als `autoLogin` startet sie keinen Abruf von selbst: den macht `backgroundCheck`.
    @discardableResult
    func reloginInBackground() async -> Bool {
        guard isConnected, state == .needsLogin, !stopped, !browserOpen, !UniAutoLogin.signedOut(.qis, store: websiteDataStore) else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "qis", store: websiteDataStore, entry: QISClient.startURL,
                                                background: true) { url, html in QISConnection.isSignedInPage(url, html: html) }
        guard d == .retryOnce, signOuts == before, isConnected, !stopped else { return false }
        set(.connected)
        Task { await UniWebSessions.save(self.websiteDataStore) }    // neue Sitzung ueber Neustarts merken
        return true
    }

    /// Hintergrundlauf: Notenspiegel abrufen, wenn verbunden, angemeldet und der letzte Abruf mindestens
    /// `backgroundInterval` zurueckliegt. Neue Noten erkennt der Hintergrundlauf am Vergleich der Datenbank.
    @discardableResult
    func backgroundCheck() async -> QISGradesSync.Report? {
        guard isConnected, !stopped, !browserOpen, !isRunning, state != .needsLogin else { return nil }
        if let last = lastRun, clock.now.timeIntervalSince(last) < Self.backgroundInterval { return nil }
        return await run(force: true)
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
        case .notConnected: return "Verbinde QIS, damit StudiNow deinen Notenspiegel holt."
        case .needsLogin: return "Die QIS-Anmeldung ist abgelaufen. Melde dich erneut an, dann holt StudiNow deinen Notenspiegel."
        case .running: return "Der Notenspiegel wird gerade abgerufen …"
        case .ok, .failed, .connected:
            if lastCount == 0 { return QISGradesSync.emptyNotice + " Sobald eine Note eingetragen ist, erscheint sie hier nach dem nächsten Abruf." }
            return "Noch keine Leistungen geladen. Nach dem nächsten Abruf erscheinen hier alle Prüfungsleistungen aus deinem QIS-Notenspiegel."
        }
    }
}

extension QISConnection: ContainerSync {}

// MARK: Bescheinigungen (CertificateCenter, docs/BESCHEINIGUNGEN-2026-11-06.md): dieselbe QIS-Sitzung der Webansicht
extension QISConnection {
    var certificateClock: UniFlowClock { clock }
    func certificateTransport() async -> UniTransport { await makeTransport(websiteDataStore) }
    var certificateHost: LocalBackendHost { host }
    /// Sitzung beim Lesen der Bescheinigungen abgelaufen: "Anmeldung nötig" wie beim Notenabruf
    func certificatesExpired() { if isConnected { set(.needsLogin) } }
}
