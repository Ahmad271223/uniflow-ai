import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Woche am iPhone als Raster (Auftrag des Inhabers 14.11.2026: unter „Woche“ stand eine Tagesliste). Sieben Spalten
/// Montag–Sonntag mit Zeitachse, Blöcke am richtigen Tag und zur richtigen Zeit, Tippen öffnet dasselbe Detail wie in
/// der Tagesansicht, der Spaltenkopf wechselt zu „Tag“. Nichts ragt über den Rand, auch auf dem kleinsten iPhone.
/// Gegenprobe: am iPad bleibt `PlanWeekGrid`. Nur erfundene Daten, kein Netz.
@MainActor
final class IPhoneWeekGridTests: IPhoneLearnTestCase {

    private func event(_ title: String, _ start: String, _ end: String, room: String = "", kind: String = "vorlesung",
                       status: String = "teilnahme", id: Int) -> JSONValue {
        ["event_id": .number(Double(id)), "title": .string(title), "start": .string(start), "end": .string(end),
         "room": .string(room), "kind": .string(kind), "status": .string(status), "color": "#7c3aed"]
    }

    /// Woche 9.–15.11.2026: Mo Vorlesung, Mi zwei Termine (einer nicht besucht) und ein Lernblock, Do ein Paket ohne Uhrzeit
    private func week() -> [JSONValue] {
        let mon = PlanData.monday(Fmt.date("2026-11-09")!)
        return (0..<7).map { i -> JSONValue in
            let date = Fmt.isoDay(PlanData.add(mon, i))
            var events: [JSONValue] = []
            var packages: [JSONValue] = []
            if i == 0 { events = [event("Grundlagen der Informatik – Vorlesung", "10:00", "12:00", room: "Hörsaal A", id: 1)] }
            if i == 2 {
                events = [event("Grundlagen der Informatik – Übung", "14:00", "16:00", room: "Seminarraum 3", kind: "uebung", id: 2),
                          event("Lineare Algebra I für Studierende der Informatik", "08:15", "09:45", room: "Hörsaal F", status: "nicht_teilnahme", id: 3)]
                packages = [["id": 7, "subject": "Grundlagen der Informatik", "title": "Übungsblatt 1", "start_time": "16:30",
                             "end_time": "17:30", "planned_minutes": 60, "status": "geplant", "color": "#16a34a",
                             "tasks": [["status": "erledigt"], ["status": "offen"]]]]
            }
            if i == 1 {
                // Termin aus dem Stud.IP-Kalender (ohne event_id): das Detail ist ein Dialog ohne Nachladen
                events = [["title": "Lerngruppe Analysis", "start": "16:00", "end": "17:30", "room": "Bibliothek",
                           "kind": "persoenlich", "status": "teilnahme", "color": "#0ea5e9"]]
            }
            if i == 3 {
                packages = [["id": 8, "subject": "Lineare Algebra", "title": "Wiederholen", "planned_minutes": 45, "status": "geplant",
                             "color": "#0ea5e9", "tasks": [["status": "offen"]]]]
            }
            return ["date": .string(date), "weekday": .number(Double(i)), "events": .array(events), "packages": .array(packages)]
        }
    }

    private func data() -> PlanData {
        let date = Fmt.date("2026-11-11")!
        return PlanData(view: "week", date: date, start: PlanData.monday(date), end: PlanData.add(PlanData.monday(date), 6),
                        module: "", cal: ["days": .array(week())], open: [], modules: [], month: nil)
    }

    private func grid(size: CGSize = IPhoneLearnTestCase.phone) throws -> HostedEnvironment {
        try hostPhone(ScrollView { PhoneWeekGrid(d: data()).padding(.horizontal, 10) }, api: remote(Canned()), size: size)
    }

    // MARK: Rechnung (reine Funktionen)

    func testGeometryGivesSevenColumnsAndPositions() {
        let col = PhoneWeekGeometry.column(width: 358, days: 7)
        XCTAssertGreaterThan(col, 40, "sieben Spalten passen aufs iPhone: \(col)")
        XCTAssertEqual(PhoneWeekGeometry.axis + 7 * col + 6 * PhoneWeekGeometry.gap, 358, accuracy: 0.01, "füllt die Breite genau")
        // 8–19 Uhr, erweitert um frühere und spätere Einträge (hier 8:15 bzw. 17:30 -> bleibt 8–19)
        let r = PhoneWeekGeometry.range(week())
        XCTAssertEqual(r.lo, 8 * 60)
        XCTAssertEqual(r.hi, 19 * 60)
        XCTAssertEqual(PhoneWeekGeometry.y(9 * 60, lo: 8 * 60), PhoneWeekGeometry.hour, accuracy: 0.01)
        // zwei gleichzeitige Blöcke teilen sich die Spalte
        let whole = PhoneWeekGeometry.block(start: 600, end: 720, lane: PlanLane(lane: 0, n: 1), width: 44, lo: 480)
        let half = PhoneWeekGeometry.block(start: 600, end: 720, lane: PlanLane(lane: 1, n: 2), width: 44, lo: 480)
        XCTAssertEqual(whole.w, 42, accuracy: 0.01)
        XCTAssertLessThan(half.w, whole.w / 2 + 1)
        XCTAssertGreaterThan(half.x, whole.x)
        XCTAssertEqual(whole.y, 2 * PhoneWeekGeometry.hour, accuracy: 0.01, "10 Uhr bei lo = 8 Uhr")
        // sehr kurzer Block: nur Farbe
        XCTAssertFalse(PhoneWeekGeometry.showsText(width: 44, height: 18))
        XCTAssertTrue(PhoneWeekGeometry.showsText(width: 44, height: 46))
    }

    func testEntriesSplitTimedAndUntimed() {
        let days = week()
        XCTAssertEqual(PhoneWeekEntry.timed(days[2]).map(\.id).count, 3, "zwei Termine und ein Lernblock mit Uhrzeit")
        XCTAssertEqual(PhoneWeekEntry.timed(days[2]).first?.start, 8 * 60 + 15, "nach Beginn sortiert")
        XCTAssertTrue(PhoneWeekEntry.untimed(days[2]).isEmpty)
        XCTAssertEqual(PhoneWeekEntry.untimed(days[3]).count, 1, "Paket ohne Uhrzeit")
        XCTAssertTrue(PhoneWeekEntry.timed(days[3]).isEmpty)
    }

    // MARK: Darstellung

    func testSevenColumnsWithBlocksAtTheRightDayAndTime() throws {
        let env = try grid()
        XCTAssertTrue(env.wait { self.element(env, id: "phoneWeekGrid") != nil }, dump(env))
        env.pump(0.5)
        // sieben Spaltenköpfe, Montag bis Sonntag
        let heads = elements(env).filter { (identifier($0) ?? "").hasPrefix("phoneWeek.head.") }
        XCTAssertEqual(heads.count, 7, "sieben Spalten: \(heads.compactMap { identifier($0) })")
        let xs = heads.map { frame($0).minX }
        XCTAssertEqual(xs.sorted(), xs.sorted(), "Köpfe nebeneinander")
        XCTAssertEqual(Set(heads.map { Int(frame($0).minY) }).count, 1, "alle Köpfe auf einer Höhe")
        // Block am richtigen Tag: die Übung am Mittwoch liegt in der dritten Spalte
        let mittwochHead = try XCTUnwrap(element(env, id: "phoneWeek.head.2026-11-11"))
        let uebung = try XCTUnwrap(elements(env).first { ($0.accessibilityLabel ?? "").hasPrefix("Grundlagen der Informatik – Übung") },
                                   dump(env))
        XCTAssertEqual(frame(uebung).midX, frame(mittwochHead).midX, accuracy: frame(mittwochHead).width / 2,
                       "Block in der Spalte seines Tages")
        // und zur richtigen Zeit: 14 Uhr liegt unter 8:15
        let la = try XCTUnwrap(elements(env).first { ($0.accessibilityLabel ?? "").hasPrefix("Lineare Algebra") })
        XCTAssertLessThan(frame(la).minY, frame(uebung).minY, "08:15 über 14:00")
        XCTAssertEqual(frame(uebung).minY - frame(la).minY,
                       CGFloat(14 * 60 - (8 * 60 + 15)) / 60 * PhoneWeekGeometry.hour, accuracy: 3, "Abstand nach Uhrzeit")
        // VoiceOver nennt Titel, Tag und Uhrzeit
        let label = uebung.accessibilityLabel ?? ""
        XCTAssertTrue(label.contains("Mittwoch") && label.contains("14:00 bis 16:00"), label)
        XCTAssertTrue((la.accessibilityLabel ?? "").contains("nicht besucht"), la.accessibilityLabel ?? "")
        // Lernblock und Eintrag ohne Uhrzeit sind da
        XCTAssertNotNil(elements(env).first { ($0.accessibilityLabel ?? "").contains("Lernblock") }, dump(env))
        XCTAssertNotNil(element(env, id: "phoneWeek.untimed"), "Zeile für Einträge ohne Uhrzeit")
        assertFitsOnAllPhones(env, "woche-raster")
        shoot(env, "iphone-woche-raster")
    }

    func testTapOnBlockOpensDetailAndHeadSwitchesToDay() throws {
        let env = try grid()
        XCTAssertTrue(env.wait { self.element(env, id: "phoneWeekGrid") != nil }, dump(env))
        env.pump(0.5)
        // Spaltenkopf: wechselt in die Tagesansicht dieses Tages
        let head = try XCTUnwrap(element(env, id: "phoneWeek.head.2026-11-11"))
        XCTAssertTrue(head.accessibilityActivate())
        XCTAssertTrue(env.wait { env.router.route == .plan(view: "day", date: "2026-11-11", module: nil) },
                      "Tag statt Woche: \(env.router.route)")
        // Block: öffnet dasselbe Detail wie in der Tagesansicht (Blatt des Termins)
        let env2 = try grid()
        XCTAssertTrue(env2.wait { self.element(env2, id: "phoneWeekGrid") != nil })
        env2.pump(0.5)
        let block = try XCTUnwrap(elements(env2).first { ($0.accessibilityLabel ?? "").hasPrefix("Lerngruppe Analysis") },
                                  dump(env2))
        XCTAssertTrue(block.accessibilityActivate())
        XCTAssertTrue(env2.wait(timeout: 10) { self.shows(env2, "Stud.IP-Kalender") },
                      "dasselbe Detail wie in der Tagesansicht: \(dump(env2))")
    }

    func testGridFitsSmallestPhoneAndLargeType() throws {
        for size in [IPhoneLearnTestCase.phoneSmall, IPhoneLearnTestCase.phone, IPhoneLearnTestCase.phoneMax] {
            let env = try grid(size: size)
            XCTAssertTrue(env.wait { self.element(env, id: "phoneWeekGrid") != nil })
            env.pump(0.4)
            let heads = elements(env).filter { (identifier($0) ?? "").hasPrefix("phoneWeek.head.") }
            XCTAssertEqual(heads.count, 7, "sieben Spalten auch bei \(size.width)")
            for e in elements(env) {
                let f = frame(e)
                guard !f.isNull, f.width > 0, let id = identifier(e), id.hasPrefix("phoneWeek") else { continue }
                XCTAssertLessThanOrEqual(f.maxX, size.width + 0.5, "\(id) ragt rechts heraus bei \(size.width)")
                XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(id) ragt links heraus bei \(size.width)")
            }
        }
        let big = try hostPhone(ScrollView { PhoneWeekGrid(d: data()).padding(.horizontal, 10) }
                                    .environment(\.dynamicTypeSize, .accessibility3),
                                api: remote(Canned()), size: IPhoneLearnTestCase.phoneSmall)
        XCTAssertTrue(big.wait { self.element(big, id: "phoneWeekGrid") != nil })
        big.pump(0.4)
        XCTAssertEqual(elements(big).filter { (identifier($0) ?? "").hasPrefix("phoneWeek.head.") }.count, 7,
                       "auch bei sehr großer Schrift sieben Spalten")
        shoot(big, "iphone-woche-raster-grosse-schrift")
    }

    // MARK: Kaputte Zeiten (Foto des Inhabers 14.11.2026: Achse lief bis "26")

    /// Woche mit alten Planer-Daten: Lernpakete 23:15–"25:15" und 23:00–"25:15", dazu ein Termin mit Ende vor Beginn
    private func brokenWeek() -> [JSONValue] {
        let mon = PlanData.monday(Fmt.date("2026-11-09")!)
        return (0..<7).map { i -> JSONValue in
            let date = Fmt.isoDay(PlanData.add(mon, i))
            var events: [JSONValue] = []
            var packages: [JSONValue] = []
            if i == 2 {
                packages = [["id": 11, "subject": "Numerik", "title": "Übungsblatt", "start_time": "23:15", "end_time": "25:15",
                             "planned_minutes": 120, "status": "geplant", "color": "#db2777", "tasks": [["status": "offen"]]]]
            }
            if i == 3 {
                packages = [["id": 12, "subject": "Optik", "title": "Lesen", "start_time": "23:00", "end_time": "25:15",
                             "planned_minutes": 135, "status": "geplant", "color": "#0ea5e9", "tasks": [["status": "offen"]]]]
                events = [event("Verdrehter Termin", "18:00", "17:00", id: 21)]
            }
            return ["date": .string(date), "weekday": .number(Double(i)), "events": .array(events), "packages": .array(packages)]
        }
    }

    /// Zeiten ab 24 Uhr und Ende vor Beginn werden sicher behandelt (UFTime.span)
    func testBrokenTimesStayInsideTheDay() {
        XCTAssertEqual(UFTime.span("23:15", "25:15").start, 23 * 60 + 15)
        XCTAssertEqual(UFTime.span("23:15", "25:15").end, UFTime.dayEnd, "Ende bei 24 Uhr abgeschnitten")
        XCTAssertEqual(UFTime.span("25:00", "26:30").start, UFTime.dayEnd - 5, "Beginn nach Mitternacht bleibt im Tag")
        XCTAssertEqual(UFTime.span("25:00", "26:30").end, UFTime.dayEnd)
        XCTAssertEqual(UFTime.span("18:00", "17:00").end, 18 * 60 + 5, "Ende vor Beginn: wenigstens fünf Minuten")
        XCTAssertEqual(UFTime.span(nil, nil).start, 0)
        XCTAssertEqual(UFTime.clock("-1:00"), 0, "nichts vor 0 Uhr")
    }

    /// Die Achse hört bei 24 Uhr auf, auch wenn Lernpakete "25:15" als Ende haben
    func testAxisNeverGoesPastMidnight() throws {
        let r = PhoneWeekGeometry.range(brokenWeek())
        XCTAssertEqual(r.hi, UFTime.dayEnd, "Achse endet um 24 Uhr")
        XCTAssertEqual(r.lo, 8 * 60, "normaler Bereich beginnt weiter um 8 Uhr")
        let date = Fmt.date("2026-11-11")!
        let d = PlanData(view: "week", date: date, start: PlanData.monday(date), end: PlanData.add(PlanData.monday(date), 6),
                         module: "", cal: ["days": .array(brokenWeek())], open: [], modules: [], month: nil)
        let env = try hostPhone(ScrollView { PhoneWeekGrid(d: d).padding(.horizontal, 10) }, api: remote(Canned()),
                                size: IPhoneLearnTestCase.phoneSmall)
        XCTAssertTrue(env.wait { self.element(env, id: "phoneWeekGrid") != nil }, dump(env))
        env.pump(0.5)
        // kein Block ragt unter das Raster, und keiner ist höher als der sichtbare Tag
        let grid = try XCTUnwrap(element(env, id: "phoneWeekGrid"))
        for e in elements(env) where (identifier(e) ?? "").hasPrefix("phoneWeek.block.") {
            XCTAssertLessThanOrEqual(frame(e).maxY, frame(grid).maxY + 1, "Block ragt unter das Raster: \(identifier(e) ?? "")")
        }
        // VoiceOver nennt keine Uhrzeit nach 24 Uhr
        let late = elements(env).compactMap(\.accessibilityLabel).filter { $0.contains("Numerik") || $0.contains("Optik") }
        XCTAssertFalse(late.isEmpty, dump(env))
        for l in late {
            XCTAssertFalse(l.contains("25:") || l.contains("26:"), "Uhrzeit nach Mitternacht: \(l)")
        }
        shoot(env, "iphone-woche-raster-kaputte-zeiten")
    }

    /// Gegenprobe: am iPad bleibt das bisherige Wochenraster, die iPhone-Fassung erscheint nur schmal
    func testIPadKeepsItsOwnWeekGrid() {
        XCTAssertTrue(PhoneWeekList.applies(width: 402), "iPhone hochkant: eigene Fassung")
        XCTAssertFalse(PhoneWeekList.applies(width: 874), "iPhone quer: Raster wie am iPad")
        UFCompact.phoneLayoutsOverride = false
        defer { UFCompact.phoneLayoutsOverride = true }
        XCTAssertFalse(PhoneWeekList.applies(width: 402), "iPad im schmalen Split View: unverändert")
    }
}
