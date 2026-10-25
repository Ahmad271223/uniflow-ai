import Foundation
import UniFlowCore

/// Stundenplan aus Stud.IP aufs iPad (S5, docs/IPAD-OHNE-PC.md): nach dem Datei-Abgleich Kurszeiten
/// (seminar-cycle-dates), eigene Eintraege (schedule-entries) und die Einzeltermine der abgeglichenen Kurse
/// (course-events) laden und in die lokale Datenbank schreiben. `StudIPScheduleStore.store` uebernimmt danach wie
/// `timetable.auto_import` auf dem PC alle eindeutigen Termine in den Stundenplan. Parallele Uebungsgruppen bleiben
/// offen; der Nutzer waehlt seine Gruppe wie in der Web-App unter "Stundenplan importieren -> aus Stud.IP"
/// (Vorschau mit Hinweis "n parallele Gruppen", `/api/timetable/import/preview` und `/confirm`).
///
/// Fehler hier brechen den Datei-Abgleich nie ab: `run` wirft nicht. Was nicht geladen werden konnte, bleibt wie
/// zuletzt gespeichert; die Zusammenfassung nennt es. Nach einem Netz- oder Zeitlimitfehler fragt der Abruf nichts
/// mehr ab (sonst wartete jeder Kurs bis zum Zeitlimit von 30 s).
struct StudIPScheduleSync {
    /// Lokales Backend, in dessen Datenbank der Stundenplan landet
    let host: LocalBackendHost

    init(host: LocalBackendHost = .shared) {
        self.host = host
    }

    /// Ergebnis eines Laufs
    struct Outcome: Equatable {
        /// gespeichert und uebernommen; nil = nicht gespeichert (Datenbank nicht verfuegbar)
        var result: StudIPScheduleResult?
        /// Kurse, deren Einzeltermine nicht geladen werden konnten
        var failedCourses = 0
        /// Stud.IP-Anmeldung abgelaufen (der Rest wurde nicht mehr abgefragt)
        var sessionExpired = false
        /// Kurszeiten und eigene Eintraege (users/{id}/schedule) nicht lesbar
        var scheduleFailed = false
        /// Netz- oder Zeitlimitfehler: der Rest wurde nicht mehr abgefragt
        var unreachable = false

        /// Teile fuer die Zusammenfassung des Abgleichs (wie `message += ", N Stundenplan-Termine"` in run_sync).
        /// Gruppen, aus denen schon gewaehlt ist, zaehlen nicht (StudIPScheduleImport.openGroups).
        var summary: [String] {
            var parts: [String] = []
            if let r = result {
                if r.newEvents > 0 { parts.append("\(r.newEvents) Stundenplan-Termine") }
                if r.pendingGroups > 0 { parts.append("Übungsgruppen zur Auswahl im Stundenplan") }
            } else {
                parts.append("Stundenplan nicht gespeichert")
            }
            if sessionExpired {
                parts.append("Stundenplan: Stud.IP-Anmeldung abgelaufen")
            } else if unreachable {
                parts.append("Stundenplan: Stud.IP nicht erreichbar")
            } else {
                if scheduleFailed { parts.append("Kurszeiten nicht geladen") }
                if failedCourses > 0 { parts.append("Termine von \(failedCourses) \(failedCourses == 1 ? "Kurs" : "Kursen") nicht geladen") }
            }
            return parts
        }
    }

    /// Laedt den Stundenplan der Kurse (`courses`: die abgeglichenen Kurse) und speichert ihn. Kein `await` in der
    /// Transaktion: erst das Netz, dann kurz schreiben. `progress` bekommt den Text fuer die Statusanzeige.
    @MainActor
    func run(client: StudIPClient, userID: String, courses: [StudIPCourse], progress: (String) -> Void = { _ in }) async -> Outcome {
        progress("Stundenplan wird geladen …")
        let download = await StudIPScheduleStore.fetch(client: client, userID: userID, courses: courses)
        var out = Outcome(failedCourses: download.failedCourses.count, sessionExpired: download.sessionExpired,
                          scheduleFailed: download.scheduleError != nil, unreachable: download.unreachable)
        do {
            let backend = try await host.backend()
            let clock = backend.context.clock
            out.result = try await backend.context.database.transaction { try StudIPScheduleStore.store(download, in: $0, clock: clock) }
        } catch {
            out.result = nil
        }
        return out
    }
}
