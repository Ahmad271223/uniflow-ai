import Foundation
import UniFlowCore

/// Stud.IP-Ergaenzungen nach dem Stundenplan (02.11.2026, `StudIPExtras` im Kern): Semester und vorlesungsfreie Zeiten
/// (Planer, Lernplan), Stud.IP-weite Ankuendigungen, Nachrichten (nur die Liste, nur auf diesem Geraet), Aenderungen in
/// Kursen (Activity-Stream, nur Hinweis) und eigene Sprechstunden. Wenige Anfragen, alle nur lesend; Endpunkte, die die
/// Hochschule nicht anbietet, merkt sich der Kern und fragt sie erst nach 30 Tagen wieder.
/// Seit 03.11.2026 dazu das Schwarze Brett (`StudIPBulletin`), nur an Hochschulen mit dem Plugin
/// (`UniversityProfile.hasBulletinBoard`), hoechstens alle sechs Stunden, je Thema die neuesten 20 Anzeigen.
/// Dazu Blubber (`StudIPBlubber`): eine Liste aller eigenen Threads, davon die der gewaehlten Kurse und der
/// Stud.IP-weite, je geaendertem Thread die neuesten 20 Beitraege (hoechstens 12 Threads je Lauf), Rolle statt Name.
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
    func run(client: StudIPClient, userID: String, courses: [StudIPCourse] = []) async -> Bool {
        guard let backend = try? await host.backend() else { return false }
        let clock = backend.context.clock
        let missing = (try? await backend.context.database.withConnection { try StudIPExtras.loadMissing($0) }) ?? [:]
        let download = await StudIPExtras.fetch(client: client, userID: userID, missing: missing, clock: clock)
        try? await backend.context.database.transaction { try StudIPExtras.store(download, in: $0, clock: clock) }
        if download.sessionExpired { return true }
        if await bulletin(client: client, backend: backend) { return true }
        // Blubber vorerst aus (StudIPBlubber.syncEnabled)
        guard StudIPBlubber.syncEnabled else { return false }
        return await blubber(client: client, userID: userID, courses: courses, backend: backend)
    }

    /// Lehrende und Kontakte der gewaehlten aktuellen Kurse (`StudIPLecturers`, 06.11.2026): Name, Rolle, E-Mail,
    /// Sprechzeiten; nur an Hochschulen mit Stud.IP, je Kurs hoechstens alle 7 Tage, nur lesend, nur auf dem Geraet.
    /// Liefert true bei abgelaufener Sitzung.
    @MainActor
    func lecturers(client: StudIPClient, courses: [StudIPCourse]) async -> Bool {
        guard host.university.profile.studipBase != nil, let backend = try? await host.backend() else { return false }
        let d = await StudIPLecturers.run(client: client, database: backend.context.database, courseIDs: courses.map(\.id),
                                          clock: backend.context.clock, university: host.university.rawValue)
        return d.sessionExpired
    }

    /// Blubber der gewaehlten aktuellen Kurse (nur lesend, nur Liste und Kommentare, nie `courses/{id}/blubber-threads`,
    /// das in Stud.IP einen Thread anlegen kann). Liefert true bei abgelaufener Sitzung.
    @MainActor
    func blubber(client: StudIPClient, userID: String, courses: [StudIPCourse], backend: LocalBackend) async -> Bool {
        let clock = backend.context.clock
        let db = backend.context.database
        let missing = (try? await db.withConnection { try StudIPExtras.loadMissing($0) }) ?? [:]
        let known = (try? await db.withConnection { try StudIPBlubber.known($0) }) ?? [:]
        let d = await StudIPBlubber.fetch(client: client, userID: userID, courseIDs: courses.map(\.id), missing: missing, known: known,
                                          today: clock.today)
        try? await db.transaction { try StudIPBlubber.store(d, in: $0, clock: clock) }
        return d.sessionExpired
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
