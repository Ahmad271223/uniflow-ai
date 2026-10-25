import SwiftUI
import UniFlowCore

/// Zustand der lokalen Daten fuer die Diagnose (ohne Inhalte).
struct Diagnostics {
    var appVersion: String
    var osVersion: String
    var journalBytes: Int64
    var cacheBytes: Int64
    var documentsWithUnsent: Int
    var unsentPages: Int
    var damaged: [String]

    @MainActor
    static func collect() async -> Diagnostics {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = UIDevice.current.systemVersion
        return await Task.detached(priority: .utility) {
            let store = FileBlobStore(root: AppPaths.journal)
            var docs = 0, pages = 0
            var damaged: [String] = []
            // alle Datenquellen (lokal, eigene Server) und ein noch nicht umgezogener alter Ort
            let spaces: [DataSourceNamespace?] = [nil] + ((try? store.list("spaces")) ?? []).sorted().map { DataSourceNamespace.named($0) }
            for space in spaces {
                for dir in (try? store.list(LocalJournal.documentsDirectory(space))) ?? [] {
                    let id = LocalJournal.documentID(forDirectory: dir)
                    guard let snap = try? LocalJournal(store: store, documentID: id, namespace: space).load() else { continue }
                    let unsent = snap.pages.filter { $0.value.localRev > (snap.acked[$0.key] ?? 0) }.count + (snap.metaRev > snap.metaAckedRev ? 1 : 0)
                    if unsent > 0 { docs += 1; pages += unsent }
                    damaged += snap.damaged.map { "\(space.map { $0.id + "/" } ?? "")\(dir)/\($0)" }
                }
            }
            return Diagnostics(appVersion: version, osVersion: os,
                               journalBytes: folderSize(AppPaths.journal), cacheBytes: folderSize(ResponseCache.shared.root),
                               documentsWithUnsent: docs, unsentPages: pages, damaged: damaged)
        }.value
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
