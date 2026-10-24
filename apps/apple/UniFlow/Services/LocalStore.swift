import Foundation

/// Lokaler Speicher pro Datei (Application Support/UniFlow/<fileId>/): PDF-Kopie und letzter Notizstand.
/// Jede Aenderung landet hier sofort, damit nach Absturz oder ohne WLAN nichts verloren geht.
struct LocalDocState: Codable {
    var root: JSONValue
    var version: Int
    var dirtyPages: [String]
}

enum LocalStore {
    private static var baseDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UniFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func dir(for fileId: String) -> URL {
        let d = baseDir.appendingPathComponent(fileId, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func pdfURL(_ fileId: String) -> URL { dir(for: fileId).appendingPathComponent("document.pdf") }
    private static func stateURL(_ fileId: String) -> URL { dir(for: fileId).appendingPathComponent("annotations.json") }

    static func loadState(_ fileId: String) -> LocalDocState? {
        guard let d = try? Data(contentsOf: stateURL(fileId)) else { return nil }
        return try? JSONDecoder().decode(LocalDocState.self, from: d)
    }

    static func saveState(_ state: LocalDocState, _ fileId: String) {
        guard let d = try? JSONEncoder().encode(state) else { return }
        try? d.write(to: stateURL(fileId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
