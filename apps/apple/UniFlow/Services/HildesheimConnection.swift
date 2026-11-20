import Foundation
import os
import QuartzCore
import UIKit
import UniFlowCore
import WebKit

// Universitaet Hildesheim auf dem iPad: Learnweb (Kurse, Dateien) und LSF (Stundenplan, Notenspiegel), die duenne
// Schicht der App ueber dem Kern der PC-Sitzung (docs/AUFTRAG-HILDESHEIM-IPAD.md, Punkte 2 und 3). Abgleich, Regeln,
// Speichern und Ausfallsicherheit stehen im Kern (`HildesheimSync`, `LearnwebAPI`, `LSFClient`, `MoodleSSO`,
// `HildesheimCAS`); hier nur: Anmeldung im WKWebView mit dem Datenspeicher des Containers, Learnweb-Schluessel im
// Schluesselbund, Transport (`URLSessionUniTransport`), wann abgeglichen wird und der Stand je Quelle.

/// Verbindung und Abgleich der Uni Hildesheim fuer einen Container (Apple-Nutzer, Uni Hildesheim). Der
/// `ContainerManager` baut je offenem Hildesheimer Container eine; sie haelt ihren Container fest (ein Wechsel der
/// Hochschule baut eine neue).
///
/// Learnweb: bevorzugt mit Schluessel aus dem Moodle-SSO (REST, Moodle zaehlt keine Aufrufe; Schluessel im
/// Schluesselbund unter `<nutzer>.hildesheim.learnweb.token`), sonst mit der CAS-/Moodle-Sitzung der Webansicht. Der
/// Schluessel gilt fuer die Learnweb-Instanz, bei der er geholt wurde; im naechsten Jahr (learnweb2027) heisst es neu
/// verbinden. LSF: immer mit der Sitzung der Webansicht.
///
/// Abgeglichen wird beim Oeffnen der App (hoechstens alle 30 Minuten) und auf Knopfdruck, Noten hoechstens alle
/// 20 Stunden wie am PC (auf Knopfdruck "Noten abrufen" sofort). `report.messages` stehen in der Statusleiste, dazu
/// der Stand je Quelle ("Learnweb: 16:30 ok", "LSF: Anmeldung nötig"). Eine Quelle, die waehrend eines Laufs verbunden
/// wird, bewertet erst der direkt folgende eigene Lauf. Vor dem Loeschen des Containers haelt `stop` einen laufenden
/// Abgleich an und wartet auf sein Ende.
///
/// Im Hintergrund (S8, `BackgroundSyncController`, `run(scope:background:)`) nur die Quellen, deren Sitzung nicht als
/// abgelaufen bekannt ist; kurz nur mit den Listen (Kurse, Dateilisten, LSF-Stundenplan; keine Downloads, keine Noten),
/// lang wie beim Oeffnen. Der Learnweb-Schluessel ist nur bei entsperrtem iPad lesbar (WhenUnlocked): ist es gesperrt,
/// bleibt Learnweb in diesem Lauf aussen vor und gilt nicht als abgemeldet. Ein Lauf nur mit Listen setzt nicht
/// `lastRun`, sondern merkt sich wartende Downloads; der naechste Abgleich beim Oeffnen kommt dann sofort.
@MainActor
final class HildesheimConnection: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case learnweb = "Learnweb"
        case lsf = "LSF"
        var id: String { rawValue }
    }

    enum State: Equatable {
        case notConnected
        /// verbunden, noch kein Abgleich in diesem App-Lauf und keiner bekannt
        case connected
        case running
        /// letzter erfolgreicher Abgleich
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var learnweb: State = .notConnected
    @Published private(set) var lsf: State = .notConnected
    @Published private(set) var isRunning = false
    /// Meldungen des letzten Abgleichs (`HildesheimSync.Report.messages`) fuer die Statusleiste
    @Published private(set) var messages: [String] = []
    @Published private(set) var lastRun: Date?
    /// Zahl der beendeten Abgleiche; offene Seiten laden danach neu (`ufReload`)
    @Published private(set) var finishedRuns = 0
    /// Zwischenstaende eines laufenden Abgleichs (15.11.2026, wie `StudIPSync.stagesReady`): Dateilisten gelesen, weitere
    /// Dateien geladen. Seiten mit `ufReload` laden dann schon neu. Vorher luden sie erst am Ende des Laufs: beim ersten
    /// Abgleich blieben die Module bis dahin leer, obwohl die Dateien schon da waren.
    @Published private(set) var stagesReady = 0
    /// letzter Zwischenstand (Schritt, Zeitpunkt): hoechstens alle `stageInterval` Sekunden einer
    private var lastStage: (step: SyncProgress.Step, at: CFTimeInterval)?
    static let stageInterval: CFTimeInterval = 3
    /// Ergebnis des letzten "Dateien laden" fuer Kurse frueherer Semester (`loadOlderFiles`)
    @Published private(set) var olderFilesNote: String?
    /// "Angemeldete Prüfungen abrufen" (Pruefungsanmeldung, "Meine POS-Anmeldungen" im LSF) laeuft
    @Published private(set) var registrationsRunning = false
    /// Bericht des letzten Abgleichs (Tests, Diagnose)
    private(set) var lastReport: HildesheimSync.Report?
    /// Fortschritt der Dateien, solange ein Abgleich laeuft (15.11.2026, `SyncProgress`): "Deine Kurse werden geladen:
    /// 121 von 250 Dateien". nil ohne Lauf - die Anzeige verschwindet dann von selbst
    @Published private(set) var progress: SyncProgress?
    /// Ein voller Abgleich hat begonnen und ist nicht zu Ende gelaufen (App beendet, Hintergrundzeit abgelaufen,
    /// abgebrochen): beim naechsten Oeffnen sofort weiter, ohne die 30 Minuten (`runWhenDue`). Bis dahin zeigt die
    /// Anzeige "wird fortgesetzt" statt nichts - kein Zustand, der wie fertig aussieht.
    var interrupted: Bool { !isRunning && defaults.object(forKey: Keys.runOpen) != nil }
    /// Was die Leiste oberhalb der Seiten zeigt: laufender Fortschritt, sonst ein unterbrochener Lauf
    var shownProgress: UFSyncProgressBar.Content? {
        if let progress { return .running(progress) }
        if isRunning { return .running(SyncProgress()) }
        return interrupted && anyConnected ? .interrupted : nil
    }

    /// Transport je Lauf aus dem Datenspeicher der Webansichten (Tests: feste Antworten)
    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    let layout: DataContainerLayout
    /// Datenspeicher der Anmelde-Webansichten dieses Containers (Cookies von CAS, Learnweb, LSF)
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    /// Learnweb-Schluessel dieses Containers (nie Benutzername oder Passwort)
    let tokens: UniversityTokenStore
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    /// nach einer Anmeldung sofort abgleichen (Tests schalten das ab)
    var syncsAfterSignIn = true
    /// Nach einer Anmeldung bei Learnweb oder LSF (15.11.2026): der `ContainerManager` verbindet die Uni-Mail gleich
    /// mit, ohne auf den Datei-Abgleich zu warten
    var onSignedIn: (@MainActor () -> Void)?
    /// Hintergrundzeit von iOS fuer einen laufenden Abgleich (Tests: Attrappe)
    var backgroundTime: UFBackgroundTime = .system
    /// Daten mit Dateischutz lesbar (iPad entsperrt)? Nur der Hintergrund fragt (Learnweb-Schluessel, Tests: fest)
    var protectedDataAvailable: @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    /// laufender Abgleich (zum Anhalten vor dem Loeschen des Containers, `stop`)
    private var current: Task<HildesheimSync.Report?, Never>?
    /// angehalten (Container wird geloescht): kein weiterer Abgleich
    private(set) var stopped = false
    /// zaehlt jedes Abmelden: ein Lauf, der vorher begann und noch auf die Demo-Pruefung wartete (noch ohne `current`,
    /// das Abmelden haelt ihn also nicht an), beginnt danach nicht mehr (Pruefpunkt 362)
    private var signOuts = 0
    /// Quellen, die waehrend eines laufenden Abgleichs (neu) verbunden wurden: der laufende bewertet sie nicht (sie
    /// bleiben "verbunden"), direkt danach folgt ein eigener Lauf
    private var connectedDuringRun: Set<Source> = []

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
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store) }
        lastRun = defaults.object(forKey: Keys.lastRun) as? Date
        messages = defaults.stringArray(forKey: Keys.messages) ?? []
        learnweb = storedState(.learnweb)
        lsf = storedState(.lsf)
        // Modulkatalog: Ausloeser fuer die Seite Studienverlauf (14.11.2026: fehlte fuer Hildesheim; die Suche lief nie,
        // weder fuer den Studiengang aus dem LSF noch fuer eine eigene Wahl oder einen eingefuegten Link)
        StudyCatalogSync.attach(host: host)
        // unterbrochenes Abmelden (App beendet, Schluesselbund gesperrt): den Rest gleich nachholen
        if defaults.bool(forKey: Keys.signOutPending) { Task { await self.finishPendingSignOut() } }
    }

    // MARK: Einstellungen des Containers (UserDefaults-Suite, gehen mit "Daten dieser Hochschule löschen")

    enum Keys {
        static let learnwebMode = "uniflow.hildesheim.learnweb.mode"
        static let learnwebBase = "uniflow.hildesheim.learnweb.base"
        static let lsfConnected = "uniflow.hildesheim.lsf.connected"
        static let lastRun = "uniflow.hildesheim.lastRun"
        static let messages = "uniflow.hildesheim.messages"
        static let gradesRun = "uniflow.hildesheim.grades.lastRun"
        /// ein Lauf nur mit Listen (Hintergrund, S8) fand Learnweb-Dateien zum Laden; weg nach einem vollen Lauf
        static let downloadsPending = "uniflow.hildesheim.downloadsPending"
        /// Beginn eines vollen Abgleichs, der noch nicht zu Ende gelaufen ist (`interrupted`)
        static let runOpen = "uniflow.hildesheim.runOpen"
        /// Abmelden begonnen, Schluessel oder Webdaten noch nicht nachweislich weg (`finishPendingSignOut`)
        static let signOutPending = "uniflow.hildesheim.signOutPending"
        static func ok(_ s: Source) -> String { "uniflow.hildesheim.\(s.rawValue.lowercased()).ok" }
        static func login(_ s: Source) -> String { "uniflow.hildesheim.\(s.rawValue.lowercased()).login" }
    }

    /// Schluessel-Dienst im Profil (`tokenServices`)
    static let tokenService = "learnweb"

    enum LearnwebMode: String { case token, session }

    var learnwebMode: LearnwebMode? { defaults.string(forKey: Keys.learnwebMode).flatMap(LearnwebMode.init(rawValue:)) }
    var lsfConnected: Bool { defaults.bool(forKey: Keys.lsfConnected) }

    func isConnected(_ s: Source) -> Bool { s == .learnweb ? learnwebMode != nil : lsfConnected }
    var anyConnected: Bool { Source.allCases.contains(where: isConnected) }

    func state(_ s: Source) -> State { s == .learnweb ? learnweb : lsf }

    /// Karte "… verbinden" bzw. "Erneut anmelden" zeigen
    func needsAttention(_ s: Source) -> Bool {
        let st = state(s)
        return st == .notConnected || st == .needsLogin
    }

    private func storedState(_ s: Source) -> State {
        guard isConnected(s) else { return .notConnected }
        if defaults.bool(forKey: Keys.login(s)) { return .needsLogin }
        return (defaults.object(forKey: Keys.ok(s)) as? Date).map(State.ok) ?? .connected
    }

    private func set(_ s: Source, _ state: State) {
        if s == .learnweb { learnweb = state } else { lsf = state }
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

    // MARK: Anmeldung (aus HildesheimLogin)

    /// Learnweb verbunden: mit Schluessel (Moodle-SSO) oder mit der Sitzung der Webansicht. false, wenn sich der
    /// Schluessel nicht ablegen liess (dann bleibt alles wie vorher).
    @discardableResult
    func learnwebSignedIn(token: LearnwebToken?, base: String) -> Bool {
        if let token {
            guard tokens.saveToken(token.keychainValue, .hildesheim, service: Self.tokenService) else { return false }
            defaults.set(LearnwebMode.token.rawValue, forKey: Keys.learnwebMode)
        } else {
            tokens.deleteToken(.hildesheim, service: Self.tokenService)
            defaults.set(LearnwebMode.session.rawValue, forKey: Keys.learnwebMode)
        }
        defaults.set(base, forKey: Keys.learnwebBase)
        // neue Anmeldung: ein noch offenes Abmelden ist ueberholt (es loeschte sonst beim naechsten Start die neue)
        defaults.removeObject(forKey: Keys.signOutPending)
        set(.learnweb, .connected)
        afterSignIn(.learnweb)
        return true
    }

    // MARK: Nachrichten und Abgaben (Knopfdruck, 05.11.2026)

    /// Learnweb mit der Sitzung der Webansicht (Antworten, Abgaben in Learnweb-Aufgaben; `MoodleWeb` wie die Hochschule
    /// Hannover). Instanz: die beim Verbinden bzw. im letzten Abgleich gemerkte. nil ohne Learnweb-Verbindung.
    func moodleWeb() async -> MoodleWeb? {
        guard isConnected(.learnweb) else { return nil }
        let base = defaults.string(forKey: Keys.learnwebBase) ?? UniversityProfile.hildesheimLearnweb.absoluteString
        return MoodleWeb(base: base, transport: await makeTransport(websiteDataStore), retry: retry)
    }

    /// Anmeldung beim Antworten oder Abgeben abgelaufen: Learnweb braucht eine neue (stille) Anmeldung
    func learnwebExpired() {
        guard isConnected(.learnweb) else { return }
        set(.learnweb, .needsLogin)
    }

    /// LSF verbunden (die Webansicht zeigt eine angemeldete Seite des LSF, `LSFClient.isLoggedIn`)
    func lsfSignedIn() {
        defaults.removeObject(forKey: Keys.signOutPending)
        defaults.set(true, forKey: Keys.lsfConnected)
        set(.lsf, .connected)
        afterSignIn(.lsf)
    }

    /// Nach einer Anmeldung abgleichen. Laeuft schon einer (der uebliche Weg: Learnweb verbunden, Abgleich laeuft, dann
    /// LSF verbinden), gilt die Quelle fuer ihn nicht; sie bekommt direkt danach einen eigenen Lauf.
    /// Letzte Anmeldung (`LoginReminder`)
    var lastSignIn: Date? { defaults.object(forKey: LoginReminder.lastLoginKey) as? Date }

    private func afterSignIn(_ s: Source) {
        defaults.set(Date(), forKey: LoginReminder.lastLoginKey)
        BackgroundReloginLedger.foregroundSuccess(s.rawValue, defaults: defaults)   // Hintergrund darf wieder (20.11.)
        renewal.verified(at: clock.now)                         // neue Anmeldung: Ruecknahme der stillen Versuche zurueck
        let store = websiteDataStore
        UniAutoLogin.signedIn(store)                           // mitgelesenes Passwort jetzt merken (falls zugelassen)
        Task { await UniWebSessions.save(store) }              // CAS-Anmeldung ueber Neustarts merken
        // eine Anmeldung fuer beide Dienste: dieselbe CAS-Sitzung verbindet den anderen gleich mit (ohne Eingabe);
        // waehrend `connectWithStoredLogin` verbindet dieses die Quellen nacheinander selbst (nie zwei Webansichten)
        if !connectingStored, let other = Source.allCases.first(where: { $0 != s && !isConnected($0) }), silentLoginAllowed {
            Task {
                _ = await silentLogin(other)
                onSignedIn?()                                  // danach (nie zwei unsichtbare Anmeldungen zugleich)
            }
        } else if !connectingStored {
            onSignedIn?()
        }
        if isRunning {
            connectedDuringRun.insert(s)
            return
        }
        guard syncsAfterSignIn else { return }
        Task { await run() }
    }

    /// Abmelden: Schluessel, Verbindungen und Anmeldungen der Webansicht (CAS, Learnweb, LSF) der Uni Hildesheim
    /// dieses Kontos; heruntergeladene Dateien, Stundenplan und Noten bleiben. Ein gemerktes Passwort (`UniAutoLogin`)
    /// geht mit; eines, das iOS im Schluesselbund hat, bleibt.
    ///
    /// Ein laufender Abgleich wird zuerst angehalten und abgewartet (vorher lief er mit Schluessel und Cookies von
    /// vorher weiter, lud Dateien und schrieb danach seinen Stand). Teilfehler: Der Merker `Keys.signOutPending` steht,
    /// bis Schluessel und Webdaten nachweislich weg sind; bis dahin ist nichts verbunden, und vor der naechsten
    /// Anmeldung sowie beim naechsten Oeffnen wird nachgeholt, was fehlte (`finishPendingSignOut`) - eine alte
    /// Sitzung wird nie wiederverwendet.
    /// - Returns: nil, wenn alles entfernt ist; sonst die Meldung fuer die Oberflaeche
    @discardableResult
    func signOut() async -> String? {
        signOuts += 1
        defaults.set(true, forKey: Keys.signOutPending)
        connectedDuringRun = []
        if let task = current {
            task.cancel()
            _ = await task.value
        }
        for k in [Keys.learnwebMode, Keys.learnwebBase, Keys.lsfConnected, Keys.downloadsPending, Keys.runOpen, LoginReminder.lastLoginKey] { defaults.removeObject(forKey: k) }
        UniLoginHelper.forget(defaults: defaults)                // gemerkter Benutzername der CAS-Anmeldeseite
        UniAutoLogin.forget(websiteDataStore)                    // gemerktes Passwort der Uni Hildesheim (Schluesselbund)
        renewal = UniRenewalState()
        for s in Source.allCases {
            defaults.removeObject(forKey: Keys.ok(s))
            set(s, .notConnected)
        }
        messages = []
        defaults.removeObject(forKey: Keys.messages)
        return await finishPendingSignOut()
    }

    /// Rest eines Abmeldens: Learnweb-Schluessel und Webdaten entfernen und pruefen, dass sie weg sind. Erst dann geht
    /// der Merker. Rueckgabe: nil, wenn nichts (mehr) aussteht.
    @discardableResult
    func finishPendingSignOut() async -> String? {
        guard defaults.bool(forKey: Keys.signOutPending) else { return nil }
        tokens.deleteAll(for: .hildesheim)
        await UniWebSessions.forget(websiteDataStore)            // gemerkte CAS-Anmeldung zuerst (nie wiederverwenden)
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let keyLeft = tokens.token(.hildesheim, service: Self.tokenService) != nil
        let cookiesLeft = !(await websiteDataStore.httpCookieStore.allCookies()).isEmpty
        guard !keyLeft, !cookiesLeft else {
            return "Abmelden noch nicht vollständig (\(keyLeft ? "Learnweb-Schlüssel" : "Anmeldung der Webansicht")) – "
                + "StudiNow versucht es beim nächsten Öffnen erneut und meldet vorher niemanden an."
        }
        defaults.removeObject(forKey: Keys.signOutPending)
        return nil
    }

    /// Transport fuer Anfragen ausserhalb eines Abgleichs (Anmeldung: Learnweb-Instanz, Moodle-Konfiguration)
    func transport() async -> UniTransport { await makeTransport(websiteDataStore) }

    /// Jahr und Monat heute in Berlin (Learnweb-Instanz des Semesters, `Learnweb.discoverBase`)
    var yearMonth: (year: Int, month: Int) {
        // clock.today ist immer "YYYY-MM-DD"
        let d = clock.today.split(separator: "-").compactMap { Int($0) }
        return (d.first ?? 0, d.count > 1 ? d[1] : 0)
    }

    // MARK: Abgleich

    /// Ein Lauf nur mit Listen hat Learnweb-Dateien gefunden, die noch nicht geladen sind
    var downloadsPending: Bool { defaults.bool(forKey: Keys.downloadsPending) }

    /// Beim Oeffnen der App: hoechstens alle 30 Minuten (warten Dateien aus einem Lauf nur mit Listen: sofort), nur mit
    /// einer verbundenen Quelle
    func runIfDue() {
        // dieselbe Regel wie beim Stud.IP-Abgleich: nie automatisch unter XCTest, -UFNoStudIPSync oder Startargumenten
        guard StudIPSync.automaticRunAllowed(), anyConnected, !isRunning else { return }
        // abgelaufen: zuerst still ueber die CAS-Sitzung erneuern (die Anmeldung startet dann selbst den Abgleich)
        let expired = expiredSources
        if !expired.isEmpty, silentLoginAllowed {
            Task {
                let left = await renewSilently()
                if left.count == expired.count, !isRunning { runWhenDue() }
            }
            return
        }
        runWhenDue()
    }

    private func runWhenDue() {
        // ein unterbrochener Lauf setzt sofort fort (15.11.2026)
        if let last = lastRun, !downloadsPending, !interrupted, clock.now.timeIntervalSince(last) < 30 * 60 { return }
        Task { await run() }
    }

    // MARK: Stille Erneuerung

    /// Verbundene Quellen mit abgelaufener Anmeldung
    var expiredSources: [Source] { Source.allCases.filter { isConnected($0) && state($0) == .needsLogin } }

    /// Unsichtbare Anmeldung moeglich: nie unter XCTest, nie mit der Debug-Nachbildung, nicht angehalten
    private var silentLoginAllowed: Bool { !StudIPSync.isUnderTest() && !DebugUniStub.isActive && !stopped }

    /// Stand der stillen Erneuerung (`UniRenewalPolicy`, wie Stud.IP: nach gescheiterten Versuchen 10, 20, 40 … Minuten
    /// Pause, hoechstens 4 Stunden; eine neue Anmeldung setzt das zurueck)
    private(set) var renewal = UniRenewalState()

    /// Abgelaufene Learnweb-/LSF-Anmeldung ohne Passwort erneuern: Die CAS-Anmeldung liegt im Datenspeicher des
    /// Containers (ueber Neustarts: `UniWebSessions`) und gilt meist laenger als die Sitzung von LSF bzw. Learnweb.
    /// Eine unsichtbare Webansicht oeffnet die Anmeldeseite des Dienstes (`HildesheimSilentLogin`); gilt die
    /// CAS-Anmeldung, kommt sie ohne Eingabe an, und die Quelle ist wieder verbunden (der Abgleich startet). Sonst
    /// bleibt es bei "Anmeldung nötig" (dort setzt iOS das gespeicherte Passwort ein). Nur mit offener App.
    /// Rueckgabe: Quellen, die weiter eine Anmeldung brauchen.
    @discardableResult
    func renewSilently(trigger: UniRenewalTrigger = .foreground) async -> [Source] {
        if let renewing { return await renewing.value }
        let expired = expiredSources
        guard !expired.isEmpty, silentLoginAllowed else { return expired }
        guard UniRenewalPolicy.decide(trigger, appActive: UIApplication.shared.applicationState == .active, connected: true,
                                      knownExpired: true, state: renewal, now: clock.now) == .renew else { return expired }
        let task = Task { @MainActor () -> [Source] in
            var left: [Source] = []
            for s in expired where !(await self.silentLogin(s)) { left.append(s) }
            return left
        }
        renewing = task
        let left = await task.value
        renewing = nil
        renewal.attempted(at: clock.now, ok: left.isEmpty)
        return left
    }

    /// Laufender stiller Versuch (ein zweiter Aufruf wartet auf ihn)
    private var renewing: Task<[Source], Never>?

    /// `connectWithStoredLogin` laeuft (die Quellen verbindet es nacheinander selbst)
    private var connectingStored = false

    /// Uni-Zugang einmal speichern (Auftrag 10.11.2026, fuer Hildesheim 12.11.2026): Learnweb und LSF mit dem
    /// gespeicherten Zugang verbinden - auch zum ersten Mal, nicht nur nach einer abgelaufenen Anmeldung. Abgelaufene
    /// erst still erneuern (`renewSilently`, beim Knopf als Handlung des Menschen ohne Ruecknahme), dann jede noch nie
    /// verbundene Quelle ueber die unsichtbare Webansicht (CAS: gespeichertes Passwort genau einmal, `autoLoginCAS`).
    /// Nur im Vordergrund, nie unter XCTest/Nachbildung. Lehnt das CAS das Passwort ab, ist es vergessen
    /// (`UniAutoLogin.handleExpiry`), die zweite Quelle sendet es dann nicht noch einmal.
    /// Rueckgabe: verbundene Quellen und solche, die eine Anmeldung von Hand brauchen.
    func connectWithStoredLogin(userAction: Bool) async -> (connected: [Source], needsLogin: [Source]) {
        let expiredLeft = await renewSilently(trigger: userAction ? .userAction : .foreground)
        var needs = Set(expiredLeft)
        if silentLoginAllowed, !connectingStored, !defaults.bool(forKey: Keys.signOutPending) {
            connectingStored = true
            for s in Source.allCases where !isConnected(s) {
                if !(await silentLogin(s)) { needs.insert(s) }
            }
            connectingStored = false
        } else {
            needs.formUnion(Source.allCases.filter { !isConnected($0) })
        }
        let connected = Source.allCases.filter { isConnected($0) && state($0) != .needsLogin && !needs.contains($0) }
        return (connected, Source.allCases.filter { needs.contains($0) })
    }

    /// Eine Quelle unsichtbar anmelden (nur mit offener App und gueltiger CAS-Anmeldung)
    private func silentLogin(_ s: Source) async -> Bool {
        guard silentLoginAllowed, UIApplication.shared.applicationState == .active else { return false }
        if await HildesheimSilentLogin.attempt(s, connection: self) { return true }
        // das CAS will das Passwort: mit dem gespeicherten still anmelden (`UniAutoLogin`), dann genau einmal neu
        guard await autoLoginCAS() else { return false }
        return await HildesheimSilentLogin.attempt(s, connection: self)
    }

    /// Automatisch anmelden am CAS (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): Einstieg des LSF, fertig, sobald das CAS
    /// zum LSF weiterleitet (die CAS-Sitzung gilt danach auch fuer Learnweb und PLuS). `background`: Hintergrundlauf
    /// (Webansicht ohne Fenster, alle Regeln von `UniAutoLogin.handleExpiry` bleiben)
    private func autoLoginCAS(background: Bool = false) async -> Bool {
        guard let entry = URL(string: HildesheimCAS.lsfLoginURL), let lsfHost = UniversityProfile.hildesheimLSF.host?.lowercased() else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "cas", store: websiteDataStore, entry: entry, background: background) { url, _ in
            url.host?.lowercased() == lsfHost && !HildesheimCAS.isCASPage(url.absoluteString)
        }
        return d == .retryOnce && signOuts == before && !stopped
    }

    // MARK: Stille Neuanmeldung im Hintergrund (Auftrag des Inhabers 17.11.2026, wie Stud.IP, QIS und Uni-Mail)

    /// Tests: ersetzt die unsichtbare Webansicht der Dienst-Anmeldung im Hintergrund (sonst `HildesheimSilentLogin`)
    static var backgroundServiceLogin: (@MainActor (Source, HildesheimConnection) async -> Bool)?

    /// Hintergrundlauf (`BackgroundSyncController.reloginStep`): abgelaufene Learnweb- bzw. LSF-Anmeldung still erneuern,
    /// ohne Fenster. Zuerst ohne Passwort ueber die noch gueltige CAS-Anmeldung; will das CAS das Passwort, genau ein
    /// Versuch mit dem gespeicherten Uni-Zugang (`UniAutoLogin.handleExpiry`: nur mit Zustimmung, abgelehnt = vergessen
    /// und nie erneut gesendet, Ruecknahme nach Fehlschlaegen), dann die Dienst-Anmeldung noch einmal. Nie nach bewusstem
    /// Abmelden (`signOutPending`, ein Abmelden waehrend des Versuchs bricht ab), nie angehalten. Gleicht nicht selbst ab:
    /// das macht der Hintergrundlauf danach in seinem Zeitlimit. Rueckgabe: wieder angemeldet.
    @discardableResult
    func reloginInBackground(_ s: Source) async -> Bool {
        guard !stopped, isConnected(s), state(s) == .needsLogin, !defaults.bool(forKey: Keys.signOutPending),
              UniAutoLogin.liveAllowed || Self.backgroundServiceLogin != nil else { return false }
        let before = signOuts
        let syncs = syncsAfterSignIn
        syncsAfterSignIn = false
        defer { syncsAfterSignIn = syncs }
        switch await serviceLoginInBackground(s) {
        case .signedIn: return signOuts == before && !stopped && state(s) != .needsLogin
        case .failed: return false                               // nichts gesendet; nach einem Fehler kein Passwort
        case .needsPassword: break
        }
        guard !Task.isCancelled, signOuts == before, !stopped, await autoLoginCAS(background: true), signOuts == before,
              !stopped, !Task.isCancelled else { return false }
        guard await serviceLoginInBackground(s) == .signedIn else { return false }
        return signOuts == before && !stopped && state(s) != .needsLogin
    }

    /// Ergebnis der Dienst-Anmeldung ohne Passwort
    enum BackgroundServiceLogin: Equatable { case signedIn, needsPassword, failed }

    /// Dienst-Anmeldung ohne Passwort ueber die CAS-Anmeldung. LSF seit 20.11.2026 zuerst ohne Webansicht
    /// (`UniDirectLogin.silent`: CAS-Einstieg des LSF per URLSession, gilt das TGC noch, kommt das Ticket von selbst);
    /// Learnweb (Moodle-SSO mit App-Schema) und unbekannte Seiten wie bisher in der unsichtbaren Webansicht.
    private func serviceLoginInBackground(_ s: Source) async -> BackgroundServiceLogin {
        if let o = Self.backgroundServiceLogin { return await o(s, self) ? .signedIn : .needsPassword }
        if s == .lsf, UniDirectLogin.available, let entry = URL(string: HildesheimCAS.lsfLoginURL) {
            switch await UniDirectLogin.silent(store: websiteDataStore, university: .hildesheim, entry: entry, isDone: { url, html in
                LSFClient.isLoggedIn(html: html, url: url)
            }) {
            case .done:
                lsfSignedIn()
                return .signedIn
            case .needsPassword: return .needsPassword
            case .unsupported: break                             // Seite unbekannt, nichts gesendet: Webansicht
            case .failed, .blocked, .cancelled, .rejected: return .failed
            }
        }
        guard silentLoginAllowed, !Task.isCancelled else { return .failed }
        return await HildesheimSilentLogin.attempt(s, connection: self, background: true) ? .signedIn : .needsPassword
    }

    /// Quellen, die ein Lauf bewertet: alle verbundenen; im Hintergrund nur die ohne bekannte abgelaufene Anmeldung
    /// (nie eine Anmeldeseite, keine Anfrage mit einer toten Sitzung)
    func sources(background: Bool) -> Set<Source> {
        Set(Source.allCases.filter { isConnected($0) && (!background || state($0) != .needsLogin) })
    }

    /// Demo-Inhalte im Container an? Dann gleicht die Verbindung nicht ab (`LocalBackendHost.demoActive`)
    func demoActive() async -> Bool { await host.demoActive() }

    /// Kennungen der Hochschul-Dateien in der Datenbank des Containers (Hintergrund: neue Dateien eines Laufs); nil,
    /// wenn die Datenbank nicht lesbar ist
    func sourceFileIDs() async -> Set<String>? {
        guard let backend = try? await host.backend() else { return nil }
        return try? await backend.context.database.withConnection { try UniStore.sourceFileIDs($0) }
    }

    /// Noten hoechstens alle 20 Stunden (wie am PC)
    private var gradesDue: Bool {
        guard let last = defaults.object(forKey: Keys.gradesRun) as? Date else { return true }
        return clock.now.timeIntervalSince(last) >= 20 * 3600
    }

    /// Ein Abgleich: Learnweb, danach LSF-Stundenplan und Noten (`HildesheimSync.run`). `forceGrades`: Noten auch vor
    /// Ablauf der 20 Stunden. Wurde waehrend des Laufs eine Quelle verbunden, folgt direkt danach ein weiterer Lauf.
    /// `scope: .lists` (kurzer Hintergrundlauf): ohne Downloads und ohne Noten; `background`: nur `sources(background:)`.
    /// `olderOnly` (`loadOlderFiles`): nur die Learnweb-Dateien gewuenschter Kurse frueherer Semester.
    @discardableResult
    func run(forceGrades: Bool = false, scope: UniSyncScope = .full, background: Bool = false,
             olderOnly: Bool = false) async -> HildesheimSync.Report? {
        guard !isRunning, !stopped, !sources(background: background).isEmpty else { return nil }
        let signOutsBefore = signOuts
        // Demo-Inhalte aktiv: nie zur Hochschule, keine Anfrage (DemoContent); erst nach "Entfernen" wieder
        if await demoActive() { return nil }
        // waehrend der Pruefung angehalten, schon ein Lauf, abgemeldet oder nichts mehr verbunden
        guard !isRunning, !stopped, signOuts == signOutsBefore, !sources(background: background).isEmpty else { return nil }
        // gleicht ein anderes Objekt desselben Containers noch ab (Wechsel A → B → A), keinen zweiten Lauf (P2-2)
        guard ContainerRuns.claim(layout.learnweb, by: self) else { return nil }
        isRunning = true
        // voller Lauf der aktuellen Kurse: als offen merken, bis er zu Ende gelaufen ist (`interrupted`)
        let tracksOpen = scope == .full && !olderOnly
        if tracksOpen { defaults.set(clock.now, forKey: Keys.runOpen) }
        let task = Task {
            olderOnly ? await self.performOlder() : await self.perform(forceGrades: forceGrades, scope: scope, background: background)
        }
        current = task
        // Wechselt die App in den Hintergrund oder wird das Geraet gesperrt, laeuft der Abgleich mit der Hintergrundzeit
        // von iOS weiter; ist sie um, endet er sauber als abgebrochen (keine halbe Datei) und setzt beim Zurueckkommen fort
        let extra = background ? nil : backgroundTime.begin("StudiNow lädt deine Kurse") { task.cancel() }
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        extra?.end()
        current = nil
        ContainerRuns.release(layout.learnweb, by: self)
        isRunning = false
        progress = nil
        lastStage = nil
        // zu Ende gelaufen (auch mit einzelnen Fehlern): nicht mehr offen; abgebrochen oder gar nicht begonnen: bleibt
        if tracksOpen, let report, !report.cancelled, report.refused == nil { defaults.removeObject(forKey: Keys.runOpen) }
        finishedRuns += 1
        if !connectedDuringRun.isEmpty {
            connectedDuringRun = []
            if syncsAfterSignIn, !stopped { Task { await run() } }
        } else if !background, !expiredSources.isEmpty, silentLoginAllowed {
            // Sitzung im Lauf abgelaufen: still ueber die CAS-Anmeldung erneuern (Ruecknahme: `UniRenewalPolicy`)
            Task { await self.renewSilently(trigger: .requestFailed) }
        }
        return report
    }

    /// Anhalten, bevor der Container geloescht wird: laufenden Abgleich abbrechen (`Task.cancel`, der Kern endet als
    /// "abgebrochen") und auf sein Ende warten, danach schreibt er nichts mehr; diese Verbindung gleicht nicht mehr ab
    func stop() async {
        stopped = true
        connectedDuringRun = []
        guard let task = current else { return }
        task.cancel()
        _ = await task.value
    }

    /// Fortschritt aus dem Kern (kommt aus beliebigen Aufgaben) auf den Hauptfaden; nach dem Ende des Laufs verworfen
    private var progressSink: @Sendable (SyncProgress) -> Void {
        { [weak self] p in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                // spaeter gemeldete, aber aeltere Staende ueberholen nichts (die Meldungen kommen aus mehreren Aufgaben)
                if let old = self.progress, old.step == p.step, old.filesDone > p.filesDone || old.coursesDone > p.coursesDone { return }
                self.progress = p
                self.noteStage(p)
            }
        }
    }

    /// Seiten neu laden lassen, wenn der Abgleich einen Schritt weiter ist (Listen fertig) oder seit dem letzten Mal
    /// `stageInterval` Sekunden geladen hat
    private func noteStage(_ p: SyncProgress) {
        let now = CACurrentMediaTime()
        guard let last = lastStage else {
            lastStage = (p.step, now)
            return
        }
        guard last.step != p.step || now - last.at >= Self.stageInterval else { return }
        lastStage = (p.step, now)
        stagesReady += 1
    }

    /// Datei auf Antippen einzeln laden (15.11.2026, `FileLoadPanel`): gelistet, aber noch nicht auf dem Geraet, z. B.
    /// waehrend der erste Abgleich noch laeuft. Mit der Learnweb-Verbindung dieses Containers, neben einem laufenden
    /// Abgleich (eigener Zwischenordner). nil: keine Learnweb-Verbindung.
    func loadFile(id: String) async -> HildesheimSync.SingleLoad? {
        guard isConnected(.learnweb), !stopped else { return nil }
        if await demoActive() { return .failed("Im Beispielmodus lädt StudiNow keine Dateien.") }
        let transport = await makeTransport(websiteDataStore)
        let lw = await learnwebAccess(transport: transport, background: false)
        guard let api = lw.api, let database = try? await host.backend().context.database else {
            return lw.loginNeeded ? .needsLogin : .failed(lw.message ?? "Learnweb ist gerade nicht erreichbar.")
        }
        let r = await HildesheimSync(db: database, container: layout, learnweb: api, lsf: nil, transport: transport,
                                     clock: clock, retry: retry, tools: AppDocumentTools()).loadFile(id: id)
        if r == .needsLogin { set(.learnweb, .needsLogin) }
        return r
    }

    /// "Dateien laden" fuer Kurse frueherer Semester (Bibliothek, Frage nach dem ersten Abgleich): nur Learnweb, nur
    /// deren Dateilisten und Downloads (`OlderSemesters.pending`); kein LSF, keine Fristen. Laeuft gerade ein Abgleich,
    /// holt der naechste die vorgemerkten Kurse. Rueckgabe: Meldung fuer die Anzeige.
    @discardableResult
    func loadOlderFiles() async -> String? {
        guard !isRunning else { return StudIPSync.olderQueuedNote }
        guard isConnected(.learnweb) else { return nil }
        olderFilesNote = nil
        await run(olderOnly: true)
        return olderFilesNote
    }

    /// Knopf "Angemeldete Prüfungen abrufen" (Pruefungsanmeldung, docs/PRUEFUNGSANMELDUNG-2026-11-05.md): liest nur
    /// "Meine POS-Anmeldungen" im LSF mit der Sitzung der Webansicht (`QISRegistrationsSync`, `layout: .hildesheim`).
    /// Meldet nie an oder ab. nil ohne LSF-Verbindung, waehrend eines Abgleichs oder mit Demo-Inhalten. Der normale
    /// Abgleich liest die Seite nach dem Notenspiegel ohnehin mit (`HildesheimSync`).
    @discardableResult
    func fetchRegistrations() async -> QISRegistrationsSync.Report? {
        guard isConnected(.lsf), !stopped, !isRunning, !registrationsRunning else { return nil }
        if await demoActive() { return nil }
        guard isConnected(.lsf), !stopped, !isRunning, !registrationsRunning else { return nil }
        registrationsRunning = true
        defer { registrationsRunning = false }
        let transport = await makeTransport(websiteDataStore)
        let r: QISRegistrationsSync.Report
        do {
            let db = try await host.backend().context.database
            r = await QISRegistrationsSync.run(db: db, transport: transport, clock: clock, retry: retry, layout: .hildesheim)
        } catch {
            r = QISRegistrationsSync.Report(message: LocalBackendHost.message(for: error))
        }
        if r.needsLogin { set(.lsf, .needsLogin) }
        finishedRuns += 1                                       // offene Seiten laden neu (Haken)
        return r
    }

    /// Lauf von `loadOlderFiles`: Stand und Meldungen des letzten vollen Abgleichs bleiben
    private func performOlder() async -> HildesheimSync.Report? {
        let transport = await makeTransport(websiteDataStore)
        let lw = await learnwebAccess(transport: transport, background: false)
        guard let api = lw.api, let database = try? await host.backend().context.database else {
            olderFilesNote = lw.message ?? "Learnweb ist gerade nicht erreichbar."
            return nil
        }
        let r = await HildesheimSync(db: database, container: layout, learnweb: api, lsf: nil, transport: transport,
                                     clock: clock, retry: retry, tools: AppDocumentTools(), onProgress: progressSink)
            .run(includeGrades: false, downloads: true, olderOnly: true)
        olderFilesNote = r.cancelled ? nil : r.needsLogin.isEmpty
            ? "\(r.newFiles.count) \(r.newFiles.count == 1 ? "Datei" : "Dateien") aus früheren Semestern geladen"
                + (r.failedFiles.isEmpty ? "" : ", \(r.failedFiles.count) später erneut")
            : "Learnweb: Anmeldung nötig"
        return r
    }

    private func perform(forceGrades: Bool, scope: UniSyncScope, background: Bool) async -> HildesheimSync.Report? {
        // nur die Quellen, die zu Beginn verbunden sind, bewertet dieser Lauf (vor dem ersten await festgehalten)
        let sources = self.sources(background: background)
        let before = (learnweb, lsf)
        for s in sources { set(s, .running) }
        let transport = await makeTransport(websiteDataStore)
        var lw = LearnwebAccess()
        if sources.contains(.learnweb) { lw = await learnwebAccess(transport: transport, background: background) }
        let lsfClient = sources.contains(.lsf) ? LSFClient(transport: transport, retry: retry) : nil
        // Noten nicht im kurzen Hintergrundlauf (nur Listen), sonst hoechstens alle 20 Stunden
        let includeGrades = scope == .full && (forceGrades || gradesDue)
        let database: SQLiteDatabase
        do {
            database = try await host.backend().context.database
        } catch {
            let message = LocalBackendHost.message(for: error)
            for s in sources.subtracting(connectedDuringRun) where isConnected(s) { set(s, .failed(message)) }
            finish(messages: [message], report: nil, succeeded: false, scope: scope)
            return nil
        }
        var report = HildesheimSync.Report()
        if lw.api != nil || lsfClient != nil {
            // Seitentexte mit PDFKit (Suche, Seitenzuordnung einer neuen Fassung, S7)
            report = await HildesheimSync(db: database, container: layout, learnweb: lw.api, lsf: lsfClient, transport: transport,
                                          clock: clock, retry: retry, tools: AppDocumentTools(), onProgress: progressSink)
                .run(includeGrades: includeGrades, downloads: scope == .full)
            if !report.cancelled { await StudIPSync.autoPlan(host: host, newFiles: report.newFiles.count, weekly: scope == .full) }   // Lernplan und Wochentests wie nach run_sync
        }
        apply(report, sources: sources.subtracting(connectedDuringRun), learnweb: lw, includeGrades: includeGrades, before: before, scope: scope)
        return report
    }

    /// Learnweb fuer einen Lauf: Zugang, oder warum es keinen gibt (Meldung; Anmeldung noetig, ohne die Uni zu fragen)
    private struct LearnwebAccess {
        var api: LearnwebAPI?
        var loginNeeded = false
        var message: String?
        /// in diesem Lauf aussen vor (Hintergrund bei gesperrtem iPad): Stand bleibt, keine neue Anmeldung noetig
        var skipped = false
    }

    /// Learnweb-Zugang fuer diesen Lauf: Instanz des Semesters (`Learnweb.discoverBase`; nicht erreichbar: die beim
    /// Verbinden gemerkte), Schluessel nur fuer die Instanz, bei der er geholt wurde. Im Hintergrund bei gesperrtem
    /// iPad (Schluessel nicht lesbar) ohne Learnweb und ohne Anfrage.
    private func learnwebAccess(transport: UniTransport, background: Bool) async -> LearnwebAccess {
        if background, learnwebMode == .token, !protectedDataAvailable() {
            return LearnwebAccess(message: "Learnweb: iPad gesperrt, Abgleich beim nächsten Öffnen", skipped: true)
        }
        guard let mode = learnwebMode else { return LearnwebAccess() }
        let stored = defaults.string(forKey: Keys.learnwebBase)
        let found = await Learnweb.discoverBase(year: yearMonth.year, month: yearMonth.month, transport: transport)
        guard let base = found ?? stored else {
            return LearnwebAccess(message: "Learnweb: \(HildesheimError.noLearnwebInstance.description)")
        }
        switch mode {
        case .session:
            return LearnwebAccess(api: LearnwebAPI(base: base, mode: .session, transport: transport, retry: retry))
        case .token:
            guard let raw = tokens.token(.hildesheim, service: Self.tokenService), let token = LearnwebToken(raw) else {
                return LearnwebAccess(loginNeeded: true, message: UFDevice.adapt("Learnweb: Der Learnweb-Schlüssel fehlt auf diesem iPad. Bitte neu verbinden."))
            }
            guard stored == nil || stored == base else {
                return LearnwebAccess(loginNeeded: true, message: "Learnweb: Das Learnweb des neuen Semesters braucht eine neue Anmeldung.")
            }
            return LearnwebAccess(api: LearnwebAPI(base: base, mode: .token(token), transport: transport, retry: retry))
        }
    }

    /// Stand je Quelle aus dem Bericht: Anmeldung noetig (`needsLogin`), zu Ende gelaufen (`completed`), Abbruch (alter
    /// Stand bleibt), sonst Fehler mit der Meldung des Kerns. Bewertet werden nur `sources` (zu Beginn des Laufs
    /// verbunden und nicht waehrend des Laufs neu angemeldet) und nur, solange sie noch verbunden sind.
    private func apply(_ r: HildesheimSync.Report, sources: Set<Source>, learnweb lw: LearnwebAccess, includeGrades: Bool,
                       before: (State, State), scope: UniSyncScope) {
        let now = clock.now
        let all = (lw.message.map { [$0] } ?? []) + r.messages
        func message(_ prefixes: [String]) -> String {
            all.first { m in prefixes.contains { m.hasPrefix($0) } } ?? r.refused ?? "Abgleich nicht abgeschlossen."
        }
        typealias Part = HildesheimSync.Report.Part
        var succeeded = !r.cancelled
        if sources.contains(.learnweb), isConnected(.learnweb) {
            if lw.skipped {
                set(.learnweb, before.0)
                succeeded = false
            } else if lw.loginNeeded || r.needsLogin.contains(Source.learnweb.rawValue) {
                set(.learnweb, .needsLogin)
                succeeded = false
            } else if lw.api != nil, r.completed.contains(Part.learnweb) {
                set(.learnweb, .ok(now))
            } else if r.cancelled {
                set(.learnweb, before.0)
            } else {
                set(.learnweb, .failed(message(["Learnweb"])))
                succeeded = false
            }
        }
        if sources.contains(.lsf), isConnected(.lsf) {
            let planOK = r.completed.contains(Part.plan)
            let gradesOK = !includeGrades || r.completed.contains(Part.grades)
            if r.needsLogin.contains(Source.lsf.rawValue) {
                set(.lsf, .needsLogin)
                succeeded = false
            } else if planOK && gradesOK {
                set(.lsf, .ok(now))
            } else if r.cancelled {
                set(.lsf, before.1)
            } else {
                set(.lsf, .failed(message(["LSF", "Stundenplan", "Notenspiegel"])))
                succeeded = false
            }
        }
        if r.completed.contains(Part.grades) {
            defaults.set(now, forKey: Keys.gradesRun)
            StudyCatalogSync.trigger(host: host)     // Studiengang aus dem Notenspiegel -> Modulkatalog suchen (Hintergrund)
        }
        // wartende Learnweb-Dateien: merken (nur Listen) bzw. erledigt, sobald ein voller Learnweb-Teil durchlief (auch
        // wenn das LSF dabei eine neue Anmeldung braucht)
        if scope == .lists, r.waiting > 0 {
            defaults.set(true, forKey: Keys.downloadsPending)
        } else if scope == .full, r.completed.contains(Part.learnweb), defaults.object(forKey: Keys.downloadsPending) != nil {
            defaults.removeObject(forKey: Keys.downloadsPending)
        }
        finish(messages: all, report: r, succeeded: succeeded, scope: scope)
    }

    /// Ende eines Laufs: Meldungen merken; die 30-Minuten-Sperre (`lastRun`) wie beim Stud.IP-Abgleich nur nach einem
    /// Lauf ohne Fehler (vorher auch nach einem gescheiterten, dann wartete der naechste Versuch 30 Minuten) und nur
    /// nach einem vollen Lauf (einer nur mit Listen hat nichts geladen)
    private func finish(messages all: [String], report: HildesheimSync.Report?, succeeded: Bool, scope: UniSyncScope) {
        lastReport = report
        messages = all
        defaults.set(all, forKey: Keys.messages)
        guard succeeded, scope == .full else { return }
        lastRun = clock.now
        defaults.set(lastRun, forKey: Keys.lastRun)
    }

    // MARK: Anzeige

    /// "Learnweb: 16:30 ok", "LSF: Anmeldung nötig" (Uhrzeit in Berlin; nicht von heute mit Datum)
    static func statusText(_ s: Source, _ state: State, now: Date = Date()) -> String {
        let what: String
        switch state {
        case .notConnected: what = "nicht verbunden"
        case .connected: what = "verbunden"
        case .running: what = "gleicht ab …"
        case .ok(let d): what = "\(time(d, now: now)) ok"
        case .needsLogin: what = "Anmeldung nötig"
        case .failed: what = "Fehler"
        }
        return "\(s.rawValue): \(what)"
    }

    /// Uhrzeit fuer Statustexte (auch QISConnection)
    static func time(_ d: Date, now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = cal.timeZone
        f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "dd.MM. HH:mm"
        return f.string(from: d)
    }
}

/// Anmeldung bei Learnweb oder LSF in der Webansicht des Containers (CAS der Uni). Die Studierenden tippen ihre
/// Zugangsdaten selbst ein und tippen selbst auf "Anmelden"; die App liest und fuellt keine Felder, ein gespeichertes
/// Passwort setzt hoechstens iOS ein (Passwort-Autofill aus dem Schluesselbund).
///
/// - LSF: `HildesheimCAS.lsfLoginURL`; fertig, sobald eine Seite des LSF angemeldet ist (`LSFClient.isLoggedIn`).
/// - Learnweb: Instanz des Semesters (`Learnweb.discoverBase`), dann `MoodleSSO.publicConfig`. Ist das SSO moeglich,
///   oeffnet die Webansicht `MoodleSSO.launchURL(config:base:passport:)` mit einem neuen Passport; die abschliessende
///   Weiterleitung `<schema>://token=…` faengt `intercept` ab (nie an das System), `MoodleSSO.parseLaunchToken` prueft
///   Passport und Adresse, der Schluessel geht in den Schluesselbund. Sonst der Sitzungsweg
///   `HildesheimCAS.learnwebLoginURL(base:)`: fertig auf einer angemeldeten Learnweb-Seite (`Learnweb.isLoggedIn`).
@MainActor
final class HildesheimLogin: ObservableObject {
    nonisolated static let log = Logger(subsystem: "de.uniflow.ai", category: "hildesheim-login")

    enum Stage: Equatable {
        case preparing
        /// Webansicht mit dieser Seite
        case page(URL)
        case done
        case failed(String)
    }

    @Published private(set) var stage: Stage = .preparing
    /// Fehlertext des CAS (z. B. falsches Passwort), aus #loginErrorsPanel
    @Published private(set) var casError: String?
    let target: HildesheimConnection.Source
    let connection: HildesheimConnection
    /// Learnweb ueber das Moodle-SSO (Schluessel) statt der Sitzung
    private(set) var viaToken = false
    private(set) var base: String?
    private var passport: String?
    private var scheme = MoodleSSO.defaultScheme
    private var siteURLs: [String] = []

    init(target: HildesheimConnection.Source, connection: HildesheimConnection) {
        self.target = target
        self.connection = connection
    }

    /// Startseite bestimmen (Learnweb: Netz fuer Instanz und Konfiguration, ohne Anmeldedaten). Ein unterbrochenes
    /// Abmelden wird vorher zu Ende gebracht: die Anmeldeseite sieht keine Cookies der alten Sitzung.
    func prepare() async {
        stage = .preparing
        casError = nil
        await connection.finishPendingSignOut()
        switch target {
        case .lsf:
            stage = URL(string: HildesheimCAS.lsfLoginURL).map(Stage.page) ?? .failed("Anmeldeseite des LSF fehlt.")
        case .learnweb:
            let t = await connection.transport()
            let day = connection.yearMonth
            let found = await Learnweb.discoverBase(year: day.year, month: day.month, transport: t)
            guard let b = found else {
                stage = .failed("Das Learnweb ist gerade nicht erreichbar. Bitte prüfe die Verbindung und versuche es erneut.")
                return
            }
            base = b
            do {
                let config = try await MoodleSSO.publicConfig(base: b, transport: t)
                let p = MoodleSSO.newPassport()
                let launch = try MoodleSSO.launchURL(config: config, base: b, passport: p)
                guard let url = URL(string: launch) else { throw HildesheimError.ssoUnavailable("Startadresse") }
                passport = p
                scheme = config.urlScheme
                siteURLs = [config.wwwroot, config.httpsWWWRoot].compactMap { $0 }
                viaToken = true
                stage = .page(url)
            } catch {
                // Uni erlaubt das App-Schema nicht oder die Schnittstelle ist aus: Sitzung der Webansicht
                viaToken = false
                passport = nil
                stage = URL(string: HildesheimCAS.learnwebLoginURL(base: b)).map(Stage.page) ?? .failed("Anmeldeseite des Learnweb fehlt.")
            }
        }
    }

    /// Fuer `decidePolicyFor navigationAction`: true = Navigation abbrechen. Alles ausser http(s) und about geht nie an
    /// das System (keine andere App); die Moodle-Antwort `<schema>://token=…` wird hier ausgewertet. http im Hauptrahmen
    /// haelt die Webansicht selbst an (`StudIPWebView.blocksMainFrame`).
    func intercept(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        if s == "https" || s == "http" || s == "about" { return false }
        if s == "file", DebugUniStub.isActive { return false }                 // nur Debug: lokale Nachbildung der Anmeldeseite
        guard target == .learnweb, viaToken, let base, let passport,
              MoodleSSO.isTokenRedirect(url.absoluteString, scheme: scheme) else { return true }
        self.passport = nil                                              // jede Antwort gilt nur einmal
        guard let token = MoodleSSO.parseLaunchToken(url.absoluteString, base: base, passport: passport, scheme: scheme,
                                                     siteURLs: siteURLs) else {
            stage = .failed("Die Antwort des Learnweb passt nicht zu dieser Anmeldung. Bitte versuche es erneut.")
            return true
        }
        stage = connection.learnwebSignedIn(token: token, base: base)
            ? .done : .failed(UFDevice.adapt("Der Learnweb-Schlüssel ließ sich nicht im Schlüsselbund dieses iPads ablegen."))
        return true
    }

    /// Nur Debug mit -UFLoginStub (DebugUniStub): die Nachbildung zeigt "angemeldet" - verbunden wie nach der echten
    /// Anmeldung (Learnweb mit erfundenem Schluessel fuer die gefundene Instanz, LSF ueber die Sitzung)
    func stubSignedIn() {
        guard DebugUniStub.isActive, stage != .done else { return }
        switch target {
        case .lsf:
            connection.lsfSignedIn()
            stage = .done
        case .learnweb:
            guard let base else { return }
            stage = connection.learnwebSignedIn(token: viaToken ? LearnwebToken("StubSchluessel0001") : nil, base: base) ? .done : .failed("Stub")
        }
    }

    /// Nach jeder geladenen Seite (Hauptrahmen): fertig? Fehlertext des CAS?
    func pageLoaded(url: URL?, html: String) {
        guard stage != .done, let url else { return }
        if HildesheimCAS.isCASPage(url.absoluteString) {
            casError = HildesheimCAS.errorText(html: html)
            return
        }
        casError = nil
        switch target {
        case .lsf:
            // Nur Rechner, Pfad und Merkmale ins Protokoll (keine Abfrage mit Ticket oder Sitzung, kein Seiteninhalt):
            // so laesst sich eine echte LSF-Seite pruefen, die die Anmeldung nicht erkennt
            Self.log.info("LSF-Seite \(url.host ?? "-", privacy: .public)\(HildesheimCAS.loggablePath(url), privacy: .public): Laenge \(html.count), abmelden \(html.range(of: "abmelden", options: .caseInsensitive) != nil), auth.logout \(html.contains("auth.logout")), auth.login \(html.contains("auth.login"))")
            // dieselbe Regel wie fuer jede Seite im Abgleich (LSF ueber HTTPS mit "Abmelden")
            if LSFClient.isLoggedIn(html: html, url: url) {
                connection.lsfSignedIn()
                stage = .done
            }
        case .learnweb:
            // Sitzungsweg: angemeldete Seite der Instanz (beim SSO-Weg zaehlt nur der Schluessel)
            guard !viaToken, let base, url.absoluteString.hasPrefix(base + "/"), Learnweb.isLoggedIn(html: html) else { return }
            if connection.learnwebSignedIn(token: nil, base: base) { stage = .done }
        }
    }
}

// MARK: Bescheinigungen (CertificateCenter, docs/BESCHEINIGUNGEN-2026-11-06.md): PLuS mit eigener Anmeldung im
// Datenspeicher dieses Containers (der Transport laesst *.uni-hildesheim.de zu); das LSF bleibt unberuehrt
extension HildesheimConnection {
    var certificateClock: UniFlowClock { clock }
    func certificateTransport() async -> UniTransport { await makeTransport(websiteDataStore) }
    var certificateHost: LocalBackendHost { host }
}
