import Foundation
import XCTest
@testable import UniFlowCore

/// Hintergrundabgleich (S8): naechster Termin 8/15/20 Uhr, wann ein Lauf ausfaellt, Texte der Benachrichtigungen,
/// Stand je Container, genau ein Abschluss je Aufgabe. Nur erfundene Daten, keine Uhr des Rechners.
final class BackgroundSyncTests: XCTestCase {

    // MARK: Naechster Termin

    private func zone(_ id: String) throws -> TimeZone {
        guard let tz = TimeZone(identifier: id) else { throw XCTSkip("keine Zeitzonendaten fuer \(id)") }
        return tz
    }

    /// Ortszeit "YYYY-MM-DD HH:MM[:SS]" in `tz` als Zeitpunkt
    private func at(_ text: String, _ tz: TimeZone) throws -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(f.date(from: text), text)
    }

    /// Zeitpunkt als Ortszeit "YYYY-MM-DD HH:MM:SS" in `tz`
    private func local(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return f.string(from: d)
    }

    private func next(_ text: String, _ tz: TimeZone) throws -> String {
        local(BackgroundSchedule.next(after: try at(text, tz), timeZone: tz), tz)
    }

    func testNextSlotOnAnOrdinaryDay() throws {
        let berlin = try zone("Europe/Berlin")
        XCTAssertEqual(BackgroundSchedule.hours, [8, 15, 20])
        let cases: [(String, String)] = [
            ("2026-11-04 00:00", "2026-11-04 08:00:00"),
            ("2026-11-04 07:59:59", "2026-11-04 08:00:00"),
            ("2026-11-04 08:00:00", "2026-11-04 15:00:00"),                 // genau zum Termin: der naechste
            ("2026-11-04 08:00:01", "2026-11-04 15:00:00"),
            ("2026-11-04 14:59", "2026-11-04 15:00:00"),
            ("2026-11-04 15:00", "2026-11-04 20:00:00"),
            ("2026-11-04 19:59:59", "2026-11-04 20:00:00"),
            ("2026-11-04 20:00", "2026-11-05 08:00:00"),                    // nach 20 Uhr der naechste Morgen
            ("2026-11-04 23:59:59", "2026-11-05 08:00:00"),
        ]
        for (now, want) in cases { XCTAssertEqual(try next(now, berlin), want, now) }
    }

    func testNextSlotAcrossMonthYearAndLeapDay() throws {
        let berlin = try zone("Europe/Berlin")
        XCTAssertEqual(try next("2026-10-31 21:15", berlin), "2026-11-01 08:00:00")
        XCTAssertEqual(try next("2026-12-31 20:30", berlin), "2027-01-01 08:00:00")
        XCTAssertEqual(try next("2028-02-28 22:00", berlin), "2028-02-29 08:00:00")
        XCTAssertEqual(try next("2028-02-29 20:01", berlin), "2028-03-01 08:00:00")
        XCTAssertEqual(try next("2027-02-28 20:01", berlin), "2027-03-01 08:00:00")
    }

    /// Sommerzeit (29.03.2026, 2 -> 3 Uhr) und Winterzeit (25.10.2026, 3 -> 2 Uhr): weiter 8:00 Ortszeit, auch wenn
    /// bis dahin eine Stunde weniger oder mehr liegt
    func testNextSlotAcrossDaylightSavingChanges() throws {
        let berlin = try zone("Europe/Berlin")
        // Samstagabend vor der Sommerzeit: 8 Uhr MESZ = 06:00 UTC, 10,5 statt 11,5 Stunden
        let sat = try at("2026-03-28 20:30", berlin)
        let sun = BackgroundSchedule.next(after: sat, timeZone: berlin)
        XCTAssertEqual(local(sun, berlin), "2026-03-29 08:00:00")
        XCTAssertEqual(utc(sun), "2026-03-29T06:00Z")
        XCTAssertEqual(sun.timeIntervalSince(sat), 10.5 * 3600)
        // in der Nacht der Umstellung (1:30 MEZ) und danach (3:30 MESZ)
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2026-03-29 01:30", berlin), timeZone: berlin)), "2026-03-29T06:00Z")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2026-03-29 03:30", berlin), timeZone: berlin)), "2026-03-29T06:00Z")
        XCTAssertEqual(try next("2026-03-29 08:00", berlin), "2026-03-29 15:00:00")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2026-03-29 08:00", berlin), timeZone: berlin)), "2026-03-29T13:00Z")

        // Samstagabend vor der Winterzeit: 8 Uhr MEZ = 07:00 UTC, 12,5 statt 11,5 Stunden
        let sat2 = try at("2026-10-24 20:30", berlin)
        let sun2 = BackgroundSchedule.next(after: sat2, timeZone: berlin)
        XCTAssertEqual(local(sun2, berlin), "2026-10-25 08:00:00")
        XCTAssertEqual(utc(sun2), "2026-10-25T07:00Z")
        XCTAssertEqual(sun2.timeIntervalSince(sat2), 12.5 * 3600)
        // in der doppelten Stunde (2:30 zuerst MESZ = 00:30 UTC, dann MEZ = 01:30 UTC): beide Male 8 Uhr MEZ
        let first = Date(timeIntervalSince1970: try at("2026-10-25 00:30", TimeZone(secondsFromGMT: 0)!).timeIntervalSince1970)
        let second = first.addingTimeInterval(3600)
        XCTAssertEqual(local(first, berlin), "2026-10-25 02:30:00")
        XCTAssertEqual(local(second, berlin), "2026-10-25 02:30:00")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: first, timeZone: berlin)), "2026-10-25T07:00Z")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: second, timeZone: berlin)), "2026-10-25T07:00Z")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2026-10-25 15:00", berlin), timeZone: berlin)), "2026-10-25T19:00Z")
    }

    /// Ortszeit des Geraets, nicht Berlin: auf Reisen gilt 8 Uhr dort; Zonen ohne Sommerzeit und eine Zone, deren
    /// Mitternacht bei der Umstellung fehlt (Sao Paulo 2018)
    func testNextSlotUsesTheGivenLocalTimeZone() throws {
        let ny = try zone("America/New_York")
        XCTAssertEqual(try next("2026-10-31 20:00", ny), "2026-11-01 08:00:00")       // US-Winterzeit am 1.11.
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2026-10-31 20:00", ny), timeZone: ny)), "2026-11-01T13:00Z")
        let tokyo = try zone("Asia/Tokyo")
        XCTAssertEqual(try next("2026-11-04 14:00", tokyo), "2026-11-04 15:00:00")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2026-11-04 14:00", tokyo), timeZone: tokyo)), "2026-11-04T06:00Z")
        let sp = try zone("America/Sao_Paulo")
        XCTAssertEqual(try next("2018-11-03 20:30", sp), "2018-11-04 08:00:00")
        XCTAssertEqual(utc(BackgroundSchedule.next(after: try at("2018-11-03 20:30", sp), timeZone: sp)), "2018-11-04T10:00Z")
        // derselbe Zeitpunkt, zwei Zonen: verschiedene Termine
        let now = try at("2026-11-04 12:00", try zone("Europe/Berlin"))
        XCTAssertNotEqual(BackgroundSchedule.next(after: now, timeZone: ny), BackgroundSchedule.next(after: now, timeZone: tokyo))
    }

    /// Ueber drei Wochen mit beiden Umstellungen in Schritten von 7 Minuten: immer ein Termin danach, immer volle 8,
    /// 15 oder 20 Uhr, nie mehr als 13 Stunden (plus eine Stunde Umstellung) und nie ein Termin dazwischen ausgelassen
    func testNextSlotNeverSkipsOne() throws {
        let berlin = try zone("Europe/Berlin")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        for start in ["2026-03-20 00:00", "2026-10-17 00:00"] {
            let from = try at(start, berlin)
            var t = from
            var previous: Date?
            while t < from.addingTimeInterval(21 * 86400) {
                let n = BackgroundSchedule.next(after: t, timeZone: berlin)
                XCTAssertGreaterThan(n, t)
                let c = cal.dateComponents([.hour, .minute, .second], from: n)
                XCTAssertTrue([8, 15, 20].contains(c.hour ?? -1) && c.minute == 0 && c.second == 0, local(n, berlin))
                XCTAssertLessThanOrEqual(n.timeIntervalSince(t), 13 * 3600 + 3600)
                if let p = previous, p > t { XCTAssertEqual(n, p, "kein Termin zwischen \(local(t, berlin)) und \(local(p, berlin))") }
                previous = n
                t = t.addingTimeInterval(7 * 60)
            }
        }
    }

    func testCustomHoursAreSortedAndDeduplicated() throws {
        let berlin = try zone("Europe/Berlin")
        let now = try at("2026-11-04 09:00", berlin)
        XCTAssertEqual(local(BackgroundSchedule.next(after: now, timeZone: berlin, hours: [20, 8, 8, 15]), berlin), "2026-11-04 15:00:00")
        XCTAssertEqual(local(BackgroundSchedule.next(after: now, timeZone: berlin, hours: [6]), berlin), "2026-11-05 06:00:00")
        // unsinnige Stunden werden ignoriert, ohne gueltige ein Tag spaeter
        XCTAssertEqual(BackgroundSchedule.next(after: now, timeZone: berlin, hours: [25, -1]), now.addingTimeInterval(86400))
    }

    /// Ein bestellter Termin wird nicht nach hinten geschoben (sonst kaeme der lange Lauf nie dran)
    func testPendingRequestIsKeptUnlessLater() throws {
        let berlin = try zone("Europe/Berlin")
        let next = try at("2026-11-04 15:00", berlin)
        XCTAssertTrue(BackgroundSchedule.keepsPending(try at("2026-11-04 08:00", berlin), next: next), "ueberfaellig: bleibt")
        XCTAssertTrue(BackgroundSchedule.keepsPending(next, next: next))
        XCTAssertTrue(BackgroundSchedule.keepsPending(nil, next: next), "ohne Uhrzeit: bleibt")
        XCTAssertFalse(BackgroundSchedule.keepsPending(try at("2026-11-04 20:00", berlin), next: next), "spaeter: ersetzen")
    }

    // MARK: Wann ein Lauf ausfaellt

    func testGateOrderAndReasons() {
        let ok = BackgroundSyncSituation(enabled: true, hasContainer: true, switching: false, syncRunning: false, usableSession: true)
        XCTAssertNil(BackgroundSyncGate.skipReason(ok))
        var s = ok
        s.usableSession = false
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .noSession)
        s.syncRunning = true
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .alreadyRunning, "nie zwei Abgleiche auf einem Container")
        s.switching = true
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .switching, "kein Lauf waehrend eines Wechsels")
        s.hasContainer = false
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .noContainer)
        s.enabled = false
        XCTAssertEqual(BackgroundSyncGate.skipReason(s), .disabled)
        XCTAssertEqual(BackgroundSkipReason.noSession.text, "keine gültige Anmeldung")
        XCTAssertEqual(BackgroundSkipReason.deviceLocked.text, "iPad gesperrt")
        XCTAssertEqual(BackgroundSyncKind.refresh.scope, .lists)
        XCTAssertEqual(BackgroundSyncKind.processing.scope, .full)
    }

    // MARK: Texte

    func testNotificationTextsHaveCountAndSourceButNoFileNames() {
        XCTAssertNil(BackgroundNotice.newFiles(0, source: "Stud.IP"))
        XCTAssertEqual(BackgroundNotice.newFiles(1, source: "Stud.IP"), .init(title: "Neue Dateien", body: "1 neue Datei aus Stud.IP"))
        XCTAssertEqual(BackgroundNotice.newFiles(3, source: "Stud.IP")?.body, "3 neue Dateien aus Stud.IP")
        XCTAssertEqual(BackgroundNotice.newFiles(12, source: "Learnweb")?.body, "12 neue Dateien aus Learnweb")
        XCTAssertEqual(BackgroundNotice.newFilesText(2, source: nil), "2 neue Dateien")
        XCTAssertFalse(BackgroundNotice.hiddenPreviewPlaceholder.isEmpty)

        XCTAssertNil(BackgroundNotice.loginNeeded([]))
        let studip = BackgroundNotice.loginNeeded(["Stud.IP"])
        XCTAssertEqual(studip?.title, "Bitte bei Stud.IP anmelden")
        XCTAssertTrue(studip?.body.contains("nie selbst an") ?? false)
        XCTAssertEqual(BackgroundNotice.loginNeeded(["LSF"])?.title, "Bitte beim LSF anmelden")
        XCTAssertEqual(BackgroundNotice.loginNeeded(["Learnweb", "LSF"])?.title, "Bitte bei Learnweb und beim LSF anmelden")
        XCTAssertEqual(BackgroundNotice.loginNeeded(["A", "B", "C"])?.title, "Bitte bei A, bei B und bei C anmelden")
    }

    // MARK: Stand je Container

    private func suite() throws -> UserDefaults {
        let name = "uniflow.tests.hintergrund.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testRecordsAreKeptPerContainer() throws {
        let luh = BackgroundSyncState(defaults: try suite())
        let hi = BackgroundSyncState(defaults: try suite())
        XCTAssertNil(luh.last)
        let when = Date(timeIntervalSince1970: 1_793_000_000)
        luh.record(BackgroundSyncRecord(finishedAt: when, kind: .refresh, outcome: .done(newFiles: 3)))
        XCTAssertEqual(luh.last, BackgroundSyncRecord(finishedAt: when, kind: .refresh, outcome: .done(newFiles: 3)))
        XCTAssertNil(hi.last, "die andere Hochschule sieht nichts")
        hi.record(BackgroundSyncRecord(finishedAt: when, kind: .processing, outcome: .loginNeeded(["Learnweb"])))
        XCTAssertEqual(luh.last?.outcome, .done(newFiles: 3))
        XCTAssertEqual(hi.last?.outcome, .loginNeeded(["Learnweb"]))

        luh.markLoginNoticeSent("Stud.IP")
        XCTAssertTrue(luh.loginNoticeSent("Stud.IP"))
        XCTAssertFalse(hi.loginNoticeSent("Stud.IP"))
    }

    func testLoginNoticeOnlyOncePerExpiry() throws {
        let d = try suite()
        let s = BackgroundSyncState(defaults: d)
        let expired = BackgroundSyncReport(loginNeeded: ["Stud.IP", "Stud.IP"])
        XCTAssertEqual(s.loginNoticeDue(expired), ["Stud.IP"])
        s.markLoginNoticeSent("Stud.IP")
        XCTAssertEqual(s.loginNoticeDue(expired), [], "nicht bei jedem Lauf")
        XCTAssertEqual(s.loginNoticeDue(BackgroundSyncReport(loginNeeded: ["Learnweb", "Stud.IP"])), ["Learnweb"])
        s.sessionUsable("Stud.IP")                                       // neu angemeldet
        XCTAssertEqual(s.loginNoticeDue(expired), ["Stud.IP"], "naechster Ablauf darf wieder einmal melden")
        // ein frischer Container bleibt leer
        let fresh = try suite()
        BackgroundSyncState(defaults: fresh).sessionUsable("Stud.IP")
        XCTAssertNil(fresh.object(forKey: BackgroundSyncState.Keys.loginNotice("Stud.IP")))
        XCTAssertEqual(BackgroundSyncState.Keys.loginNotice("Stud.IP"), "uniflow.background.loginNotice.studip")
    }

    func testOutcomeAndCardText() throws {
        let d = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(BackgroundSyncRecord.outcome(BackgroundSyncReport(newFiles: 2)), .done(newFiles: 2))
        XCTAssertEqual(BackgroundSyncRecord.outcome(BackgroundSyncReport(newFiles: 2, loginNeeded: ["Stud.IP"])), .loginNeeded(["Stud.IP"]))
        XCTAssertEqual(BackgroundSyncRecord.outcome(BackgroundSyncReport(newFiles: 1, loginNeeded: ["Stud.IP"], cancelled: true)), .expired)
        XCTAssertEqual(BackgroundSyncRecord.outcome(BackgroundSyncReport(failure: "kein Netz")), .failed("kein Netz"))
        XCTAssertEqual(BackgroundSyncRecord.outcome(.skipped(.noSession)), .skipped(.noSession))
        XCTAssertEqual(BackgroundSyncRecord(finishedAt: d, kind: .refresh, outcome: .done(newFiles: 0)).text, "Listen: nichts Neues")
        XCTAssertEqual(BackgroundSyncRecord(finishedAt: d, kind: .processing, outcome: .done(newFiles: 4)).text, "Listen und Dateien: 4 neue Dateien")
        XCTAssertEqual(BackgroundSyncRecord(finishedAt: d, kind: .refresh, outcome: .loginNeeded(["Stud.IP"])).text, "Anmeldung nötig (Stud.IP)")
        XCTAssertEqual(BackgroundSyncRecord(finishedAt: d, kind: .refresh, outcome: .skipped(.alreadyRunning)).text, "übersprungen: ein Abgleich lief bereits")
        XCTAssertTrue(BackgroundSyncRecord(finishedAt: d, kind: .refresh, outcome: .expired).text.contains("vorzeitig"))
        // Codable in beide Richtungen fuer jeden Fall
        for o: BackgroundSyncRecord.Outcome in [.done(newFiles: 1), .loginNeeded(["Learnweb", "LSF"]), .expired, .failed("x"), .skipped(.switching)] {
            let r = BackgroundSyncRecord(finishedAt: d, kind: .processing, outcome: o)
            XCTAssertEqual(try JSONDecoder().decode(BackgroundSyncRecord.self, from: try JSONEncoder().encode(r)), r)
        }
    }

    // MARK: Genau ein Abschluss je Aufgabe

    private final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [BackgroundTaskRun.End] = []
        func add(_ e: BackgroundTaskRun.End) { lock.withLock { list.append(e) } }
        var all: [BackgroundTaskRun.End] { lock.withLock { list } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func set() { lock.withLock { v = true } }
        var value: Bool { lock.withLock { v } }
    }

    private func wait(_ timeout: Double = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testFinishedRunCompletesOnce() async {
        let ends = Ends()
        let run = BackgroundTaskRun { ends.add($0) }
        run.start { true }
        await wait { !ends.all.isEmpty }
        run.finish(.finished(success: false))
        run.expire()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ends.all, [.finished(success: true)])
    }

    /// Ablauf mitten im Lauf: der Lauf wird abgebrochen (Task.cancel), die Aufgabe endet einmal als abgelaufen
    func testExpirationCancelsTheRunAndCompletesOnce() async {
        let ends = Ends()
        let started = Flag(), sawCancel = Flag()
        let run = BackgroundTaskRun(graceNanos: 5_000_000_000) { ends.add($0) }
        run.start {
            started.set()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            sawCancel.set()
            return true                                                   // auch ein "Erfolg" nach dem Ablauf zaehlt nicht
        }
        await wait { started.value }
        run.expire()
        await wait { !ends.all.isEmpty }
        XCTAssertTrue(sawCancel.value)
        XCTAssertTrue(run.isExpired)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ends.all, [.expired])
    }

    /// Ein Lauf, der nicht schnell genug anhaelt: die Aufgabe endet nach der Gnadenfrist, das spaete Ende zaehlt nicht
    func testExpirationEndsAfterGraceEvenIfTheRunHangs() async {
        let ends = Ends()
        let release = Flag()
        let run = BackgroundTaskRun(graceNanos: 30_000_000) { ends.add($0) }
        run.start {
            while !release.value { usleep(2_000) }                       // haelt sich nicht an den Abbruch
            return true
        }
        run.expire()
        await wait { !ends.all.isEmpty }
        XCTAssertEqual(ends.all, [.expired])
        release.set()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(ends.all, [.expired], "kein zweiter Abschluss")
    }

    func testExpirationBeforeStartCancelsImmediately() async {
        let ends = Ends()
        let sawCancel = Flag()
        let run = BackgroundTaskRun(graceNanos: 5_000_000_000) { ends.add($0) }
        run.expire()
        run.start {
            if Task.isCancelled { sawCancel.set() }
            return true
        }
        await wait { !ends.all.isEmpty }
        XCTAssertTrue(sawCancel.value)
        XCTAssertEqual(ends.all, [.expired])
    }

    // MARK: Neue Dateien zaehlen

    func testSourceFileIDsLeaveOutOwnDocuments() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_792_900_000))
        try await db.migrate(clock: clock, university: "luh")
        let before = try await db.withConnection { try UniStore.sourceFileIDs($0) }
        try await db.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "c1", title: "Testkurs Numerik", number: nil, semester: "WiSe"), now: clock.nowISO)
            _ = try UniStore.storeFiles(c, courseID: "c1", [
                UniStore.FileRow(id: "d1", name: "Blatt 1.pdf", size: 10, mime: "application/pdf", chdate: 1, downloadURL: "x", folder: ""),
                UniStore.FileRow(id: "d2", name: "Blatt 2.pdf", size: 10, mime: "application/pdf", chdate: 1, downloadURL: "y", folder: ""),
            ], now: clock.nowISO, fileExists: { _ in false })
        }
        let after = try await db.withConnection { try UniStore.sourceFileIDs($0) }
        XCTAssertEqual(after.subtracting(before), ["d1", "d2"])
        let own = try await db.scalar("SELECT COUNT(*) FROM courses WHERE id='__user__'")?.int
        XCTAssertEqual(own, 1, "Pseudokurs der eigenen Dokumente vorhanden")
        _ = try await db.execute("INSERT INTO files(id, course_id, name, first_seen, status) VALUES ('u1', '__user__', 'Eigene.pdf', ?, 'neu')",
                             [.text(clock.nowISO)])
        let withOwn = try await db.withConnection { try UniStore.sourceFileIDs($0) }
        XCTAssertEqual(withOwn, ["d1", "d2"], "eigene Dokumente zaehlen nie als neu aus der Hochschule")
    }
}
