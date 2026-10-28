import Foundation
import UniFlowCore

/// Laden der Einstellungsseite (`SettingsPage`), ohne Server aus dem lokalen Backend, mit eigenem Server (Entwicklung)
/// von dort. Pruefbericht 561-566:
/// - Ein Ladefehler wird gemeldet (`stale`), statt still eine leere Modul- oder Kursliste zu zeigen; vorher machte
///   `try?` aus einem gescheiterten `/api/modules` "0 Module" und alle Kurse "ohne Modul".
/// - Scheitert das Neuladen, bleibt der zuletzt geladene Stand stehen und ist als nicht aktualisiert gekennzeichnet.
/// - Nur der zuletzt begonnene Ladevorgang setzt den Stand: ueberholt ein aelterer (schneller Wechsel, zwei
///   Speichervorgaenge mit Neuladen kurz nacheinander), wird sein Ergebnis verworfen.
@MainActor
final class SettingsLoader: ObservableObject {
    /// eigener Server: alle Antworten
    @Published private(set) var data: SettingsPage.Loaded?
    /// eigener Server: erster Ladefehler (ohne geladenen Stand)
    @Published private(set) var error: String?
    /// ohne Server: lokales Backend
    @Published private(set) var local: SettingsPage.LocalLoaded?
    /// Laden scheiterte; angezeigt wird der zuletzt geladene Stand (bzw. ohne Server keiner)
    @Published private(set) var stale: String?
    private var generation = 0

    func load(api: APIClient?, ownServer: Bool) async {
        generation += 1
        let mine = generation
        guard let api else { data = nil; error = nil; local = nil; stale = nil; return }
        guard ownServer else {
            data = nil; error = nil
            do {
                let loaded = try await Self.fetchLocal(api)
                guard mine == generation else { return }
                local = loaded
                stale = nil
            } catch {
                guard mine == generation, !Task.isCancelled else { return }
                stale = error.localizedDescription
            }
            return
        }
        local = nil
        do {
            async let s = api.value("/api/settings")
            async let c = api.value("/api/courses")
            async let m = api.value("/api/modules")
            async let l = api.value("/api/sync/status")
            async let cr = api.value("/api/credentials")
            async let t = api.value("/api/terms")
            let (sv, cv, mv, lv, crv, tv) = try await (s, c, m, l, cr, t)
            guard mine == generation else { return }
            data = SettingsPage.Loaded(s: sv, courses: cv.items, mods: mv.items, log: lv.list("log"), cred: crv, term: tv)
            error = nil
            stale = nil
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if data == nil { self.error = error.localizedDescription } else { stale = error.localizedDescription }
        }
    }

    /// Einstellungen, Semester, Module und Kurse des lokalen Backends; scheitert eine Anfrage, scheitert alles.
    /// Module zuerst: GET /api/modules ordnet neue Kurse ihrem Fach zu (ensure_modules), die Kursliste danach zeigt
    /// diese Zuordnung schon.
    static func fetchLocal(_ api: APIClient) async throws -> SettingsPage.LocalLoaded {
        async let s = api.value("/api/settings")
        async let t = api.value("/api/terms")
        let (sv, tv) = try await (s, t)
        let mv = try await api.value("/api/modules")
        let cv = try await api.value("/api/courses")
        return SettingsPage.LocalLoaded(s: sv, term: tv, courses: cv.items, mods: mv.items)
    }
}
