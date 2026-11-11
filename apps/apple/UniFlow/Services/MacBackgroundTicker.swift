import Foundation

// Abgleich am Mac (Version 1.3/1.4, docs/BENACHRICHTIGUNGEN-1-3.md): StudiNow laeuft dort als "Designed for iPad".
// Ob macOS die Hintergrundaufgaben von iOS (BGTaskScheduler) startet, ist ungewiss. Darum gleicht die App am Mac,
// solange sie laeuft (auch wenn sie nicht vorn ist), alle 20 bis 30 Minuten selbst ab: derselbe kurze Lauf wie der von
// iOS gestartete (`BackgroundSyncController.performIfDue`), mit denselben Schaltern und Mitteilungen. War eben schon ein
// Lauf (z. B. doch von iOS), faellt der Takt aus. App Nap koennte den Takt sonst stark verzoegern; die App meldet dem
// System deshalb eine laufende Aufgabe an, die den Ruhezustand des Macs erlaubt.

@MainActor
final class MacBackgroundTicker {
    /// "Designed for iPad" auf einem Mac
    static var isMac: Bool { ProcessInfo.processInfo.isiOSAppOnMac }
    static let minDelay: TimeInterval = 20 * 60
    static let maxDelay: TimeInterval = 30 * 60
    /// so lange nach dem letzten Lauf faellt ein Takt aus
    static let minGap: TimeInterval = 15 * 60

    /// Wartezeit bis zum naechsten Takt (zufaellig zwischen 20 und 30 Minuten, damit nicht alle Geraete zugleich fragen)
    static func delay(random: Double) -> TimeInterval { minDelay + (maxDelay - minDelay) * min(max(random, 0), 1) }

    static func due(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= minGap
    }

    private let tick: @MainActor () async -> Void
    /// Zufall 0...1 (Tests: fest)
    var random: () -> Double = { Double.random(in: 0...1) }
    /// Warten; false, wenn abgebrochen (Tests: sofort)
    var sleep: (TimeInterval) async -> Bool = { s in (try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))) != nil }
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    init(tick: @escaping @MainActor () async -> Void) { self.tick = tick }

    var isActive: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        if Self.isMac {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "StudiNow gleicht alle 20 bis 30 Minuten mit der Hochschule ab")
        }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.sleep, delay = Self.delay(random: self.random())
                guard await wait(delay), !Task.isCancelled else { return }
                guard self.task != nil else { return }               // inzwischen angehalten
                await self.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
