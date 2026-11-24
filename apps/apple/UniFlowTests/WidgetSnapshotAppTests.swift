import SwiftUI
import UniFlowCore
import WidgetKit
import XCTest
@testable import UniFlow

/// Widgets (docs/WIDGETS-2026-11-23.md): Schnappschuss aus den Antworten der Datenquelle (`HomeWidgetSync`), Lesen und
/// Schreiben (`HomeWidgetStore`), Auswahl im Widget (`HomeWidgetData`) und Bilder jeder Groesse mit Beispieldaten
/// (`NextEventView`, `MensaWidgetView` aus StudiNowWidgets/WidgetViews.swift). Die Bilder landen in
/// $UF_WIDGET_SHOT_DIR (Testlauf mit TEST_RUNNER_UF_WIDGET_SHOT_DIR=…), sonst im Temp-Ordner.
@MainActor
final class WidgetSnapshotAppTests: XCTestCase {
    private func ev(_ id: Int, _ date: String, _ title: String, _ start: String, _ end: String, status: String = "teilnahme", room: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["event_id": .number(Double(id)), "date": .string(date), "title": .string(title), "start": .string(start),
                                      "end": .string(end), "status": .string(status), "color": "#4f5bd5", "kind": "vorlesung"]
        if let room { o["room"] = .string(room) }
        return .object(o)
    }

    func testEventsSkipCancelledSkippedAndDuplicates() {
        let week: JSONValue = ["days": .array([
            ["date": "2026-11-22", "events": .array([ev(1, "2026-11-22", "Gestern", "10:00", "11:00")])],
            ["date": "2026-11-23", "events": .array([
                ev(2, "2026-11-23", "Analysis I", "10:15", "11:45", room: " F 102 "),
                ev(3, "2026-11-23", "Abgesagt", "12:00", "13:00", status: "ausfall"),
                ev(4, "2026-11-23", "Nicht besucht", "12:00", "13:00", status: "nicht_teilnahme"),
                ev(5, "2026-11-23", "Ausfall laut Stud.IP", "14:00", "15:00", status: "ausfall"),
                ev(6, "2026-11-23", "Analysis I", "10:15", "11:45"),              // doppelt (zweite Quelle)
            ])],
            ["date": "2026-11-24", "events": .array([ev(7, "2026-11-24", "Programmieren", "08:00", "07:00", room: "")])],
        ])]
        let cancelled = StudIPCancellations.keys(.array([["event_id": .number(5), "date": "2026-11-23"]]))
        let out = HomeWidgetSync.events(weeks: [week], cancelled: cancelled, from: "2026-11-23", to: "2026-11-24")
        XCTAssertEqual(out.map(\.title), ["Analysis I", "Programmieren"])
        XCTAssertEqual(out[0].room, "F 102")
        XCTAssertNil(out[1].room, "leerer Raum faellt weg")
        XCTAssertEqual(out[1].end.timeIntervalSince(out[1].start), 90 * 60, "Ende vor Beginn: 90 Minuten")
        XCTAssertEqual(WUI.time(out[0].start), "10:15", "Uhrzeit in Berlin")
    }

    func testMensaDaySwitchesAtThreePM() throws {
        let data = HomeWidgetData(createdAt: Date(), events: [], eventsUntil: Date(), mensa: .init(canteen: "Hauptmensa", days: [
            .init(date: "2026-11-23", status: "open", meals: [.init(name: "A", category: nil, price: nil, vegan: false, vegetarian: false)]),
            .init(date: "2026-11-24", status: "open", meals: [.init(name: "B", category: nil, price: nil, vegan: true, vegetarian: true)]),
        ]))
        let noon = try XCTUnwrap(HomeWidgetClock.date(day: "2026-11-23", time: "12:00"))
        let late = try XCTUnwrap(HomeWidgetClock.date(day: "2026-11-23", time: "15:30"))
        XCTAssertEqual(data.mensaDay(at: noon)?.day.date, "2026-11-23")
        XCTAssertEqual(data.mensaDay(at: noon)?.isToday, true)
        XCTAssertEqual(data.mensaDay(at: late)?.day.date, "2026-11-24")
        XCTAssertEqual(data.mensaDay(at: late)?.isToday, false)
    }

    func testMensaUsesFilterAndRole() {
        var prefs = MensaPrefs()
        prefs.vegan = true
        prefs.role = "guest"
        let menu: JSONValue = ["days": .array([["date": "2026-11-23", "status": "open", "meals": .array([
            ["name": "Schnitzel", "labels": .array(["schwein"]), "prices": ["student": .number(3.2), "guest": .number(5.1)]],
            ["name": "Curry", "labels": .array(["vegan"]), "prices": ["student": .number(2.9), "guest": .number(4.5)]],
        ])]])]
        let m = HomeWidgetSync.mensa(menu: menu, name: "Hauptmensa", prefs: prefs)
        XCTAssertEqual(m.days.first?.meals.map(\.name), ["Curry"])
        XCTAssertEqual(m.days.first?.meals.first?.vegan, true)
        XCTAssertEqual(m.days.first?.meals.first?.price, MensaUI.price(Mensa.price(menu.list("days")[0].list("meals")[1], role: "guest")))
    }

    func testStoreRoundTripAndClear() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)/home-widget.json")
        let now = Date(timeIntervalSince1970: 1_795_400_000)
        let data = HomeWidgetData.sample(now: now)
        XCTAssertTrue(HomeWidgetStore.save(data, to: url))
        XCTAssertEqual(HomeWidgetStore.load(from: url), data)
        var same = data
        same.createdAt = now.addingTimeInterval(60)
        XCTAssertFalse(HomeWidgetStore.save(same, to: url), "nur neue Zeit: kein Neuladen der Widgets")
        XCTAssertTrue(HomeWidgetStore.clear(at: url))
        XCTAssertNil(HomeWidgetStore.load(from: url))
        XCTAssertFalse(HomeWidgetStore.clear(at: url))
        XCTAssertFalse(HomeWidgetStore.save(data, to: nil), "ohne App-Gruppe nichts schreiben")
    }

    // MARK: Bilder

    private var shotDir: URL {
        let env = ProcessInfo.processInfo.environment["UF_WIDGET_SHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let dir = env ?? FileManager.default.temporaryDirectory.appendingPathComponent("widget-shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Groessen eines iPhone 17 Pro (402 pt breit) in Punkten
    private let sizes: [(WidgetFamily, String, CGSize)] = [
        (.systemSmall, "klein", CGSize(width: 170, height: 170)),
        (.systemMedium, "mittel", CGSize(width: 364, height: 170)),
        (.systemLarge, "gross", CGSize(width: 364, height: 382)),
        (.accessoryRectangular, "sperr-rechteck", CGSize(width: 172, height: 76)),
        (.accessoryCircular, "sperr-rund", CGSize(width: 76, height: 76)),
        (.accessoryInline, "sperr-zeile", CGSize(width: 250, height: 22)),
    ]

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

    func testRenderEveryFamily() throws {
        let now = try XCTUnwrap(HomeWidgetClock.date(day: "2026-11-23", time: "10:30"))
        var data = HomeWidgetData.sample(now: now)
        // ein laufender, zwei spaetere heute, einer morgen
        data.events = [
            .init(title: "Analysis I", room: "F 102", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(4500), color: "#4f5bd5", kind: "vorlesung"),
            .init(title: "Lineare Algebra – Übung", room: "B 305", start: now.addingTimeInterval(5400), end: now.addingTimeInterval(10_800), color: "#d9822b", kind: "uebung"),
            .init(title: "Grundlagen der Informatik – Tutorium", room: nil, start: now.addingTimeInterval(16_200), end: now.addingTimeInterval(21_600), color: "#7c3aed", kind: "tutorium"),
            .init(title: "Programmieren", room: "Audimax", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(91_800), color: "#2f8a4b", kind: "vorlesung"),
        ]
        let soon = now.addingTimeInterval(-1800)                        // 10:00: Analysis beginnt in 15 Min.
        for dark in [false, true] {
            for (fam, label, size) in sizes {
                try render(NextEventView(entry: .init(date: now, data: data), familyOverride: fam), family: fam, size: size, dark: dark, name: "termin-laeuft-\(label)")
                try render(NextEventView(entry: .init(date: soon, data: data), familyOverride: fam), family: fam, size: size, dark: dark, name: "termin-bald-\(label)")
                if fam != .accessoryCircular, fam != .accessoryInline {
                    try render(MensaWidgetView(entry: .init(date: now, data: data), familyOverride: fam), family: fam, size: size, dark: dark, name: "mensa-\(label)")
                }
            }
            try render(NextEventView(entry: .init(date: now, data: nil), familyOverride: .systemSmall), family: .systemSmall,
                       size: sizes[0].2, dark: dark, name: "termin-leer-klein")
            try render(MensaWidgetView(entry: .init(date: now, data: nil), familyOverride: .systemMedium), family: .systemMedium,
                       size: sizes[1].2, dark: dark, name: "mensa-leer-mittel")
        }
        print("Widget-Bilder: \(shotDir.path)")
    }
}
