import Foundation
import UniFlowCore

/// Stud.IP-Ergaenzungen nach dem Stundenplan (02.11.2026, `StudIPExtras` im Kern): Semester und vorlesungsfreie Zeiten
/// (Planer, Lernplan), Stud.IP-weite Ankuendigungen, Nachrichten (nur die Liste, nur auf diesem Geraet), Aenderungen in
/// Kursen (Activity-Stream, nur Hinweis) und eigene Sprechstunden. Wenige Anfragen, alle nur lesend; Endpunkte, die die
/// Hochschule nicht anbietet, merkt sich der Kern und fragt sie erst nach 30 Tagen wieder.
///
/// Fehler hier brechen den Abgleich nie ab: `run` wirft nicht, was nicht geladen werden konnte, bleibt wie gespeichert.
struct StudIPExtrasSync {
    let host: LocalBackendHost

    init(host: LocalBackendHost = .shared) {
        self.host = host
    }

    /// Liefert true, wenn die Stud.IP-Sitzung dabei abgelaufen ist
    @MainActor
    @discardableResult
    func run(client: StudIPClient, userID: String) async -> Bool {
        guard let backend = try? await host.backend() else { return false }
        let clock = backend.context.clock
        let missing = (try? await backend.context.database.withConnection { try StudIPExtras.loadMissing($0) }) ?? [:]
        let download = await StudIPExtras.fetch(client: client, userID: userID, missing: missing, clock: clock)
        try? await backend.context.database.transaction { try StudIPExtras.store(download, in: $0, clock: clock) }
        return download.sessionExpired
    }
}
