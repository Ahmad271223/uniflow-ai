import Foundation
import XCTest
@testable import UniFlowCore

/// Abgleich von selbst (Auftrag 17.11.2026): Fenster 8 bis 18 Uhr Ortszeit, Abstand 30 Minuten je Portal, Pause nach
/// "ueberlastet". Nur erfundene Zeiten, keine Uhr des Rechners, kein Netz.
final class AutoSyncScheduleTests: XCTestCase {
    private let plan = AutoSyncSchedule.standard

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

    private func local(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "autosync-test-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    // MARK: Die drei Zahlen

    func testStandardIsEightToEighteenEveryThirtyMinutes() {
        XCTAssertEqual(plan.startHour, 8)
        XCTAssertEqual(plan.endHour, 18)
        XCTAssertEqual(plan.interval, 30 * 60)
        XCTAssertEqual(plan.runsPerDay, 20, "8 bis 18 Uhr alle 30 Minuten: 20 Abgleiche am Tag")
    }

    // MARK: Fenster

    func testWindowBoundariesEightIsInsideEighteenIsOutside() throws {
        let tz = try zone("Europe/Berlin")
        XCTAssertFalse(plan.isInWindow(try at("2026-11-17 07:59:59", tz), timeZone: tz))
        XCTAssertTrue(plan.isInWindow(try at("2026-11-17 08:00:00", tz), timeZone: tz), "08:00 gehoert dazu")
        XCTAssertTrue(plan.isInWindow(try at("2026-11-17 12:00", tz), timeZone: tz))
        XCTAssertTrue(plan.isInWindow(try at("2026-11-17 17:59:59", tz), timeZone: tz))
        XCTAssertFalse(plan.isInWindow(try at("2026-11-17 18:00:00", tz), timeZone: tz), "18:00 gehoert nicht mehr dazu")
        XCTAssertFalse(plan.isInWindow(try at("2026-11-17 23:30", tz), timeZone: tz))
        XCTAssertFalse(plan.isInWindow(try at("2026-11-18 03:00", tz), timeZone: tz))
    }

    func testWindowAppliesOnWeekendsToo() throws {
        let tz = try zone("Europe/Berlin")
        XCTAssertTrue(plan.isInWindow(try at("2026-11-21 10:00", tz), timeZone: tz), "Samstag")
        XCTAssertTrue(plan.isInWindow(try at("2026-11-22 10:00", tz), timeZone: tz), "Sonntag")
    }

    /// Dieselbe Sekunde, zwei Orte: es zaehlt die Uhr des Ortes, an dem das Geraet ist
    func testWindowUsesTheDevicesLocalTime() throws {
        let berlin = try zone("Europe/Berlin"), newYork = try zone("America/New_York")
        let moment = try at("2026-11-17 09:00", berlin)                   // 03:00 in New York
        XCTAssertTrue(plan.isInWindow(moment, timeZone: berlin))
        XCTAssertFalse(plan.isInWindow(moment, timeZone: newYork))
        let evening = try at("2026-11-17 19:00", berlin)                  // 13:00 in New York
        XCTAssertFalse(plan.isInWindow(evening, timeZone: berlin))
        XCTAssertTrue(plan.isInWindow(evening, timeZone: newYork))
    }

    // MARK: Abstand

    func testDueWithoutEarlierRunOnlyInsideTheWindow() throws {
        let tz = try zone("Europe/Berlin")
        XCTAssertTrue(plan.isDue(last: nil, now: try at("2026-11-17 08:00", tz), timeZone: tz))
        XCTAssertFalse(plan.isDue(last: nil, now: try at("2026-11-17 07:30", tz), timeZone: tz))
        XCTAssertFalse(plan.isDue(last: nil, now: try at("2026-11-17 18:00", tz), timeZone: tz))
    }

    func testDueExactlyThirtyMinutesAfterTheLastRun() throws {
        let tz = try zone("Europe/Berlin")
        let last = try at("2026-11-17 10:00:00", tz)
        XCTAssertFalse(plan.isDue(last: last, now: try at("2026-11-17 10:00:01", tz), timeZone: tz), "eine Sekunde spaeter")
        XCTAssertFalse(plan.isDue(last: last, now: try at("2026-11-17 10:29:59", tz), timeZone: tz))
        XCTAssertTrue(plan.isDue(last: last, now: try at("2026-11-17 10:30:00", tz), timeZone: tz))
        XCTAssertTrue(plan.isDue(last: last, now: try at("2026-11-17 13:00", tz), timeZone: tz))
    }

    /// Ein Lauf vom Abend zaehlt am naechsten Morgen nicht mehr: um 08:00 geht es los
    func testRunFromTheEveningDoesNotDelayTheMorning() throws {
        let tz = try zone("Europe/Berlin")
        let last = try at("2026-11-17 17:45", tz)
        XCTAssertFalse(plan.isDue(last: last, now: try at("2026-11-17 18:15", tz), timeZone: tz), "nach 18 Uhr nie")
        XCTAssertFalse(plan.isDue(last: last, now: try at("2026-11-18 07:59", tz), timeZone: tz))
        XCTAssertTrue(plan.isDue(last: last, now: try at("2026-11-18 08:00", tz), timeZone: tz))
    }

    /// Uhr zurueckgestellt bzw. Datum gesprungen: der letzte Lauf liegt "in der Zukunft" - faellig statt ewig gesperrt
    func testClockSetBackCountsAsDue() throws {
        let tz = try zone("Europe/Berlin")
        let last = try at("2026-11-20 10:00", tz)
        XCTAssertTrue(plan.isDue(last: last, now: try at("2026-11-17 10:00", tz), timeZone: tz))
        XCTAssertFalse(plan.isDue(last: last, now: try at("2026-11-17 19:00", tz), timeZone: tz), "aber weiter nur im Fenster")
    }

    /// Datum springt vor (Uhr vorgestellt): faellig, sobald das Fenster offen ist
    func testClockSetForwardIsSimplyLater() throws {
        let tz = try zone("Europe/Berlin")
        let last = try at("2026-11-17 10:00", tz)
        XCTAssertTrue(plan.isDue(last: last, now: try at("2027-03-01 09:00", tz), timeZone: tz))
    }

    // MARK: Zeitumstellung und Zeitzonen

    /// Ende der Sommerzeit (25.10.2026, 03:00 -> 02:00): der Tag hat 25 Stunden, das Fenster bleibt 08:00 bis 18:00
    /// Ortszeit, und der Abstand zaehlt echte 30 Minuten
    func testEndOfDaylightSavingKeepsLocalWindow() throws {
        let tz = try zone("Europe/Berlin")
        XCTAssertFalse(plan.isInWindow(try at("2026-10-25 07:59", tz), timeZone: tz))
        XCTAssertTrue(plan.isInWindow(try at("2026-10-25 08:00", tz), timeZone: tz))
        XCTAssertFalse(plan.isInWindow(try at("2026-10-25 18:00", tz), timeZone: tz))
        let evening = try at("2026-10-24 17:40", tz)
        let next = plan.nextRun(last: evening, now: try at("2026-10-24 17:45", tz), timeZone: tz)
        XCTAssertEqual(local(next, tz), "2026-10-25 08:00:00")
        XCTAssertEqual(next.timeIntervalSince(try at("2026-10-24 08:00", tz)), 25 * 3600, "25 Stunden zwischen den beiden 08:00")
    }

    /// Beginn der Sommerzeit (28.03.2027, 02:00 -> 03:00): 23 Stunden, 08:00 bleibt 08:00
    func testStartOfDaylightSavingKeepsLocalWindow() throws {
        let tz = try zone("Europe/Berlin")
        let next = plan.nextRun(last: nil, now: try at("2027-03-27 20:00", tz), timeZone: tz)
        XCTAssertEqual(local(next, tz), "2027-03-28 08:00:00")
        XCTAssertEqual(next.timeIntervalSince(try at("2027-03-27 08:00", tz)), 23 * 3600)
        XCTAssertTrue(plan.isDue(last: try at("2027-03-27 17:30", tz), now: next, timeZone: tz))
    }

    /// Flug von Berlin nach New York: der Abstand bleibt echte Zeit, das Fenster folgt der neuen Ortszeit
    func testTimeZoneChangeKeepsIntervalAndMovesWindow() throws {
        let berlin = try zone("Europe/Berlin"), newYork = try zone("America/New_York")
        let last = try at("2026-11-17 17:30", berlin)                     // 11:30 in New York
        let twentyMinutesLater = last.addingTimeInterval(20 * 60)
        XCTAssertFalse(plan.isDue(last: last, now: twentyMinutesLater, timeZone: newYork), "erst 20 Minuten her")
        let fortyMinutesLater = last.addingTimeInterval(40 * 60)          // 18:10 Berlin, 12:10 New York
        XCTAssertFalse(plan.isDue(last: last, now: fortyMinutesLater, timeZone: berlin))
        XCTAssertTrue(plan.isDue(last: last, now: fortyMinutesLater, timeZone: newYork))
    }

    // MARK: Naechster Termin

    func testNextRunInsideTheWindow() throws {
        let tz = try zone("Europe/Berlin")
        let now = try at("2026-11-17 10:10", tz)
        XCTAssertEqual(plan.nextRun(last: nil, now: now, timeZone: tz), now, "noch nie gelaufen: jetzt")
        XCTAssertEqual(local(plan.nextRun(last: try at("2026-11-17 10:00", tz), now: now, timeZone: tz), tz), "2026-11-17 10:30:00")
        XCTAssertEqual(plan.nextRun(last: try at("2026-11-17 09:00", tz), now: now, timeZone: tz), now, "ueberfaellig: jetzt")
        XCTAssertEqual(plan.nextRun(last: try at("2026-11-19 09:00", tz), now: now, timeZone: tz), now, "Uhr zurueckgestellt: jetzt")
    }

    func testNextRunOutsideTheWindowIsTheNextEightOClock() throws {
        let tz = try zone("Europe/Berlin")
        XCTAssertEqual(local(plan.nextRun(last: nil, now: try at("2026-11-17 06:00", tz), timeZone: tz), tz), "2026-11-17 08:00:00")
        XCTAssertEqual(local(plan.nextRun(last: nil, now: try at("2026-11-17 18:00", tz), timeZone: tz), tz), "2026-11-18 08:00:00")
        XCTAssertEqual(local(plan.nextRun(last: nil, now: try at("2026-11-17 23:59:59", tz), timeZone: tz), tz), "2026-11-18 08:00:00")
        // letzter Lauf 17:45: 18:15 laege ausserhalb, also morgen 08:00
        XCTAssertEqual(local(plan.nextRun(last: try at("2026-11-17 17:45", tz), now: try at("2026-11-17 17:50", tz), timeZone: tz), tz),
                       "2026-11-18 08:00:00")
        // letzter Lauf 17:29: 17:59 liegt noch im Fenster
        XCTAssertEqual(local(plan.nextRun(last: try at("2026-11-17 17:29", tz), now: try at("2026-11-17 17:40", tz), timeZone: tz), tz),
                       "2026-11-17 17:59:00")
    }

    func testNextRunIsNeverInThePastAndAlwaysInsideTheWindow() throws {
        let tz = try zone("Europe/Berlin")
        let start = try at("2026-10-24 00:00", tz)
        for step in 0..<(3 * 24 * 4) {                                    // drei Tage (mit Zeitumstellung) im Viertelstundentakt
            let now = start.addingTimeInterval(Double(step) * 900)
            for last in [nil, now.addingTimeInterval(-600), now.addingTimeInterval(-7200), now.addingTimeInterval(3600)] as [Date?] {
                let next = plan.nextRun(last: last, now: now, timeZone: tz)
                XCTAssertGreaterThanOrEqual(next, now)
                XCTAssertTrue(plan.isInWindow(next, timeZone: tz), "\(local(now, tz)) -> \(local(next, tz))")
            }
        }
    }

    /// Ein ganzer Tag im Minutentakt, die App durchgehend offen: genau 20 Abgleiche, der erste 08:00, der letzte 17:30
    func testAFullDayGivesExactlyTwentyRuns() throws {
        let tz = try zone("Europe/Berlin")
        var now = try at("2026-11-17 00:00", tz)
        let end = try at("2026-11-18 00:00", tz)
        var last: Date?
        var runs: [String] = []
        while now < end {
            if plan.isDue(last: last, now: now, timeZone: tz) {
                last = now
                runs.append(String(local(now, tz).suffix(8).prefix(5)))
            }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(runs.count, 20)
        XCTAssertEqual(runs.first, "08:00")
        XCTAssertEqual(runs.last, "17:30")
    }

    /// Andere Zahlen (spaetere Einstellung): dieselbe Rechnung
    func testOtherNumbersWorkTheSameWay() throws {
        let tz = try zone("Europe/Berlin")
        let other = AutoSyncSchedule(startHour: 7, endHour: 22, interval: 3600)
        XCTAssertTrue(other.isInWindow(try at("2026-11-17 21:59", tz), timeZone: tz))
        XCTAssertFalse(other.isInWindow(try at("2026-11-17 22:00", tz), timeZone: tz))
        XCTAssertEqual(other.runsPerDay, 15)
        XCTAssertFalse(other.isDue(last: try at("2026-11-17 10:00", tz), now: try at("2026-11-17 10:45", tz), timeZone: tz))
    }

    // MARK: Stand je Portal

    func testLedgerKeepsPortalsApart() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        let now = try at("2026-11-17 10:00", tz)
        XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: nil, now: now, timeZone: tz))
        ledger.recordAttempt("Stud.IP", at: now)
        let later = now.addingTimeInterval(10 * 60)
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, now: later, timeZone: tz), "Versuch vor 10 Minuten")
        XCTAssertTrue(ledger.isDue("QIS", lastSuccess: nil, now: later, timeZone: tz), "QIS hat seinen eigenen Stand")
        XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: nil, now: now.addingTimeInterval(30 * 60), timeZone: tz))
    }

    /// Auch ein gescheiterter Versuch zaehlt (er ist vermerkt, bevor der Lauf beginnt): kein Dauerfeuer bei Fehlern
    func testFailedAttemptStillWaitsThirtyMinutes() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        let success = try at("2026-11-17 08:00", tz)
        ledger.recordAttempt("Learnweb", at: try at("2026-11-17 09:00", tz))            // gescheitert, lastSuccess bleibt 08:00
        XCTAssertFalse(ledger.isDue("Learnweb", lastSuccess: success, now: try at("2026-11-17 09:20", tz), timeZone: tz))
        XCTAssertTrue(ledger.isDue("Learnweb", lastSuccess: success, now: try at("2026-11-17 09:30", tz), timeZone: tz))
    }

    /// Ein Abgleich von Hand (Knopf "Sync") um 10:10 schiebt den naechsten von selbst auf 10:40
    func testManualSyncCountsAsLastSuccess() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        ledger.recordAttempt("Stud.IP", at: try at("2026-11-17 10:00", tz))
        let manual = try at("2026-11-17 10:10", tz)
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: manual, now: try at("2026-11-17 10:30", tz), timeZone: tz))
        XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: manual, now: try at("2026-11-17 10:40", tz), timeZone: tz))
        XCTAssertEqual(local(ledger.nextRun("Stud.IP", lastSuccess: manual, now: try at("2026-11-17 10:15", tz), timeZone: tz), tz),
                       "2026-11-17 10:40:00")
    }

    /// Wartende Arbeit (unterbrochener Lauf, Dateien eines Laufs nur mit Listen): ohne Abstand, aber nur im Fenster
    func testPendingWorkIgnoresTheIntervalButNotTheWindow() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        let now = try at("2026-11-17 10:05", tz)
        ledger.recordAttempt("Stud.IP", at: try at("2026-11-17 10:00", tz))
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, now: now, timeZone: tz))
        XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: nil, pending: true, now: now, timeZone: tz))
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, pending: true, now: try at("2026-11-17 10:04", tz), timeZone: tz),
                       "scheitert die Fortsetzung, dann fruehestens nach 5 Minuten wieder")
        XCTAssertTrue(ledger.isDue("QIS", lastSuccess: nil, pending: true, now: now, timeZone: tz), "ohne bisherigen Versuch sofort")
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, pending: true, now: try at("2026-11-17 19:00", tz), timeZone: tz))
    }

    func testOwnIntervalForRareParts() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        ledger.recordAttempt("Bescheinigungen", at: try at("2026-11-17 08:00", tz))
        XCTAssertFalse(ledger.isDue("Bescheinigungen", lastSuccess: nil, now: try at("2026-11-17 12:00", tz), timeZone: tz, interval: 6 * 3600))
        XCTAssertTrue(ledger.isDue("Bescheinigungen", lastSuccess: nil, now: try at("2026-11-17 14:00", tz), timeZone: tz, interval: 6 * 3600))
    }

    // MARK: Pause nach "ueberlastet"

    func testOverloadPausesOnlyThatPortalForTwoHours() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        let now = try at("2026-11-17 09:00", tz)
        ledger.pause("Stud.IP", from: now)
        XCTAssertEqual(ledger.pausedUntil("Stud.IP", now: now), now.addingTimeInterval(2 * 3600))
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, now: try at("2026-11-17 10:59", tz), timeZone: tz))
        XCTAssertFalse(ledger.isDue("Stud.IP", lastSuccess: nil, pending: true, now: try at("2026-11-17 10:59", tz), timeZone: tz),
                       "auch wartende Arbeit ruht")
        XCTAssertTrue(ledger.isDue("QIS", lastSuccess: nil, now: try at("2026-11-17 10:59", tz), timeZone: tz), "andere Portale laufen weiter")
        XCTAssertTrue(ledger.isDue("Stud.IP", lastSuccess: nil, now: try at("2026-11-17 11:00", tz), timeZone: tz))
        XCTAssertEqual(local(ledger.nextRun("Stud.IP", lastSuccess: nil, now: try at("2026-11-17 09:30", tz), timeZone: tz), tz),
                       "2026-11-17 11:00:00")
    }

    func testPauseEndsEarlyAfterSuccessAndNeverOutlivesAClockChange() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        ledger.pause("Moodle", from: try at("2026-11-17 09:00", tz))
        ledger.clearPause("Moodle")
        XCTAssertNil(ledger.pausedUntil("Moodle", now: try at("2026-11-17 09:10", tz)))
        // Pause vermerkt, dann die Uhr um Tage zurueckgestellt: sie gilt nicht laenger als zwei Stunden
        ledger.pause("Moodle", from: try at("2026-11-20 09:00", tz))
        XCTAssertNil(ledger.pausedUntil("Moodle", now: try at("2026-11-17 09:00", tz)))
    }

    func testOverloadIsRecognisedInMessages() {
        XCTAssertTrue(AutoSyncOverload.isOverload(status: 429))
        XCTAssertTrue(AutoSyncOverload.isOverload(status: 503))
        XCTAssertFalse(AutoSyncOverload.isOverload(status: 500))
        XCTAssertFalse(AutoSyncOverload.isOverload(status: 404))
        XCTAssertTrue(AutoSyncOverload.mentionsOverload(StudIPError.http(status: 429, path: "courses").description))
        XCTAssertTrue(AutoSyncOverload.mentionsOverload(HildesheimError.http(status: 503, url: "https://lsf.example/plan?x=1").description))
        XCTAssertFalse(AutoSyncOverload.mentionsOverload(StudIPError.http(status: 500, path: "courses").description))
        XCTAssertFalse(AutoSyncOverload.mentionsOverload("HTTP 4290 bei x"))
        XCTAssertFalse(AutoSyncOverload.mentionsOverload("Kein Netz."))
        XCTAssertFalse(AutoSyncOverload.mentionsOverload(nil))
    }

    func testLedgerKeysCarryNoSecretsAndSurviveANewInstance() throws {
        let tz = try zone("Europe/Berlin")
        let d = freshDefaults()
        let now = try at("2026-11-17 10:00", tz)
        AutoSyncLedger(defaults: d).recordAttempt("Uni-Mail", at: now)
        XCTAssertEqual(AutoSyncLedger(defaults: d).lastAttempt("Uni-Mail"), now, "uebersteht einen Neustart")
        XCTAssertEqual(AutoSyncLedger.attemptKey("Uni-Mail"), "uniflow.autosync.attempt.unimail")
        XCTAssertEqual(AutoSyncLedger.attemptKey("Stud.IP"), "uniflow.autosync.attempt.studip")
    }

    // MARK: Versatz je Geraet (26.11.2026, "Abruf schonen")

    /// Mit Versatz 17 Minuten: Fenster ab 08:17, Laeufe 08:17, 08:47 … 17:47 - weiter 20, das Ende bleibt 18:00
    func testOffsetMovesTheWindowStartButNotTheEnd() throws {
        let tz = try zone("Europe/Berlin")
        let staggered = plan.staggered(by: 17 * 60)
        XCTAssertFalse(staggered.isInWindow(try at("2026-11-17 08:16:59", tz), timeZone: tz))
        XCTAssertTrue(staggered.isInWindow(try at("2026-11-17 08:17:00", tz), timeZone: tz))
        XCTAssertTrue(staggered.isInWindow(try at("2026-11-17 17:59:59", tz), timeZone: tz))
        XCTAssertFalse(staggered.isInWindow(try at("2026-11-17 18:00:00", tz), timeZone: tz))
        XCTAssertEqual(local(staggered.nextRun(last: nil, now: try at("2026-11-17 06:00", tz), timeZone: tz), tz), "2026-11-17 08:17:00")
        XCTAssertEqual(local(staggered.nextRun(last: nil, now: try at("2026-11-17 19:00", tz), timeZone: tz), tz), "2026-11-18 08:17:00")
        var now = try at("2026-11-17 00:00", tz)
        let end = try at("2026-11-18 00:00", tz)
        var last: Date?
        var runs: [String] = []
        while now < end {
            if staggered.isDue(last: last, now: now, timeZone: tz) {
                last = now
                runs.append(String(local(now, tz).suffix(8).prefix(5)))
            }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(runs.count, 20)
        XCTAssertEqual(runs.first, "08:17")
        XCTAssertEqual(runs.last, "17:47")
    }

    func testOffsetStaysBelowTheInterval() {
        XCTAssertEqual(plan.offset, 0, "der Plan selbst hat keinen Versatz")
        XCTAssertEqual(plan.staggered(by: -5).offset, 0)
        XCTAssertEqual(plan.staggered(by: 45 * 60).offset, 30 * 60 - 1)
        XCTAssertEqual(plan.staggered(by: 61.9).offset, 61)
    }

    func testDeviceOffsetIsRolledOnceAndKept() {
        let d = freshDefaults()
        XCTAssertEqual(AutoSyncStagger.offset(defaults: d, random: { _ in 1234 }), 1234)
        XCTAssertEqual(AutoSyncStagger.offset(defaults: d, random: { _ in 7 }), 1234, "bleibt bei jedem Start derselbe")
        d.set(99_999, forKey: AutoSyncStagger.key)
        XCTAssertEqual(AutoSyncStagger.offset(defaults: d, random: { _ in 5 }), 5, "ein unsinniger Wert wird neu gewuerfelt")
        let spread = Set((0..<200).map { _ in AutoSyncStagger.offset(defaults: freshDefaults()) })
        XCTAssertTrue(spread.allSatisfy { $0 >= 0 && $0 < 30 * 60 })
        XCTAssertGreaterThan(spread.count, 100, "die Geraete verteilen sich ueber die 30 Minuten")
    }

    // MARK: eigener Abstand je Portal (Noten aus QIS hoechstens alle 4 Stunden)

    func testOwnIntervalAlsoMovesTheNextRun() throws {
        let tz = try zone("Europe/Berlin")
        let d = freshDefaults()
        let ledger = AutoSyncLedger(defaults: d)
        let last = try at("2026-11-17 08:00", tz)
        let four: TimeInterval = 4 * 3600
        XCTAssertFalse(ledger.isDue("QIS", lastSuccess: last, now: try at("2026-11-17 11:59", tz), timeZone: tz, interval: four))
        XCTAssertTrue(ledger.isDue("QIS", lastSuccess: last, now: try at("2026-11-17 12:00", tz), timeZone: tz, interval: four))
        XCTAssertEqual(local(ledger.nextRun("QIS", lastSuccess: last, now: try at("2026-11-17 08:30", tz), timeZone: tz, interval: four), tz),
                       "2026-11-17 12:00:00")
        XCTAssertEqual(local(ledger.nextRun("QIS", lastSuccess: try at("2026-11-17 16:00", tz), now: try at("2026-11-17 16:30", tz),
                                            timeZone: tz, interval: four), tz),
                       "2026-11-18 08:00:00", "nach 18 Uhr nicht mehr, am naechsten Morgen zuerst")
        XCTAssertEqual(local(ledger.nextRun("QIS", lastSuccess: last, now: try at("2026-11-17 08:30", tz), timeZone: tz), tz),
                       "2026-11-17 08:30:00", "ohne eigenen Abstand wie bisher 30 Minuten")
    }

    func testFourHoursGiveThreeRunsADay() throws {
        let tz = try zone("Europe/Berlin")
        let ledger = AutoSyncLedger(defaults: freshDefaults())
        var now = try at("2026-11-17 00:00", tz)
        let end = try at("2026-11-18 00:00", tz)
        var runs: [String] = []
        while now < end {
            if ledger.isDue("QIS", lastSuccess: nil, now: now, timeZone: tz, interval: 4 * 3600) {
                ledger.recordAttempt("QIS", at: now)
                runs.append(String(local(now, tz).suffix(8).prefix(5)))
            }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(runs, ["08:00", "12:00", "16:00"])
    }
}
