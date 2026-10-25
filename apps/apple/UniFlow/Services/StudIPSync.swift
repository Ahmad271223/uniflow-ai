import Foundation
import Security
import UniFlowCore
import WebKit

// Stud.IP direkt auf dem iPad (Uebergang bis OAuth2, siehe docs/IPAD-STUDIP-SYNC.md):
// Anmeldung auf der echten Hochschulseite in einer eingebetteten Webansicht, danach Abgleich ueber die JSON:API
// mit dem Sitzungs-Cookie. Passwort und Cookie verlassen das Geraet nie; das Cookie liegt nur im Schluesselbund.

/// Sitzungs-Cookies im Schluesselbund (nur dieses Geraet, nicht in Backups/iCloud).
enum StudIPKeychain {
    private static let service = "de.uniflow.ai.studip"
    private static let account = "session-cookies"

    struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func save(_ cookies: [HTTPCookie]) throws {
        let stored = cookies.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate, secure: $0.isSecure)
        }
        let data = try JSONEncoder().encode(stored)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Schlüsselbund-Fehler \(status)"])
        }
    }

    static func load() -> [HTTPCookie] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        return stored.compactMap { s in
            var p: [HTTPCookiePropertyKey: Any] = [.name: s.name, .value: s.value, .domain: s.domain, .path: s.path]
            if let e = s.expires { p[.expires] = e }
            if s.secure { p[.secure] = "TRUE" }
            return HTTPCookie(properties: p)
        }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

/// Anfragen mit dem gespeicherten Sitzungs-Cookie. Eigene, fluechtige URLSession: keine Cookies anderer Dienste.
final class URLSessionStudIPTransport: StudIPTransport, @unchecked Sendable {
    private let session: URLSession
    private let cookieHeader: String

    init(cookies: [HTTPCookie], host: String) {
        let now = Date()
        let valid = cookies.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return (host == d || host.hasSuffix("." + d)) && (c.expiresDate ?? .distantFuture) > now
        }
        cookieHeader = HTTPCookie.requestHeaderFields(with: valid)["Cookie"] ?? ""
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        var r = URLRequest(url: url)
        r.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw StudIPError.badResponse("keine HTTP-Antwort") }
        return HTTPReply(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                         finalURL: http.url, body: data)
    }
}

/// Abgleich der eigenen Stud.IP-Dateien aufs iPad. Laeuft beim Oeffnen der App (hoechstens alle 30 Minuten)
/// und auf Knopfdruck; Dateien liegen unter Application Support/StudIP, ausgenommen vom iCloud-Backup.
@MainActor
final class StudIPSync: ObservableObject {
    static let base = URL(string: "https://studip.uni-hannover.de")!

    enum Phase: Equatable {
        case signedOut
        case idle
        case running(String)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var courses: [StudIPCourse] = []
    @Published private(set) var entries: [StudIPLocalEntry] = []
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: String?
    @Published var selectedCourses: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(selectedCourses), forKey: "uniflow.studip.courses") }
    }

    let root: URL
    private var index: [String: StudIPLocalEntry] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("StudIP", isDirectory: true)
        selectedCourses = Set(UserDefaults.standard.stringArray(forKey: "uniflow.studip.courses") ?? [])
        lastRun = UserDefaults.standard.object(forKey: "uniflow.studip.lastRun") as? Date
        lastSummary = UserDefaults.standard.string(forKey: "uniflow.studip.lastSummary")
        if let d = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([StudIPLocalEntry].self, from: d) {
            index = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let d = try? Data(contentsOf: root.appendingPathComponent("courses.json")),
           let list = try? JSONDecoder().decode([StudIPCourse].self, from: d) {
            courses = list
        }
        entries = sortedEntries()
        phase = StudIPKeychain.load().isEmpty ? .signedOut : .idle
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }

    func fileURL(_ e: StudIPLocalEntry) -> URL { root.appendingPathComponent(e.relativePath) }

    // MARK: Anmeldung

    /// Aufruf aus der Anmeldeansicht, sobald Stud.IP die Sitzung bestaetigt hat.
    func signedIn(cookies: [HTTPCookie]) {
        do {
            try StudIPKeychain.save(cookies)
            phase = .idle
            Task { await run() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Prueft mit den Cookies aus der Webansicht, ob Stud.IP die Sitzung annimmt.
    static func sessionIsValid(_ cookies: [HTTPCookie]) async -> Bool {
        let t = URLSessionStudIPTransport(cookies: cookies, host: base.host ?? "")
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0, maxRequests: 1)
        return (try? await c.currentUserID()) != nil
    }

    /// Abmelden: Cookie aus dem Schluesselbund und alle Daten der Webansicht (auch die SSO-Sitzung) loeschen.
    /// Heruntergeladene Dateien bleiben, bis der Nutzer sie entfernt.
    func signOut() async {
        StudIPKeychain.clear()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        phase = .signedOut
    }

    func removeDownloads() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("files"))
        index = [:]
        saveIndex()
        entries = []
    }

    // MARK: Abgleich

    func runIfDue() {
        guard phase == .idle || isFailed else { return }
        if let last = lastRun, Date().timeIntervalSince(last) < 30 * 60 { return }
        Task { await run() }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    func run() async {
        guard !isRunning else { return }
        let cookies = StudIPKeychain.load()
        guard !cookies.isEmpty else { phase = .signedOut; return }
        let client = StudIPClient(base: Self.base, transport: URLSessionStudIPTransport(cookies: cookies, host: Self.base.host ?? ""))
        do {
            try prepareFolder()
            phase = .running("Kurse werden geladen …")
            let uid = try await client.currentUserID()
            let list = try await client.courses(userID: uid)
            courses = list.sorted { ($0.semesterStart ?? "", $0.title) > ($1.semesterStart ?? "", $1.title) }
            try? JSONEncoder().encode(courses).write(to: root.appendingPathComponent("courses.json"), options: .atomic)
            if selectedCourses.isEmpty { selectedCourses = StudIPImport.defaultSelection(list) }

            var remote: [StudIPFile] = []
            var checked = Set<String>()
            let chosen = courses.filter { selectedCourses.contains($0.id) }
            for (i, c) in chosen.enumerated() {
                phase = .running("Dateiliste \(i + 1) von \(chosen.count): \(c.title)")
                remote += try await client.files(courseID: c.id)
                checked.insert(c.id)
            }
            let titles = Dictionary(courses.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let root = self.root
            let plan = StudIPImport.plan(remote: remote, local: index, checkedCourses: checked,
                                         fileExists: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
            var loaded = 0
            for f in plan.download {
                phase = .running("Lade \(loaded + 1) von \(plan.download.count): \(f.name)")
                let data = try await client.download(fileID: f.id)
                let rel = StudIPImport.relativePath(for: f)
                let target = root.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                index[f.id] = StudIPLocalEntry(file: f, courseTitle: titles[f.courseID] ?? "Kurs", relativePath: rel,
                                               downloadedAt: ISO8601DateFormatter().string(from: Date()))
                saveIndex()                                   // nach jeder Datei: Abbruch verliert nichts
                loaded += 1
            }
            entries = sortedEntries()
            var parts = ["\(loaded) neu/geändert", "\(plan.unchanged) unverändert"]
            if !plan.notDownloadable.isEmpty { parts.append("\(plan.notDownloadable.count) nicht herunterladbar") }
            if !plan.goneRemotely.isEmpty { parts.append("\(plan.goneRemotely.count) in Stud.IP nicht mehr vorhanden") }
            finish(summary: parts.joined(separator: ", ") + " · \(checked.count) Kurse")
            phase = .idle
        } catch StudIPError.sessionExpired {
            entries = sortedEntries()
            phase = .needsLogin
        } catch {
            entries = sortedEntries()
            phase = .failed(error.localizedDescription)
        }
    }

    private func finish(summary: String) {
        lastRun = Date()
        lastSummary = summary
        UserDefaults.standard.set(lastRun, forKey: "uniflow.studip.lastRun")
        UserDefaults.standard.set(summary, forKey: "uniflow.studip.lastSummary")
    }

    /// Ordner anlegen und vom iCloud-Backup ausnehmen (Vorlesungsunterlagen lassen sich jederzeit neu laden).
    private func prepareFolder() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var r = root
        try r.setResourceValues(values)
    }

    private func saveIndex() {
        let list = index.values.sorted { $0.id < $1.id }
        try? JSONEncoder().encode(list).write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    private func sortedEntries() -> [StudIPLocalEntry] {
        index.values.sorted { ($0.courseTitle, $0.folderPath, $0.name) < ($1.courseTitle, $1.folderPath, $1.name) }
    }
}
