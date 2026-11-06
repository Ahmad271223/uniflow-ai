import Foundation
import UIKit
import UniFlowCore
import WebKit

// Hochschule Hannover auf dem iPad (docs/HSH-2026-11-05.md): Moodle (Kurse, Dateien, Fristen, Ankuendigungen) und
// Campusmanagement (HISinOne: Stundenplan, Leistungen, angemeldete Pruefungen; aeltere Fakultaeten ueber das alte QIS
// icms im Iframe). Die duenne Schicht der App ueber dem Kern (`HildesheimSync` mit `names: .hsh`, `LearnwebAPI` im
// Sitzungsmodus, `HISinOneClient`). Anmeldung in der Webansicht des Containers auf den echten Seiten (Moodle-Formular,
// SAML-IdP der HsH); das Passwort tippt der Mensch, merken darf es nur iOS. Gespeichert werden nur die Cookies der
// Webansicht und die persoenliche Abo-Adresse des Stundenplans (Schluesselbund, `hsh.ical.token`), nie ein Passwort.
// Moodle und HISinOne haben keine Einmalanmeldung untereinander: zwei Anmeldungen mit demselben SSO-Account.

/// Verbindung und Abgleich der Hochschule Hannover fuer einen Container (Apple-Nutzer, HsH)
@MainActor
final class HsHConnection: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case moodle = "Moodle"
        case campus = "Campusmanagement"
        var id: String { rawValue }
        /// Anmeldedienst im Profil (`UniversityProfile.hsh.loginServices`)
        var loginService: String { self == .moodle ? "moodle" : "campus" }
    }

    enum State: Equatable {
        case notConnected
        case connected
        case running
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var moodle: State = .notConnected
    @Published private(set) var campus: State = .notConnected
    @Published private(set) var isRunning = false
    @Published private(set) var messages: [String] = []
    @Published private(set) var lastRun: Date?
    @Published private(set) var finishedRuns = 0
    /// Meldung des letzten Lesens der angemeldeten Pruefungen
    @Published private(set) var registrationsMessage: String?
    /// Meldung des letzten Abrufs der Moodle-Nachrichten
    @Published private(set) var messagesNote: String?
    /// Studienservice (Rueckmeldung, Studiengang, offene Zahlungen, Bescheide), aus der Datenbank
    @Published private(set) var studyService: JSONValue?
    private(set) var lastReport: HildesheimSync.Report?

    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    let layout: DataContainerLayout
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    /// Abo-Adresse des Stundenplans (persoenlich, wie ein Schluessel)
    let tokens: UniversityTokenStore
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    var syncsAfterSignIn = true
    private var current: Task<HildesheimSync.Report?, Never>?
    private(set) var stopped = false
    private var signOuts = 0

    /// Rechner der HsH, zu denen Anfragen gehen duerfen (Moodle, HISinOne, IdP, altes QIS)
    static let domains = ["moodle.hs-hannover.de", "campusmanagement.hs-hannover.de", "idp.hs-hannover.de", "icms.hs-hannover.de"]
    static let icalService = "ical"
    static let signOutMessage = "Die Anmeldungen bei Moodle und im Campusmanagement werden in der Webansicht gelöscht, die gemerkte Stundenplan-Adresse ebenso. Dateien, Stundenplan und Leistungen bleiben. Ein in StudiNow gemerktes Passwort der HsH wird gelöscht; eines, das iOS gesichert hat, bleibt unter „Passwörter“."

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = UniRetry()) {
        key = c.key
        layout = c.layout
        host = c.host
        defaults = c.defaults
        tokens = c.tokens
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store, allowedDomains: HsHConnection.domains) }
        lastRun = defaults.object(forKey: Keys.lastRun) as? Date
        messages = defaults.stringArray(forKey: Keys.messages) ?? []
        moodle = storedState(.moodle)
        campus = storedState(.campus)
        StudyCatalogSync.attach(host: host)      // Studiengang aus den Leistungen -> Modulkatalog (Studienverlauf)
        let h = host
        Task { [weak self] in
            let stored = try? await h.backend().context.database.withConnection { try HISinOneStudyService.stored($0) }
            self?.studyService = stored ?? nil
        }
    }

    enum Keys {
        static func connected(_ s: Source) -> String { "uniflow.hsh.\(s.loginService).connected" }
        static func ok(_ s: Source) -> String { "uniflow.hsh.\(s.loginService).ok" }
        static func login(_ s: Source) -> String { "uniflow.hsh.\(s.loginService).login" }
        static let lastRun = "uniflow.hsh.lastRun"
        static let messages = "uniflow.hsh.messages"
        static let gradesRun = "uniflow.hsh.grades.lastRun"
        static var all: [String] {
            Source.allCases.flatMap { [connected($0), ok($0), login($0)] } + [lastRun, messages, gradesRun]
        }
    }

    func isConnected(_ s: Source) -> Bool { defaults.bool(forKey: Keys.connected(s)) }
    var anyConnected: Bool { Source.allCases.contains(where: isConnected) }
    func state(_ s: Source) -> State { s == .moodle ? moodle : campus }
    func needsAttention(_ s: Source) -> Bool { state(s) == .notConnected || state(s) == .needsLogin }

    private func storedState(_ s: Source) -> State {
        guard isConnected(s) else { return .notConnected }
        if defaults.bool(forKey: Keys.login(s)) { return .needsLogin }
        return (defaults.object(forKey: Keys.ok(s)) as? Date).map(State.ok) ?? .connected
    }

    private func set(_ s: Source, _ state: State) {
        if s == .moodle { moodle = state } else { campus = state }
        switch state {
        case .ok(let d):
            defaults.set(d, forKey: Keys.ok(s))
            defaults.removeObject(forKey: Keys.login(s))
        case .needsLogin:
            defaults.set(true, forKey: Keys.login(s))
        case .connected, .notConnected:
            defaults.removeObject(forKey: Keys.login(s))
        case .running, .failed:
            break
        }
    }

    // MARK: Anmeldung (HsHLoginPane)

    /// Angemeldete Seite erkannt: Moodle (sesskey, keine Anmeldeseite) bzw. HISinOne (Abmelden-Link)
    static func isSignedIn(_ s: Source, html: String, url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        switch s {
        case .moodle:
            return url.host?.lowercased() == UniversityProfile.hshMoodle.host && !url.path.hasPrefix("/login/")
                && Learnweb.isLoggedIn(html: html)
        case .campus:
            return HISinOne.isLoggedIn(html: html, url: url)
        }
    }

    func signedIn(_ s: Source) {
        defaults.set(true, forKey: Keys.connected(s))
        set(s, .connected)
        let store = websiteDataStore
        UniAutoLogin.signedIn(store)                           // mitgelesenes Passwort jetzt merken (falls zugelassen)
        Task { await UniWebSessions.save(store) }              // Sitzungen ueber Neustarts merken
        guard syncsAfterSignIn, !isRunning else { return }
        Task { await run(forceGrades: s == .campus) }
    }

    /// Abmelden: Verbindungen, Abo-Adresse und die Cookies der HsH in der Webansicht; Daten bleiben
    func signOut() async {
        signOuts += 1
        if let task = current {
            task.cancel()
            _ = await task.value
        }
        for k in Keys.all { defaults.removeObject(forKey: k) }
        UniAutoLogin.forget(websiteDataStore)                  // gemerktes Passwort der HsH (Schluesselbund)
        tokens.deleteAll(for: .hsh)
        messages = []
        for s in Source.allCases { set(s, .notConnected) }
        await UniWebSessions.ready(websiteDataStore)
        let store = websiteDataStore.httpCookieStore
        for c in await store.allCookies() where Self.domains.contains(where: { c.domain.lowercased().hasSuffix($0) }) {
            await store.deleteCookie(c)
        }
        await UniWebSessions.save(websiteDataStore)
    }

    // MARK: Abgleich

    private var gradesDue: Bool {
        guard let last = defaults.object(forKey: Keys.gradesRun) as? Date else { return true }
        return clock.now.timeIntervalSince(last) >= 20 * 3600
    }

    /// Beim Oeffnen der App hoechstens alle 30 Minuten, nur verbunden; nie unter XCTest (wie Stud.IP)
    func runIfDue() {
        guard StudIPSync.automaticRunAllowed(), anyConnected, !isRunning else { return }
        if let last = lastRun, clock.now.timeIntervalSince(last) < 30 * 60 { return }
        Task { await run() }
    }

    var savedICal: URL? { tokens.token(.hsh, service: Self.icalService).flatMap(URL.init(string:)).flatMap { HISinOne.isExportURL($0) ? $0 : nil } }

    /// Quellen eines Laufs: alle verbundenen; im Hintergrund nur die ohne bekannte abgelaufene Anmeldung (der
    /// Stundenplan kommt dort auch mit abgelaufener Campus-Sitzung ueber die gemerkte Abo-Adresse)
    func sources(background: Bool) -> Set<Source> {
        Set(Source.allCases.filter { s in
            isConnected(s) && (!background || state(s) != .needsLogin || (s == .campus && savedICal != nil))
        })
    }

    /// Ein Abgleich in der Reihenfolge des Inhabers: aktuelles Semester zuerst (Moodle-Kurse mit Dateien, Fristen,
    /// Ankuendigungen, Stundenplan), dann Leistungen und angemeldete Pruefungen, dann Nachrichten und Studienservice;
    /// Kurse frueherer Semester ohne Dateien (`OlderSemesters`). `scope: .lists` (kurzer Hintergrundlauf): ohne
    /// Downloads, Leistungen und Studienservice; `background`: nur `sources(background:)`.
    @discardableResult
    func run(forceGrades: Bool = false, scope: UniSyncScope = .full, background: Bool = false) async -> HildesheimSync.Report? {
        guard !isRunning, !stopped, !sources(background: background).isEmpty else { return nil }
        let signOutsBefore = signOuts
        if await host.demoActive() { return nil }
        guard !isRunning, !stopped, signOuts == signOutsBefore, !sources(background: background).isEmpty else { return nil }
        guard ContainerRuns.claim(layout.learnweb, by: self) else { return nil }
        isRunning = true
        let task = Task { await self.perform(forceGrades: forceGrades, scope: scope, background: background) }
        current = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        ContainerRuns.release(layout.learnweb, by: self)
        isRunning = false
        finishedRuns += 1
        return report
    }

    func stop() async {
        stopped = true
        guard let task = current else { return }
        task.cancel()
        _ = await task.value
    }

    /// Stufe (d) des Abgleichs (`SyncOrder`, `OlderSemesterLoader`) und "Dateien laden" in der Bibliothek: nur die
    /// Moodle-Dateien gewuenschter Kurse frueherer Semester (`OlderSemesters.pending`), neuestes Semester zuerst; kein
    /// Campusmanagement, Stand des letzten vollen Abgleichs bleibt. Laeuft gerade ein Abgleich, kommt sie danach.
    @discardableResult
    func loadOlderFiles() async -> String? {
        guard !isRunning, !stopped else { return isRunning ? StudIPSync.olderQueuedNote : nil }
        guard isConnected(.moodle) else { return nil }
        if await host.demoActive() { return nil }
        guard !isRunning, !stopped, ContainerRuns.claim(layout.learnweb, by: self) else { return StudIPSync.olderQueuedNote }
        isRunning = true
        let task = Task { () -> HildesheimSync.Report? in
            let transport = await self.makeTransport(self.websiteDataStore)
            guard let database = try? await self.host.backend().context.database else { return nil }
            let api = LearnwebAPI(base: UniversityProfile.hshMoodle.absoluteString, mode: .session, transport: transport, retry: self.retry)
            return await HildesheimSync(db: database, container: self.layout, learnweb: api, lsf: nil, transport: transport,
                                        clock: self.clock, retry: self.retry, tools: AppDocumentTools(), names: .hsh)
                .run(includeGrades: false, downloads: true, olderOnly: true)
        }
        current = task
        let r = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        ContainerRuns.release(layout.learnweb, by: self)
        isRunning = false
        finishedRuns += 1
        guard let r, !r.cancelled else { return nil }
        return r.needsLogin.isEmpty
            ? "\(r.newFiles.count) \(r.newFiles.count == 1 ? "Datei" : "Dateien") aus früheren Semestern geladen"
            : "Moodle: Anmeldung nötig"
    }

    private func perform(forceGrades: Bool, scope: UniSyncScope, background: Bool) async -> HildesheimSync.Report? {
        let sources = self.sources(background: background)
        for s in sources { set(s, .running) }
        let transport = await makeTransport(websiteDataStore)
        let api = sources.contains(.moodle)
            ? LearnwebAPI(base: UniversityProfile.hshMoodle.absoluteString, mode: .session, transport: transport, retry: retry) : nil
        let saved = savedICal
        let campusClient = sources.contains(.campus) || saved != nil
            ? HISinOneClient(transport: transport, retry: retry, savedICal: saved) : nil
        let includeGrades = scope == .full && sources.contains(.campus) && state(.campus) != .needsLogin && (forceGrades || gradesDue)
        guard let database = try? await host.backend().context.database else {
            for s in sources { set(s, .failed("Datenbank nicht lesbar")) }
            return nil
        }
        let report = await HildesheimSync(db: database, container: layout, learnweb: api, lsf: campusClient, transport: transport,
                                          clock: clock, retry: retry, tools: AppDocumentTools(), names: .hsh)
            .run(includeGrades: includeGrades, downloads: scope == .full)
        if let campusClient, let found = await campusClient.foundICal, found != saved {
            _ = tokens.saveToken(found.absoluteString, .hsh, service: Self.icalService)
        }
        // angemeldete Pruefungen (nur lesen) nach den Leistungen
        if includeGrades, let campusClient, !report.cancelled, !report.needsLogin.contains(Source.campus.rawValue) {
            do {
                let rows = try await campusClient.registrations()
                let now = clock.nowISO
                try await database.transaction { try QISRegistrationsSync.store($0, rows, now: now) }
                registrationsMessage = rows.isEmpty ? "Im Campusmanagement sind keine Prüfungen angemeldet."
                    : "\(rows.count) angemeldete \(rows.count == 1 ? "Prüfung" : "Prüfungen") gelesen."
            } catch {
                registrationsMessage = "Angemeldete Prüfungen: \(LocalBackendHost.message(for: error))"
            }
        }
        // Moodle-Nachrichten (nur lesen) nach dem aktuellen Semester
        if let api, !report.cancelled, !report.needsLogin.contains(Source.moodle.rawValue) {
            let r = await MoodleMessagesSync.run(db: database, web: MoodleWeb(base: api.base, transport: transport, retry: retry), clock: clock)
            if !r.message.isEmpty { messagesNote = r.message }
        }
        // Studienservice: Rueckmeldung, Studiengang/PO/Fachsemester (Studienverlauf), offene Zahlungen, Bescheide
        if includeGrades, let campusClient, !report.cancelled, !report.needsLogin.contains(Source.campus.rawValue) {
            if let s = try? await campusClient.studyService() {
                let now = clock.nowISO
                try? await database.transaction { try HISinOneStudyService.store($0, s, now: now) }
            }
        }
        studyService = try? await database.withConnection { try HISinOneStudyService.stored($0) }
        if !report.cancelled { await StudIPSync.autoPlan(host: host, newFiles: report.newFiles.count, weekly: scope == .full) }
        apply(report, sources: sources, includeGrades: includeGrades)
        // abgelaufen: still mit dem gespeicherten Passwort anmelden, dann genau einmal neu (`autoLogin`); im Hintergrund nie
        if !background, !report.cancelled {
            for s in Source.allCases where sources.contains(s) && state(s) == .needsLogin { Task { await self.autoLogin(s) } }
        }
        return report
    }

    // MARK: Automatisch anmelden (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md)

    /// Unsichtbar mit dem gespeicherten SSO-Account anmelden (Moodle-Formular bzw. IdP der HsH); gelingt es, ist die
    /// Quelle wieder verbunden und gleicht genau einmal neu ab (`signedIn`). Falsches Passwort: "Anmeldung nötig" bleibt.
    @discardableResult
    func autoLogin(_ s: Source, userAction: Bool = false) async -> Bool {
        guard isConnected(s), state(s) == .needsLogin, !stopped else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: s.loginService, store: websiteDataStore, entry: UniversityProfile.hsh.loginService(s.loginService)?.entryURLs.first ?? UniversityProfile.hshMoodle,
                                                userAction: userAction) { url, html in HsHConnection.isSignedIn(s, html: html, url: url) }
        guard d == .retryOnce, signOuts == before, isConnected(s), !stopped else { return false }
        for _ in 0..<300 where isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }   // Lauf von eben zu Ende
        guard signOuts == before, isConnected(s), !stopped else { return false }
        signedIn(s)
        return true
    }

    private func apply(_ r: HildesheimSync.Report, sources: Set<Source>, includeGrades: Bool) {
        lastReport = r
        let now = clock.now
        typealias Part = HildesheimSync.Report.Part
        for s in sources where isConnected(s) {
            if r.cancelled { set(s, .connected); continue }
            if r.needsLogin.contains(s.rawValue) { set(s, .needsLogin); continue }
            let done = s == .moodle ? r.completed.contains(Part.learnweb) : r.completed.contains(Part.plan)
            if done {
                set(s, .ok(now))
            } else {
                set(s, .failed(r.messages.first { $0.hasPrefix(s.rawValue) } ?? r.refused ?? "Abgleich nicht abgeschlossen."))
            }
        }
        if includeGrades, r.completed.contains(Part.grades) {
            defaults.set(now, forKey: Keys.gradesRun)
            StudyCatalogSync.trigger(host: host)
        }
        if !r.cancelled {
            messages = r.messages
            defaults.set(r.messages, forKey: Keys.messages)
            lastRun = now
            defaults.set(now, forKey: Keys.lastRun)
        }
    }

    // MARK: Nachrichten und Abgaben (Knopfdruck)

    /// Moodle mit der Sitzung der Webansicht (Antworten, Abgaben); nil ohne Moodle-Verbindung
    func moodleWeb() async -> MoodleWeb? {
        guard isConnected(.moodle) else { return nil }
        return MoodleWeb(base: UniversityProfile.hshMoodle.absoluteString, transport: await makeTransport(websiteDataStore), retry: retry)
    }

    /// Nur die Nachrichten neu lesen (Ziehen auf der Seite "Nachrichten")
    func syncMessages() async {
        guard let web = await moodleWeb(), let database = try? await host.backend().context.database else { return }
        let r = await MoodleMessagesSync.run(db: database, web: web, clock: clock)
        if !r.message.isEmpty { messagesNote = r.message }
        if r.needsLogin { set(.moodle, .needsLogin) }
        finishedRuns += 1
    }

    /// Anmeldung im Lauf abgelaufen (Antworten, Abgaben): Moodle braucht eine neue Anmeldung
    func moodleExpired() { set(.moodle, .needsLogin) }

    // MARK: Anzeige

    /// "Moodle: 16:30 ok", "Campusmanagement: Anmeldung nötig"
    static func statusText(_ s: Source, _ state: State, now: Date = Date()) -> String {
        switch state {
        case .notConnected: return "\(s.rawValue): nicht verbunden"
        case .connected: return "\(s.rawValue): verbunden"
        case .running: return "\(s.rawValue): gleicht ab …"
        case .ok(let d): return "\(s.rawValue): \(HildesheimConnection.time(d, now: now)) ok"
        case .needsLogin: return "\(s.rawValue): Anmeldung nötig"
        case .failed: return "\(s.rawValue): Fehler"
        }
    }

    /// Was die Quelle holt (Karte, erster Start)
    static func describe(_ s: Source) -> String {
        switch s {
        case .moodle: return "Kurse, Materialien, Abgaben und Ankündigungen aus Moodle."
        case .campus: return "Stundenplan, Leistungen und angemeldete Prüfungen aus dem Campusmanagement (HISinOne)."
        }
    }
}

extension HsHConnection: ContainerSync {}

extension HsHConnection: BackgroundSyncable {
    var fileSource: String { "Moodle" }
    var usableSources: [String] { sources(background: true).map(\.rawValue).sorted() }
    var loginNeededSources: [String] { Source.allCases.filter { isConnected($0) && state($0) == .needsLogin }.map(\.rawValue) }

    /// Hintergrund: gemerkte Cookies der Webansicht und die Abo-Adresse des Stundenplans; keine stille Erneuerung
    /// (die HsH hat keine Einmalanmeldung, ein Passwort hat die App nicht): abgelaufen = "Anmeldung nötig"
    func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport {
        guard !stopped else { return .skipped(.noContainer) }
        if await host.demoActive() { return .skipped(.demo) }
        let sources = self.sources(background: true)
        guard !sources.isEmpty else { return .skipped(.noSession) }
        let before = await sourceFileIDs()
        guard !isRunning, let report = await run(scope: kind.scope, background: true) else {
            return isRunning ? .skipped(.alreadyRunning) : BackgroundSyncReport(failure: messages.first ?? "Abgleich nicht möglich.")
        }
        let after = await sourceFileIDs()
        let newFiles = before.flatMap { b in after.map { $0.subtracting(b).count } } ?? 0
        let expired = Source.allCases.filter { sources.contains($0) && state($0) == .needsLogin }.map(\.rawValue)
        var failure: String?
        for s in Source.allCases where sources.contains(s) {
            if case .failed(let m) = state(s) { failure = failure ?? m }
        }
        return BackgroundSyncReport(newFiles: newFiles, loginNeeded: expired, cancelled: report.cancelled, failure: failure)
    }

    /// Kennungen der Hochschul-Dateien (neue Dateien eines Hintergrundlaufs)
    func sourceFileIDs() async -> Set<String>? {
        guard let backend = try? await host.backend() else { return nil }
        return try? await backend.context.database.withConnection { try UniStore.sourceFileIDs($0) }
    }
}

// MARK: Bescheinigungen (CertificateCenter, docs/BESCHEINIGUNGEN-2026-11-06.md): Sitzung des Campusmanagements
extension HsHConnection {
    var certificateClock: UniFlowClock { clock }
    func certificateTransport() async -> UniTransport { await makeTransport(websiteDataStore) }
    var certificateHost: LocalBackendHost { host }
    func certificatesExpired() { if isConnected(.campus) { set(.campus, .needsLogin) } }
}
