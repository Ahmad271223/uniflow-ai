import Foundation
import XCTest
@testable import UniFlowCore

// Erfundene Antworten im Aufbau von users/{id}/courses und users/{id}/schedule (docs/QIS-STUDIP-STRUKTUR.md).

private let coursesJSON = #"""
{"data":[
 {"id":"k-et","type":"courses","attributes":{"title":"Elektrotechnische  Grundlagen","course-number":" 4711 ","course-type":1}},
 {"id":"k-gue","type":"courses","attributes":{"title":"Gruppenübung Mathematik I","course-number":"4712","course-type":3}},
 {"id":"k-mech","type":"courses","attributes":{"title":"Hörsaalübung Technische Mechanik","course-type":"3"}},
 {"id":"k-tut","type":"courses","attributes":{"title":"Tutorium Physik","course-type":7}},
 {"id":"k-erst","type":"courses","attributes":{"title":"Begrüßung der Erstsemester","course-type":7}},
 {"id":"k-db","type":"courses","attributes":{"title":"Datenbanksysteme","course-type":2}},
 {"id":"k-mess","type":"courses","attributes":{"title":"Labor Messtechnik","course-type":4}},
 {"id":"k-math","type":"courses","attributes":{"title":"Mathematik I","course-number":"4700","course-type":1}}
]}
"""#

private func cycle(_ id: String, course: String, weekday: Int, start: String, end: String, description: String = "",
                   recurrence: String = #"{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-12","UNTIL":"2027-01-29"}"#,
                   locations: String = "[]", color: String = "null") -> String {
    #"""
    {"id":"\#(id)","type":"seminar-cycle-dates","attributes":{"title":"Kurszeit","description":"\#(description)",
     "start":"\#(start)","end":"\#(end)","weekday":\#(weekday),"color":\#(color),"recurrence":\#(recurrence),
     "locations":\#(locations)},"relationships":{"owner":{"data":{"type":"courses","id":"\#(course)"}}}}
    """#
}

private let scheduleJSON = "{\"data\":[" + [
    cycle("cy-et-1", course: "k-et", weekday: 1, start: "10:00", end: "11:30",
          recurrence: #"{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-12T10:00:00+02:00","UNTIL":"2027-01-25T11:30:00+01:00","EXDATES":["2026-11-02T10:00:00+01:00"]}"#,
          locations: #"["Hörsaal A (1101 - A001), Musterstraße 1"]"#, color: ##""#ff8800""##),
    cycle("cy-et-2", course: "k-et", weekday: 4, start: "8:15", end: "09:45:00",
          recurrence: #"{"freq":"WEEKLY","interval":"2","dtstart":"20261015T081500","until":"20270128T235959Z","exdates":"20261224,20261112T081500"}"#,
          locations: #"["Raum 012"]"#),
    cycle("cy-gue-1", course: "k-gue", weekday: 2, start: "08:00", end: "09:30"),
    cycle("cy-gue-2", course: "k-gue", weekday: 2, start: "10:00", end: "11:30"),
    cycle("cy-gue-3", course: "k-gue", weekday: 3, start: "16:00", end: "17:30"),
    cycle("cy-mech", course: "k-mech", weekday: 3, start: "12:00", end: "13:30",
          recurrence: #""FREQ=WEEKLY;INTERVAL=1;DTSTART=2026-10-14;UNTIL=2027-01-27""#),
    cycle("cy-tut-1", course: "k-tut", weekday: 5, start: "10:00", end: "11:00"),
    cycle("cy-tut-2", course: "k-tut", weekday: 5, start: "11:00", end: "12:00"),
    cycle("cy-erst", course: "k-erst", weekday: 1, start: "09:00", end: "12:00",
          recurrence: #"{"FREQ":"WEEKLY","INTERVAL":1,"DTSTART":"2026-10-12","UNTIL":"2026-10-12"}"#),
    cycle("cy-db", course: "k-db", weekday: 3, start: "14:00", end: "15:30"),
    cycle("cy-mess", course: "k-mess", weekday: 5, start: "13:00", end: "16:00",
          recurrence: #"{"FREQ":"WEEKLY","INTERVAL":3,"DTSTART":"2026-10-16","UNTIL":"2027-01-29"}"#),
    cycle("cy-math-vl1", course: "k-math", weekday: 1, start: "08:00", end: "09:30"),
    cycle("cy-math-vl2", course: "k-math", weekday: 4, start: "10:00", end: "11:30", description: "Vorlesung"),
    cycle("cy-math-ue1", course: "k-math", weekday: 2, start: "12:00", end: "13:30", description: "Übung Gruppe 1"),
    cycle("cy-math-ue2", course: "k-math", weekday: 2, start: "14:00", end: "15:30", description: "Übung Gruppe 2"),
    cycle("cy-math-ue3", course: "k-math", weekday: 3, start: "08:00", end: "09:30", description: "Übung Gruppe 3"),
    #"""
    {"id":"se-1","type":"schedule-entries","attributes":{"title":"Lerngruppe mit Max Muster","description":"alle 2 Wochen",
     "start":"18:00","end":"19:30","weekday":3,"color":"#00aa00"},"relationships":{"owner":{"data":{"type":"users","id":"u1"}}}}
    """#,
    #"{"id":"x-1","type":"course-events","attributes":{"title":"Sitzung"}}"#,
].joined(separator: ",") + "]}"

private func fixture() throws -> StudIPTimetable {
    StudIPSchedule.timetable(scheduleDocument: try JSONValue.parse(scheduleJSON), coursesDocument: try JSONValue.parse(coursesJSON))
}

private func entry(_ t: StudIPTimetable, _ id: String) -> StudIPScheduleEntry? { t.entries.first { $0.id == id } }

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class StudIPScheduleArtTests: XCTestCase {

    func testTitleRulesLikeClassifyAndGuessKind() {
        let cases: [(String, StudIPScheduleArt, String)] = [
            ("Mathematik I", .vorlesung, "vorlesung"),
            ("Gruppenübung Mathematik I", .gruppenuebung, "uebung"),
            ("Gruppenuebung Analysis", .gruppenuebung, "uebung"),
            ("Hörsaalübung Technische Mechanik", .hoersaaluebung, "uebung"),
            ("Zentralübung Elektrotechnik", .hoersaaluebung, "uebung"),
            ("Übung zu Programmieren", .uebung, "uebung"),
            ("Signale und Systeme - Fragestunde", .uebung, "uebung"),
            ("Mathematikübung", .uebung, "uebung"),                    // classify: kein Wortanfang, guess_kind: "übung"
            ("Ü: Lineare Algebra", .uebung, "uebung"),
            ("Tutorium Physik", .tutorium, "uebung"),
            ("Labor Messtechnik", .labor, "labor"),
            ("Grundlagenpraktikum Chemie", .labor, "labor"),
            ("Proseminar Robotik", .seminar, "seminar"),
            ("Begrüßung der Erstsemester", .sonstiges, "sonstiges"),
            ("Übung für Erstsemester", .sonstiges, "sonstiges"),        // Sonstiges geht vor (wie classify)
        ]
        for (title, art, kind) in cases {
            let a = StudIPSchedule.art(title: title)
            XCTAssertEqual(a, art, title)
            XCTAssertEqual(a.kind, kind, title)
        }
    }

    func testKindMatchesPythonFormula() {
        // studip_entries: "uebung" wenn classify() "uebung" liefert, sonst guess_kind(title)
        for title in ["Mathematik I", "Gruppenübung Mathe", "Hörsaalübung Mechanik", "Tutorium Physik", "Labor Messtechnik",
                      "Seminar Ethik", "Mathematikübung", "Fragestunde Analysis", "Exercise Algorithms", "Kollaboration"] {
            let python = StudIPSchedule.courseArt(title) == .uebung ? "uebung" : StudIPSchedule.guessKind(title)
            XCTAssertEqual(StudIPSchedule.art(title: title).kind, python, title)
        }
    }

    func testCourseTypeOnlyWhenTitleIsNeutral() {
        XCTAssertEqual(StudIPSchedule.art(title: "Datenbanksysteme", courseType: 2), .seminar)
        XCTAssertEqual(StudIPSchedule.art(title: "Datenbanksysteme", courseType: 3), .uebung)
        XCTAssertEqual(StudIPSchedule.art(title: "Datenbanksysteme", courseType: 4), .labor)
        XCTAssertEqual(StudIPSchedule.art(title: "Datenbanksysteme", courseType: 1), .vorlesung)
        XCTAssertEqual(StudIPSchedule.art(title: "Datenbanksysteme", courseType: 35), .vorlesung)
        XCTAssertEqual(StudIPSchedule.art(title: "Tutorium Physik", courseType: 2), .tutorium)
        XCTAssertEqual(StudIPSchedule.art(title: "Datenbanksysteme", courseType: 35, courseTypes: [35: .labor]), .labor)
        XCTAssertEqual(StudIPSchedule.art(title: "Mathematik I", courseType: 1, detail: "Übung Gruppe 2"), .uebung)
        XCTAssertEqual(StudIPSchedule.art(title: "Mathematik I", detail: "Begrüßung"), .vorlesung)
    }
}

final class StudIPScheduleTests: XCTestCase {

    func testCycleFieldsFromRecurrence() throws {
        let t = try fixture()
        let e1 = try XCTUnwrap(entry(t, "cy-et-1"))
        XCTAssertEqual(e1.title, "Elektrotechnische Grundlagen")
        XCTAssertEqual(e1.courseID, "k-et")
        XCTAssertEqual(e1.courseNumber, "4711")
        XCTAssertEqual(e1.weekday, 0)
        XCTAssertEqual(e1.startTime, "10:00")
        XCTAssertEqual(e1.endTime, "11:30")
        XCTAssertEqual(e1.rrule, "weekly")
        XCTAssertEqual(e1.dateFrom, "2026-10-12")
        XCTAssertEqual(e1.dateTo, "2027-01-25")
        XCTAssertEqual(e1.exdates, ["2026-11-02"])
        XCTAssertEqual(e1.room, "Hörsaal A (1101 - A001)")
        XCTAssertEqual(e1.locations, ["Hörsaal A (1101 - A001), Musterstraße 1"])
        XCTAssertEqual(e1.color, "#ff8800")
        XCTAssertEqual(e1.art, .vorlesung)
        XCTAssertTrue(e1.selected)
        XCTAssertFalse(e1.uncertain)
        XCTAssertNil(e1.hint)

        // Kleinbuchstaben-Schluessel, iCalendar-Formate, EXDATES als Text, UNTIL 23:59:59Z = Vortag
        let e2 = try XCTUnwrap(entry(t, "cy-et-2"))
        XCTAssertEqual(e2.weekday, 3)
        XCTAssertEqual(e2.startTime, "08:15")
        XCTAssertEqual(e2.endTime, "09:45")
        XCTAssertEqual(e2.interval, 2)
        XCTAssertEqual(e2.rrule, "biweekly")
        XCTAssertEqual(e2.dateFrom, "2026-10-15")
        XCTAssertEqual(e2.dateTo, "2027-01-28")
        XCTAssertEqual(e2.exdates, ["2026-11-12", "2026-12-24"])
        XCTAssertEqual(e2.groupSlots, 2)
        XCTAssertTrue(e2.selected, "zwei Vorlesungszeiten sind keine Gruppen")

        let mech = try XCTUnwrap(entry(t, "cy-mech"))
        XCTAssertEqual(mech.art, .hoersaaluebung)
        XCTAssertEqual(mech.kind, "uebung")
        XCTAssertEqual(mech.dateFrom, "2026-10-14")
        XCTAssertEqual(mech.dateTo, "2027-01-27")

        XCTAssertEqual(entry(t, "cy-db")?.art, .seminar, "course-type 2, Titel ohne Hinweis")
        XCTAssertEqual(entry(t, "cy-mess")?.art, .labor)
        XCTAssertNil(entry(t, "cy-erst"), "Begrüßung bleibt wie auf dem PC draussen")
        XCTAssertEqual(t.skippedCourseIDs, ["k-erst"])
        XCTAssertNil(entry(t, "x-1"))
    }

    func testUnusualRhythmIsKeptButUncertain() throws {
        let mess = try XCTUnwrap(entry(try fixture(), "cy-mess"))
        XCTAssertEqual(mess.interval, 3)
        XCTAssertEqual(mess.rrule, "weekly")
        XCTAssertTrue(mess.uncertain)
        XCTAssertTrue(mess.selected)
        XCTAssertEqual(mess.hint, "Rhythmus alle 3 Wochen – bitte prüfen")
        let days = mess.occurrences(from: "2026-10-01", to: "2026-11-30").map(\.date)
        XCTAssertEqual(days, ["2026-10-16", "2026-11-06", "2026-11-27"])
    }

    func testParallelGroupsArePendingAndUniqueEntriesSelected() throws {
        let t = try fixture()
        XCTAssertEqual(Set(t.pending.map(\.id)),
                       ["cy-gue-1", "cy-gue-2", "cy-gue-3", "cy-tut-1", "cy-tut-2", "cy-math-ue1", "cy-math-ue2", "cy-math-ue3"])
        for id in ["cy-et-1", "cy-et-2", "cy-mech", "cy-db", "cy-mess", "cy-math-vl1", "cy-math-vl2", "se-1"] {
            XCTAssertEqual(entry(t, id)?.selected, true, id)
        }
        let gue = try XCTUnwrap(entry(t, "cy-gue-1"))
        XCTAssertEqual(gue.groupSlots, 3)
        XCTAssertTrue(gue.uncertain)
        XCTAssertEqual(gue.hint, "3 parallele Gruppen – nur deine Gruppe auswählen")
        XCTAssertEqual(entry(t, "cy-tut-2")?.hint, "2 parallele Gruppen – nur deine Gruppe auswählen")
        XCTAssertEqual(entry(t, "cy-math-ue1")?.art, .uebung, "Beschreibung der Kurszeit zaehlt")
        XCTAssertEqual(entry(t, "cy-math-vl1")?.groupSlots, 2)

        let groups = t.groups
        XCTAssertEqual(groups.map(\.title), ["Gruppenübung Mathematik I", "Mathematik I", "Tutorium Physik"])
        XCTAssertEqual(groups[1].art, .uebung)
        XCTAssertEqual(groups[1].options.map(\.id), ["cy-math-ue1", "cy-math-ue2", "cy-math-ue3"])

        let imported = t.importEntries(choosing: ["cy-math-ue2", "cy-tut-1"])
        XCTAssertEqual(imported.count, t.selected.count + 2)
        let chosen = try XCTUnwrap(imported.first { $0.id == "cy-math-ue2" })
        XCTAssertTrue(chosen.selected)
        XCTAssertFalse(chosen.uncertain)
        XCTAssertNil(chosen.hint)
        XCTAssertFalse(imported.contains { $0.id == "cy-math-ue1" })
    }

    func testEntriesSortedByWeekdayAndStart() throws {
        let t = try fixture()
        let keys = t.entries.map { "\($0.weekday) \($0.startTime)" }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(t.entries.first?.id, "cy-math-vl1")
    }

    func testPersonalEntryLikeStudipEntries() throws {
        let t = try fixture()
        let p = try XCTUnwrap(entry(t, "se-1"))
        XCTAssertTrue(p.isPersonal)
        XCTAssertEqual(p.weekday, 2)
        XCTAssertEqual(p.rrule, "biweekly", "alle 2 Wochen laut Beschreibung")
        XCTAssertNil(p.courseID)
        XCTAssertNil(p.dateFrom)
        XCTAssertEqual(p.kind, "vorlesung")
        XCTAssertEqual(p.hint, "persönlicher Eintrag aus deinem Stud.IP-Stundenplan")
        XCTAssertEqual(t.personal.map(\.id), ["se-1"])
    }

    func testEntryJSONUsesServerFieldNames() throws {
        let t = try fixture()
        let j = try XCTUnwrap(entry(t, "cy-et-2")).json
        let keys = Set(j.object.map { Array($0.keys) } ?? [])
        let server: Set<String> = ["title", "kind", "weekday", "start_time", "end_time", "room", "lecturer", "rrule", "date_from",
                                   "date_to", "module_id", "course_id", "color", "uncertain", "selected", "group_slots"]
        XCTAssertTrue(server.isSubset(of: keys), "fehlt: \(server.subtracting(keys))")
        XCTAssertEqual(j["weekday"], 3)
        XCTAssertEqual(j["start_time"], "08:15")
        XCTAssertEqual(j["rrule"], "biweekly")
        XCTAssertEqual(j["date_from"], "2026-10-15")
        XCTAssertEqual(j["course_id"], "k-et")
        XCTAssertEqual(j["module_id"], .null)
        XCTAssertEqual(j["color"], .null)
        XCTAssertEqual(j["group_slots"], 2)
        XCTAssertEqual(j["exdates"], ["2026-11-12", "2026-12-24"])
        XCTAssertNil(j["personal"])
        XCTAssertNil(j["hint"])

        let p = try XCTUnwrap(entry(t, "se-1")).json
        XCTAssertEqual(p["personal"], true)
        XCTAssertEqual(p["date_from"], .null)
        XCTAssertEqual(p["selected"], true)
        XCTAssertEqual(p["group_slots"], 1)

        let g = try XCTUnwrap(entry(t, "cy-gue-2")).json
        XCTAssertEqual(g["selected"], false)
        XCTAssertEqual(g["uncertain"], true)
        XCTAssertEqual(g["hint"], "3 parallele Gruppen – nur deine Gruppe auswählen")

        // Rundlauf durch den eigenen JSON-Schreiber und -Leser
        XCTAssertEqual(try JSONValue.parse(t.entriesJSON.serialized(sortedKeys: true)), t.entriesJSON)
    }

    func testAutoStatusShape() throws {
        let s = try fixture().autoStatusJSON
        XCTAssertEqual(Set(s.object.map { Array($0.keys) } ?? []), ["pending_groups", "courses", "personal"])
        XCTAssertEqual(s["pending_groups"], 8)
        XCTAssertEqual(s["courses"], ["Gruppenübung Mathematik I", "Mathematik I", "Tutorium Physik"])
        XCTAssertEqual(s["personal"]?.array?.count, 1)
        XCTAssertEqual(s["personal"]?.array?.first?["title"], "Lerngruppe mit Max Muster")
    }

    func testExceptionsJSONAsEventExceptions() throws {
        let ex = try XCTUnwrap(entry(try fixture(), "cy-et-1")).exceptionsJSON
        XCTAssertEqual(ex.count, 1)
        XCTAssertEqual(ex[0]["date"], "2026-11-02")
        XCTAssertEqual(ex[0]["type"], "cancelled")
        XCTAssertEqual(ex[0]["new_date"], .null)
    }

    // MARK: Einzeltermine

    func testWeeklyOccurrencesSkipExdatesAndRespectRange() throws {
        let e = try XCTUnwrap(entry(try fixture(), "cy-et-1"))
        let all = e.occurrences(from: "2026-09-01", to: "2027-03-31")
        XCTAssertEqual(all.count, 15)
        XCTAssertEqual(all.first?.date, "2026-10-12")
        XCTAssertEqual(all.last?.date, "2027-01-25")
        XCTAssertFalse(all.contains { $0.date == "2026-11-02" })
        let withCancelled = e.occurrences(from: "2026-11-01", to: "2026-11-10", includeCancelled: true)
        XCTAssertEqual(withCancelled.map(\.date), ["2026-11-02", "2026-11-09"])
        XCTAssertEqual(withCancelled.map(\.cancelled), [true, false])
        XCTAssertEqual(withCancelled[0].json["status"], "ausfall")
        XCTAssertEqual(withCancelled[0].json["exception"], "cancelled")
        XCTAssertEqual(withCancelled[1].json["status"], "teilnahme")
        XCTAssertEqual(withCancelled[1].json["color"], "#ff8800")
        XCTAssertEqual(withCancelled[1].json["event_id"], "cy-et-1")
        XCTAssertTrue(e.occurrences(from: "2026-11-10", to: "2026-11-01").isEmpty)
        XCTAssertTrue(e.occurrences(from: "kein Datum", to: "2026-11-01").isEmpty)
    }

    func testBiweeklyOccurrencesCountFromFirstDay() throws {
        let e = try XCTUnwrap(entry(try fixture(), "cy-et-2"))
        XCTAssertEqual(e.occurrences(from: "2026-10-01", to: "2027-02-28").map(\.date),
                       ["2026-10-15", "2026-10-29", "2026-11-26", "2026-12-10", "2027-01-07", "2027-01-21"])
        // Abfrage beginnt in einer "freien" Woche: der Rhythmus bleibt am ersten Tag ausgerichtet
        XCTAssertEqual(e.occurrences(from: "2026-10-20", to: "2026-11-05").map(\.date), ["2026-10-29"])
    }

    func testOccurrencesUseBerlinTimeAcrossDaylightSaving() throws {
        let e = try XCTUnwrap(entry(try fixture(), "cy-et-1"))
        let o = e.occurrences(from: "2026-10-19", to: "2026-10-26")
        XCTAssertEqual(o.map(\.date), ["2026-10-19", "2026-10-26"])
        XCTAssertEqual(o[0].start, utc("2026-10-19T08:00:00Z"), "Sommerzeit UTC+2")
        XCTAssertEqual(o[0].end, utc("2026-10-19T09:30:00Z"))
        XCTAssertEqual(o[1].start, utc("2026-10-26T09:00:00Z"), "Winterzeit UTC+1")
    }

    func testPersonalEntryUsesTermWhenNoRange() throws {
        let p = try XCTUnwrap(entry(try fixture(), "se-1"))
        let term = StudIPTerm(start: "2026-10-12", end: "2026-11-15")
        XCTAssertEqual(p.occurrences(from: "2026-10-01", to: "2026-12-31", term: term).map(\.date),
                       ["2026-10-14", "2026-10-28", "2026-11-11"])
        XCTAssertEqual(p.occurrences(from: "2026-10-01", to: "2026-10-31").count, 4, "ohne Semester: Rhythmus nicht verankert")
    }

    func testOccurrencesInDateInterval() throws {
        let e = try XCTUnwrap(entry(try fixture(), "cy-et-1"))
        let i = DateInterval(start: utc("2026-10-19T09:00:00Z"), end: utc("2026-10-26T08:30:00Z"))
        XCTAssertEqual(e.occurrences(in: i).map(\.date), ["2026-10-19"], "laeuft noch um 11:00 Uhr, 26.10. beginnt erst 10:00 Uhr")
    }

    func testCombinedOccurrencesSorted() throws {
        let t = try fixture()
        let o = StudIPSchedule.occurrences(of: t.selected, from: "2026-10-12", to: "2026-10-18")
        XCTAssertEqual(o.first?.entryID, "cy-math-vl1")
        let keys = o.map { "\($0.date) \($0.startTime)" }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(o.contains { $0.entryID == "cy-et-2" && $0.date == "2026-10-15" })
        XCTAssertFalse(o.contains { $0.entryID.hasPrefix("cy-gue") })
    }

    func testOnceWhenStartEqualsEnd() throws {
        let doc: JSONValue = ["data": [[
            "id": "c1", "type": "seminar-cycle-dates",
            "attributes": ["title": "Block", "start": "09:00", "end": "17:00", "weekday": 6,
                           "recurrence": ["DTSTART": "2026-11-14T09:00:00+01:00", "UNTIL": "2026-11-14T17:00:00+01:00"]],
        ]]]
        let t = StudIPSchedule.timetable(scheduleDocument: doc, coursesDocument: ["data": []])
        let e = try XCTUnwrap(t.entries.first)
        XCTAssertEqual(e.weekday, 5, "Stud.IP 6 = Samstag")
        XCTAssertEqual(e.title, "Block", "ohne bekannten Kurs gilt der eigene Titel")
        XCTAssertEqual(e.rrule, "once")
        XCTAssertEqual(e.occurrences(from: "2026-11-01", to: "2026-11-30").map(\.date), ["2026-11-14"])
    }
}

final class StudIPScheduleTimeTests: XCTestCase {

    func testMomentFormats() {
        let d = BerlinClock.parseISODate
        XCTAssertEqual(StudIPSchedule.moment("2026-10-12"), StudIPMoment(day: d("2026-10-12")!, minutes: nil))
        XCTAssertEqual(StudIPSchedule.moment("20261012"), StudIPMoment(day: d("2026-10-12")!, minutes: nil))
        XCTAssertEqual(StudIPSchedule.moment("2026-10-12T10:15:00+02:00"), StudIPMoment(day: d("2026-10-12")!, minutes: 615))
        XCTAssertEqual(StudIPSchedule.moment("2026-10-12T08:15:00.000Z"), StudIPMoment(day: d("2026-10-12")!, minutes: 615))
        XCTAssertEqual(StudIPSchedule.moment("20261012T081500Z"), StudIPMoment(day: d("2026-10-12")!, minutes: 615))
        XCTAssertEqual(StudIPSchedule.moment("20261012T101500"), StudIPMoment(day: d("2026-10-12")!, minutes: 615))
        XCTAssertEqual(StudIPSchedule.moment("2026-12-01 10:15"), StudIPMoment(day: d("2026-12-01")!, minutes: 615))
        XCTAssertEqual(StudIPSchedule.moment("2026-12-23T23:30:00Z"), StudIPMoment(day: d("2026-12-24")!, minutes: 30))
        XCTAssertEqual(StudIPSchedule.moment(.number(1_792_051_200)), StudIPSchedule.moment("2026-10-15T08:00:00Z"))
        XCTAssertEqual(StudIPSchedule.moment("1792051200"), StudIPSchedule.moment("2026-10-15T08:00:00Z"))
        XCTAssertNil(StudIPSchedule.moment("2026-02-30"))
        XCTAssertNil(StudIPSchedule.moment("morgen"))
        XCTAssertNil(StudIPSchedule.moment("2026-10-12T10:15+02:00x"))
    }

    func testRecurrenceAsText() {
        let r = StudIPSchedule.recurrence("FREQ=WEEKLY;INTERVAL=2;DTSTART=20261012;EXDATES=20261026,20261109")
        XCTAssertEqual(r["INTERVAL"], "2")
        XCTAssertEqual(StudIPSchedule.exdates(r["EXDATES"]), ["2026-10-26", "2026-11-09"])
        XCTAssertEqual(StudIPSchedule.rhythm(r).0, 2)
        XCTAssertEqual(StudIPSchedule.rhythm(["FREQ": "DAILY"]).1, "Rhythmus DAILY aus Stud.IP – bitte prüfen")
    }

    func testWeekdayMapping() {
        XCTAssertEqual(StudIPSchedule.studipWeekday(1), 0)
        XCTAssertEqual(StudIPSchedule.studipWeekday("5"), 4)
        XCTAssertEqual(StudIPSchedule.studipWeekday(0), 6)
        XCTAssertEqual(StudIPSchedule.studipWeekday(7), 6)
        XCTAssertNil(StudIPSchedule.studipWeekday(9))
    }

    func testCivilDatesRoundTrip() {
        XCTAssertEqual(BerlinClock.dayNumber(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(BerlinClock.weekday(BerlinClock.parseISODate("2026-10-12")!), 0)
        XCTAssertEqual(BerlinClock.weekday(BerlinClock.parseISODate("2026-10-25")!), 6)
        for n in stride(from: -800, through: 30_000, by: 37) {
            let c = BerlinClock.civil(n)
            XCTAssertEqual(BerlinClock.dayNumber(year: c.year, month: c.month, day: c.day), n)
            XCTAssertEqual(BerlinClock.parseISODate(BerlinClock.isoDate(n)), n)
        }
        XCTAssertEqual(BerlinClock.daysInMonth(year: 2028, month: 2), 29)
        XCTAssertEqual(BerlinClock.daysInMonth(year: 2100, month: 2), 28)
    }

    func testDaylightSavingEdges() {
        // 2027: Beginn 28.03. 01:00 UTC, Ende 31.10. 01:00 UTC
        XCTAssertFalse(BerlinClock.isSummerTime(utc: Int(utc("2027-03-28T00:59:59Z").timeIntervalSince1970)))
        XCTAssertTrue(BerlinClock.isSummerTime(utc: Int(utc("2027-03-28T01:00:00Z").timeIntervalSince1970)))
        XCTAssertTrue(BerlinClock.isSummerTime(utc: Int(utc("2027-10-31T00:59:59Z").timeIntervalSince1970)))
        XCTAssertFalse(BerlinClock.isSummerTime(utc: Int(utc("2027-10-31T01:00:00Z").timeIntervalSince1970)))
        let mar = BerlinClock.parseISODate("2027-03-28")!, oct = BerlinClock.parseISODate("2027-10-31")!
        XCTAssertEqual(BerlinClock.utcSeconds(day: mar, minutes: 150), Int(utc("2027-03-28T01:30:00Z").timeIntervalSince1970), "02:30 gibt es nicht")
        XCTAssertEqual(BerlinClock.utcSeconds(day: oct, minutes: 150), Int(utc("2027-10-31T00:30:00Z").timeIntervalSince1970), "erste 02:30")
        XCTAssertEqual(BerlinClock.utcSeconds(day: oct, minutes: 210), Int(utc("2027-10-31T02:30:00Z").timeIntervalSince1970))
    }

    /// Gegenprobe mit der Zeitzonendatenbank, wo sie vorhanden ist (Apple-Systeme, Linux mit tzdata).
    func testMatchesSystemTimeZoneWhenAvailable() throws {
        guard let tz = TimeZone(identifier: "Europe/Berlin") else { throw XCTSkip("keine Zeitzonendatenbank") }
        var s = Int(utc("2025-01-01T00:30:00Z").timeIntervalSince1970)
        let end = Int(utc("2031-01-01T00:00:00Z").timeIntervalSince1970)
        while s < end {
            XCTAssertEqual(BerlinClock.offset(utc: s), tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s))), "\(s)")
            s += 3 * 3600 + 17 * 60
        }
    }
}

final class StudIPScheduleClientTests: XCTestCase {

    func testClientFetchesScheduleAndCoursesReadOnly() async throws {
        func reply(_ s: String) -> HTTPReply { HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(s.utf8)) }
        let t = StubTransport([
            "/jsonapi.php/v1/users/u1/schedule": reply(scheduleJSON),
            "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester": reply(coursesJSON),
        ])
        let c = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let tt = try await c.timetable(userID: "u1")
        XCTAssertEqual(tt, try fixture())
        XCTAssertEqual(t.requested, ["/jsonapi.php/v1/users/u1/schedule",
                                     "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester"])
    }
}
