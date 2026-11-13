import Foundation
import SwiftUI

// Reiter der offenen Dokumente (Auftrag des Inhabers 12.11.2026: "Dateien oben ansammeln (wie Reiter), damit man beim
// Schreiben schneller auf eine andere Datei zugreifen kann").
//
// Je Fenster eine Liste (`UFRouter.tabs`), gemerkt in den Einstellungen des Containers (je Geraet, verlaesst es nie).
// Im Speicher liegt immer nur das aktive Dokument (eine `DocumentView` mit PDFView); jeder andere Reiter ist ein
// leichter Eintrag mit Kennung, Titel, Seite, Stelle und Zoom. Antippen wechselt die Route (`UFRouter.replace`), das
// Dokument oeffnet neu und springt an die gemerkte Stelle. Vor dem Wechsel wartet `leaveGuard` des aktiven Dokuments,
// bis Stift und Finger ruhen (PDFKit nie waehrend einer Geste tauschen), und sichert die Striche (`DocumentStore.flush`).

/// Stelle im Dokument: Seite (Schluessel des Seitenaufbaus, sonst PDF-Seite), Punkt oben links der Ansicht in
/// Seitenkoordinaten und Zoom relativ zur eingepassten Breite (1 = eingepasst; die Fensterbreite kann sich aendern)
struct DocumentViewSpot: Codable, Equatable {
    var pageKey: String?
    var pdfPage: Int?
    var x: Double
    var y: Double
    var zoom: Double
}

struct DocumentTabEntry: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var spot: DocumentViewSpot?
    /// zuletzt gezeigt (Sekunden seit 1970): der aelteste faellt bei mehr als `DocumentTabList.limit` Reitern heraus
    var used: Double
    /// beim Verlassen nicht gesichert (lokales Sichern fehlgeschlagen, Konflikt offen): faellt nie von selbst heraus
    var unsaved = false
}

@MainActor
final class DocumentTabList: ObservableObject {
    /// hoechstens so viele Reiter: die zuletzt geoeffneten 15 Dokumente (Auftrag des Inhabers 13.11.2026; vorher 10);
    /// darueber faellt der am laengsten nicht gezeigte heraus
    static let limit = 15
    static let sceneKeyPrefix = "uniflow.docTabs.scene."
    static let lastKey = "uniflow.docTabs.last"

    @Published private(set) var entries: [DocumentTabEntry] = []
    /// Reiter des gerade gezeigten Dokuments
    @Published private(set) var activeID: String?
    /// Ein Wechsel laeuft (wartet auf Gestenende und Sichern): weitere Wechsel warten nicht doppelt
    @Published private(set) var switching = false

    /// Vom aktiven Dokument gesetzt: vor dem Wechsel Geste abwarten, Stelle merken, Striche sichern
    private(set) var leaveGuard: (() async -> Void)?
    private var leaveGuardOwner: UUID?

    /// Fenster (`UFRouter.resume.sceneID`); leer = noch keins
    var sceneID: () -> String = { "" }
    private let fixedDefaults: UserDefaults?
    private var loadedFrom: ObjectIdentifier?
    /// Zeit (Tests: fest)
    var now: () -> Date = Date.init
    /// Nur das erste Fenster eines Laufs uebernimmt die Reiter des zuletzt geschriebenen Fensters (ein neues Fenster
    /// beginnt leer, statt die Reiter des anderen zu doppeln)
    private static var lastTaken = false

    /// Einstellungen des aktiven Containers (Tests: eigene Suiten, um einen Konto-Wechsel nachzustellen)
    var containerDefaults: () -> UserDefaults? = { ActiveContainer.current?.defaults }

    /// `defaults` nil: Einstellungen des aktiven Containers (Konto- und Hochschulwechsel laden die Liste neu)
    init(defaults: UserDefaults? = nil) { fixedDefaults = defaults }

    private var defaults: UserDefaults? { fixedDefaults ?? containerDefaults() }

    /// Reiter fuer die Anzeige: nur, wenn die Liste aus den Einstellungen des gerade offenen Containers stammt. Nach
    /// einem Konto- oder Hochschulwechsel steht bis zum Neuladen (`refresh`) nichts da statt der Reiter des anderen
    /// Kontos (Datentrennung).
    var visibleEntries: [DocumentTabEntry] {
        // ohne Container (nur im Speicher) gilt die Liste, solange sie nie aus einem Container kam
        defaults.map(ObjectIdentifier.init) == loadedFrom ? entries : []
    }

    /// Liste fuer den aktiven Container laden, falls sie von einem anderen stammt (beim Erscheinen der Reiterzeile)
    func refresh() { loadIfNeeded() }

    // MARK: Oeffnen, wechseln, schliessen

    func entry(_ id: String) -> DocumentTabEntry? { loadIfNeeded(); return entries.first { $0.id == id } }

    var ids: [String] { entries.map(\.id) }

    /// Dokument gezeigt (Route `#/doc/<id>`): als Reiter anlegen bzw. den vorhandenen aktiv setzen. Neue Reiter stehen
    /// rechts neben dem bisher aktiven (wie in Safari), damit Zusammengehoeriges zusammen bleibt.
    func open(_ id: String, title: String?) {
        loadIfNeeded()
        let stamp = now().timeIntervalSince1970
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].used = stamp
            if let title, !title.isEmpty { entries[i].title = title }
        } else {
            let e = DocumentTabEntry(id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Dokument", used: stamp)
            if let a = activeID, let i = entries.firstIndex(where: { $0.id == a }) { entries.insert(e, at: i + 1) } else { entries.append(e) }
        }
        activeID = id
        evictIfNeeded()
        save()
    }

    func setTitle(_ title: String, for id: String) {
        guard !title.isEmpty, let i = entries.firstIndex(where: { $0.id == id }), entries[i].title != title else { return }
        entries[i].title = title
        save()
    }

    /// Stelle, Seite und Zoom des Reiters (beim Blaettern entprellt und beim Verlassen)
    func setSpot(_ spot: DocumentViewSpot?, for id: String) {
        guard let spot, let i = entries.firstIndex(where: { $0.id == id }), entries[i].spot != spot else { return }
        entries[i].spot = spot
        save()
    }

    func setUnsaved(_ unsaved: Bool, for id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].unsaved != unsaved else { return }
        entries[i].unsaved = unsaved
        save()
    }

    /// Mehr als `limit`: die am laengsten nicht gezeigten heraus, nie der aktive und nie einer mit ungesicherten
    /// Aenderungen
    private func evictIfNeeded() {
        while entries.count > Self.limit {
            let candidates = entries.filter { $0.id != activeID && !$0.unsaved }
            guard let oldest = candidates.min(by: { $0.used < $1.used }) else { return }
            entries.removeAll { $0.id == oldest.id }
        }
    }

    /// Naechster bzw. voriger Reiter (Ctrl-Tab, Cmd-Umschalt-]), nach dem letzten wieder der erste
    func neighbor(step: Int) -> String? { DocumentTabs.neighbor(of: activeID, in: ids, step: step) }

    /// Reiter, der nach dem Schliessen von `id` gezeigt wird: der links daneben, sonst der rechts; nil = keiner mehr
    static func successor(closing id: String, in ids: [String]) -> String? {
        guard let i = ids.firstIndex(of: id) else { return nil }
        var rest = ids
        rest.remove(at: i)
        guard !rest.isEmpty else { return nil }
        return rest[max(0, i - 1)]
    }

    /// Zum Reiter wechseln: Geste abwarten und sichern (`leaveGuard`), dann die Route ersetzen (kein neuer Schritt im
    /// Zurueck-Verlauf: Zurueck fuehrt dorthin, wo das erste Dokument geoeffnet wurde)
    func select(_ id: String, router: UFRouter) {
        guard !switching else { return }
        if id == activeID, case .doc(let current, _, _) = router.route, current == id { return }
        switching = true
        let guardAction = leaveGuard
        Task { @MainActor in
            await guardAction?()
            self.switching = false
            router.replace(.doc(id))
        }
    }

    /// "×": Reiter schliessen. War er zu sehen, kommt der Nachbar (sonst zurueck, woher das Dokument geoeffnet wurde).
    func close(_ id: String, router: UFRouter) {
        guard !switching else { return }
        let next = Self.successor(closing: id, in: ids)
        guard id == activeID else {
            entries.removeAll { $0.id == id }
            save()
            return
        }
        switching = true
        let guardAction = leaveGuard
        Task { @MainActor in
            await guardAction?()
            self.entries.removeAll { $0.id == id }
            self.activeID = next
            self.save()
            self.switching = false
            if let next { router.replace(.doc(next)) } else { router.goBack() }
        }
    }

    /// "Andere schließen": nur dieser Reiter bleibt (er wird gezeigt, falls er es nicht schon ist)
    func closeOthers(keeping id: String, router: UFRouter) {
        entries.removeAll { $0.id != id && $0.id != activeID }
        save()
        if id != activeID {
            let old = activeID
            select(id, router: router)
            if let old { entries.removeAll { $0.id == old } }
            save()
        }
    }

    /// "In neuem Fenster öffnen": Reiter hier schliessen, das Dokument in einem eigenen Fenster an seiner Stelle oeffnen
    func openInNewWindow(_ id: String, router: UFRouter) {
        let page = entry(id)?.spot?.pdfPage
        let wasActive = id == activeID
        close(id, router: router)
        Task { @MainActor in
            // das Dokument hier ist zu (Striche gesichert), bevor das neue Fenster es zum Schreiben oeffnet
            if wasActive { try? await Task.sleep(nanoseconds: 400_000_000) }
            DocumentWindows.open(fileID: id, page: page)
        }
    }

    // MARK: Geloeschte Dokumente

    /// Dokumente aus der Leiste nehmen (Papierkorb, endgueltig geloescht); auch den aktiven Reiter, die Anzeige zeigt
    /// das offene Dokument dann ohne "×"
    func remove(_ ids: Set<String>) {
        loadIfNeeded()
        guard entries.contains(where: { ids.contains($0.id) }) else { return }
        entries.removeAll { ids.contains($0.id) }
        if let a = activeID, ids.contains(a) { activeID = nil }
        save()
    }

    /// Abgleich mit der Bibliothek (`GET /api/library`): Reiter im Papierkorb fallen heraus; Reiter, die weder in der
    /// Liste noch im Papierkorb stehen (endgueltig geloescht, oder nur ausgeblendet wie Dateien abgewaehlter Kurse),
    /// fragt `exists` einzeln nach – nur was es wirklich nicht mehr gibt, faellt heraus
    func pruneDeleted(listed: Set<String>, trashed: Set<String>, exists: (String) async -> Bool) async {
        loadIfNeeded()
        let source = defaults.map(ObjectIdentifier.init)
        var gone = Set(entries.map(\.id).filter { trashed.contains($0) })
        for id in entries.map(\.id) where !listed.contains(id) && !trashed.contains(id) {
            if await !exists(id) { gone.insert(id) }
        }
        // inzwischen anderer Container (Konto-Wechsel): dessen Liste nicht anfassen
        guard !gone.isEmpty, source == defaults.map(ObjectIdentifier.init) else { return }
        remove(gone)
    }

    // MARK: Schutz des aktiven Dokuments

    /// Das aktive Dokument meldet seinen Schutz; die Kennung gibt ihn beim Verschwinden wieder frei (eine neue Ansicht
    /// kann ihren schon gesetzt haben)
    func setLeaveGuard(_ owner: UUID, _ action: @escaping () async -> Void) {
        leaveGuardOwner = owner
        leaveGuard = action
    }

    func clearLeaveGuard(_ owner: UUID) {
        guard leaveGuardOwner == owner else { return }
        leaveGuardOwner = nil
        leaveGuard = nil
    }

    // MARK: Gemerkt je Geraet

    private struct Saved: Codable {
        var entries: [DocumentTabEntry]
        var active: String?
    }

    private func loadIfNeeded() {
        guard let d = defaults else { return }
        let source = ObjectIdentifier(d)
        guard loadedFrom != source else { return }
        loadedFrom = source
        entries = []
        activeID = nil
        let scene = sceneID()
        var keys = scene.isEmpty ? [] : [Self.sceneKeyPrefix + scene]
        if !Self.lastTaken { keys.append(Self.lastKey) }
        Self.lastTaken = true
        for k in keys {
            if let data = d.data(forKey: k), let s = try? JSONDecoder().decode(Saved.self, from: data) {
                entries = Array(s.entries.prefix(Self.limit))
                activeID = s.active
                return
            }
        }
    }

    private func save() {
        guard let d = defaults, loadedFrom == ObjectIdentifier(d),
              let data = try? JSONEncoder().encode(Saved(entries: entries, active: activeID)) else { return }
        let scene = sceneID()
        if !scene.isEmpty { d.set(data, forKey: Self.sceneKeyPrefix + scene) }
        d.set(data, forKey: Self.lastKey)
    }

    /// Nur Tests: Liste neu aus den Einstellungen lesen (Neustart nachstellen)
    func reloadForTesting() {
        loadedFrom = nil
        Self.lastTaken = false
        loadIfNeeded()
    }
}
