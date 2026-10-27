import Foundation
import UniFlowCore
import WebKit

// Datentrennung je (Apple-Nutzer, Hochschule), docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 2.
//
// Jede Kombination hat einen eigenen Container (UniFlowCore `DataContainerLayout`) mit Datenbank, Journal,
// PDF-Zwischenspeicher, Vorschaubildern, Antwort-Zwischenspeicher, Loesungs-Bibliothek, eigenen Dokumenten, Bildern
// und Stud.IP- bzw. Learnweb-Downloads; dazu je Container ein eigener Einstellungs-Bereich (UserDefaults-Suite), ein eigener
// Schluesselbund-Eintrag fuer das Stud.IP-Sitzungs-Cookie, der Learnweb-Schluessel mit dem Praefix des Nutzers und ein
// eigener WKWebsiteDataStore(forIdentifier:) mit der UUID des Containers fuer alle Anmelde-Webansichten. Hochschul-
// Passwoerter speichert die App nicht (die merkt nur das System); frueher gemerkte entfernt `UniversityPasswordCleanup`.
//
// Wechsel der Hochschule (Einstellungen) oder des Kontos: `ContainerManager` oeffnet den passenden Container, die
// Oberflaeche baut sich neu auf (RootView mit `generation`). Objekte halten ihren Container ab der Erzeugung fest;
// ein Dokument, das waehrend des Wechsels noch sichert, schreibt in seinen alten Container, nie in den neuen.

/// Orte der Container im App-Container
enum ContainerPaths {
    static var applicationSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    /// Ordner aller Container: Application Support/UniFlowContainers/<uuid>/
    static var base: URL { applicationSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }

    /// Orte aus der Zeit vor den Containern (alles LUH): Application Support/UniFlow und Application Support/StudIP
    static var legacy: LegacyDataMigration.Sources {
        LegacyDataMigration.Sources(support: applicationSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                    studip: applicationSupport.appendingPathComponent("StudIP", isDirectory: true))
    }

    /// Ort ohne Container (vor Anmeldung und Hochschulwahl): Temp-Ordner, dort entsteht nichts Dauerhaftes
    static var none: URL { FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-ohne-container", isDirectory: true) }
}

/// Schreibrecht in einen Container. Wer laenger schreibt, als der Container lebt (ein Dokument, das beim Schliessen noch
/// sichert oder hochlaedt), prueft es vor jedem Schreiben (`FileBlobStore(canWrite:)`): "Daten dieser Hochschule
/// loeschen" entzieht es (`ContainerLeases.revoke`), bevor geloescht wird. Vorher legte ein spaeter Schreibzugriff den
/// Journal-Ordner im geloeschten Container neu an bzw. landete im leer neu geoeffneten Container mit demselben
/// Schluessel (die Notizen ueberlebten das Loeschen).
final class ContainerLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    var isValid: Bool { lock.withLock { !revoked } }
    func revoke() { lock.withLock { revoked = true } }
}

/// Ein Schreibrecht je Container-Kennung, gemeinsam fuer alle Objekte, die ihn geoeffnet haben; nach dem Entziehen
/// bekommt ein neu geoeffneter Container gleicher Kennung ein neues
enum ContainerLeases {
    private static let lock = NSLock()
    private static var current: [UUID: ContainerLease] = [:]

    static func lease(for id: UUID) -> ContainerLease {
        lock.withLock {
            if let l = current[id] { return l }
            let l = ContainerLease()
            current[id] = l
            return l
        }
    }

    static func revoke(_ id: UUID) {
        let old = lock.withLock { current.removeValue(forKey: id) }
        old?.revoke()
    }
}

/// Alles, was zu einem (Apple-Nutzer, Hochschule) gehoert.
final class ActiveContainer: @unchecked Sendable {
    let key: DataContainerKey
    let layout: DataContainerLayout
    /// Schreibrecht (entzogen beim Loeschen dieses Containers)
    let lease: ContainerLease
    let host: LocalBackendHost
    let api: APIClient
    let cache: ResponseCache
    let thumbnails: UFThumbnails
    let solutions: SolutionLibrary
    /// Online-Community dieses Containers (CloudKit; ohne iCloud-Container im Build "nicht verfügbar")
    let community: CloudKitCommunityService
    /// Einstellungen dieses Containers (Stud.IP-Kursauswahl, letzter Abgleich, Learnweb/LSF, Anzeigename beim Teilen)
    let defaults: UserDefaults
    let defaultsSuite: String
    /// Schluessel der Hochschuldienste (Learnweb) mit dem Praefix des Nutzers; nie Benutzername oder Passwort
    let tokens: UniversityTokenStore
    /// Stud.IP-Sitzungs-Cookie dieses Containers
    let cookies: StudIPCookieStore

    /// Kennung des WKWebsiteDataStore der Anmelde-Webansichten (= UUID des Containers, `DataContainerKey.websiteDataStoreID`)
    var websiteDataStoreID: UUID { key.websiteDataStoreID }

    init(key: DataContainerKey, base: URL, keychain: UniversitySecretStoring, cookieService: String, appDefaults: UserDefaults,
         clock: UniFlowClock = .system, cloud: CommunityCloud? = CommunityCloudFactory.make()) {
        self.key = key
        layout = DataContainerLayout(base: base, key: key)
        lease = ContainerLeases.lease(for: layout.identifier)
        host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: key.university)
        api = .local(host)
        cache = ResponseCache(root: layout.url(.cache))
        thumbnails = UFThumbnails(root: layout.root)
        solutions = SolutionLibrary(root: layout.solutions)
        defaultsSuite = Self.defaultsSuite(layout.identifier)
        defaults = UserDefaults(suiteName: defaultsSuite) ?? appDefaults
        let localHost = host, university = key.university.rawValue
        community = CloudKitCommunityService(cloud: cloud, university: key.university, membership: CommunityMembership(defaults: defaults),
                                             courseKeys: { await CommunityCourses.courseKeys(host: localHost, university: university) })
        tokens = UniversityTokenStore(secrets: keychain, defaults: appDefaults, userScope: key.userScope, onlyUniversity: key.university)
        cookies = StudIPCookieStore(service: cookieService, container: layout.identifier)
    }

    static func defaultsSuite(_ id: UUID) -> String { "de.uniflow.ai.container." + id.uuidString }

    // MARK: Aktiver Container (fuer Stellen ohne eigenen Bezug: AppPaths.support, LocalBackendHost.shared …)

    private static let lock = NSLock()
    private static var active: ActiveContainer?

    static var current: ActiveContainer? {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }
}

/// Abgleich eines Containers (Stud.IP, Learnweb/LSF). Vor dem Loeschen des Containers haelt ihn `ContainerManager` an
/// und wartet auf sein Ende (`stop`), damit kein laufender Abgleich Ordner, Dateien oder Einstellungen neu anlegt.
@MainActor
protocol ContainerSync: AnyObject {
    var isRunning: Bool { get }
    func stop() async
}

extension StudIPSync: ContainerSync {}
extension HildesheimConnection: ContainerSync {}

/// Oeffnet den Container zu (Apple-Nutzer, gewaehlte Hochschule), zieht beim ersten Start die alten Daten in den
/// LUH-Container des Nutzers um und loescht Container ("Daten dieser Hochschule löschen", "Konto löschen").
@MainActor
final class ContainerManager: ObservableObject {
    @Published private(set) var active: ActiveContainer?
    /// Stud.IP-Abgleich des aktiven Containers (ohne Container ein leerer, der nichts tut)
    @Published private(set) var studip: StudIPSync
    /// Learnweb und LSF des aktiven Containers der Uni Hildesheim (an der LUH und ohne Container nil)
    @Published private(set) var hildesheim: HildesheimConnection?
    /// QIS (Noten) des aktiven Containers der LUH (an der Uni Hildesheim und ohne Container nil)
    @Published private(set) var qis: QISConnection?
    /// Container laesst sich nicht oeffnen (andere Hochschule oder anderes Konto, Umzug gescheitert): Meldung
    @Published private(set) var problem: String?
    /// zaehlt jeden Wechsel; die Oberflaeche baut sich damit neu auf
    @Published private(set) var generation = 0
    /// wird nach jedem Wechsel aufgerufen (App: Session auf das Backend des Containers umstellen)
    var onChange: ((ActiveContainer?) -> Void)?

    let base: URL
    private let legacy: LegacyDataMigration.Sources
    private let keychain: UniversitySecretStoring
    private let cookieService: String
    private let appDefaults: UserDefaults
    private let clock: UniFlowClock
    /// nur die App setzt den aktiven Container fuer alle (`ActiveContainer.current`); Tests nicht
    private let publishesCurrent: Bool
    /// Transport der Hildesheimer Abgleiche (nil: URLSession mit den Cookies des Containers; Tests: feste Antworten)
    private let hildesheimTransport: HildesheimConnection.TransportFactory?
    /// Transport des QIS-Abrufs (nil: URLSession mit den Cookies des Containers; Tests und Debug-Stub: feste Antworten)
    private let qisTransport: QISConnection.TransportFactory?
    private var stores: [UUID: WKWebsiteDataStore] = [:]
    /// Abgleiche je Container, auch die eines abgeloesten (Wechsel der Hochschule waehrend eines Abgleichs). Schwach
    /// gehalten: ein laufender Abgleich haelt sich selbst, ein beendeter faellt weg.
    private struct SyncRef {
        let key: DataContainerKey
        weak var sync: ContainerSync?
    }
    private var syncs: [SyncRef] = []

    /// Merker: Cookies der alten gemeinsamen Webansicht (`WKWebsiteDataStore.default()`) ziehen noch in diesen Container
    static let legacyWebDataKey = "uniflow.legacy.webdata.target"

    init(base: URL = ContainerPaths.base, legacy: LegacyDataMigration.Sources = ContainerPaths.legacy,
         keychain: UniversitySecretStoring = UniversityKeychain(), cookieService: String = StudIPCookieStore.service,
         defaults: UserDefaults = .standard, clock: UniFlowClock = .system, publishesCurrent: Bool = true,
         hildesheimTransport: HildesheimConnection.TransportFactory? = nil, qisTransport: QISConnection.TransportFactory? = nil) {
        self.base = base
        self.legacy = legacy
        self.keychain = keychain
        self.cookieService = cookieService
        self.appDefaults = defaults
        self.clock = clock
        self.publishesCurrent = publishesCurrent
        self.hildesheimTransport = hildesheimTransport
        self.qisTransport = qisTransport
        // Neuinstallation: Stud.IP-Sitzungen der geloeschten App nicht als Anmeldung uebernehmen (vor jedem Lesen)
        StudIPCookieStore.removeLeftoversOfEarlierInstallation(service: cookieService, defaults: defaults)
        // Bestandsnutzer: frueher von der App gemerkte Hochschul-Passwoerter einmal loeschen (alle Container)
        UniversityPasswordCleanup.run(secrets: keychain, defaults: defaults)
        studip = Self.idleSync()
        DataContainerLayout.purgeTrash(base: base)
    }

    var key: DataContainerKey? { active?.key }

    /// Bestandsnutzer: frueher von der App gemerkte Hochschul-Passwoerter einmal loeschen (alle Container dieses
    /// iPads, `UniversityPasswordCleanup`). Laeuft beim Anlegen, beim Oeffnen eines Containers und beim Wechsel in den
    /// Vordergrund, bis es einmal gelungen ist (z. B. Schluesselbund beim Start im Hintergrund gesperrt); danach nur
    /// noch ein Blick auf den Merker.
    @discardableResult
    func removeRememberedPasswords() -> Bool { UniversityPasswordCleanup.run(secrets: keychain, defaults: appDefaults) }

    /// Abgleich ohne Container: kein Ordner, keine Datenbank, keine Anmeldung
    private static func idleSync() -> StudIPSync {
        let none = ContainerPaths.none
        return StudIPSync(root: DataContainerLayout.Folder.studip.url(in: none), host: .unavailable,
                          defaults: UserDefaults(suiteName: "de.uniflow.ai.container.keiner") ?? .standard, support: none,
                          cookies: StudIPCookieStore(account: "ohne-container"), websiteDataStore: .nonPersistent())
    }

    // MARK: Konto und Hochschule

    /// Nach Start, Anmeldung, Hochschulwahl oder -wechsel: alte Daten umziehen (einmal), dann den passenden Container
    /// oeffnen. Ohne Anmeldung oder Hochschule ist keiner offen.
    func sync(account: AccountStore) {
        guard let user = account.account?.userID else { deactivate(); problem = nil; return }
        if migrateLegacyData(userID: user), account.university == nil {
            // die alten Daten sind LUH-Daten (V1 kannte nur die LUH): Hochschule nicht erneut abfragen
            account.chooseUniversity(.luh)
        }
        guard let uni = account.university else { deactivate(); return }
        // gescheiterter Umzug: den LUH-Container nicht leer anlegen, die alten Daten gehoeren hinein
        if uni == .luh, let message = lastMigrationError {
            deactivate()
            problem = Self.migrationProblem(message)
            return
        }
        activate(DataContainerKey(userID: user, university: uni))
    }

    /// letzter Fehler beim Umzug (dann bleibt der LUH-Container zu, bis der Umzug gelingt)
    private(set) var lastMigrationError: String?

    static func migrationProblem(_ message: String) -> String {
        "Deine bisherigen Daten konnten nicht in den Speicher der Leibniz Universität Hannover umziehen: \(message) "
            + "Es wurde nichts gelöscht; UniFlow versucht es beim nächsten Start erneut."
    }

    /// Umzug der Daten von vor den Containern in den LUH-Container dieses Nutzers. true, wenn jetzt Daten in
    /// seinen LUH-Container gezogen sind. Scheitert er, bleibt alles am alten Ort (nichts geloescht) und `problem`
    /// sagt es; der naechste Aufruf versucht es erneut.
    @discardableResult
    func migrateLegacyData(userID: String) -> Bool {
        guard !LegacyDataMigration.isDone(base: base) else { return false }
        do {
            let report = try LegacyDataMigration.run(sources: legacy, base: base, owner: userID, clock: clock) { layout in
                try self.finishLegacyMove(into: layout)
            }
            lastMigrationError = nil
            return !report.alreadyDone && report.target == DataContainerKey(userID: userID, university: .luh).identifier
        } catch {
            lastMigrationError = LocalBackendHost.message(for: error)
            return false
        }
    }

    /// Einstellungen eines Containers aus der Zeit vor den Containern (gemeinsame UserDefaults): Stud.IP-Abgleich und
    /// der Anzeigename beim Teilen von Loesungen
    static let legacyContainerKeys = StudIPSync.defaultsKeys + [SolutionDisplayName.key]

    /// Schritte der App im Umzug (wiederholbar): Einstellungen des Containers (`legacyContainerKeys`) in seine Suite,
    /// Sitzungs-Cookie in den Eintrag des Containers; die Cookies der alten gemeinsamen Webansicht folgen nach dem
    /// Oeffnen (`moveLegacyWebData`). Gemerkte Zugangsdaten aus dieser Zeit ziehen nicht mit: die loescht
    /// `UniversityPasswordCleanup`.
    private func finishLegacyMove(into layout: DataContainerLayout) throws {
        if let suite = UserDefaults(suiteName: ActiveContainer.defaultsSuite(layout.identifier)) {
            for k in Self.legacyContainerKeys {
                guard let v = appDefaults.object(forKey: k) else { continue }
                if suite.object(forKey: k) == nil { suite.set(v, forKey: k) }
                appDefaults.removeObject(forKey: k)
            }
        }
        try StudIPCookieStore(service: cookieService, container: layout.identifier)
            .adopt(StudIPCookieStore(service: cookieService, account: StudIPCookieStore.legacyAccount))
        appDefaults.set(layout.identifier.uuidString, forKey: Self.legacyWebDataKey)
    }

    /// Cookies der alten gemeinsamen Webansicht in den Datenspeicher des LUH-Containers verschieben und den alten
    /// Speicher leeren (nur einmal; Fehler kosten hoechstens eine erneute Anmeldung, nie Daten)
    private func moveLegacyWebData(into c: ActiveContainer) async {
        guard appDefaults.string(forKey: Self.legacyWebDataKey) == c.layout.identifier.uuidString, publishesCurrent else { return }
        let old = WKWebsiteDataStore.default()
        let cookies = await old.httpCookieStore.allCookies()
        let target = websiteDataStore(for: c)
        for cookie in cookies { await target.httpCookieStore.setCookie(cookie) }
        await old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        appDefaults.removeObject(forKey: Self.legacyWebDataKey)
    }

    // MARK: Oeffnen und Schliessen

    /// Container oeffnen (anlegen und kennzeichnen bzw. Kennzeichnung pruefen). Gehoert er einer anderen Hochschule
    /// oder einem anderen Konto, bleibt er zu und `problem` erklaert es.
    func activate(_ key: DataContainerKey) {
        if active?.key == key, problem == nil { return }
        removeRememberedPasswords()
        let c = ActiveContainer(key: key, base: base, keychain: keychain, cookieService: cookieService, appDefaults: appDefaults, clock: clock)
        do {
            try c.layout.prepare(clock: clock)
            Self.protect(c.layout.root)
        } catch {
            deactivate()
            problem = LocalBackendHost.message(for: error)
            return
        }
        problem = nil
        if publishesCurrent { ActiveContainer.current = c }
        active = c
        studip = StudIPSync(root: c.layout.studip, host: c.host, clock: clock, defaults: c.defaults, support: c.layout.root,
                            university: key.university, cookies: c.cookies, websiteDataStore: websiteDataStore(for: c),
                            container: c.layout)
        hildesheim = key.university == .hildesheim
            ? HildesheimConnection(container: c, websiteDataStore: websiteDataStore(for: c), clock: clock, transport: hildesheimTransport)
            : nil
        qis = key.university == .luh
            ? QISConnection(container: c, websiteDataStore: websiteDataStore(for: c), clock: clock, transport: qisTransport)
            : nil
        syncs.removeAll { $0.sync == nil }
        syncs.append(SyncRef(key: key, sync: studip))
        if let hildesheim { syncs.append(SyncRef(key: key, sync: hildesheim)) }
        if let qis { syncs.append(SyncRef(key: key, sync: qis)) }
        generation += 1
        onChange?(c)
        Task { await checkDatabase(c) }
        Task { await moveLegacyWebData(into: c) }
        // gleich abgleichen, wenn faellig (vorher erst beim naechsten Wechsel in den Vordergrund): eine abgelaufene
        // Sitzung zeigt sich so sofort. Nicht, wenn iOS die App fuer eine Hintergrundaufgabe gestartet hat (S8): dann
        // gleicht nur die Aufgabe ab, mit ihrem Umfang und ihrer Zeit (sonst lief hier ein voller Abgleich ohne
        // Hintergrundzeit los, und die Aufgabe fand den Container besetzt). Erst im naechsten Takt gefragt, dann gibt es
        // `UIApplication`; ein Start im Vordergrund gleicht ohnehin beim Wechsel nach "aktiv" ab.
        Task { @MainActor [weak self] in
            guard let self, self.active === c, !AppActivity.isInBackground() else { return }
            self.studip.runIfDue()
            self.hildesheim?.runIfDue()
            self.qis?.runIfDue()
        }
    }

    /// Laeuft auf diesem Container ein Abgleich, auch einer eines abgeloesten Abgleich-Objekts (Wechsel waehrend eines
    /// Laufs)? Dieselbe Liste wie beim Loeschen (`syncs`); der Hintergrund startet dann keinen zweiten (S8).
    func isSyncing(_ key: DataContainerKey) -> Bool {
        syncs.contains { $0.key == key && $0.sync?.isRunning == true }
    }

    /// Datenbank gleich pruefen: gehoert sie einer anderen Hochschule (`UniversityMismatch`), nicht weiterarbeiten
    private func checkDatabase(_ c: ActiveContainer) async {
        do {
            _ = try await c.host.backend()
        } catch let e as UniversityMismatch {
            guard active === c else { return }
            deactivate()
            problem = e.description
        } catch {
            // andere Fehler (Speicher voll …) meldet jede Seite selbst; die naechste Anfrage versucht es erneut
        }
    }

    func deactivate() {
        guard active != nil else { return }
        if publishesCurrent { ActiveContainer.current = nil }
        active = nil
        studip = Self.idleSync()
        hildesheim = nil
        qis = nil
        generation += 1
        onChange?(nil)
    }

    /// Datenspeicher der Anmelde-Webansichten dieses Containers (eigene UUID, nie `.default()`)
    func websiteDataStore(for c: ActiveContainer) -> WKWebsiteDataStore {
        if let s = stores[c.websiteDataStoreID] { return s }
        let s = WKWebsiteDataStore(forIdentifier: c.websiteDataStoreID)
        stores[c.websiteDataStoreID] = s
        return s
    }

    /// Ordner mit Dateischutz (nach dem ersten Entsperren lesbar) und im iCloud-Backup (Notizen, Plan); die
    /// Zwischenspeicher darin nehmen sich selbst aus (`DataContainerLayout.setExcludedFromBackup`, StudIP)
    private static func protect(_ root: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        try? DataContainerLayout.setExcludedFromBackup(root, false)
    }

    // MARK: Loeschen

    /// "Daten dieser Hochschule löschen": genau dieser Container (Datenbank, Dateien, Notizen, Zwischenspeicher),
    /// sein Datenspeicher der Webansichten, sein Sitzungs-Cookie, der Learnweb-Schluessel dieser Hochschule und
    /// seine Einstellungen. Die andere Hochschule bleibt unberuehrt. War er offen, geht es mit einem leeren weiter.
    /// Laufende Abgleiche des Containers werden vorher angehalten und abgewartet (`remove`).
    /// - Returns: nil, wenn alles geloescht ist; sonst die Meldung, was blieb (fuer die Oberflaeche; vorher meldete
    ///   sie immer "geloescht", auch wenn der Ordner oder ein Schluessel blieb)
    @discardableResult
    func deleteUniversityData(_ key: DataContainerKey) async -> String? {
        let wasActive = active?.key == key
        if wasActive { deactivate() }
        let left = await remove(key)
        if wasActive { activate(key) }
        return Self.deletionProblem(left)
    }

    /// "Konto löschen": alle Container des Nutzers samt Webdaten, Schluesselbund und Einstellungen; laufende Abgleiche
    /// werden vorher angehalten und abgewartet. Rueckgabe wie `deleteUniversityData`.
    @discardableResult
    func deleteAllData(userID: String) async -> String? {
        if active?.key.userID == userID { deactivate() }
        var left: [String] = []
        for uni in UniversityKey.allCases { left += await remove(DataContainerKey(userID: userID, university: uni)) }
        let tokens = UniversityTokenStore(secrets: keychain, defaults: appDefaults, userScope: DataContainerKey.userScope(userID))
        tokens.deleteAll()
        if UniversityKey.allCases.contains(where: { uni in uni.profile.tokenServices.contains { tokens.token(uni, service: $0) != nil } }),
           !left.contains(Self.leftKey) {
            left.append(Self.leftKey)
        }
        // Anzeigename von vor den Containern (gemeinsame UserDefaults), falls der Umzug ihn nicht mitgenommen hat
        appDefaults.removeObject(forKey: SolutionDisplayName.key)
        // empfangene Loesungen, die noch ausserhalb der Container lagen (Documents/Inbox)
        SolutionSharing.purgeInbox()
        return Self.deletionProblem(Array(Set(left)).sorted())
    }

    static let leftFiles = "Dateien und Notizen"
    static let leftKey = "Learnweb-Schlüssel"
    static let leftSession = "Stud.IP-Anmeldung"

    /// Meldung "Nicht alles liess sich loeschen ..." zu den Resten (nil ohne Reste)
    static func deletionProblem(_ left: [String]) -> String? {
        guard !left.isEmpty else { return nil }
        return "Nicht alles ließ sich löschen (\(left.joined(separator: ", "))). Bitte versuche es erneut."
    }

    /// Abgleiche eines Containers anhalten und auf ihr Ende warten (danach schreibt keiner mehr hinein)
    private func stopSyncs(_ key: DataContainerKey) async {
        let running = syncs.filter { $0.key == key }.compactMap(\.sync)
        syncs.removeAll { $0.key == key || $0.sync == nil }
        for s in running { await s.stop() }
    }

    /// Rueckgabe: was nach dem Loeschen noch da ist (leer = alles weg)
    private func remove(_ key: DataContainerKey) async -> [String] {
        let layout = DataContainerLayout(base: base, key: key)
        // zuerst das Schreibrecht entziehen: offene Dokumente sichern und laden danach nichts mehr hinein
        ContainerLeases.revoke(layout.identifier)
        await stopSyncs(key)
        StudIPCookieStore(service: cookieService, container: layout.identifier).clear()
        UniversityTokenStore(secrets: keychain, defaults: appDefaults, userScope: key.userScope).deleteAll(for: key.university)
        await removeWebsiteData(key.websiteDataStoreID)
        AppTemp.remove(container: layout.identifier)                       // Teilen-Dateien dieses Containers in tmp
        let suite = ActiveContainer.defaultsSuite(layout.identifier)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? layout.remove()
        // noch einmal nachsehen: was waehrend des Loeschens entstand, geht ebenfalls (ohne Kennzeichnung schreibt kein
        // Abgleich mehr hinein, `UniDownloads`)
        if layout.exists() { try? layout.remove() }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        // pruefen statt annehmen: was blieb, sagt die Oberflaeche
        var left: [String] = []
        if layout.exists() { left.append(Self.leftFiles) }
        let tokens = UniversityTokenStore(secrets: keychain, defaults: appDefaults, userScope: key.userScope, onlyUniversity: key.university)
        if key.university.profile.tokenServices.contains(where: { tokens.token(key.university, service: $0) != nil }) { left.append(Self.leftKey) }
        if !StudIPCookieStore(service: cookieService, container: layout.identifier).load().isEmpty { left.append(Self.leftSession) }
        return left
    }

    /// Webdaten eines Containers leeren und seinen Datenspeicher entfernen (ist er noch in Gebrauch, bleibt er leer
    /// zurueck und wird beim naechsten Mal entfernt)
    private func removeWebsiteData(_ id: UUID) async {
        let store = stores.removeValue(forKey: id) ?? WKWebsiteDataStore(forIdentifier: id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }
}
