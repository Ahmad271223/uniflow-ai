import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Mitteilungen wie bei Studo (Version 1.3/1.4, Entscheidung des Inhabers 11.11.2026, docs/BENACHRICHTIGUNGEN-1-3.md):
/// neue Noten (Vergleich mit dem gespeicherten Notenspiegel), Stud.IP-Nachrichten und Ankuendigungen je mit eigenem
/// Schalter, stille Neuanmeldung im Hintergrund nur mit gespeichertem Uni-Zugang (Schluesselbund dieses Geraets, nie
/// ein Server) und der Takt am Mac. Kein Netz, keine echte Mitteilung, erfundene Module, Kurse und Zugangsdaten.
@MainActor
final class BackgroundNewsAppTests: XCTestCase {

    // MARK: Attrappen

    private final class FakeScheduler: BackgroundTaskScheduling {
        func pending() async -> [BackgroundSyncKind: Date?] { [:] }
        func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {}
        func cancel(_ kind: BackgroundSyncKind) {}
    }

    private final class FakeNotifier: BackgroundNotifying {
        var allowed = true
        private(set) var permissionRequests = 0
        private(set) var posts: [(content: BackgroundNotice.Content, id: String, thread: String)] = []
        func requestPermission() async -> Bool { permissionRequests += 1; return allowed }
        func isAllowed() async -> Bool { allowed }
        func post(_ content: BackgroundNotice.Content, id: String, thread: String) async { posts.append((content, id, thread)) }
        func schedule(_ content: BackgroundNotice.Content, id: String, thread: String, at date: Date) async {}
        func cancel(id: String) {}
    }

    /// Abgleich, der beim Lauf Zeilen in die Datenbank schreibt (wie Stud.IP bzw. QIS es taeten)
    private final class WritingSync: BackgroundSyncable {
        var fileSource = "Stud.IP"
        var usableSources = ["Stud.IP"]
        var loginNeededSources: [String] = []
        var isRunning = false
        var write: (() async throws -> Void)?
        private(set) var runs = 0
        func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport {
            runs += 1
            try? await write?()
            return BackgroundSyncReport()
        }
    }

    // MARK: Umgebung

    private let clock = UniFlowClock.fixed(berlin: "2026-11-11T10:00:00")!
    /// 11.11.2026, 10:00 Berlin
    private let now = Date(timeIntervalSince1970: 1_794_387_600)
    private var bed: ContainerTestBed!
    private var services: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "mitteilungen", clock: clock)
    }

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        await bed.tearDown()
        try await super.tearDown()
    }

    private func ready(_ uni: UniversityKey = .luh) throws -> (ContainerManager, AccountStore, ActiveContainer) {
        let m = bed.manager()
        let a = bed.account(uni)
        a.markLoginDone()
        let c = try bed.open(m, a)
        services.append(m.credentialService)
        return (m, a, c)
    }

    private func controller(_ m: ContainerManager, _ a: AccountStore) -> (BackgroundSyncController, FakeNotifier) {
        let n = FakeNotifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults),
                                         scheduler: FakeScheduler(), notifier: n)
        b.allowed = { true }
        b.now = { self.now }
        b.timeZone = { TimeZone(identifier: "Europe/Berlin")! }
        b.weeklyTick = { _ in .off }
        return (b, n)
    }

    private func exec(_ c: ActiveContainer, _ sql: String, _ params: [SQLiteValue] = []) async throws {
        try await c.host.backend().context.database.transaction { conn in _ = try conn.execute(sql, params) }
    }

    private func grade(_ c: ActiveContainer, nr: String, text: String, note: String?, status: String) async throws {
        try await exec(c, """
            INSERT INTO grades(pruefungsnr, text, semester, note, status, versuch) VALUES (?,?,?,?,?,?)
            ON CONFLICT(pruefungsnr, text, semester, versuch) DO UPDATE SET note=excluded.note, status=excluded.status
            """, [.text(nr), .text(text), "WiSe 26/27", SQLiteValue(note), .text(status), "1"])
    }

    private func qisRunOK(_ c: ActiveContainer) async throws {
        try await exec(c, "INSERT INTO qis_runs(started_at, finished_at, ok, message, grades) VALUES ('2026-11-10T08:00:00','2026-11-10T08:00:05',1,'2 Leistungen',2)")
    }

    // MARK: Regeln (rein)

    private func g(_ key: String, _ module: String, note: String = "", status: String = "") -> GradeEntry {
        GradeEntry(key: key, module: module, note: note, status: status)
    }

    func testGradeDiffFindsOnlyNewResultsAndNeverOnTheFirstFill() {
        let before = BackgroundNewsSnapshot(grades: [g("1", "Analysis A", note: "2,3", status: "bestanden"),
                                                     g("2", "Numerik B", status: "angemeldet")], gradesKnown: true)
        let after = BackgroundNewsSnapshot(grades: [g("1", "Analysis A", note: "2,3", status: "bestanden"),
                                                    g("2", "Numerik B", note: "1,7", status: "bestanden"),
                                                    g("3", "Seminar C", status: "bestanden"),
                                                    g("4", "Statistik D", status: "angemeldet")], gradesKnown: true)
        let d = BackgroundNews.diff(before: before, after: after, now: now)
        XCTAssertEqual(d.newGrades.map(\.module), ["Numerik B", "Seminar C"], "angemeldet ist keine Note; unbenotet bestanden zaehlt")
        XCTAssertEqual(d.newGrades.first?.note, "1,7")

        // erster Notenspiegel (vorher nie ein gelungener Abruf): nichts melden
        let first = BackgroundNews.diff(before: BackgroundNewsSnapshot(), after: after, now: now)
        XCTAssertEqual(first.newGrades, [])
        // vorher leer, aber ein Abruf war schon gelungen (noch keine Leistung): die erste Note wird gemeldet
        let firstGrade = BackgroundNews.diff(before: BackgroundNewsSnapshot(gradesKnown: true),
                                             after: BackgroundNewsSnapshot(grades: [g("9", "Mathe E", note: "1,0")], gradesKnown: true), now: now)
        XCTAssertEqual(firstGrade.newGrades.map(\.module), ["Mathe E"])
        // "-" und Leerzeichen sind keine Note
        XCTAssertFalse(g("x", "M", note: " - ", status: "AN").hasResult)
        XCTAssertTrue(g("x", "M", status: "NB").hasResult)
    }

    /// 12.11.2026: der Notenspiegel liest die Pruefungsnummer jetzt auch aus "PrfNr."; eine schon bekannte Leistung,
    /// die dadurch erst jetzt eine Nummer hat, ist keine neue Note (eine wirklich neue schon)
    func testKnownGradeThatGainsItsNumberIsNotNew() {
        let before = BackgroundNewsSnapshot(grades: [GradeEntry(key: "\u{1}Analysis A\u{1}WiSe 26/27\u{1}1", module: "Analysis A", note: "2,3",
                                                                status: "bestanden", looseKey: "Analysis A\u{1}WiSe 26/27\u{1}1")],
                                            gradesKnown: true)
        let after = BackgroundNewsSnapshot(grades: [GradeEntry(key: "1101\u{1}Analysis A\u{1}WiSe 26/27\u{1}1", module: "Analysis A", note: "2,3",
                                                               status: "bestanden", looseKey: "Analysis A\u{1}WiSe 26/27\u{1}1"),
                                                    GradeEntry(key: "1201\u{1}Numerik B\u{1}WiSe 26/27\u{1}1", module: "Numerik B", note: "1,7",
                                                               status: "bestanden", looseKey: "Numerik B\u{1}WiSe 26/27\u{1}1")],
                                           gradesKnown: true)
        XCTAssertEqual(BackgroundNews.diff(before: before, after: after, now: now).newGrades.map(\.module), ["Numerik B"])
    }

    func testMessageAndAnnouncementDiffIgnoresOldEntries() {
        let recent = now.addingTimeInterval(-3600), old = now.addingTimeInterval(-40 * 86400)
        let before = BackgroundNewsSnapshot(messages: ["m1": recent],
                                            announcements: [NewsAnnouncement(id: "sp-news-1", title: "Alt", course: "Kurs A", postedAt: recent)])
        let after = BackgroundNewsSnapshot(messages: ["m1": recent, "m2": recent, "m3": old, "m4": nil],
                                           announcements: [NewsAnnouncement(id: "sp-news-1", title: "Alt", course: "Kurs A", postedAt: recent),
                                                           NewsAnnouncement(id: "sp-news-2", title: "Raumänderung", course: "Testkurs Numerik", postedAt: recent),
                                                           NewsAnnouncement(id: "sp-news-3", title: "Uralt", course: "Kurs B", postedAt: old)])
        let d = BackgroundNews.diff(before: before, after: after, now: now)
        XCTAssertEqual(d.newMessages, 2, "neu und juenger als 14 Tage (ohne Datum zaehlt)")
        XCTAssertEqual(d.newAnnouncements.map(\.id), ["sp-news-2"])
        XCTAssertTrue(BackgroundNews.diff(before: after, after: after, now: now).isEmpty)
    }

    func testNoticeTextsNameTheModuleAndTheValueOnlyWithItsSwitch() {
        XCTAssertEqual(BackgroundNotice.newGrade(module: "Numerik B", value: nil),
                       BackgroundNotice.Content(title: "Neue Note", body: "Neue Note in Numerik B eingetragen"))
        XCTAssertEqual(BackgroundNotice.newGrade(module: "Numerik B", value: "1,7").body, "Neue Note in Numerik B eingetragen: 1,7")
        XCTAssertEqual(BackgroundNotice.newGrades(5)?.body, "5 neue Noten eingetragen. Öffne StudiNow, um sie zu sehen.")
        XCTAssertNil(BackgroundNotice.newGrades(0))
        XCTAssertEqual(BackgroundNotice.newStudIPMessages(1)?.body, "1 neue Nachricht in Stud.IP")
        XCTAssertEqual(BackgroundNotice.newStudIPMessages(3)?.body, "3 neue Nachrichten in Stud.IP")
        XCTAssertNil(BackgroundNotice.newStudIPMessages(0))
        XCTAssertEqual(BackgroundNotice.newAnnouncement(NewsAnnouncement(id: "a", title: "Raumänderung", course: "Testkurs", postedAt: nil)),
                       BackgroundNotice.Content(title: "Neue Ankündigung in Testkurs", body: "Raumänderung"))
        XCTAssertEqual(BackgroundNotice.newAnnouncement(NewsAnnouncement(id: "a", title: "Wartung", course: nil, postedAt: nil)).title,
                       "Neue Ankündigung in Stud.IP")
        XCTAssertEqual(BackgroundNotice.newAnnouncements(4)?.body, "4 neue Ankündigungen")
        // abgelaufene Anmeldung: mit Versuch im Hintergrund ehrlich, ohne wie bisher
        XCTAssertTrue(BackgroundNotice.loginNeeded(["Stud.IP"], reloginTried: true)?.body.contains("gespeicherten Uni-Zugang") ?? false)
        XCTAssertEqual(BackgroundNotice.loginNeeded(["Stud.IP"], reloginTried: false), BackgroundNotice.loginNeeded(["Stud.IP"]))
    }

    func testSettingsDefaults() {
        let s = BackgroundNewsSettings(defaults: bed.defaults)
        XCTAssertFalse(s.grades, "Mitteilungen erst nach dem Einschalten (fragt dann iOS)")
        XCTAssertFalse(s.gradeValue, "Notenwert nur mit eigenem Schalter")
        XCTAssertFalse(s.messages)
        XCTAssertFalse(s.announcements)
        XCTAssertTrue(s.relogin, "Neuanmeldung im Hintergrund an, wirkt aber nur mit gespeichertem Uni-Zugang")
        XCTAssertFalse(s.anyOn)
        s.messages = true
        XCTAssertTrue(s.anyOn)
    }

    func testReloginLedgerAllowsOneTryPerSixHoursAndWaitsADayAfterAFailure() {
        let d = UserDefaults(suiteName: "uniflow.tests.relogin.\(UUID().uuidString)")!
        let l = BackgroundReloginLedger(defaults: d)
        XCTAssertTrue(l.mayTry("Stud.IP", now: now))
        l.record("Stud.IP", ok: true, now: now)
        XCTAssertFalse(l.mayTry("Stud.IP", now: now.addingTimeInterval(5 * 3600)))
        XCTAssertTrue(l.mayTry("QIS", now: now), "je Dienst getrennt")
        XCTAssertTrue(l.mayTry("Stud.IP", now: now.addingTimeInterval(6 * 3600)))
        l.record("Stud.IP", ok: false, now: now)
        XCTAssertFalse(l.mayTry("Stud.IP", now: now.addingTimeInterval(23 * 3600)), "nach einem Fehlschlag einen Tag Ruhe")
        XCTAssertTrue(l.mayTry("Stud.IP", now: now.addingTimeInterval(24 * 3600)))
    }

    // MARK: Lauf

    func testBackgroundRunPostsNewGradeMessageAndAnnouncementPerSwitch() async throws {
        let (m, a, c) = try ready()
        let (b, n) = controller(m, a)
        try await qisRunOK(c)
        try await grade(c, nr: "100", text: "Analysis A", note: "2,3", status: "bestanden")
        try await grade(c, nr: "200", text: "Numerik B", note: nil, status: "angemeldet")
        let sync = WritingSync()
        b.target = { _ in sync }
        // Stud.IP liest Nachrichten und Ankuendigungen, QIS den Notenspiegel
        sync.write = {
            try await self.exec(c, StudIPExtrasMessagesTableForTests.sql)
            try await self.exec(c, "INSERT INTO studip_messages(id, subject, sent_at) VALUES ('m1','Geheimer Betreff','2026-11-11T09:00:00+01:00')")
            try await self.exec(c, "INSERT INTO courses(id, title) VALUES ('c1','Testkurs Numerik') ON CONFLICT(id) DO NOTHING")
            try await self.exec(c, "INSERT INTO announcements(id, source, course_id, title, posted_at) VALUES ('sp-news-9','studip','c1','Raumänderung','2026-11-11T08:00:00+01:00')")
        }
        var gradeSteps = 0
        b.gradesStep = { cc in
            gradeSteps += 1
            try? await self.grade(cc, nr: "200", text: "Numerik B", note: "1,7", status: "bestanden")
        }
        // alle Schalter aus: kein Lauf schreibt Mitteilungen, der Notenabruf laeuft trotzdem
        await b.perform(.refresh)
        XCTAssertEqual(gradeSteps, 1)
        XCTAssertTrue(n.posts.isEmpty, "ohne Schalter keine Mitteilung")

        // Schalter an (je Art): Note ohne Wert, Nachricht ohne Betreff, Ankuendigung mit Kurs
        try await grade(c, nr: "200", text: "Numerik B", note: nil, status: "angemeldet")
        try await exec(c, "DELETE FROM studip_messages")
        try await exec(c, "DELETE FROM announcements")
        let s = BackgroundNewsSettings(defaults: bed.defaults)
        s.grades = true
        s.messages = true
        s.announcements = true
        await b.perform(.refresh)
        let bodies = n.posts.map(\.content.body)
        XCTAssertEqual(Set(bodies), ["Neue Note in Numerik B eingetragen", "1 neue Nachricht in Stud.IP", "Raumänderung"])
        XCTAssertFalse(bodies.joined().contains("1,7"), "ohne Schalter kein Notenwert")
        XCTAssertFalse(bodies.joined().contains("Geheimer Betreff"), "nie der Betreff einer Nachricht")
        XCTAssertTrue(n.posts.allSatisfy { $0.thread == "de.uniflow.ai.sync." + c.layout.identifier.uuidString })
        XCTAssertTrue(n.posts.allSatisfy { $0.id.hasPrefix("de.uniflow.ai.sync.") })
        XCTAssertEqual(n.permissionRequests, 0, "nie von selbst nach der Erlaubnis fragen")

        // mit Notenwert; ein zweiter Lauf ohne Neues meldet nichts
        try await grade(c, nr: "200", text: "Numerik B", note: nil, status: "angemeldet")
        s.gradeValue = true
        let count = n.posts.count
        await b.perform(.refresh)
        XCTAssertEqual(n.posts.dropFirst(count).map(\.content.body), ["Neue Note in Numerik B eingetragen: 1,7"])
        let count2 = n.posts.count
        sync.write = nil
        b.gradesStep = { _ in }
        await b.perform(.refresh)
        XCTAssertEqual(n.posts.count, count2, "nichts Neues, keine Mitteilung")

        // iOS erlaubt keine Mitteilungen: nichts
        try await grade(c, nr: "200", text: "Numerik B", note: nil, status: "angemeldet")
        b.gradesStep = { cc in try? await self.grade(cc, nr: "200", text: "Numerik B", note: "1,7", status: "bestanden") }
        n.allowed = false
        await b.perform(.refresh)
        XCTAssertEqual(n.posts.count, count2)
    }

    func testGradesAreCheckedEvenWhenStudIPHasNoSessionButNeverWithBackgroundSyncOff() async throws {
        let (m, a, c) = try ready()
        let (b, _) = controller(m, a)
        let sync = WritingSync()
        sync.usableSources = []
        b.target = { _ in sync }
        var steps = 0
        b.gradesStep = { _ in steps += 1 }
        await b.perform(.refresh)
        XCTAssertEqual(steps, 1, "QIS hat eine eigene Sitzung")
        XCTAssertEqual(sync.runs, 0)
        BackgroundSyncSettings(defaults: bed.defaults).enabled = false
        await b.perform(.refresh)
        XCTAssertEqual(steps, 1, "Abgleich im Hintergrund aus: kein Notenabruf")
        _ = c
    }

    func testReloginInBackgroundOnlyWithStoredLoginAndSwitchThenSyncRuns() async throws {
        let (m, a, c) = try ready()
        let (b, n) = controller(m, a)
        BackgroundSyncSettings(defaults: bed.defaults).notify = true
        let sync = WritingSync()
        sync.usableSources = []
        sync.loginNeededSources = ["Stud.IP"]
        b.target = { _ in sync }
        b.gradesStep = { _ in }
        var tried: [String] = []
        var succeeds = true
        b.expiredPortals = { _ in sync.loginNeededSources }
        b.relogin = { _, portal in
            tried.append(portal)
            guard succeeds else { return false }
            sync.loginNeededSources = []
            sync.usableSources = ["Stud.IP"]
            return true
        }
        // ohne gespeicherten Uni-Zugang: kein Versuch, Bitte um Anmeldung wie bisher (Takt wie am Mac: auch im kurzen Lauf)
        b.reloginInShortRun = true
        b.hasStoredLogin = { _ in false }
        await b.perform(.refresh)
        XCTAssertEqual(tried, [])
        XCTAssertEqual(sync.runs, 0)

        // Schalter "Im Hintergrund neu anmelden" aus: kein Versuch
        b.hasStoredLogin = { _ in true }
        BackgroundNewsSettings(defaults: bed.defaults).relogin = false
        await b.perform(.refresh)
        XCTAssertEqual(tried, [])

        // an: im kurzen Lauf von iOS (rund 30 Sekunden) nie, im langen ein Versuch, danach der Abgleich mit der neuen Sitzung
        BackgroundNewsSettings(defaults: bed.defaults).relogin = true
        b.reloginInShortRun = false
        await b.perform(.refresh)
        XCTAssertEqual(tried, [], "kurzer Lauf: keine Neuanmeldung")
        await b.perform(.processing)
        XCTAssertEqual(tried, ["Stud.IP"])
        XCTAssertEqual(sync.runs, 1, "nach der Neuanmeldung im selben Lauf abgeglichen")

        // wieder abgelaufen, eine Stunde spaeter: kein zweiter Versuch (hoechstens alle 6 Stunden)
        b.reloginInShortRun = true
        sync.usableSources = []
        sync.loginNeededSources = ["Stud.IP"]
        b.now = { self.now.addingTimeInterval(3600) }
        await b.perform(.refresh)
        XCTAssertEqual(tried, ["Stud.IP"])

        // 7 Stunden spaeter scheitert er: kein Abgleich, danach einen Tag Ruhe
        succeeds = false
        b.now = { self.now.addingTimeInterval(7 * 3600) }
        await b.perform(.refresh)
        XCTAssertEqual(tried, ["Stud.IP", "Stud.IP"])
        XCTAssertEqual(sync.runs, 1)
        b.now = { self.now.addingTimeInterval(20 * 3600) }
        await b.perform(.refresh)
        XCTAssertEqual(tried, ["Stud.IP", "Stud.IP"], "nach dem Fehlschlag erst nach 24 Stunden wieder")
        XCTAssertTrue(n.posts.isEmpty, "keine Mitteilung ohne Lauf")
        _ = c
    }

    func testHandleExpiryInBackgroundUsesTheStoredLoginOnlyWhenAsked() async throws {
        let (m, _, c) = try ready()
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        let vault = UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
        var requests: [UniAutoLoginRequest] = []
        UniAutoLogin.runnerOverride = { r in requests.append(r); return .success }
        UniAutoLogin.appActiveOverride = false
        qis.signedIn()
        qis.certificatesExpired()
        // ohne gespeichertes Passwort: nichts
        let none = await qis.reloginInBackground()
        XCTAssertFalse(none)
        XCTAssertEqual(requests.count, 0)
        try vault.save(UniCredential(username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123", savedAt: Date()))
        // der alte Weg bleibt: im Hintergrund nie (ohne ausdrueckliche Hintergrund-Anmeldung)
        _ = await qis.autoLogin()
        XCTAssertEqual(requests.count, 0)
        // Hintergrund-Anmeldung: unsichtbar ohne Fenster, Stand danach verbunden, kein zweiter Abruf von selbst
        let ok = await qis.reloginInBackground()
        XCTAssertTrue(ok)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.background, true)
        XCTAssertEqual(requests.first?.entry, QISClient.startURL)
        XCTAssertEqual(qis.state, .connected)
        // abgemeldet: nie
        await qis.signOut()
        let after = await qis.reloginInBackground()
        XCTAssertFalse(after)
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: Mac

    func testMacTickerRunsEveryTwentyToThirtyMinutesUntilStopped() async throws {
        XCTAssertEqual(MacBackgroundTicker.delay(random: 0), 20 * 60)
        XCTAssertEqual(MacBackgroundTicker.delay(random: 1), 30 * 60)
        XCTAssertEqual(MacBackgroundTicker.delay(random: 7), 30 * 60, "begrenzt")
        XCTAssertTrue(MacBackgroundTicker.due(lastRun: nil, now: now))
        XCTAssertFalse(MacBackgroundTicker.due(lastRun: now.addingTimeInterval(-10 * 60), now: now), "eben erst gelaufen (z. B. von iOS)")
        XCTAssertTrue(MacBackgroundTicker.due(lastRun: now.addingTimeInterval(-19 * 60), now: now))

        var runs = 0
        var waits: [TimeInterval] = []
        let t = MacBackgroundTicker { runs += 1 }
        t.random = { 0.5 }
        t.sleep = { seconds in
            waits.append(seconds)
            await Task.yield()
            return true
        }
        t.start()
        XCTAssertTrue(t.isActive)
        try await bed.waitUntil("drei Laeufe") { runs >= 3 }
        t.stop()
        XCTAssertFalse(t.isActive)
        let stopped = runs
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThanOrEqual(runs, stopped + 1, "nach dem Anhalten kein weiterer Takt")
        XCTAssertTrue(waits.allSatisfy { $0 == 25 * 60 })
    }

    func testMacTickerRunsTheSameBackgroundRunOnlyWhenDue() async throws {
        let (m, a, _) = try ready()
        let (b, _) = controller(m, a)
        let sync = WritingSync()
        b.target = { _ in sync }
        b.gradesStep = { _ in }
        await b.performIfDue()
        XCTAssertEqual(sync.runs, 1, "erster Takt: Lauf")
        await b.performIfDue()
        XCTAssertEqual(sync.runs, 1, "eben gelaufen: kein zweiter")
        b.now = { self.now.addingTimeInterval(21 * 60) }
        await b.performIfDue()
        XCTAssertEqual(sync.runs, 2)
    }
}

/// Tabelle der Stud.IP-Nachrichten wie `StudIPExtras.messagesTable` (dort intern)
enum StudIPExtrasMessagesTableForTests {
    static let sql = """
        CREATE TABLE IF NOT EXISTS studip_messages (
            id TEXT PRIMARY KEY, sender TEXT, subject TEXT, preview TEXT, sent_at TEXT, url TEXT, dates TEXT, fetched_at TEXT)
        """
}
