import Foundation
import UniFlowCore
import WebKit

// Uni-Mail und Uni-Kalender der LUH (SOGo, https://kalender.uni-hannover.de/SOGo/), docs/UNI-MAIL-2026-11-05.md.
// Duenne Schicht ueber dem Kern (`SOGo`, `SOGoClient`, `SOGoCalendar`), wie `QISConnection` fuer das QIS: Anmeldung in
// der Webansicht des Containers auf der echten SOGo-Seite (eigenes Formular; das Passwort tippt der Mensch, merken darf
// es nur iOS), gespeichert werden nur die Cookies (`UniWebSessions`, Schluesselbund) und der Kontoname aus der Adresse
// (/SOGo/so/<benutzer>/). Abgelaufen (Anmeldeformular, 401/403) heisst "Anmeldung nötig"; keine stille Erneuerung.
// E-Mails bleiben auf dem iPad: nur die Kopfzeilen der ersten Seite des Posteingangs liegen fuer die Anzeige ohne Netz
// in der Datenbank des Containers, Inhalte nur im Arbeitsspeicher, Anhaenge in einem Temp-Ordner zum Oeffnen/Teilen.
// Nichts geht an StudiNow-Server. Senden nur ueber `send` (Knopf "Senden" mit Rueckfrage), genau einmal.

/// Verbindung zu Uni-Mail/Uni-Kalender fuer einen LUH-Container
@MainActor
final class UniMailConnection: ObservableObject {
    enum State: Equatable {
        case notConnected
        case connected
        case running
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var state: State = .notConnected
    /// ungelesene im Posteingang (Abzeichen am Menuepunkt "Uni-Mail")
    @Published private(set) var unseen = 0
    @Published private(set) var user: String?
    @Published private(set) var isRunning = false
    @Published private(set) var finishedRuns = 0
    @Published private(set) var calendarMessage: String?
    /// Zahl der Anfragen an .../send (Tests; nie mehr als Knopfdruecke)
    private(set) var sendCount = 0

    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    var refreshesAfterSignIn = true
    private(set) var stopped = false
    private var signOuts = 0

    static let domains = [SOGo.host]
    static let signOutMessage = "Die Anmeldung bei Uni-Mail wird in der Webansicht gelöscht, ebenso die zwischengespeicherte Liste des Posteingangs und die übernommenen Termine des Uni-Kalenders. Deine E-Mails bleiben in deinem Uni-Postfach. Ein Passwort, das iOS gesichert hat, bleibt unter „Passwörter“."
    static let hint = "Uni-Mail und Uni-Kalender (SOGo) der Leibniz Universität Hannover: E-Mails lesen, beantworten, weiterleiten und schreiben, Termine im Lernkalender. Du meldest dich auf der echten SOGo-Seite an; dein Passwort speichert StudiNow nicht (das kann iOS übernehmen). E-Mails bleiben auf diesem iPad und in deinem Uni-Postfach, nichts geht an StudiNow-Server."

    enum Keys {
        static let connected = "uniflow.sogo.connected"
        static let user = "uniflow.sogo.user"
        static let login = "uniflow.sogo.login"
        static let unseen = "uniflow.sogo.unseen"
        static let lastUID = "uniflow.sogo.lastInboxUID"
        static let lastCheck = "uniflow.sogo.lastCheck"
        static let notify = "uniflow.sogo.notify"
        static let calendarRun = "uniflow.sogo.calendar.lastRun"
        static let calendarDays = "uniflow.sogo.calendar.days"
        static let all = [connected, user, login, unseen, lastUID, lastCheck, notify, calendarRun, calendarDays]
    }

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = UniRetry()) {
        key = c.key
        host = c.host
        defaults = c.defaults
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store, allowedDomains: UniMailConnection.domains) }
        user = defaults.string(forKey: Keys.user)
        unseen = defaults.integer(forKey: Keys.unseen)
        state = storedState()
    }

    /// Einstellungen des Containers (nur Tests)
    var defaultsForTests: UserDefaults { defaults }

    var isConnected: Bool { defaults.bool(forKey: Keys.connected) && user != nil }
    var needsAttention: Bool { state == .notConnected || state == .needsLogin }
    var lastCheck: Date? { defaults.object(forKey: Keys.lastCheck) as? Date }
    /// "Bei neuen Uni-Mails benachrichtigen" (Vorgabe aus; Erlaubnis von iOS fragt der Schalter)
    var notify: Bool {
        get { defaults.bool(forKey: Keys.notify) }
        set { defaults.set(newValue, forKey: Keys.notify); objectWillChange.send() }
    }

    private func storedState() -> State {
        guard isConnected else { return .notConnected }
        if defaults.bool(forKey: Keys.login) { return .needsLogin }
        return lastCheck.map(State.ok) ?? .connected
    }

    private func set(_ s: State) {
        state = s
        switch s {
        case .ok(let d):
            defaults.set(d, forKey: Keys.lastCheck)
            defaults.removeObject(forKey: Keys.login)
        case .needsLogin: defaults.set(true, forKey: Keys.login)
        case .connected, .notConnected: defaults.removeObject(forKey: Keys.login)
        case .running, .failed: break
        }
    }

    private func setUnseen(_ n: Int) {
        unseen = max(0, n)
        defaults.set(unseen, forKey: Keys.unseen)
    }

    // MARK: Anmeldung

    /// Angemeldete Seite erkannt (Adresse /SOGo/so/<benutzer>/...); Konto merken, Cookies sichern, Posteingang lesen
    func signedIn(user u: String) {
        defaults.set(true, forKey: Keys.connected)
        defaults.set(u, forKey: Keys.user)
        user = u
        set(.connected)
        let store = websiteDataStore
        Task { await UniWebSessions.save(store) }
        guard refreshesAfterSignIn else { return }
        Task { await refreshInbox() }
    }

    /// Abmelden: Cookies von SOGo, Einstellungen, Zwischenspeicher und uebernommene Termine; nie Mails im Postfach
    func signOut() async {
        signOuts += 1
        for k in Keys.all { defaults.removeObject(forKey: k) }
        user = nil
        setUnseen(0)
        calendarMessage = nil
        set(.notConnected)
        if let db = try? await host.backend().context.database {
            _ = try? await db.transaction { c in
                try SOGoCalendar.forget(c)
                try SOGoMailCache.forget(c)
            }
        }
        await UniWebSessions.ready(websiteDataStore)
        let store = websiteDataStore.httpCookieStore
        for c in await store.allCookies() where UniCookiePolicy.matches(c, Self.domains) {
            await store.deleteCookie(c)
        }
        await UniWebSessions.save(websiteDataStore)
        finishedRuns += 1
    }

    func stop() async { stopped = true }

    // MARK: Abruf

    /// Client mit den Cookies der Webansicht; nil ohne Verbindung, nach dem Anhalten oder mit Demo-Inhalten
    func client() async -> SOGoClient? {
        guard isConnected, !stopped, let user else { return nil }
        if await host.demoActive() { return nil }
        await UniWebSessions.ready(websiteDataStore)
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        let transport = await makeTransport(websiteDataStore)
        return SOGoClient(user: user, transport: transport, xsrf: SOGoClient.xsrf(from: cookies), retry: retry)
    }

    /// Eine Aktion mit SOGo; abgelaufene Anmeldung setzt "Anmeldung nötig", Erfolg "ok"
    func perform<T>(_ op: (SOGoClient) async throws -> T) async throws -> T {
        guard let c = await client() else { throw SOGoError.needsLogin }
        let before = signOuts
        do {
            let r = try await op(c)
            if signOuts == before { set(.ok(clock.now)) }
            return r
        } catch SOGoError.needsLogin {
            if signOuts == before { set(.needsLogin) }
            throw SOGoError.needsLogin
        }
    }

    struct InboxReport: Equatable {
        var unseen: Int?
        var newMessages = 0
        var needsLogin = false
        var failure: String?
    }

    /// Posteingang lesen (erste Seite zuerst, vor allem anderen; `SyncReihenfolge`): Zwischenspeicher, ungelesene,
    /// neue seit dem letzten Blick (nur Zahl, fuer die Mitteilung)
    @discardableResult
    func refreshInbox(background: Bool = false) async -> InboxReport {
        guard isConnected, !isRunning, state != .needsLogin || !background else { return InboxReport() }
        isRunning = true
        defer { isRunning = false; finishedRuns += 1 }
        do {
            let listing = try await perform { try await $0.folder("INBOX") }
            await storeCache(listing)
            return apply(listing)
        } catch SOGoError.needsLogin {
            return InboxReport(needsLogin: true)
        } catch {
            if !(error is CancellationError) { set(.failed(Self.message(error))) }
            return InboxReport(failure: LocalBackendHost.message(for: error))
        }
    }

    /// Stand aus einer frischen Liste des Posteingangs uebernehmen
    @discardableResult
    func apply(_ listing: JSONValue) -> InboxReport {
        let uids = SOGo.flattenUIDs(listing["uids"])
        let last = defaults.object(forKey: Keys.lastUID) as? Int
        let fresh = SOGo.newSince(uids, last: last)
        if let top = uids.max() { defaults.set(max(top, last ?? 0), forKey: Keys.lastUID) }
        let n = listing["unseen"]?.int
        if let n { setUnseen(n) }
        return InboxReport(unseen: n, newMessages: fresh.count)
    }

    private func storeCache(_ listing: JSONValue) async {
        guard let db = try? await host.backend().context.database else { return }
        let now = clock.nowISO
        _ = try? await db.transaction { try SOGoMailCache.store($0, listing, fetchedAt: now) }
    }

    /// Zwischengespeicherte erste Seite des Posteingangs (ohne Netz)
    func cachedInbox() async -> JSONValue? {
        guard let db = try? await host.backend().context.database else { return nil }
        return try? await db.withConnection { try SOGoMailCache.cached($0, folder: "INBOX") }
    }

    /// Beim Oeffnen der App hoechstens alle 5 Minuten (nie unter XCTest)
    func runIfDue() {
        guard StudIPSync.automaticRunAllowed(), isConnected, state != .needsLogin, !isRunning else { return }
        if let l = lastCheck, clock.now.timeIntervalSince(l) < 5 * 60 { return }
        Task { await refreshInbox() }
    }

    // MARK: Mail (Knopfdruck)

    func listing(folder: String, query: String = "") async throws -> JSONValue {
        let l = try await perform { try await $0.folder(folder, query: query) }
        if folder == "INBOX", query.isEmpty {
            apply(l)
            await storeCache(l)
        }
        return l
    }

    func page(folder: String, uids: [Int], page: Int) async throws -> [JSONValue] {
        let want = SOGo.pageUIDs(uids, page: page)
        return try await perform { try await $0.headers(folder, uids: want) }
    }

    func mailboxes() async throws -> [JSONValue] { try await perform { try await $0.mailboxes() } }

    /// Lesen (SOGo markiert dabei als gelesen); danach die Zahl der ungelesenen neu
    func read(folder: String, uid: Int, wasUnread: Bool) async throws -> JSONValue {
        let m = try await perform { try await $0.message(folder, uid: uid) }
        if folder == "INBOX", wasUnread { setUnseen(unseen - 1) }
        return m
    }

    func setRead(folder: String, uid: Int, read: Bool) async throws {
        try await perform { try await $0.markRead(folder, uid: uid, read: read) }
        if folder == "INBOX" { setUnseen(unseen + (read ? -1 : 1)) }
    }

    func setFlag(folder: String, uid: Int, flagged: Bool) async throws {
        try await perform { try await $0.flag(folder, uid: uid, flagged: flagged) }
    }

    /// In den Papierkorb (nach Ablauf der Zeit fuer "Rückgängig" in der Oberflaeche); nie endgueltig
    func trash(folder: String, uids: [Int], unread: Int = 0) async throws {
        try await perform { try await $0.trash(folder, uids: uids) }
        if folder == "INBOX", unread > 0 { setUnseen(unseen - unread) }
    }

    /// Aus dem Papierkorb zurueck in den Posteingang
    func restore(uids: [Int], boxes: [JSONValue]) async throws {
        let trash = SOGo.folder(ofType: "trash", in: boxes, fallback: "Trash"), inbox = SOGo.folder(ofType: "inbox", in: boxes, fallback: "INBOX")
        try await perform { try await $0.move(trash, uids: uids, to: inbox) }
    }

    func newDraft(_ action: String, folder: String = "INBOX", uid: Int? = nil) async throws -> JSONValue {
        try await perform { try await $0.newDraft(action, folder: folder, uid: uid) }
    }

    func save(_ draft: JSONValue, body: JSONValue) async throws {
        _ = try await perform { try await $0.save(draft, body: body) }
    }

    func attach(_ draft: JSONValue, name: String, data: Data, mime: String) async throws -> JSONValue {
        try await perform { try await $0.attach(draft, name: name, data: data, mime: mime) }
    }

    /// Senden: nur aus dem Knopf "Senden" (nach der Rueckfrage); genau ein Versuch
    func send(_ draft: JSONValue, body: JSONValue) async throws -> (ok: Bool, message: String) {
        if let err = SOGo.checkSend(body) { throw SOGoError.input(err) }
        sendCount += 1
        return try await perform { try await $0.send(draft, body: body) }
    }

    /// Anhang in einen Temp-Ordner (Oeffnen, Teilen); Rueckgabe: Datei
    func download(_ attachment: JSONValue) async throws -> URL {
        let path = attachment["path"]?.string ?? ""
        let url = try AppTemp.file("uni-mail", name: attachment["name"]?.string ?? "Anhang")
        try await perform { try await $0.download(path, to: url) }
        return url
    }

    // MARK: Kalender

    /// Termine der naechsten 7 bzw. 30 Tage in den Lernkalender/Stundenplan (Quelle "Uni-Kalender", nur lesend)
    @discardableResult
    func importCalendar(days: Int) async -> String {
        let d = days > 7 ? 30 : 7
        let today = SOGo.berlinDay(clock)
        do {
            let events = try await perform { try await $0.events(day: today, days: d) }
            let db = try await host.backend().context.database
            let now = clock.nowISO
            let n = try await db.transaction { try SOGoCalendar.store($0, events, first: today, last: today + d, fetchedAt: now) }
            defaults.set(clock.now, forKey: Keys.calendarRun)
            defaults.set(d, forKey: Keys.calendarDays)
            let allDay = events.filter { $0["all_day"]?.bool == true }.count
            let msg = "\(n) \(n == 1 ? "Termin" : "Termine") der nächsten \(d) Tage übernommen" + (allDay > 0 ? " (\(allDay) ganztägig, nur hier in der Liste)." : ".")
            calendarMessage = msg
            finishedRuns += 1
            return msg
        } catch SOGoError.needsLogin {
            calendarMessage = "Uni-Kalender: Anmeldung nötig"
            return calendarMessage ?? ""
        } catch {
            calendarMessage = "Uni-Kalender: \(LocalBackendHost.message(for: error))"
            return calendarMessage ?? ""
        }
    }

    /// Uebernommene Termine ab heute
    func upcomingEvents(days: Int = 30) async -> [JSONValue] {
        guard let db = try? await host.backend().context.database else { return [] }
        let today = SOGo.berlinDay(clock)
        return (try? await db.withConnection { try SOGoCalendar.stored($0, first: today, last: today + days) }) ?? []
    }

    /// Termine schon einmal uebernommen und seit 20 Stunden nicht mehr: im langen Hintergrundlauf erneuern
    var calendarDue: Bool {
        guard let last = defaults.object(forKey: Keys.calendarRun) as? Date else { return false }
        return clock.now.timeIntervalSince(last) >= 20 * 3600
    }

    var calendarDays: Int { defaults.integer(forKey: Keys.calendarDays) > 7 ? 30 : 7 }

    // MARK: Anzeige

    static func statusText(_ s: State, now: Date = Date()) -> String {
        switch s {
        case .notConnected: return "Uni-Mail: nicht verbunden"
        case .connected: return "Uni-Mail: verbunden"
        case .running: return "Uni-Mail: liest …"
        case .ok(let d): return "Uni-Mail: \(HildesheimConnection.time(d, now: now)) ok"
        case .needsLogin: return "Uni-Mail: Anmeldung nötig"
        case .failed: return "Uni-Mail: Fehler"
        }
    }

    /// Fehlertext fuer die Oberflaeche
    static func message(_ error: Error) -> String {
        if let e = error as? SOGoError { return e.description }
        return LocalBackendHost.message(for: error)
    }
}

extension UniMailConnection: ContainerSync {}
