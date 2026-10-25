import CryptoKit
import Foundation
import SwiftUI
import UniFlowCore

/// Letzte erfolgreiche Serverantwort je Pfad, damit Ansichten auch ohne WLAN etwas zeigen.
struct ResponseCache {
    static let shared = ResponseCache(root: AppPaths.support.appendingPathComponent("cache", isDirectory: true))
    let root: URL

    private func url(_ path: String) -> URL {
        let name = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".json")
    }

    func store(_ value: JSONValue, for path: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
    private(set) var path: String
    private let api: APIClient?

    init(path: String, api: APIClient?) {
        self.path = path
        self.api = api
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
        }
        await load()
    }

    func load() async {
        guard let api else { state = .failed("Nicht mit dem Server verbunden."); return }
        // Zwischenspeicher je Server getrennt (sonst zeigt ein anderer Server alte Daten)
        let key = api.base.absoluteString + path
        if value == nil, let cached = ResponseCache.shared.load(key) { state = .loaded(cached.0, offlineSince: cached.1) }
        do {
            let v = try await api.value(path)
            ResponseCache.shared.store(v, for: key)
            state = .loaded(v, offlineSince: nil)
        } catch {
            if let cached = ResponseCache.shared.load(key) {
                state = .loaded(cached.0, offlineSince: cached.1)
            } else {
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
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: String($0.prefix(10))) } }

    static func day(_ s: String?, style: String = "EEEE, d. MMMM") -> String {
        guard let d = date(s) else { return s ?? "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = style
        return f.string(from: d)
    }

    static func isoDay(_ d: Date) -> String { iso.string(from: d) }

    static func minutes(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        let h = Int(m) / 60, r = Int(m) % 60
        return h > 0 ? (r > 0 ? "\(h) h \(r) min" : "\(h) h") : "\(r) min"
    }

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
