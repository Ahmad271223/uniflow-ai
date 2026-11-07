import Foundation
import Security
import UIKit
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
        /// seit 3.11.2026 (Anmeldung der Webansicht ueber Neustarts, `UniWebSessions`); aeltere Eintraege ohne
        var httpOnly: Bool? = nil
        var sameSite: String? = nil
    }

    func save(_ cookies: [HTTPCookie]) throws {
        let stored = cookies.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate, secure: $0.isSecure,
                         httpOnly: $0.isHTTPOnly ? true : nil, sameSite: $0.sameSitePolicy?.rawValue)
        }
        try saveRaw(try JSONEncoder().encode(stored))
    }

    func load() -> [HTTPCookie] {
        guard let data = loadRaw(), let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        return stored.compactMap { s in
            var p: [HTTPCookiePropertyKey: Any] = [.name: s.name, .value: s.value, .domain: s.domain, .path: s.path]
            if let e = s.expires { p[.expires] = e }
            if s.secure { p[.secure] = "TRUE" }
            if s.httpOnly == true { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let same = s.sameSite { p[.sameSitePolicy] = same }
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

    /// "Meldung schließen" an der Fehlermeldung (07.11.2026): Fehler ausblenden, bis der naechste Abgleich scheitert
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = hasStoredSession ? .idle : .signedOut
    }
    @Published private(set) var courses: [StudIPCourse] = []
    /// geladene Dateien aus der Datenbank (`StudIPLibrary.downloadedFiles`, das eine Register; vorher index.json)
    @Published private(set) var entries: [StudIPLibrary.DownloadedFile] = []
    /// Dateien "Link/Webadresse" (nicht herunterladbar, mit Adresse), zum Oeffnen im Browser
    @Published private(set) var links: [StudIPLibrary.FileLink] = []
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSummary: String?
    /// Zahl der beendeten Abgleiche dieses App-Laufs; Seiten mit `ufReload` laden bei jeder Aenderung neu
    @Published private(set) var finishedRuns = 0
    /// Zwischenstaende eines laufenden Abgleichs (07.11.2026): Stundenplan gespeichert, neue Dateien geladen. Seiten mit
    /// `ufReload` laden dann schon neu, statt bis zum Ende des Laufs (Ergaenzungen, Aufzeichnungen, Lernstoff) zu warten
    @Published private(set) var stagesReady = 0
    /// Ergebnis des letzten "Dateien laden" fuer Kurse frueherer Semester (`loadOlderFiles`)
    @Published private(set) var olderFilesNote: String?
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
        /// Die flache Ordnerliste (`courses/{id}/folders`) stimmte beim letzten Vergleich mit dem Ordnerbaum ueberein:
        /// Dateilisten ohne Unterordner-Abfrage je Ordner (`StudIPFolderMode.flat`). Weg bei der ersten Abweichung
        static let flatFolders = "uniflow.studip.flatFolders"
        /// Letzter Vergleich flache Liste gegen Baum (ein Kurs je Vergleich, reihum, `folderCheckInterval`)
        static let folderCheckAt = "uniflow.studip.folderCheckAt"
        static let folderCheckIndex = "uniflow.studip.folderCheckIndex"
        /// Letzter Lauf mit Aufzeichnungen und Lernstoff (`slowPartsInterval`)
        static let slowPartsAt = "uniflow.studip.slowPartsAt"
    }

    /// Aufzeichnungen (Opencast) und Lernstoff (Courseware, Wiki, Forum) fragen je Kurs mehrere Seiten ab; beim Oeffnen
    /// der App (hoechstens alle 30 Minuten) reicht das alle zwei Stunden
    static let slowPartsInterval: TimeInterval = 2 * 3600

    static func slowPartsDue(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= slowPartsInterval || $0 > now } ?? true
    }

    /// Der naechste Lauf holt Aufzeichnungen und Lernstoff sofort (ohne die zwei Stunden abzuwarten)
    func refreshSlowPartsNextRun() { defaults.removeObject(forKey: Keys.slowPartsAt) }

    /// Wie oft ein Lauf mit bestaetigter flacher Ordnerliste einen Kurs doch ueber den Baum liest (reihum): so faellt
    /// eine Abweichung der flachen Liste spaetestens nach einem halben Tag auf
    static let folderCheckInterval: TimeInterval = 12 * 3600
    /// Kurse, deren Dateilisten zugleich gelesen werden (die Anfragen selbst begrenzt `StudIPClient.maxConcurrent`)
    static let parallelCourses = 4

    /// Ordnerlesart je Kurs fuer diesen Lauf: Baum, bis die flache Liste bestaetigt ist; danach flach, nur der faellige
    /// Vergleichskurs (reihum, hoechstens alle `folderCheckInterval`) ueber den Baum. Rueckgabe: Lesart je Kurs und
    /// Index des Vergleichskurses (nil: kein Vergleich faellig)
    static func folderModes(count: Int, trusted: Bool, lastCheck: Date?, checkIndex: Int, now: Date) -> (modes: [StudIPFolderMode], checked: Int?) {
        guard count > 0 else { return ([], nil) }
        guard trusted else { return (Array(repeating: .walk, count: count), nil) }
        var modes = [StudIPFolderMode](repeating: .flat, count: count)
        guard lastCheck.map({ now.timeIntervalSince($0) >= folderCheckInterval }) ?? true else { return (modes, nil) }
        let i = ((checkIndex % count) + count) % count
        modes[i] = .walk
        return (modes, i)
    }

    /// Fortschritt der Downloads ("3 neue Dateien" statt nur "Stud.IP-Abgleich")
    /// Dateien eines Laufs, die geladen werden (07.11.2026, Befund vom iPad): alles ausser Links (Stud.IP-Datei ohne
    /// Inhalt, nur Adresse) und Videodateien (nur auf Wunsch, Aufzeichnungen). Vorher fiel jede Datei mit
    /// "is-downloadable": false still weg: an der LUH melden normale Veranstaltungen ihre Dateien so (Lizenz bzw.
    /// Nutzungsbedingungen), waehrend der Inhalt ueber `file-refs/{id}/content` kommt (der PC-Abgleich app/studip_sync.py
    /// fragt das Merkmal nie). Die Dateien standen als "erkannt" in `files`, ohne je geladen zu werden. Verweigert
    /// Stud.IP den Inhalt wirklich, steht das als Fehler je Datei da (`DownloadFailures`).
    static func downloadCandidates(_ wanted: [StudIPFile]) -> [StudIPFile] {
        wanted.filter { $0.linkURL == nil && !OpencastFileVideos.isVideo(name: $0.name, mime: $0.mimeType) }
    }

    static func downloadStep(_ i: Int, of n: Int, name: String) -> String {
        n == 1 ? "1 neue Datei wird geladen: \(name)" : "\(n) neue Dateien – lade \(i + 1) von \(n): \(name)"
    }

    /// Kurzer Stand nach den Dateien fuer die weiteren Schritte
    static func filesNote(loaded: Int) -> String {
        switch loaded {
        case 0: return "Keine neuen Dateien"
        case 1: return "1 neue Datei"
        default: return "\(loaded) neue Dateien"
        }
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
    /// zaehlt jedes Abmelden: ein Lauf, der vorher begann und noch auf die Demo-Pruefung wartete (noch ohne `current`,
    /// das Abmelden haelt ihn also nicht an), beginnt danach nicht mehr mit der alten Sitzung (Pruefpunkt 362)
    private var signOuts = 0

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
        // Videodateien aus Stud.IP (Dateibaum, Courseware) laufen ueber die JSON:API mit dem Sitzungs-Cookie dieses Containers
        let cookieStore = self.cookies
        recordings = RecordingLibrary(root: self.root.appendingPathComponent(RecordingFiles.folder, isDirectory: true), host: host,
                                      container: container, cookies: { url in Self.ownCookies(cookieStore.load(), host: url.host ?? "") })
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
        links = (try? await backend.context.database.withConnection { try StudIPLibrary.links($0) }) ?? []
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

    /// Letzte Anmeldung (`LoginReminder`)
    var lastSignIn: Date? { offersStudIP ? defaults.object(forKey: LoginReminder.lastLoginKey) as? Date : nil }

    /// Aufruf aus der Anmeldeansicht, sobald Stud.IP die Sitzung bestaetigt hat.
    func signedIn(cookies: [HTTPCookie]) {
        do {
            try self.cookies.save(cookies)
            setFlag(Keys.sessionExpired, false)
            renewal.verified(at: Date())                       // neue Sitzung: Ruecknahme der stillen Versuche zurueck
            defaults.set(Date(), forKey: LoginReminder.lastLoginKey)
            phase = .idle
            let store = websiteDataStore
            UniAutoLogin.signedIn(store)                       // mitgelesenes Passwort jetzt merken (falls zugelassen)
            Task { await UniWebSessions.save(store) }          // Uni-Anmeldung (WebSSO) ueber Neustarts merken
            Task { await run() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Direkter Einstieg ins WebSSO der LUH (ueberspringt die Hochschulauswahl), wie `SHIB_LOGIN_URL` in
    /// app/studip_sync.py
    static let ssoEntityID = "https://sso.idm.uni-hannover.de/idp/shibboleth"
    static func ssoLoginURL(base: URL = base) -> URL {
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        let target = root + "/dispatch.php/login?sso=shib&again=yes&cancel_login=1"
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
        return URL(string: root + "/Shibboleth.sso/Login?target=" + enc(target) + "&entityID=" + enc(ssoEntityID))!
    }

    /// Cookies der Stud.IP-Adresse aus allen Cookies der Webansicht
    static func ownCookies(_ all: [HTTPCookie], host: String = base.host ?? "") -> [HTTPCookie] {
        all.filter { host.hasSuffix($0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain) }
    }

    /// Stand der Pruefung und stillen Erneuerung (`UniRenewalPolicy`: Pruefung beim Oeffnen hoechstens alle 15 Minuten,
    /// vor einem Abgleich hoechstens alle 5; nach gescheiterten stillen Versuchen 10, 20, 40 … Minuten Pause, hoechstens
    /// 4 Stunden; eine neue Anmeldung setzt das zurueck)
    private(set) var renewal = UniRenewalState()

    /// Pruefen und still erneuern mit echten Anfragen: nie unter XCTest, nie mit der Debug-Nachbildung
    var liveSessionWorkAllowed: Bool { !Self.isUnderTest() && DebugUniStub.studipTransport() == nil }

    /// Abgelaufene Stud.IP-Sitzung ohne Passwort erneuern: Die Uni-Anmeldung (WebSSO) liegt im eigenen Datenspeicher
    /// der Anmeldeansicht und gilt meist laenger als die Stud.IP-Sitzung. Eine unsichtbare Webansicht oeffnet den
    /// WebSSO-Einstieg; gilt die Uni-Anmeldung noch, kommt sie ohne Eingabe bei Stud.IP an, die neuen Cookies werden
    /// gespeichert und der Abgleich startet. Sonst bleibt es bei "Erneut anmelden" (dort setzt iOS das gespeicherte
    /// Passwort ein). Nur mit offener App, nie im Hintergrund; die App sieht kein Passwort.
    /// Laufender stiller Versuch: ein zweiter Aufruf (Oeffnen der App und Bitte um Anmeldung zugleich) wartet auf ihn
    private var renewing: Task<Bool, Never>?

    @discardableResult
    func renewSilently(trigger: UniRenewalTrigger = .foreground) async -> Bool {
        if let renewing { return await renewing.value }
        guard sessionKnownExpired, offersStudIP, liveSessionWorkAllowed else { return false }
        // Ruecknahme nach gescheiterten Versuchen (`UniRenewalPolicy`); nur mit offener App
        guard UniRenewalPolicy.decide(trigger, appActive: UIApplication.shared.applicationState == .active, connected: hasStoredSession,
                                      knownExpired: true, state: renewal, now: Date()) == .renew else { return false }
        if phase != .needsLogin, !isRunning { phase = .needsLogin }   // abgelaufen gemerkt (Neustart): wie im Lauf
        let store = websiteDataStore
        let task = Task { @MainActor () -> Bool in
            var fresh = await StudIPSilentLogin.attempt(url: Self.ssoLoginURL(), dataStore: store)
            // WebSSO will das Passwort: mit dem gespeicherten still anmelden, dann genau einmal neu (`UniAutoLogin`)
            if fresh == nil, await self.autoLogin(store: store) {
                fresh = await StudIPSilentLogin.attempt(url: Self.ssoLoginURL(), dataStore: store)
            }
            guard let fresh, self.sessionKnownExpired else { return false }
            self.signedIn(cookies: fresh)                          // speichert (auch die Uni-Anmeldung) und startet den Abgleich
            return true
        }
        renewing = task
        let ok = await task.value
        renewing = nil
        renewal.attempted(at: Date(), ok: ok)
        return ok
    }

    /// Automatisch anmelden (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): auf dem WebSSO mit dem gespeicherten Passwort
    /// (nur mit Zustimmung, nur dieses Geraet); true, wenn danach Stud.IP erreicht ist
    private func autoLogin(store: WKWebsiteDataStore) async -> Bool {
        let host = Self.base.host?.lowercased() ?? ""
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "studip", store: store, entry: Self.ssoLoginURL()) { url, _ in
            url.host?.lowercased() == host && !url.path.contains("Shibboleth.sso")
        }
        return d == .retryOnce && signOuts == before && hasStoredSession
    }

    /// Bereitschaft der gemerkten Sitzung vor einem Abgleich bzw. beim Oeffnen (`ensureSession`)
    enum SessionReadiness: Equatable {
        /// gilt (oder es gibt nichts zu pruefen): weiter wie geplant
        case ready
        /// still erneuert; `signedIn` hat den Abgleich mit der neuen Sitzung schon gestartet
        case renewed
        /// abgelaufen, still nicht zu erneuern: "Erneut anmelden" (Anmeldeseite mit Benutzername, iOS setzt das Passwort ein)
        case needsUser
        /// nicht entscheidbar (kein Netz): weiter, der Abgleich meldet den Fehler selbst
        case unknown
        case notConnected
    }

    /// Angemeldet bleiben (04.11.2026): vor dem Abgleich und beim Oeffnen der App die gemerkte Sitzung pruefen und, wenn
    /// sie abgelaufen ist, gleich still erneuern - nicht erst nach einer gescheiterten Anfrage. Wann geprueft bzw.
    /// erneuert wird, entscheidet `UniRenewalPolicy`; im Hintergrund nie (dort fehlt die Webansicht).
    @discardableResult
    func ensureSession(_ trigger: UniRenewalTrigger) async -> SessionReadiness {
        guard offersStudIP, hasStoredSession, phase != .signedOut else { return .notConnected }
        guard liveSessionWorkAllowed else { return .ready }
        let active = UIApplication.shared.applicationState == .active
        switch UniRenewalPolicy.decide(trigger, appActive: active, connected: true, knownExpired: sessionKnownExpired,
                                       state: renewal, now: Date()) {
        case .nothing:
            return sessionKnownExpired ? needsUser() : .ready
        case .wait:
            return needsUser()
        case .renew:
            return await renewSilently(trigger: trigger) ? .renewed : needsUser()
        case .check:
            guard !isRunning else { return .ready }
            switch await Self.sessionCheck(cookies.load()) {
            case .valid:
                renewal.verified(at: Date())
                return .ready
            case .unknown:
                return .unknown
            case .expired:
                guard !isRunning, hasStoredSession else { return .ready }
                phase = .needsLogin
                setFlag(Keys.sessionExpired, true)
                return await renewSilently(trigger: .requestFailed) ? .renewed : needsUser()
            }
        }
    }

    /// Abgelaufen und still nicht zu erneuern: "Erneut anmelden" zeigen (auch nach einem Neustart mit gemerktem Merker)
    private func needsUser() -> SessionReadiness {
        if phase != .needsLogin, !isRunning, hasStoredSession { phase = .needsLogin }
        return .needsUser
    }

    /// Prueft mit den Cookies aus der Webansicht, ob Stud.IP die Sitzung annimmt.
    static func sessionIsValid(_ cookies: [HTTPCookie]) async -> Bool {
        await sessionCheck(cookies) == .valid
    }

    /// Eine leichte Anfrage (`users/me`): gilt die Sitzung, ist sie abgelaufen (401, Weiterleitung zur Anmeldung) oder
    /// ist das nicht zu sagen (kein Netz, Stud.IP gestoert)? `transport`: nur Tests (feste Antworten).
    static func sessionCheck(_ cookies: [HTTPCookie], transport: StudIPTransport? = nil) async -> UniSessionCheck {
        let t = transport ?? URLSessionStudIPTransport(cookies: cookies, host: base.host ?? "")
        let c = StudIPClient(base: base, transport: t, pauseMillis: 0, maxRequests: 1)
        do {
            _ = try await c.currentUserID()
            return .valid
        } catch StudIPError.sessionExpired {
            return .expired
        } catch {
            return .unknown
        }
    }

    /// Stud.IP-Cookies des Abgleichs in den Datenspeicher der Webansicht, soweit sie dort fehlen (In-App-Browser: dieselbe
    /// Sitzung wie der Abgleich)
    func seedWebSession() async {
        guard offersStudIP else { return }
        await UniWebSessions.ready(websiteDataStore)
        await UniWebSessions.insertMissing(cookies.load(), into: websiteDataStore)
    }

    /// In-App-Browser geschlossen: hat Stud.IP dort eine neue Sitzung gesetzt (z. B. nach einer Anmeldung auf der
    /// Seite), uebernimmt der Abgleich sie, sobald `users/me` sie annimmt. War die Sitzung als abgelaufen bekannt, gilt
    /// das wie eine Anmeldung (der Abgleich startet). Nur bei verbundenem Stud.IP; nie eine neue Verbindung.
    func adoptBrowserSession() async {
        guard offersStudIP, hasStoredSession, liveSessionWorkAllowed, !isRunning else { return }
        let mine = Self.ownCookies(await websiteDataStore.httpCookieStore.allCookies())
        guard !mine.isEmpty, UniCookiePolicy.differs(mine, cookies.load()) else { return }
        guard await Self.sessionCheck(mine) == .valid, hasStoredSession, !isRunning else { return }
        if sessionKnownExpired {
            signedIn(cookies: mine)
        } else {
            try? cookies.save(mine)
            renewal.verified(at: Date())
        }
    }

    /// Abmelden: Cookie aus dem Schluesselbund und alle Daten der Webansicht dieses Containers (auch die SSO-Sitzung)
    /// loeschen; die andere Hochschule bleibt angemeldet. Heruntergeladene Dateien bleiben, bis der Nutzer sie entfernt.
    func signOut() async {
        signOuts += 1
        // laufenden Abgleich zuerst anhalten und abwarten: er arbeitete sonst mit der alten Sitzung weiter und setzte
        // danach "verbunden" (phase .idle), obwohl abgemeldet
        if let task = current {
            task.cancel()
            _ = await task.value
        }
        cookies.clear()
        setFlag(Keys.sessionExpired, false)
        defaults.removeObject(forKey: LoginReminder.lastLoginKey)
        UniLoginHelper.forget(defaults: defaults)                // gemerkter Benutzername der Anmeldeseite
        UniAutoLogin.forget(websiteDataStore)                    // gemerktes Passwort dieser Hochschule (Schluesselbund)
        renewal = UniRenewalState()
        await UniWebSessions.forget(websiteDataStore)            // gemerkte Uni-Anmeldung zuerst (nie wiederverwenden)
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

    /// Beim Oeffnen: zuerst die Sitzung (Pruefung hoechstens alle 15 Minuten, abgelaufen: gleich still erneuern,
    /// `ensureSession`), dann der Abgleich hoechstens alle 30 Minuten; warten Dateien aus einem Lauf nur mit Listen
    /// (Hintergrund), sofort
    func runIfDue() {
        guard Self.automaticRunAllowed() else { return }
        guard phase == .idle || isFailed || phase == .needsLogin else { return }
        Task {
            let ready = await ensureSession(.foreground)
            // erneuert: `signedIn` hat den Abgleich schon gestartet; abgelaufen: "Erneut anmelden"
            guard ready == .ready || ready == .unknown, phase == .idle || isFailed else { return }
            if let last = lastRun, !downloadsPending, Date().timeIntervalSince(last) < 30 * 60 { return }
            await run()
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    func run(scope: UniSyncScope = .full) async {
        guard !isRunning, offersStudIP, !Self.isUnderTest() else { return }
        guard !self.cookies.load().isEmpty else { phase = .signedOut; return }
        // vorab pruefen bzw. still erneuern (nur mit offener App; im Hintergrund entscheidet die erste Anfrage)
        switch await ensureSession(.beforeSync) {
        case .renewed, .needsUser, .notConnected: return        // erneuert: der Abgleich laeuft schon mit der neuen Sitzung
        case .ready, .unknown: break
        }
        let cookies = self.cookies.load()
        guard !cookies.isEmpty else { phase = .signedOut; return }
        await run(client: liveClient(cookies), scope: scope)
    }

    /// "Dateien laden" fuer Kurse frueherer Semester (Bibliothek, Frage nach dem ersten Abgleich) und Stufe (d) des
    /// Abgleichs (`OlderSemesterLoader`, `SyncOrder`): nur deren Dateilisten und Downloads (`OlderSemesters.pending`),
    /// neuestes Semester zuerst, ohne Stundenplan und Aufzeichnungen. `only`: nur diese Kurse (ein Semester je Lauf).
    /// Laeuft gerade ein Abgleich, holt der naechste die vorgemerkten Kurse. Rueckgabe: Meldung fuer die Anzeige.
    @discardableResult
    func loadOlderFiles(only: Set<String>? = nil) async -> String? {
        guard !isRunning else { return Self.olderQueuedNote }
        guard offersStudIP, !Self.isUnderTest() else { return nil }
        let cookies = self.cookies.load()
        guard !cookies.isEmpty else { phase = .signedOut; return nil }
        await run(client: liveClient(cookies), olderOnly: true, olderCourses: only)
        return olderFilesNote
    }

    static let olderQueuedNote = "Vorgemerkt: Die Dateien kommen mit dem nächsten Abgleich."

    /// Client mit dem gespeicherten Sitzungs-Cookie (nur Debug mit -UFLoginStub: feste Antworten aus dem Stub-Ordner)
    func liveClient(_ cookies: [HTTPCookie]) -> StudIPClient {
        let transport: StudIPTransport = DebugUniStub.studipTransport() ?? URLSessionStudIPTransport(cookies: cookies, host: Self.base.host ?? "")
        return StudIPClient(base: Self.base, transport: transport)
    }

    /// Termin-Detail (06.11.2026): Lehrende eines Kurses, die noch nicht geladen sind, auf Wunsch nachholen (wie nach
    /// Stufe (a) des Abgleichs, `StudIPExtrasSync.lecturers`: nur lesend, je Kurs hoechstens alle 7 Tage). Nur mit
    /// gespeicherter Sitzung, nicht waehrend eines Abgleichs. Rueckgabe: ohne abgelaufene Sitzung gelaufen.
    @discardableResult
    func loadLecturers(courseID: String) async -> Bool {
        guard offersStudIP, !isRunning, !stopped, !courseID.isEmpty else { return false }
        let cookies = self.cookies.load()
        guard !cookies.isEmpty else { return false }
        let expired = await StudIPExtrasSync(host: host).lecturers(client: liveClient(cookies), courses: [StudIPCourse(id: courseID, title: "")])
        return !expired
    }

    /// Ergebnis von "Jetzt laden" fuer eine einzelne Datei (Dateiansicht)
    enum FileLoadOutcome: Equatable {
        case loaded
        /// keine oder abgelaufene Stud.IP-Anmeldung
        case needsLogin
        /// gescheitert, mit verstaendlichem Grund (steht auch je Datei in `DownloadFailures`)
        case failed(String)
        /// keine Stud.IP-Datei dieses Containers (eigener Upload, Learnweb, andere Hochschule)
        case notStudIP
    }

    /// Nur Tests (Ansichtstest "Jetzt laden"): Client mit festen Antworten statt der gespeicherten Sitzung
    var fileClientForTests: StudIPClient?

    /// Stud.IP-Datei laut Datenbank (nur Originale mit Download-Adresse `…/file-refs/<id>/content`)
    nonisolated static func storedFile(_ c: SQLiteConnection, id: String) throws -> UniStore.FileRow? {
        guard let r = try c.queryOne("""
            SELECT id, name, size, mime, chdate, revision, download_url, studip_folder FROM files
            WHERE id=? AND course_id <> '__user__' AND instr(COALESCE(download_url, ''), '/file-refs/' || id || '/') > 0
            """, [.text(id)]), let url = r["download_url"]?.string else { return nil }
        return UniStore.FileRow(id: id, name: r["name"]?.string ?? id, size: r["size"]?.int, mime: r["mime"]?.string,
                                chdate: r["chdate"]?.int, revision: r["revision"]?.int, downloadURL: url,
                                folder: r["studip_folder"]?.string)
    }

    /// Gescheiterter Download dieser Datei (nil: keiner bekannt)
    func downloadFailure(id: String) async -> DownloadFailures.Entry? {
        guard let db = try? await host.backend().context.database else { return nil }
        return try? await db.withConnection { try DownloadFailures.entry($0, fileID: id) }
    }

    /// "Jetzt laden" in der Dateiansicht (07.11.2026): genau diese gelistete, nicht geladene Datei sofort mit der
    /// gespeicherten Stud.IP-Sitzung laden, auf demselben Weg wie der Abgleich (`UniDownloads`: Zwischenordner,
    /// Pruefung, Hash, Eintrag). Darf neben einem laufenden Abgleich laufen (eigener Zwischenordner). Scheitert der
    /// Download, steht der Grund je Datei in `DownloadFailures`. `client`: nur Tests.
    func loadFile(id: String, client: StudIPClient? = nil) async -> FileLoadOutcome {
        guard offersStudIP, !stopped else { return .notStudIP }
        let client = client ?? fileClientForTests
        let c: StudIPClient
        if let client {
            c = client
        } else {
            let cookies = self.cookies.load()
            guard !cookies.isEmpty else { return .needsLogin }
            c = liveClient(cookies)
        }
        if await demoActive() { return .failed("Im Beispielmodus lädt StudiNow keine Dateien von Stud.IP.") }
        var database: SQLiteDatabase?
        do {
            let db = try await host.backend().context.database
            database = db
            guard let localFiles = host.files else { return .failed("Die Daten dieser Hochschule sind gerade nicht geöffnet.") }
            guard let row = try await db.withConnection({ try Self.storedFile($0, id: id) }) else { return .notStudIP }
            guard DeviceStorage.fits(Int64(row.size ?? 0), free: DeviceStorage.availableBytes(at: root)) else { throw DeviceStorage.Full() }
            let downloads = UniDownloads(folder: root, files: localFiles, container: container, source: "Stud.IP")
            try downloads.begin()
            defer { downloads.end() }
            _ = try await downloads.load(row, to: StudIPImport.relativePath(fileID: id, name: row.name), db: db, clock: clock) { part in
                try await c.download(fileID: id, to: part, name: row.name)
            }
            await refreshEntries()
            return .loaded
        } catch StudIPError.sessionExpired {
            if client == nil {
                setFlag(Keys.sessionExpired, true)
                if phase == .idle { phase = .needsLogin }
                Task { await renewSilently(trigger: .requestFailed) }
            }
            return .needsLogin
        } catch where DeviceStorage.isFull(error) {
            return .failed("Auf diesem iPad ist nicht genug Speicher frei. Platz schaffen und erneut versuchen.")
        } catch {
            let d = DownloadFailures.describe(error)
            let at = clock.nowISO
            _ = try? await database?.transaction { try DownloadFailures.record($0, fileID: id, message: d.message, status: d.status, now: at) }
            return .failed(d.message)
        }
    }

    /// Ein Abgleich mit diesem Client (Tests: feste Antworten statt Stud.IP). Ablauf wie run_sync in
    /// app/studip_sync.py: Kurse, je Kurs die Dateiliste in die Datenbank, dann die Downloads, danach der Stundenplan
    /// derselben Kurse (`StudIPScheduleSync` mit demselben lokalen Backend, wie `auto_import` am Ende von run_sync),
    /// am Ende `sync_log`. Kein `await` innerhalb einer Transaktion: erst das Netz, dann kurz schreiben.
    /// `scope: .lists` (kurzer Hintergrundlauf): ohne Downloads und ohne Aufzeichnungen. Rueckgabe: wie der Lauf
    /// endete; nil, wenn er nicht begann (es lief schon einer, angehalten).
    /// `olderOnly`: nur die gewuenschten Kurse frueherer Semester (`loadOlderFiles`, Stufe d), `olderCourses`: davon
    /// nur diese.
    @discardableResult
    func run(client: StudIPClient, scope: UniSyncScope = .full, olderOnly: Bool = false, olderCourses: Set<String>? = nil) async -> RunEnd? {
        guard !isRunning, !stopped else { return nil }
        let signOutsBefore = signOuts
        // Demo-Inhalte aktiv: nie zur Hochschule, keine Anfrage (DemoContent); erst nach "Entfernen" wieder
        if await demoActive() { return nil }
        // waehrend der Pruefung angehalten, schon ein Lauf oder abgemeldet (dann gehoert `client` zur alten Sitzung)
        guard !isRunning, !stopped, signOuts == signOutsBefore else { return nil }
        // gleicht ein anderes Objekt desselben Containers noch ab (Wechsel A → B → A), keinen zweiten Lauf (P2-2)
        guard ContainerRuns.claim(root, by: self) else { return nil }
        defer { ContainerRuns.release(root, by: self) }
        phase = .running("Kurse werden geladen …")
        let task = Task { await self.perform(client: client, scope: scope, olderOnly: olderOnly, olderCourses: olderCourses) }
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

    private func perform(client: StudIPClient, scope: UniSyncScope, olderOnly: Bool = false, olderCourses: Set<String>? = nil) async -> RunEnd {
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
            // Kurse, die laut Semesterregel laufen (auch "unbegrenzt"), zaehlen wie das juengste Semester (Riesentest 03.11.2026)
            let selection = StudIPImport.selection(courses: list, selected: selectedCourses, known: knownCourses, today: clock.today)
            if selection.selected != selectedCourses { selectedCourses = selection.selected }
            knownCourses = selection.known

            let selectedNow = courses.filter { selectedCourses.contains($0.id) }
            let today = clock.today
            // Kurse frueherer Semester kommen als Kurs in die Datenbank, auch ohne Auswahl (inaktiv nach der
            // Semesterregel, ohne Modul, Termine und Dateien): die Bibliothek zeigt sie je Semester zum Nachladen, die
            // Community prueft daran "hat oder hatte das Modul". Abgewaehlte Kurse des aktuellen Semesters bleiben aus.
            let olderUnselected = courses.filter { !selectedCourses.contains($0.id) && StudIPView.isOlder($0, today: today) }
            // Fach und Art wie upsert_course (classify), aktiv nach der Semesterregel (`Semesters`, app/semesters.py);
            // die Module legt ensure_modules beim naechsten Lesen an
            let (active, wantedOlder) = try await db.transaction { c -> (Set<String>, Set<String>) in
                try StudIPLibrary.storeCourses(c, selectedNow + olderUnselected, startedAt: started, today: today)
                return (Set(try c.rows("SELECT id FROM courses WHERE active=1").compactMap { $0["id"]?.string }),
                        try OlderSemesters.pending(c, today: today))
            }
            // Reihenfolge (`SyncOrder`, Wunsch des Inhabers 05.11.2026): (a) Dateilisten der aktuellen Kurse, gleich
            // danach der Stundenplan, dann ihre Downloads; (c) das naechste Semester dahinter. Alte Semester bleiben als
            // Kurs bekannt, kosten im vollen Lauf aber keinen Abruf; eigene Schalter (Einstellungen -> Module,
            // active_custom) gelten. Ihre Dateien holt Stufe (d) danach im Hintergrund (`olderOnly`,
            // `OlderSemesterLoader`), neuestes Semester zuerst, nur Dateiliste und Downloads.
            let term = SyncOrder.currentTerm(today: today, terms: courses.compactMap { c in
                c.semesterTitle.map { SyncOrder.PortalTerm(title: $0, start: c.semesterStart) } }, university: .luh)
            let chosen = selectedNow.filter { active.contains($0.id) }.enumerated().sorted { a, b in
                (SyncOrder.stage(active: true, semester: a.element.semesterTitle, current: term), a.offset)
                    < (SyncOrder.stage(active: true, semester: b.element.semesterTitle, current: term), b.offset)
            }.map(\.element)
            let olderFiles = olderOnly ? SyncOrder.newestFirst(courses.filter {
                wantedOlder.contains($0.id) && !active.contains($0.id) && (olderCourses?.contains($0.id) ?? true)
            }, semester: \.semesterTitle) : []
            // ausgewaehlte Kurse frueherer Semester: nicht eingeplant (ihre Dateien kommen erst in Stufe d)
            let older = selectedNow.filter { !active.contains($0.id) }.count
            let fileCourses = olderOnly ? olderFiles : chosen
            // Erstes Einrichten (noch kein voller Lauf, 07.11.2026): Kurse und Stundenplan zuerst zeigen, die Dateien
            // danach. Spaetere Laeufe: Dateilisten zuerst (neue Dateien sind das, worauf man wartet), dann der Stundenplan
            var timetable = StudIPScheduleSync.Outcome()
            let scheduleFirst = !olderOnly && lastRun == nil
            if scheduleFirst {
                try Task.checkCancellation()
                timetable = await StudIPScheduleSync(host: host).run(client: client, userID: uid, courses: chosen) { phase = .running($0) }
                stagesReady += 1                              // Stundenplan und Kurse schon zeigen
            }
            var remote: [StudIPFile] = []
            var wantedByCourse: [Int: [StudIPFile]] = [:]
            var checked = Set<String>()
            var unreadable: [Error] = []
            /// Unterordner, die Stud.IP nicht zeigt (403/404), und Kurse mit solchen Ordnern (nicht vollstaendig gelesen)
            var skippedFolders = 0, partial = Set<String>()
            // Tempo (07.11.2026): bis zu `parallelCourses` Kurse zugleich; bestaetigte flache Ordnerliste statt der
            // Unterordner-Abfrage je Ordner (`folderModes`). Jede Dateiliste jedes Ordners wird weiter gelesen: neue,
            // geaenderte und entfernte Dateien fallen bei jedem Lauf auf; Dateien vergleicht `storeFiles` nur ueber
            // Kennung, chdate und Groesse, geladen wird nur, was neu, geaendert oder lokal fehlend ist
            let plan = Self.folderModes(count: fileCourses.count, trusted: defaults.bool(forKey: Keys.flatFolders),
                                        lastCheck: defaults.object(forKey: Keys.folderCheckAt) as? Date,
                                        checkIndex: defaults.integer(forKey: Keys.folderCheckIndex), now: Date())
            var checks: [StudIPFolderCheck] = []
            var done = 0
            if !fileCourses.isEmpty { phase = .running("Dateien werden geprüft: 0 von \(fileCourses.count) \(fileCourses.count == 1 ? "Kurs" : "Kursen")") }
            try await withThrowingTaskGroup(of: (Int, Result<StudIPFileListing, Error>).self) { group in
                var next = 0
                func addNext() {
                    guard next < fileCourses.count else { return }
                    let i = next, id = fileCourses[i].id, mode = plan.modes[i]
                    next += 1
                    group.addTask {
                        do { return (i, .success(try await client.fileListing(courseID: id, mode: mode))) } catch { return (i, .failure(error)) }
                    }
                }
                for _ in 0..<Self.parallelCourses { addNext() }
                while let (i, result) = try await group.next() {
                    try Task.checkCancellation()
                    let c = fileCourses[i]
                    done += 1
                    phase = .running("Dateien werden geprüft: \(done) von \(fileCourses.count) \(fileCourses.count == 1 ? "Kurs" : "Kursen")")
                    let files: [StudIPFile]
                    switch result {
                    case .success(let listing):
                        files = listing.files
                        skippedFolders += listing.unreadableFolders
                        if listing.unreadableFolders > 0 { partial.insert(c.id) }
                        checks.append(listing.folderCheck)
                    case .failure(let e as StudIPError) where e.affectsOnlyItem:
                        // wie run_sync ("Fehler bei Dateiliste"): naechster Kurs; seine Dateien bleiben unveraendert
                        unreadable.append(e)
                        addNext()
                        continue
                    case .failure(let e as URLError) where !Self.endsRun(e):
                        // z. B. Zeitueberschreitung oder WLAN-Wechsel bei diesem Kurs: wie oben, die uebrigen Kurse, ihre
                        // Downloads und der Stundenplan kommen trotzdem
                        unreadable.append(e)
                        addNext()
                        continue
                    case .failure(let e):
                        throw e                                   // abgelaufen, kein Netz, Anfragegrenze, Abbruch
                    }
                    addNext()
                    remote += files
                    checked.insert(c.id)
                    // je Kurs sofort in die Datenbank: ein spaeterer Fehler verliert die schon gelesenen Kurse nicht
                    let complete = !partial.contains(c.id)
                    wantedByCourse[i] = try await db.transaction {
                        try StudIPLibrary.storeLinks($0, courseID: c.id, files, complete: complete, now: started)
                        // Videodateien zusaetzlich als Aufzeichnungen (Stream und Laden auf Wunsch, `OpencastStore`)
                        try OpencastStore.storeFileVideos($0, courseID: c.id, files, complete: complete, now: started, base: Self.base)
                        return try StudIPLibrary.storeFiles($0, files, startedAt: started, base: Self.base, localFiles: localFiles)
                    }
                }
            }
            // Downloads in der Reihenfolge der Kurse (aktuelles Semester zuerst), nicht in der Reihenfolge der Antworten
            let wanted = wantedByCourse.sorted { $0.key < $1.key }.flatMap(\.value)
            // Vergleich flache Ordnerliste gegen Baum: eine Abweichung schaltet die flache Liste ab, eine Bestaetigung an
            if checks.contains(.mismatch) {
                setFlag(Keys.flatFolders, false)
            } else if checks.contains(.confirmed) {
                // gerade erst bestaetigt (alle Kurse ueber den Baum gelesen): das gilt als Vergleich
                if !defaults.bool(forKey: Keys.flatFolders) { defaults.set(Date(), forKey: Keys.folderCheckAt) }
                setFlag(Keys.flatFolders, true)
            }
            if let i = plan.checked, checked.contains(fileCourses[i].id) {
                defaults.set(Date(), forKey: Keys.folderCheckAt)
                defaults.set(i + 1, forKey: Keys.folderCheckIndex)
            }
            // kein einziger Kurs lesbar (z. B. Stud.IP gestoert): Fehlerlauf statt "0 neue Dateien"
            if let first = unreadable.first, unreadable.count == fileCourses.count { throw first }
            // in Stud.IP nicht mehr vorhanden: aus dem einen Register (`files`), nur in vollstaendig gelesenen Kursen
            let prefix = (localFiles.stored(root) ?? "StudIP") + "/"
            let remoteIDs = Set(remote.map(\.id))
            let gone = try await db.withConnection {
                try StudIPLibrary.goneRemotely($0, remoteIDs: remoteIDs, checkedCourses: checked.subtracting(partial), under: prefix)
            }
            // Stundenplan aus Stud.IP (S5) gleich nach den Dateilisten, vor den Downloads: wer die App oeffnet, sieht
            // seine Woche sofort (`SyncOrder` Stufe a); Fehler dort brechen den Datei-Abgleich nicht ab
            if !olderOnly && !scheduleFirst {
                try Task.checkCancellation()
                timetable = await StudIPScheduleSync(host: host).run(client: client, userID: uid, courses: chosen) { phase = .running($0) }
                stagesReady += 1
            }
            // Videodateien laedt der Abgleich nicht (Entscheidung 7: grosse Dateien nur auf Wunsch); sie stehen bei den
            // Aufzeichnungen mit "Abspielen" (Stream) und "Laden". Links ebenso nicht. Alles andere wird geladen, auch
            // mit "is-downloadable": false (`downloadCandidates`, Befund 07.11.2026)
            let download = Self.downloadCandidates(wanted)
            var failed = 0
            /// davon ausdruecklich von Stud.IP verweigert (403/404): kein sofortiger neuer Lauf deswegen
            var refused = 0
            /// Kurse mit einer nicht geladenen Datei (ein frueheres Semester gilt dann nicht als fertig geladen)
            var failedCourses = Set<String>()
            // Absagen (403/404) fragt der automatische Abgleich erst nach `DownloadFailures.refusedRetryAfter` erneut;
            // jede andere nicht geladene Datei bei jedem Lauf ("Jetzt laden" in der Dateiansicht fragt immer)
            let failures = (try? await db.withConnection { try DownloadFailures.all($0) }) ?? [:]
            let nowISO = clock.nowISO
            let resting = download.filter { !DownloadFailures.dueForAutomaticRetry(failures[$0.id], now: nowISO) }
            let restingIDs = Set(resting.map(\.id))
            // nur Listen (kurzer Hintergrundlauf): die Dateien laedt der naechste volle Lauf
            let toLoad = scope == .full ? download.filter { !restingIDs.contains($0.id) } : []
            /// Fehlversuch je Datei sichtbar machen ("Nicht geladen – erneut versuchen" in der Dateiansicht)
            func noteFailure(_ f: StudIPFile, _ error: Error) async {
                failed += 1
                failedCourses.insert(f.courseID)
                let d = DownloadFailures.describe(error)
                if d.status == 403 || d.status == 404 { refused += 1 }
                let at = clock.nowISO
                _ = try? await db.transaction { try DownloadFailures.record($0, fileID: f.id, message: d.message, status: d.status, now: at) }
            }
            // je Datei ueber `UniDownloads`: erst in den Zwischenordner, pruefen, Hash, alte Fassung einer Datei mit
            // Notizen aufbewahren (S7), an ihren Platz, eintragen, Seitentexte und Notizen der neuen Fassung; ein Abbruch
            // hinterlaesst keine halbe Datei als "geladen". Vor jeder Datei der freie Platz: ein voller Speicher haelt
            // den Lauf an (`DeviceStorage.Full`), statt Datei fuer Datei zu scheitern
            for (i, f) in toLoad.enumerated() {
                try Task.checkCancellation()
                guard DeviceStorage.fits(Int64(f.size), free: DeviceStorage.availableBytes(at: root)) else { throw DeviceStorage.Full() }
                phase = .running(Self.downloadStep(i, of: toLoad.count, name: f.name))
                let rel = StudIPImport.relativePath(for: f)
                do {
                    try await downloads.load(StudIPLibrary.fileRow(f, base: Self.base), to: rel, db: db, clock: clock) { part in
                        try await client.download(fileID: f.id, to: part, name: f.name)
                    }
                } catch where DeviceStorage.isFull(error) {
                    throw DeviceStorage.Full()
                } catch let e as StudIPError where e.affectsOnlyItem {
                    // wie run_sync ("Download-Fehler"): naechste Datei; der naechste Abgleich versucht es erneut
                    await noteFailure(f, e)
                    continue
                } catch let e as URLError where !Self.endsRun(e) {
                    // z. B. Zeitueberschreitung bei einer grossen Datei: nur diese Datei, die uebrigen kommen trotzdem
                    await noteFailure(f, e)
                    continue
                } catch let e as UniDownloads.Failure {
                    // leere Antwort statt der Datei oder alte Fassung mit Notizen nicht gesichert (S7): die alte Fassung
                    // bleibt, der naechste Abgleich laedt erneut
                    await noteFailure(f, e)
                    continue
                }
                loaded += 1
            }
            await refreshEntries()                            // Dateien schon zeigen, waehrend Ergaenzungen laden
            if !olderOnly { stagesReady += 1 }
            /// ehrlicher Stand fuer die weiteren Schritte ("3 neue Dateien · Aufzeichnungen …")
            let note = Self.filesNote(loaded: loaded)
            // Kurse frueherer Semester mit vollstaendiger Liste und allen Dateien: der naechste Abgleich fragt sie nicht
            // erneut ab (alte Semester aendern sich kaum; "Dateien laden" holt sie wieder)
            let olderDone = scope == .full
                ? olderFiles.map(\.id).filter { checked.contains($0) && !partial.contains($0) && !failedCourses.contains($0) } : []
            if !olderDone.isEmpty {
                let now = clock.nowISO
                try await db.transaction { try OlderSemesters.markLoaded($0, courseIDs: olderDone, now: now) }
            }
            if olderOnly {
                // nur Dateien frueherer Semester: kein Stundenplan, keine Aufzeichnungen, kein Lernplan; Stand und
                // Zusammenfassung des letzten vollen Abgleichs bleiben
                olderFilesNote = Self.olderFilesNote(courses: olderFiles.count, loaded: loaded, failed: failed, unreadable: unreadable.count)
                await log(database, started: started, ok: true, newFiles: loaded, message: StudIPLibrary.summary(newFiles: loaded))
                phase = .idle
                return .completed
            }
            try Task.checkCancellation()
            // Stufe (a) ist durch: die Oberflaeche zeigt das aktuelle Semester ("Aktuelles Semester ist da …")
            let readyAt = clock.nowISO
            _ = try? await db.transaction { try SyncOrder.markCurrentReady($0, now: readyAt) }
            // Semester, Stud.IP-weite Ankuendigungen, Nachrichten (nur Liste), Aenderungen, Sprechstunden, Brett, Blubber (StudIPExtrasSync)
            phase = .running(note + " · Neuigkeiten werden geladen …")
            let extrasExpired = timetable.sessionExpired ? false : await StudIPExtrasSync(host: host).run(client: client, userID: uid, courses: chosen)
            try Task.checkCancellation()
            // Lehrende und Kontakte (StudIPLecturers, 06.11.2026): erst nach Stufe (a), nur im vollen Lauf, je Kurs hoechstens
            // alle 7 Tage; nur an Hochschulen mit Stud.IP. Fehler halten den Abgleich nicht an
            let lecturersExpired = timetable.sessionExpired || extrasExpired || scope == .lists ? false
                : await StudIPExtrasSync(host: host).lecturers(client: client, courses: chosen)
            try Task.checkCancellation()
            // Aufzeichnungen (Opencast): je Kurs eine Seite; Fehler eines Kurses ueberspringen nur diesen, Kurse ohne
            // Opencast sind kein Fehler; Videos laedt nur der Nutzer. Nach abgelaufener Sitzung nicht mehr fragen, im
            // kurzen Hintergrundlauf auch nicht (eine Seite je Kurs sprengte die rund 30 Sekunden)
            // Aufzeichnungen und Lernstoff (viele Anfragen je Kurs, aendern sich selten binnen Minuten) hoechstens alle
            // `slowPartsInterval` (07.11.2026); Dateien, Stundenplan und Nachrichten kommen bei jedem Lauf
            let slowDue = Self.slowPartsDue(last: defaults.object(forKey: Keys.slowPartsAt) as? Date, now: Date())
            let rec = timetable.sessionExpired || scope == .lists || !slowDue ? nil
                : await recordings.refresh(client: client, courses: chosen) { phase = .running(note + " · " + $0) }
            // Lernstoff aus Stud.IP (Courseware-Fristen, Courseware, Wiki, Forum; StudIPTextsSync), nur im vollen Lauf
            let texts = timetable.sessionExpired || rec?.sessionExpired == true || scope == .lists || !slowDue ? nil
                : await StudIPTextsSync(host: host).run(client: client, courses: chosen) { phase = .running(note + " · " + $0) }
            if rec != nil, texts != nil, rec?.sessionExpired != true, texts?.sessionExpired != true {
                defaults.set(Date(), forKey: Keys.slowPartsAt)
            }
            let linkCount = remote.filter { $0.linkURL != nil }.count
            let waiting = download.count - toLoad.count - resting.count
            let waitingText = "\(waiting) \(waiting == 1 ? "Datei wartet" : "Dateien warten") auf den Download"
            var parts = ["\(loaded) neu/geändert", "\(max(0, remote.count - linkCount - download.count)) unverändert"]
            if waiting > 0 { parts.append(waitingText) }
            if linkCount > 0 { parts.append("\(linkCount) \(linkCount == 1 ? "Link" : "Links")") }
            if failed > 0 { parts.append("\(failed) nicht geladen (Fehler)") }
            if !resting.isEmpty { parts.append("\(resting.count) von Stud.IP nicht freigegeben") }
            if !gone.isEmpty { parts.append("\(gone.count) in Stud.IP nicht mehr vorhanden") }
            if !unreadable.isEmpty { parts.append("\(unreadable.count) \(unreadable.count == 1 ? "Kurs" : "Kurse") nicht lesbar") }
            if skippedFolders > 0 { parts.append("\(skippedFolders) Ordner nicht lesbar") }
            if let n = Self.newCoursesNote(selection.newUnselected.count) { parts.append(n) }
            if let n = Self.olderCoursesNote(older) { parts.append(n) }
            parts += timetable.summary
            parts += rec?.summary ?? []
            parts += texts?.summary ?? []
            let expired = timetable.sessionExpired || rec?.sessionExpired == true || texts?.sessionExpired == true || extrasExpired
                || lecturersExpired
            if scope == .full {
                finish(summary: parts.joined(separator: ", ") + " · \(checked.count) Kurse")
                // Dateien, die an einem voruebergehenden Fehler scheiterten (Netz, Zeit, Stud.IP gestoert), holt der
                // naechste Abgleich beim Oeffnen sofort (ohne die 30 Minuten); Absagen (403/404) nicht
                setFlag(Keys.downloadsPending, failed > refused)
            } else if waiting > 0 {
                setFlag(Keys.downloadsPending, true)
            }
            let message = scope == .full ? StudIPLibrary.summary(newFiles: loaded, newEvents: timetable.result?.newEvents ?? 0,
                                                                   removedEvents: timetable.result?.removedEvents ?? 0)
                : "Hintergrund: Listen abgeglichen, " + waitingText
            await log(database, started: started, ok: true, newFiles: loaded, message: message)
            await Self.autoPlan(host: host, newFiles: loaded, weekly: scope == .full)
            // Sitzung erst beim Stundenplan oder den Aufzeichnungen abgelaufen: Dateien sind da, die Anmeldung muss neu
            phase = expired ? .needsLogin : .idle
            setFlag(Keys.sessionExpired, expired)
            if expired { Task { await renewSilently(trigger: .requestFailed) } } else { renewal.verified(at: Date()) }
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
            Task { await renewSilently(trigger: .requestFailed) }
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

    /// Meldung nach "Dateien laden" fuer fruehere Semester
    static func olderFilesNote(courses: Int, loaded: Int, failed: Int, unreadable: Int) -> String {
        if courses == 0 { return "Keine Dateien früherer Semester zu laden." }
        var text = "\(loaded) \(loaded == 1 ? "Datei" : "Dateien") aus \(courses) \(courses == 1 ? "Kurs" : "Kursen") früherer Semester geladen"
        if failed > 0 { text += ", \(failed) nicht geladen (später erneut)" }
        if unreadable > 0 { text += ", \(unreadable) \(unreadable == 1 ? "Kurs" : "Kurse") nicht lesbar" }
        return text
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

    /// Lernplan nach dem Abgleich wie am PC (`study.auto_plan_week` nach run_sync): mit `auto_plan` die laufende Woche
    /// planen, nur Stoff der Lehrwoche und den Skriptrest nach dem Marker der Vorwoche. Danach die gemeinsamen
    /// Wochentests wie `_full_sync` am PC (`WeeklyAutoTick.run`: nur mit `auto_tests`, verbundener KI und ohne anderen
    /// Hintergrundauftrag; hat er etwas veroeffentlicht, laden offene Boxen neu), nur nach einem vollen Abgleich
    /// (`weekly`), nicht im kurzen Hintergrundlauf. Nicht nach einem Abbruch (der Container wird vielleicht gerade
    /// geloescht; ein Abbruch im Takt kostet keinen Versuch); ein Fehler stoppt den Abgleich nicht.
    nonisolated static func autoPlan(host: LocalBackendHost, newFiles: Int, weekly: Bool = true) async {
        guard !Task.isCancelled, let backend = try? await host.backend() else { return }
        _ = try? await StudyAutoPlan.afterSync(backend, newFiles: newFiles)
        guard weekly, !Task.isCancelled else { return }
        // automatische Wochentests ab Pro AI (UFWeeklyAutoGate); der Index unten laeuft in jedem Tarif
        if await UFWeeklyAutoGate.check(), case .ran(_, let changed) = await WeeklyAutoTick.run(backend.context), changed {
            await MainActor.run { NotificationCenter.default.post(name: .uniflowWeeklyChanged, object: nil) }
        }
        // Dokument-Index der laufenden Woche vorwaermen (erst Bibliothek, dann sparsames Modell): nur WLAN + Laden
        guard !Task.isCancelled else { return }
        await DocIndexPrewarm.run(backend.context)
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
