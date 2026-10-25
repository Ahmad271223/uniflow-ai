import Foundation

/// Datenquelle eines Dokuments: das lokale Backend des Geraets oder ein bestimmter eigener UniFlow-Server.
///
/// Journal (offene Operationen, Basisversionen) und Zwischenspeicher liegen je Datenquelle getrennt. Sonst wuerde
/// beim Wechsel PC <-> lokal ein Stand gegen die falsche Quelle hochgeladen oder als Basis fuer eine Zusammenfuehrung
/// genommen: die Datei-IDs beider Quellen koennen gleich sein, ihre Notizversionen haben nichts miteinander zu tun.
public struct DataSourceNamespace: Hashable, Sendable, CustomStringConvertible {
    /// Ordnername: "local" oder "server-<host>-<port>" (nur a-z, 0-9, ".", "-", "_")
    public let id: String

    public static let local = DataSourceNamespace(id: "local")

    /// Schema der Basis-URL des lokalen Backends (`uniflow-local://device/`)
    public static let localScheme = "uniflow-local"

    init(id: String) { self.id = id }

    /// Namensraum zu einem Ordnernamen unter `spaces/` (z. B. fuer die Diagnose)
    public static func named(_ id: String) -> DataSourceNamespace { DataSourceNamespace(id: id) }

    /// Eigener Server; ohne bekannte Adresse "server"
    public static func server(host: String?, port: Int?) -> DataSourceNamespace {
        guard let host, !host.isEmpty else { return DataSourceNamespace(id: "server") }
        let safe = host.lowercased().unicodeScalars.map { c -> String in
            let ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "-"
            return ok ? String(c) : "_"
        }.joined()
        return DataSourceNamespace(id: "server-" + safe + (port.map { "-\($0)" } ?? ""))
    }

    /// Aus der Basis-URL des `APIClient`
    public init(base: URL) {
        if base.scheme?.lowercased() == DataSourceNamespace.localScheme {
            self = .local
        } else {
            self = .server(host: base.host, port: base.port)
        }
    }

    /// Pfad im Journal-Speicher: `spaces/<id>`
    public var journalPrefix: String { "spaces/\(id)" }

    public var isLocal: Bool { self == .local }

    public var description: String { id }
}

/// Einmaliger Umzug der Journale aus der Zeit vor den Namensraeumen.
///
/// Bis S2 lagen alle Journale unter `<root>/docs/<id>` und gehoerten zum eigenen Server (ein lokales Backend gab es
/// nicht). Sie ziehen nach `<root>/spaces/<server>/docs/<id>` um – je Dokument ein Umbenennen im selben Ordnerbaum,
/// also atomar: ein Dokument liegt immer vollstaendig am alten oder am neuen Ort. Gibt es am Ziel schon ein Journal
/// desselben Dokuments, bleibt das alte unberuehrt liegen und wird gemeldet (nie ueberschrieben). Ein zweiter Lauf
/// tut nichts.
public enum JournalNamespaceMigration {
    public struct Report: Equatable, Sendable {
        /// umgezogene Dokumentordner
        public var moved: [String] = []
        /// am alten Ort geblieben, weil das Ziel schon existiert
        public var kept: [String] = []
    }

    /// `root` ist der Ordner des Journal-Speichers (FileBlobStore-Wurzel). Fehler beim Umbenennen werden geworfen;
    /// was bis dahin umgezogen ist, bleibt am neuen Ort, der Rest am alten (der naechste Lauf macht weiter).
    @discardableResult
    public static func run(root: URL, owner: DataSourceNamespace, fileManager fm: FileManager = .default) throws -> Report {
        try moveEntries(from: root.appendingPathComponent("docs", isDirectory: true),
                        to: root.appendingPathComponent(owner.journalPrefix, isDirectory: true).appendingPathComponent("docs", isDirectory: true),
                        fileManager: fm)
    }

    /// Alle Eintraege eines Ordners in einen anderen verschieben (z. B. auch den PDF-Zwischenspeicher).
    @discardableResult
    public static func moveEntries(from source: URL, to target: URL, fileManager fm: FileManager = .default) throws -> Report {
        var report = Report()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { return report }
        let entries = try fm.contentsOfDirectory(atPath: source.path).filter { !$0.hasPrefix(".") }.sorted()
        if !entries.isEmpty { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
        for name in entries {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) {
                report.kept.append(name)
                continue
            }
            try fm.moveItem(at: from, to: to)
            report.moved.append(name)
        }
        // alter Ordner nur weg, wenn nichts mehr darin liegt (versteckte Systemdateien zaehlen nicht)
        if report.kept.isEmpty, (try? fm.contentsOfDirectory(atPath: source.path).filter { !$0.hasPrefix(".") })?.isEmpty == true {
            try? fm.removeItem(at: source)
        }
        return report
    }
}
