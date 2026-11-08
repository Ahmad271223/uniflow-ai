import Combine
import Foundation
import Network
import SwiftUI
import UniFlowCore

/// Stufe (d) des Abgleichs auf dem iPad (`SyncOrder`, Wunsch des Inhabers 05.11.2026): fruehere Semester im
/// Hintergrund, nachdem das aktuelle Semester samt Stundenplan da ist. Neuestes Semester zuerst, je Lauf ein Semester
/// (Stud.IP) mit Pause dazwischen, fortsetzbar (`OlderSemesters.markLoaded` je Kurs), nie neben einem vollen Abgleich.
/// Bedingungen (`OlderLoadPolicy`): "Ältere Semester laden: Automatisch / Nur WLAN / Aus", Stromsparmodus pausiert,
/// "Nur WLAN" wartet auf ein nicht teures Netz (`NWPath.isExpensive`: Mobilfunk, persoenlicher Hotspot). Im
/// Hintergrund laeuft sie nur im langen Lauf (`BackgroundSyncController`, BGProcessingTask) und nur, solange iOS Zeit
/// gibt. Der Stand steht in `sync_stage_state` (Hinweis "(3 von 6)" auf der Seite Module).
@MainActor
final class OlderSemesterLoader {
    static let shared = OlderSemesterLoader()

    /// Pause zwischen zwei Semestern (drosseln: Portal, Akku, Leitung)
    var pauseNanos: UInt64 = 2_000_000_000
    var lowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    private(set) var isLoading = false
    /// letzter bekannter Netzweg teuer (Mobilfunk, Hotspot) oder kein Netz
    private var expensive = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let costly = path.isExpensive || path.status != .satisfied
            Task { @MainActor in self?.expensive = costly }
        }
        monitor.start(queue: DispatchQueue(label: "de.uniflow.older-semesters.path"))
    }

    /// WLAN (oder ein anderes nicht teures Netz) vorhanden
    var onWiFi: Bool { !expensive }

    /// Nach einem vollen Abgleich, einer geaenderten Wahl oder dem Ende des Stromsparmodus: Stufe (d) starten, wenn
    /// erlaubt. Nicht unter XCTest und nicht bei Startargumenten fuer Bildvergleiche (`automaticRunAllowed`).
    func kick(_ containers: ContainerManager) {
        guard StudIPSync.automaticRunAllowed(), !isLoading else { return }
        Task { await run(containers) }
    }

    /// Stufe (d) fuer den offenen Container. `expired`: im Hintergrund die Zeit von iOS. Rueckgabe: Zahl der Laeufe.
    @discardableResult
    func run(_ containers: ContainerManager, expired: @escaping () -> Bool = { false }) async -> Int {
        guard !isLoading, let c = containers.active, !containers.demoActive else { return 0 }
        // Abgleich-Objekte dieses Containers vor dem ersten Warten festhalten (danach koennte schon ein anderer offen sein)
        let studip = containers.studip, hsh = containers.hsh, hildesheim = containers.hildesheim
        guard let db = try? await c.host.backend().context.database, containers.active === c else { return 0 }
        isLoading = true
        defer { isLoading = false }
        let perTerm = studip.offersStudIP
        return await Self.runStage(db: db, today: UniFlowClock.system.today, perTerm: perTerm,
                                   pause: { [weak self] mode in
                                       // abgemeldet bzw. anderes Konto oder andere Hochschule offen: kein weiteres
                                       // Semester mit der Sitzung des alten Containers; weiter, wenn er wieder offen ist
                                       guard let self, !expired(), containers.active === c else { return .closed }
                                       return OlderLoadPolicy.decide(mode: mode, lowPower: self.lowPower(), onWiFi: self.onWiFi)
                                   },
                                   load: { ids in
                                       if perTerm { _ = await studip.loadOlderFiles(only: ids) }
                                       else if let hsh { _ = await hsh.loadOlderFiles() }
                                       else if let hildesheim { _ = await hildesheim.loadOlderFiles() }
                                   },
                                   wait: { [pauseNanos] in try? await Task.sleep(nanoseconds: pauseNanos) })
    }

    /// Ablauf der Stufe (d), ohne App-Objekte (Tests: Attrappen). Je Durchgang: Bedingungen pruefen (`pause`: nil =
    /// weiter, sonst Grund), das neueste Semester mit offenen Kursen waehlen, laden (`load` mit dessen Kursen; ohne
    /// `perTerm` holt ein Lauf alle offenen Kurse, neuestes zuerst), Stand merken. Hoert auf, wenn nichts mehr offen
    /// ist, eine Bedingung fehlt oder ein Lauf nichts geschafft hat (der naechste volle Abgleich versucht es erneut).
    static func runStage(db: SQLiteDatabase, today: String, perTerm: Bool,
                         pause: (OlderSemesters.Mode) async -> OlderLoadPolicy.Pause?,
                         load: (Set<String>) async -> Void,
                         wait: () async -> Void) async -> Int {
        var runs = 0
        while !Task.isCancelled {
            guard let state = try? await db.withConnection({ c in
                (try OlderSemesters.mode(c), try OlderSemesters.groups(c, today: today), try OlderSemesters.pending(c, today: today))
            }) else { break }
            let (mode, groups, pending) = state
            guard let next = groups.first(where: { $0.courses.contains { pending.contains($0.id) } }) else {
                _ = try? await db.transaction { try SyncOrder.setOlder($0, running: false) }
                break
            }
            if let why = await pause(mode) {
                _ = try? await db.transaction { try SyncOrder.setOlder($0, running: false, paused: why) }
                break
            }
            _ = try? await db.transaction { try SyncOrder.setOlder($0, running: true) }
            await load(perTerm ? Set(next.courses.map(\.id)).intersection(pending) : pending)
            runs += 1
            let left = (try? await db.withConnection { try OlderSemesters.pending($0, today: today) }) ?? pending
            guard perTerm, left.count < pending.count, !left.isEmpty else {
                _ = try? await db.transaction { try SyncOrder.setOlder($0, running: false) }
                break
            }
            await wait()
        }
        return runs
    }
}

/// Startet Stufe (d) nach jedem vollen Abgleich (Stud.IP, Learnweb/LSF, Moodle/Campusmanagement: `lastRun`), beim
/// Oeffnen und am Ende des Stromsparmodus. Nicht unter XCTest (`OlderSemesterLoader.kick`).
struct OlderSemesterLoaderHost: ViewModifier {
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.hsh) private var hsh

    func body(content: Content) -> some View {
        content
            .task { OlderSemesterLoader.shared.kick(containers) }
            .onChange(of: studip.lastRun) { _, _ in OlderSemesterLoader.shared.kick(containers) }
            .onReceive(hildesheim?.$lastRun.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in OlderSemesterLoader.shared.kick(containers) }
            .onReceive(hsh?.$lastRun.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in OlderSemesterLoader.shared.kick(containers) }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                Task { @MainActor in OlderSemesterLoader.shared.kick(containers) }
            }
    }
}
