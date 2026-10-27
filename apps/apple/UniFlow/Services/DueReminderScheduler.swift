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

/// Was iOS zu Mitteilungen sagt
enum DueNotificationStatus: Equatable { case allowed, denied, notDetermined }

/// Lokale Mitteilungen (Tests: Mitschreiber)
@MainActor
protocol DueNotifying: AnyObject {
    func status() async -> DueNotificationStatus
    func requestPermission() async -> Bool
    func pendingIdentifiers() async -> [String]
    func schedule(_ r: DueReminders.Reminder) async
    func remove(_ identifiers: [String])
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

    func schedule(_ r: DueReminders.Reminder) async {
        let c = UNMutableNotificationContent()
        c.title = r.title
        c.body = r.body
        c.sound = .default
        c.threadIdentifier = Self.thread
        if let route = r.route { c.userInfo = ["route": route] }
        var comps = Fmt.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireAt)
        comps.timeZone = Fmt.zone
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: r.identifier, content: c, trigger: trigger))
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
    private let defaults: UserDefaults
    private weak var containers: ContainerManager?
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
        bag.removeAll()
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
        guard let c = containers?.active else {
            await withdrawAll()
            return
        }
        let api = c.api
        if recompute {
            // PDFs ohne Seitentexte (vor S7 geladen, nie geoeffnet) nachlesen, je Lauf hoechstens 5 x 20
            for _ in 0..<5 {
                guard containers?.active === c, let b = try? await api.value("/api/due/backfill?limit=20", method: "POST") else { break }
                if (b["read"]?.int ?? 0) > 0 { revision += 1 }
                if (b["remaining"]?.int ?? 0) == 0 { break }
            }
            if let r = try? await api.value("/api/due/refresh", method: "POST"), r["changed"]?.bool == true { revision += 1 }
        }
        guard let list = try? await api.value("/api/due") else { return }       // Fehler: die geplanten bleiben
        if list["refreshed"]?.bool == true { revision += 1 }
        guard containers?.active === c else { return }                          // inzwischen gewechselt: der naechste Lauf plant
        guard enabled, await notifier.status() == .allowed else {
            await withdrawAll()
            return
        }
        let container = c.layout.identifier.uuidString
        let plan = DueReminders.plan(DueReminders.items(from: list), container: container, now: now())
        let d = DueReminders.diff(pending: await notifier.pendingIdentifiers(), planned: plan)
        notifier.remove(d.remove)
        for r in d.add { await notifier.schedule(r) }
        scheduled = plan.count
        plannedContainer = container
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
        guard identifier.hasPrefix(DueReminders.prefix), let r = userInfo["route"] as? String, !r.isEmpty else { return nil }
        return r
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(DueReminders.prefix) ? [.banner, .list, .sound] : [])
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
                if let r = scheduler.pendingRoute { open(r) }
            }
            .onChange(of: scheduler.pendingRoute) { _, r in if let r { open(r) } }
            .onChange(of: scheduler.revision) { _, _ in router.reload() }
            .onChange(of: scenePhase) { _, p in
                // auch nach einem Abgleich im Hintergrund (S8): neue Seitentexte erkennen, Erinnerungen ersetzen
                if p == .active, !StudIPSync.isUnderTest() { scheduler.schedule(recompute: true) }
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
