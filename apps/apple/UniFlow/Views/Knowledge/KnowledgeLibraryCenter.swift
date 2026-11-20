import Foundation
import SwiftUI
import UniFlowCore

// Wissensbibliothek in der App (Auftrag des Inhabers 20.11.2026, docs/STAND-MAC-SITZUNG.md): eigene, private
// Lernbibliothek (Erklaerungen und Loesungen je Vorlesungsseite) aus einem Ordner oder einer ZIP-Datei. Sie liegt nur
// im Container des Nutzers (`KnowledgeLibraryStore`), nie im App-Bundle, nie auf einem Server, nie bei einer KI.
//
// Schalter: Einstellungen -> Erweitert -> "Wissensbibliothek", Standard AUS. Aus heisst: nirgends sichtbar (kein
// Menuepunkt, keine Suchtreffer, kein Knopf an Dokumenten). Zu keinem Tarif gehoerig und nirgends beworben, bis der
// Inhaber ueber die Abo-Stufe entscheidet.

/// Lokaler Schalter (nur dieses Geraet, nicht im Geraete-Abgleich)
enum KnowledgeLibrarySetting {
    static let key = "knowledgeLibrary.enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Zustand der Bibliothek des aktiven Containers: laden, einlesen, suchen, entfernen.
@MainActor
final class KnowledgeLibraryCenter: ObservableObject {
    static let shared = KnowledgeLibraryCenter()

    enum Phase: Equatable {
        case idle
        case loading
        /// Einlesen laeuft: erledigte und alle Dateien
        case importing(done: Int, total: Int)
    }

    @Published private(set) var library: KnowledgeLibrary?
    @Published private(set) var phase: Phase = .idle
    /// letzte Meldung (Ergebnis des Einlesens, Fehler)
    @Published var message: String?
    /// Ordner des Containers, zu dem `library` gehoert
    private var loadedRoot: URL?

    /// Bibliothek des aktiven Containers, sobald geladen (nach einem Kontowechsel bis zum Neuladen nil)
    var current: KnowledgeLibrary? { loadedRoot != nil && loadedRoot == Self.containerRoot ? library : nil }

    /// Ordner des aktiven Containers (ohne Anmeldung nil: dann gibt es keine Bibliothek)
    nonisolated static var containerRoot: URL? { ActiveContainer.current?.layout.root }

    private func store(_ root: URL) -> KnowledgeLibraryStore { KnowledgeLibraryStore(containerRoot: root) }

    /// Bibliothek des aktiven Containers laden (einmal je Container; nach einem Wechsel neu)
    func ensureLoaded() async {
        guard let root = Self.containerRoot else { library = nil; loadedRoot = nil; return }
        if loadedRoot == root || phase == .loading { return }
        await reload(root)
    }

    private func reload(_ root: URL) async {
        phase = .loading
        let s = store(root)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<KnowledgeLibrary?, Error> in
            Result { try s.load() }
        }.value
        loadedRoot = root
        phase = .idle
        switch result {
        case .success(let lib): library = lib
        case .failure(let e): library = nil; message = "Die Wissensbibliothek ließ sich nicht laden: \(e.localizedDescription)"
        }
    }

    /// Ordner oder ZIP einlesen (Dateien-App, Mac-Ordner, Startparameter). `force`: auch bei gleichem oder aelterem Stand.
    /// Rueckgabe: Meldung fuer den Nutzer.
    @discardableResult
    func importFrom(_ url: URL, force: Bool = false) async -> String {
        guard let root = Self.containerRoot else { return say("Bitte zuerst anmelden: Die Bibliothek gehört zu deinem Konto auf diesem Gerät.") }
        guard phase == .idle || phase == .loading else { return say("Es wird schon eingelesen.") }
        phase = .importing(done: 0, total: 0)
        let s = store(root)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<KnowledgeLibraryStore.Outcome, Error> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return Result {
                var source = url
                var cleanup: URL?
                defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
                if ZipArchive.isZipName(url.lastPathComponent) {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-zip-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    cleanup = dir
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    _ = try ZipArchive.extract(data, to: dir, limits: Self.zipLimits)
                    source = dir
                }
                return try s.importLibrary(from: source, sourceName: url.lastPathComponent, force: force) { done, total in
                    Task { @MainActor in KnowledgeLibraryCenter.shared.progress(done, total) }
                }
            }
        }.value
        phase = .idle
        switch result {
        case .success(.imported(let m)):
            try? DataContainerLayout.setExcludedFromBackup(s.base)          // jederzeit neu einlesbar, privat
            await reload(root)
            if ZipArchive.isZipName(url.lastPathComponent) { forgetSource() } else { rememberSource(url) }
            return say(Self.importedText(m))
        case .success(.alreadyCurrent(let stand)):
            if !ZipArchive.isZipName(url.lastPathComponent) { rememberSource(url) }
            return say("Die Bibliothek ist aktuell (Stand \(UFFmt.dateDE(stand))). Nichts geändert.")
        case .success(.newerInstalled(let installed, let offered)):
            return say("Eingelesen ist schon ein neuerer Stand (\(UFFmt.dateDE(installed))) als der gewählte (\(UFFmt.dateDE(offered))). Nichts geändert.")
        case .failure(let e):
            return say((e as? LocalizedError)?.errorDescription ?? e.localizedDescription)
        }
    }

    /// Fuer ZIP-Dateien der Bibliothek: viele kleine Dateien (heute ~2.700, Platz fuer das Zehnfache)
    nonisolated static let zipLimits = ZipArchive.Limits(maxEntries: 40_000, maxTotalBytes: 2 << 30, maxEntryBytes: 200 << 20)

    private func progress(_ done: Int, _ total: Int) {
        if case .importing = phase { phase = .importing(done: done, total: total) }
    }

    static func importedText(_ m: KnowledgeImportManifest) -> String {
        var t = "Eingelesen: Stand \(UFFmt.dateDE(m.stand)), \(m.subjects) Fächer, \(m.units) Einheiten, \(m.files) Dateien."
        if m.missingCount > 0 { t += " \(m.missingCount) Dateien aus katalog.json fehlten im Ordner." }
        return t
    }

    @discardableResult
    private func say(_ text: String) -> String {
        message = text
        return text
    }

    /// Bibliothek entfernen (nur sie; Notizen und Downloads bleiben)
    func remove() async {
        guard let root = Self.containerRoot else { return }
        let s = store(root)
        _ = await Task.detached { try? s.remove() }.value
        forgetSource()
        library = nil
        loadedRoot = root
        say("Die Wissensbibliothek wurde von diesem Gerät entfernt.")
    }

    // MARK: Gemerkter Ordner (Mac: Klon des Repos; "Neu einlesen" ohne erneute Auswahl)

    private static let sourceKey = "knowledgeLibrary.sourceBookmark"
    private var defaults: UserDefaults { ActiveContainer.current?.defaults ?? .standard }

    var hasRememberedSource: Bool { defaults.data(forKey: Self.sourceKey) != nil }

    private func rememberSource(_ url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Self.sourceKey)
        }
    }

    private func forgetSource() { defaults.removeObject(forKey: Self.sourceKey) }

    /// Aus dem zuletzt gewaehlten Ordner neu einlesen; nil, wenn kein Ordner gemerkt ist oder er fehlt
    func reimportRemembered(force: Bool = false) async -> String? {
        guard let data = defaults.data(forKey: Self.sourceKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            forgetSource()
            return say("Der zuletzt gewählte Ordner ist nicht mehr erreichbar. Bitte neu wählen.")
        }
        return await importFrom(url, force: force)
    }

    // MARK: Suche und Zuordnung

    /// Volltextsuche (ohne Pruefskripte); leer, wenn ausgeschaltet oder nichts eingelesen
    func search(_ query: String, limit: Int = 8) async -> [KnowledgeSearchHit] {
        guard KnowledgeLibrarySetting.isEnabled else { return [] }
        await ensureLoaded()
        guard let lib = library else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? lib.search(query, limit: limit)) ?? [] }.value
    }

    /// Einheiten zu einer geoeffneten Stud.IP-Datei (Titel bzw. Dateiname in `quellen`)
    func units(forTitle title: String?, fileName: String?) async -> [KnowledgeUnit] {
        guard KnowledgeLibrarySetting.isEnabled else { return [] }
        await ensureLoaded()
        guard let lib = library else { return [] }
        return lib.units(matchingTitle: title, fileName: fileName)
    }

    // MARK: Startparameter (nur Debug)

    /// `-UFKnowledgeImport <Ordner>` (nur Debug-Builds, Simulator/Mac): Bibliothek aus diesem Ordner einlesen, wie ueber
    /// "Ordner wählen"; `-UFKnowledgeForce YES` auch bei gleichem Stand. Release kennt diesen Weg nicht.
    func applyDebugLaunch(defaults d: UserDefaults = .standard) async {
        #if DEBUG
        guard d.string(forKey: "UFKnowledgeImport") != nil || d.string(forKey: "UFKnowledgeSearch") != nil else { return }
        for _ in 0..<80 where Self.containerRoot == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        if let path = d.string(forKey: "UFKnowledgeImport"), !path.isEmpty {
            let started = Date()
            let text = await importFrom(URL(fileURLWithPath: path, isDirectory: true), force: d.bool(forKey: "UFKnowledgeForce"))
            print("UFKnowledgeImport: \(text) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        }
        // -UFKnowledgeSearch <Begriff>: dieselbe Suche wie die Suchleiste, Ergebnis nur in der Konsole (Pruefen ohne Tippen)
        if let q = d.string(forKey: "UFKnowledgeSearch"), !q.isEmpty {
            let started = Date()
            let hits = await search(q, limit: 6)
            let shell = ShellState.knowledgeHits(hits, library: current)
            print("UFKnowledgeSearch: \(hits.count) Treffer in \(String(format: "%.3f", Date().timeIntervalSince(started))) s: "
                  + shell.prefix(3).map { "\($0.title) -> \($0.route.hash)" }.joined(separator: " | "))
        }
        #endif
    }
}

extension UFFmt {
    /// "2026-11-20" -> "20.11.2026" (sonst unveraendert)
    static func dateDE(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        guard p.count == 3 else { return iso }
        return "\(p[2]).\(p[1]).\(p[0])"
    }
}
