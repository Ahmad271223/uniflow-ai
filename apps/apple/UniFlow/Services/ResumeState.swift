import Foundation
import UniFlowCore

/// Weitermachen wie zuvor (Wunsch des Inhabers 04.11.2026, docs/WEITERMACHEN-2026-11-04.md): wurde das Dokument nicht
/// geschlossen, sondern das iPad gesperrt, ausgeschaltet oder die App von iOS beendet, zeigt der naechste Start
/// denselben Stand - das zuletzt offene Dokument auf seiner Seite, die KI-Hilfe offen, wenn sie offen war (ihr
/// Gespraech kommt aus `TutorConversations`), und "Daneben öffnen", wenn es offen war.
///
/// Gespeichert je Fenster (`UFRouter.resume`, Szene-Kennung aus `@SceneStorage`) in den Einstellungen des Containers:
/// `uniflow.resume.scene.<Szene>` und `uniflow.resume.last` (das zuletzt geschriebene Fenster; nach einem Beenden
/// durch den Nutzer legt iOS die Szenen neu an, dann gilt dieses). Verlaesst das Geraet nie.
struct ResumeState: Codable, Equatable {
    /// Hash-Route wie im Web (`UFRoute.hash`), z. B. "#/doc/f-1?page=4"
    var route: String
    /// offenes Dokument und seine PDF-Seite (1 = erste); nil ausserhalb des Editors
    var fileID: String?
    var page: Int?
    /// KI-Hilfe offen
    var tutorOpen = false
    /// "Daneben öffnen": zweites Dokument und seine Seite
    var companionID: String?
    var companionPage: Int?
    /// Zeitpunkt des letzten Schreibens (ISO, Berlin)
    var at: String = ""

    static let sceneKeyPrefix = "uniflow.resume.scene."
    static let lastKey = "uniflow.resume.last"

    static func sceneKey(_ sceneID: String) -> String { sceneKeyPrefix + sceneID }

    /// Route ohne Dokument: alle Dokumentfelder leer (ein spaeteres Dokument setzt sie neu)
    static func forRoute(_ r: UFRoute) -> ResumeState {
        if case .doc(let id, _, let page) = r { return ResumeState(route: r.hash, fileID: id, page: page) }
        return ResumeState(route: r.hash)
    }

    var isDocument: Bool { fileID != nil }
}

/// Was beim Start aus dem gemerkten Stand wird (reine Funktion, UniFlowTests/ResumeAppTests.swift)
enum ResumeDecision: Equatable {
    /// nichts gemerkt, Uebersicht gemerkt, oder das Dokument gibt es nicht mehr: still auf der Uebersicht bleiben
    case dashboard
    /// eine andere Seite (Lernkalender, Einstellungen …)
    case route(UFRoute)
    /// das Dokument auf seiner Seite; die Spalten stellt der Editor aus `panels` wieder her
    case document(id: String, page: Int?, panels: ResumeState)

    /// `documentExists`: Antwort auf `GET /api/files/{id}` (nil = kein Dokument gemerkt); fehlt es, Uebersicht
    static func decide(_ s: ResumeState?, documentExists: Bool?) -> ResumeDecision {
        guard let s else { return .dashboard }
        if let id = s.fileID {
            guard documentExists == true else { return .dashboard }
            return .document(id: id, page: s.page, panels: s)
        }
        let r = UFRoute(hash: s.route)
        return r == .dashboard ? .dashboard : .route(r)
    }
}

/// Stand eines Fensters mitschreiben und beim Start einmal wiederherstellen; haengt am `UFRouter` des Fensters.
/// Schreibt in die Einstellungen des aktiven Containers (Tests: eigene Suite). Der Kaltstart wartet nie darauf:
/// die Uebersicht erscheint sofort, `restoreIfNeeded` holt das Dokument danach und schweigt bei jedem Fehler.
@MainActor
final class ResumeTracker {
    /// Kennung des Fensters (`@SceneStorage` in `SceneObjects`); leer = noch kein Fenster (nur `last`)
    var sceneID = ""
    private(set) var state: ResumeState?
    private var restored = false
    /// vom Start wiederhergestellte Spalten, die der Editor beim Laden des Dokuments einmal abholt
    private var restoredPanels: ResumeState?
    private let fixedDefaults: UserDefaults?
    /// Zeit fuer `at` (Tests: fest)
    var now: () -> Date = Date.init

    /// `defaults` nil: die Einstellungen des aktiven Containers zum Zeitpunkt des Schreibens (Konto und Hochschule
    /// koennen seit dem Start gewechselt haben)
    init(defaults: UserDefaults? = nil) { fixedDefaults = defaults }

    private var defaults: UserDefaults? { fixedDefaults ?? ActiveContainer.current?.defaults }

    // MARK: Mitschreiben

    func noteRoute(_ r: UFRoute) {
        if case .doc(let id, _, let page) = r, state?.fileID == id {
            // dasselbe Dokument (z. B. Sprung zu einer Seite): Spalten behalten
            state?.route = r.hash
            if let page { state?.page = page }
        } else {
            state = ResumeState.forRoute(r)
        }
        save()
    }

    /// Editor geladen: Dokument und Startseite (`page` 1 = erste, nil = Anfang)
    func noteDocument(id: String, page: Int?) {
        if state?.fileID != id { state = ResumeState(route: UFRoute.doc(id, page: page).hash, fileID: id, page: page) }
        if let page { state?.page = page }
        save()
    }

    func notePage(_ page: Int?, of id: String) {
        guard state?.fileID == id, let page else { return }
        state?.page = page
        state?.route = UFRoute.doc(id, page: page).hash
        save()
    }

    func noteTutor(open: Bool, of id: String) {
        guard state?.fileID == id, state?.tutorOpen != open else { return }
        state?.tutorOpen = open
        save()
    }

    func noteCompanion(id companionID: String?, page: Int?, of id: String) {
        guard state?.fileID == id else { return }
        guard state?.companionID != companionID || state?.companionPage != page else { return }
        state?.companionID = companionID
        state?.companionPage = page
        save()
    }

    private func save() {
        guard var s = state, let d = defaults else { return }
        s.at = Fmt.isoDateTime(now())
        state = s
        guard let data = try? JSONEncoder().encode(s) else { return }
        if !sceneID.isEmpty { d.set(data, forKey: ResumeState.sceneKey(sceneID)) }
        d.set(data, forKey: ResumeState.lastKey)
    }

    // MARK: Wiederherstellen

    /// Gemerkter Stand dieses Fensters, sonst der des zuletzt geschriebenen
    func stored() -> ResumeState? {
        guard let d = defaults else { return nil }
        let keys = (sceneID.isEmpty ? [] : [ResumeState.sceneKey(sceneID)]) + [ResumeState.lastKey]
        for k in keys {
            if let data = d.data(forKey: k), let s = try? JSONDecoder().decode(ResumeState.self, from: data) { return s }
        }
        return nil
    }

    /// Einmal je Fenster nach dem Oeffnen des Containers: Dokument pruefen (`GET /api/files/{id}`), dann die Route
    /// setzen; ein verschwundenes Dokument oder ein Fehler laesst die Uebersicht stehen. Gibt die Entscheidung zurueck.
    @discardableResult
    func restoreIfNeeded(api: APIClient?, router: UFRouter) async -> ResumeDecision {
        guard !restored else { return .dashboard }
        guard let s = stored() else { restored = true; return .dashboard }
        // ohne Zugang (Container noch nicht offen) spaeter erneut versuchen (`MainView` ruft mit jedem neuen Zugang)
        if s.fileID != nil, api == nil { return .dashboard }
        restored = true
        let start = router.route
        var exists: Bool? = nil
        if let id = s.fileID, let api {
            exists = (try? await api.value("/api/files/\(id)")) != nil
        }
        let decision = ResumeDecision.decide(s, documentExists: exists)
        // hat der Nutzer waehrend der Pruefung schon etwas anderes geoeffnet, bleibt es dabei
        guard router.route == start, start == .dashboard else { return .dashboard }
        switch decision {
        case .dashboard:
            break
        case .route(let r):
            router.go(r)
        case .document(let id, let page, let panels):
            restoredPanels = panels
            router.go(.doc(id, page: page))
            state = panels                       // Spalten bleiben gemerkt, bis der Editor sie meldet
            save()
        }
        return decision
    }

    /// Der Editor holt beim Laden die Spalten des wiederhergestellten Dokuments (einmal; eine andere Datei bekommt nichts)
    func takeRestoredPanels(for fileID: String) -> ResumeState? {
        guard let p = restoredPanels, p.fileID == fileID else { return nil }
        restoredPanels = nil
        return p
    }

    /// Nur Tests: Wiederherstellung erneut erlauben
    func resetForTests() { restored = false; restoredPanels = nil }
}
