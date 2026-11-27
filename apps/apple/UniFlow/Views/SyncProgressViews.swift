import SwiftUI
import UIKit
import UniFlowCore

// Erster Abgleich nach dem Verbinden (Auftrag des Inhabers 15.11.2026, docs/ERST-ABGLEICH-2026-11-15.md): eine ruhige
// Anzeige, solange Dateien geladen werden - dasselbe Bild an der LUH (Stud.IP) und an der Uni Hildesheim (Learnweb).
// Sie steht nur waehrend eines Laufs bzw. solange ein unterbrochener Lauf noch fortgesetzt wird; danach verschwindet
// sie. Die Dauerleiste "Learnweb ok · LSF ok" (14.11.2026 vom Inhaber abgelehnt) kommt damit nicht zurueck.

/// Hintergrundzeit von iOS fuer einen laufenden Abgleich: wechselt die App in den Hintergrund oder wird das Geraet
/// gesperrt, darf der Abgleich noch kurz weiterlaufen (`beginBackgroundTask`, in der Regel rund 30 Sekunden). Ist die
/// Zeit um, ruft iOS `expired`: der Abgleich endet sauber als abgebrochen und setzt beim Zurueckkommen fort.
@MainActor
struct UFBackgroundTime {
    @MainActor
    final class Handle {
        fileprivate var id = UIBackgroundTaskIdentifier.invalid
        private let finish: (UIBackgroundTaskIdentifier) -> Void
        init(finish: @escaping (UIBackgroundTaskIdentifier) -> Void) { self.finish = finish }
        /// Zeit zurueckgeben (auch mehrfach aufrufbar)
        func end() {
            guard id != .invalid else { return }
            finish(id)
            id = .invalid
        }
    }

    /// Name fuer iOS, `expired` (Hauptfaden): die Zeit ist um
    let begin: (String, @escaping @MainActor () -> Void) -> Handle

    static let system = UFBackgroundTime { name, expired in
        let handle = Handle { UIApplication.shared.endBackgroundTask($0) }
        handle.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // iOS ruft den Ablauf auf dem Hauptfaden
            MainActor.assumeIsolated {
                expired()
                handle.end()
            }
        }
        return handle
    }
}

/// "Deine Kurse werden geladen: 121 von 250 Dateien" mit dem Kurs, der gerade dran ist, und einem Balken
struct UFSyncProgressBar: View {
    enum Content: Equatable {
        case running(SyncProgress)
        /// ein Lauf wurde unterbrochen und wird gleich fortgesetzt
        case interrupted
        /// unterbrochen, aber ausserhalb von 8 bis 18 Uhr: von selbst geht es erst am Morgen weiter, jetzt nur mit "Sync"
        /// (27.11.2026, Inhaber: "lädt gleich weiter" stand abends wie eine Dauerschleife)
        case waiting

        /// Unterbrochener Lauf zu dieser Uhrzeit: im Fenster des Abgleichs von selbst `interrupted`, sonst `waiting`
        static func resumed(at now: Date, schedule: AutoSyncSchedule, timeZone: TimeZone) -> Content {
            schedule.isInWindow(now, timeZone: timeZone) ? .interrupted : .waiting
        }

        var title: String {
            switch self {
            case .running(let p): return p.title
            case .interrupted, .waiting: return "Deine Kurse sind noch nicht vollständig geladen"
            }
        }

        var detail: String? {
            switch self {
            case .running(let p): return p.detail
            case .interrupted: return "StudiNow lädt gleich weiter."
            case .waiting: return "Tippe auf „Sync“, dann lädt StudiNow weiter. Von selbst geht es ab 8 Uhr weiter."
            }
        }

        var fraction: Double? {
            if case .running(let p) = self { return p.fraction }
            return nil
        }
    }

    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        if content == .interrupted {
            // jede Minute neu: um 18 Uhr wird aus "gleich" der Hinweis auf "Sync", um 8 Uhr wieder "gleich"
            TimelineView(.periodic(from: .now, by: 60)) { context in
                bar(.resumed(at: context.date, schedule: AutoSync.schedule, timeZone: AutoSync.timeZone()))
            }
        } else {
            bar(content)
        }
    }

    private func bar(_ content: Content) -> some View {
        UFCard(flat: true) {
            HStack(alignment: .center, spacing: 12) {
                if content == .waiting {
                    UFIcon("clock", size: 18).foregroundStyle(UF.muted)
                } else {
                    ProgressView().tint(UF.accent)
                }
                VStack(alignment: .leading, spacing: 4.8) {
                    Text(content.title)
                        .ufFont(14.5, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .monospacedDigit()
                        .accessibilityIdentifier("sync.progress.title")
                    if let detail = content.detail {
                        Text(detail).ufFont(13.12).foregroundStyle(UF.muted)
                            .lineLimit(content == .waiting ? nil : 1).truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: content == .waiting)
                            .accessibilityIdentifier("sync.progress.detail")
                    }
                    if let fraction = content.fraction {
                        ProgressView(value: fraction).tint(UF.accent)
                            .animation(UFMotion.animation(reduce: reduce), value: fraction)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync.progress")
    }
}

/// Was fuer die Module noch aussteht (aus der Datenbank des offenen Containers, `SyncPending`), solange ein Abgleich
/// laeuft oder unterbrochen ist. Liest neu, wenn der Abgleich vorankommt oder endet.
@MainActor
final class SyncPendingModel: ObservableObject {
    @Published private(set) var overview = SyncPending.Overview()
    /// laeuft gerade ein Abgleich oder wird einer fortgesetzt (sonst zeigt niemand "wird noch geladen")
    @Published private(set) var active = false

    func refresh(active: Bool, host: LocalBackendHost?) async {
        self.active = active
        guard active, let host, let db = try? await host.backend().context.database else {
            overview = SyncPending.Overview()
            return
        }
        overview = (try? await db.withConnection { try SyncPending.overview($0) }) ?? SyncPending.Overview()
    }

    /// Hinweis fuer ein Modul; nil, wenn nichts (mehr) aussteht oder kein Abgleich laeuft
    func hint(moduleID: Int) -> String? {
        guard active else { return nil }
        let m = overview.module(moduleID)
        return SyncPending.hint(unlisted: m.unlisted, waiting: m.waiting)
    }
}

/// Zeile im Modul, solange seine Dateien noch geladen werden: "Dateien werden noch geladen …" bzw. "5 Dateien werden
/// noch geladen …". `empty`: das Modul hat noch gar keine Dokumente (dann als leerer Zustand statt "Noch keine Dokumente").
struct ModulePendingHint: View {
    let moduleID: Int
    let empty: Bool
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var containers: ContainerManager
    @Environment(\.hildesheim) private var hildesheim
    @StateObject private var model = SyncPendingModel()

    /// Text des leeren Zustands ohne laufenden Abgleich
    static let emptyText = "Noch keine Dokumente in diesem Modul. Nach dem nächsten Abgleich stehen sie hier nach Lehrwoche."

    var body: some View {
        // ohne die Hildesheimer Verbindung im Baum beobachtet nur Stud.IP; mit ihr auch ihr Fortschritt
        if let hildesheim {
            Watch(moduleID: moduleID, empty: empty, model: model, hildesheim: hildesheim)
        } else {
            row(active: studip.isRunning || studip.interrupted, key: "\(studip.progress?.coursesDone ?? -1)-\(studip.progress?.filesDone ?? -1)-\(studip.finishedRuns)")
        }
    }

    private struct Watch: View {
        let moduleID: Int
        let empty: Bool
        @ObservedObject var model: SyncPendingModel
        @ObservedObject var hildesheim: HildesheimConnection
        @EnvironmentObject private var containers: ContainerManager

        var body: some View {
            Row(moduleID: moduleID, empty: empty, model: model, active: hildesheim.isRunning || hildesheim.interrupted,
                key: "\(hildesheim.progress?.coursesDone ?? -1)-\(hildesheim.progress?.filesDone ?? -1)-\(hildesheim.finishedRuns)",
                host: containers.active?.host)
        }
    }

    private func row(active: Bool, key: String) -> some View {
        Row(moduleID: moduleID, empty: empty, model: model, active: active, key: key, host: containers.active?.host)
    }

    private struct Row: View {
        let moduleID: Int
        let empty: Bool
        @ObservedObject var model: SyncPendingModel
        let active: Bool
        let key: String
        let host: LocalBackendHost?

        var body: some View {
            Group {
                if let hint = model.hint(moduleID: moduleID) {
                    ModulePendingRow(text: hint, empty: empty).padding(.bottom, empty ? 0 : 9.6)
                } else if empty {
                    UFCard { UFEmpty(icon: "file", text: ModulePendingHint.emptyText, small: true) }
                }
            }
            .task(id: "\(active)-\(key)") { await model.refresh(active: active, host: host) }
        }
    }
}

/// Darstellung des Hinweises (ohne Datenbank, fuer Ansichtstests und Bilder)
struct ModulePendingRow: View {
    let text: String
    let empty: Bool

    var body: some View {
        UFCard(flat: !empty) {
            HStack(spacing: 9.6) {
                ProgressView().tint(UF.accent).controlSize(.small)
                VStack(alignment: .leading, spacing: 2.4) {
                    Text(text).ufFont(14, 600).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    if empty {
                        Text("Sie erscheinen hier von selbst. Du musst nichts tun.")
                            .ufFont(13.12).foregroundStyle(UF.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("module.pending")
    }
}
