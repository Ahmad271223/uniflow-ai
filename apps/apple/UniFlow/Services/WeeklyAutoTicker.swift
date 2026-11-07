import Foundation
import os
import UniFlowCore

/// Automatische Wochentests ohne Dienst (Takt im Vordergrund, nach dem vollen Abgleich, im langen Hintergrundlauf):
/// ab Pro AI wie "Wochentest erstellen" (`UFFeature.weeklyTests`, 07.11.2026; braucht die StudiNow-KI). Free und Plus
/// (auch nach der Probe) erzeugen und uebernehmen keine neuen Wochentests; vorhandene Tests bleiben les- und durchfuehrbar. Der Kern
/// (`WeeklyAutoTick`) kennt keinen Tarif, darum prueft die App vor jedem Lauf. Tests setzen `allowed`.
enum UFWeeklyAutoGate {
    @MainActor static var allowed: () -> Bool = { Entitlements.shared.allows(.weeklyTests) }

    /// aus nicht isoliertem Code (Abgleich, Hintergrundlauf)
    nonisolated static func check() async -> Bool { await MainActor.run { allowed() } }
}

/// Takt der gemeinsamen Wochentests auf dem iPad (am PC `_weekly_loop` in app/server.py): kurz nach dem Oeffnen der
/// App, danach alle 10 min, solange sie im Vordergrund ist. Die Regeln (nur mit `auto_tests`, nur mit verbundener
/// KI, nicht neben einem anderen Hintergrundauftrag) stehen in `WeeklyAutoTick`. Hat ein Lauf etwas veroeffentlicht,
/// laden offene Wochentest-Boxen neu.
@MainActor
final class WeeklyAutoTicker {
    static let log = Logger(subsystem: "de.uniflow.ai", category: "weekly-tick")
    /// Wartezeit nach dem Oeffnen (der Start der App und der Stud.IP-Abgleich gehen vor)
    static let firstDelay: UInt64 = 20_000_000_000

    private var loop: Task<Void, Never>?
    private let backend: () async -> LocalBackend?

    init(backend: @escaping () async -> LocalBackend? = { try? await LocalBackendHost.shared.backend() }) {
        self.backend = backend
    }

    var isRunning: Bool { loop != nil }

    func resume() {
        guard loop == nil, !StudIPSync.isUnderTest() else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.firstDelay)
            while !Task.isCancelled {
                _ = await self?.runOnce()
                try? await Task.sleep(nanoseconds: UInt64(WeeklyAutoTick.interval * 1_000_000_000))
            }
        }
    }

    func pause() {
        loop?.cancel()
        loop = nil
    }

    /// Ein Lauf; nil ohne lokales Backend (keine Hochschule gewaehlt)
    @discardableResult
    func runOnce() async -> WeeklyAutoTick.Outcome? {
        guard let b = await backend() else { return nil }
        guard UFWeeklyAutoGate.allowed() else { return .off }       // Free: keine automatischen Wochentests
        let r = await WeeklyAutoTick.run(b.context)
        switch r {
        case .ran(let text, let changed):
            Self.log.info("Wochentest-Takt: \(text, privacy: .public)")
            if changed { NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil) }
        case .failed(let message):
            Self.log.error("Wochentest-Takt: \(message, privacy: .public)")
        case .off, .noAI, .busy, .cancelled:
            break
        }
        return r
    }
}
