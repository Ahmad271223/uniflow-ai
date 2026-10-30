import BackgroundTasks
import Foundation
import UIKit
import UniFlowCore
import UserNotifications

// Abgleich im Hintergrund (S8, docs/STUDIFLOW-PLAN.md "Abgleich um 8, 15 und 20 Uhr", docs/AUFGABENTEILUNG-APPLE-PC.md
// M12). Zwei Aufgaben beim BGTaskScheduler (Kennungen in project.yml, BGTaskSchedulerPermittedIdentifiers):
// - BGAppRefreshTask `de.uniflow.ai.sync.refresh` (rund 30 Sekunden): nur die Listen (neue Kurse, Dateilisten,
//   Stundenplan), keine Downloads
// - BGProcessingTask `de.uniflow.ai.sync.files` mit Netz: der volle Abgleich wie beim Oeffnen, also auch die neuen
//   Dateien laden
// Beide fruehestens zum naechsten Zeitpunkt 8:00, 15:00 oder 20:00 Ortszeit (`BackgroundSchedule`); wann genau,
// entscheidet iOS (Nutzung, Akku, Netz, Energiesparmodus, Hintergrundaktualisierung). Neu geplant beim Start, beim
// Wechsel in den Hintergrund und nach jedem Lauf; ein schon bestellter, nicht spaeterer Termin bleibt dabei stehen
// (`BackgroundSchedule.keepsPending`), sonst schoebe jeder kurze Lauf den langen nach hinten. Sicher bleibt der Abgleich
// beim Oeffnen (`runIfDue`).
//
// Regeln je Lauf (`perform`, Pruefung in `BackgroundSyncGate`):
// - nur der Container des angemeldeten Nutzers und der gewaehlten Hochschule; nicht waehrend eines Konto- oder
//   Hochschulwechsels oder der Einrichtung; nie neben einem laufenden Abgleich desselben Containers
//   (`ContainerManager.isSyncing`, dazu die Sperre `isRunning` des Abgleichs selbst)
// - nur mit gespeicherter, nicht als abgelaufen bekannter Sitzung; nie eine Anmeldeseite, nie gemerkte Zugangsdaten.
//   Laeuft sie ab, kommt hoechstens einmal "Bitte bei … anmelden" (`BackgroundSyncState`)
// - der expirationHandler bricht ab (`BackgroundTaskRun`); halbe Dateien sind nie sichtbar (`.part` und `rename` in
//   `UniDownloads`), was gelesen war, steht in der Datenbank
// - Benachrichtigung "N neue Dateien aus Stud.IP/Learnweb" nur mit dem Schalter in den Einstellungen und Erlaubnis von
//   iOS, nie mit Dateinamen; um die Erlaubnis fragt erst der Schalter, nie der Start der App
// - Stand je Container (letzter Lauf, Hinweis gezeigt) in dessen Einstellungs-Suite; nach dem Loeschen eines
//   Containers schreibt ein spaet endender Lauf nichts mehr hinein
// - Wochentests (docs/WOCHENTESTS.md "Hintergrundlauf"): der lange Lauf prueft nach dem Abgleich, auch wenn dieser
//   ausfiel (Sitzung abgelaufen, Schalter aus), ob ein gemeinsamer Wochentest faellig ist (`WeeklyBackground.decision`),
//   und erzeugt ihn (`WeeklyAutoTick.run`); dafuer wird der lange Lauf auch mit ausgeschaltetem Abgleich zum Termin
//   `next_at` bestellt. Ein Abbruch durch iOS kostet keinen der drei Versuche eines Plans. Mitteilung "Neuer Wochentest
//   verfügbar" nach denselben Regeln wie die zu neuen Dateien.

/// Kennungen der Aufgaben (Info.plist BGTaskSchedulerPermittedIdentifiers)
enum BackgroundTaskID {
    static let refresh = "de.uniflow.ai.sync.refresh"
    static let processing = "de.uniflow.ai.sync.files"
    static let all = [refresh, processing]

    static func of(_ kind: BackgroundSyncKind) -> String { kind == .refresh ? refresh : processing }
}

/// Laeuft die App gerade im Hintergrund (Start durch iOS fuer eine Hintergrundaufgabe)? Tests setzen einen festen Wert.
enum AppActivity {
    @MainActor static var isInBackground: () -> Bool = { UIApplication.shared.applicationState == .background }
}

/// Schalter in den Einstellungen, fuer dieses iPad (UserDefaults der App): Abgleich im Hintergrund (Vorgabe an) und
/// Benachrichtigen bei neuen Dateien (Vorgabe aus)
struct BackgroundSyncSettings {
    static let enabledKey = "uniflow.background.enabled"
    static let notifyKey = "uniflow.background.notify"

    let defaults: UserDefaults

    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var notify: Bool {
        get { defaults.bool(forKey: Self.notifyKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.notifyKey) }
    }
}

/// Termine bei iOS bestellen und abbestellen (BGTaskScheduler; Tests: Mitschreiber)
@MainActor
protocol BackgroundTaskScheduling: AnyObject {
    /// bestellte, noch nicht gestartete Termine je Aufgabe (Wert: fruehester Beginn, nil ohne Uhrzeit)
    func pending() async -> [BackgroundSyncKind: Date?]
    func submit(_ kind: BackgroundSyncKind, earliest: Date) throws
    func cancel(_ kind: BackgroundSyncKind)
}

final class SystemBackgroundScheduler: BackgroundTaskScheduling {
    func pending() async -> [BackgroundSyncKind: Date?] {
        var out: [BackgroundSyncKind: Date?] = [:]
        for r in await BGTaskScheduler.shared.pendingTaskRequests() {
            guard let kind = BackgroundSyncKind.allCases.first(where: { BackgroundTaskID.of($0) == r.identifier }) else { continue }
            out[kind] = .some(r.earliestBeginDate)
        }
        return out
    }

    func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {
        let request: BGTaskRequest
        switch kind {
        case .refresh:
            request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.refresh)
        case .processing:
            let p = BGProcessingTaskRequest(identifier: BackgroundTaskID.processing)
            p.requiresNetworkConnectivity = true                 // Downloads brauchen Netz
            p.requiresExternalPower = false                      // iOS legt ihn ohnehin gern ans Ladekabel
            request = p
        }
        request.earliestBeginDate = earliest                     // nur "fruehestens"
        // ersetzt einen schon bestellten Termin derselben Kennung
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(_ kind: BackgroundSyncKind) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundTaskID.of(kind))
    }
}

/// Eine von iOS gestartete Aufgabe (BGTask; Tests: Attrappe)
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: BackgroundTaskHandle {}

/// Lokale Benachrichtigungen (UNUserNotificationCenter; Tests: Mitschreiber)
@MainActor
protocol BackgroundNotifying: AnyObject {
    /// Erlaubnis bei iOS erfragen (nur aus dem Schalter in den Einstellungen); true = erlaubt
    func requestPermission() async -> Bool
    /// Erlaubt, ohne zu fragen?
    func isAllowed() async -> Bool
    /// `id`: gleiche Kennung ersetzt die alte; `thread`: Gruppe in der Mitteilungszentrale (Container)
    func post(_ content: BackgroundNotice.Content, id: String, thread: String) async
}

/// Eigene Schicht des Hintergrundabgleichs: eigene Kennungen (Kategorie, Mitteilungen, Gruppen mit dem Praefix
/// `de.uniflow.ai.sync.`), eigener Schalter (`BackgroundSyncSettings.notifyKey`). Andere Mitteilungen der App (Lern-Timer,
/// Erinnerungen) bleiben unberuehrt: keine Kategorie wird ersetzt, nichts Fremdes entfernt.
final class SystemBackgroundNotifier: BackgroundNotifying {
    /// Kategorie mit eigenem Platzhalter fuer ausgeblendete Vorschauen (Sperrbildschirm)
    static let category = "de.uniflow.ai.sync"
    /// Praefix aller Kennungen dieser Schicht (Mitteilungen und Gruppen)
    static let prefix = "de.uniflow.ai.sync."
    private var categoryRegistered = false

    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default: return false
        }
    }

    func isAllowed() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    func post(_ content: BackgroundNotice.Content, id: String, thread: String) async {
        let center = UNUserNotificationCenter.current()
        if !categoryRegistered {
            // ohne Option .hiddenPreviewsShowTitle: bei ausgeblendeter Vorschau nur der Platzhalter. setNotificationCategories
            // ersetzt alle Kategorien der App: die vorhandenen anderer Schichten (Erinnerungen) bleiben dabei stehen
            let mine = UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: [],
                                              hiddenPreviewsBodyPlaceholder: BackgroundNotice.hiddenPreviewPlaceholder, options: [])
            let others = await center.notificationCategories().filter { $0.identifier != Self.category }
            center.setNotificationCategories(others.union([mine]))
            categoryRegistered = true
        }
        let c = UNMutableNotificationContent()
        c.title = content.title
        c.body = content.body
        c.sound = .default
        c.categoryIdentifier = Self.category
        c.threadIdentifier = thread
        try? await center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

/// Ein Abgleich, den der Hintergrund starten kann: Stud.IP der LUH (`StudIPSync`), Learnweb/LSF der Uni Hildesheim
/// (`HildesheimConnection`)
@MainActor
protocol BackgroundSyncable: AnyObject {
    /// Quelle der Dateien fuer "N neue Dateien aus …"
    var fileSource: String { get }
    /// Quellen mit gespeicherter, nicht als abgelaufen bekannter Sitzung (leer: kein Lauf)
    var usableSources: [String] { get }
    var isRunning: Bool { get }
    func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport
}

extension StudIPSync: BackgroundSyncable {
    var fileSource: String { "Stud.IP" }

    var usableSources: [String] { offersStudIP && hasStoredSession && !sessionKnownExpired ? ["Stud.IP"] : [] }

    /// Mit dem Sitzungs-Cookie aus dem Schluesselbund, nie unter XCTest (Tests rufen die Fassung mit Client)
    func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport {
        guard !Self.isUnderTest() else { return .skipped(.noSession) }
        let cookies = self.cookies.load()
        guard !cookies.isEmpty else { return .skipped(.noSession) }
        return await runInBackground(kind, client: liveClient(cookies))
    }

    /// Ein Hintergrundlauf mit diesem Client: nur mit gueltiger Sitzung (sonst nichts, keine Anfrage), Umfang nach
    /// `kind`; neue Dateien = Kennungen nachher ohne die vorher
    func runInBackground(_ kind: BackgroundSyncKind, client: StudIPClient) async -> BackgroundSyncReport {
        guard offersStudIP, !stopped else { return .skipped(.noContainer) }
        if await demoActive() { return .skipped(.demo) }          // Demo-Inhalte: nie zur Hochschule
        guard usableSources.contains("Stud.IP") else { return .skipped(.noSession) }
        let before = await sourceFileIDs()
        guard !isRunning, let end = await run(client: client, scope: kind.scope) else { return .skipped(.alreadyRunning) }
        let after = await sourceFileIDs()
        let newFiles = before.flatMap { b in after.map { $0.subtracting(b).count } } ?? 0
        switch end {
        case .completed: return BackgroundSyncReport(newFiles: newFiles)
        case .sessionExpired: return BackgroundSyncReport(newFiles: newFiles, loginNeeded: ["Stud.IP"])
        case .cancelled: return BackgroundSyncReport(newFiles: newFiles, cancelled: true)
        case .failed(let m): return BackgroundSyncReport(newFiles: newFiles, failure: m)
        }
    }
}

extension HildesheimConnection: BackgroundSyncable {
    var fileSource: String { "Learnweb" }

    var usableSources: [String] { sources(background: true).sorted { $0.rawValue < $1.rawValue }.map(\.rawValue) }

    /// Nur die Quellen ohne bekannte abgelaufene Anmeldung (`sources(background:)`); welche in diesem Lauf abliefen,
    /// zeigt der Stand danach
    func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport {
        guard !stopped else { return .skipped(.noContainer) }
        if await demoActive() { return .skipped(.demo) }          // Demo-Inhalte: nie zur Hochschule
        let sources = self.sources(background: true)
        guard !sources.isEmpty else { return .skipped(.noSession) }
        // nur Learnweb mit Schluessel und das iPad gesperrt: nichts zu tun (der Lauf liesse Learnweb ohnehin aus)
        if sources == [.learnweb], learnwebMode == .token, !protectedDataAvailable() { return .skipped(.deviceLocked) }
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
}

/// Hintergrundabgleich der App: Anmeldung der Aufgaben bei iOS, Termine, Lauf auf dem offenen Container, Stand und
/// Benachrichtigungen. Die App baut einen beim Start (`UniFlowApp`); Tests mit Attrappen fuer Planer, Aufgabe,
/// Benachrichtigungen und Abgleich.
@MainActor
final class BackgroundSyncController: ObservableObject {
    /// zaehlt jeden beendeten Hintergrundlauf (die Karte in den Einstellungen liest den Stand neu)
    @Published private(set) var revision = 0
    /// zuletzt bestellter Termin (nil: keiner, z. B. ausgeschaltet)
    @Published private(set) var nextPlanned: Date?

    let containers: ContainerManager
    let account: AccountStore
    let settings: BackgroundSyncSettings
    let scheduler: BackgroundTaskScheduling
    let notifier: BackgroundNotifying
    var now: () -> Date = { Date() }
    /// Ortszeit des Geraets (auf Reisen die dortige)
    var timeZone: () -> TimeZone = { TimeZone.current }
    /// Automatische Abgleiche erlaubt (nie unter XCTest, -UFNoStudIPSync oder Startargumenten fuer Bildvergleiche)
    var allowed: () -> Bool = { StudIPSync.automaticRunAllowed() }
    /// Abgleich des Containers (Tests: gefaelschter Abgleich)
    var target: (ActiveContainer) -> BackgroundSyncable?
    /// Gnadenfrist nach dem Ablauf, bevor die Aufgabe auch ohne Ende des Laufs abgeschlossen wird
    var graceNanos: UInt64 = 1_000_000_000
    /// Hintergrundaktualisierung in den iPad-Einstellungen (Karte: Hinweis, wenn aus)
    var refreshStatus: () -> UIBackgroundRefreshStatus = { UIApplication.shared.backgroundRefreshStatus }
    /// Takt der Wochentests im langen Lauf (Tests: Attrappe)
    var weeklyTick: (LocalContext) async -> WeeklyAutoTick.Outcome = { await WeeklyAutoTick.run($0) }
    /// Ergebnis des letzten Wochentest-Schritts eines Hintergrundlaufs in diesem Prozess (nil: noch keiner; Tests)
    private(set) var lastWeekly: WeeklyAutoTick.Outcome?

    private static var registered = false

    /// `scheduler`, `notifier`: nil = BGTaskScheduler bzw. UNUserNotificationCenter
    init(containers: ContainerManager, account: AccountStore, settings: BackgroundSyncSettings = BackgroundSyncSettings(defaults: .standard),
         scheduler: BackgroundTaskScheduling? = nil, notifier: BackgroundNotifying? = nil) {
        self.containers = containers
        self.account = account
        self.settings = settings
        self.scheduler = scheduler ?? SystemBackgroundScheduler()
        self.notifier = notifier ?? SystemBackgroundNotifier()
        target = { [weak containers] c in
            guard let containers, containers.active === c else { return nil }
            return c.key.university == .hildesheim ? containers.hildesheim : (containers.studip.offersStudIP ? containers.studip : nil)
        }
    }

    // MARK: Anmelden und planen

    /// Beide Aufgaben bei iOS anmelden (einmal je Prozess, vor dem Ende des App-Starts)
    func register() {
        guard !Self.registered else { return }
        Self.registered = true
        for kind in BackgroundSyncKind.allCases {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskID.of(kind), using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.handle(task, kind: kind)
                }
            }
        }
    }

    /// Beide Aufgaben auf den naechsten Zeitpunkt 8, 15 oder 20 Uhr Ortszeit legen; ein bestellter, nicht spaeterer
    /// Termin bleibt (`keepsPending`), `ran` (die eben gestartete Aufgabe) bestellt immer neu. Ausgeschaltet: beide
    /// abbestellen; nur der lange Lauf bleibt bestellt, wenn ein Wochentest einen Termin braucht (`next_at` aus
    /// `WeeklyBackground.decision`, Berliner Zeit); mit Schalter ist sein fruehester Beginn der fruehere der beiden
    /// Termine. Unter XCTest und mit Startargumenten fuer Bildvergleiche geschieht nichts (Tests setzen `allowed`).
    /// Rueckgabe: neu bestellte Termine (Tests).
    @discardableResult
    func schedule(ran: BackgroundSyncKind? = nil) async -> [BackgroundSyncKind: Date] {
        guard allowed() else { return [:] }
        let weeklyAt = await weeklyNextAt()
        guard settings.enabled || weeklyAt != nil else {
            for k in BackgroundSyncKind.allCases { scheduler.cancel(k) }
            nextPlanned = nil
            return [:]
        }
        let at = BackgroundSchedule.next(after: now(), timeZone: timeZone())
        let pending = await scheduler.pending()
        // inzwischen ausgeschaltet (Schalter waehrend der Abfrage): nur noch der Termin der Wochentests
        let enabled = settings.enabled
        var submitted: [BackgroundSyncKind: Date] = [:]
        var earliest: [Date] = []
        for k in BackgroundSyncKind.allCases {
            let wanted: Date?
            switch k {
            case .refresh: wanted = enabled ? at : nil
            case .processing: wanted = enabled ? min(at, weeklyAt ?? at) : weeklyAt
            }
            guard let wanted else {
                scheduler.cancel(k)
                continue
            }
            if k != ran, let p = pending[k], BackgroundSchedule.keepsPending(p, next: wanted) {
                earliest.append(p ?? wanted)
                continue
            }
            // abgelehnt (Hintergrundaktualisierung aus, Simulator, zu viele Termine): beim naechsten Planen erneut
            if (try? scheduler.submit(k, earliest: wanted)) != nil {
                submitted[k] = wanted
                earliest.append(wanted)
            }
        }
        nextPlanned = earliest.min()
        return submitted
    }

    /// Naechster Termin, an dem ein Wochentest des offenen Containers etwas zu tun haben kann (`next_at`); nil ohne
    /// offenen Plan mit Versuchen, ohne verbundene KI, ohne Backend oder waehrend eines Wechsels
    private func weeklyNextAt() async -> Date? {
        guard let c = containers.active, c.key == account.containerKey, account.stage == .ready, containers.problem == nil,
              let backend = try? await c.host.backend(),
              let decision = try? await WeeklyBackground.decision(backend.context), decision.action != "no_ai" else { return nil }
        return decision.nextAt
    }

    /// Schalter "Im Hintergrund abgleichen"
    func setEnabled(_ on: Bool) {
        settings.enabled = on
        Task { await schedule() }
    }

    /// Schalter "Benachrichtigen bei neuen Dateien": erst hier fragt iOS nach der Erlaubnis. false, wenn sie fehlt
    /// (abgelehnt oder in den iPad-Einstellungen aus); dann bleibt der Schalter aus.
    func setNotify(_ on: Bool) async -> Bool {
        guard on else {
            settings.notify = false
            return true
        }
        let ok = await notifier.requestPermission()
        settings.notify = ok
        return ok
    }

    // MARK: Lauf

    private final class TaskBox: @unchecked Sendable {
        let task: BackgroundTaskHandle
        init(_ task: BackgroundTaskHandle) { self.task = task }
    }

    /// Start durch iOS: naechsten Termin dieser Aufgabe gleich bestellen (auch wenn dieser Lauf abbricht oder die App
    /// beendet wird), Lauf starten, Ablauf bricht ihn ab, genau ein Abschluss; danach erneut planen (`perform`)
    func handle(_ task: BackgroundTaskHandle, kind: BackgroundSyncKind) {
        let box = TaskBox(task)
        let run = BackgroundTaskRun(graceNanos: graceNanos) { end in
            box.task.setTaskCompleted(success: end == .finished(success: true))
            box.task.expirationHandler = nil                     // Aufgabe und Lauf halten sich nicht gegenseitig
        }
        task.expirationHandler = { run.expire() }
        run.start { [weak self] in
            guard let self else { return false }
            await self.schedule(ran: kind)
            return await self.perform(kind, expired: { run.isExpired })
        }
    }

    /// Ein Hintergrundlauf auf dem offenen Container. Rueckgabe: Erfolg fuer `setTaskCompleted`.
    @discardableResult
    func perform(_ kind: BackgroundSyncKind, expired: @escaping () -> Bool = { false }) async -> Bool {
        let ok = await performRun(kind, expired: expired)
        await schedule()                                         // nach jedem Lauf neu planen
        return ok
    }

    private func performRun(_ kind: BackgroundSyncKind, expired: @escaping () -> Bool) async -> Bool {
        let c = containers.active
        let target = c.flatMap { self.target($0) }
        let situation = BackgroundSyncSituation(
            enabled: allowed() && settings.enabled,
            hasContainer: c != nil && containers.problem == nil && target != nil,
            switching: c?.key != account.containerKey || account.stage != .ready,
            syncRunning: (c.map { containers.isSyncing($0.key) } ?? false) || (target?.isRunning ?? false),
            usableSession: !(target?.usableSources.isEmpty ?? true),
            demo: containers.demoActive)
        let reason = BackgroundSyncGate.skipReason(situation)
        // Wochentests nur im langen Lauf, unabhaengig vom Gate des Abgleichs (auch mit abgelaufener Sitzung oder
        // ausgeschaltetem Abgleich), aber nur im passenden Container und nie neben einem laufenden Abgleich
        // (direkt aus der Lage: bei ausgeschaltetem Abgleich nennt das Gate nur .disabled)
        let weekly = kind == .processing && allowed() && situation.hasContainer && !situation.switching && !situation.syncRunning
        if let reason {
            // im passenden Container festhalten, dass iOS gestartet hat (nicht waehrend eines Wechsels)
            if let c, reason != .noContainer, reason != .switching, c.layout.exists() {
                BackgroundSyncState(defaults: c.defaults).record(BackgroundSyncRecord(finishedAt: now(), kind: kind, outcome: .skipped(reason)))
                revision += 1
            }
            if weekly, let c { await runWeekly(c, expired: expired) }
            return true
        }
        guard let c, let target else { return true }
        let state = BackgroundSyncState(defaults: c.defaults)
        // wieder gueltige Sitzungen: der naechste Ablauf darf wieder einmal melden
        for s in target.usableSources { state.sessionUsable(s) }
        var report = await target.runInBackground(kind)
        if expired() { report.cancelled = true }
        // Container inzwischen geloescht (oder geloescht und leer neu angelegt): nichts mehr hineinschreiben, nichts melden
        guard owns(c) else { return false }
        if report.skipped == nil, containers.active === c, settings.notify, await notifier.isAllowed() {
            let container = c.layout.identifier.uuidString, prefix = SystemBackgroundNotifier.prefix
            let thread = prefix + container
            if let n = BackgroundNotice.newFiles(report.newFiles, source: target.fileSource) {
                await notifier.post(n, id: prefix + "files.\(container).\(UUID().uuidString)", thread: thread)
            }
            let due = state.loginNoticeDue(report)
            if let n = BackgroundNotice.loginNeeded(due) {
                await notifier.post(n, id: prefix + "login.\(container)", thread: thread)
                due.forEach(state.markLoginNoticeSent)
            }
        }
        if owns(c) {
            state.record(BackgroundSyncRecord(finishedAt: now(), kind: kind, outcome: BackgroundSyncRecord.outcome(report)))
            // neue Dateien und Fristen: Abgaben-Erinnerungen gleich neu planen, nicht erst beim naechsten Oeffnen
            if report.skipped == nil, !report.cancelled, containers.active === c { DueReminderScheduler.shared.schedule(recompute: true) }
        }
        // nach dem Abgleich (der volle Abgleich hat selbst schon getaktet): faellige Wochentests, solange Zeit ist
        if weekly, !report.cancelled { await runWeekly(c, expired: expired) }
        revision += 1
        return report.skipped != nil || (!report.cancelled && report.failure == nil)
    }

    /// Wochentests im langen Lauf (docs/WOCHENTESTS.md "Hintergrundlauf"): Entscheidung aus dem Stand der Plaene
    /// (`WeeklyBackground.decision`: `auto_tests`, KI verbunden, kein anderer Auftrag, ein Plan faellig), bei `run` der
    /// Takt wie im Vordergrund (`weeklyTick`). Hat er etwas veroeffentlicht, laden offene Boxen neu und es kommt
    /// "Neuer Wochentest verfügbar" (nur mit dem Schalter und der Erlaubnis von iOS, ohne Fach oder Inhalt). Ein
    /// Abbruch durch iOS (`Task.cancel` aus `BackgroundTaskRun.expire`) kostet keinen Versuch (`.cancelled`).
    /// Rueckgabe: nil ohne Lauf (nichts faellig, Zeit um, Backend nicht offen, Container inzwischen geloescht).
    @discardableResult
    private func runWeekly(_ c: ActiveContainer, expired: @escaping () -> Bool) async -> WeeklyAutoTick.Outcome? {
        guard !expired(), owns(c), let backend = try? await c.host.backend(),
              let decision = try? await WeeklyBackground.decision(backend.context), decision.action == "run" else { return nil }
        let outcome = await weeklyTick(backend.context)
        lastWeekly = outcome
        guard case .ran(_, let changed) = outcome, changed, owns(c), containers.active === c else { return outcome }
        NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil)
        if settings.notify, await notifier.isAllowed() {
            let container = c.layout.identifier.uuidString, prefix = SystemBackgroundNotifier.prefix
            await notifier.post(BackgroundNotice.weeklyTest, id: prefix + "weekly.\(container).\(UUID().uuidString)", thread: prefix + container)
        }
        return outcome
    }

    /// Darf ein Lauf noch in seinen Container schreiben? Nur, wenn es ihn noch gibt und er nicht inzwischen geloescht
    /// und unter demselben Schluessel leer neu geoeffnet wurde (Daten der Hochschule geloescht)
    private func owns(_ c: ActiveContainer) -> Bool {
        guard c.layout.exists() else { return false }
        if let a = containers.active, a.key == c.key { return a === c }
        return true
    }

    // MARK: Anzeige

    /// letzter Hintergrundlauf des offenen Containers
    var lastRecord: BackgroundSyncRecord? { containers.active.flatMap { BackgroundSyncState(defaults: $0.defaults).last } }
}
