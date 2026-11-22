import SwiftUI
import UniFlowCore

/// Gekaufte Probeklausuren von selbst abholen (22.11.2026). Anlass: Der Inhaber hatte am iPad eine Probeklausur gekauft,
/// der Dienst hatte sie nach 50 Sekunden fertig und abgerechnet, aber sie kam nie auf das Geraet. Abgeholt hat bis
/// dahin nur das offene Kauf-Blatt (`ExamGeneratorBuy`); danach nur, wer dieselben Dateien noch einmal auswaehlte.
///
/// Jetzt fragt die App selbst nach (`POST /api/exam-generator/collect`, im Kern `ExamGeneratorShop.collectAll`): beim
/// Start, bei anderer Datenquelle und beim Wechsel in den Vordergrund, hoechstens alle `minInterval` Sekunden. Erstellt
/// der Dienst noch etwas, schaut sie alle `watchEvery` Sekunden nach, hoechstens `watchLimit` lang. Neu Abgelegtes
/// meldet ein Hinweis mit Modul und Ordner; die Seiten laden neu, damit der Ordner „Probeklausuren“ sofort da ist.
///
/// Sparsam: nur mit Pro AI (sonst gibt es nichts abzuholen) und nie zwei Abfragen zugleich. Fehler bleiben still, der
/// naechste Anlass versucht es wieder. Unter XCTest fragt nichts, ausser ein Test setzt `collectOverride`.
@MainActor
final class ExamShopInbox {
    static let shared = ExamShopInbox()
    static let minInterval: TimeInterval = 60
    static let watchEvery: TimeInterval = 10
    static let watchLimit: TimeInterval = 30 * 60

    /// Eine neu abgelegte PDF
    struct Added: Equatable {
        var variant: Int
        var module: String
    }

    struct Outcome: Equatable {
        var added: [Added] = []
        var pending = 0

        init(added: [Added] = [], pending: Int = 0) { self.added = added; self.pending = pending }

        init(_ v: JSONValue) {
            added = v.list("added").map { Added(variant: $0.i("variant") ?? 0, module: $0.s("module") ?? "") }
            pending = v.i("pending") ?? 0
        }
    }

    private(set) weak var router: UFRouter?
    private(set) weak var toast: UFToastCenter?
    private var api: APIClient?
    /// Tests: Antwort statt des Geraete-Dienstes, Uhr, Pause und Tarifpruefung
    var collectOverride: (() async -> Outcome?)?
    var now: () -> Date = Date.init
    var pause: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var allowed: () -> Bool = { ExamGenerator.isEnabled && UFLock.plan(.aiHelp, plan: Entitlements.shared.plan) == nil }

    private var lastRefresh: Date?
    private var running: Task<Outcome?, Never>?
    private(set) var watching: Task<Void, Never>?

    /// Fenster verbinden (MainView, je Datenquelle neu) und einmal nachsehen
    func attach(router: UFRouter, toast: UFToastCenter, api: APIClient?) {
        if self.api?.base != api?.base {                                  // andere Datenquelle: altes Nachsehen endet
            watching?.cancel()
            watching = nil
            lastRefresh = nil
        }
        self.router = router
        self.toast = toast
        self.api = api
        refreshSoon()
    }

    func refreshSoon(force: Bool = false) { Task { await refresh(force: force) } }

    /// Einmal abholen. Liefert, was dazukam und was der Dienst noch erstellt; nil = nicht gefragt oder Fehler.
    @discardableResult
    func refresh(force: Bool = false) async -> Outcome? {
        if StudIPSync.isUnderTest(), collectOverride == nil { return nil }
        guard allowed() else { return nil }
        if let running { return await running.value }
        if !force, let last = lastRefresh, now().timeIntervalSince(last) < Self.minInterval { return nil }
        lastRefresh = now()
        let api = self.api, override = collectOverride
        let task = Task { () -> Outcome? in
            if let override { return await override() }
            guard let api, let v = try? await api.value("/api/exam-generator/collect", method: "POST", body: .object([:])) else { return nil }
            return Outcome(v)
        }
        running = task
        let out = await task.value
        if running == task { running = nil }
        if let out {
            if let text = Self.notice(out.added) {
                toast?.show(text, seconds: 6)
                router?.reload()
            }
            if out.pending > 0 { watch() }
        }
        return out
    }

    /// Solange der Dienst noch erstellt: alle `watchEvery` Sekunden nachsehen (nie zwei Schleifen, hoechstens `watchLimit`)
    func watch() {
        guard watching == nil else { return }
        let started = now()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pause(Self.watchEvery)
                if Task.isCancelled { return }
                // ohne Antwort (kein Netz) weiter versuchen, bis die Zeit um ist
                if let out = await self.refresh(force: true), out.pending == 0 { break }
                if self.now().timeIntervalSince(started) > Self.watchLimit { break }
            }
            self?.watching = nil
        }
    }

    /// Hinweis nach dem Ablegen: "Probeklausur 1 ist da: Bibliothek, Modul „Analysis“, Ordner „Probeklausuren“."
    nonisolated static func notice(_ added: [Added]) -> String? {
        guard !added.isEmpty else { return nil }
        let modules = Set(added.map(\.module).filter { !$0.isEmpty })
        // Aufgaben und Lösungen zaehlen als eine Probeklausur
        let exams = Set(added.map { "\($0.module)|\($0.variant)" }).count
        let what = exams == 1 ? "Probeklausur \(added[0].variant) ist da" : "\(exams) Probeklausuren sind da"
        let folder = "Ordner „\(ExamGenerator.folderName)“"
        if modules.count == 1, let m = modules.first { return "\(what): Bibliothek, Modul „\(m)“, \(folder)." }
        return "\(what): Bibliothek, \(folder) im jeweiligen Modul."
    }
}

/// Haengt das Abholen an den Rahmen (MainView): beim Erscheinen, bei anderer Datenquelle und im Vordergrund
struct ExamShopInboxHost: ViewModifier {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { ExamShopInbox.shared.attach(router: router, toast: toast, api: session.api) }
            .onChange(of: session.api?.base) { _, _ in ExamShopInbox.shared.attach(router: router, toast: toast, api: session.api) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { ExamShopInbox.shared.refreshSoon() } }
    }
}
