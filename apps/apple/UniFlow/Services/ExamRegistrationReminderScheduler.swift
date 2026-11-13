import Combine
import Foundation
import SwiftUI
import UniFlowCore

// Erinnerungen an den Meldezeitraum der Pruefungsanmeldung (docs/PRUEFUNGSANMELDUNG-2026-11-05.md): am ersten Tag,
// 7 und 2 Tage vor dem Ende um 9:00, nur mit sicher bekanntem Zeitraum (Plan im Kern: `ExamRegistrationReminders`).
// Eigener Schalter, Vorgabe an; geplant wird nur, wenn iOS Mitteilungen erlaubt. Die Erlaubnis fragt nur das
// Einschalten (Schalter in der Karte bzw. im Studienverlauf), nie der Start der App. Kennungen "de.uniflow.ai.examreg.*",
// unabhaengig von den Erinnerungen an Abgaben und Pruefungen (`DueReminderScheduler`).

@MainActor
final class ExamRegistrationReminderScheduler: ObservableObject {
    static let shared = ExamRegistrationReminderScheduler()
    /// Schalter "An die Prüfungsanmeldung erinnern" (Geraet, alle Container; ohne Eintrag: an)
    static let enabledKey = "uniflow.examreg.reminders"

    @Published private(set) var enabled: Bool
    /// geplante Erinnerungen (Anzeige, Tests)
    @Published private(set) var scheduled = 0
    /// iOS hat Mitteilungen abgelehnt (Hinweis unter dem Schalter)
    @Published private(set) var denied = false

    let notifier: DueNotifying
    var now: () -> Date = { Date() }
    private let defaults: UserDefaults
    private weak var containers: ContainerManager?
    private var bag = Set<AnyCancellable>()

    init(notifier: DueNotifying? = nil, defaults: UserDefaults = .standard) {
        self.notifier = notifier ?? SystemDueNotifier()
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Wechsel des Containers und jeder QIS-Abruf planen neu
    func attach(_ containers: ContainerManager) {
        guard self.containers !== containers else { return }
        self.containers = containers
        bag.removeAll()
        containers.$active.removeDuplicates { $0 === $1 }
            .sink { [weak self] _ in Task { await self?.refresh() } }.store(in: &bag)
        containers.$qis
            .map { q in q.map { $0.$finishedRuns.dropFirst().eraseToAnyPublisher() } ?? Empty<Int, Never>().eraseToAnyPublisher() }
            .switchToLatest()
            .sink { [weak self] _ in Task { await self?.refresh() } }.store(in: &bag)
    }

    /// Mit dem offenen Container planen (ohne Container: alle zuruecknehmen)
    func refresh() async {
        guard let c = containers?.active else { await withdrawAll(); return }
        await refresh(api: c.api, container: c.layout.identifier.uuidString)
    }

    /// Antwort von GET /api/exam-registration lesen und Erinnerungen ersetzen; Fehler: die geplanten bleiben
    func refresh(api: APIClient?, container: String) async {
        guard let api, let v = try? await api.value("/api/exam-registration") else { return }
        await apply(v, container: container)
    }

    func apply(_ response: JSONValue, container: String) async {
        let status = await notifier.status()
        denied = status == .denied
        guard enabled, status == .allowed else { await withdrawAll(); return }
        let plan = ExamRegistrationReminders.plan(response, container: container, now: now())
        let d = ExamRegistrationReminders.diff(pending: await notifier.pendingIdentifiers(), planned: plan)
        notifier.remove(d.remove)
        for r in d.add { await notifier.schedule(r) }
        scheduled = plan.count
    }

    func withdrawAll() async {
        notifier.remove((await notifier.pendingIdentifiers()).filter { $0.hasPrefix(ExamRegistrationReminders.prefix) })
        scheduled = 0
    }

    /// Schalter. Einschalten fragt iOS (nur hier); abgelehnt: bleibt aus, Rueckgabe false
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
        denied = !ok
        defaults.set(ok, forKey: Self.enabledKey)
        if ok { await refresh() }
        return ok
    }

    /// Schalter zeigt "an", wenn er an ist und iOS es erlaubt (noch nicht gefragt: aus, Einschalten fragt)
    func isEffectivelyOn() async -> Bool {
        guard enabled else { return false }
        return await notifier.status() == .allowed
    }
}

/// Schalter "An die Prüfungsanmeldung erinnern" (Karte, Studienverlauf): Ein fragt iOS um Erlaubnis
struct ExamRegistrationReminderToggle: View {
    @ObservedObject var scheduler: ExamRegistrationReminderScheduler = .shared
    @State private var on = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { on }, set: { v in
                on = v
                Task { on = await scheduler.setEnabled(v) && v }
            })) {
                Text("An die Prüfungsanmeldung erinnern").ufFont(13.12, 600).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .accessibilityIdentifier("examreg.reminders")
            Text(scheduler.denied ? "Mitteilungen sind für StudiNow ausgeschaltet (\(UFDevice.textName)-Einstellungen → StudiNow → Mitteilungen)."
                                  : "Am ersten Tag, 7 und 2 Tage vor dem Ende um 9:00 Uhr.")
                .ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            guard !loaded else { return }
            loaded = true
            on = await scheduler.isEffectivelyOn()
        }
    }
}
