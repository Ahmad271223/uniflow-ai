import Foundation
import UniFlowCore
import WebKit

// Uni-Mail und Uni-Kalender (SOGo) der LUH (https://kalender.uni-hannover.de/SOGo/) und der Uni Hildesheim
// (https://webmail.uni-hildesheim.de/SOGo/, seit 06.11.2026), docs/UNI-MAIL-2026-11-05.md. Rechner, Namen und
// Raum-Links aus `SOGoSite` der Hochschule des Containers; jeder Container hat seine eigenen Cookies (Webdaten).
// Duenne Schicht ueber dem Kern (`SOGo`, `SOGoClient`, `SOGoCalendar`), wie `QISConnection` fuer das QIS: Anmeldung in
// der Webansicht des Containers auf der echten SOGo-Seite (eigenes Formular; das Passwort tippt der Mensch, merken darf
// es nur iOS), gespeichert werden nur die Cookies (`UniWebSessions`, Schluesselbund) und der Kontoname aus der Adresse
// (/SOGo/so/<benutzer>/). Abgelaufen (Anmeldeformular, 401/403) heisst "Anmeldung nötig"; keine stille Erneuerung.
// E-Mails bleiben auf dem iPad: nur die Kopfzeilen der ersten Seite des Posteingangs liegen fuer die Anzeige ohne Netz
// in der Datenbank des Containers, Inhalte nur im Arbeitsspeicher, Anhaenge in einem Temp-Ordner zum Oeffnen/Teilen.
// Nichts geht an StudiNow-Server. Senden nur ueber `send` (Knopf "Senden" mit Rueckfrage), genau einmal.
//
// Uni Goettingen (27.11.2026, docs/GOETTINGEN-MAIL-2026-11-27.md): Exchange der GWDG ueber IMAP/SMTP statt SOGo
// (`site.isIMAP`, Kern `IMAPMailClient`). Anmeldung im eigenen Formular (Kennung und Passwort tippt der Mensch), ein
// Versuch je Eingabe; das Passwort liegt nur im Schluesselbund dieses Geraets (derselbe Uni-Zugang wie fuer Stud.IP,
// `UniAutoLogin`) oder - ohne "merken" - nur im Arbeitsspeicher bis zum Beenden. Lehnt der Mail-Rechner es ab, wird
// genau dieses Passwort nie wieder an ihn gesendet (Merker `Keys.imapRejected`). Kein Uni-Kalender (Exchange).

/// Verbindung zu Uni-Mail/Uni-Kalender fuer einen Container der LUH oder der Uni Hildesheim
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
    /// Die automatische Anmeldung mit dem gespeicherten Uni-Zugang hat nicht geklappt (15.11.2026): die Karte sagt dann
    /// klar "bitte einmal von Hand anmelden" statt nur "nicht verbunden". Weg mit der naechsten Anmeldung.
    @Published private(set) var autoConnectFailed = false
    static let autoConnectFailedText = "Die automatische Anmeldung bei Uni-Mail hat nicht geklappt. Bitte melde dich einmal von Hand an – danach bleibt Uni-Mail verbunden."
    static let notRecognizedText = "Die Anmeldung wurde noch nicht erkannt. Bitte melde dich oben auf der Seite an; danach schließt sich dieses Fenster von selbst."
    /// Zahl der Anfragen an .../send (Tests; nie mehr als Knopfdruecke)
    private(set) var sendCount = 0

    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport
    /// IMAP/SMTP-Verbindungen (Tests: Nachbildung; sonst nur zu den Rechnern der Hochschule)
    typealias MailOpenerFactory = @MainActor (IMAPMailSite) -> MailStreamOpener

    let key: DataContainerKey
    /// SOGo der Hochschule des Containers (Rechner, Anzeigename, Raum-Links)
    let site: SOGoSite
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    private let makeOpener: MailOpenerFactory
    /// offene IMAP-Verbindung (Uni Goettingen)
    private var imapClient: IMAPMailClient?
    /// Passwort nur fuer diesen Lauf der App ("Passwort merken" aus); nie gespeichert
    private var sessionLogin: (username: String, password: String)?
    var refreshesAfterSignIn = true
    private(set) var stopped = false
    private var signOuts = 0

    /// Rechner, an die Anfragen gehen und deren Cookies "Abmelden" loescht: nur SOGo dieser Hochschule
    var domains: [String] { [site.host] }
    static let signOutMessage = "Die Anmeldung bei Uni-Mail wird in der Webansicht gelöscht, ebenso die zwischengespeicherte Liste des Posteingangs und die übernommenen Termine des Uni-Kalenders. Deine E-Mails bleiben in deinem Uni-Postfach. Ein in StudiNow gemerktes Passwort der Hochschule wird gelöscht; eines, das iOS gesichert hat, bleibt unter „Passwörter“."
    static let imapSignOutMessage = "Die Verbindung zu Uni-Mail wird getrennt und die zwischengespeicherte Liste des Posteingangs gelöscht. Deine E-Mails bleiben in deinem Uni-Postfach. Ein in StudiNow gemerktes Passwort der Hochschule wird gelöscht (auch für Stud.IP); eines, das iOS gesichert hat, bleibt unter „Passwörter“."
    var signOutText: String { site.isIMAP ? Self.imapSignOutMessage : Self.signOutMessage }
    static func hint(_ site: SOGoSite) -> String {
        if site.isIMAP {
            return UFDevice.adapt("Uni-Mail der \(site.universityName) (Exchange der GWDG): E-Mails lesen, beantworten, weiterleiten und schreiben. Du meldest dich mit deiner Uni-Kennung an; StudiNow verbindet sich verschlüsselt direkt mit dem Mail-Rechner der Uni. Dein Passwort merkt StudiNow nur, wenn du es zulässt, und nur auf diesem iPad. E-Mails bleiben auf diesem iPad und in deinem Uni-Postfach, nichts geht an StudiNow-Server.")
        }
        return UFDevice.adapt("Uni-Mail und Uni-Kalender (SOGo) der \(site.universityName): E-Mails lesen, beantworten, weiterleiten und schreiben, Termine im \(LearnCalendar.text("Lernkalender", off: "Stundenplan")). Du meldest dich auf der echten SOGo-Seite an; dein Passwort merkt StudiNow nur, wenn du es zulässt, und nur auf diesem iPad. E-Mails bleiben auf diesem iPad und in deinem Uni-Postfach, nichts geht an StudiNow-Server.")
    }
    var hint: String { Self.hint(site) }

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
        /// IMAP: abgelehnter Zugang ("<benutzer>|<gespeichert um>"), nie wieder senden
        static let imapRejected = "uniflow.imap.rejected"
        static let all = [connected, user, login, unseen, lastUID, lastCheck, notify, calendarRun, calendarDays, imapRejected]
    }

    init(container c: ActiveContainer, site: SOGoSite, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = UniRetry(), mailOpener: MailOpenerFactory? = nil) {
        key = c.key
        self.site = site
        host = c.host
        defaults = c.defaults
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        let domains = [site.host]
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store, allowedDomains: domains) }
        makeOpener = mailOpener ?? { SystemMailStreamOpener(site: $0) }
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

    /// Angemeldete Seite erkannt (Adresse https://<rechner der hochschule>/SOGo/so/<benutzer>/...); Konto merken, Cookies sichern, Posteingang lesen
    func signedIn(user u: String) {
        defaults.set(true, forKey: Keys.connected)
        defaults.set(u, forKey: Keys.user)
        user = u
        autoConnectFailed = false
        set(.connected)
        let store = websiteDataStore
        UniAutoLogin.clearSignedOut(.sogo, store: store)       // angemeldet: die Abmelden-Sperre faellt
        BackgroundReloginLedger.foregroundSuccess(OpenSync.uniMail, defaults: defaults)
        if !site.isIMAP {
            UniAutoLogin.signedIn(store, portal: .sogo)        // mitgelesenes Passwort jetzt merken (falls zugelassen)
            Task { await UniWebSessions.save(store) }
        }
        guard refreshesAfterSignIn else { return }
        Task { await refreshInbox() }
    }

    /// Abmelden: Cookies von SOGo, Einstellungen, Zwischenspeicher und uebernommene Termine; nie Mails im Postfach
    func signOut() async {
        signOuts += 1
        for k in Keys.all { defaults.removeObject(forKey: k) }
        UniAutoLogin.forget(websiteDataStore)                  // gemerktes Passwort der Hochschule (Schluesselbund)
        UniAutoLogin.markSignedOut(.sogo, store: websiteDataStore)  // bewusst abgemeldet: nie still wieder verbinden
        user = nil
        setUnseen(0)
        calendarMessage = nil
        set(.notConnected)
        let imap = imapClient
        imapClient = nil
        sessionLogin = nil
        if let imap { await imap.close() }
        if let db = try? await host.backend().context.database {
            _ = try? await db.transaction { c in
                try SOGoCalendar.forget(c)
                try SOGoMailCache.forget(c)
            }
        }
        await UniWebSessions.ready(websiteDataStore)
        let store = websiteDataStore.httpCookieStore
        for c in await store.allCookies() where UniCookiePolicy.matches(c, domains) {
            await store.deleteCookie(c)
        }
        await UniWebSessions.save(websiteDataStore)
        finishedRuns += 1
    }

    /// Anhalten, bevor der Container geloescht wird. Ein laufender Abruf (Posteingang, Kalender) endet danach wie nach
    /// dem Abmelden ohne zu schreiben (`signOuts`): vorher setzte er nach dem Loeschen "zuletzt geprueft", ungelesene und
    /// Kalendertermine wieder in die geloeschte Einstellungs-Suite bzw. den leer neu geoeffneten Container (Audit
    /// 08.11.2026, P37-03)
    func stop() async {
        stopped = true
        signOuts += 1
        let imap = imapClient
        imapClient = nil
        sessionLogin = nil
        if let imap { await imap.close() }
    }

    // MARK: Abruf

    #if DEBUG
    /// Nur Debug-Builds (Store-Bildschirmfotos, `StoreScreenshotV11Tests`): Uni-Mail auch mit Demo-Inhalten lesen,
    /// gegen eine erfundene Nachbildung im Test (nie ein Netz). Im Release gibt es den Schalter nicht.
    static var readsDemoForScreenshots = false
    #endif

    /// Client mit den Cookies der Webansicht (SOGo) bzw. die IMAP-Verbindung; nil ohne Verbindung, nach dem Anhalten
    /// oder mit Demo-Inhalten
    func client() async -> UniMailBackend? {
        guard isConnected, !stopped, let user else { return nil }
        if await host.demoActive() {
            #if DEBUG
            if !Self.readsDemoForScreenshots { return nil }
            #else
            return nil
            #endif
        }
        if let imap = site.imap {
            if let c = imapClient { return c }
            let c = makeIMAPClient(imap, address: user)
            imapClient = c
            return c
        }
        await UniWebSessions.ready(websiteDataStore)
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        let transport = await makeTransport(websiteDataStore)
        return SOGoClient(user: user, site: site, transport: transport, xsrf: SOGoClient.xsrf(from: cookies, site: site), retry: retry)
    }

    /// Eine Aktion mit dem Postfach; abgelaufene Anmeldung setzt "Anmeldung nötig", Erfolg "ok"
    func perform<T>(_ op: (UniMailBackend) async throws -> T) async throws -> T {
        // vor dem Client: wer waehrend seines Aufbaus abmeldet oder anhaelt, bekommt keinen Stand geschrieben
        let before = signOuts
        guard let c = await client() else { throw SOGoError.needsLogin }
        if site.isIMAP {
            do {
                let r = try await op(c)
                if signOuts == before { set(.ok(clock.now)) }
                return r
            } catch IMAPMailError.rejected {
                if signOuts == before { imapRejected(); set(.needsLogin) }
                throw SOGoError.needsLogin
            } catch SOGoError.needsLogin {
                if signOuts == before { set(.needsLogin) }
                throw SOGoError.needsLogin
            }
        }
        do {
            let r = try await op(c)
            if signOuts == before { set(.ok(clock.now)) }
            return r
        } catch SOGoError.needsLogin {
            // automatisch anmelden (gespeichertes Passwort, nur mit Zustimmung), dann genau einmal neu versuchen
            if signOuts == before, await autoLogin(), signOuts == before, let again = await client() {
                do {
                    let r = try await op(again)
                    if signOuts == before { set(.ok(clock.now)) }
                    UniAutoLogin.succeeded(portal: "sogo", store: websiteDataStore)
                    return r
                } catch SOGoError.needsLogin {}
            }
            if signOuts == before { set(.needsLogin) }
            throw SOGoError.needsLogin
        }
    }

    /// Automatisch anmelden (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): unsichtbar auf der SOGo-Seite mit dem
    /// gespeicherten Passwort; fertig, sobald SOGo das gemerkte Konto zeigt (/SOGo/so/<benutzer>/). Kein Abruf hier:
    /// die gescheiterte Aktion wiederholt `perform` genau einmal.
    @discardableResult
    /// `background`: aus dem Hintergrundlauf (Version 1.3/1.4, `UniAutoLogin.handleExpiry`)
    func autoLogin(userAction: Bool = false, background: Bool = false) async -> Bool {
        guard isConnected, !stopped, let account = user, !site.isIMAP else { return false }
        let before = signOuts
        let site = self.site
        let d = await UniAutoLogin.handleExpiry(portal: "sogo", store: websiteDataStore, entry: site.loginURL,
                                                userAction: userAction, background: background) { url, _ in SOGo.user(fromURL: url, site: site) == account }
        guard d == .retryOnce, signOuts == before, isConnected else { return false }
        set(.connected)
        return true
    }

    /// Uni-Zugang einmal speichern (10.11.2026): noch nie verbunden -> mit dem gespeicherten Zugang zum ersten Mal auf der
    /// SOGo-Seite anmelden (unsichtbar, nur im Vordergrund); fertig, sobald SOGo ein Konto zeigt (/SOGo/so/<benutzer>/).
    /// Dann wie nach einer Anmeldung von Hand (`signedIn(user:)`, liest den Posteingang). Nie nach bewusstem Abmelden.
    @discardableResult
    func connectWithStoredLogin(userAction: Bool = false) async -> Bool {
        guard !isConnected, !stopped, !UniAutoLogin.signedOut(.sogo, store: websiteDataStore) else { return false }
        if let imap = site.imap { return await connectIMAPWithStoredLogin(imap) }
        let before = signOuts
        let site = self.site
        let found = SignedInAccount()
        let d = await UniAutoLogin.handleExpiry(portal: "sogo", store: websiteDataStore, entry: site.loginURL,
                                                userAction: userAction) { url, _ in
            guard let u = SOGo.user(fromURL: url, site: site) else { return false }
            found.user = u
            return true
        }
        guard d == .retryOnce, signOuts == before, !isConnected, !stopped, let account = found.user else {
            if signOuts == before, !isConnected, !stopped { autoConnectFailed = true }
            return false
        }
        signedIn(user: account)
        return true
    }

    /// Schon bei SOGo angemeldet? (15.11.2026) Liegt im Datenspeicher der Webansicht eine gueltige SOGo-Sitzung (z. B.
    /// der Mensch hat sich auf der Seite angemeldet, die App hat es aber nicht erkannt), leitet SOGo die Startseite auf
    /// /SOGo/so/<benutzer>/… weiter: dann ist Uni-Mail verbunden, ohne Passwort und ohne Webansicht. Nur eine lesende
    /// Anfrage an den SOGo-Rechner dieser Hochschule. `userAction`: der Mensch hat es eben verlangt ("Fertig" im
    /// Anmeldefenster) - gilt auch nach einem frueheren bewussten Abmelden.
    @discardableResult
    func adoptExistingSession(userAction: Bool = false) async -> Bool {
        guard !isConnected, !stopped else { return isConnected }
        guard !site.isIMAP else { return false }                  // IMAP: keine Sitzung einer Webseite
        guard !DebugUniStub.isActive else { return false }       // Nachbildung der Anmeldeseite: nie ein echtes Netz
        guard userAction || !UniAutoLogin.signedOut(.sogo, store: websiteDataStore) else { return false }
        if await host.demoActive() { return false }
        let before = signOuts
        await UniWebSessions.ready(websiteDataStore)
        let transport = await makeTransport(websiteDataStore)
        guard let resp = try? await transport.send(UniRequest(url: site.loginURL)), signOuts == before, !isConnected, !stopped,
              let account = SOGo.user(fromURL: resp.finalURL, site: site) else { return false }
        signedIn(user: account)
        return true
    }

    /// Konto der angemeldeten SOGo-Seite (aus der Adresse), gefunden von der unsichtbaren Anmeldung
    @MainActor private final class SignedInAccount { var user: String? }

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
            let before = signOuts
            let listing = try await perform { try await $0.folder("INBOX", query: "") }
            // inzwischen abgemeldet: nichts mehr zwischenspeichern oder zaehlen
            guard signOuts == before, isConnected else { return InboxReport() }
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
        let before = signOuts
        do {
            guard !site.isIMAP else { return "" }                    // Exchange: kein Uni-Kalender in StudiNow
        let events = try await perform { c -> [JSONValue] in
            guard let sogo = c as? SOGoClient else { return [] }
            return try await sogo.events(day: today, days: d)
        }
            // inzwischen abgemeldet oder angehalten (Container geloescht): nichts mehr uebernehmen
            guard signOuts == before else { return "" }
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
        guard !site.isIMAP, let last = defaults.object(forKey: Keys.calendarRun) as? Date else { return false }
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
        if let e = error as? IMAPMailError { return e.description }
        return LocalBackendHost.message(for: error)
    }
}

extension UniMailConnection: ContainerSync {}

// MARK: - IMAP/SMTP (Uni Goettingen)

extension UniMailConnection {
    /// Zugang, mit dem die IMAP-Verbindung sich anmeldet: Passwort dieses Laufs oder der Uni-Zugang im Schluesselbund;
    /// nie einer, den der Mail-Rechner schon abgelehnt hat
    func imapLogin() -> (username: String, password: String, marker: String)? {
        if let s = sessionLogin { return (s.username, s.password, "") }
        guard let e = UniAutoLogin.entry(websiteDataStore), let r = UniAutoLogin.resolvedCredential(.sogo, entry: e) else { return nil }
        let marker = Self.rejectionMarker(r.credential)
        if defaults.string(forKey: Keys.imapRejected) == marker { return nil }
        return (r.credential.username, r.credential.password, marker)
    }

    static func rejectionMarker(_ c: UniCredential) -> String { "\(c.username)|\(c.savedAt.timeIntervalSince1970)" }

    /// Hat der Mail-Rechner den gespeicherten Uni-Zugang abgelehnt? (Karte: "Passwort abgelehnt")
    var imapLoginRejected: Bool { defaults.string(forKey: Keys.imapRejected) != nil && imapLogin() == nil }

    /// Benutzername des gespeicherten Uni-Zugangs (Vorgabe im Formular)
    var storedUsername: String? {
        guard let e = UniAutoLogin.entry(websiteDataStore) else { return nil }
        return UniAutoLogin.resolvedCredential(.sogo, entry: e)?.credential.username
    }

    /// Liegt ein gespeicherter, nicht abgelehnter Uni-Zugang bereit?
    var hasUsableStoredLogin: Bool { sessionLogin == nil && imapLogin() != nil }

    /// Der Mail-Rechner hat den Zugang abgelehnt: Passwort dieses Laufs vergessen, gespeichertes markieren (der Eintrag
    /// bleibt fuer Stud.IP, das ihn vielleicht annimmt; an den Mail-Rechner geht er nie wieder)
    func imapRejected() {
        if sessionLogin != nil {
            sessionLogin = nil                                      // abgelehnt war das Getippte, nicht der gespeicherte Zugang
        } else if let e = UniAutoLogin.entry(websiteDataStore), let r = UniAutoLogin.resolvedCredential(.sogo, entry: e) {
            defaults.set(Self.rejectionMarker(r.credential), forKey: Keys.imapRejected)
        }
        let c = imapClient
        imapClient = nil
        if let c { Task { await c.close() } }
    }

    func makeIMAPClient(_ imap: IMAPMailSite, address: String, login: (username: String, password: String)? = nil) -> IMAPMailClient {
        let opener = makeOpener(imap)
        let clock = self.clock
        let box = IMAPLoginBox()
        box.fixed = login
        return IMAPMailClient(site: imap, address: address, opener: opener, now: { clock.now }) { [weak self] in
            if let f = box.fixed { return f }
            return await self?.currentIMAPLogin()
        }
    }

    private func currentIMAPLogin() -> (username: String, password: String)? {
        imapLogin().map { ($0.username, $0.password) }
    }

    /// Anmelden im Formular (Knopf "Anmelden"): genau ein Versuch mit dem, was der Mensch getippt hat. Erst wenn der
    /// Mail-Rechner annimmt, kommt das Passwort in den Schluesselbund (mit "merken") bzw. nur in den Arbeitsspeicher.
    /// Rueckgabe: Fehlertext oder nil
    func signInIMAP(username typed: String, password: String, remember: Bool) async -> String? {
        guard let imap = site.imap, !stopped else { return "Uni-Mail ist hier nicht über IMAP verbunden." }
        let account = imap.account(typed)
        guard UniLoginForms.isAcceptableUsername(account), !account.isEmpty else { return "Bitte deine Uni-Kennung eingeben (z. B. vorname.nachname)." }
        guard UniLoginForms.isAcceptablePassword(password), !password.isEmpty else { return "Bitte dein Passwort eingeben." }
        if await host.demoActive() { return "Mit Demo-Inhalten verbindet StudiNow keine Uni-Mail." }
        let before = signOuts
        let c = makeIMAPClient(imap, address: imap.address(account), login: (account, password))
        do {
            try await c.verify()
        } catch IMAPMailError.rejected {
            await c.close()
            return "Kennung oder Passwort wurden abgelehnt. Bitte prüfe beides. (Es wird nichts automatisch wiederholt.)"
        } catch {
            await c.close()
            return Self.message(error)
        }
        guard signOuts == before, !stopped else { await c.close(); return nil }
        var saved = false
        if remember {
            // ein Zugang je Hochschule (Uni Goettingen: derselbe wie fuer Stud.IP, Einstellungen "Uni-Zugang")
            saved = UniAutoLogin.saveTyped(username: account, password: password, store: websiteDataStore) == .saved
        }
        sessionLogin = saved ? nil : (account, password)
        defaults.removeObject(forKey: Keys.imapRejected)
        let old = imapClient
        imapClient = makeIMAPClient(imap, address: imap.address(account))
        if let old { await old.close() }
        await c.close()
        signedIn(user: imap.address(account))
        return nil
    }

    /// Erstes Verbinden mit dem gespeicherten Uni-Zugang (`connectWithStoredLogin`): genau ein Versuch
    func connectIMAPWithStoredLogin(_ imap: IMAPMailSite) async -> Bool {
        guard let login = imapLogin(), !login.marker.isEmpty else { return false }
        if await host.demoActive() { return false }
        let before = signOuts
        let account = imap.account(login.username)
        let c = makeIMAPClient(imap, address: imap.address(account), login: (login.username, login.password))
        do {
            try await c.verify()
        } catch IMAPMailError.rejected {
            await c.close()
            if signOuts == before { defaults.set(login.marker, forKey: Keys.imapRejected); autoConnectFailed = true }
            return false
        } catch {
            await c.close()
            if signOuts == before, !isConnected { autoConnectFailed = true }
            return false
        }
        await c.close()
        guard signOuts == before, !isConnected, !stopped else { return false }
        signedIn(user: imap.address(account))
        return true
    }
}

/// Fester Zugang fuer die Pruefung im Formular (sonst der aktuelle aus `imapLogin`)
private final class IMAPLoginBox: @unchecked Sendable { var fixed: (username: String, password: String)? }


// MARK: - Mit KI verbessern (13.11.2026)

extension UniMailConnection {
    /// Fehler von "Mit KI verbessern" mit Code des Dienstes (z. B. quota_exhausted, plan_required)
    struct RewriteError: Error, Equatable {
        let code: String?
        let message: String
    }

    /// Vorschlag der StudiNow-KI fuer den Text einer E-Mail (`POST /api/ai/mail-rewrite` im lokalen Backend, beim Dienst
    /// Aufgabe `mail`: Pro AI, 50 je Monat). Gesendet wird hier nichts.
    func rewrite(subject: String, text: String) async throws -> String {
        let body = JSONValue.object(["subject": .string(subject), "text": .string(text)]).serialized()
        let backend = try await host.backend()
        let r = await backend.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/mail-rewrite")!,
                                                  headers: ["Content-Type": "application/json"], body: body))
        if r.status == 200, let t = r.json?["text"]?.string, !t.isEmpty { return t }
        let detail = r.json?["detail"]
        let code = detail?["code"]?.string ?? r.json?["code"]?.string
        let text = detail?["detail"]?.string ?? detail?.string ?? "Die KI konnte die E-Mail gerade nicht verbessern. Bitte später erneut versuchen."
        if r.status == 404 && code == nil {
            throw RewriteError(code: "no_ai", message: "Die StudiNow-KI ist nicht verbunden. Melde dich in den Einstellungen mit deinem StudiNow-Konto an.")
        }
        throw RewriteError(code: code, message: MailRewrite.message(code: code, fallback: text))
    }
}
