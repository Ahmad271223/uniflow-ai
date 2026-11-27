import Foundation
import UIKit
import UniFlowCore
import WebKit

// Uni Goettingen, FlexNow 2: angemeldete Pruefungen mit Abmeldefrist lesen, nur lesend (Auftrag 27.11.2026,
// docs/GOETTINGEN-FLEXNOW-2026-11-27.md). Die duenne Schicht ueber dem Kern (`FlexNowParser`,
// `FlexNowRegistrationsSync`), wie `QISConnection` fuer das QIS der LUH.
//
// - Anmeldung: echte Seite `flexnow2.uni-goettingen.de` in der Webansicht des Containers (`FlexNowLoginView`). Das
//   Passwort tippt nur der Mensch; mit "Passwort merken" liest das Mitleseskript es auf dem FlexNow-Formular
//   (`UniLoginForms.goettingenFlexNow`) mit und legt es nur in den Schluesselbund dieses Geraets (`UniAutoLogin`,
//   gemeinsamer Uni-Zugang wie fuer Stud.IP). Nie an einen Server.
// - Lesen: FlexNow laedt "Aktuelles" per `FrontControllerSS` nach (Inhalt der Anfrage nicht gesehen). Darum oeffnet eine
//   unsichtbare Webansicht `/FN2SSS/`, wartet, bis "Aktuelle Prüfungen" fertig dasteht, und liest `outerHTML`
//   (`FlexNowWebReader`). Die App klickt nichts, sendet kein Formular und ruft `FrontControllerSS` nie selbst auf;
//   "Prüfungen an-/abmelden", "erzeugen" und "Logout" werden nie angetippt.
// - Abgelaufen: genau einmal still mit dem gemerkten Zugang anmelden (`UniAutoLogin.handleExpiry`, unsichtbare
//   Webansicht, nur im Vordergrund), dann einmal neu lesen; sonst "Anmeldung nötig".
// - Von selbst nur beim Oeffnen von "Uni & Noten" und hoechstens alle `interval` (`runIfDue`), sonst auf Knopfdruck.

/// Ergebnis der unsichtbaren Webansicht
enum FlexNowPageRead: Equatable {
    /// `outerHTML` der zuletzt gezeigten Seite (fertig gelesen oder nach Ablauf der Wartezeit)
    case page(String)
    /// nichts zu lesen (kein Fenster, Netzfehler, fremder Rechner)
    case failed(String)
}

@MainActor
final class FlexNowConnection: ObservableObject {
    enum State: Equatable {
        case notConnected
        case connected
        case running
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var state: State = .notConnected
    @Published private(set) var isRunning = false
    /// Meldung des letzten Lesens ("2 angemeldete Prüfungen aus FlexNow gelesen.", Fehler)
    @Published private(set) var lastMessage: String?
    /// beendete Lesevorgaenge; offene Ansichten laden danach neu
    @Published private(set) var finishedRuns = 0

    typealias Reader = @MainActor (WKWebsiteDataStore) async -> FlexNowPageRead

    let key: DataContainerKey
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    private let clock: UniFlowClock
    private let reader: Reader
    private(set) var stopped = false
    private var signOuts = 0
    /// nach der Anmeldung gleich lesen (Tests schalten das ab)
    var readsAfterSignIn = true

    /// Tests: statt der Webansicht
    static var readerOverride: Reader?

    enum Keys {
        static let connected = "uniflow.flexnow.connected"
        static let lastRun = "uniflow.flexnow.lastRun"
        static let login = "uniflow.flexnow.login"
        static let message = "uniflow.flexnow.message"
        /// bewusst abgemeldet: nie still wieder verbinden, bis der Mensch sich anmeldet
        static let signedOut = "uniflow.flexnow.signedOut"
        static let all = [connected, lastRun, login, message]
    }

    /// Von selbst hoechstens so oft (Oeffnen von "Uni & Noten")
    static let interval: TimeInterval = 6 * 3600

    static let signOutMessage = "Die FlexNow-Anmeldung in StudiNow wird gelöscht. Die gelesenen Prüfungen bleiben, Stud.IP bleibt angemeldet. Ein gemerktes Uni-Passwort bleibt für Stud.IP; löschen kannst du es unter „Uni-Zugang & Abgleich“."

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system, reader: Reader? = nil) {
        key = c.key
        host = c.host
        defaults = c.defaults
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.reader = reader ?? Self.readerOverride ?? { store in await FlexNowWebReader.read(store: store) }
        lastMessage = defaults.string(forKey: Keys.message)
        state = storedState()
    }

    var isConnected: Bool { defaults.bool(forKey: Keys.connected) }
    var lastRun: Date? { defaults.object(forKey: Keys.lastRun) as? Date }
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

    // MARK: Anmeldung (aus FlexNowLoginView)

    /// Die Webansicht zeigt die angemeldete Studentenschnittstelle: verbunden, mitgelesenes Passwort merken (falls
    /// zugelassen), Sitzung merken, dann einmal lesen
    func signedIn(read: Bool = true) {
        defaults.set(true, forKey: Keys.connected)
        defaults.removeObject(forKey: Keys.signedOut)
        set(.connected)
        UniAutoLogin.signedIn(websiteDataStore)
        let store = websiteDataStore
        Task { await UniWebSessions.save(store) }
        guard read, readsAfterSignIn, !isRunning else { return }
        Task { await run(force: true) }
    }

    /// Abmelden: Stand und die FlexNow-Cookies der Webansicht; gelesene Pruefungen bleiben, Stud.IP bleibt angemeldet
    func signOut() async {
        signOuts += 1
        for k in Keys.all { defaults.removeObject(forKey: k) }
        defaults.set(true, forKey: Keys.signedOut)
        lastMessage = nil
        set(.notConnected)
        await UniWebSessions.ready(websiteDataStore)
        let cookies = websiteDataStore.httpCookieStore
        for c in await cookies.allCookies() where c.domain.lowercased().hasSuffix(FlexNowPage.host) {
            await cookies.deleteCookie(c)
        }
        await UniWebSessions.save(websiteDataStore)
        finishedRuns += 1
    }

    var signedOutOnPurpose: Bool { defaults.bool(forKey: Keys.signedOut) }

    // MARK: Lesen

    private var due: Bool {
        guard let last = lastRun else { return true }
        return clock.now.timeIntervalSince(last) >= Self.interval
    }

    /// Beim Oeffnen von "Uni & Noten": nur verbunden, nicht abgelaufen, hoechstens alle `interval`; nie unter XCTest
    func runIfDue() {
        guard StudIPSync.automaticRunAllowed(), isConnected, !isRunning, state != .needsLogin, due else { return }
        Task { await run() }
    }

    /// Einmal lesen; `force`: auch vor Ablauf von `interval` (Knopf). Meldet FlexNow "abgelaufen", einmal still
    /// anmelden und einmal neu lesen (`renews`).
    @discardableResult
    func run(force: Bool = false, renews: Bool = true) async -> QISRegistrationsSync.Report? {
        guard !isRunning, !stopped, isConnected, force || due else { return nil }
        if await host.demoActive() { return nil }                 // Demo-Inhalte: nie zur Hochschule
        guard !isRunning, !stopped, isConnected else { return nil }
        let before = signOuts
        isRunning = true
        let previous = state
        set(.running)
        var report = await readOnce()
        if report?.needsLogin == true, renews, signOuts == before, await renewSession(userAction: force) {
            report = await readOnce()
        }
        isRunning = false
        guard signOuts == before else { finishedRuns += 1; return report }
        apply(report, previous: previous)
        finishedRuns += 1
        return report
    }

    private func readOnce() async -> QISRegistrationsSync.Report? {
        switch await reader(websiteDataStore) {
        case .failed(let message):
            return QISRegistrationsSync.Report(message: message)
        case .page(let html):
            do {
                let db = try await host.backend().context.database
                return await FlexNowRegistrationsSync.read(db: db, html: html, clock: clock)
            } catch {
                return QISRegistrationsSync.Report(message: LocalBackendHost.message(for: error))
            }
        }
    }

    private func apply(_ r: QISRegistrationsSync.Report?, previous: State) {
        guard let r else { set(.failed("Lesen nicht möglich.")); return }
        lastMessage = r.message
        defaults.set(r.message, forKey: Keys.message)
        if r.ok {
            set(.ok(clock.now))
            UniAutoLogin.succeeded(portal: "flexnow", store: websiteDataStore)
        } else if r.needsLogin {
            set(.needsLogin)
        } else {
            set(.failed(r.message))
        }
    }

    /// Stille Anmeldung mit dem gemerkten Uni-Zugang (nur Vordergrund, nur mit Zustimmung, nie mit abgelehntem Passwort)
    private func renewSession(userAction: Bool) async -> Bool {
        guard isConnected, !stopped, !signedOutOnPurpose else { return false }
        let d = await UniAutoLogin.handleExpiry(portal: "flexnow", store: websiteDataStore, entry: FlexNowPage.entry,
                                                userAction: userAction) { url, html in
            FlexNowPage.isSignedIn(url: url, html: html)
        }
        return d == .retryOnce
    }

    /// Anhalten vor dem Loeschen des Containers
    func stop() async { stopped = true }

    // MARK: Anzeige

    static func statusText(_ state: State, now: Date = Date()) -> String {
        switch state {
        case .notConnected: return "FlexNow: nicht verbunden"
        case .connected: return "FlexNow: verbunden"
        case .running: return "FlexNow: liest …"
        case .ok(let d): return "FlexNow: \(HildesheimConnection.time(d, now: now)) ok"
        case .needsLogin: return "FlexNow: Anmeldung nötig"
        case .failed: return "FlexNow: Fehler"
        }
    }
}

extension FlexNowConnection: ContainerSync {}

// MARK: - Unsichtbare Webansicht zum Lesen

/// Oeffnet `/FN2SSS/` in einer sehr kleinen, durchsichtigen Webansicht mit dem Datenspeicher des Containers (wie
/// `UniAutoLoginWeb`), wartet, bis "Aktuelle Prüfungen" fertig gelesen werden kann (oder das Anmeldeformular dasteht),
/// und gibt `outerHTML` zurueck. Kein Mitleseskript, kein Klick, kein Formular. Der Hauptrahmen darf nur HTTPS auf
/// Rechnern der Uni Goettingen laden; alles andere wird abgebrochen.
@MainActor
enum FlexNowWebReader {
    static let timeout: TimeInterval = 25

    private final class Delegate: NSObject, WKNavigationDelegate {
        var failed: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame != false, !FlexNowWebReader.allows(navigationAction.request.url) {
                failed = "FlexNow hat auf eine andere Seite geleitet."
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if let m = UFWebLoadState.message(for: error) { failed = m }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if let m = UFWebLoadState.message(for: error) { failed = m }
        }
    }

    /// Hauptrahmen: HTTPS auf `*.uni-goettingen.de` (FlexNow, Anmeldung) oder about:blank
    nonisolated static func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "uni-goettingen.de" || host.hasSuffix(".uni-goettingen.de")
    }

    static func read(store: WKWebsiteDataStore) async -> FlexNowPageRead {
        // Debug-Nachbildung: die angemeldete Seite aus dem Ordner, nie ein Netz
        if let dir = DebugUniStub.directory {
            let file = dir.appendingPathComponent("flexnow-angemeldet.html")
            return (try? String(contentsOf: file, encoding: .utf8)).map(FlexNowPageRead.page) ?? .failed("Keine FlexNow-Nachbildung im Ordner.")
        }
        if StudIPSync.isUnderTest() { return .failed("Unter Tests liest StudiNow FlexNow nie im Netz.") }
        await UniWebSessions.ready(store)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            return .failed("FlexNow kann nur gelesen werden, solange StudiNow geöffnet ist.")
        }
        let delegate = Delegate()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: StudIPWebView.loginConfiguration(dataStore: store))
        web.navigationDelegate = delegate
        web.alpha = 0.01
        web.isUserInteractionEnabled = false
        web.accessibilityElementsHidden = true
        window.addSubview(web)
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            web.removeFromSuperview()
        }
        web.load(URLRequest(url: FlexNowPage.start))
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        var readySince: Date?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { break }
            if let f = delegate.failed { return .failed(f) }
            guard !web.isLoading else { continue }
            let html = await UniAutoLoginWeb.outerHTML(web)
            if FlexNowPage.showsLoginForm(html) { return .page(html) }          // abgelaufen: der Kern meldet "Anmeldung nötig"
            // fertig, wenn die Liste lesbar ist und sich eine Sekunde lang nicht mehr aendert (Nachladen beendet)
            if FlexNowParser.parse(html: html).reached {
                if html == last, let since = readySince, Date().timeIntervalSince(since) >= 1 { return .page(html) }
                if html != last { readySince = Date() }
            } else {
                readySince = nil
            }
            last = html
        }
        return .page(last)                                                   // nicht fertig: der Kern loescht nichts
    }
}
