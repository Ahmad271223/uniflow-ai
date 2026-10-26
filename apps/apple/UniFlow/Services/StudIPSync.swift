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

    /// `configuration`: nur Tests (feste Antworten ueber `URLProtocol`); sonst fluechtig, ohne Cookie-Speicher.
    init(cookies: [HTTPCookie], host: String, configuration: URLSessionConfiguration = .ephemeral) {
        let now = Date()
        let valid = cookies.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return (host == d || host.hasSuffix("." + d)) && (c.expiresDate ?? .distantFuture) > now
        }
        cookieHeader = HTTPCookie.requestHeaderFields(with: valid)["Cookie"] ?? ""
        let config = configuration
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    private func request(_ url: URL, accept: String?) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        return r
    }

    private static func reply(_ response: URLResponse, body: Data = Data()) throws -> HTTPReply {
        guard let http = response as? HTTPURLResponse else { throw StudIPError.badResponse("keine HTTP-Antwort") }
        return HTTPReply(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                         finalURL: http.url, body: body)
    }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let (data, response) = try await session.data(for: request(url, accept: accept))
        return try Self.reply(response, body: data)
    }

    /// Dateien gehen direkt auf die Platte (Vorlesungsvideos sprengen sonst den Arbeitsspeicher)
    func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        let (temp, response) = try await session.download(for: request(url, accept: nil))
        defer { try? FileManager.default.removeItem(at: temp) }
        let reply = try Self.reply(response)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: temp, to: file)
        return reply
    }
}

/// Abgleich der eigenen Stud.IP-Dateien aufs iPad. Laeuft beim Oeffnen der App (hoechstens alle 30 Minuten)
/// und auf Knopfdruck; Dateien liegen unter Application Support/StudIP, ausgenommen vom iCloud-Backup.
///
/// Seit S3 landen Kurse und Dateien wie bei app/studip_sync.py in der lokalen Datenbank (`StudIPLibrary` ueber
/// `UniStore`, dieselbe Fassung wie fuer Learnweb), seit S4 mit Fach und Art je Kurs (`classify`), jede geladene
/// Datei mit ihrem Inhalts-Hash fuer gemeinsame Wochentests (`content_sha256`): sie erscheinen nach Fach als Module
/// in Dokumente (Modulordner mit Unterordnern nach Art) und Meine Module (Moduldetail nach Lehrwoche), dazu in der
/// Kursliste und der Uebersicht, und oeffnen sich im Editor.
/// Welche Dateien geladen werden, entscheidet die Datenbank (neu, in Stud.IP geaendert, lokal fehlend);
/// `index.json` bleibt fuer die Liste in StudIPView. Was ein Abgleich vor S3 schon geladen hat, wird beim Start
/// uebernommen, ohne neu zu laden.
/// Wie in Python halten Fehler einzelner Kurse oder Dateien den Abgleich nicht an (`StudIPError.affectsOnlyItem`,
/// bei Dateiliste und Download auch Transportfehler eines Kurses oder einer Datei wie eine Zeitueberschreitung); eine
/// abgelaufene Sitzung, kein Netz und volle Platte brechen ab. Wie `stream_download` wiederholt der Download eine
/// abgerissene Verbindung bis zu zweimal (`UniRetry` im `StudIPClient`), und eine Webseite statt der Datei wird nicht
/// gespeichert. Eine neue Fassung, die nicht ankam, laedt der naechste Abgleich (`UniStore`). Laeuft die Sitzung erst
/// beim Stundenplan ab, bleiben die Dateien, der Lauf endet aber mit "Erneut anmelden" (`.needsLogin`).
/// Am Ende jedes Laufs (auch eines gescheiterten: was bis dahin gelesen war, steht in der Datenbank) zaehlt
/// `finishedRuns` hoch; offene Seiten laden dann neu (`ufReload`), wie nach einem Sync des PC-Servers.
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
    /// Zahl der beendeten Abgleiche dieses App-Laufs; Seiten mit `ufReload` laden bei jeder Aenderung neu
    @Published private(set) var finishedRuns = 0
    @Published var selectedCourses: Set<String> = [] {
        didSet { defaults.set(Array(selectedCourses), forKey: "uniflow.studip.courses") }
    }

    let root: URL
    private var index: [String: StudIPLocalEntry] = [:]
    /// Lokales Backend, in dessen Datenbank der Abgleich schreibt
    private let host: LocalBackendHost
    private let clock: UniFlowClock
    private let defaults: UserDefaults
    /// Ordner mit dem PDF-Zwischenspeicher des Editors (`AppPaths.support`)
    private let support: URL
    /// Uebernahme des Bestands von vor S3 (laeuft beim Start; ein Abgleich wartet darauf)
    private var adoption: Task<Void, Never>?

    /// `root`: Stud.IP-Ordner (Standard Application Support/StudIP), `host`: lokales Backend, `support`: Ordner des
    /// Editors (Journal, PDF-Zwischenspeicher). Tests geben Temp-Ordner und eine eigene Datenbank mit.
    init(root: URL? = nil, host: LocalBackendHost = .shared, clock: UniFlowClock = .system, defaults: UserDefaults = .standard,
         support: URL = AppPaths.support) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? appSupport.appendingPathComponent("StudIP", isDirectory: true)
        self.host = host
        self.clock = clock
        self.defaults = defaults
        self.support = support
        selectedCourses = Set(defaults.stringArray(forKey: "uniflow.studip.courses") ?? [])
        lastRun = defaults.object(forKey: "uniflow.studip.lastRun") as? Date
        lastSummary = defaults.string(forKey: "uniflow.studip.lastSummary")
        if let d = try? Data(contentsOf: self.root.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([StudIPLocalEntry].self, from: d) {
            index = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let d = try? Data(contentsOf: self.root.appendingPathComponent("courses.json")),
           let list = try? JSONDecoder().decode([StudIPCourse].self, from: d) {
            courses = list
        }
        entries = sortedEntries()
        phase = StudIPKeychain.load().isEmpty ? .signedOut : .idle
        if !index.isEmpty { adoption = Task { await adoptExistingDownloads() } }
    }

    /// Dateien, die ein Abgleich vor S3 geladen hat (index.json), in die Datenbank uebernehmen, ohne neu zu laden.
    /// Bekannte Dateien bleiben unberuehrt; ein zweiter Lauf tut nichts. Rueckgabe: Zahl der uebernommenen Dateien.
    @discardableResult
    func adoptExistingDownloads() async -> Int {
        guard !index.isEmpty, let files = host.files, let backend = try? await host.backend() else { return 0 }
        let entries = Array(index.values), courses = self.courses, root = self.root, now = clock.nowISO
        return (try? await backend.context.database.transaction { c in
            try StudIPLibrary.adopt(c, entries: entries, courses: courses, at: now, base: Self.base, localPath: { e in
                let url = root.appendingPathComponent(e.relativePath)
                return FileManager.default.fileExists(atPath: url.path) ? files.stored(url) : nil
            })
        }) ?? 0
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

    /// Heruntergeladene Dateien loeschen. In der Datenbank bleiben die Dokumente mit ihren Notizen, nur der Ablageort
    /// faellt weg; der naechste Abgleich laedt sie neu. Die Kopien im PDF-Zwischenspeicher des Editors und die
    /// Vorschaubilder der Bibliothek (lokale Datenquelle) gehen mit, sonst blieben die Stud.IP-Dateien auf dem Geraet.
    func removeDownloads() async {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("files"))
        try? FileManager.default.removeItem(at: partialFolder)
        index = [:]
        saveIndex()
        entries = []
        if let prefix = host.files?.stored(root), let backend = try? await host.backend() {
            let ids = (try? await backend.context.database.transaction { try StudIPLibrary.forgetDownloads($0, under: prefix + "/") }) ?? []
            let cache = AppPaths.pdfDirectory(.local, root: support)
            for id in ids { try? FileManager.default.removeItem(at: cache.appendingPathComponent(LocalJournalName.safe(id) + ".pdf")) }
            AppPaths.removeThumbnails(fileIDs: ids, namespace: .local, root: support)
        }
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
        await run(client: StudIPClient(base: Self.base, transport: URLSessionStudIPTransport(cookies: cookies, host: Self.base.host ?? "")))
    }

    /// Ein Abgleich mit diesem Client (Tests: feste Antworten statt Stud.IP). Ablauf wie run_sync in
    /// app/studip_sync.py: Kurse, je Kurs die Dateiliste in die Datenbank, dann die Downloads, danach der Stundenplan
    /// derselben Kurse (`StudIPScheduleSync` mit demselben lokalen Backend, wie `auto_import` am Ende von run_sync),
    /// am Ende `sync_log`. Kein `await` innerhalb einer Transaktion: erst das Netz, dann kurz schreiben.
    func run(client: StudIPClient) async {
        guard !isRunning else { return }
        phase = .running("Kurse werden geladen …")
        defer { finishedRuns += 1 }                       // nach der letzten Phase: Seiten laden neu
        await adoption?.value
        let started = clock.nowISO
        var loaded = 0
        var database: SQLiteDatabase?
        do {
            try prepareFolder()
            let db = try await host.backend().context.database
            database = db
            let localFiles = host.files
            let uid = try await client.currentUserID()
            let list = try await client.courses(userID: uid)
            courses = list.sorted { ($0.semesterStart ?? "", $0.title) > ($1.semesterStart ?? "", $1.title) }
            try? JSONEncoder().encode(courses).write(to: root.appendingPathComponent("courses.json"), options: .atomic)
            if selectedCourses.isEmpty { selectedCourses = StudIPImport.defaultSelection(list) }

            let chosen = courses.filter { selectedCourses.contains($0.id) }
            // Fach und Art wie upsert_course (classify); die Module legt ensure_modules beim naechsten Lesen an
            try await db.transaction { try StudIPLibrary.storeCourses($0, chosen, startedAt: started) }
            var remote: [StudIPFile] = []
            var wanted: [StudIPFile] = []
            var checked = Set<String>()
            var unreadable: [Error] = []
            for (i, c) in chosen.enumerated() {
                phase = .running("Dateiliste \(i + 1) von \(chosen.count): \(c.title)")
                let files: [StudIPFile]
                do {
                    files = try await client.files(courseID: c.id)
                } catch let e as StudIPError where e.affectsOnlyItem {
                    // wie run_sync ("Fehler bei Dateiliste"): naechster Kurs; seine Dateien bleiben unveraendert
                    unreadable.append(e)
                    continue
                } catch let e as URLError where !Self.endsRun(e) {
                    // z. B. Zeitueberschreitung oder WLAN-Wechsel bei diesem Kurs: wie oben, die uebrigen Kurse, ihre
                    // Downloads und der Stundenplan kommen trotzdem
                    unreadable.append(e)
                    continue
                }
                remote += files
                checked.insert(c.id)
                // je Kurs sofort in die Datenbank: ein spaeterer Fehler verliert die schon gelesenen Kurse nicht
                wanted += try await db.transaction {
                    try StudIPLibrary.storeFiles($0, files, startedAt: started, base: Self.base, localFiles: localFiles)
                }
            }
            // kein einziger Kurs lesbar (z. B. Stud.IP gestoert): Fehlerlauf statt "0 neue Dateien"
            if let first = unreadable.first, unreadable.count == chosen.count { throw first }
            let titles = Dictionary(courses.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            let root = self.root
            let gone = StudIPImport.plan(remote: remote, local: index, checkedCourses: checked,
                                         fileExists: { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }).goneRemotely
            let download = wanted.filter(\.isDownloadable)
            var failed = 0
            // Downloads erst in einen Zwischenordner, dann an ihren Platz: ein Abbruch hinterlaesst keine halbe Datei
            // als "geladen"; Reste eines abgebrochenen Laufs gehen hier weg
            let partial = partialFolder
            let versions = localFiles.map { versionKeeper(db, $0) }
            try? FileManager.default.removeItem(at: partial)
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: partial) }
            for (i, f) in download.enumerated() {
                phase = .running("Lade \(i + 1) von \(download.count): \(f.name)")
                let temp = partial.appendingPathComponent(UUID().uuidString)
                do {
                    try await client.download(fileID: f.id, to: temp, name: f.name)
                } catch let e as StudIPError where e.affectsOnlyItem {
                    // wie run_sync ("Download-Fehler"): naechste Datei; der naechste Abgleich versucht es erneut
                    failed += 1
                    continue
                } catch let e as URLError where !Self.endsRun(e) {
                    // z. B. Zeitueberschreitung bei einer grossen Datei: nur diese Datei, die uebrigen kommen trotzdem
                    failed += 1
                    continue
                }
                let rel = StudIPImport.relativePath(for: f)
                let target = root.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Inhalts-Hash fuer gemeinsame Wochentests wie store_course_files am PC (vor dem Ersetzen, dieselben
                // Bytes); grosse Dateien nicht auf dem Hauptthread und nicht in der Transaktion
                let sha = await Task.detached(priority: .utility) { TestShare.contentHash(file: temp) }.value
                let stored = localFiles?.stored(target)
                // S7: Seitentexte der neuen Fassung aus der geladenen Datei; die alte Fassung einer Datei mit Notizen
                // aufbewahren und die Seiten zuordnen, bevor die neue sie ersetzt. Laesst sie sich nicht sichern, bleibt
                // die alte Datei und der naechste Abgleich versucht es erneut
                let prepared: FileVersionKeeper.Prepared?
                do {
                    prepared = try await versions?.prepare(fileID: f.id, newSHA: sha, newFile: temp, newPath: stored)
                } catch {
                    failed += 1
                    continue
                }
                try Self.place(temp, at: target)
                index[f.id] = StudIPLocalEntry(file: f, courseTitle: titles[f.courseID] ?? "Kurs", relativePath: rel,
                                               downloadedAt: ISO8601DateFormatter().string(from: Date()))
                saveIndex()                                   // nach jeder Datei: Abbruch verliert nichts
                if let stored {
                    let now = clock.nowISO, base = Self.base
                    let mark: @Sendable (SQLiteConnection) throws -> Void = {
                        try StudIPLibrary.markDownloaded($0, file: f, localPath: stored, sha256: sha, at: now, base: base)
                    }
                    // eine Transaktion: neue Fassung, Seitentexte, alte Fassung und umgehaengte Notizen. Scheitert sie
                    // (oder endet die App vorher), bleibt die Datenbank beim alten Stand und der naechste Abgleich laedt
                    // die Datei erneut (die alte PDF ist schon aufbewahrt)
                    do {
                        if let versions, let prepared { try await versions.commit(prepared, download: mark) } else { try await db.transaction(mark) }
                    } catch {
                        failed += 1
                        continue
                    }
                }
                loaded += 1
            }
            entries = sortedEntries()                         // Dateien schon zeigen, waehrend der Stundenplan laedt
            // Stundenplan aus Stud.IP (S5); Fehler dort brechen den Datei-Abgleich nicht ab
            let timetable = await StudIPScheduleSync(host: host).run(client: client, userID: uid, courses: chosen) { phase = .running($0) }
            let notDownloadable = remote.filter { !$0.isDownloadable }.count
            var parts = ["\(loaded) neu/geändert", "\(remote.count - notDownloadable - download.count) unverändert"]
            if notDownloadable > 0 { parts.append("\(notDownloadable) nicht herunterladbar") }
            if failed > 0 { parts.append("\(failed) nicht geladen (Fehler)") }
            if !gone.isEmpty { parts.append("\(gone.count) in Stud.IP nicht mehr vorhanden") }
            if !unreadable.isEmpty { parts.append("\(unreadable.count) \(unreadable.count == 1 ? "Kurs" : "Kurse") nicht lesbar") }
            parts += timetable.summary
            finish(summary: parts.joined(separator: ", ") + " · \(checked.count) Kurse")
            await log(database, started: started, ok: true, newFiles: loaded,
                      message: StudIPLibrary.summary(newFiles: loaded, newEvents: timetable.result?.newEvents ?? 0))
            // Sitzung erst beim Stundenplan abgelaufen: Dateien sind da, die Anmeldung muss trotzdem neu
            phase = timetable.sessionExpired ? .needsLogin : .idle
        } catch StudIPError.sessionExpired {
            entries = sortedEntries()
            await log(database, started: started, ok: false, newFiles: loaded, message: StudIPLibrary.failure(StudIPError.sessionExpired.description))
            phase = .needsLogin
        } catch {
            entries = sortedEntries()
            await log(database, started: started, ok: false, newFiles: loaded, message: StudIPLibrary.failure(error.localizedDescription))
            phase = .failed(error.localizedDescription)
        }
    }

    /// Eintrag in `sync_log` wie im `finally` von run_sync (Uebersicht "letzter Abgleich", Einstellungen)
    private func log(_ db: SQLiteDatabase?, started: String, ok: Bool, newFiles: Int, message: String) async {
        guard let db else { return }
        let finished = clock.nowISO
        _ = try? await db.transaction {
            try StudIPLibrary.log($0, startedAt: started, finishedAt: finished, ok: ok, newFiles: newFiles, message: message)
        }
    }

    private func finish(summary: String) {
        lastRun = Date()
        lastSummary = summary
        defaults.set(lastRun, forKey: "uniflow.studip.lastRun")
        defaults.set(summary, forKey: "uniflow.studip.lastSummary")
    }

    /// Zwischenordner der laufenden Downloads (im Stud.IP-Ordner, also ohne Backup)
    private var partialFolder: URL { root.appendingPathComponent(".laden", isDirectory: true) }

    /// Alte Fassungen von Dateien mit Notizen (S7): im Stud.IP-Ordner ohne Backup (Entscheidung 6), aber nicht unter
    /// `files`, damit "Dateien löschen" sie nicht entfernt (aus Stud.IP lassen sie sich nicht mehr laden)
    private func versionKeeper(_ db: SQLiteDatabase, _ files: LocalFiles) -> FileVersionKeeper {
        FileVersionKeeper(database: db, files: files, directory: files.stored(root.appendingPathComponent("Fassungen")) ?? "Fassungen",
                          source: "Stud.IP", clock: clock)
    }

    /// Transportfehler, nach dem keine weitere Datei ankaeme (kein Netz, Stud.IP nicht erreichbar, abgebrochen):
    /// der Lauf endet als Fehler. Alles andere (z. B. Zeitueberschreitung) betrifft nur den einen Kurs (Dateiliste)
    /// oder die eine Datei (Download).
    nonisolated static func endsRun(_ e: URLError) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .cancelled].contains(e.code)
    }

    /// Geladene Datei an ihren Platz (ersetzt eine aeltere Fassung), mit Dateischutz wie bisher
    nonisolated static func place(_ temp: URL, at target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
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
