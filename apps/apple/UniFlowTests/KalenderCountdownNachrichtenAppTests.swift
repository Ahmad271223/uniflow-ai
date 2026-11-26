import EventKit
import SwiftUI
import UniFlowCore
import WidgetKit
import XCTest
@testable import UniFlow

/// Termine im Kalender, Countdown in "Heute an der Uni" und Widget "Nachrichten" (26.11.2026,
/// docs/KALENDER-COUNTDOWN-NACHRICHTEN-2026-11-26.md). Reine Regeln mit erfundenen Daten; der Abgleich zusaetzlich gegen
/// den echten Kalender des Simulators, wenn die Erlaubnis erteilt ist (`xcrun simctl privacy <Geraet> grant calendar
/// de.uniflow.ai`), sonst uebersprungen. Widget-Bilder in $UF_WIDGET_SHOT_DIR (wie WidgetSnapshotAppTests).
@MainActor
final class KalenderCountdownNachrichtenAppTests: XCTestCase {

    private func ev(_ id: Int?, _ date: String, _ title: String, _ start: String, _ end: String, status: String = "teilnahme",
                    extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["date": .string(date), "title": .string(title), "start": .string(start), "end": .string(end),
                                      "status": .string(status), "color": "#4f5bd5", "kind": "vorlesung"]
        o["event_id"] = id.map { .number(Double($0)) } ?? .null
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    private func at(_ day: String, _ time: String) throws -> Date { try XCTUnwrap(HomeWidgetClock.date(day: day, time: time)) }

    // MARK: - Kalender: Eintraege

    private var week: JSONValue {
        ["term": ["end": "2027-01-30"], "days": .array([
            ["date": "2026-11-26", "events": .array([
                ev(1, "2026-11-26", "Analysis I", "10:15", "11:45", extra: ["room": " F 102 ", "lecturer": "Prof. Beispiel", "module_name": "Mathematik I",
                                                                           "session_topic": "Folgen und Reihen"]),
                ev(2, "2026-11-26", "Lineare Algebra", "12:00", "13:30", status: "ausfall", extra: ["exception": "cancelled", "note": "Krankheit"]),
                ev(3, "2026-11-26", "Nicht besucht", "14:00", "15:00", status: "nicht_teilnahme"),
                ev(4, "2026-11-26", "Verlegt weg", "16:00", "17:00", status: "verschoben", extra: ["moved_to": "2026-11-27"]),
                ev(nil, "2026-11-26", "Analysis I", "10:15", "11:45", extra: ["studip_id": "dup", "source": "studip-kalender"]),   // doppelt
                ev(5, "2026-11-26", "Stud.IP-Ausfall", "08:00", "09:00", status: "ausfall", extra: ["exception": "cancelled", "note": "Ausfall laut Stud.IP"]),
            ]), "deadlines": .array([
                ["id": "dl-7", "title": "Blatt 4", "kind": "abgabe", "kind_label": "Abgabe", "time": "12:00", "course_title": "Analysis I"],
                ["id": "dl-8", "title": "Quiz", "kind": "test_ende", "kind_label": "Test endet", "time": ""],
                ["id": "dl-9", "title": "Klausur Analysis", "kind": "pruefung", "kind_label": "Prüfung", "time": "09:00"],
            ]), "marks": .array([])],
            ["date": "2026-11-27", "events": .array([
                ev(4, "2026-11-27", "Verlegt weg", "09:00", "10:00", extra: ["exception": "moved_here", "moved_from": "2026-11-26"]),
                ev(6, "2026-11-27", "Ferien", "10:00", "11:00", status: "ausfall", extra: ["exception": "vorlesungsfrei"]),
            ]), "marks": .array([["kind": "pause", "label": "Brückentag"]])],
            ["date": "2026-11-28", "events": .array([]), "marks": .array([["kind": "pause", "label": "Brückentag"]])],
            ["date": "2026-11-29", "events": .array([]), "marks": .array([["kind": "feiertag", "label": "1. Advent"]])],
        ])]
    }

    private var cancelled: Set<String> { StudIPCancellations.keys(.array([["event_id": .number(5), "date": "2026-11-26"]])) }

    func testItemsFollowTheTimetableAsShownInTheApp() throws {
        let exams: JSONValue = .array([["id": "exam-luh-1-2026-11-26", "date": "2026-11-26", "time": "09:00", "end": "11:00",
                                        "title": "Klausur Analysis", "room": "Audimax", "source_label": "QIS"]])
        let items = CalendarExportPlan.items(weeks: [week], cancelled: cancelled, exams: exams.array ?? [], settings: CalendarExportSettings(),
                                             from: "2026-11-26", to: "2026-11-30")
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })

        let a = try XCTUnwrap(byKey["e1@2026-11-26"])
        XCTAssertEqual(a.title, "Analysis I")
        XCTAssertEqual(a.location, "F 102")
        XCTAssertEqual(a.start, try at("2026-11-26", "10:15"))
        XCTAssertEqual(a.end, try at("2026-11-26", "11:45"))
        XCTAssertTrue(a.notes.contains("Lehrende: Prof. Beispiel"))
        XCTAssertTrue(a.notes.contains("Vorlesung · Modul Mathematik I"))
        XCTAssertTrue(a.notes.contains("Thema: Folgen und Reihen"))
        XCTAssertEqual(a.url?.absoluteString, "uniflow://#/timetable?date=2026-11-26&sn=e1%402026-11-26")
        XCTAssertFalse(a.free)
        XCTAssertNil(byKey["sstudip-kalender|dup"], "gleicher Titel, gleiche Zeit aus zweiter Quelle: einmal")

        let gone = try XCTUnwrap(byKey["e2@2026-11-26"])
        XCTAssertEqual(gone.title, "Fällt aus: Lineare Algebra")
        XCTAssertTrue(gone.free)
        XCTAssertTrue(gone.notes.hasPrefix("Fällt aus (Krankheit)."))
        XCTAssertNil(byKey["e5@2026-11-26"], "Ausfall laut Stud.IP: in der App ausgeblendet, also auch im Kalender")
        XCTAssertNil(byKey["e3@2026-11-26"], "nicht besucht")
        XCTAssertNil(byKey["e6@2026-11-27"], "vorlesungsfrei: steht als Feiertag/Pause da")

        let moved = try XCTUnwrap(byKey["e4@2026-11-26"], "verlegt: Kennung des urspruenglichen Tages")
        XCTAssertEqual(moved.start, try at("2026-11-27", "09:00"))
        XCTAssertTrue(moved.notes.contains("Verlegt vom 26.11."))
        XCTAssertEqual(items.filter { $0.key == "e4@2026-11-26" }.count, 1)

        let due = try XCTUnwrap(byKey["ddl-7"])
        XCTAssertEqual(due.title, "Abgabe: Blatt 4 (bis 12:00)")
        XCTAssertEqual(due.end, try at("2026-11-26", "12:00"))
        XCTAssertEqual(due.end.timeIntervalSince(due.start), 15 * 60)
        XCTAssertTrue(due.free)
        let quiz = try XCTUnwrap(byKey["ddl-8"])
        XCTAssertTrue(quiz.allDay)
        XCTAssertEqual(quiz.title, "Test endet: Quiz")
        XCTAssertNil(byKey["ddl-9"], "erkannte Pruefung am Tag einer Pruefung: nicht doppelt")
        let exam = try XCTUnwrap(byKey["xexam-luh-1-2026-11-26"])
        XCTAssertEqual(exam.location, "Audimax")
        XCTAssertEqual(exam.end, try at("2026-11-26", "11:00"))

        let bridge = try XCTUnwrap(byKey["hpause|Brückentag|0"], "zwei Tage als ein Eintrag")
        XCTAssertTrue(bridge.allDay)
        XCTAssertTrue(Calendar.current.isDate(bridge.start, inSameDayAs: try XCTUnwrap(CalendarExportPlan.allDayDate("2026-11-27"))))
        XCTAssertTrue(Calendar.current.isDate(bridge.end, inSameDayAs: try XCTUnwrap(CalendarExportPlan.allDayDate("2026-11-28"))))
        XCTAssertNotNil(byKey["hfeiertag|1. Advent|0"])
        XCTAssertEqual(Set(items.map(\.key)).count, items.count, "jede Kennung einmal")
    }

    func testSwitchesLeaveThingsOut() {
        var s = CalendarExportSettings()
        s.cancelled = false
        s.deadlines = false
        s.exams = false
        s.holidays = false
        let items = CalendarExportPlan.items(weeks: [week], cancelled: cancelled, exams: [], settings: s, from: "2026-11-26", to: "2026-11-30")
        XCTAssertEqual(Set(items.map(\.key)), ["e1@2026-11-26", "e4@2026-11-26"])
        let narrow = CalendarExportPlan.items(weeks: [week], cancelled: cancelled, exams: [], settings: s, from: "2026-11-27", to: "2026-11-27")
        XCTAssertEqual(narrow.map(\.key), ["e4@2026-11-26"], "nur im Zeitraum")
    }

    func testKeyRoundTripAndForeignEvents() throws {
        for k in ["e12@2026-11-26", "sstudip-kalender|a b/c?d=e&f", "huni|Vorlesungsfreie Zeit|0", "xexam-luh-1-2026-11-26"] {
            let url = try XCTUnwrap(CalendarExportPlan.url(route: "timetable", date: "2026-11-26", key: k))
            XCTAssertEqual(CalendarExportPlan.key(from: url), k)
            XCTAssertEqual(UFRoute(hash: String(url.absoluteString.dropFirst("uniflow://".count))), .timetable(date: "2026-11-26"), "Link oeffnet den Tag")
        }
        XCTAssertNil(CalendarExportPlan.key(from: URL(string: "https://example.org/?sn=e1")), "fremde Adresse")
        XCTAssertNil(CalendarExportPlan.key(from: URL(string: "uniflow://#/timetable?date=2026-11-26")), "ohne Kennung")
        XCTAssertNil(CalendarExportPlan.key(from: nil))
    }

    func testLastDayOfRange() {
        XCTAssertEqual(CalendarExportPlan.lastDay(today: "2026-11-26", range: .weeks2, termEnd: nil), "2026-12-09")
        XCTAssertEqual(CalendarExportPlan.lastDay(today: "2026-11-26", range: .weeks8, termEnd: nil), "2027-01-20")
        XCTAssertEqual(CalendarExportPlan.lastDay(today: "2026-11-26", range: .term, termEnd: "2027-01-30"), "2027-01-30")
        XCTAssertEqual(CalendarExportPlan.lastDay(today: "2026-11-26", range: .term, termEnd: "2026-11-28"), "2026-12-09", "mindestens 2 Wochen")
        XCTAssertEqual(CalendarExportPlan.lastDay(today: "2026-11-26", range: .term, termEnd: "2028-01-01"), Mensa.addDays("2026-11-26", 199), "hoechstens 200 Tage")
        XCTAssertEqual(CalendarExportPlan.lastDay(today: "2026-11-26", range: .term, termEnd: "kaputt"), "2027-01-20", "ohne Semesterende 8 Wochen")
    }

    // MARK: - Kalender: Abgleich

    private func item(_ key: String, _ title: String, _ h: Double, allDay: Bool = false) -> CalendarItem {
        let base = Date(timeIntervalSince1970: 1_795_600_000)
        return CalendarItem(key: key, title: title, start: base.addingTimeInterval(h * 3600), end: base.addingTimeInterval(h * 3600 + 5400),
                            allDay: allDay, notes: "n", url: CalendarExportPlan.url(route: "timetable", date: nil, key: key))
    }

    func testChangesOnlyTouchOwnEventsAndNothingTwice() {
        let keep = item("a", "Analysis", 1), changed = item("b", "Algebra", 3), stale = item("c", "Weg", 5), fresh = item("d", "Neu", 7)
        var moved = changed
        moved.start = moved.start.addingTimeInterval(3600)
        moved.end = moved.end.addingTimeInterval(3600)
        let existing = [
            StoredCalendarEvent(id: "1", key: "a", item: keep),
            StoredCalendarEvent(id: "2", key: "a", item: keep),                        // doppelt (abgebrochener Lauf)
            StoredCalendarEvent(id: "3", key: "b", item: changed),
            StoredCalendarEvent(id: "4", key: "c", item: stale),
            StoredCalendarEvent(id: "5", key: nil, item: item("", "Eigener Termin", 2)),  // vom Nutzer im Kalender "StudiNow"
        ]
        let c = CalendarExportPlan.changes(existing: existing, desired: [keep, moved, fresh])
        XCTAssertEqual(c.create, [fresh])
        XCTAssertEqual(c.update.map(\.id), ["3"])
        XCTAssertEqual(c.update.first?.item, moved)
        XCTAssertEqual(c.remove, ["2", "4"])
        XCTAssertFalse(c.remove.contains("5"), "fremdes Ereignis bleibt")
        XCTAssertTrue(CalendarExportPlan.changes(existing: [StoredCalendarEvent(id: "1", key: "a", item: keep)], desired: [keep]).isEmpty, "nichts zu tun")
        var busy = keep
        busy.free = true
        XCTAssertEqual(CalendarExportPlan.changes(existing: [StoredCalendarEvent(id: "1", key: "a", item: keep)], desired: [busy]).update.count, 1)
        XCTAssertTrue(CalendarExportPlan.changes(existing: [StoredCalendarEvent(id: "1", key: "a", item: keep)], desired: [busy], availability: false).isEmpty,
                      "Kalender ohne frei/beschäftigt: kein ewiges Neuschreiben")
    }

    func testAllDayRunThatStartedBeforeTodayKeepsItsStart() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: 1_795_600_000))
        let earlier = try XCTUnwrap(cal.date(byAdding: .day, value: -10, to: today))
        let end = try XCTUnwrap(cal.date(byAdding: .day, value: 20, to: today))
        let old = CalendarItem(key: "hpause|Weihnachten|0", title: "Weihnachten", start: earlier, end: end, allDay: true, notes: "x", url: nil, free: true)
        var now = old
        now.start = today
        XCTAssertTrue(CalendarExportPlan.changes(existing: [StoredCalendarEvent(id: "1", key: old.key, item: old)], desired: [now], today: today).isEmpty)
    }

    /// Gegen den echten Kalender des Simulators: anlegen, zweiter Lauf ohne Aenderung, Aendern, Entfernen, fremdes
    /// Ereignis im eigenen Kalender bleibt, Abschalten entfernt den Kalender
    func testRealCalendarOnTheSimulator() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Kalender-Erlaubnis fehlt (xcrun simctl privacy <Geraet> grant calendar de.uniflow.ai)")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "kalender-test-\(UUID().uuidString)"))
        let store = EKEventStore()
        let target = try EventKitCalendarStore.open(store: store, defaults: defaults, color: nil)
        defer { try? EventKitCalendarStore.remove(store: store, defaults: defaults) }
        XCTAssertEqual(target.calendar.title, "StudiNow")

        let now = try at("2026-11-26", "09:00")
        let desired = CalendarExportPlan.items(weeks: [week], cancelled: cancelled, exams: [], settings: CalendarExportSettings(),
                                               from: "2026-11-26", to: "2026-11-30")
        let first = try CalendarExport.run(target: target, desired: desired, now: now)
        XCTAssertEqual(first.create.count, desired.count)
        let back = try target.events(from: try at("2026-11-26", "00:00"), to: try at("2026-12-01", "00:00"))
        for d in desired {
            guard let e = back.first(where: { $0.key == d.key }) else { XCTFail("fehlt: \(d.key)"); continue }
            XCTAssertTrue(e.item.sameContent(as: d, availability: target.supportsAvailability), "liest sich anders zurueck: \(d.key)\n\(d)\n\(e.item)")
        }
        XCTAssertTrue(try CalendarExport.run(target: target, desired: desired, now: now).isEmpty, "zweiter Lauf: nichts doppelt, nichts geaendert")

        // fremdes Ereignis im Kalender "StudiNow"
        let foreign = EKEvent(eventStore: store)
        foreign.calendar = target.calendar
        foreign.title = "Selbst eingetragen"
        foreign.startDate = try at("2026-11-26", "18:00")
        foreign.endDate = try at("2026-11-26", "19:00")
        try store.save(foreign, span: .thisEvent, commit: true)

        var changed = desired.filter { $0.key != "ddl-7" }
        let i = try XCTUnwrap(changed.firstIndex { $0.key == "e1@2026-11-26" })
        changed[i].location = "Hörsaal 2"
        let second = try CalendarExport.run(target: target, desired: changed, now: now)
        XCTAssertEqual(second.update.count, 1)
        XCTAssertEqual(second.remove.count, 1)
        XCTAssertTrue(second.create.isEmpty)
        let events = try target.events(from: try at("2026-11-26", "00:00"), to: try at("2026-12-01", "00:00"))
        XCTAssertEqual(events.first { $0.key == "e1@2026-11-26" }?.item.location, "Hörsaal 2")
        XCTAssertTrue(events.contains { $0.key == nil && $0.item.title == "Selbst eingetragen" }, "fremdes Ereignis bleibt")
        XCTAssertEqual(events.filter { $0.key != nil }.count, changed.count)
        XCTAssertTrue(try CalendarExport.run(target: target, desired: changed, now: now).isEmpty, "ganztaegige und Zeiten lesen sich gleich zurueck")

        // Abschalten: Kalender weg; danach gilt der gemerkte als geloescht
        try EventKitCalendarStore.remove(store: store, defaults: defaults)
        XCTAssertNil(store.calendar(withIdentifier: target.calendar.calendarIdentifier))
        defaults.set(target.calendar.calendarIdentifier, forKey: CalendarExportSettings.Keys.calendarID)
        XCTAssertThrowsError(try EventKitCalendarStore.open(store: store, defaults: defaults, color: nil)) {
            XCTAssertEqual($0 as? EventKitCalendarStore.Problem, .calendarDeleted)
        }
        defaults.removeObject(forKey: CalendarExportSettings.Keys.calendarID)
    }

    func testSettingsDefaultOffAndRoundTrip() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "kalender-einst-\(UUID().uuidString)"))
        let s0 = CalendarExportSettings.load(d)
        XCTAssertFalse(s0.enabled, "von selbst aus")
        XCTAssertEqual(s0.range, .term)
        XCTAssertTrue(s0.deadlines && s0.exams && s0.cancelled && s0.holidays)
        var s = s0
        s.enabled = true
        s.range = .weeks4
        s.cancelled = false
        s.save(d)
        XCTAssertEqual(CalendarExportSettings.load(d), s)
    }

    // MARK: - Countdown

    private var today: [JSONValue] {
        [ev(1, "2026-11-26", "Analysis I", "10:15", "11:45"),
         ev(2, "2026-11-26", "Fällt aus", "12:00", "13:00", status: "ausfall"),
         ev(3, "2026-11-26", "Algebra", "14:00", "15:30"),
         ev(4, "2026-11-26", "Tutorium", "14:00", "15:00"),
         ev(5, "2026-11-26", "Abends", "18:15", "19:45")]
    }

    func testCountdownLabels() throws {
        let d = "2026-11-26"
        func label(_ i: Int, _ t: String) throws -> TerminCountdown.Label? {
            TerminCountdown.label(for: today[i], in: today, date: d, now: try at(d, t))
        }
        XCTAssertEqual(try label(0, "09:50")?.text, "in 25 Min")
        XCTAssertEqual(try label(0, "09:50")?.spoken, "Beginnt in 25 Minuten")
        XCTAssertNil(try label(2, "09:50"), "nur der naechste")
        XCTAssertEqual(try label(0, "08:00")?.text, "in 2 Std 15 Min")
        XCTAssertEqual(try label(0, "09:15")?.text, "in 1 Std")
        XCTAssertEqual(try label(0, "10:14")?.text, "in 1 Min")
        XCTAssertEqual(try label(0, "10:15")?.text, "läuft · noch 1 Std 30 Min")
        XCTAssertEqual(try label(0, "11:10")?.text, "läuft · noch 35 Min")
        XCTAssertEqual(try label(0, "11:10")?.spoken, "Läuft gerade, noch 35 Minuten")
        XCTAssertEqual(try label(0, "11:44")?.spoken, "Läuft gerade, noch 1 Minute")
        XCTAssertNil(try label(0, "11:45"), "vorbei")
        XCTAssertNil(try label(1, "11:50"), "Ausfall zaehlt nicht")
        XCTAssertEqual(try label(2, "11:50")?.text, "in 2 Std 10 Min", "nach Analysis kommt Algebra, nicht der Ausfall")
        XCTAssertEqual(try label(3, "11:50")?.text, "in 2 Std 10 Min", "gleicher Beginn: beide")
        XCTAssertEqual(try label(3, "14:30")?.text, "läuft · noch 30 Min")
        XCTAssertEqual(try label(2, "14:30")?.text, "läuft · noch 1 Std")
        XCTAssertEqual(try label(4, "14:30")?.text, "in 3 Std 45 Min", "waehrend zwei laufen: der naechste danach")
        let soon = try at(d, "13:59").addingTimeInterval(30)
        XCTAssertEqual(TerminCountdown.label(for: today[2], in: today, date: d, now: soon)?.text, "in 1 Min")
        XCTAssertEqual(TerminCountdown.label(for: today[2], in: today, date: d, now: try at(d, "14:00").addingTimeInterval(-0.5))?.text, "in 1 Min")
    }

    func testAfterTheLastEventTheNextDay() throws {
        let d = "2026-11-26"           // Donnerstag
        let tomorrow = TerminCountdown.Later(date: "2026-11-27", start: "08:15", title: "Analysis I")
        XCTAssertNil(TerminCountdown.afterLast(today, date: d, now: try at(d, "19:00"), later: tomorrow), "Abends laeuft noch")
        let l = try XCTUnwrap(TerminCountdown.afterLast(today, date: d, now: try at(d, "19:45"), later: tomorrow))
        XCTAssertEqual(l.text, "Als Nächstes: morgen 8:15 · Analysis I")
        XCTAssertEqual(l.spoken, "Nächster Termin morgen um 8:15 Uhr: Analysis I")
        let monday = TerminCountdown.Later(date: "2026-11-30", start: "10:00", title: "Algebra")
        XCTAssertEqual(TerminCountdown.afterLast(today, date: d, now: try at(d, "21:00"), later: monday)?.text, "Als Nächstes: Mo. 10:00 · Algebra")
        let far = TerminCountdown.Later(date: "2026-12-14", start: "10:00", title: "Algebra")
        XCTAssertEqual(TerminCountdown.afterLast(today, date: d, now: try at(d, "21:00"), later: far)?.text, "Als Nächstes: 14.12. 10:00 · Algebra")
        XCTAssertNil(TerminCountdown.afterLast(today, date: d, now: try at(d, "21:00"), later: nil), "nichts in Sicht: Zeile verschwindet")
        XCTAssertNil(TerminCountdown.afterLast([today[1]], date: d, now: try at(d, "21:00"), later: tomorrow), "nur ein Ausfall heute: keine Zeile")
    }

    func testLaterSkipsCancelledAndEmptyDays() {
        let w: JSONValue = ["days": .array([
            ["date": "2026-11-27", "events": .array([])],
            ["date": "2026-11-28", "events": .array([ev(9, "2026-11-28", "Abgesagt", "08:00", "09:00", status: "ausfall", extra: ["exception": "cancelled"]),
                                                    ev(10, "2026-11-28", "Ausfall", "09:00", "10:00", status: "ausfall"),
                                                    ev(11, "2026-11-28", "Übung", "12:00", "13:00"),
                                                    ev(12, "2026-11-28", "Früher", "10:30", "11:00")])],
        ])]
        let keys = StudIPCancellations.keys(.array([["event_id": .number(9), "date": "2026-11-28"]]))
        XCTAssertEqual(TerminCountdown.later(week: w, cancelled: keys), .init(date: "2026-11-28", start: "10:30", title: "Früher"))
        XCTAssertNil(TerminCountdown.later(week: nil, cancelled: []))
    }

    // MARK: - Widget "Nachrichten"

    private func msg(_ id: String, _ sent: String, read: Bool?, sender: String = "Lehrende", subject: String = "Betreff", text: String = "Text") -> JSONValue {
        ["id": .string(id), "sender": .string(sender), "subject": .string(subject), "text": .string(text), "sent_at": .string(sent),
         "read": read.map(JSONValue.bool) ?? .null]
    }

    func testMessagesCountOnlyUnreadAndNew() throws {
        let list: JSONValue = ["messages": .array([
            msg("1", "2026-11-26T09:00:00+01:00", read: false, subject: "Blatt 5\nist online", text: "Bitte bis Freitag abgeben. " + String(repeating: "x", count: 200)),
            msg("2", "2026-11-26T08:00:00+01:00", read: true, subject: "Schon im Browser gelesen"),
            msg("3", "2026-11-26T07:00:00+01:00", read: nil, sender: "", subject: ""),
            msg("4", "2026-11-20T07:00:00+01:00", read: false, subject: "Vor dem letzten Öffnen"),
        ]), "fetched_at": "2026-11-26T09:30:00"]
        let mark = MessagesInbox.ReadState(baseline: "2026-11-25T12:00:00+01:00")
        let m = try XCTUnwrap(HomeWidgetSync.messages(list: list, state: mark, source: "Stud.IP", prefs: MessagesWidgetPrefs(), mailUnread: nil, mailListing: nil))
        XCTAssertEqual(m.unread, 2)
        XCTAssertEqual(m.lines.map(\.subject), ["Blatt 5 ist online", "(ohne Betreff)"])
        XCTAssertEqual(m.lines[1].sender, "Stud.IP", "ohne Absender die Quelle")
        XCTAssertNil(m.lines[0].preview, "kein Nachrichtentext ohne Schalter")
        XCTAssertFalse(m.lockSubjects)
        XCTAssertNil(m.mailUnread)

        var prefs = MessagesWidgetPrefs()
        prefs.preview = true
        prefs.lockSubjects = true
        let mail: JSONValue = ["messages": .array([["uid": 3, "sender": "Prüfungsamt", "subject": "Anmeldung", "read": false],
                                                   ["uid": 2, "sender": "Bibliothek", "subject": "Leihfrist", "read": true]])]
        let p = try XCTUnwrap(HomeWidgetSync.messages(list: list, state: mark, source: "Stud.IP", prefs: prefs, mailUnread: 5, mailListing: mail))
        let preview = try XCTUnwrap(p.lines[0].preview)
        XCTAssertTrue(preview.hasPrefix("Bitte bis Freitag abgeben."))
        XCTAssertEqual(preview.count, HomeWidgetSync.previewLength)
        XCTAssertTrue(p.lockSubjects)
        XCTAssertEqual(p.mailUnread, 5)
        XCTAssertEqual(p.total, 7)
        XCTAssertEqual(p.lines.map(\.isMail), [false, false, true], "erst die Quelle, dann ungelesene E-Mails")
        XCTAssertEqual(p.lines.last?.sender, "Prüfungsamt")

        XCTAssertNil(HomeWidgetSync.messages(list: ["messages": .array([])], state: .init(), source: "Stud.IP", prefs: prefs, mailUnread: nil, mailListing: nil),
                     "weder Nachrichten noch Uni-Mail: Hinweis statt Zahl")
        XCTAssertEqual(HomeWidgetSync.messages(list: nil, state: .init(), source: "Stud.IP", prefs: prefs, mailUnread: 0, mailListing: nil)?.total, 0)
        XCTAssertEqual(HomeWidgetSync.sourceName(.hildesheim), "Learnweb")
        XCTAssertEqual(HomeWidgetSync.sourceName(.hsh), "Moodle")
        XCTAssertEqual(HomeWidgetSync.sourceName(.luh), "Stud.IP")
    }

    /// Lauf ohne Fenster (Hintergrund): Uni-Mail-Zahl und -Zeilen bleiben vom letzten Stand
    func testBackgroundRunKeepsMailCount() throws {
        let now = Date(timeIntervalSince1970: 1_795_400_000)
        let old = try XCTUnwrap(HomeWidgetData.sampleMessages(now: now).messages)
        var fresh = old
        fresh.mailUnread = nil
        fresh.lines = Array(old.lines.filter { !$0.isMail }.prefix(1))
        let kept = try XCTUnwrap(HomeWidgetSync.keepingMail(fresh, from: old))
        XCTAssertEqual(kept.mailUnread, 1)
        XCTAssertEqual(kept.lines.map(\.isMail), [false, true])
        XCTAssertEqual(HomeWidgetSync.keepingMail(fresh, from: nil), fresh, "ohne alten Stand: wie neu")
        XCTAssertNil(HomeWidgetSync.keepingMail(nil, from: old), "keine Quelle mehr: nichts erfinden")
    }

    func testBadgeIgnoresMessagesReadInStudIP() {
        let list = [msg("1", "2026-11-26T09:00:00+01:00", read: true), msg("2", "2026-11-26T10:00:00+01:00", read: nil),
                    msg("3", "2026-11-26T11:00:00+01:00", read: false)]
        XCTAssertEqual(MessagesInbox.unreadCount(list, state: .init()), 2)
        XCTAssertEqual(MessagesInbox.unreadCount(list, state: .init(baseline: "2026-11-26T10:30:00+01:00")), 1)
        XCTAssertEqual(MessagesInbox.unreadCount(list, state: .init(overrides: ["3": true])), 1, "in StudiNow geoeffnet")
        XCTAssertEqual(MessagesInbox.unreadCount(list, state: .init(overrides: ["1": false])), 3, "eigene Wahl vor Stud.IP")
    }

    /// Ausgangsmarke beim Umstieg: einmal aus der frueheren Marke, danach fest (auch wenn die Seite die Marke weiterschiebt)
    func testBaselineIsTakenOnce() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "lese-stand-\(UUID().uuidString)"))
        d.set("2026-11-20T08:00:00+01:00", forKey: MessagesInbox.seenKey)
        XCTAssertEqual(MessagesInbox.readState(d).baseline, "2026-11-20T08:00:00+01:00")
        d.set("2026-11-26T08:00:00+01:00", forKey: MessagesInbox.seenKey)
        XCTAssertEqual(MessagesInbox.readState(d).baseline, "2026-11-20T08:00:00+01:00", "bleibt fest")
        let fresh = try XCTUnwrap(UserDefaults(suiteName: "lese-stand-\(UUID().uuidString)"))
        XCTAssertNil(MessagesInbox.readState(fresh).baseline, "nie geoeffnet: keine Marke")
        fresh.set("2026-11-26T08:00:00+01:00", forKey: MessagesInbox.seenKey)
        XCTAssertNil(MessagesInbox.readState(fresh).baseline, "spaeter auch nicht")
    }

    func testOldSnapshotWithoutMessagesStillReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)/home-widget.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"createdAt":1795400000,"events":[],"eventsUntil":1795400000}"#.utf8).write(to: url)
        let d = try XCTUnwrap(HomeWidgetStore.load(from: url), "Schnappschuss von Build 50 bleibt lesbar")
        XCTAssertNil(d.messages)
        let now = Date(timeIntervalSince1970: 1_795_400_000)
        XCTAssertTrue(HomeWidgetStore.save(.sampleMessages(now: now), to: url))
        XCTAssertEqual(HomeWidgetStore.load(from: url)?.messages, HomeWidgetData.sampleMessages(now: now).messages)
    }

    func testWidgetPrefsDefaults() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "widget-prefs-\(UUID().uuidString)"))
        let p = MessagesWidgetPrefs.load(d)
        XCTAssertFalse(p.lockSubjects, "Sperrbildschirm: von selbst ohne Betreff")
        XCTAssertFalse(p.preview, "kein Nachrichtentext ohne Schalter")
        XCTAssertTrue(p.mail)
    }

    // MARK: Bilder

    private var shotDir: URL {
        let env = ProcessInfo.processInfo.environment["UF_WIDGET_SHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let dir = env ?? FileManager.default.temporaryDirectory.appendingPathComponent("widget-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func render<V: View>(_ view: V, family: WidgetFamily, size: CGSize, dark: Bool, name: String) throws {
        let system = [.systemSmall, .systemMedium, .systemLarge].contains(family)
        let framed = view
            .padding(system ? 16 : 0)
            .frame(width: size.width, height: size.height)
            .background(system ? Color(uiColor: .systemBackground) : Color.white.opacity(dark ? 0.08 : 0.2))
            .clipShape(RoundedRectangle(cornerRadius: system ? 22 : (family == .accessoryCircular ? 38 : 8)))
            .padding(8)
            .background(system ? Color(white: dark ? 0.0 : 0.85) : Color(white: 0.15))
            .environment(\.colorScheme, system ? (dark ? .dark : .light) : .dark)
        let r = ImageRenderer(content: framed)
        r.scale = 3
        let image = try XCTUnwrap(r.uiImage, "Bild \(name)")
        try XCTUnwrap(image.pngData()).write(to: shotDir.appendingPathComponent("\(name)-\(dark ? "dunkel" : "hell").png"))
    }

    func testRenderMessagesWidget() throws {
        let now = try at("2026-11-26", "10:30")
        let full = HomeWidgetData.sampleMessages(now: now)
        var none = full
        none.messages?.unread = 0
        none.messages?.mailUnread = nil
        none.messages?.lines = []
        var noMessages = full
        noMessages.messages = nil
        let sizes: [(WidgetFamily, String, CGSize)] = [
            (.systemSmall, "klein", CGSize(width: 170, height: 170)),
            (.systemMedium, "mittel", CGSize(width: 364, height: 170)),
            (.accessoryRectangular, "sperr-rechteck", CGSize(width: 172, height: 76)),
            (.accessoryCircular, "sperr-rund", CGSize(width: 76, height: 76)),
            (.accessoryInline, "sperr-zeile", CGSize(width: 250, height: 22)),
        ]
        for dark in [false, true] {
            for (fam, label, size) in sizes {
                try render(MessagesWidgetView(entry: .init(date: now, data: full), familyOverride: fam), family: fam, size: size, dark: dark, name: "nachrichten-\(label)")
                try render(MessagesWidgetView(entry: .init(date: now, data: none), familyOverride: fam), family: fam, size: size, dark: dark, name: "nachrichten-gelesen-\(label)")
            }
            try render(MessagesWidgetView(entry: .init(date: now, data: noMessages), familyOverride: .systemSmall), family: .systemSmall,
                       size: sizes[0].2, dark: dark, name: "nachrichten-ohne-quelle-klein")
            try render(MessagesWidgetView(entry: .init(date: now, data: nil), familyOverride: .systemMedium), family: .systemMedium,
                       size: sizes[1].2, dark: dark, name: "nachrichten-leer-mittel")
        }
        print("Widget-Bilder: \(shotDir.path)")
    }

    // MARK: Bilder des Countdowns (feste Uhrzeit, iPhone und iPad, grosse Schrift)

    func testRenderCountdownCard() throws {
        let d = "2026-11-26"
        let evs = [ev(1, d, "Analysis I", "10:15", "11:45", extra: ["room": "F 102"]),
                   ev(2, d, "Lineare Algebra – Übung", "12:00", "13:30", status: "ausfall", extra: ["exception": "cancelled", "room": "B 305"]),
                   ev(3, d, "Grundlagen der Informatik – Vorlesung", "14:00", "15:30", extra: ["room": "Hörsaal A"])]
        let later = TerminCountdown.Later(date: "2026-11-27", start: "08:15", title: "Programmieren")
        defer { TerminCountdown.nowOverride = nil }
        let cases: [(String, String)] = [("bald", "09:50"), ("laeuft", "11:10"), ("pause", "13:40"), ("abends", "18:00")]
        let devices: [(String, CGFloat, Bool, DynamicTypeSize)] = [("iphone", 402, true, .large), ("iphone-gross", 402, true, .accessibility2),
                                                                   ("iphone-se", 375, true, .large), ("ipad", 720, false, .large)]
        for (label, time) in cases {
            TerminCountdown.nowOverride = try at(d, time)
            for (dev, width, compact, type) in devices {
                for dark in [false, true] {
                    let view = DashboardEventsCard(events: evs, date: d, later: later, compact: compact, openTimetable: {}, open: { _ in })
                        .padding(16)
                        .frame(width: width)
                        .background(UF.bg)
                        .environment(\.ufCompact, compact)
                        .environment(\.dynamicTypeSize, type)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    let image = try XCTUnwrap(r.uiImage, "Bild \(label) \(dev)")
                    try XCTUnwrap(image.pngData()).write(to: shotDir.appendingPathComponent("countdown-\(label)-\(dev)-\(dark ? "dunkel" : "hell").png"))
                }
            }
        }
        print("Countdown-Bilder: \(shotDir.path)")
    }
}

/// Durchgehend wie in der App: lokale Datenbank (`LocalBackendHost`), Termine, Ausfall, Verlegung und Nachrichten ueber
/// dieselben Schnittstellen wie die Seiten der App, dann Kalender-Abgleich gegen den echten Kalender des Simulators,
/// Widget-Schnappschuss und Countdown aus denselben Antworten. Uhr der Datenbank: Do., 26.11.2026, 09:00 Berlin.
@MainActor
final class KalenderDurchgehendAppTests: XCTestCase {
    private func backend() throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kalender-durchgehend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-26T09:00:00")!)
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func at(_ day: String, _ time: String) throws -> Date { try XCTUnwrap(HomeWidgetClock.date(day: day, time: time)) }

    func testFromTheAppsTimetableIntoTheRealCalendarAndBack() async throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Kalender-Erlaubnis fehlt (xcrun simctl privacy <Geraet> grant calendar de.uniflow.ai)")
        }
        let api = try backend()
        // zwei eigene Reihen wie "Termin hinzufügen" im Stundenplan (Wochentag 0 = Montag)
        let analysis = try await api.value("/api/timetable/events", method: "POST", body: [
            "title": "Analysis I", "kind": "vorlesung", "weekday": 3, "start_time": "10:15", "end_time": "11:45",
            "room": "F 102", "lecturer": "Prof. Beispiel", "date_from": "2026-11-01", "date_to": "2027-01-30"])
        let prog = try await api.value("/api/timetable/events", method: "POST", body: [
            "title": "Programmieren", "kind": "uebung", "weekday": 4, "start_time": "08:15", "end_time": "09:45",
            "room": "Audimax", "date_from": "2026-11-01", "date_to": "2027-01-30"])
        let a = try XCTUnwrap(analysis.i("id")), p = try XCTUnwrap(prog.i("id"))
        // selbst markierter Ausfall und eine Verlegung, wie im Termin-Detail
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(a)), "date": "2026-12-03", "type": "cancelled", "note": "Krankheit"])
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(p)), "date": "2026-11-27", "type": "moved", "new_date": "2026-11-28", "new_start": "10:00", "new_end": "11:30"])

        let now = try at("2026-11-26", "09:00")
        var settings = CalendarExportSettings()
        settings.range = .weeks2
        let got = await CalendarExport.desired(api: api, settings: settings, now: now)
        let desired = try XCTUnwrap(got)
        let byKey = Dictionary(desired.map { ($0.key, $0) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(byKey["e\(a)@2026-11-26"]?.location, "F 102")
        XCTAssertTrue(byKey["e\(a)@2026-11-26"]?.notes.contains("Lehrende: Prof. Beispiel") == true)
        XCTAssertEqual(byKey["e\(a)@2026-12-03"]?.title, "Fällt aus: Analysis I")
        let moved = try XCTUnwrap(byKey["e\(p)@2026-11-27"], "verlegt: Kennung des urspruenglichen Tages")
        XCTAssertEqual(moved.start, try at("2026-11-28", "10:00"))
        XCTAssertEqual(byKey["e\(p)@2026-12-04"]?.start, try at("2026-12-04", "08:15"))
        XCTAssertEqual(desired.filter { $0.key.hasPrefix("e") }.count, 4, "\(desired.map(\.key))")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "kalender-durchgehend-\(UUID().uuidString)"))
        let store = EKEventStore()
        let target = try EventKitCalendarStore.open(store: store, defaults: defaults, color: nil)
        defer { try? EventKitCalendarStore.remove(store: store, defaults: defaults) }
        XCTAssertEqual(try CalendarExport.run(target: target, desired: desired, now: now).create.count, desired.count)
        XCTAssertTrue(try CalendarExport.run(target: target, desired: desired, now: now).isEmpty, "zweiter Lauf ohne Aenderung")

        // Aenderungen in der App: heute spaeter, Programmieren ganz geloescht
        _ = try await api.value("/api/timetable/exceptions", method: "POST", body: [
            "event_id": .number(Double(a)), "date": "2026-11-26", "type": "edit", "new_start": "10:30", "new_end": "12:00"])
        _ = try await api.value("/api/timetable/events/\(p)", method: "DELETE")
        let got2 = await CalendarExport.desired(api: api, settings: settings, now: now)
        let after = try XCTUnwrap(got2)
        let c = try CalendarExport.run(target: target, desired: after, now: now)
        XCTAssertEqual(c.update.count, 1, "nur der heutige Termin")
        XCTAssertEqual(c.remove.count, 2, "beide Programmieren-Termine")
        XCTAssertTrue(c.create.isEmpty)
        let inCal = try target.events(from: try at("2026-11-26", "00:00"), to: try at("2026-12-10", "00:00"))
        XCTAssertEqual(inCal.first { $0.key == "e\(a)@2026-11-26" }?.item.start, try at("2026-11-26", "10:30"))
        XCTAssertFalse(inCal.contains { $0.item.title.contains("Programmieren") })

        // Countdown aus derselben Antwort wie die Startseite
        let day = try await api.value("/api/timetable/day?date=2026-11-26")
        let evs = day.list("events")
        let first = try XCTUnwrap(evs.first { $0.s("title") == "Analysis I" })
        XCTAssertEqual(TerminCountdown.label(for: first, in: evs, date: "2026-11-26", now: try at("2026-11-26", "10:05"))?.text, "in 25 Min")
        XCTAssertEqual(TerminCountdown.label(for: first, in: evs, date: "2026-11-26", now: try at("2026-11-26", "11:25"))?.text, "läuft · noch 35 Min")
        let week = try await api.value("/api/timetable/week?start=2026-11-27")
        // Programmieren ist geloescht, der 3.12. faellt aus: als Naechstes kommt Analysis am 10.12. - liegt aber ausserhalb
        // der Woche ab morgen, also keine Zeile
        XCTAssertNil(TerminCountdown.later(week: week, cancelled: []), "Ausfall am 3.12. ist kein besuchter Termin")
    }
}
