import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Audit 08.11.2026, Pakete 35, 37 und 40 (docs/audit/AUDIT-2026-11-08-PAKET-35-37-40.md): Kontowechsel auf demselben
/// iPad (Abmelden, anderes Konto anmelden), laufende Abgleiche und Downloads waehrend eines Wechsels oder Loeschens,
/// Uni-Mail im Hintergrund, Geraete-Abgleich (G2) je Container. Erfundene Apple-Nutzer, Cookies, Module und Mails; eigene
/// Schluesselbund-Dienste und UserDefaults-Suiten; nie ein Netz (UniStubProtocol, Transporte des Tests).
@MainActor
final class AuditPaket353740AppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private let bob = "009876.erfunden-bob.\(UUID().uuidString.prefix(8))"
    private let mailUser = "erika.muster@stud.uni-hannover.de"
    private var websiteStores: [UUID] = []

    override func setUp() async throws {
        bed = try ContainerTestBed(name: "audit353740", clock: .fixed(berlin: "2026-11-09T08:00:00")!)
    }

    override func tearDown() async throws {
        UniStubProtocol.reset()
        for layout in DataContainerLayout.all(base: bed.containers, userID: bob) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            websiteStores.append(layout.identifier)
        }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        await bed.tearDown()
        bed = nil
    }

    // MARK: Hilfen

    /// Container-Verwaltung wie in der App; Uni-Mail (SOGo), Hildesheim und QIS ueber `UniStubProtocol`
    private func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: SOGoSite.all.map(\.host) + URLSessionUniTransport.hildesheimDomains,
                                              configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                publishesCurrent: false, hildesheimTransport: stub, qisTransport: stub, uniMailTransport: stub)
    }

    /// Ein Konto-Speicher wie in der App (einer fuer alle Anmeldungen auf diesem iPad)
    private func accountStore() -> AccountStore {
        AccountStore(secrets: ContainerTestBed.MemorySecrets(), defaults: bed.defaults, checker: ContainerTestBed.Authorized(), observeRevocation: false)
    }

    /// Mit Apple anmelden, Tarifwahl gesehen, Hochschule gewaehlt, Anmeldeseiten durch; Container oeffnen
    @discardableResult
    private func signIn(_ a: AccountStore, _ m: ContainerManager, _ id: String, _ uni: UniversityKey = .luh) throws -> ActiveContainer {
        a.signIn(userID: id, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(uni)
        a.markLoginDone()
        m.sync(account: a)
        let c = try XCTUnwrap(m.active, m.problem ?? "kein Container")
        XCTAssertEqual(c.key.userID, id)
        websiteStores.append(c.websiteDataStoreID)
        return c
    }

    /// Abmelden wie in den Einstellungen: Konto weg, RootView schliesst den Container (`ContainerTrigger`)
    private func signOut(_ a: AccountStore, _ m: ContainerManager) {
        XCTAssertTrue(a.signOut())
        m.sync(account: a)
        XCTAssertNil(m.active, "nach dem Abmelden ist kein Container offen")
    }

    private func suiteKeys(_ layout: DataContainerLayout, prefix: String = "uniflow.") -> [String] {
        let s = ActiveContainer.defaultsSuite(layout.identifier)
        let domain = UserDefaults(suiteName: s)?.persistentDomain(forName: s) ?? [:]
        return domain.filter { k, v in k.hasPrefix(prefix) && !(k == "uniflow.studip.courses" && (v as? [String])?.isEmpty == true) }
            .keys.sorted()
    }

    private func cookie(_ name: String, _ value: String, domain: String, path: String = "/") -> HTTPCookie {
        bed.cookie(name, value, domain: domain, path: path)
    }

    // MARK: Geraete-Abgleich (G2) mit Attrappe

    /// Dienst des Geraete-Abgleichs: liefert `changes` (optional erst nach Freigabe) und merkt sich jede Sendung
    private final class FakeDeviceService: DeviceSyncTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var pushed: [String] = []
        let gate = StubGate()
        let gated: Bool
        let changes: JSONValue

        init(changes: JSONValue = .object([:]), gated: Bool = false) {
            self.changes = changes
            self.gated = gated
        }

        var pushes: [String] { lock.withLock { pushed } }

        func syncChanges(query: String) async throws -> JSONValue {
            if gated {
                let gate = self.gate
                await Task.detached { gate.pass() }.value
            }
            return .object(["changes": changes, "tombstones": .array([]), "cursor": .string("2026-11-09T07:00:00.000Z"), "has_more": .bool(false)])
        }

        func syncPush(_ body: JSONValue) async throws -> JSONValue {
            lock.withLock { pushed.append(body.jsonString()) }
            return .object(["results": .array([]), "mapping": .array([]), "conflicts": .array([])])
        }
    }

    private func moduleNames(_ c: ActiveContainer) async throws -> [String] {
        let db = try await c.host.backend().context.database
        return try await db.withConnection { try $0.query("SELECT name FROM modules ORDER BY name").compactMap { $0["name"]?.string } }
    }

    // MARK: P35-05 / Hauptauftrag: Abmelden, anderes Konto anmelden

    /// Konto A legt Daten an und meldet sich ab; Konto B meldet sich auf demselben iPad an: B sieht nichts von A (Module,
    /// Einstellungen, Stud.IP-Sitzung, Webdaten, Einstellungs-Suite, Konto-Anschluss), die Sitzung der App zeigt auf B,
    /// und der Geraete-Abgleich von B sendet nichts von A. Wieder als A angemeldet ist alles von A da.
    func testSigningOutAndInWithAnotherAccountShowsAndUploadsNothingOfTheFirst() async throws {
        let m = manager()
        let a = accountStore()
        let session = Session(local: .local(.unavailable), defaults: bed.defaults)
        m.onChange = { [weak session] c in session?.useLocal(c?.api ?? .local(.unavailable)) }
        let ada = try signIn(a, m, bed.user)
        _ = try await ada.api.value("/api/modules", method: "POST", body: ["name": "Ada-Geheimmodul"])
        _ = try await ada.api.value("/api/settings", method: "PUT", body: ["user_name": "Ada Erfunden"])
        try ada.cookies.save([cookie("Seminar_Session", "sitzung-ada", domain: "studip.uni-hannover.de")])
        await m.websiteDataStore(for: ada).httpCookieStore.setCookie(cookie("sso-ADA", "x", domain: "sso.idm.uni-hannover.de"))
        ada.defaults.set("ada", forKey: "uniflow.audit.marker")
        XCTAssertTrue(m.studip.hasStoredSession)
        XCTAssertEqual(m.account.aiConsentAccount, "geraet:" + ada.key.userScope)

        signOut(a, m)
        XCTAssertFalse(m.studip.hasStoredSession, "ohne Konto keine Stud.IP-Sitzung")
        XCTAssertEqual(m.account.aiConsentAccount, "geraet:ohne", "Konto-Anschluss ohne Apple-Nutzer")
        XCTAssertNil(m.account.user)

        let bobC = try signIn(a, m, bob)
        XCTAssertNotEqual(bobC.layout.root, ada.layout.root)
        XCTAssertTrue((session.api?.transport as? LocalTransport)?.host === bobC.host, "die App fragt das Backend von B")
        let modules = try await bobC.api.value("/api/modules").jsonString()
        XCTAssertFalse(modules.contains("Ada"), modules)
        let settings = try await bobC.api.value("/api/settings").jsonString()
        XCTAssertFalse(settings.contains("Ada Erfunden"), settings)
        XCTAssertFalse(m.studip.hasStoredSession, "Stud.IP-Sitzung von A nicht bei B")
        XCTAssertTrue(bobC.cookies.load().isEmpty)
        let web = await m.websiteDataStore(for: bobC).httpCookieStore.allCookies()
        XCTAssertTrue(web.isEmpty, "\(web.map(\.name))")
        XCTAssertNil(bobC.defaults.string(forKey: "uniflow.audit.marker"))
        XCTAssertTrue(m.studip.entries.isEmpty)
        XCTAssertEqual(m.account.aiConsentAccount, "geraet:" + bobC.key.userScope)
        XCTAssertNil(m.account.user)
        XCTAssertNil(m.account.planStatus)
        XCTAssertNil(m.account.credits)

        // Geraete-Abgleich von B (wie StudoraAccountLink.syncNow: Datenbank des offenen Containers): nichts von A
        let service = FakeDeviceService()
        let r = await DeviceSync(database: try await bobC.host.backend().context.database, transport: service, device: "ipad-test").run(account: "konto-b")
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertFalse(service.pushes.isEmpty, "B sendet seine eigenen Daten")
        for body in service.pushes {
            XCTAssertFalse(body.contains("Ada"), body)
            XCTAssertFalse(body.contains("sitzung-ada"), body)
        }

        // zurueck zu A: alles von A da, nichts von B
        signOut(a, m)
        let again = try signIn(a, m, bed.user)
        XCTAssertEqual(again.layout.root, ada.layout.root)
        let names = try await moduleNames(again)
        XCTAssertTrue(names.contains("Ada-Geheimmodul"), "\(names)")
        XCTAssertTrue(m.studip.hasStoredSession)
        XCTAssertEqual(again.defaults.string(forKey: "uniflow.audit.marker"), "ada")
    }

    // MARK: P35-01: "Konto löschen" auf dem iPad und das StudiNow-Konto beim Dienst

    /// Seit 12.11.2026 (eine Apple-Anmeldung fuer alles) loescht "Konto löschen" das Konto beim Dienst mit
    /// (`AccountDeletion`, FirstAppleLoginAccountAppTests); die Rueckfrage sagt das ehrlich, ohne Dienst-Sitzung auf diesem
    /// Geraet sagt sie, was dann gilt. Die Verknuepfung "Mit Apple anmelden" widerruft der Dienst beim Loeschen; der Weg
    /// in den Einstellungen des iPads bleibt genannt.
    func testDeleteAccountDialogNamesTheServiceAccountThatStays() {
        XCTAssertFalse(DeleteAccountText.appleID.contains("nirgends außerhalb"), DeleteAccountText.appleID)
        XCTAssertFalse(DeleteAccountText.appleID.contains("nur auf diesem iPad"), DeleteAccountText.appleID)
        XCTAssertTrue(DeleteAccountText.appleID.contains("Mit Apple anmelden"))
        let service = DeleteAccountText.service
        XCTAssertTrue(service.contains("StudiNow-Konto"), service)
        XCTAssertTrue(service.contains("ebenfalls gelöscht"), service)
        XCTAssertFalse(DeleteAccountText.shows(serviceSignedIn: false).contains(service))
        XCTAssertTrue(DeleteAccountText.shows(serviceSignedIn: false).contains(DeleteAccountText.serviceUnknown))
        XCTAssertTrue(DeleteAccountText.shows(serviceSignedIn: true).contains(service))
    }

    // MARK: Paket 40 Test 5: Modulwechsel waehrend der Antwort

    /// Direkter Wechsel von einem Modul zum naechsten (Seitenleiste): SwiftUI behaelt den Zustand der Seite (gleicher Zweig
    /// in `MainView`). Die Seite zeigt eine Antwort nur, wenn sie zu ihrem Modul gehoert; vorher stand das vorige Modul
    /// unter der neuen Adresse, bis die neue Antwort kam, und nach einem Fehler beim Laden dauerhaft.
    func testModulePageShowsOnlyTheResponseOfItsOwnModule() async throws {
        let m = manager()
        let c = try signIn(accountStore(), m, bed.user)
        let a = try await c.api.value("/api/modules", method: "POST", body: ["name": "Analysis"])
        let b = try await c.api.value("/api/modules", method: "POST", body: ["name": "Chemie"])
        let first = try XCTUnwrap(a["id"]?.int), second = try XCTUnwrap(b["id"]?.int)
        let d = try await c.api.value("/api/modules/\(first)")
        XCTAssertTrue(ModulePage.shows(d, moduleID: first))
        XCTAssertFalse(ModulePage.shows(d, moduleID: second), "Antwort von Analysis nie unter Chemie")
        XCTAssertFalse(ModulePage.shows(nil, moduleID: first))
    }

    // MARK: P37-02: Geraete-Abgleich laeuft beim Kontowechsel

    /// Der Abgleich von A haelt seine Datenbank ab dem Start fest (StudoraAccountLink.syncNow liest `backend` vor dem
    /// Lauf): wechselt das iPad waehrenddessen zu B, landet die Antwort des Dienstes nur bei A, nie bei B.
    func testDeviceSyncRunningDuringAnAccountSwitchWritesOnlyIntoItsOwnContainer() async throws {
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        let changes: JSONValue = ["modules": .array([["id": .number(1), "name": "Vom-Dienst-fuer-Ada", "sync_version": .number(1),
                                                      "sync_updated_at": "2026-11-09T06:00:00.000Z", "sync_device": "windows"]])]
        let service = FakeDeviceService(changes: changes, gated: true)
        let db = try await ada.host.backend().context.database
        let run = Task { await DeviceSync(database: db, transport: service, device: "ipad-test").run(account: "konto-a") }
        try await bed.waitUntil("Abgleich von A wartet auf den Dienst") { service.gate.wasReached }

        signOut(a, m)
        let bobC = try signIn(a, m, bob)
        service.gate.release()
        let r = await run.value
        XCTAssertTrue(r.ok, r.error ?? "")
        let adaNames = try await moduleNames(ada)
        XCTAssertTrue(adaNames.contains("Vom-Dienst-fuer-Ada"), "\(adaNames)")
        let bobNames = try await moduleNames(bobC)
        XCTAssertFalse(bobNames.contains("Vom-Dienst-fuer-Ada"), "\(bobNames)")
    }

    /// P37-03 (Rest): Der Geraete-Abgleich des Konto-Anschlusses steht nicht in der Liste der Abgleiche, auf die das
    /// Loeschen wartet. Endet er erst nach "Daten dieser Hochschule löschen", gehoert seine Antwort zur geloeschten
    /// Datenbank: im leer neu geoeffneten Container (gleicher Ort) steht nichts davon (festgenagelt; SQLite schreibt
    /// ueber die alte Verbindung nie in die neue Datei).
    func testDeviceSyncEndingAfterTheContainerWasDeletedLeavesNothingInTheFreshOne() async throws {
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        let changes: JSONValue = ["modules": .array([["id": .number(1), "name": "Nach-dem-Loeschen", "sync_version": .number(1),
                                                      "sync_updated_at": "2026-11-09T06:00:00.000Z", "sync_device": "windows"]])]
        let service = FakeDeviceService(changes: changes, gated: true)
        let db = try await ada.host.backend().context.database
        let run = Task { await DeviceSync(database: db, transport: service, device: "ipad-test").run(account: "konto-a") }
        try await bed.waitUntil("Abgleich wartet auf den Dienst") { service.gate.wasReached }
        let left = await m.deleteUniversityData(ada.key)
        XCTAssertNil(left)
        let fresh = try XCTUnwrap(m.active)
        XCTAssertEqual(fresh.layout.root, ada.layout.root, "gleicher Ort, leer neu angelegt")
        service.gate.release()
        _ = await run.value
        let names = try await moduleNames(fresh)
        XCTAssertFalse(names.contains("Nach-dem-Loeschen"), "\(names)")
        let state = try await fresh.host.backend().context.database.withConnection { c in
            try c.query("SELECT name FROM sqlite_master WHERE name='sync_link_state'").count
        }
        XCTAssertEqual(state, 0, "kein Abgleich-Stand im neuen Container")
    }

    // MARK: P35-07: Hintergrundlauf beim Kontowechsel

    /// Ein Hintergrundlauf von A endet erst, nachdem das iPad zu B gewechselt hat: sein Stand landet im Container von A,
    /// bei B steht nichts, und es kommt keine Mitteilung (sie gehoerte zu A).
    func testBackgroundRunEndingAfterAnAccountSwitchWritesOnlyIntoItsContainerAndStaysSilent() async throws {
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        let settings = BackgroundSyncSettings(defaults: bed.defaults)
        settings.notify = true
        let n = RecordingNotifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: settings, scheduler: NoScheduler(), notifier: n)
        b.allowed = { true }
        let fake = HoldingSync()
        fake.report = BackgroundSyncReport(newFiles: 3)
        b.target = { _ in fake }
        let run = Task { await b.perform(.refresh) }
        try await bed.waitUntil("Hintergrundlauf von A laeuft") { fake.isRunning }

        signOut(a, m)
        let bobC = try signIn(a, m, bob)
        fake.release = true
        _ = await run.value
        XCTAssertTrue(n.posts.isEmpty, "keine Mitteilung zu den Dateien von A, waehrend B angemeldet ist: \(n.posts.map(\.body))")
        XCTAssertNotNil(BackgroundSyncState(defaults: ada.defaults).last, "Stand im Container von A")
        XCTAssertNil(BackgroundSyncState(defaults: bobC.defaults).last, "nichts bei B")
        XCTAssertEqual(suiteKeys(bobC.layout), [])
    }

    // MARK: P35-02 / P35-07: Uni-Mail im Hintergrund beim Kontowechsel

    /// SOGo nachgebaut (fixtures/sogo/raw); `gate`: jede Antwort wartet, bis der Test sie freigibt
    private func installSOGo(gate: StubGate? = nil) throws {
        func fx(_ name: String) throws -> Data {
            try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/sogo/raw/\(name)"))
        }
        let answers: [String: Data] = ["/Mail/0/folderINBOX/view": try fx("folder-inbox.json"), "/Mail/0/view": try fx("mailboxes.json"),
                                       "/Mail/unseenCount": try fx("unseen.json"), "/Calendar/eventslist": try fx("events.json")]
        UniStubProtocol.install { seen in
            gate?.pass()
            let path = seen.url.absoluteString.components(separatedBy: "?")[0]
            if let d = answers.first(where: { path.hasSuffix($0.key) })?.value {
                return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/json"], body: d)
            }
            return UniStubProtocol.Reply(status: 404, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
    }

    /// Uni-Mail des offenen LUH-Containers angemeldet (Cookies wie nach der Anmeldung, erfunden)
    private func connectMail(_ m: ContainerManager) async throws -> UniMailConnection {
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        let store = mail.websiteDataStore.httpCookieStore
        await store.setCookie(cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        await store.setCookie(cookie("XSRF-TOKEN", "tok%2B1", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        mail.signedIn(user: mailUser)
        return mail
    }

    /// Der Hintergrundlauf liest den Posteingang von A; waehrenddessen meldet sich B an. Die Mitteilung "N neue E-Mails"
    /// gehoert zu A und kommt nicht, solange B angemeldet ist (wie bei neuen Dateien: nur fuer den offenen Container).
    func testBackgroundMailOfThePreviousAccountPostsNoNoticeAfterASwitch() async throws {
        let gate = StubGate()
        try installSOGo(gate: gate)
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        let mail = try await connectMail(m)
        mail.defaultsForTests.set(120, forKey: UniMailConnection.Keys.lastUID)
        mail.notify = true
        let n = RecordingNotifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults),
                                         scheduler: NoScheduler(), notifier: n)
        b.allowed = { true }
        let run = Task { await b.runUniMail(ada, kind: .refresh) }
        try await bed.waitUntil("Posteingang von A wird gelesen") { gate.wasReached }

        signOut(a, m)
        try signIn(a, m, bob)
        gate.release()
        let r = await run.value
        XCTAssertEqual(r?.newMessages, 8, "der Lauf selbst gehoert A und zaehlt dort")
        XCTAssertTrue(n.posts.isEmpty, "keine Mitteilung zu den Mails von A, waehrend B angemeldet ist: \(n.posts.map(\.body))")
    }

    /// Ohne passenden Container, ohne Abgleich, in der Demo oder waehrend eines Wechsels liest der Hintergrund keine Mail
    /// (eigene Bedingungen in `runUniMail`, gleich streng wie das Gate des Abgleichs; Ausnahme nur ein laufender
    /// Abgleich im Vordergrund, docs/SYNC-REIHENFOLGE-2026-11-05.md "Uni-Mail zuerst")
    func testBackgroundMailFollowsTheSameGateAsTheSync() async throws {
        try installSOGo()
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        _ = try await connectMail(m)
        let settings = BackgroundSyncSettings(defaults: bed.defaults)
        let b = BackgroundSyncController(containers: m, account: a, settings: settings, scheduler: NoScheduler(), notifier: RecordingNotifier())
        b.allowed = { false }
        var r = await b.runUniMail(ada, kind: .refresh)
        XCTAssertNil(r, "automatische Abgleiche nicht erlaubt")
        b.allowed = { true }
        settings.enabled = false
        r = await b.runUniMail(ada, kind: .refresh)
        XCTAssertNil(r, "Hintergrundabgleich aus")
        settings.enabled = true
        r = await b.runUniMail(ada, kind: .refresh, expired: { true })
        XCTAssertNil(r, "Zeit von iOS um")
        a.resetLoginStep()
        r = await b.runUniMail(ada, kind: .refresh)
        XCTAssertNil(r, "Anmeldeseiten noch offen")
        a.markLoginDone()
        a.chooseUniversity(.hildesheim)
        r = await b.runUniMail(ada, kind: .refresh)
        XCTAssertNil(r, "Wechsel der Hochschule")
        a.chooseUniversity(.luh)
        _ = try await m.setDemo(true)
        r = await b.runUniMail(ada, kind: .refresh)
        XCTAssertNil(r, "Demo")
        _ = try await m.setDemo(false)
        XCTAssertTrue(UniStubProtocol.requests.isEmpty, "keine Anfrage an SOGo: \(UniStubProtocol.requests.map(\.url))")
        r = await b.runUniMail(ada, kind: .refresh)
        XCTAssertNotNil(r, "im passenden Container liest er")
    }

    // MARK: P37-03: Loeschen waehrend Uni-Mail liest

    /// "Daten dieser Hochschule löschen" waehrend der Posteingang gelesen wird: der Lauf schreibt danach nichts mehr,
    /// weder in den leer neu geoeffneten Container noch in die geloeschte Einstellungs-Suite (vorher stand dort wieder
    /// "zuletzt geprueft" und die Zahl der ungelesenen). Ebenso nach "Konto löschen".
    func testDeletingWhileUniMailReadsLeavesNoMailStateBehind() async throws {
        let gate = StubGate()
        try installSOGo(gate: gate)
        let m = manager()
        let a = accountStore()
        let ada = try signIn(a, m, bed.user)
        let mail = try await connectMail(m)
        let read = Task { await mail.refreshInbox() }
        try await bed.waitUntil("Posteingang wird gelesen") { gate.wasReached }
        let deletion = Task { await m.deleteUniversityData(ada.key) }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.release()
        _ = await read.value
        let left = await deletion.value
        XCTAssertNil(left)
        let fresh = try XCTUnwrap(m.active)
        XCTAssertEqual(fresh.key, ada.key)
        XCTAssertEqual(suiteKeys(fresh.layout), [], "kein Stand des alten Laufs im neuen Container")
        XCTAssertFalse(m.uniMail?.isConnected ?? true)

        // Konto loeschen, waehrend der Kalender uebernommen wird
        let gate2 = StubGate()
        try installSOGo(gate: gate2)
        let mail2 = try await connectMail(m)
        let calendar = Task { await mail2.importCalendar(days: 7) }
        try await bed.waitUntil("Kalender wird gelesen") { gate2.wasReached }
        let deletion2 = Task { await m.deleteAllData(userID: bed.user) }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate2.release()
        _ = await calendar.value
        _ = await deletion2.value
        for layout in DataContainerLayout.all(base: bed.containers, userID: bed.user) {
            XCTAssertFalse(layout.exists(), "\(layout.university)")
            XCTAssertEqual(suiteKeys(layout), [], "\(layout.university): keine Einstellungen eines geloeschten Kontos")
        }
    }

    // MARK: P40 / P37-03: "Jetzt laden" waehrend des Loeschens

    /// Stud.IP mit einem Kurs und einer Datei (erfunden); der Download wartet auf die Freigabe des Tests
    private final class OneFileStudIP: StudIPTransport, @unchecked Sendable {
        let gate = StubGate()
        private let lock = NSLock()
        private var downloads = 0
        var downloadCount: Int { lock.withLock { downloads } }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let path = (url.path + (url.query.map { "?" + $0 } ?? ""))
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            let json: String
            switch path {
            case "/jsonapi.php/v1/users/me": json = #"{"data":{"id":"u1","type":"users"}}"#
            case "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester":
                json = #"""
                    {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Numerik","course-number":"T-42"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
                     "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
                    """#
            case "/jsonapi.php/v1/courses/c1/folders?page[limit]=200": json = #"{"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}}]}"#
            case "/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500":
                json = #"{"data":[{"id":"d1","attributes":{"name":"Blatt 3.pdf","filesize":12,"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}}]}"#
            case "/jsonapi.php/v1/folders/r1/folders?page[limit]=200": json = #"{"data":[]}"#
            case "/jsonapi.php/v1/users/u1/schedule": json = #"{"data":[],"links":{}}"#
            default: return HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
            }
            return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
        }

        func download(_ url: URL, to file: URL) async throws -> HTTPReply {
            lock.withLock { downloads += 1 }
            let gate = self.gate
            await Task.detached { gate.pass() }.value
            try Data("%PDF-1.7 LUH".utf8).write(to: file)
            return HTTPReply(status: 200, contentType: "application/pdf")
        }
    }

    private func studIPClient(_ t: StudIPTransport) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    /// "Jetzt laden" einer einzelnen Datei laeuft, als "Daten dieser Hochschule löschen" kommt. `stop` wartet zwar nur
    /// auf den grossen Abgleich, aber die Zwischendatei des Einzel-Downloads liegt im Container (`UniDownloads.partial`)
    /// und geht mit ihm: der Download scheitert, nichts landet im leer neu geoeffneten Container, das alte
    /// Abgleich-Objekt laedt danach nichts mehr (festgenagelt, Paket 40 Test 1).
    func testDeletingDuringASingleFileLoadLeavesNoFileInTheFreshContainer() async throws {
        let m = manager()
        let a = accountStore()
        let luh = try signIn(a, m, bed.user)
        try luh.cookies.save([cookie("Seminar_Session", "sitzung-ada", domain: "studip.uni-hannover.de")])
        let stud = OneFileStudIP()
        let sync = m.studip
        _ = await sync.run(client: studIPClient(stud), scope: .lists)            // nur die Liste, nichts geladen
        XCTAssertEqual(stud.downloadCount, 0)
        let load = Task { await sync.loadFile(id: "d1", client: self.studIPClient(stud)) }
        try await bed.waitUntil("Download laeuft") { stud.gate.wasReached }
        let deletion = Task { await m.deleteUniversityData(luh.key) }
        try await Task.sleep(nanoseconds: 200_000_000)
        stud.gate.release()
        let outcome = await load.value
        _ = await deletion.value
        XCTAssertNotEqual(outcome, .loaded, "angehalten: nicht als geladen gemeldet")
        let fresh = try XCTUnwrap(m.active)
        XCTAssertEqual(fresh.key, luh.key)
        let files = fresh.layout.studip.appendingPathComponent("files")
        let leftovers = FileManager.default.enumerator(at: fresh.layout.studip, includingPropertiesForKeys: nil)?.allObjects.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.path), "keine Datei im neuen Container: \(leftovers)")
        let rows = try await fresh.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE id='d1'")?.int
        XCTAssertEqual(rows, 0)
        let again = await sync.loadFile(id: "d1", client: studIPClient(stud))
        XCTAssertEqual(again, .notStudIP, "das alte Abgleich-Objekt laedt nichts mehr")
    }

    /// Paket 40 Test 2: "Jetzt laden" derselben Datei, waehrend der volle Abgleich sie gerade laedt. Jeder Lauf hat einen
    /// eigenen Zwischenordner, das Ersetzen ist atomar (`UniDownloads`): danach liegt genau eine vollstaendige Datei da,
    /// ein Eintrag mit Ablageort, kein Zwischenordner (festgenagelt).
    func testSingleFileLoadNextToTheFullSyncOfTheSameFileLeavesOneCompleteFile() async throws {
        let m = manager()
        let luh = try signIn(accountStore(), m, bed.user)
        try luh.cookies.save([cookie("Seminar_Session", "sitzung-ada", domain: "studip.uni-hannover.de")])
        let stud = OneFileStudIP()
        let sync = m.studip
        _ = await sync.run(client: studIPClient(stud), scope: .lists)
        let full = Task { await sync.run(client: self.studIPClient(stud)) }
        try await bed.waitUntil("Abgleich laedt die Datei") { stud.gate.wasReached }
        let single = Task { await sync.loadFile(id: "d1", client: self.studIPClient(stud)) }
        try await bed.waitUntil("Einzel-Download laeuft auch") { stud.downloadCount == 2 }
        stud.gate.release()
        let outcome = await single.value
        _ = await full.value
        XCTAssertEqual(outcome, .loaded)
        let files = luh.layout.studip.appendingPathComponent("files")
        let stored = FileManager.default.enumerator(at: files, includingPropertiesForKeys: nil)?.allObjects
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        XCTAssertEqual(stored.count, 1, "\(stored.map(\.lastPathComponent))")
        XCTAssertEqual(try stored.first.map { try Data(contentsOf: $0) }, Data("%PDF-1.7 LUH".utf8))
        let rows = try await luh.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE id='d1' AND local_path IS NOT NULL")?.int
        XCTAssertEqual(rows, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UniDownloads.partial(in: luh.layout.studip).path), "kein Zwischenordner")
    }
}

// MARK: - Attrappen

private final class RecordingNotifier: BackgroundNotifying {
    var posts: [BackgroundNotice.Content] = []
    func requestPermission() async -> Bool { true }
    func isAllowed() async -> Bool { true }
    func post(_ content: BackgroundNotice.Content, id: String, thread: String) async { posts.append(content) }
    func schedule(_ content: BackgroundNotice.Content, id: String, thread: String, at date: Date) async {}
    func cancel(id: String) {}
}

private final class NoScheduler: BackgroundTaskScheduling {
    func pending() async -> [BackgroundSyncKind: Date?] { [:] }
    func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {}
    func cancel(_ kind: BackgroundSyncKind) {}
}

/// Abgleich, der wartet, bis der Test `release` setzt
private final class HoldingSync: BackgroundSyncable {
    var fileSource = "Stud.IP"
    var usableSources = ["Stud.IP"]
    var isRunning = false
    var report = BackgroundSyncReport()
    var release = false

    func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport {
        isRunning = true
        defer { isRunning = false }
        while !release { try? await Task.sleep(nanoseconds: 5_000_000) }
        return report
    }
}
