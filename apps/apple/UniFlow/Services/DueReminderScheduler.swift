import Combine
import Foundation
import SwiftUI
import UniFlowCore
import UserNotifications

// Erinnerungen an Abgaben und Pruefungen: eine kleine, eigene Schicht ueber lokalen Mitteilungen. Der Plan kommt aus
// dem Kern (`DueReminders.plan`: 3 Tage, 1 Tag, Morgen 8:00, mit Uhrzeit 2 Stunden vorher, hoechstens 60), die Termine
// aus GET /api/due des offenen Containers. Neu geplant wird nach jedem Abgleich (vorher fehlende Seitentexte nachlesen,
// POST /api/due/backfill, und neu erkennen, POST /api/due/refresh), beim
// Wechsel des Containers, beim Oeffnen der App und nach Aenderungen in der Liste (ausblenden, bestaetigen, Uhrzeit).
// Kennungen "de.uniflow.ai.due.<Container>.<Termin>.<Zeitpunkt>"; nur diese werden ersetzt oder zurueckgenommen, andere
// Mitteilungen der App (z. B. "de.uniflow.ai.sync.*" vom Hintergrundabgleich) bleiben unberuehrt. Die Erlaubnis fragt
// erst der Schalter in den Einstellungen, nie der Start der App.
//
// Seit 17.11.2026 ("Klausur stand nur in einer Folie"):
// - Nachlesen auch fuer PowerPoint und Word, im Vordergrund bis 25 x 20 Dateien je Lauf (vorher 5 x 20, nur PDF)
// - Folien als Bild: Texterkennung in Portionen (POST /api/due/ocr), nur im Vordergrund und nicht im Stromsparmodus,
//   nach dem Planen (die Erinnerungen warten nicht darauf); findet sie etwas, wird einmal neu geplant
// - ein neu erkannter Klausur- oder Testtermin wird einmal sofort gemeldet (`DueReminders.newNotices`), mit denselben
//   Bedingungen wie die Erinnerungen (Schalter, Tarif, Erlaubnis von iOS); die Uebersicht zeigt ihn in jedem Fall
// - ein Lauf ohne angehaengte Container (Start durch iOS im Hintergrund, bevor ein Fenster erscheint) nimmt nichts mehr
//   zurueck; der Hintergrundabgleich haengt die Container selbst an und wartet auf das Planen

/// Was iOS zu Mitteilungen sagt
enum DueNotificationStatus: Equatable { case allowed, denied, notDetermined }

/// Lokale Mitteilungen (Tests: Mitschreiber)
@MainActor
protocol DueNotifying: AnyObject {
    func status() async -> DueNotificationStatus
    func requestPermission() async -> Bool
    func pendingIdentifiers() async -> [String]
    func schedule(_ r: DueReminders.Reminder) async
    /// sofort zustellen ("Neuer Klausurtermin erkannt")
    func post(_ r: DueReminders.Reminder) async
    func remove(_ identifiers: [String])
}

extension DueNotifying {
    /// Vorgabe fuer Mitschreiber, die nichts sofort zustellen (Pruefungsanmeldung)
    func post(_ r: DueReminders.Reminder) async {}
}

/// Warum fuer einen Termin (k)eine Erinnerung kommt (Hinweis an der Stelle, wo der Termin steht)
enum DueReminderState: Equatable {
    /// eingeschaltet, Tarif und iOS erlauben es
    case on
    /// Schalter in den Einstellungen aus (Vorgabe)
    case off
    /// Tarif ohne Erinnerungen (ab Pro AI seit 18.11.2026)
    case locked
    /// eingeschaltet, aber iOS erlaubt StudiNow keine Mitteilungen
    case denied
}

/// UNUserNotificationCenter: Zeitpunkt als Kalendertermin in Berlin (wie alle Zeiten der App)
@MainActor
final class SystemDueNotifier: DueNotifying {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    static let thread = "de.uniflow.ai.due"

    func status() async -> DueNotificationStatus {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    private func content(_ r: DueReminders.Reminder) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = r.title
        c.body = r.body
        c.sound = .default
        c.threadIdentifier = Self.thread
        if let route = r.route { c.userInfo = ["route": route] }
        return c
    }

    func schedule(_ r: DueReminders.Reminder) async {
        var comps = Fmt.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireAt)
        comps.timeZone = Fmt.zone
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: r.identifier, content: content(r), trigger: trigger))
    }

    /// ohne Ausloeser: iOS stellt sofort zu
    func post(_ r: DueReminders.Reminder) async {
        try? await center.add(UNNotificationRequest(identifier: r.identifier, content: content(r), trigger: nil))
    }

    func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Plant die Erinnerungen des offenen Containers
@MainActor
final class DueReminderScheduler: ObservableObject {
    static let shared = DueReminderScheduler()
    /// Schalter "Erinnerungen an Abgaben und Prüfungen" (Geraet, fuer alle Container; Vorgabe aus)
    static let enabledKey = "uniflow.due.reminders"

    @Published private(set) var enabled: Bool
    /// Zahl der geplanten Erinnerungen (Einstellungen)
    @Published private(set) var scheduled = 0
    /// steigt, wenn sich erkannte Termine geaendert haben (Listen und Kalender laden neu)
    @Published private(set) var revision = 0
    /// Ziel einer angetippten Erinnerung (Hash-Route oder Adresse); die Oberflaeche oeffnet es und setzt nil
    @Published var pendingRoute: String?

    let notifier: DueNotifying
    /// jetzt (Tests: feste Zeit)
    var now: () -> Date = { Date() }
    /// Tarif erlaubt Erinnerungen und "Neuer Klausurtermin erkannt" (ab Pro AI seit 18.11.2026, vorher ab Plus,
    /// `UFFeature.dueReminders`; die Probe zaehlt wie Pro AI). Ohne:
    /// nichts geplant, schon geplante werden zurueckgenommen, der Schalter bleibt gemerkt (nach dem Kauf geht es weiter)
    var allowed: () -> Bool = { Entitlements.shared.allows(.dueReminders) }
    /// Texterkennung fuer Folien als Bild nur im Vordergrund (Vision rechnet im Hintergrund nicht verlaesslich) und
    /// nicht im Stromsparmodus (Tests: fester Wert)
    var ocrAllowed: () -> Bool = { !AppActivity.isInBackground() && !ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// Laeuft die App im Hintergrund? Dann nur wenige Dateien nachlesen (iOS gibt wenig Zeit)
    var inBackground: () -> Bool = { AppActivity.isInBackground() }
    /// Dateien je Aufruf und Aufrufe je Lauf beim Nachlesen der Seitentexte (Vordergrund / Hintergrund)
    static let backfillChunk = 20
    static let backfillRounds = (foreground: 25, background: 5)
    /// Seiten je Aufruf und je Lauf fuer die Texterkennung
    static let ocrChunk = 12
    static let ocrPagesPerRun = 48
    /// Mitteilungen "neu erkannt" dieses Prozesses (Tests)
    private(set) var announced: [DueReminders.Reminder] = []
    private let defaults: UserDefaults
    private weak var containers: ContainerManager?
    /// einmal angehaengt (`attach`); davor weiss ein Lauf nichts ueber den offenen Container und laesst alles, wie es ist
    private var attached = false
    private var bag = Set<AnyCancellable>()
    private var running: Task<Void, Never>?
    private var again = false
    private var wantsRecompute = false
    /// Container, fuer den zuletzt geplant wurde (Tests)
    private(set) var plannedContainer: String?

    init(notifier: DueNotifying? = nil, defaults: UserDefaults = .standard) {
        self.notifier = notifier ?? SystemDueNotifier()
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// An die Container haengen: Wechsel des Containers und Ende jedes Abgleichs erkennen und planen neu (ohne
    /// geaenderte Seitentexte, Dateien oder Ankuendigungen kostet das Erkennen kaum etwas, `DueStore.inputStamp`)
    func attach(_ containers: ContainerManager) {
        guard self.containers !== containers else { return }
        self.containers = containers
        attached = true
        bag.removeAll()
        // Tarif gewechselt (Kauf, Probe zu Ende, Abo abgelaufen): neu planen bzw. zuruecknehmen
        Entitlements.shared.$plan.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.schedule(recompute: false) }.store(in: &bag)
        containers.$active.removeDuplicates { $0 === $1 }
            .sink { [weak self] _ in self?.schedule(recompute: true) }.store(in: &bag)
        containers.$studip.map { $0.$finishedRuns.dropFirst() }.switchToLatest()
            .sink { [weak self] _ in self?.schedule(recompute: true) }.store(in: &bag)
        containers.$hildesheim
            .map { h in h.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() } ?? Empty<Int, Never>().eraseToAnyPublisher() }
            .switchToLatest()
            .sink { [weak self] _ in self?.schedule(recompute: true) }.store(in: &bag)
    }

    /// Neu planen, gebuendelt: laeuft schon ein Lauf, folgt genau einer danach
    func schedule(recompute: Bool) {
        wantsRecompute = wantsRecompute || recompute
        guard running == nil else { again = true; return }
        running = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.again = false
                let r = self.wantsRecompute
                self.wantsRecompute = false
                await self.refresh(recompute: r)
            } while self.again
            self.running = nil
        }
    }

    /// Auf einen laufenden Plan warten (Tests)
    func settle() async {
        while let t = running { await t.value }
    }

    /// Einmal planen: erkennen (nach einem Abgleich), Liste lesen, Erinnerungen ersetzen bzw. zuruecknehmen
    func refresh(recompute: Bool) async {
        // noch nie angehaengt (Start durch iOS im Hintergrund vor dem ersten Fenster): nichts anfassen. Vorher nahm ein
        // solcher Lauf alle geplanten Erinnerungen zurueck (17.11.2026)
        guard attached else { return }
        guard let c = containers?.active else {
            await withdrawAll()
            return
        }
        let api = c.api
        if recompute {
            // Dateien ohne Seitentexte (nie geoeffnet; PDF, PowerPoint, Word) nachlesen
            let rounds = inBackground() ? Self.backfillRounds.background : Self.backfillRounds.foreground
            var read = false
            for _ in 0..<rounds {
                guard containers?.active === c,
                      let b = try? await api.value("/api/due/backfill?limit=\(Self.backfillChunk)", method: "POST") else { break }
                if (b["read"]?.int ?? 0) > 0 { read = true }
                if (b["remaining"]?.int ?? 0) == 0 { break }
                await Task.yield()
            }
            if read { revision += 1 }
            if let r = try? await api.value("/api/due/refresh", method: "POST"), r["changed"]?.bool == true { revision += 1 }
        }
        guard await plan(c) else { return }
        // Folien als Bild: Texterkennung in Portionen; erst nach dem Planen, damit die Erinnerungen nicht darauf warten
        if recompute, await recognizeImagePages(c) {
            revision += 1
            _ = await plan(c)
        }
    }

    /// Liste lesen, neu erkannte Klausuren melden, Erinnerungen ersetzen bzw. zuruecknehmen. false: Fehler oder der
    /// Container hat inzwischen gewechselt (die geplanten bleiben, der naechste Lauf plant).
    private func plan(_ c: ActiveContainer) async -> Bool {
        let api = c.api
        guard let list = try? await api.value("/api/due") else { return false }
        if list["refreshed"]?.bool == true { revision += 1 }
        guard containers?.active === c else { return false }
        let items = DueReminders.items(from: list)
        let container = c.layout.identifier.uuidString
        let permitted = enabled && allowed() ? await notifier.status() == .allowed : false
        // neu erkannte Klausur- und Testtermine: einmal sofort melden (nur mit Schalter, Tarif und Erlaubnis), in jedem
        // Fall als entschieden merken, damit der naechste Abgleich nicht erneut meldet; die Uebersicht zeigt sie weiter
        let fresh = DueReminders.newItems(items)
        if !fresh.isEmpty {
            if permitted {
                for n in DueReminders.newNotices(items, container: container, now: now()) {
                    await notifier.post(n)
                    announced.append(n)
                }
            }
            _ = try? await api.value("/api/due/seen", method: "POST",
                                     body: ["ids": .array(fresh.map { .string($0.id) }), "notified": true])
            revision += 1
        }
        guard permitted else {
            await withdrawAll()
            return true
        }
        let plan = DueReminders.plan(items, container: container, now: now())
        let d = DueReminders.diff(pending: await notifier.pendingIdentifiers(), planned: plan)
        notifier.remove(d.remove)
        for r in d.add { await notifier.schedule(r) }
        scheduled = plan.count
        plannedContainer = container
        return true
    }

    /// Seiten ohne Textebene lesen (Vision, abseits des Hauptthreads im lokalen Backend), je Lauf hoechstens
    /// `ocrPagesPerRun`; true, wenn Seiten gelesen wurden
    private func recognizeImagePages(_ c: ActiveContainer) async -> Bool {
        var left = Self.ocrPagesPerRun
        var found = false
        while left > 0, ocrAllowed(), containers?.active === c {
            guard let r = try? await c.api.value("/api/due/ocr?pages=\(min(Self.ocrChunk, left))", method: "POST") else { break }
            let n = r["pages"]?.int ?? 0
            if n > 0 { found = true }
            left -= Self.ocrChunk
            if n == 0 || (r["remaining"]?.int ?? 0) == 0 { break }
            await Task.yield()
        }
        return found
    }

    /// Kommt fuer die Termine eine Erinnerung? (Hinweis der Uebersicht, fragt iOS nicht)
    func reminderState() async -> DueReminderState {
        guard allowed() else { return .locked }
        guard enabled else { return .off }
        return await notifier.status() == .allowed ? .on : .denied
    }

    /// Alle Erinnerungen an Abgaben und Pruefungen zuruecknehmen (aus, ohne Container, ohne Erlaubnis)
    func withdrawAll() async {
        notifier.remove((await notifier.pendingIdentifiers()).filter { $0.hasPrefix(DueReminders.prefix) })
        scheduled = 0
        plannedContainer = nil
    }

    /// Schalter in den Einstellungen. Einschalten fragt iOS (nur hier); abgelehnt: bleibt aus, Rueckgabe false
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            await withdrawAll()
            return true
        }
        guard allowed() else { return false }                                  // ab Pro AI: die Karte zeigt die Sperre
        let ok: Bool
        switch await notifier.status() {
        case .allowed: ok = true
        case .notDetermined: ok = await notifier.requestPermission()
        case .denied: ok = false
        }
        enabled = ok
        defaults.set(ok, forKey: Self.enabledKey)
        if ok { await refresh(recompute: false) }
        return ok
    }

    /// iOS erlaubt Mitteilungen nicht (Einstellungen zeigen den Hinweis)
    func isDenied() async -> Bool { await notifier.status() == .denied }
}

/// Antippen einer Erinnerung oeffnet die Quelle; im Vordergrund erscheint sie als Banner. Mitteilungen anderer Teile der
/// App behalten das Verhalten ohne Delegaten (im Vordergrund nicht gezeigt, Antippen oeffnet nur die App).
final class DueNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = DueNotificationDelegate()

    /// beim Start der App (vor dem ersten Antippen einer Erinnerung, auch beim Kaltstart)
    static func install() {
        if UNUserNotificationCenter.current().delegate == nil { UNUserNotificationCenter.current().delegate = shared }
    }

    /// Ziel aus einer Erinnerung (nur eigene Kennungen)
    static func route(identifier: String, userInfo: [AnyHashable: Any]) -> String? {
        guard isOwn(identifier), let r = userInfo["route"] as? String, !r.isEmpty else { return nil }
        return r
    }

    /// Erinnerungen an Abgaben/Pruefungen und an die Pruefungsanmeldung (`ExamRegistrationReminders`)
    static func isOwn(_ identifier: String) -> Bool {
        identifier.hasPrefix(DueReminders.prefix) || identifier.hasPrefix(ExamRegistrationReminders.prefix)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.isOwn(notification.request.identifier) ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let r = Self.route(identifier: response.notification.request.identifier, userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let r { DueReminderScheduler.shared.pendingRoute = r }
            completionHandler()
        }
    }
}

/// Haengt die Erinnerungen an die Oberflaeche: Container beobachten, angetippte Erinnerung oeffnen, beim Oeffnen der
/// App neu planen, nach neu erkannten Terminen die Seiten neu laden. Nicht unter XCTest (Tests bauen eigene).
struct DueReminderHost: ViewModifier {
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var router: UFRouter
    @ObservedObject private var scheduler = DueReminderScheduler.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !StudIPSync.isUnderTest() else { return }
                scheduler.attach(containers)
                ExamRegistrationReminderScheduler.shared.attach(containers)      // Meldezeitraum (05.11.2026)
                if let r = scheduler.pendingRoute { open(r) }
            }
            .onChange(of: scheduler.pendingRoute) { _, r in if let r { open(r) } }
            .onChange(of: scheduler.revision) { _, _ in router.reload() }
            .onChange(of: scenePhase) { _, p in
                // auch nach einem Abgleich im Hintergrund (S8): neue Seitentexte erkennen, Erinnerungen ersetzen
                if p == .active, !StudIPSync.isUnderTest() {
                    scheduler.schedule(recompute: true)
                    Task { await ExamRegistrationReminderScheduler.shared.refresh() }
                }
            }
    }

    private func open(_ r: String) {
        scheduler.pendingRoute = nil
        DueOpen.open(route: r, router: router, openURL: openURL)
    }
}

/// Quelle eines Termins oeffnen: PDF auf der Seite, sonst Ankuendigung bzw. Learnweb, sonst das Modul
enum DueOpen {
    /// Ziel als Hash-Route ("#/doc/<id>?page=2", "#/modules/3") oder http(s)-Adresse; nil ohne Ziel
    static func route(_ x: JSONValue) -> String? {
        if let f = x.s("file_id"), !f.isEmpty {
            let p = x.i("page") ?? 1
            return "#/doc/\(f)" + (p > 1 ? "?page=\(p)" : "")
        }
        if let u = x.s("url"), UFDayExtras.safeURL(u) != nil { return u }
        if let m = x.i("module_id") { return "#/modules/\(m)" }
        return nil
    }

    @MainActor
    static func open(_ x: JSONValue, router: UFRouter, openURL: OpenURLAction) {
        if let r = route(x) { open(route: r, router: router, openURL: openURL) }
    }

    @MainActor
    static func open(route r: String, router: UFRouter, openURL: OpenURLAction) {
        if r.hasPrefix("#") {
            router.go(hash: r)
        } else if let u = UFDayExtras.safeURL(r) {
            openURL(u)
        }
    }
}
