import Combine
import SwiftUI
import UniFlowCore

/// Abzeichen am Menuepunkt "Community" (03.11.2026, Wunsch des Inhabers): Zahl der offenen, noch nicht geoeffneten
/// Korrekturhinweise an eigene Loesungen (`CommunityCorrections.openInbox`: an mich, nicht von mir, nicht ignoriert,
/// nicht gesehen). Oeffnen macht einen Hinweis "gesehen", Ignorieren legt ihn weg; beides nimmt ihn sofort aus der
/// Zahl (`resolve`), ohne den Dienst zu fragen.
///
/// Sparsam: keine Schleife, je Auffrischen hoechstens eine Abfrage beim Dienst (`correctionsForMyOwnSolutions`), und
/// die nur beim Verbinden (Start, anderer Container), beim Wechsel in den Vordergrund und nach einem Abgleich,
/// hoechstens alle `minInterval` Sekunden (`CommunityBadgeHost`). Laedt die Community-Seite ihren Posteingang, gibt sie
/// die Liste mit (`apply`), eine zweite Abfrage entfaellt. Die letzte Zahl steht in den Einstellungen des Containers
/// (`cacheKey`), damit das Abzeichen beim naechsten Start sofort da ist. Unter XCTest fragt nichts beim Dienst, ausser
/// ein Test setzt `serviceOverride`.
///
/// Andere Bereiche setzen ihr Abzeichen direkt ueber `UFRouter.setBadge(_:for:)` (Schluessel = `UFRoute.navKey`).
@MainActor
final class CommunityBadge {
    static let shared = CommunityBadge()
    static let navKey = "community"
    /// zuletzt bekannte Zahl in den Einstellungen des Containers
    static let cacheKey = "uniflow.community.corrections.badge"
    /// zwischen zwei Abfragen beim Dienst mindestens so lange (Vordergrund und Abgleich-Ende kommen oft kurz nacheinander)
    static let minInterval: TimeInterval = 60

    private(set) weak var router: UFRouter?
    /// Tests: Dienst und Einstellungen statt des aktiven Containers
    var serviceOverride: CommunityService?
    var defaultsOverride: UserDefaults?
    /// Uhr (Tests)
    var now: () -> Date = Date.init

    private(set) var count = 0
    /// IDs der offenen Hinweise seit der letzten Liste; nil = nur die gespeicherte Zahl bekannt
    private(set) var openIDs: Set<String>?
    private var lastRefresh: Date?
    private var running: Task<Void, Never>?

    private var service: CommunityService { serviceOverride ?? SolutionSharing.community }
    private var defaults: UserDefaults? { defaultsOverride ?? ActiveContainer.current?.defaults }

    /// Router verbinden (MainView, je Container neu): die zuletzt gespeicherte Zahl sofort zeigen, dann einmal beim
    /// Dienst nachsehen
    func attach(_ router: UFRouter) {
        self.router = router
        openIDs = nil
        lastRefresh = nil
        publish(defaults?.integer(forKey: Self.cacheKey) ?? 0)
        refreshSoon(force: true)
    }

    /// Zahl aus einer schon geladenen Liste des Posteingangs (keine zweite Abfrage)
    func apply(_ corrections: [CommunityCorrection]) {
        let open = CommunityCorrections.openInbox(corrections)
        openIDs = Set(open.map { $0.id.lowercased() })
        lastRefresh = now()
        publish(open.count)
    }

    /// Hinweis geoeffnet oder ignoriert: sofort aus der Zahl (ist nur die gespeicherte Zahl bekannt, eins weniger)
    func resolve(_ id: String) {
        let key = id.lowercased()
        if var ids = openIDs {
            guard ids.remove(key) != nil else { return }
            openIDs = ids
            publish(ids.count)
        } else {
            publish(count - 1)
        }
    }

    func refreshSoon(force: Bool = false) { Task { await refresh(force: force) } }

    /// Eine Abfrage beim Dienst: nie zwei zugleich, ohne `force` hoechstens alle `minInterval` Sekunden; ohne Netz
    /// bleibt die letzte Zahl stehen. Unter XCTest nur mit eingesetztem Dienst.
    func refresh(force: Bool = false) async {
        if StudIPSync.isUnderTest(), serviceOverride == nil { return }
        if let running { await running.value; return }
        if !force, let last = lastRefresh, now().timeIntervalSince(last) < Self.minInterval { return }
        let service = self.service
        guard service.supportsCorrections else { publish(0); return }
        let task = Task { [weak self] in
            guard let all = try? await service.correctionsForMyOwnSolutions() else { return }
            self?.apply(all)
        }
        running = task
        await task.value
        if running == task { running = nil }
    }

    private func publish(_ n: Int) {
        count = max(0, n)
        router?.setBadge(count, for: Self.navKey)
        defaults?.set(count, forKey: Self.cacheKey)
    }
}

/// Haengt das Community-Abzeichen an den Rahmen (MainView): verbinden beim Erscheinen und bei anderer Datenquelle,
/// auffrischen beim Wechsel in den Vordergrund und nach einem Abgleich (Stud.IP bzw. Learnweb/LSF)
struct CommunityBadgeHost: ViewModifier {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { CommunityBadge.shared.attach(router) }
            .onChange(of: session.api?.base) { _, _ in CommunityBadge.shared.attach(router) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { CommunityBadge.shared.refreshSoon() } }
            .onChange(of: studip.finishedRuns) { _, _ in CommunityBadge.shared.refreshSoon() }
            .onReceive(hildesheimRuns) { _ in CommunityBadge.shared.refreshSoon() }
    }

    private var hildesheimRuns: AnyPublisher<Int, Never> {
        hildesheim.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()
    }
}
