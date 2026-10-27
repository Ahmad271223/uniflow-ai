import SwiftUI
import UniFlowCore

/// Zustand der lokalen Daten fuer die Diagnose (ohne Inhalte: keine Notizen, Dateinamen, Zugangsdaten, Schluessel oder
/// Sitzungen; nur Zahlen, Groessen und die Namen beschaedigter Dateien des Journals).
struct Diagnostics {
    var appVersion: String
    var osVersion: String
    var journalBytes: Int64
    var cacheBytes: Int64
    var documentsWithUnsent: Int
    var unsentPages: Int
    var damaged: [String]
    /// Journal-Ordner, die sich nicht lesen liessen (vorher stillschweigend uebersprungen)
    var unreadable: [String] = []
    /// Zeitpunkt der Erhebung: eine Momentaufnahme der Dateien (jede Datei atomar geschrieben, `JournalScan`)
    var collectedAt = Date()

    /// Erhebung abseits des Hauptthreads (Groessen und Journale koennen bei vielen Dateien dauern; die Oberflaeche
    /// zeigt bis dahin "…")
    @MainActor
    static func collect() async -> Diagnostics {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = UIDevice.current.systemVersion
        let journal = AppPaths.journal, cache = ResponseCache.shared.root
        return await Task.detached(priority: .utility) {
            collect(journal: journal, cache: cache, appVersion: version, osVersion: os)
        }.value
    }

    /// Erhebung fuer einen Journal- und einen Zwischenspeicher-Ordner (Tests: Temp-Ordner)
    nonisolated static func collect(journal: URL, cache: URL, appVersion: String, osVersion: String) -> Diagnostics {
        let scan = JournalScan.scan(store: FileBlobStore(root: journal))
        return Diagnostics(appVersion: appVersion, osVersion: osVersion,
                           journalBytes: folderSize(journal), cacheBytes: folderSize(cache),
                           documentsWithUnsent: scan.documentsWithUnsent, unsentPages: scan.unsentPages,
                           damaged: scan.damaged, unreadable: scan.unreadable)
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Zeilen zu den lokalen Daten fuer den Diagnosetext (Einstellungen, "Kopieren")
    var reportLines: [String] {
        let time = DateFormatter.localizedString(from: collectedAt, dateStyle: .none, timeStyle: .medium)
        var lines = [
            "Lokale Notizen: \(ByteCountFormatter.string(fromByteCount: journalBytes, countStyle: .file))",
            "Zwischenspeicher: \(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))",
            "Ungesendete Seiten: \(unsentPages) in \(documentsWithUnsent) Dokumenten",
            "Beschädigte lokale Dateien: \(damaged.isEmpty ? "keine" : damaged.joined(separator: ", "))",
        ]
        if !unreadable.isEmpty { lines.append("Nicht lesbare lokale Ordner: \(unreadable.joined(separator: ", "))") }
        lines.append("Stand der lokalen Daten: \(time) (Momentaufnahme)")
        return lines
    }

    /// Adresse fuer den Diagnosetext: nur Schema, Rechner und Port (ohne Benutzer, Passwort, Pfad und Abfrage)
    static func address(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme else { return "–" }
        var c = URLComponents()
        c.scheme = scheme
        c.host = url.host
        c.port = url.port
        return c.string ?? "–"
    }
}
