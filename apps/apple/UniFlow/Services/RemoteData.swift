import CryptoKit
import Foundation
import SwiftUI
import UniFlowCore

/// Letzte erfolgreiche Serverantwort je Pfad, damit Ansichten auch ohne WLAN etwas zeigen.
struct ResponseCache {
    /// Zwischenspeicher des aktiven Containers (je Apple-Nutzer und Hochschule getrennt)
    static var shared: ResponseCache { ActiveContainer.current?.cache ?? ResponseCache(root: DataContainerLayout.Folder.cache.url(in: ContainerPaths.none)) }
    let root: URL

    private func url(_ path: String) -> URL {
        let name = SolutionSHA256.hexString(Array(SHA256.hash(data: Data(path.utf8)).prefix(16)))
        return root.appendingPathComponent(name + ".json")
    }

    func store(_ value: JSONValue, for path: String) {
        // nur im bestehenden Container: ist er inzwischen geloescht ("Konto löschen", "Daten dieser Hochschule
        // löschen", waehrend die Antwort unterwegs war), entsteht kein Ordner <Container>/cache ohne Kennzeichnung
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try? value.serialized().write(to: url(path), options: .atomic)     // nur Zwischenspeicher: Fehler sind unkritisch
    }

    func load(_ path: String) -> (JSONValue, Date)? {
        let u = url(path)
        guard let data = try? Data(contentsOf: u), let v = try? JSONValue.parse(data) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? Date.distantPast
        return (v, date)
    }
}

/// Lade-, Fehler-, Offline- und Leerzustand einer Serverabfrage.
@MainActor
final class RemoteData: ObservableObject {
    enum State {
        case loading
        case loaded(JSONValue, offlineSince: Date?)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// letzter Fehler war ein Netzfehler (Server nicht erreichbar), keine Fehlerantwort des Servers – wie
    /// /Failed to fetch|NetworkError|Load failed/ in route() (app.js)
    @Published private(set) var failedOffline = false
    /// Neu laden ist gescheitert, waehrend schon ein Stand da war: der bleibt stehen, dazu diese Meldung (vorher
    /// ersetzte die Fehlerkarte den Inhalt, auch bei einer kurzen Stoerung)
    @Published private(set) var reloadError: String?
    private(set) var path: String
    private let api: APIClient?
    /// Zwischenspeicher des Containers, in dem die Ansicht entstand (eine spaete Antwort landet nie in einem anderen)
    private let cache: ResponseCache
    /// Nummer des juengsten Ladevorgangs: eine aeltere Antwort (zwei Ladevorgaenge zugleich, Pfadwechsel waehrend des
    /// Ladens) ueberschreibt nie den neueren Stand
    private var generation = 0

    init(path: String, api: APIClient?, cache: ResponseCache = .shared) {
        self.path = path
        self.api = api
        self.cache = cache
    }

    var value: JSONValue? {
        if case .loaded(let v, _) = state { return v }
        return nil
    }

    /// Anderen Pfad laden (z. B. naechste Woche im Kalender).
    func reload(path newPath: String) async {
        if newPath != path {
            path = newPath
            state = .loading
            reloadError = nil
        }
        await load()
    }

    func load() async {
        guard let api else { failedOffline = true; state = .failed("Nicht mit dem Server verbunden."); return }
        generation += 1
        let mine = generation
        // Zwischenspeicher je Server getrennt (sonst zeigt ein anderer Server alte Daten)
        let key = api.base.absoluteString + path
        if value == nil, let cached = cache.load(key) { state = .loaded(cached.0, offlineSince: cached.1) }
        do {
            let v = try await api.value(path)
            guard mine == generation else { return }                      // inzwischen neuer geladen: veraltet
            cache.store(v, for: key)
            reloadError = nil
            state = .loaded(v, offlineSince: nil)
        } catch {
            guard mine == generation else { return }
            // nur bei Netzfehlern den letzten Stand als "Offline" zeigen; eine Fehlerantwort (401, 500 …) ist kein Offline
            let network = !(error is APIError)
            if network, let cached = cache.load(key) {
                state = .loaded(cached.0, offlineSince: cached.1)
            } else if case .loaded = state {
                // schon ein Stand da (Neu laden nach einer Aktion, Abgleich, Tageswechsel): behalten und melden
                reloadError = error.localizedDescription
            } else {
                failedOffline = network
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Kurzzugriffe fuer Ansichten

extension JSONValue {
    func s(_ key: String) -> String? { self[key]?.string }
    func n(_ key: String) -> Double? { self[key]?.double }
    func i(_ key: String) -> Int? { self[key]?.int }
    func list(_ key: String) -> [JSONValue] { self[key]?.array ?? [] }
    var items: [JSONValue] { array ?? [] }
}

/// Eindeutige ID fuer Listen aus JSON-Zeilen.
struct Row: Identifiable {
    let id: String
    let value: JSONValue

    static func rows(_ list: [JSONValue], key: String = "id") -> [Row] {
        var seen = Set<String>()
        return list.enumerated().map { i, v in
            var id = v[key].map { $0.string ?? JSONValue.format($0.double ?? Double(i)) } ?? "\(i)"
            if !seen.insert(id).inserted { id += "#\(i)" }
            return Row(id: id, value: v)
        }
    }
}

enum Fmt {
    /// Zeitzone aller Tage der Oberflaeche: dieselbe wie im lokalen Backend (`UniFlowClock`, Europe/Berlin) und am
    /// PC-Server. Mit der Zeitzone des Geraets lag "heute" auf einem iPad ausserhalb Berlins um Mitternacht einen Tag
    /// neben dem Backend (Lernplan ab gestern, Tagesmarkierung am Vortag).
    static let zone = TimeZone(identifier: "Europe/Berlin") ?? .current

    /// Kalender fuer Tagesrechnungen (Woche ab Montag) in `zone`
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2
        return c
    }()

    /// Datumsformat in `zone` (deutsche Namen, sonst `locale`)
    static func formatter(_ format: String, locale: String = "de_DE") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    static let iso = formatter("yyyy-MM-dd", locale: "en_US_POSIX")

    static func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: String($0.prefix(10))) } }

    static func isoDay(_ d: Date) -> String { iso.string(from: d) }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        return f.localizedString(for: d, relativeTo: Date())
    }
}

extension Color {
    /// Modulfarbe aus `#rrggbb`, sonst Akzentfarbe.
    init(hex: String?) {
        if let c = UIColor(hex: hex) { self = Color(uiColor: c) } else { self = .accentColor }
    }
}
