import UniFlowCore
import UserNotifications
import WebKit
import XCTest
@testable import UniFlow

/// Erinnerungen an Abgaben und Pruefungen in der App (`DueReminderScheduler`): Erlaubnis erst beim Einschalten,
/// Planen aus GET /api/due des offenen Containers, Ersetzen und Zuruecknehmen, Trennung je Container (Wechsel der
/// Hochschule), Grenze 60, andere Mitteilungen der App bleiben. Mitteilungen gehen an einen Mitschreiber, nicht an iOS;
/// Container in einem Temp-Ordner, erfundene Nutzer, Kurse und Texte.
@MainActor
final class DueRemindersAppTests: XCTestCase {

    /// Mitschreiber statt UNUserNotificationCenter
    final class FakeNotifier: DueNotifying {
        var state: DueNotificationStatus = .notDetermined
        var grant = true
        var requests = 0
        var pending: [String: DueReminders.Reminder] = [:]
        var foreign: Set<String> = []
        var removed: [String] = []

        func status() async -> DueNotificationStatus { state }
        func requestPermission() async -> Bool {
            requests += 1
            state = grant ? .allowed : .denied
            return grant
        }
        func pendingIdentifiers() async -> [String] { Array(pending.keys) + Array(foreign) }
        func schedule(_ r: DueReminders.Reminder) async { pending[r.identifier] = r }
        func remove(_ identifiers: [String]) {
            removed += identifiers
            for i in identifiers { pending[i] = nil; foreign.remove(i) }
        }
    }

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
    private var suite = ""
    private var defaults: UserDefaults!
    private let user = "001234.erfunden-due.\(UUID().uuidString.prefix(8))"
    private let clock = UniFlowClock.fixed(berlin: "2026-10-27T10:00:00")!
    private var now: Date { clock.now }                                       // 27.10.2026 10:00 in Berlin
    private var stores: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-due-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        suite = "uniflow.tests.due.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        for layout in DataContainerLayout.all(base: base, userID: user) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            stores.append(layout.identifier)
        }
        for id in Set(stores) { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: appSupport)
        try await super.tearDown()
    }

    private var base: URL { appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }

    private func manager() -> ContainerManager {
        ContainerManager(base: base, legacy: LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                        studip: appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                         keychain: UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)"),
                         cookieService: "de.uniflow.ai.studip.test.\(UUID().uuidString)", defaults: defaults, clock: clock, publishesCurrent: false)
    }

    private func account(_ uni: UniversityKey) -> AccountStore {
        let a = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a.signIn(userID: user, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(uni)
        return a
    }

    private func scheduler(_ fake: FakeNotifier) -> DueReminderScheduler {
        let s = DueReminderScheduler(notifier: fake, defaults: defaults)
        let fixed = now
        s.now = { fixed }
        return s
    }

    private func db(_ c: ActiveContainer) async throws -> SQLiteDatabase { try await c.host.backend().context.database }

    private func unix(_ local: String) -> Int64 {
        Int64(UniFlowClock.fixed(berlin: local)!.now.timeIntervalSince1970)
    }

    /// LUH-Container: Modul mit Uebungsblatt (Abgabe mit Uhrzeit) und Folien (Kurzklausur ohne Uhrzeit)
    private func seedLUH(_ c: ActiveContainer) async throws {
        let d = try await db(c)
        try await d.execute("INSERT INTO modules(id, name, color) VALUES (1, 'Lineare Algebra', '#16a34a')")
        try await d.execute("INSERT INTO courses(id, title, active, module_id) VALUES ('k-la', 'Lineare Algebra', 1, 1)")
        for (id, name, text) in [("f-b3", "Blatt3.pdf", "Übungsblatt 3\nAbgabe: Do, 05.11.2026, 23:59 Uhr"),
                                 ("f-org", "Organisatorisches.pdf", "Kurzklausurtermin – Datum: Fr, 11.12.2026, Anmeldung über Stud.IP")] {
            try await d.execute("INSERT INTO files(id, course_id, name, chdate, local_path, kind) VALUES (?, 'k-la', ?, ?, ?, 'pdf')",
                                [.text(id), .text(name), .integer(unix("2026-10-20T12:00")), .text("StudIP/\(name)")])
            try await d.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?, 1, ?, ?, ?)",
                                [.text(id), .text(text), .integer(unix("2026-10-20T12:00")), .text(ScriptSearch.searchForm(text))])
        }
    }

    private func ids(_ fake: FakeNotifier) -> [String] { fake.pending.keys.sorted() }

    // MARK: Erlaubnis

    func testNeverAsksBeforeTheSwitchAndPlansAfterEnabling() async throws {
        let m = manager()
        m.sync(account: account(.luh))
        let c = try XCTUnwrap(m.active)
        stores.append(c.websiteDataStoreID)
        try await seedLUH(c)
        let fake = FakeNotifier()
        let s = scheduler(fake)
        s.attach(m)
        await s.settle()
        await s.refresh(recompute: true)
        XCTAssertEqual(fake.requests, 0, "nie beim Start fragen")
        XCTAssertEqual(fake.pending.count, 0, "aus: nichts geplant")
        XCTAssertFalse(s.enabled)

        let ok = await s.setEnabled(true)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.requests, 1, "erst der Schalter fragt")
        XCTAssertTrue(defaults.bool(forKey: DueReminderScheduler.enabledKey))
        let prefix = "de.uniflow.ai.due.\(c.layout.identifier.uuidString)."
        XCTAssertTrue(ids(fake).allSatisfy { $0.hasPrefix(prefix) })
        XCTAssertEqual(fake.pending.count, 7, "Abgabe mit Uhrzeit: 4, Kurzklausur ohne: 3")
        XCTAssertEqual(s.scheduled, 7)
        let h2 = try XCTUnwrap(fake.pending.values.first { $0.identifier.hasSuffix(".h2") })
        XCTAssertEqual(h2.title, "In 2 Stunden: Abgabe Blatt 3")
        XCTAssertEqual(h2.route, "#/doc/f-b3")
        XCTAssertTrue(h2.body.contains("erkannt in Blatt3.pdf, S. 1"))
        // zweites Einschalten fragt nicht noch einmal
        _ = await s.setEnabled(true)
        XCTAssertEqual(fake.requests, 1)
    }

    func testDeniedStaysOffAndSchedulesNothing() async throws {
        let m = manager()
        m.sync(account: account(.luh))
        let c = try XCTUnwrap(m.active)
        stores.append(c.websiteDataStoreID)
        try await seedLUH(c)
        let fake = FakeNotifier()
        fake.grant = false
        let s = scheduler(fake)
        s.attach(m)
        let ok = await s.setEnabled(true)
        XCTAssertFalse(ok)
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(defaults.bool(forKey: DueReminderScheduler.enabledKey))
        await s.refresh(recompute: false)
        XCTAssertEqual(fake.pending.count, 0)
        XCTAssertTrue(DueTexts.deniedText.contains("iPad-Einstellungen"))
    }

    // MARK: Ersetzen und Zuruecknehmen

    func testHideWithdrawsAndTimeChangeReplaces() async throws {
        let m = manager()
        m.sync(account: account(.luh))
        let c = try XCTUnwrap(m.active)
        stores.append(c.websiteDataStoreID)
        try await seedLUH(c)
        let fake = FakeNotifier()
        fake.state = .allowed
        let s = scheduler(fake)
        s.attach(m)
        _ = await s.setEnabled(true)
        let list = try await c.api.value("/api/due")
        let items = list.list("items")
        let abgabe = try XCTUnwrap(items.first { $0.s("kind") == "abgabe" }?.s("id"))
        let kk = try XCTUnwrap(items.first { $0.s("kind") == "klausur" }?.s("id"))
        // Kurzklausur ausgeblendet ("stimmt nicht"): ihre Erinnerungen weg
        _ = try await c.api.value("/api/due/\(kk)", method: "PATCH", body: ["hidden": true])
        await s.refresh(recompute: false)
        XCTAssertFalse(ids(fake).contains { $0.contains(".\(kk).") })
        XCTAssertEqual(fake.removed.filter { $0.contains(".\(kk).") }.count, 3)
        // Uhrzeit der Abgabe geaendert: gleiche Kennung, neuer Zeitpunkt
        let before = try XCTUnwrap(fake.pending.values.first { $0.identifier.hasSuffix("\(abgabe).h2") }?.fireAt)
        _ = try await c.api.value("/api/due/\(abgabe)", method: "PATCH", body: ["time": "12:00"])
        await s.refresh(recompute: true)
        let after = try XCTUnwrap(fake.pending.values.first { $0.identifier.hasSuffix("\(abgabe).h2") }?.fireAt)
        XCTAssertEqual(after.timeIntervalSince(before), -(11 * 3600 + 59 * 60), "23:59 -> 12:00")
        XCTAssertEqual(fake.pending.count, 4)
        // nach einem Abgleich bleibt die Kurzklausur ausgeblendet
        await s.refresh(recompute: true)
        XCTAssertFalse(ids(fake).contains { $0.contains(".\(kk).") })
    }

    func testSwitchingOffKeepsOtherNotificationsOfTheApp() async throws {
        let m = manager()
        m.sync(account: account(.luh))
        let c = try XCTUnwrap(m.active)
        stores.append(c.websiteDataStoreID)
        try await seedLUH(c)
        let fake = FakeNotifier()
        fake.state = .allowed
        fake.foreign = ["de.uniflow.ai.sync.files.\(c.layout.identifier.uuidString).1"]
        let s = scheduler(fake)
        s.attach(m)
        _ = await s.setEnabled(true)
        XCTAssertEqual(fake.pending.count, 7)
        _ = await s.setEnabled(false)
        XCTAssertEqual(fake.pending.count, 0)
        XCTAssertEqual(fake.foreign.count, 1, "Mitteilung des Hintergrundabgleichs bleibt")
        XCTAssertEqual(s.scheduled, 0)
    }

    // MARK: Trennung je Container

    func testUniversitySwitchWithdrawsTheOtherContainer() async throws {
        let m = manager()
        let a = account(.luh)
        m.sync(account: a)
        let luh = try XCTUnwrap(m.active)
        stores.append(luh.websiteDataStoreID)
        try await seedLUH(luh)
        let fake = FakeNotifier()
        fake.state = .allowed
        let s = scheduler(fake)
        s.attach(m)
        _ = await s.setEnabled(true)
        await s.settle()
        let luhPrefix = "de.uniflow.ai.due.\(luh.layout.identifier.uuidString)."
        XCTAssertEqual(fake.pending.count, 7)

        // Wechsel zur Uni Hildesheim: Learnweb-Frist dort
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let hi = try XCTUnwrap(m.active)
        stores.append(hi.websiteDataStoreID)
        XCTAssertNotEqual(hi.layout.identifier, luh.layout.identifier)
        let d = try await db(hi)
        try await d.execute("INSERT INTO courses(id, title, active) VALUES ('lw-35', 'Informatik', 1)")
        try await d.execute("""
            INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue)
            VALUES ('lw-ev-9', 'learnweb', 'lw-35', 'Aufgabe 1 hochladen', 'Aufgabe 1 hochladen', 'abgabe', 'assign', '2026-11-12T23:59',
                    'https://learnweb.example.test/a', 0)
            """)
        await s.settle()
        await s.refresh(recompute: true)
        let hiPrefix = "de.uniflow.ai.due.\(hi.layout.identifier.uuidString)."
        XCTAssertTrue(ids(fake).allSatisfy { $0.hasPrefix(hiPrefix) }, "nur Erinnerungen des offenen Containers")
        XCTAssertEqual(fake.pending.count, 4)
        XCTAssertEqual(fake.removed.filter { $0.hasPrefix(luhPrefix) }.count, 7)
        XCTAssertEqual(fake.pending.values.first { $0.identifier.hasSuffix(".h2") }?.route, "https://learnweb.example.test/a")

        // zurueck zur LUH: deren Erinnerungen wieder, Hildesheim zurueckgenommen
        a.chooseUniversity(.luh)
        m.sync(account: a)
        await s.settle()
        await s.refresh(recompute: false)
        XCTAssertTrue(ids(fake).allSatisfy { $0.hasPrefix(luhPrefix) })
        XCTAssertEqual(fake.pending.count, 7)
    }

    func testAtMostSixtyAndNothingWithoutContainer() async throws {
        let m = manager()
        let a = account(.luh)
        m.sync(account: a)
        let c = try XCTUnwrap(m.active)
        stores.append(c.websiteDataStoreID)
        let d = try await db(c)
        try await d.execute("INSERT INTO courses(id, title, active) VALUES ('k1', 'Mathe', 1)")
        for i in 0..<25 {
            let day = String(format: "2026-11-%02d", i + 2)
            try await d.execute("INSERT INTO deadlines(id, source, course_id, title, kind, due_at) VALUES (?, 'learnweb', 'k1', ?, 'abgabe', ?)",
                                [.text("lw-ev-\(i)"), .text("Abgabe \(i)"), .text(day + "T12:00")])
        }
        let fake = FakeNotifier()
        fake.state = .allowed
        let s = scheduler(fake)
        s.attach(m)
        _ = await s.setEnabled(true)
        XCTAssertEqual(fake.pending.count, DueReminders.limit)
        XCTAssertEqual(fake.pending.count, 60)
        // abgemeldet bzw. ohne Container: alles zurueck
        m.deactivate()
        await s.settle()
        await s.refresh(recompute: false)
        XCTAssertEqual(fake.pending.count, 0)
    }

    // MARK: Antippen und Anzeige

    func testTappedReminderOpensSource() {
        XCTAssertEqual(DueNotificationDelegate.route(identifier: "de.uniflow.ai.due.C.due-1.d1", userInfo: ["route": "#/doc/f1?page=2"]), "#/doc/f1?page=2")
        XCTAssertNil(DueNotificationDelegate.route(identifier: "de.uniflow.ai.sync.files.C.1", userInfo: ["route": "#/files"]))
        XCTAssertNil(DueNotificationDelegate.route(identifier: "de.uniflow.ai.due.C.due-1.d1", userInfo: [:]))
        XCTAssertEqual(DueOpen.route(["file_id": "f1", "page": 2]), "#/doc/f1?page=2")
        XCTAssertEqual(DueOpen.route(["file_id": "f1", "page": 1]), "#/doc/f1")
        XCTAssertEqual(DueOpen.route(["url": "https://studip.example.test/x"]), "https://studip.example.test/x")
        XCTAssertNil(DueOpen.route(["url": "javascript:alert(1)"]))
        XCTAssertEqual(DueOpen.route(["module_id": 3]), "#/modules/3")
        XCTAssertEqual(UFRoute(hash: "#/doc/f1?page=2"), .doc("f1", page: 2))
    }

    func testListTexts() {
        let x: JSONValue = ["date": "2026-12-11", "time": "10:00", "kind_label": "Kurzklausur", "title": "Kurzklausur",
                            "course_title": "Analysis I (Übung)"]
        XCTAssertEqual(DueTexts.sub(x), "\(UFFmt.short("2026-12-11")) 10:00 · Analysis I (Übung)")
        let y: JSONValue = ["date": "2026-11-02", "kind_label": "Kurztestat", "title": "Kurztestat 1", "module_name": "Analysis I"]
        XCTAssertEqual(DueTexts.sub(y), "\(UFFmt.short("2026-11-02")) · Kurztestat · Analysis I")
        XCTAssertEqual(DueTexts.tone(0), .bad)
        XCTAssertEqual(DueTexts.tone(5), .warn)
        XCTAssertEqual(DueTexts.tone(30), .neutral)
        XCTAssertTrue(DueTexts.reminderText.contains("3 Tage vorher"))
        XCTAssertTrue(DueTexts.reminderText.contains("2 Stunden vorher"))
    }
}
