import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Hochschulwahl und Datentrennung je (Apple-Nutzer, Hochschule) in der App (docs/AUFTRAG-HILDESHEIM-IPAD.md
/// Abschnitt 1 und 2): Container mit Datenbank, Dateien, Journal, Zwischenspeicher, Loesungen, Einstellungen,
/// Schluesselbund-Eintraegen und eigenem WKWebsiteDataStore. Nur Temp-Ordner, eigene Schluesselbund-Dienste und
/// UserDefaults-Suiten, erfundene Nutzer, Cookies und Zugangsdaten; kein Netz, keine echte Hochschulseite.
@MainActor
final class DataSeparationAppTests: XCTestCase {

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct Authorized: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private var appSupport: URL!
    private var keychain: UniversityKeychain!
    private var cookieService = ""
    private var suite = ""
    private var defaults: UserDefaults!
    private var websiteStores: [UUID] = []
    private let user = "001234.erfunden-ada.\(UUID().uuidString.prefix(8))"
    private let otherUser = "009876.erfunden-bob.\(UUID().uuidString.prefix(8))"
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!

    override func setUp() async throws {
        try await super.setUp()
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-trennung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        keychain = UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)")
        cookieService = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
        suite = "uniflow.tests.trennung.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        keychain.accounts().forEach(keychain.remove)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: cookieService] as CFDictionary)
        defaults.removePersistentDomain(forName: suite)
        for u in [user, otherUser] {
            for layout in DataContainerLayout.all(base: base, userID: u) {
                let s = ActiveContainer.defaultsSuite(layout.identifier)
                UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
                websiteStores.append(layout.identifier)
            }
        }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        try? FileManager.default.removeItem(at: appSupport)
        try await super.tearDown()
    }

    private var base: URL { appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }
    private var legacy: LegacyDataMigration.Sources {
        LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                    studip: appSupport.appendingPathComponent("StudIP", isDirectory: true))
    }

    private func manager() -> ContainerManager {
        ContainerManager(base: base, legacy: legacy, keychain: keychain, cookieService: cookieService, defaults: defaults,
                         clock: clock, publishesCurrent: false)
    }

    private func account(_ id: String? = nil, planShown: Bool = true) -> AccountStore {
        let a = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        if let id {
            a.signIn(userID: id, name: nil, email: nil)
            if planShown { a.markPlanShown() }
        }
        return a
    }

    private func active(_ m: ContainerManager, file: StaticString = #filePath, line: UInt = #line) throws -> ActiveContainer {
        let c = try XCTUnwrap(m.active, "kein Container offen: \(m.problem ?? "-")", file: file, line: line)
        websiteStores.append(c.websiteDataStoreID)
        return c
    }

    private func cookie(_ name: String, _ value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
                                .expires: Date().addingTimeInterval(3600)])!
    }

    private func cookies(_ m: ContainerManager, _ c: ActiveContainer) async -> [String] {
        await m.websiteDataStore(for: c).httpCookieStore.allCookies().map(\.name).sorted()
    }

    // MARK: Erster Start

    func testFirstStartWithUniversityChoiceOpensThatContainer() async throws {
        let a = account(user)
        let m = manager()
        XCTAssertEqual(a.stage, .universityPicker, "nach Anmeldung und Tarifwahl: Hochschule wählen")
        m.sync(account: a)
        XCTAssertNil(m.active, "ohne Hochschule ist kein Container offen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(DataContainerKey(userID: user, university: .luh).identifier.uuidString).path),
                       "keine Hochschule angenommen")

        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let c = try active(m)
        XCTAssertEqual(c.key, DataContainerKey(userID: user, university: .hildesheim))
        XCTAssertEqual(a.stage, .universityLogin, "Container offen, zuerst die Anmeldeseiten der Hochschule")
        a.markLoginDone()
        XCTAssertEqual(a.stage, .ready)
        XCTAssertEqual(try c.layout.manifest()?.university, "hildesheim")
        let s = try await c.api.value("/api/settings")
        XCTAssertEqual(s["university"]?.string, "hildesheim", "Datenbank gehoert der gewaehlten Hochschule")
        XCTAssertFalse(m.studip.offersStudIP)
        XCTAssertEqual(m.studip.root, c.layout.studip)
        let mode = UFDataMode.current(api: c.api, studip: m.studip)
        XCTAssertEqual(mode, .local(.otherSources))
        XCTAssertTrue(mode.hasOtherSources, "statt \u{201E}Stud.IP verbinden\u{201C} die Karten von Learnweb und LSF")
        XCTAssertEqual(m.hildesheim?.key, c.key, "Learnweb und LSF dieses Containers")
        XCTAssertEqual(m.hildesheim?.websiteDataStore, m.websiteDataStore(for: c), "Anmeldung im Datenspeicher des Containers")
        let services = try await c.api.value("/api/services")["services"]?.array?.compactMap { $0["key"]?.string }
        XCTAssertEqual(services?.first, "learnweb")

        // zweiter Start: derselbe Container, ohne erneute Wahl
        let again = manager()
        let a2 = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a2.signIn(userID: user, name: nil, email: nil)
        XCTAssertEqual(a2.stage, .ready)
        again.sync(account: a2)
        XCTAssertEqual(try active(again).layout.root, c.layout.root)
    }

    func testPickerTextsAreHonestAndNothingIsPreselected() {
        XCTAssertTrue(UniversityOption.services(.hildesheim).contains("Learnweb"))
        XCTAssertTrue(UniversityOption.services(.hildesheim).contains("LSF"))
        XCTAssertFalse(UniversityOption.services(.hildesheim).contains("folgen"), "Learnweb und LSF gibt es jetzt")
        XCTAssertTrue(UniversityOption.services(.luh).contains("Stud.IP"))
        XCTAssertTrue(UniversityPickerView.note.contains("getrennt"))
        let notice = UniversitySwitchDialog.notice(from: .luh, to: .hildesheim)
        XCTAssertTrue(notice.contains("Daten der Leibniz Universität Hannover bleiben getrennt"))
        XCTAssertTrue(notice.contains("sofort mit dem Speicher der Universität Hildesheim"))
        XCTAssertTrue(DeleteUniversityDataDialog.explanation(.luh).contains("Die Daten der Universität Hildesheim bleiben unberührt"))
    }

    // MARK: Zwei Hochschulen nacheinander befuellen

    /// Fuellt den offenen Container: Einstellung, Kursauswahl, Learnweb-Schluessel (nur Hildesheim; Passwoerter legt die
    /// App nie ab), Sitzungs-Cookie, Cookie der Webansicht, Journal, Antwort-Zwischenspeicher, Loesungsordner
    private func fill(_ m: ContainerManager, _ c: ActiveContainer, tag: String) async throws {
        _ = try await c.api.value("/api/settings", method: "PUT", body: ["user_name": .string("Ada \(tag)")])
        m.studip.selectedCourses = ["kurs-\(tag)"]
        if c.key.university == .hildesheim {
            XCTAssertTrue(c.tokens.saveToken("Schluessel-\(tag)", .hildesheim, service: "learnweb"),
                          "Schluesselbund nicht beschreibbar – mit CODE_SIGN_IDENTITY=- bauen")
        }
        try c.cookies.save([cookie("sitzung", "wert-\(tag)", domain: "studip.uni-hannover.de")])
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(cookie("sso-\(tag)", "x", domain: "sso.example.org"))
        let journal = LocalJournal(store: FileBlobStore(root: c.layout.journal), documentID: "doc-\(tag)", namespace: .local)
        try journal.writePage("p1", JournalPage(page: ["objects": .array([["id": .string("tinte-\(tag)")]])], localRev: 1))
        c.cache.store(["tag": .string(tag)], for: "uniflow-local://device//api/overview")
        try FileManager.default.createDirectory(at: c.layout.solutions, withIntermediateDirectories: true)
        try Data(tag.utf8).write(to: c.layout.solutions.appendingPathComponent("probe.txt"))
    }

    /// Prueft, dass der offene Container genau die Daten `tag` hat und nichts von `foreign`
    private func assertOnly(_ m: ContainerManager, _ c: ActiveContainer, tag: String, foreign: String,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let s = try await c.api.value("/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "Ada \(tag)", "Datenbank", file: file, line: line)
        XCTAssertEqual(m.studip.selectedCourses, ["kurs-\(tag)"], "Einstellungen des Abgleichs", file: file, line: line)
        if c.key.university == .hildesheim {
            XCTAssertEqual(c.tokens.token(.hildesheim, service: "learnweb"), "Schluessel-\(tag)", "Learnweb-Schluessel", file: file, line: line)
        } else {
            XCTAssertNil(c.tokens.token(.hildesheim, service: "learnweb"), "Schluesselbund: andere Hochschule nicht lesbar", file: file, line: line)
            XCTAssertFalse(c.tokens.saveToken("x", .hildesheim, service: "learnweb"), "und nicht beschreibbar", file: file, line: line)
        }
        XCTAssertFalse(keychain.accounts().contains(where: UniversityProfile.isRetiredLoginSecret), "nie Benutzername oder Passwort",
                       file: file, line: line)
        XCTAssertEqual(c.cookies.load().map(\.value), ["wert-\(tag)"], "Sitzungs-Cookie", file: file, line: line)
        let web = await cookies(m, c)
        XCTAssertEqual(web, ["sso-\(tag)"], "Cookies der Webansicht", file: file, line: line)
        XCTAssertNil(try LocalJournal(store: FileBlobStore(root: c.layout.journal), documentID: "doc-\(foreign)", namespace: .local).load(),
                     "Journal", file: file, line: line)
        XCTAssertNotNil(try LocalJournal(store: FileBlobStore(root: c.layout.journal), documentID: "doc-\(tag)", namespace: .local).load(),
                        file: file, line: line)
        XCTAssertEqual(c.cache.load("uniflow-local://device//api/overview")?.0["tag"]?.string, tag, "Zwischenspeicher", file: file, line: line)
        XCTAssertEqual(try? String(contentsOf: c.layout.solutions.appendingPathComponent("probe.txt"), encoding: .utf8), tag, "Loesungen",
                       file: file, line: line)
        XCTAssertTrue(UniversityKeychain(service: cookieService).accounts().allSatisfy { $0.hasPrefix(StudIPCookieStore.legacyAccount + ".") },
                      "Sitzungs-Cookies nur in Eintraegen je Container", file: file, line: line)
    }

    func testTwoUniversitiesFilledOneAfterTheOtherCannotReadEachOther() async throws {
        let a = account(user)
        let m = manager()
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let luh = try active(m)
        try await fill(m, luh, tag: "LUH")

        // Wechsel in den Einstellungen: sofort der Speicher der anderen Hochschule, ohne Neustart
        let generation = m.generation
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let hi = try active(m)
        XCTAssertGreaterThan(m.generation, generation, "Oberflaeche baut sich neu auf")
        XCTAssertNotEqual(hi.layout.root, luh.layout.root)
        XCTAssertNotEqual(hi.websiteDataStoreID, luh.websiteDataStoreID)
        let empty = try await hi.api.value("/api/settings")
        XCTAssertEqual(empty["user_name"]?.string, "", "nichts von der LUH in der Datenbank")
        XCTAssertTrue(m.studip.selectedCourses.isEmpty)
        XCTAssertTrue(hi.cookies.load().isEmpty)
        let hiWeb = await cookies(m, hi)
        XCTAssertEqual(hiWeb, [], "keine Cookies der LUH-Webansicht")
        XCTAssertNil(hi.cache.load("uniflow-local://device//api/overview"))
        try await fill(m, hi, tag: "HI")
        try await assertOnly(m, hi, tag: "HI", foreign: "LUH")

        // zurueck zur LUH: alles noch da, nichts aus Hildesheim
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let luhAgain = try active(m)
        XCTAssertEqual(luhAgain.layout.root, luh.layout.root)
        try await assertOnly(m, luhAgain, tag: "LUH", foreign: "HI")

        // Stud.IP abmelden raeumt nur Sitzung und Webdaten dieses Containers
        await m.studip.signOut()
        XCTAssertTrue(luhAgain.cookies.load().isEmpty)
        let afterSignOut = await cookies(m, luhAgain)
        XCTAssertEqual(afterSignOut, [])
        let hiCookies = await cookies(m, hi)
        XCTAssertEqual(hiCookies, ["sso-HI"], "Webdaten der anderen Hochschule bleiben")
        XCTAssertEqual(hi.cookies.load().map(\.value), ["wert-HI"])

        // anderes Konto auf demselben iPad, ebenfalls LUH: eigener Container, sieht nichts
        let b = account(otherUser)
        b.chooseUniversity(.luh)
        m.sync(account: b)
        let bob = try active(m)
        XCTAssertNotEqual(bob.layout.root, luh.layout.root)
        let bs = try await bob.api.value("/api/settings")
        XCTAssertEqual(bs["user_name"]?.string, "")
        XCTAssertNil(bob.tokens.token(.hildesheim, service: "learnweb"))
        XCTAssertNil(UniversityTokenStore(secrets: keychain, defaults: defaults, userScope: bob.key.userScope, onlyUniversity: .hildesheim)
            .token(.hildesheim, service: "learnweb"), "Learnweb-Schluessel eines anderen Kontos nicht lesbar")
    }

    // MARK: Loeschen

    func testDeletingOneUniversityLeavesTheOtherUntouched() async throws {
        let a = account(user)
        let m = manager()
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let hi = try active(m)
        try await fill(m, hi, tag: "HI")
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let luh = try active(m)
        try await fill(m, luh, tag: "LUH")

        await m.deleteUniversityData(luh.key)
        let fresh = try active(m)
        XCTAssertEqual(fresh.key, luh.key, "es geht mit einem leeren LUH-Container weiter")
        XCTAssertFalse(fresh === luh)
        let s = try await fresh.api.value("/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "", "Datenbank geloescht")
        XCTAssertTrue(m.studip.selectedCourses.isEmpty, "Einstellungen geloescht")
        XCTAssertTrue(fresh.cookies.load().isEmpty, "Sitzungs-Cookie geloescht")
        let web = await cookies(m, fresh)
        XCTAssertEqual(web, [], "Webdaten geloescht")
        XCTAssertNil(try LocalJournal(store: FileBlobStore(root: fresh.layout.journal), documentID: "doc-LUH", namespace: .local).load(),
                     "Notizen geloescht")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.layout.solutions.appendingPathComponent("probe.txt").path))

        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        try await assertOnly(m, try active(m), tag: "HI", foreign: "LUH")
    }

    func testDeletingTheAccountRemovesAllItsContainersButNoOtherAccount() async throws {
        let m = manager()
        let b = account(otherUser)
        b.chooseUniversity(.luh)
        m.sync(account: b)
        try await fill(m, try active(m), tag: "BOB")

        let a = account(user)
        for uni in [UniversityKey.luh, .hildesheim] {
            a.chooseUniversity(uni)
            m.sync(account: a)
            try await fill(m, try active(m), tag: "ADA-\(uni.rawValue)")
        }
        // wie AccountStore.deletionSteps, ohne die Server-PIN der Test-App anzufassen
        let id = user
        await a.deleteAccount(also: [{ await m.deleteAllData(userID: id) }])
        m.sync(account: a)
        XCTAssertEqual(a.stage, .welcome)
        XCTAssertNil(m.active)
        for layout in DataContainerLayout.all(base: base, userID: user) {
            XCTAssertFalse(layout.exists(), "\(layout.university)")
            XCTAssertTrue(StudIPCookieStore(service: cookieService, container: layout.identifier).load().isEmpty)
        }
        let scope = DataContainerKey.userScope(user) + "."
        XCTAssertFalse(keychain.accounts().contains { $0.hasPrefix(scope) }, "kein Schluessel des Kontos mehr")

        b.chooseUniversity(.luh)
        m.sync(account: b)
        try await assertOnly(m, try active(m), tag: "BOB", foreign: "ADA-luh")
    }

    /// Konto loeschen und mit derselben Apple-ID neu anmelden (Wunsch des Inhabers 27.10.2026): Tarifwahl, Hochschule und
    /// Anmeldeseiten kommen wieder, beide Hochschulen sind leer, die Webansichten haben keine Sitzung und kein Cookie,
    /// im Schluesselbund liegt nichts des Kontos - nichts ist vorgespeichert (Passwoerter merkt sich ohnehin nur iOS)
    func testAfterDeletingTheAccountTheNextSignInStartsWithoutAnyStoredLogin() async throws {
        let m = manager()
        let a = account(user)
        for uni in [UniversityKey.hildesheim, .luh] {
            a.chooseUniversity(uni)
            m.sync(account: a)
            try await fill(m, try active(m), tag: "ADA-\(uni.rawValue)")
            a.markLoginDone()
        }
        XCTAssertEqual(a.stage, .ready)
        let id = user
        await a.deleteAccount(also: [{ await m.deleteAllData(userID: id) }])
        m.sync(account: a)
        XCTAssertEqual(a.stage, .welcome)

        // dieselbe Apple-ID meldet sich wieder an
        a.signIn(userID: user, name: nil, email: nil)
        XCTAssertEqual(a.stage, .planPicker, "Tarifwahl kommt wieder")
        a.markPlanShown()
        XCTAssertEqual(a.stage, .universityPicker, "Hochschule wird neu gewählt")
        for uni in [UniversityKey.luh, .hildesheim] {
            a.chooseUniversity(uni)
            m.sync(account: a)
            XCTAssertEqual(a.stage, .universityLogin, "Anmeldeseiten kommen wieder: \(uni)")
            let fresh = try active(m)
            let names = await cookies(m, fresh)
            XCTAssertEqual(names, [], "keine alte Sitzung in der Webansicht: \(uni)")
            let records = await m.websiteDataStore(for: fresh).dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            XCTAssertTrue(records.isEmpty, "keine Webdaten: \(uni)")
            XCTAssertTrue(fresh.cookies.load().isEmpty, "keine Stud.IP-Sitzung: \(uni)")
            XCTAssertNil(fresh.tokens.token(uni, service: "learnweb"), "kein Learnweb-Schluessel: \(uni)")
            let settings = try await fresh.api.value("/api/settings")
            XCTAssertNotEqual(settings["user_name"]?.string, "Ada ADA-\(uni.rawValue)", "Einstellungen der alten Daten weg: \(uni)")
        }
        let scope = DataContainerKey.userScope(user) + "."
        XCTAssertFalse(keychain.accounts().contains { $0.hasPrefix(scope) }, "nichts des Kontos im Schluesselbund")
    }

    // MARK: Umzug der alten Daten

    /// Stand vor dieser Version: Datenbank und Notizen unter Application Support/UniFlow, Downloads unter
    /// Application Support/StudIP, Kursauswahl in den UserDefaults, Sitzungs-Cookie und (damals von der App gemerkte)
    /// Zugangsdaten ohne Nutzer
    private func makeLegacyData() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: legacy.support.appendingPathComponent("db"), withIntermediateDirectories: true)
        let b = try await LocalBackend.open(path: legacy.support.appendingPathComponent("db/uniflow.sqlite").path, clock: clock)
        try await b.context.database.transaction { c in
            try c.execute("UPDATE settings SET value='Ada alt' WHERE key='user_name'")
            try c.execute("INSERT INTO courses(id, title, created_at) VALUES ('c1', 'Testkurs Analysis', '2026-10-20')")
            try c.execute("INSERT INTO files(id, course_id, name, local_path) VALUES ('s1', 'c1', 'Blatt 1.pdf', 'Library/Application Support/StudIP/files/Testkurs Analysis/Blatt 1.pdf')")
        }
        let pdf = legacy.studip.appendingPathComponent("files/Testkurs Analysis/Blatt 1.pdf")
        try fm.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-alt".utf8).write(to: pdf)
        let journal = LocalJournal(store: FileBlobStore(root: legacy.support.appendingPathComponent("journal")), documentID: "s1", namespace: .local)
        try journal.writePage("p1", JournalPage(page: ["objects": .array([["id": "tinte-alt"]])], localRev: 2))
        defaults.set(["c1"], forKey: "uniflow.studip.courses")
        defaults.set("1 neu/geändert", forKey: "uniflow.studip.lastSummary")
        try StudIPCookieStore(service: cookieService, account: StudIPCookieStore.legacyAccount)
            .save([cookie("sitzung", "wert-alt", domain: "studip.uni-hannover.de")])
        defaults.set(true, forKey: UniversityTokenStore.installedKey)                 // Installation gab es schon
        defaults.set(true, forKey: StudIPCookieStore.installedKey)
        XCTAssertTrue(keychain.write("ab1-alt", account: "luh.studip.user"))
        XCTAssertTrue(keychain.write("Passwort-alt", account: "luh.studip.password"))
        defaults.set(false, forKey: "uniflow.login.remember.luh.qis")                // Schalter "Auf diesem iPad merken" von damals
        defaults.set("Ada beim Teilen", forKey: SolutionDisplayName.key)
    }

    func testLegacyDataMovesIntoTheLUHContainerOfTheCurrentUserOnFirstStart() async throws {
        try await makeLegacyData()
        let a = account(user)                                           // bisheriger Nutzer, Tarifwahl schon gezeigt
        XCTAssertEqual(a.stage, .universityPicker)
        let m = manager()
        m.sync(account: a)
        XCTAssertEqual(a.university, .luh, "die alten Daten sind LUH-Daten: keine erneute Abfrage")
        XCTAssertEqual(a.stage, .universityLogin, "einmal die Anmeldeseiten (Stud.IP ist schon verbunden und wird uebersprungen, QIS ist neu)")
        let c = try active(m)
        XCTAssertEqual(c.key, DataContainerKey(userID: user, university: .luh))

        // verschoben, nicht kopiert
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.support.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.studip.path))
        let s = try await c.api.value("/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "Ada alt")
        let (data, http) = try await c.api.data("/api/files/s1/content")
        XCTAssertEqual(http.statusCode, 200, "Datei unter dem umgeschriebenen Pfad")
        XCTAssertEqual(data, Data("%PDF-alt".utf8))
        let snap = try LocalJournal(store: FileBlobStore(root: c.layout.journal), documentID: "s1", namespace: .local).load()
        XCTAssertEqual(snap?.pages["p1"]?.localRev, 2, "Notizen erhalten, ungesendet bleibt ungesendet")
        XCTAssertEqual(m.studip.selectedCourses, ["c1"])
        XCTAssertEqual(m.studip.lastSummary, "1 neu/geändert")
        XCTAssertNil(defaults.object(forKey: "uniflow.studip.courses"), "aus den gemeinsamen UserDefaults entfernt")
        XCTAssertEqual(c.cookies.load().map(\.value), ["wert-alt"])
        XCTAssertTrue(StudIPCookieStore(service: cookieService, account: StudIPCookieStore.legacyAccount).load().isEmpty)
        // damals gemerkte Zugangsdaten ziehen nicht mit, sie sind geloescht (Passwoerter merkt nur noch iOS)
        XCTAssertNil(keychain.read("luh.studip.user"), "kein Eintrag ohne Nutzer mehr")
        XCTAssertNil(keychain.read("luh.studip.password"))
        XCTAssertNil(keychain.read(UniversityProfile.scoped("luh.studip.password", userScope: c.key.userScope)), "auch nicht umgezogen")
        XCTAssertFalse(keychain.accounts().contains(where: UniversityProfile.isRetiredLoginSecret))
        XCTAssertNil(defaults.object(forKey: "uniflow.login.remember.luh.qis"), "Schalter entfernt")
        XCTAssertTrue(defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
        XCTAssertTrue(LegacyDataMigration.isDone(base: base))
        XCTAssertEqual(SolutionDisplayName.load(c.defaults), "Ada beim Teilen", "Anzeigename beim Teilen mit umgezogen")
        XCTAssertNil(defaults.object(forKey: SolutionDisplayName.key), "nicht mehr in den gemeinsamen Einstellungen")

        // anderes Konto danach: bekommt nichts von den alten Daten und waehlt selbst
        let b = account(otherUser)
        m.sync(account: b)
        XCTAssertNil(b.university)
        XCTAssertNil(m.active)

        // Neustart: kein zweiter Umzug, dieselben Daten
        let restarted = manager()
        let a2 = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a2.signIn(userID: user, name: nil, email: nil)
        restarted.sync(account: a2)
        let again = try await active(restarted).api.value("/api/settings")
        XCTAssertEqual(again["user_name"]?.string, "Ada alt")
    }

    func testFailedLegacyMoveKeepsTheLUHContainerClosedAndRetriesLater() async throws {
        try await makeLegacyData()
        // Ordner aller Container laesst sich nicht anlegen (an seiner Stelle liegt eine Datei)
        try Data("kein Ordner".utf8).write(to: base)
        let a = account(user)
        a.chooseUniversity(.luh)
        let m = manager()
        m.sync(account: a)
        XCTAssertNil(m.active, "kein leerer LUH-Container, solange die alten Daten nicht drin sind")
        let problem = try XCTUnwrap(m.problem)
        XCTAssertTrue(problem.contains("nichts gelöscht"), problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.support.appendingPathComponent("db/uniflow.sqlite").path), "alte Daten unberuehrt")

        // naechster Versuch nach Behebung
        try FileManager.default.removeItem(at: base)
        m.sync(account: a)
        XCTAssertNil(m.problem)
        let s = try await active(m).api.value("/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "Ada alt")
    }

    // MARK: Falscher Container wird nicht geoeffnet

    func testContainerOfOtherUniversityIsNotOpenedAndExplained() async throws {
        // Datenbank der LUH liegt im Hildesheimer Container (Kennzeichnung stimmt, Datenbank nicht)
        let luhLayout = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .luh))
        let hiLayout = DataContainerLayout(base: base, key: DataContainerKey(userID: user, university: .hildesheim))
        try luhLayout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: luhLayout.databaseDirectory, withIntermediateDirectories: true)
        let lb = try await LocalBackend.open(path: luhLayout.databaseURL.path, clock: clock, university: "luh")
        _ = try await lb.context.database.query("PRAGMA wal_checkpoint(TRUNCATE)")
        try hiLayout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: hiLayout.databaseDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: luhLayout.databaseURL, to: hiLayout.databaseURL)

        let a = account(user)
        a.chooseUniversity(.hildesheim)
        let m = manager()
        m.sync(account: a)
        for _ in 0..<100 where m.problem == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(m.active)
        XCTAssertEqual(m.problem, UniversityMismatch(stored: "luh", expected: "hildesheim").description)
        XCTAssertTrue(m.problem?.contains("Leibniz Universität Hannover") == true)

        // vertauschte Kennzeichnung: Container der LUH sagt "hildesheim"
        let wrong = DataContainerManifest(university: "hildesheim", owner: luhLayout.ownerScope, createdAt: "2026-10-26T10:00:00")
        try JSONEncoder().encode(wrong).write(to: luhLayout.manifestURL)
        a.chooseUniversity(.luh)
        m.sync(account: a)
        XCTAssertNil(m.active)
        XCTAssertTrue(m.problem?.contains("Universität Hildesheim") == true, m.problem ?? "")
        // die Webansicht nutzt nie den gemeinsamen Datenspeicher
        XCTAssertNotEqual(luhLayout.identifier, hiLayout.identifier)
    }

    // MARK: Anzeigename beim Teilen

    /// Der Name beim Teilen einer Loesung gehoert dem Container: ein zweites Konto sieht ihn nicht, Loeschen entfernt ihn
    func testSolutionDisplayNameStaysWithItsContainer() async throws {
        let m = manager()
        let a = account(user)
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let luh = try active(m)
        SolutionDisplayName.save("Ada LUH", luh.defaults)
        XCTAssertNil(defaults.object(forKey: SolutionDisplayName.key), "nicht in den gemeinsamen Einstellungen")

        let b = account(otherUser)
        b.chooseUniversity(.luh)
        m.sync(account: b)
        XCTAssertEqual(SolutionDisplayName.load(try active(m).defaults), "", "anderes Konto sieht den Namen nicht")
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        XCTAssertEqual(SolutionDisplayName.load(try active(m).defaults), "", "andere Hochschule desselben Kontos ebenso nicht")
        a.chooseUniversity(.luh)
        m.sync(account: a)
        XCTAssertEqual(SolutionDisplayName.load(try active(m).defaults), "Ada LUH")
        XCTAssertEqual(SolutionDisplayName.load(nil), "", "ohne Container nichts")

        await m.deleteUniversityData(luh.key)
        XCTAssertEqual(SolutionDisplayName.load(try active(m).defaults), "", "mit den Daten der Hochschule geloescht")
        SolutionDisplayName.save("Ada neu", try active(m).defaults)
        defaults.set("Ada alt", forKey: SolutionDisplayName.key)                  // Rest von vor den Containern
        await m.deleteAllData(userID: user)
        XCTAssertNil(defaults.object(forKey: SolutionDisplayName.key), "Konto löschen entfernt auch den alten Eintrag")
        for layout in DataContainerLayout.all(base: base, userID: user) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            XCTAssertNil(UserDefaults(suiteName: s)?.persistentDomain(forName: s)?[SolutionDisplayName.key])
        }
    }

    // MARK: Loeschen waehrend eines Abgleichs

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    /// Container-Verwaltung mit dem Hildesheimer Abgleich ueber den Stub statt des Netzes
    private func hildesheimManager() -> ContainerManager {
        ContainerManager(base: base, legacy: legacy, keychain: keychain, cookieService: cookieService, defaults: defaults, clock: clock,
                         publishesCurrent: false,
                         hildesheimTransport: { store in await URLSessionUniTransport.make(dataStore: store, configuration: UniStubProtocol.configuration()) })
    }

    /// Learnweb verbinden und abgleichen; der erste Download haelt im Stub an, bis `gate` ihn freigibt
    private func startLearnwebSync(_ m: ContainerManager, _ gate: StubGate) async throws
        -> (ActiveContainer, HildesheimConnection, Task<HildesheimSync.Report?, Never>) {
        let c = try active(m)
        let h = try XCTUnwrap(m.hildesheim)
        h.syncsAfterSignIn = false
        let token = "TestSchluessel0123456789abcdef", lw = "https://www.uni-hildesheim.de/learnweb2026"
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: lw))
        let uni = HildesheimAppTests.uniHildesheim(base: lw, lsf: "https://lsf.uni-hildesheim.de", token: token, ics: Data(),
                                                   contents: try repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json"))
        UniStubProtocol.install { r in
            if r.url.path.contains("/webservice/pluginfile.php/") { gate.pass() }
            return uni(r)
        }
        let run = Task { await h.run() }
        try await waitUntil("Learnweb-Download laeuft") { gate.wasReached }
        return (c, h, run)
    }

    /// Eintraege der App in der Einstellungs-Suite eines Containers, die ein Abgleich schreibt (ein frisch geoeffneter
    /// Container legt von sich aus nur die leere Stud.IP-Kursauswahl an)
    private func suiteKeys(_ layout: DataContainerLayout) -> [String] {
        let s = ActiveContainer.defaultsSuite(layout.identifier)
        let domain = UserDefaults(suiteName: s)?.persistentDomain(forName: s) ?? [:]
        return domain.filter { k, v in k.hasPrefix("uniflow.") && !(k == "uniflow.studip.courses" && (v as? [String])?.isEmpty == true) }
            .keys.sorted()
    }

    /// Stud.IP mit festen Antworten (ein Kurs, eine Datei, erfunden); der Download wartet, bis der Test ihn freigibt
    private final class WaitingStudIP: StudIPTransport, @unchecked Sendable {
        let gate = StubGate()

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let path = (url.path + (url.query.map { "?" + $0 } ?? ""))
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            let json: String
            switch path {
            case "/jsonapi.php/v1/users/me": json = #"{"data":{"id":"u1","type":"users"}}"#
            case "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester":
                json = #"""
                    {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Numerik","course-number":"T-42"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
                     "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
                    """#
            case "/jsonapi.php/v1/courses/c1/folders?page[limit]=200": json = #"{"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}}]}"#
            case "/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500":
                json = #"{"data":[{"id":"d1","attributes":{"name":"Blatt 3.pdf","filesize":12,"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}}]}"#
            case "/jsonapi.php/v1/folders/r1/folders?page[limit]=200": json = #"{"data":[]}"#
            default: return HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
            }
            return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
        }

        func download(_ url: URL, to file: URL) async throws -> HTTPReply {
            let gate = self.gate
            await Task.detached { gate.pass() }.value
            try Data("%PDF-1.7 LUH".utf8).write(to: file)
            return HTTPReply(status: 200, contentType: "application/pdf")
        }
    }

    /// 240: Schneller Wechsel von Hochschule und Konto, waehrend der Stud.IP-Abgleich der LUH noch laedt: Jeder neue
    /// Container bekommt einen eigenen Abgleich, eigene Cookies und eigene Webdaten; die Datei des alten Laufs landet
    /// nur im LUH-Container des ersten Kontos.
    func testSwitchingUniversityAndAccountDuringARunningSyncKeepsEverythingApart() async throws {
        let a = account(user)
        a.chooseUniversity(.luh)
        let m = manager()
        m.sync(account: a)
        let luh = try active(m)
        try luh.cookies.save([cookie("Seminar_Session", "sitzung-ada", domain: "studip.uni-hannover.de")])
        await m.websiteDataStore(for: luh).httpCookieStore.setCookie(cookie("sso-ADA", "x", domain: "sso.idm.uni-hannover.de"))
        let stud = WaitingStudIP()
        let sync = m.studip
        let run = Task { await sync.run(client: StudIPClient(base: StudIPSync.base, transport: stud, pauseMillis: 0)) }
        try await waitUntil("Stud.IP-Download laeuft") { stud.gate.wasReached }

        // Wechsel zur Uni Hildesheim, dann zu einem anderen Konto (LUH) – der Download von Ada laeuft noch
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let hi = try active(m)
        XCTAssertFalse(m.studip === sync, "neuer Abgleich fuer den neuen Container")
        XCTAssertTrue(sync.isRunning, "der alte Lauf gehoert weiter seinem Container")
        XCTAssertFalse(m.studip.hasStoredSession)
        XCTAssertTrue(hi.cookies.load().isEmpty)
        let b = account(otherUser)
        b.chooseUniversity(.luh)
        m.sync(account: b)
        let bob = try active(m)
        XCTAssertFalse(m.studip === sync)
        XCTAssertEqual(m.studip.phase, .signedOut, "Bob hat keine Stud.IP-Sitzung")
        XCTAssertTrue(bob.cookies.load().isEmpty, "Sitzungs-Cookie von Ada nicht bei Bob")
        let bobWeb = await cookies(m, bob)
        XCTAssertEqual(bobWeb, [])
        let hiWeb = await cookies(m, hi)
        XCTAssertEqual(hiWeb, [])
        stud.gate.release()
        await run.value
        XCTAssertFalse(sync.isRunning)

        // Datei nur bei Ada/LUH
        let adaFiles = try await luh.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE course_id='c1'")?.int
        XCTAssertEqual(adaFiles, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: luh.layout.studip.appendingPathComponent("files").path))
        for (c, who) in [(hi, "Hildesheim"), (bob, "Bob")] {
            let n = try await c.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE course_id='c1'")?.int
            XCTAssertEqual(n, 0, who)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.layout.studip.appendingPathComponent("files").path), who)
        }
        XCTAssertEqual(luh.cookies.load().map(\.value), ["sitzung-ada"], "Sitzung von Ada unveraendert")
        let adaWeb = await cookies(m, luh)
        XCTAssertEqual(adaWeb, ["sso-ADA"])
        // zurueck zu Ada/LUH: ihr Abgleich kennt die Datei, Bob weiterhin nichts
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let again = try active(m)
        XCTAssertEqual(again.layout.root, luh.layout.root)
        XCTAssertTrue(m.studip.hasStoredSession)
        try await waitUntil("Dateiliste von Ada") { !m.studip.entries.isEmpty }
        XCTAssertEqual(m.studip.entries.count, 1)
    }

    /// "Daten dieser Hochschule löschen" und "Konto löschen" waehrend eines laufenden Abgleichs: der Abgleich wird
    /// angehalten und abgewartet, danach bleiben weder Ordner noch Dateien noch Eintraege in der Einstellungs-Suite
    /// (vorher legte der Learnweb-Abgleich den geloeschten Container ohne Kennzeichnung neu an)
    func testDeletingDuringARunningSyncLeavesNothingBehind() async throws {
        defer { UniStubProtocol.reset() }
        let a = account(user)
        a.chooseUniversity(.hildesheim)
        let m = hildesheimManager()
        m.sync(account: a)

        // 1. Daten der Uni Hildesheim loeschen, waehrend der erste Learnweb-Download laeuft
        let gate = StubGate()
        let (hi, h, run) = try await startLearnwebSync(m, gate)
        XCTAssertTrue(h.isRunning)
        let deletion = Task { await m.deleteUniversityData(hi.key) }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.release()
        await deletion.value
        _ = await run.value
        XCTAssertTrue(h.stopped)
        let fresh = try active(m)
        XCTAssertEqual(fresh.key, hi.key, "es geht mit einem leeren Container weiter")
        XCTAssertEqual(try fresh.layout.manifest()?.university, "hildesheim")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.layout.learnweb.path), "keine Learnweb-Reste")
        let files = try await fresh.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE course_id LIKE 'lw-%'")?.int
        XCTAssertEqual(files, 0)
        XCTAssertEqual(suiteKeys(fresh.layout), [], "Stand des alten Abgleichs nicht zurueckgeschrieben")
        XCTAssertFalse(m.hildesheim?.anyConnected ?? true)
        let after = await h.run()
        XCTAssertNil(after, "die alte Verbindung gleicht nicht mehr ab")

        // 2. Konto loeschen, waehrend im neuen Container wieder ein Download laeuft
        let gate2 = StubGate()
        let (hi2, _, run2) = try await startLearnwebSync(m, gate2)
        let deletion2 = Task { await m.deleteAllData(userID: user) }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate2.release()
        await deletion2.value
        _ = await run2.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: hi2.layout.root.path))
        for layout in DataContainerLayout.all(base: base, userID: user) {
            XCTAssertFalse(layout.exists(), "\(layout.university)")
            XCTAssertEqual(suiteKeys(layout), [], "\(layout.university)")
        }

        // 3. LUH: Stud.IP-Abgleich laeuft beim Loeschen (Download wartet)
        let b = account(otherUser)
        b.chooseUniversity(.luh)
        m.sync(account: b)
        let luh = try active(m)
        let stud = WaitingStudIP()
        let sync = m.studip
        let studRun = Task { await sync.run(client: StudIPClient(base: StudIPSync.base, transport: stud, pauseMillis: 0)) }
        try await waitUntil("Stud.IP-Download laeuft") { stud.gate.wasReached }
        let deletion3 = Task { await m.deleteUniversityData(luh.key) }
        try await Task.sleep(nanoseconds: 200_000_000)
        stud.gate.release()
        await deletion3.value
        await studRun.value
        XCTAssertTrue(sync.stopped)
        let freshLUH = try active(m)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshLUH.layout.studip.appendingPathComponent("files").path), "keine Stud.IP-Reste")
        let luhFiles = try await freshLUH.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE course_id='c1'")?.int
        XCTAssertEqual(luhFiles, 0)
        XCTAssertEqual(suiteKeys(freshLUH.layout), [], "Kursauswahl und Stand des alten Abgleichs weg")
    }
}
