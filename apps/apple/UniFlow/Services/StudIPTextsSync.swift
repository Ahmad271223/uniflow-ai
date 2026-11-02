import Foundation
import UniFlowCore

/// Lernstoff aus Stud.IP im Abgleich des iPads (nach Stundenplan und Aufzeichnungen, nur im vollen Lauf): Fristen der
/// Courseware-Aufgaben, Courseware-Seiten, Wiki und Forum der aktuellen Kurse (`StudIPTexts` im Kern, wie
/// app/studip_texts.py). Nur lesend, hoechstens `StudIPTexts.maxRequests` Anfragen. Wirft nie: Fehler lassen das
/// Gespeicherte stehen und halten den Datei-Abgleich nicht an; nur eine abgelaufene Sitzung wird gemeldet.
/// Kein `await` in der Transaktion: erst das Netz, dann kurz schreiben.
struct StudIPTextsSync {
    let host: LocalBackendHost

    struct Outcome: Equatable {
        var result: StudIPTexts.StoreResult?
        var sessionExpired = false

        /// Teile fuer die Zusammenfassung (nur wenn etwas Neues kam)
        var summary: [String] { result?.summary ?? [] }
    }

    @MainActor
    func run(client: StudIPClient, courses: [StudIPCourse], progress: (String) -> Void = { _ in }) async -> Outcome {
        var out = Outcome()
        guard !courses.isEmpty, let backend = try? await host.backend() else { return out }
        progress("Courseware, Wiki und Forum werden gelesen …")
        let db = backend.context.database, clock = backend.context.clock
        do {
            let loaded: (known: StudIPTexts.Known, state: [String: String]) = try await db.withConnection { try StudIPTexts.load($0) }
            let d = try await StudIPTexts.fetch(client: client, courses: courses, known: loaded.known, state: loaded.state,
                                                today: clock.today, base: client.base.absoluteString)
            let now = clock.nowISO
            out.result = try await db.transaction { try StudIPTexts.store($0, d, now: now) }
        } catch StudIPError.sessionExpired {
            out.sessionExpired = true
        } catch {
            out.result = nil
        }
        return out
    }
}
