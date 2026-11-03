import Foundation
import UniFlowCore

/// Stud.IP-Ergaenzungen nach dem Stundenplan (02.11.2026, `StudIPExtras` im Kern): Semester und vorlesungsfreie Zeiten
/// (Planer, Lernplan), Stud.IP-weite Ankuendigungen, Nachrichten (nur die Liste, nur auf diesem Geraet), Aenderungen in
/// Kursen (Activity-Stream, nur Hinweis) und eigene Sprechstunden. Wenige Anfragen, alle nur lesend; Endpunkte, die die
/// Hochschule nicht anbietet, merkt sich der Kern und fragt sie erst nach 30 Tagen wieder.
/// Seit 03.11.2026 dazu das Schwarze Brett (`StudIPBulletin`), nur an Hochschulen mit dem Plugin
/// (`UniversityProfile.hasBulletinBoard`), hoechstens alle sechs Stunden, je Thema die neuesten 20 Anzeigen.
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
        if download.sessionExpired { return true }
        return await bulletin(client: client, backend: backend)
    }

    /// Schwarzes Brett: nur mit Plugin laut Hochschulprofil; der Kern merkt sich ein fehlendes Plugin (30 Tage) und den
    /// letzten Abruf (6 Stunden). Liefert true bei abgelaufener Sitzung.
    @MainActor
    func bulletin(client: StudIPClient, backend: LocalBackend) async -> Bool {
        guard host.university.profile.hasBulletinBoard else { return false }
        let clock = backend.context.clock
        let db = backend.context.database
        let missing = (try? await db.withConnection { try StudIPExtras.loadMissing($0) }) ?? [:]
        let last = (try? await db.withConnection { try StudIPBulletin.lastFetchedAt($0) }) ?? nil
        let d = await StudIPBulletin.fetch(client: client, missing: missing, lastFetchedAt: last, clock: clock)
        if !d.skipped { try? await db.transaction { try StudIPBulletin.store(d, in: $0, clock: clock) } }
        return d.sessionExpired
    }
}
