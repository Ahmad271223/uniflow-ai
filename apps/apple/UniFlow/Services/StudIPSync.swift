import Foundation
import Security
import UniFlowCore
import WebKit

// Stud.IP direkt auf dem iPad (Uebergang bis OAuth2, siehe docs/IPAD-STUDIP-SYNC.md):
// Anmeldung auf der echten Hochschulseite in einer eingebetteten Webansicht, danach Abgleich ueber die JSON:API
// mit dem Sitzungs-Cookie. Passwort und Cookie verlassen das Geraet nie; das Cookie liegt nur im Schluesselbund.

/// Sitzungs-Cookies im Schluesselbund (`KeychainStore`, nur dieses Geraet, nicht in Backups/iCloud), je Container
/// (Apple-Nutzer, Hochschule) ein eigener Eintrag: `session-cookies.<container-uuid>`. Kein Rueckfall auf einen
/// anderen Container. Eine Neuinstallation leert den ganzen Dienst (`removeLeftoversOfEarlierInstallation`).
struct StudIPCookieStore: Sendable {
    static let service = "de.uniflow.ai.studip"
    /// Eintrag aus der Zeit vor den Containern (zieht beim Umzug in den LUH-Container des Nutzers)
    static let legacyAccount = "session-cookies"
    /// Merker dieser Installation (UserDefaults verschwinden mit der App, der Schluesselbund nicht)
    static let installedKey = "uniflow.studip.installed"

    let service: String
    let account: String
    private var store: KeychainStore { KeychainStore(service: service) }

    init(service: String = StudIPCookieStore.service, account: String) {
        self.service = service
        self.account = account
    }

    /// Neuinstallation: Sitzungen einer geloeschten App (Container-UUIDs folgen fest aus Apple-ID und Hochschule) nie
    /// uebernehmen, sonst galt Stud.IP nach einer Neuinstallation sofort als verbunden. Ohne Merker wird der ganze
    /// Dienst geleert (auch der Alt-Eintrag `session-cookies`); der Merker erst danach. Rueckgabe: geleert oder nicht
    /// noetig (gesperrter Schluesselbund: false, beim naechsten Start erneut).
    @discardableResult
    static func removeLeftoversOfEarlierInstallation(service: String = StudIPCookieStore.service, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: installedKey) else { return true }
        guard KeychainStore(service: service).removeAll() else { return false }
        defaults.set(true, forKey: installedKey)
        return true
    }

    /// Eintrag eines Containers
    init(service: String = StudIPCookieStore.service, container: UUID) {
        self.init(service: service, account: Self.legacyAccount + "." + container.uuidString)
    }

    struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
    }

    func save(_ cookies: [HTTPCookie]) throws {
        let stored = cookies.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate, secure: $0.isSecure)
        }
        try saveRaw(try JSONEncoder().encode(stored))
    }

    func load() -> [HTTPCookie] {
        guard let data = loadRaw(), let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        return stored.compactMap { s in
            var p: [HTTPCookiePropertyKey: Any] = [.name: s.name, .value: s.value, .domain: s.domain, .path: s.path]
            if let e = s.expires { p[.expires] = e }
            if s.secure { p[.secure] = "TRUE" }
            return HTTPCookie(properties: p)
        }
    }

    func clear() { store.remove(account) }

    /// Inhalt unveraendert (fuer den Umzug)
    func loadRaw() -> Data? { store.data(account) }

    func saveRaw(_ data: Data) throws { try store.write(data, account: account) }

    /// Umzug: alten Eintrag in diesen verschieben (wiederholbar; ein vorhandener Eintrag wird nicht ueberschrieben)
    func adopt(_ legacy: StudIPCookieStore) throws {
        guard let data = legacy.loadRaw() else { return }
        if loadRaw() == nil { try saveRaw(data) }
        legacy.clear()
    }
}

/// Sitzungs-Cookies des aktiven Containers (fuer Stellen ohne eigenen StudIPSync)
enum StudIPKeychain {
    static func load() -> [HTTPCookie] { ActiveContainer.current?.cookies.load() ?? [] }
}

/// Stud.IP-Anfragen mit dem gespeicherten Sitzungs-Cookie ueber dieselbe URLSession-Umsetzung wie Learnweb und LSF
/// (`URLSessionUniTransport`: eigene fluechtige URLSession je Lauf, Cookies je Zieladresse, nur HTTPS auf Stud.IP und
/// den Anmeldeseiten der LUH, Downloads direkt in die Datei). Hier nur die Uebersetzung in `StudIPTransport`.
final class URLSessionStudIPTransport: StudIPTransport, @unchecked Sendable {
    private let transport: URLSessionUniTransport

    /// `configuration`: nur Tests (feste Antworten ueber `URLProtocol`); sonst fluechtig, ohne Cookie-Speicher.
    init(cookies: [HTTPCookie], host: String, configuration: URLSessionConfiguration = .ephemeral) {
        transport = URLSessionUniTransport(cookies: cookies, allowedDomains: [host] + URLSessionUniTransport.studipDomains,
                                           configuration: configuration)
    }

    private static func reply(_ r: UniResponse) -> HTTPReply {
        HTTPReply(status: r.status, contentType: r.headers["content-type"] ?? "", finalURL: r.finalURL, body: r.body)
    }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        Self.reply(try await transport.send(UniRequest(url: url, headers: accept.map { ["Accept": $0] } ?? [:])))
    }

    /// Dateien gehen direkt auf die Platte (Vorlesungsvideos sprengen sonst den Arbeitsspeicher)
    func download(_ url: URL, to file: URL) async throws -> HTTPReply {
        Self.reply(try await transport.download(UniRequest(url: url), to: file))
    }
}

/// Abgleich der eigenen Stud.IP-Dateien aufs iPad. Laeuft beim Oeffnen der App (hoechstens alle 30 Minuten)
/// und auf Knopfdruck; Dateien liegen im Container (Apple-Nutzer, Hochschule) unter `StudIP/`, ausgenommen vom
/// iCloud-Backup. Je Container ein eigener Abgleich mit eigenem Sitzungs-Cookie und eigener Webansicht.
///
/// Seit S3 landen Kurse und Dateien wie bei app/studip_sync.py in der lokalen Datenbank (`StudIPLibrary` ueber
/// `UniStore`, dieselbe Fassung wie fuer Learnweb), seit S4 mit Fach und Art je Kurs (`classify`), jede geladene
/// Datei mit ihrem Inhalts-Hash (`content_sha256`, neue Fassung mit gleichem Inhalt, S7): sie erscheinen nach Fach als
/// Module in Dokumente (Modulordner mit Unterordnern nach Art) und Meine Module (Moduldetail nach Lehrwoche), dazu in
/// der Kursliste und der Uebersicht, und oeffnen sich im Editor.
/// Die Datenbank ist das eine Register: sie entscheidet, welche Dateien geladen werden (neu, in Stud.IP geaendert,
/// lokal fehlend), und liefert die Liste in StudIPView (`entries`) sowie "nicht mehr vorhanden". Was ein Abgleich vor
/// S3 geladen hat (index.json), wird einmal uebernommen, ohne neu zu laden; danach ist index.json weg.
/// Welche Kurse abgeglichen werden: `StudIPImport.selection` (neue Kurse des juengsten Semesters kommen dazu).
/// Wie in Python halten Fehler einzelner Kurse oder Dateien den Abgleich nicht an (`StudIPError.affectsOnlyItem`,
/// bei Dateiliste und Download auch Transportfehler eines Kurses oder einer Datei wie eine Zeitueberschreitung); eine
/// abgelaufene Sitzung, kein Netz und ein voller Speicher (`DeviceStorage`, vor jeder Datei geprueft) brechen ab. Wie `stream_download` wiederholt der Download eine
/// abgerissene Verbindung bis zu zweimal (`UniRetry` im `StudIPClient`), und eine Webseite oder leere Antwort statt
/// der Datei wird nicht gespeichert. Ablage, Hash und Eintrag jeder Datei laufen ueber `UniDownloads`, dieselbe
/// Fassung wie fuer Learnweb, ebenso seit S7 die alte Fassung einer Datei mit Notizen (unter `Fassungen`, Notizen auf
/// den passenden Seiten der neuen) und die Seitentexte fuer die Suche (PDFKit ueber `host.files`). Eine neue Fassung,
/// die nicht ankam, laedt der naechste Abgleich (`UniStore`). Laeuft die Sitzung erst beim Stundenplan ab, bleiben die
/// Dateien, der Lauf endet aber mit "Erneut anmelden" (`.needsLogin`).
/// "Daten dieser Hochschule löschen" und "Konto löschen" halten einen laufenden Abgleich an (`stop`) und warten auf
/// sein Ende, bevor sie den Container entfernen.
/// Am Ende jedes Laufs (auch eines gescheiterten: was bis dahin gelesen war, steht in der Datenbank) zaehlt
/// `finishedRuns` hoch; offene Seiten laden dann neu (`ufReload`), wie nach einem Sync des PC-Servers.
/// Nach dem Stundenplan kommen die Listen der Opencast-Aufzeichnungen (`recordings`, nur die Listen, nie ein Video;
/// Listen in der Datenbank, geladene Videos unter `Aufzeichnungen` im Container). `stop` haelt auch laufende Downloads
/// von Aufzeichnungen an.
/// Im Hintergrund (S8, `BackgroundSyncController`) laeuft derselbe Abgleich: kurz nur mit den Listen (`scope: .lists`,
/// Kurse, Dateilisten, Stundenplan; keine Downloads, keine Aufzeichnungen), lang mit Netz wie beim Oeffnen. Ein Lauf
/// nur mit Listen setzt nicht `lastRun` (sonst wartete das Laden der neuen Dateien beim Oeffnen 30 Minuten), sondern
/// merkt sich wartende Downloads (`downloadsPending`): der naechste Abgleich beim Oeffnen kommt dann sofort. Eine
/// abgelaufene Sitzung merkt sich der Container (`sessionKnownExpired`) bis zur neuen Anmeldung; der Hintergrund
/// versucht es damit nicht erneut und meldet sie nur einmal.
@MainActor
final class StudIPSync: ObservableObject {
    /// Stud.IP der LUH aus dem Hochschul-Profil (die eine Quelle der Adresse)
    static let base = UniversityKey.luh.profile.studipBase!

    enum Phase: Equatable {
        case signedOut
        case idle
        case running(String)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published private(set) var courses: [StudIPCourse] = []
    /// geladene Dateien aus der Datenbank (`StudIPLibrary.downloadedFiles`, das eine Register; vorher index.json)
    @Published private(set) var entries: [StudIPLibrary.DownloadedFile] = []
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: String?
    /// Zahl der beendeten Abgleiche dieses App-Laufs; Seiten mit `ufReload` laden bei jeder Aenderung neu
    @Published private(set) var finishedRuns = 0
    @Published var selectedCourses: Set<String> = [] {
        didSet { defaults.set(Array(selectedCourses), forKey: "uniflow.studip.courses") }
    }
    /// Kurse, die der Abgleich schon gesehen hat (abgewaehlt = bekannt und nicht ausgewaehlt, `StudIPImport.selection`);
    /// nil bis zum ersten Abgleich mit dieser Regel
    private var knownCourses: Set<String>? {
        didSet { defaults.set(knownCourses.map(Array.init), forKey: "uniflow.studip.knownCourses") }
    }

    /// Einstellungen des Abgleichs (je Container in dessen UserDefaults-Suite)
    static let defaultsKeys = ["uniflow.studip.courses", "uniflow.studip.knownCourses", "uniflow.studip.lastRun", "uniflow.studip.lastSummary"]

    /// Merker im Container seit S8 (aus der Zeit vor den Containern gibt es sie nicht, darum nicht in `defaultsKeys`)
    enum Keys {
        /// ein Abgleich endete mit "Anmeldung abgelaufen"; weg mit der neuen Anmeldung oder einem Lauf ohne Fehler
        static let sessionExpired = "uniflow.studip.sessionExpired"
        /// ein Lauf nur mit Listen fand Dateien zum Laden; weg nach einem vollen Lauf ohne Fehler
        static let downloadsPending = "uniflow.studip.downloadsPending"
    }

    /// Wie ein Lauf endete (Hintergrund: Stand und Benachrichtigung)
    enum RunEnd: Equatable {
        case completed
        case cancelled
        case sessionExpired
        case failed(String)
    }

    let root: URL
    /// Hochschule des Containers; Stud.IP gibt es nur an der LUH
    let university: UniversityKey
    /// Sitzungs-Cookie dieses Containers im Schluesselbund
    let cookies: StudIPCookieStore
    /// Datenspeicher der Anmelde-Webansicht dieses Containers (`WKWebsiteDataStore(forIdentifier:)`)
    let websiteDataStore: WKWebsiteDataStore
    /// Opencast-Aufzeichnungen: Listen in derselben Datenbank des Containers, geladene Videos (nur auf Wunsch) unter
    /// `root/Aufzeichnungen` ohne Backup
    let recordings: RecordingLibrary
    /// Bestand eines Abgleichs von vor S3 (index.json): einmal in die Datenbank uebernehmen, danach geloescht
    private var legacyIndex: [StudIPLocalEntry] = []
    /// Lokales Backend, in dessen Datenbank der Abgleich schreibt
    private let host: LocalBackendHost
    private let clock: UniFlowClock
    private let defaults: UserDefaults
    /// Ordner mit dem PDF-Zwischenspeicher des Editors (`AppPaths.support`)
    private let support: URL
    /// Uebernahme des Bestands von vor S3 (laeuft beim Start; ein Abgleich wartet darauf)
    private var adoption: Task<Void, Never>?
    /// Container, in den der Abgleich schreibt; vor jedem Schreiben einer Datei geprueft (`UniDownloads`). nil nur
    /// fuer eine Ablage ohne Container (Tests mit eigenem Ordner)
    private let container: DataContainerLayout?
    /// laufender Abgleich (zum Anhalten vor dem Loeschen des Containers)
    private var current: Task<RunEnd, Never>?
    /// angehalten (Container wird geloescht): kein weiterer Abgleich
    private(set) var stopped = false

    /// `root`: Stud.IP-Ordner (in der App `<Container>/StudIP`), `host`: lokales Backend, `support`: Ordner des
    /// Editors (Journal, PDF-Zwischenspeicher), `defaults`: Einstellungen des Containers, `cookies` und
    /// `websiteDataStore`: Anmeldung dieses Containers. Die App baut je Container einen eigenen Abgleich
    /// (`ContainerManager`, mit `container`); Tests geben Temp-Ordner und eine eigene Datenbank mit.
    init(root: URL? = nil, host: LocalBackendHost = .shared, clock: UniFlowClock = .system, defaults: UserDefaults = .standard,
         support: URL = AppPaths.support, university: UniversityKey = .luh, cookies: StudIPCookieStore? = nil,
         websiteDataStore: WKWebsiteDataStore? = nil, container: DataContainerLayout? = nil) {
        self.container = container
        self.root = root ?? DataContainerLayout.Folder.studip.url(in: AppPaths.support)
        self.host = host
        self.clock = clock
        self.defaults = defaults
        self.support = support
        self.university = university
        self.cookies = cookies ?? ActiveContainer.current?.cookies ?? StudIPCookieStore(account: "ohne-container")
        self.websiteDataStore = websiteDataStore ?? .nonPersistent()
        recordings = RecordingLibrary(root: self.root.appendingPathComponent(RecordingFiles.folder, isDirectory: true), host: host,
                                      container: container)
        selectedCourses = Set(defaults.stringArray(forKey: "uniflow.studip.courses") ?? [])
        knownCourses = defaults.stringArray(forKey: "uniflow.studip.knownCourses").map(Set.init)
        lastRun = defaults.object(forKey: "uniflow.studip.lastRun") as? Date
        lastSummary = defaults.string(forKey: "uniflow.studip.lastSummary")
        if let d = try? Data(contentsOf: legacyIndexURL), let list = try? JSONDecoder().decode([StudIPLocalEntry].self, from: d) {
            legacyIndex = list
        }
        if let d = try? Data(contentsOf: self.root.appendingPathComponent("courses.json")),
           let list = try? JSONDecoder().decode([StudIPCourse].self, from: d) {
            courses = list
        }
        phase = offersStudIP && !self.cookies.load().isEmpty ? .idle : .signedOut
        // erst den alten Bestand uebernehmen (einmal), dann die Liste aus der Datenbank
        adoption = Task {
            if !legacyIndex.isEmpty { await adoptExistingDownloads() }
            await refreshEntries()
        }
    }

    /// index.json aus der Zeit vor S3 (nur noch fuer die einmalige Uebernahme)
    private var legacyIndexURL: URL { root.appendingPathComponent("index.json") }

    /// Dateien, die ein Abgleich vor S3 geladen hat (index.json), in die Datenbank uebernehmen, ohne neu zu laden;
    /// danach ist index.json weg (vorher lief die "einmalige" Uebernahme bei jedem Start). Bekannte Dateien bleiben
    /// unberuehrt. Rueckgabe: Zahl der uebernommenen Dateien.
    @discardableResult
    func adoptExistingDownloads() async -> Int {
        guard !legacyIndex.isEmpty, let files = host.files, let backend = try? await host.backend() else { return 0 }
        let entries = legacyIndex, courses = self.courses, root = self.root, now = clock.nowISO
        let adopted = try? await backend.context.database.transaction { c in
            try StudIPLibrary.adopt(c, entries: entries, courses: courses, at: now, base: Self.base, localPath: { e in
                let url = root.appendingPathComponent(e.relativePath)
                return FileManager.default.fileExists(atPath: url.path) ? files.stored(url) : nil
            })
        }
        guard let adopted else { return 0 }               // gescheitert: beim naechsten Start erneut
        try? FileManager.default.removeItem(at: legacyIndexURL)
        legacyIndex = []
        return adopted
    }

    /// Kennungen der Hochschul-Dateien in der Datenbank des Containers (Hintergrund: neue Dateien eines Laufs); nil,
    /// wenn die Datenbank nicht lesbar ist
    func sourceFileIDs() async -> Set<String>? {
        guard let backend = try? await host.backend() else { return nil }
        return try? await backend.context.database.withConnection { try UniStore.sourceFileIDs($0) }
    }

    /// Liste der geladenen Dateien aus der Datenbank neu lesen
    func refreshEntries() async {
        guard let prefix = host.files?.stored(root), let backend = try? await host.backend() else { entries = []; return }
        entries = (try? await backend.context.database.withConnection { try StudIPLibrary.downloadedFiles($0, under: prefix + "/") }) ?? []
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }

    /// Demo-Inhalte im Container dieses Abgleichs an? Dann gleicht er nicht ab (`LocalBackendHost.demoActive`)
    func demoActive() async -> Bool { await host.demoActive() }

    /// Hat die Hochschule dieses Containers Stud.IP? (Hildesheim: Learnweb und LSF, Abgleich folgt)
    var offersStudIP: Bool { university.profile.studipBase != nil }

    /// Liegt ein Sitzungs-Cookie dieses Containers im Schluesselbund?
    var hasStoredSession: Bool { !cookies.load().isEmpty }

    /// Sitzung als abgelaufen bekannt (in diesem App-Lauf oder gemerkt im Container, auch nach einem Neustart)
    var sessionKnownExpired: Bool { phase == .needsLogin || defaults.bool(forKey: Keys.sessionExpired) }

    /// Ein Lauf nur mit Listen hat Dateien gefunden, die noch nicht geladen sind
    var downloadsPending: Bool { defaults.bool(forKey: Keys.downloadsPending) }

    /// Merker nur schreiben, wenn sich etwas aendert (ein frischer Container bleibt leer)
    private func setFlag(_ key: String, _ on: Bool) {
        if on { defaults.set(true, forKey: key) } else if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
    }

    func fileURL(_ e: StudIPLibrary.DownloadedFile) -> URL? { host.files?.url(stored: e.localPath) }

    // MARK: Anmeldung

    /// Aufruf aus der Anmeldeansicht, sobald Stud.IP die Sitzung bestaetigt hat.
    func signedIn(cookies: [HTTPCookie]) {
        do {
            try self.cookies.save(cookies)
            setFlag(Keys.sessionExpired, false)
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

    /// Abmelden: Cookie aus dem Schluesselbund und alle Daten der Webansicht dieses Containers (auch die SSO-Sitzung)
    /// loeschen; die andere Hochschule bleibt angemeldet. Heruntergeladene Dateien bleiben, bis der Nutzer sie entfernt.
    func signOut() async {
        cookies.clear()
        setFlag(Keys.sessionExpired, false)
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        phase = .signedOut
    }

    /// Heruntergeladene Dateien loeschen. In der Datenbank bleiben die Dokumente mit ihren Notizen, nur der Ablageort
    /// faellt weg; der naechste Abgleich laedt sie neu. Die Kopien im PDF-Zwischenspeicher des Editors und die
    /// Vorschaubilder der Bibliothek (lokale Datenquelle) gehen mit, sonst blieben die Stud.IP-Dateien auf dem Geraet.
    func removeDownloads() async {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("files"))
        try? FileManager.default.removeItem(at: UniDownloads.partial(in: root))
        try? FileManager.default.removeItem(at: legacyIndexURL)
        legacyIndex = []
        entries = []
        if let prefix = host.files?.stored(root), let backend = try? await host.backend() {
            let ids = (try? await backend.context.database.transaction { try StudIPLibrary.forgetDownloads($0, under: prefix + "/") }) ?? []
            for id in ids { try? FileManager.default.removeItem(at: AppPaths.pdf(id, namespace: .local, root: support)) }
            AppPaths.removeThumbnails(fileIDs: ids, namespace: .local, root: support)
        }
        await recordings.removeAll()                      // geladene Aufzeichnungen ebenso, die Listen bleiben
    }

    // MARK: Abgleich

    /// Laeuft der Prozess als Test-Host von XCTest? Dann nie Stud.IP/Opencast abrufen (auch wenn im Simulator eine
    /// echte Sitzung im Schluesselbund liegt).
    nonisolated static func isUnderTest(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// Automatischer Abgleich beim Oeffnen erlaubt? Nicht unter XCTest, nicht mit -UFNoStudIPSync und nicht bei
    /// Startargumenten fuer Bildvergleiche/Agenten (-UFRoute, -UFAction, -UFServer, -UFDisconnect). Der Knopf
    /// "Jetzt abgleichen" bleibt ausserhalb von XCTest moeglich.
    nonisolated static func automaticRunAllowed(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                defaults: UserDefaults = .standard) -> Bool {
        if isUnderTest(environment: environment) { return false }
        if defaults.bool(forKey: "UFNoStudIPSync") { return false }
        return !DebugLaunch.skipTriggers.contains { defaults.object(forKey: $0) != nil }
    }

    /// Beim Oeffnen: hoechstens alle 30 Minuten; warten Dateien aus einem Lauf nur mit Listen (Hintergrund), sofort
    func runIfDue() {
        guard Self.automaticRunAllowed() else { return }
        guard phase == .idle || isFailed else { return }
        if let last = lastRun, !downloadsPending, Date().timeIntervalSince(last) < 30 * 60 { return }
        Task { await run() }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    func run(scope: UniSyncScope = .full) async {
        guard !isRunning, offersStudIP, !Self.isUnderTest() else { return }
        let cookies = self.cookies.load()
        guard !cookies.isEmpty else { phase = .signedOut; return }
        await run(client: liveClient(cookies), scope: scope)
    }

    /// Client mit dem gespeicherten Sitzungs-Cookie (nur Debug mit -UFLoginStub: feste Antworten aus dem Stub-Ordner)
    func liveClient(_ cookies: [HTTPCookie]) -> StudIPClient {
        let transport: StudIPTransport = DebugUniStub.studipTransport() ?? URLSessionStudIPTransport(cookies: cookies, host: Self.base.host ?? "")
        return StudIPClient(base: Self.base, transport: transport)
    }

    /// Ein Abgleich mit diesem Client (Tests: feste Antworten statt Stud.IP). Ablauf wie run_sync in
    /// app/studip_sync.py: Kurse, je Kurs die Dateiliste in die Datenbank, dann die Downloads, danach der Stundenplan
    /// derselben Kurse (`StudIPScheduleSync` mit demselben lokalen Backend, wie `auto_import` am Ende von run_sync),
    /// am Ende `sync_log`. Kein `await` innerhalb einer Transaktion: erst das Netz, dann kurz schreiben.
    /// `scope: .lists` (kurzer Hintergrundlauf): ohne Downloads und ohne Aufzeichnungen. Rueckgabe: wie der Lauf
    /// endete; nil, wenn er nicht begann (es lief schon einer, angehalten).
    @discardableResult
    func run(client: StudIPClient, scope: UniSyncScope = .full) async -> RunEnd? {
        guard !isRunning, !stopped else { return nil }
        // Demo-Inhalte aktiv: nie zur Hochschule, keine Anfrage (DemoContent); erst nach "Entfernen" wieder
        if await demoActive() { return nil }
        guard !isRunning, !stopped else { return nil }
        phase = .running("Kurse werden geladen …")
        let task = Task { await self.perform(client: client, scope: scope) }
        current = task
        let end = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        return end
    }

    /// Anhalten, bevor der Container geloescht wird: laufenden Abgleich abbrechen und auf sein Ende warten (danach
    /// schreibt er nichts mehr), ebenso laufende Downloads von Aufzeichnungen; diese Instanz gleicht danach nicht mehr ab
    func stop() async {
        stopped = true
        recordings.stop()
        guard let task = current else { return }
        task.cancel()
        _ = await task.value
    }

    /// Abbruch (`stop`) statt Fehler, auch `URLError(.cancelled)` einer abgebrochenen Anfrage
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func perform(client: StudIPClient, scope: UniSyncScope) async -> RunEnd {
        defer { finishedRuns += 1 }                       // nach der letzten Phase: Seiten laden neu
        await adoption?.value
        let started = clock.nowISO
        var loaded = 0
        var database: SQLiteDatabase?
        do {
            let db = try await host.backend().context.database
            database = db
            guard let localFiles = host.files else { throw DataContainerError.missing }
            let downloads = UniDownloads(folder: root, files: localFiles, container: container, source: "Stud.IP")
            // Ordner anlegen (ohne iCloud-Backup); Reste eines abgebrochenen Laufs im Zwischenordner gehen hier weg
            try downloads.begin()
            defer { downloads.end() }
            let uid = try await client.currentUserID()
            let list = try await client.courses(userID: uid)
            courses = list.sorted { ($0.semesterStart ?? "", $0.title) > ($1.semesterStart ?? "", $1.title) }
            try? JSONEncoder().encode(courses).write(to: root.appendingPathComponent("courses.json"), options: .atomic)
            // neue Kurse des juengsten Semesters kommen dazu, aeltere werden gemeldet; Abgewaehltes bleibt abgewaehlt
            let selection = StudIPImport.selection(courses: list, selected: selectedCourses, known: knownCourses)
            if selection.selected != selectedCourses { selectedCourses = selection.selected }
            knownCourses = selection.known

            let selectedNow = courses.filter { selectedCourses.contains($0.id) }
            // Fach und Art wie upsert_course (classify), aktiv nach der Semesterregel (`Semesters`, app/semesters.py);
            // die Module legt ensure_modules beim naechsten Lesen an
            let today = clock.today
            let active = try await db.transaction { c -> Set<String> in
                try StudIPLibrary.storeCourses(c, selectedNow, startedAt: started, today: today)
                return Set(try c.rows("SELECT id FROM courses WHERE active=1").compactMap { $0["id"]?.string })
            }
            // Dateien, Termine und Aufzeichnungen nur fuer aktuelle Kurse wie run_studip_sync (c0721da): alte Semester
            // bleiben als Kurs bekannt, kosten aber keinen Abruf und keinen Download; eigene Schalter (Einstellungen ->
            // Module, active_custom) gelten
            let chosen = selectedNow.filter { active.contains($0.id) }
            let older = selectedNow.count - chosen.count
            var remote: [StudIPFile] = []
            var wanted: [StudIPFile] = []
            var checked = Set<String>()
            var unreadable: [Error] = []
            for (i, c) in chosen.enumerated() {
                try Task.checkCancellation()
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
            // in Stud.IP nicht mehr vorhanden: aus dem einen Register (`files`), nur in vollstaendig gelesenen Kursen
            let prefix = (localFiles.stored(root) ?? "StudIP") + "/"
            let remoteIDs = Set(remote.map(\.id))
            let gone = try await db.withConnection {
                try StudIPLibrary.goneRemotely($0, remoteIDs: remoteIDs, checkedCourses: checked, under: prefix)
            }
            let download = wanted.filter(\.isDownloadable)
            var failed = 0
            // nur Listen (kurzer Hintergrundlauf): die Dateien laedt der naechste volle Lauf
            let toLoad = scope == .full ? download : []
            // je Datei ueber `UniDownloads`: erst in den Zwischenordner, pruefen, Hash, alte Fassung einer Datei mit
            // Notizen aufbewahren (S7), an ihren Platz, eintragen, Seitentexte und Notizen der neuen Fassung; ein Abbruch
            // hinterlaesst keine halbe Datei als "geladen". Vor jeder Datei der freie Platz: ein voller Speicher haelt
            // den Lauf an (`DeviceStorage.Full`), statt Datei fuer Datei zu scheitern
            for (i, f) in toLoad.enumerated() {
                try Task.checkCancellation()
                guard DeviceStorage.fits(Int64(f.size), free: DeviceStorage.availableBytes(at: root)) else { throw DeviceStorage.Full() }
                phase = .running("Lade \(i + 1) von \(toLoad.count): \(f.name)")
                let rel = StudIPImport.relativePath(for: f)
                do {
                    try await downloads.load(StudIPLibrary.fileRow(f, base: Self.base), to: rel, db: db, clock: clock) { part in
                        try await client.download(fileID: f.id, to: part, name: f.name)
                    }
                } catch where DeviceStorage.isFull(error) {
                    throw DeviceStorage.Full()
                } catch let e as StudIPError where e.affectsOnlyItem {
                    // wie run_sync ("Download-Fehler"): naechste Datei; der naechste Abgleich versucht es erneut
                    failed += 1
                    continue
                } catch let e as URLError where !Self.endsRun(e) {
                    // z. B. Zeitueberschreitung bei einer grossen Datei: nur diese Datei, die uebrigen kommen trotzdem
                    failed += 1
                    continue
                } catch is UniDownloads.Failure {
                    // leere Antwort statt der Datei oder alte Fassung mit Notizen nicht gesichert (S7): die alte Fassung
                    // bleibt, der naechste Abgleich laedt erneut
                    failed += 1
                    continue
                }
                loaded += 1
            }
            await refreshEntries()                            // Dateien schon zeigen, waehrend der Stundenplan laedt
            try Task.checkCancellation()
            // Stundenplan aus Stud.IP (S5); Fehler dort brechen den Datei-Abgleich nicht ab
            let timetable = await StudIPScheduleSync(host: host).run(client: client, userID: uid, courses: chosen) { phase = .running($0) }
            try Task.checkCancellation()
            // Aufzeichnungen (Opencast): je Kurs eine Seite; Fehler eines Kurses ueberspringen nur diesen, Kurse ohne
            // Opencast sind kein Fehler; Videos laedt nur der Nutzer. Nach abgelaufener Sitzung nicht mehr fragen, im
            // kurzen Hintergrundlauf auch nicht (eine Seite je Kurs sprengte die rund 30 Sekunden)
            let rec = timetable.sessionExpired || scope == .lists ? nil
                : await recordings.refresh(client: client, courses: chosen) { phase = .running($0) }
            let notDownloadable = remote.filter { !$0.isDownloadable }.count
            let waiting = download.count - toLoad.count
            let waitingText = "\(waiting) \(waiting == 1 ? "Datei wartet" : "Dateien warten") auf den Download"
            var parts = ["\(loaded) neu/geändert", "\(remote.count - notDownloadable - download.count) unverändert"]
            if waiting > 0 { parts.append(waitingText) }
            if notDownloadable > 0 { parts.append("\(notDownloadable) nicht herunterladbar") }
            if failed > 0 { parts.append("\(failed) nicht geladen (Fehler)") }
            if !gone.isEmpty { parts.append("\(gone.count) in Stud.IP nicht mehr vorhanden") }
            if !unreadable.isEmpty { parts.append("\(unreadable.count) \(unreadable.count == 1 ? "Kurs" : "Kurse") nicht lesbar") }
            if let n = Self.newCoursesNote(selection.newUnselected.count) { parts.append(n) }
            if let n = Self.olderCoursesNote(older) { parts.append(n) }
            parts += timetable.summary
            parts += rec?.summary ?? []
            let expired = timetable.sessionExpired || rec?.sessionExpired == true
            if scope == .full {
                finish(summary: parts.joined(separator: ", ") + " · \(checked.count) Kurse")
                // alle Dateien geladen oder als Fehler gezaehlt: nichts wartet mehr auf den naechsten Abgleich
                setFlag(Keys.downloadsPending, false)
            } else if waiting > 0 {
                setFlag(Keys.downloadsPending, true)
            }
            let message = scope == .full ? StudIPLibrary.summary(newFiles: loaded, newEvents: timetable.result?.newEvents ?? 0,
                                                                   removedEvents: timetable.result?.removedEvents ?? 0)
                : "Hintergrund: Listen abgeglichen, " + waitingText
            await log(database, started: started, ok: true, newFiles: loaded, message: message)
            // Sitzung erst beim Stundenplan oder den Aufzeichnungen abgelaufen: Dateien sind da, die Anmeldung muss neu
            phase = expired ? .needsLogin : .idle
            setFlag(Keys.sessionExpired, expired)
            return expired ? .sessionExpired : .completed
        } catch where Self.isCancellation(error) || Task.isCancelled {
            // angehalten (Container wird geloescht) oder abgebrochen: kein Fehler; was gelesen war, steht in der Datenbank
            await refreshEntries()
            await log(database, started: started, ok: false, newFiles: loaded, message: StudIPLibrary.failure("Abgleich abgebrochen"))
            phase = hasStoredSession ? .idle : .signedOut
            return .cancelled
        } catch StudIPError.sessionExpired {
            await refreshEntries()
            await log(database, started: started, ok: false, newFiles: loaded, message: StudIPLibrary.failure(StudIPError.sessionExpired.description))
            phase = .needsLogin
            setFlag(Keys.sessionExpired, true)
            return .sessionExpired
        } catch {
            await refreshEntries()
            // verstaendlich statt "…SQLiteError-Fehler 1." (LocalBackendHost.message, auch "Speicher voll")
            let message = LocalBackendHost.message(for: error)
            await log(database, started: started, ok: false, newFiles: loaded, message: StudIPLibrary.failure(message))
            phase = .failed(message)
            return .failed(message)
        }
    }

    /// Hinweis auf ausgewaehlte Kurse frueherer Semester, die der Abgleich nach der Semesterregel nicht einplant
    /// (wie "N Kurse aus frueheren Semestern uebersprungen" im Protokoll von run_studip_sync)
    static func olderCoursesNote(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "1 Kurs aus früheren Semestern nicht eingeplant (Einstellungen → Module)"
        default: return "\(count) Kurse aus früheren Semestern nicht eingeplant (Einstellungen → Module)"
        }
    }

    /// Hinweis auf neue Kurse aelterer Semester, die nicht von selbst dazukamen (`StudIPImport.selection`)
    static func newCoursesNote(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "1 neuer Kurs nicht ausgewählt (Stud.IP → Kurse)"
        default: return "\(count) neue Kurse nicht ausgewählt (Stud.IP → Kurse)"
        }
    }

    /// Eintrag in `sync_log` wie im `finally` von run_sync (Uebersicht "letzter Abgleich", Einstellungen)
    private func log(_ db: SQLiteDatabase?, started: String, ok: Bool, newFiles: Int, message: String) async {
        guard let db else { return }
        let finished = clock.nowISO
        _ = try? await db.transaction {
            try UniStore.logSync($0, startedAt: started, finishedAt: finished, ok: ok, newFiles: newFiles, message: message)
        }
    }

    private func finish(summary: String) {
        lastRun = Date()
        lastSummary = summary
        defaults.set(lastRun, forKey: "uniflow.studip.lastRun")
        defaults.set(summary, forKey: "uniflow.studip.lastSummary")
    }

    /// Transportfehler, nach dem keine weitere Datei ankaeme (kein Netz, Stud.IP nicht erreichbar, abgebrochen):
    /// der Lauf endet als Fehler. Alles andere (z. B. Zeitueberschreitung) betrifft nur den einen Kurs (Dateiliste)
    /// oder die eine Datei (Download).
    nonisolated static func endsRun(_ e: URLError) -> Bool {
        [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .cancelled, .cannotWriteToFile, .cannotCreateFile].contains(e.code)
    }
}
