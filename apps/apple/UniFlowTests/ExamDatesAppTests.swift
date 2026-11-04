import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Klausurtermine immer sichtbar (Frage des Inhabers 04.11.2026): Liste aus allen Quellen ueber das lokale Backend,
/// Karte "Nächste Klausuren" nur mit Klausuren, Klausur-Pin im Kalender immer zuerst (auch an vollen Tagen, Hinweis
/// "Prüfung" desselben Moduls nicht doppelt), Chips der Neuigkeiten mit Pruefungen zuerst, naechste Klausur im
/// Modulkopf. Lokales Backend mit eingefrorener Uhr, nur erfundene Daten.
@MainActor
final class ExamDatesAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-exams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    /// Modul Analysis I mit Stud.IP-Klausurtermin (Art "Klausur", zwei Raeume) und einer Ankuendigung mit vielen Fristen
    /// und der Klausur; Modul Statistik ohne Klausur
    private func seededAPI() async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let backend = try await host.backend()
        let ann = Announcements.make(id: "sp-news-k1", source: "studip", courseID: "c-ana", title: "Organisatorisches",
                                     bodyHTML: "<p>Abgabe Blatt 3 bis zum 10.11.</p><p>Abgabe Blatt 4 bis zum 17.11.</p><p>Abgabe Blatt 5 bis zum 24.11.</p>"
                                         + "<p>Die Klausur findet am 12.02.2027 um 9 Uhr im Hörsaal F 303 statt.</p>",
                                     author: "", postedAt: "2026-11-03T09:00:00+01:00", url: "https://studip.example/course", today: 20761)
        try await backend.context.database.transaction { c in
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Analysis I', '#4f5bd5', 't'), (2, 'Statistik', '#c2255c', 't')")
            _ = try c.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES ('c-ana', 'Analysis I', 'vorlesung', 1, 1, 't')")
            for (id, room) in [("e1", "Hörsaal F 303"), ("e2", "Hörsaal F 102")] {
                _ = try c.execute("""
                    INSERT INTO studip_events(id, course_id, title, start, end, room, description, cancelled, category, fetched_at)
                    VALUES (?, 'c-ana', 'Klausur', '2027-02-12T09:00:00', '2027-02-12T11:00:00', ?, '', 0, 'Klausur', 't')
                    """, [.text(id), .text(room)])
            }
            _ = try Announcements.store(c, [ann], source: "studip", fetchedAt: "t", courseIDs: ["c-ana"])
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    /// Ueber den Weg der App: eine Klausur je Modul und Tag mit Raeumen und beiden Quellen; Klausurtermin am Modul gefuellt
    func testUpcomingExamsThroughTheAppClient() throws {
        let (items, module) = try awaiting { () -> ([JSONValue], JSONValue) in
            let api = try await self.seededAPI()
            let items = await UFExam.load(api)
            let module = try await api.value("/api/modules/1")
            return (items, module)
        }
        XCTAssertEqual(items.count, 1)
        let e = try XCTUnwrap(items.first)
        XCTAssertEqual(e.s("title"), "Klausur Analysis I")
        XCTAssertEqual(e.s("room"), "Hörsaal F 303 · Hörsaal F 102")
        XCTAssertEqual(e.s("source_label"), "aus Stud.IP-Terminen · aus Ankündigung vom 03.11.2026")
        XCTAssertEqual(UFExam.countdown(e), "in 100 Tagen")
        XCTAssertEqual(UFExam.dateText(e), "Fr., 12.02.2027")
        XCTAssertEqual(UFExam.placeText(e), "09:00–11:00 Uhr · Hörsaal F 303 · Hörsaal F 102")
        XCTAssertEqual(ModuleNextExam.text(e), "Klausur: Fr., 12.02.2027 · in 100 Tagen · 09:00–11:00 Uhr · Hörsaal F 303 · Hörsaal F 102")
        XCTAssertEqual(module["module"]?.s("exam_date"), "2027-02-12", "leerer Klausurtermin aus Stud.IP gefuellt")
    }

    /// Chips der Neuigkeiten: die Klausur steht vor den drei Fristen (Grenze von zwei gilt nur fuer die anderen)
    func testNewsChipsShowExamFirst() throws {
        let items = try awaiting { try await self.seededAPI().value("/api/news") }.list("items")
        let chips = try XCTUnwrap(items.first).list("chips").compactMap { $0.s("label") }
        XCTAssertEqual(chips, ["Prüfung 12.02.", "Frist 10.11.", "Frist 17.11."])
    }

    /// Karte nur mit Klausuren: ohne Liste kein Bild, mit Liste eine Karte; mehr als vier: "und n weitere"
    func testCardOnlyWhenThereAreExams() throws {
        let empty = ImageRenderer(content: UpcomingExamsList(items: [], open: { _ in }).frame(width: 600))
        XCTAssertTrue(empty.uiImage == nil || (empty.uiImage?.size.height ?? 0) < 1, "ohne Klausuren keine Karte")
        let items: [JSONValue] = (1...6).map { i in
            ["id": .string("exam-m\(i)-2027-02-1\(i)"), "date": .string("2027-02-1\(i)"), "time": "09:00", "end": .null,
             "title": .string("Klausur Modul \(i)"), "kind_label": "Klausur", "in_days": .string("in \(99 + i) Tagen"),
             "room": .null, "source_label": "aus Stud.IP-Terminen", "module_id": .number(Double(i))]
        }
        let r = ImageRenderer(content: UpcomingExamsList.card(items, open: { _ in }).frame(width: 600))
        r.scale = 1
        let img = try XCTUnwrap(r.uiImage)
        XCTAssertGreaterThan(img.size.height, 200)
        let one = ImageRenderer(content: UpcomingExamsList.card(Array(items.prefix(1)), open: { _ in }).frame(width: 600))
        one.scale = 1
        XCTAssertLessThan(one.uiImage?.size.height ?? 0, img.size.height, "eine Klausur: kleinere Karte")
    }

    /// Kalendertag mit vielen Hinweisen: der Klausur-Pin steht immer zuerst, der Hinweis "Prüfung" desselben Moduls
    /// nicht noch einmal, alle anderen bleiben; Tage ohne Klausur unveraendert
    func testCalendarPinIsFirstAndAlwaysShown() throws {
        let exam: JSONValue = ["id": "exam-m1-2027-02-12", "date": "2027-02-12", "time": "09:00", "title": "Klausur Analysis I",
                               "kind_label": "Klausur", "module_id": 1, "course_id": "c-ana", "room": "Hörsaal F 303",
                               "source_label": "aus Stud.IP-Terminen", "sources": [["kind": "studip", "label": "aus Stud.IP-Terminen", "url": .null]]]
        let deadlines: [JSONValue] = (1...5).map { ["id": .string("lw-\($0)"), "kind": "abgabe", "kind_label": "Abgabe", "title": .string("Blatt \($0)")] }
        let notices: [JSONValue] = [
            ["announcement_id": "a1", "kind": "pruefung", "title": "Klausur", "module_id": 1, "course_id": "c-ana"],
            ["announcement_id": "a2", "kind": "raum", "title": "Raumänderung", "module_id": 2],
            ["announcement_id": "a3", "kind": "pruefung", "title": "Klausur Statistik", "module_id": 2],
        ]
        let cal: JSONValue = ["days": [
            ["date": "2027-02-11", "events": []],
            ["date": "2027-02-12", "marks": [["kind": "vorlesungsfrei", "label": "Vorlesungsfreie Zeit"]], "deadlines": .array(deadlines),
             "notices": .array(notices)],
        ]]
        let attached = UFExam.attach(cal, [exam])
        let days = attached.list("days")
        XCTAssertNil(days[0]["exams"], "Tag ohne Klausur unveraendert")
        XCTAssertEqual(days[1].list("exams").count, 1)
        let hints = UFHint.all(days[1])
        XCTAssertEqual(hints.first?.category, .exam, "Klausur zuerst")
        XCTAssertEqual(hints.first?.title, "Klausur Analysis I")
        XCTAssertEqual(hints.first?.source, "aus Stud.IP-Terminen")
        XCTAssertEqual(hints.count, 1 + 1 + 5 + 2, "Pin, Markierung, fuenf Fristen, zwei Hinweise (Pruefung desselben Moduls nicht doppelt)")
        XCTAssertFalse(hints.contains { $0.category == .notice && $0.moduleID == 1 })
        XCTAssertTrue(hints.contains { $0.category == .notice && $0.title == "Klausur Statistik" }, "anderes Modul bleibt")
        XCTAssertTrue(UFDayExtras.hasAny(["date": "2027-02-12", "exams": [exam]]), "Tag nur mit Klausur hat Hinweise")
        XCTAssertEqual(UFDayExtraChips.text(try XCTUnwrap(hints.first), compact: true), "09:00 Klausur")
        XCTAssertEqual(UFExam.attach(cal, []), cal, "ohne Klausuren unveraendert")
    }

    /// Das Detail eines Klausur-Pins baut sich auf (Umgebung wie in der App)
    func testExamHintDialogRenders() throws {
        let exam: JSONValue = ["id": "exam-m1-2027-02-12", "date": "2027-02-12", "time": "09:00", "title": "Klausur Analysis I",
                               "kind_label": "Klausur", "module_id": 1, "room": "Hörsaal F 303", "source_label": "aus Stud.IP-Terminen",
                               "sources": [["kind": "ankuendigung", "label": "aus Ankündigung vom 03.11.2026", "url": "https://studip.example/course"]]]
        let h = UFHint.exam(exam, date: "2027-02-12")
        XCTAssertEqual(h.snippet, "Raum: Hörsaal F 303")
        XCTAssertEqual(h.url?.absoluteString, "https://studip.example/course")
        let view = UFHintDialog(hint: h)
            .environmentObject(Session(local: .local(.unavailable)))
            .environmentObject(UFOverlay())
            .environmentObject(UFToastCenter())
            .environmentObject(UFRouter())
            .frame(width: 620)
        let r = ImageRenderer(content: view)
        r.scale = 1
        XCTAssertGreaterThan(try XCTUnwrap(r.uiImage).size.height, 150)
    }
}
