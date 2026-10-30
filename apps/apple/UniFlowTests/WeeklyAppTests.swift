import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// "Vorlesung bis hier" und gemeinsame Wochentests auf dem iPad (views-weekly.js): dieselben Anfragen wie die
/// Ansichten gegen das lokale Backend, die Box auf der Modulseite, der Dialog im Dokument, der Takt im Vordergrund.
/// Seed aus `LocalModulesAppTests.seededAPI` (VL01.pdf im Fach "Testmathematik I") mit gespeicherten Seitentexten.
extension LocalModulesAppTests {

    /// Seitentexte von VL01.pdf wie nach dem Lesen der PDF (gleiche Aenderungszeit wie die Datei)
    private func withPageTexts(_ api: APIClient) async throws -> Int {
        let pages = ["Einfuehrung Folgen und Reihen", "Grenzwerte von Folgen Konvergenz", "Rechenregeln fuer Grenzwerte",
                     "Monotone Folgen Satz von Bolzano Weierstrass", "Reihen Konvergenzkriterien"]
        let mods = try await api.value("/api/modules").items                // legt die Module an
        let id = try XCTUnwrap(mods.first?.i("id"))
        try await seedPages(api, pages: pages, chdate: ts("2026-10-13T10:00"))
        return id
    }

    /// Schreibt die Seitentexte ueber die Datenbank des Backends hinter `api` (Transport des Seeds)
    private func seedPages(_ api: APIClient, pages: [String], chdate: SQLiteValue) async throws {
        guard let recorder = api.transport as? RecordingTransport else { throw XCTSkip("kein lokaler Transport") }
        let backend = try await recorder.inner.host.backend()
        try await backend.context.database.transaction { c in
            for (i, t) in pages.enumerated() {
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES ('f-1', ?, ?, ?, ?)",
                              [.integer(Int64(i + 1)), .text(t), chdate, .text(t.lowercased())])
            }
        }
    }

    // MARK: Ablauf wie die Ansichten

    func testLectureMarkerFlowLikeTheViews() async throws {
        let (api, _) = try await seededAPI()
        let moduleID = try await withPageTexts(api)

        // Dialog oeffnet: Vorschau zur angezeigten Seite 3
        let pv = try await api.value("/api/markers/preview?file_id=f-1&page=3")
        XCTAssertEqual(pv.i("page"), 3)
        XCTAssertEqual(pv.i("page_count"), 5)
        XCTAssertEqual(pv.list("range").compactMap(\.int), [1, 3])
        XCTAssertEqual(pv["existing"]?.isNull, true)
        XCTAssertFalse(WeeklyText.lecture(pv).isEmpty)
        XCTAssertTrue(WeeklyText.publish(pv).detail.contains("h nach Vorlesungsende"), WeeklyText.publish(pv).detail)

        // "Bis Seite 3 markieren" (LectureMarkerSheet.save)
        let day = try XCTUnwrap(pv.s("lecture_date"))
        _ = try await api.value("/api/markers", method: "POST", body: ["file_id": "f-1", "page": 3, "page_key": "p3",
                                                                       "lecture_date": .string(day), "topic": "Grenzwerte"])
        let markers = LectureMarkers()
        await markers.refresh(api: api, fileID: "f-1")
        XCTAssertEqual(markers.marks.count, 1)
        XCTAssertNotNil(markers.mark(pdfPage: 3), "Kennzeichen \"bis hier\" an Seite 3")
        XCTAssertNil(markers.mark(pdfPage: 2))
        XCTAssertNil(markers.mark(pdfPage: nil), "eingefuegte Seiten tragen keinen Marker")
        XCTAssertFalse(markers.needsReview)
        XCTAssertEqual(markers.marks.first?.s("topic"), "Grenzwerte")
        XCTAssertEqual(WeeklyText.range(try XCTUnwrap(markers.marks.first)), "S. 1–3")

        // erneut auf Seite 3: "Änderungen speichern" (vorhandener Marker)
        let again = try await api.value("/api/markers/preview?file_id=f-1&page=3")
        XCTAssertEqual(again["existing"]?.isNull, false)
        // auf die aktuelle Seite 4 verschieben ("→ S. 4")
        let mid = try XCTUnwrap(markers.marks.first?.i("id"))
        _ = try await api.value("/api/markers/\(mid)", method: "PATCH", body: ["page": 4, "page_key": "p4"])
        await markers.refresh(api: api, fileID: "f-1")
        XCTAssertNotNil(markers.mark(pdfPage: 4))
        XCTAssertNil(markers.mark(pdfPage: 3))

        // Box der Modulseite: Woche mit Marker, noch kein Plan
        let d = try await api.value("/api/weekly/module/\(moduleID)")
        XCTAssertTrue(d.list("weeks").contains { !$0.list("markers").isEmpty }, d.jsonString())
        XCTAssertTrue(d.list("needs_review").isEmpty)

        // Einstellungen speichern wie WeeklySettingsDialog.save
        _ = try await api.value("/api/settings", method: "PUT", body: ["weekly_publish_hours": "48"])
        _ = try await api.value("/api/modules/\(moduleID)", method: "PATCH",
                                body: ["expected_materials": ["gruppenuebung"], "exam_reuse": "original"])
        let overview = try await api.value("/api/weekly/module/\(moduleID)")
        let s = try XCTUnwrap(overview["settings"])
        XCTAssertEqual(WeeklyText.number(s.n("publish_hours")), "48")
        XCTAssertEqual(s.list("expected_materials").compactMap(\.string), ["gruppenuebung"])
        XCTAssertEqual(s.s("exam_reuse"), "original")

        // fuer den Kurs freigeben: zusaetzlicher Kursmarker, der eigene bleibt (Liste im Dialog: nur eigene)
        _ = try await api.value("/api/markers/\(mid)/release", method: "POST", body: ["confirm": true])
        await markers.refresh(api: api, fileID: "f-1")
        XCTAssertEqual(markers.marks.count, 2)
        XCTAssertEqual(markers.marks.filter { $0.s("scope") == "personal" }.count, 1)

        // loeschen
        _ = try await api.value("/api/markers/\(mid)", method: "DELETE")
        await markers.refresh(api: api, fileID: "f-1")
        XCTAssertEqual(markers.marks.filter { $0.s("scope") == "personal" }.count, 0)

        // Probeklausur ohne markierten Stoff im Modul: Meldung sofort (400), kein Hintergrundauftrag
        let (api2, _) = try await seededAPI()
        let list2 = try await api2.value("/api/modules").items
        let other = try XCTUnwrap(list2.first?.i("id"))
        do {
            _ = try await api2.value("/api/weekly/mock-exam", method: "POST", body: ["module_id": .number(Double(other)), "full": false])
            XCTFail("ohne Marker keine Probeklausur")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Noch kein Vorlesungsstoff markiert"), error.localizedDescription)
        }
    }

    // MARK: Seiten im Fenster

    func testWeeklyBoxOnModulePage() async throws {
        let (api, recorder) = try await seededAPI()
        let id = try await withPageTexts(api)
        let pv = try await api.value("/api/markers/preview?file_id=f-1&page=2")
        _ = try await api.value("/api/markers", method: "POST", body: ["file_id": "f-1", "page": 2, "lecture_date": .string(pv.s("lecture_date") ?? "")])

        // lokal ohne KI: weder Box noch Ankuendigung (wie der Modul-Dialog)
        let local = try await render(ModulePage(id: id), api: api, recorder: recorder) { calls in calls.contains { $0.path == "/api/modules/\(id)" } }
        XCTAssertFalse(shows(local, "Lernfortschritt & Wochentests"), local.joined(separator: "\n"))
        XCTAssertFalse(recorder.calls.contains { $0.path.hasPrefix("/api/weekly/") }, "\(recorder.calls)")

        // eigener Server (dieselbe lokale Weiche): Box mit der markierten Woche
        let server = APIClient(base: URL(string: "http://pc-server.invalid/")!, transport: recorder)
        let shown = try await render(ModulePage(id: id), api: server, recorder: recorder) { calls in
            calls.contains { $0.path == "/api/weekly/module/\(id)" }
        }
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(recorder.calls.contains { $0.path == "/api/weekly/module/\(id)" && $0.status == 200 }, "\(recorder.calls)")
        for text in ["Lernfortschritt & Wochentests", "Probeklausur", "Marker gesetzt", "Ein gemeinsamer Test pro Lehrwoche"] {
            XCTAssertTrue(shows(shown, text), "\(text): \(all)")
        }
    }

    func testLectureMarkerSheetShowsPreview() async throws {
        let (api, recorder) = try await seededAPI()
        _ = try await withPageTexts(api)
        let sheet = LectureMarkerSheet(api: api, fileID: "f-1", page: 3, pageKey: "p3", markers: LectureMarkers(), goTo: { _ in }, done: { _ in })
        let shown = try await render(sheet, api: api, recorder: recorder) { calls in calls.contains { $0.path == "/api/markers/preview" } }
        let all = shown.joined(separator: "\n")
        XCTAssertTrue(recorder.calls.contains { $0.path == "/api/markers/preview" && $0.status == 200 }, "\(recorder.calls)")
        for text in ["Bis Seite 3 als behandelt markieren?", "Folie 3 von 5", "Erfasster Seitenbereich", "Seite 1–3", "Bis Seite 3 markieren"] {
            XCTAssertTrue(shows(shown, text), "\(text): \(all)")
        }
    }

    // MARK: Regeln ohne Fenster

    func testLectureMarkerButtonRule() {
        func file(module: Int? = 1, course: String? = "k-a-v", kind: String = "pdf", downloaded: String? = "2026-10-13") -> LibFile {
            LibFile(id: "f", name: "VL.pdf", title: nil, kind: kind, module_id: module, subject: nil, doc_type: "vorlesung", ai_title: nil,
                    sub_label: nil, downloaded_at: downloaded, has_notes: nil, page_count: nil, studip_folder: nil, course_id: course)
        }
        XCTAssertTrue(DocumentView.offersLectureMarker(file(), readOnly: false, local: true, ai: true))
        XCTAssertFalse(DocumentView.offersLectureMarker(file(), readOnly: false, local: true, ai: false), "lokal ohne KI nicht angekuendigt")
        XCTAssertTrue(DocumentView.offersLectureMarker(file(), readOnly: false, local: false, ai: false), "PC-Server hat die KI")
        XCTAssertFalse(DocumentView.offersLectureMarker(file(course: "__user__"), readOnly: false, local: false, ai: true), "eigener Upload")
        XCTAssertFalse(DocumentView.offersLectureMarker(file(module: nil), readOnly: false, local: false, ai: true), "ohne Modul")
        XCTAssertFalse(DocumentView.offersLectureMarker(file(kind: "notebook"), readOnly: false, local: false, ai: true), "Notizbuch")
        XCTAssertFalse(DocumentView.offersLectureMarker(file(downloaded: nil), readOnly: false, local: false, ai: true), "nicht geladen")
        XCTAssertFalse(DocumentView.offersLectureMarker(file(), readOnly: true, local: false, ai: true), "alte Fassung")
        // course_id kommt aus der Bibliothek (Decodable)
        let decoded = try? JSONDecoder().decode(LibFile.self, from: Data(#"{"id":"x","name":"a.pdf","course_id":"__user__"}"#.utf8))
        XCTAssertEqual(decoded?.course_id, "__user__")
    }

    func testWeeklyTexts() {
        let w = WeeklyText.when("2026-10-21T13:05:00")
        XCTAssertTrue(w.contains("21.10.") && w.contains("13:05") && w.hasPrefix("Mi"), w)
        XCTAssertEqual(WeeklyText.when(nil), "–")
        XCTAssertEqual(WeeklyText.when(""), "–")
        XCTAssertEqual(WeeklyText.pct(["submitted_at": "x", "score": 7, "max_score": 10]), 70)
        XCTAssertNil(WeeklyText.pct(["score": 7, "max_score": 10]), "nicht abgegeben")
        XCTAssertNil(WeeklyText.pct(["submitted_at": "x", "score": 0, "max_score": 0]))
        XCTAssertEqual(WeeklyText.number(24.0), "24")
        XCTAssertEqual(WeeklyText.number(nil), "–")
        XCTAssertEqual(WeeklyText.source("gruppenuebung"), "Gruppenübung")
        XCTAssertEqual(WeeklyText.source("neu"), "neu")
        let noLecture = WeeklyText.lecture(["lecture": .null])
        XCTAssertEqual(noLecture, "kein Termin im Stundenplan – Ende wird geschätzt")
        XCTAssertEqual(WeeklyText.lecture(["lecture": ["start": "10:00", "end": "11:30", "room": "F 102"]]), "10:00–11:30 · F 102 (Stundenplan)")
    }

    // MARK: Lernplan nach dem Abgleich

    /// Nach einem Abgleich plant das iPad die laufende Woche wie der PC (`study.auto_plan_week`, Regel vom 30.10.2026):
    /// nur der Stoff dieser Lehrwoche (VL06), nicht die offenen Vorlesungen frueherer Wochen; mit auto_plan = 0 nichts
    func testAutoPlanAfterSyncPlansOnlyTheCurrentWeek() async throws {
        let (api, recorder) = try await seededAPI()                  // Freitag, 20.11.2026 = Lehrwoche 6
        let backend = try await recorder.inner.host.backend()
        let tuesday = ts("2026-11-17T10:00"), wednesday = ts("2026-11-18T10:00")
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES ('f-11', 'k-a-v', 'VL06.pdf', 'Vorlesung', ?, 'neu', 'pdf')",
                          [tuesday])
        }
        await StudIPSync.autoPlan(host: recorder.inner.host, newFiles: 1)
        let cal = try await api.value("/api/calendar?start=2026-11-20&end=2026-11-22")
        let titles = cal.list("days").flatMap { $0.list("packages") }.flatMap { $0.list("tasks") }.compactMap { $0.s("title") }
        XCTAssertEqual(titles, ["VL06.pdf"], "nur die Lehrwoche 6: \(titles)")
        // aus: kein weiterer Lauf, auch mit neuen Dateien
        _ = try await api.value("/api/settings", method: "PUT", body: ["auto_plan": false])
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES ('f-12', 'k-a-gu', 'GU06.pdf', 'Gruppenübung', ?, 'neu', 'pdf')",
                          [wednesday])
        }
        await StudIPSync.autoPlan(host: recorder.inner.host, newFiles: 1)
        let again = try await api.value("/api/calendar?start=2026-11-20&end=2026-11-22")
        XCTAssertEqual(again.list("days").flatMap { $0.list("packages") }.flatMap { $0.list("tasks") }.compactMap { $0.s("title") }, ["VL06.pdf"])
    }

    /// Nach einem vollen Abgleich laeuft auch der Takt der Wochentests wie `_full_sync` am PC: ohne KI nicht (kein
    /// Versuch verbraucht), im kurzen Hintergrundlauf (`weekly: false`) nicht, sonst ja. Der Plan ohne markierten
    /// Stoff scheitert dabei und zaehlt einen Versuch (so ist der Lauf sichtbar).
    func testAutoPlanAfterSyncRunsTheWeeklyTick() async throws {
        let (_, recorder) = try await seededAPI()                   // Freitag, 20.11.2026
        let host = recorder.inner.host
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            try c.execute("""
                INSERT INTO wt_plans(module_id, week_no, scope, scope_key, coverage, lecture_end, publish_at, deadline_at, attempts)
                VALUES(1, 1, 'personal', 'k', '{}', '2026-11-19T10:00:00', '2026-11-19T11:00:00', '2026-11-22T11:00:00', 0)
                """)
        }
        func plan() async throws -> [String: JSONValue] {
            let rows = try await backend.context.database.rows("SELECT status, attempts, lock_until FROM wt_plans")
            return try XCTUnwrap(rows.first)
        }
        await StudIPSync.autoPlan(host: host, newFiles: 0)
        let noAI = try await plan()
        XCTAssertEqual(noAI["attempts"], .number(0), "ohne KI kein Takt")
        backend.context.ai.set(EchoAI())
        await StudIPSync.autoPlan(host: host, newFiles: 0, weekly: false)
        let lists = try await plan()
        XCTAssertEqual(lists["attempts"], .number(0), "kurzer Hintergrundlauf: kein Takt")
        await StudIPSync.autoPlan(host: host, newFiles: 0)
        let after = try await plan()
        XCTAssertEqual(after["attempts"], .number(1), "der Takt lief nach dem vollen Abgleich")
        XCTAssertEqual(after["status"], "fehlgeschlagen")
        XCTAssertEqual(after["lock_until"], .null, "Sperre geloest")
    }

    // MARK: Takt im Vordergrund

    private struct EchoAI: AIProvider {
        func answer(system: String, prompt: String) async throws -> String { "{}" }
    }

    func testAutoTickerRules() async throws {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-20T10:00:00")!)
        let backend = try await host.backend()
        let ticker = WeeklyAutoTicker(backend: { backend })
        let none = await ticker.runOnce()
        XCTAssertEqual(none, .noAI, "ohne KI kein Lauf")
        backend.context.ai.set(EchoAI())
        let ran = await ticker.runOnce()
        XCTAssertEqual(ran, .ran("0 veröffentlicht, 0 wartend, 0 fehlgeschlagen, 0 Nachträge", changed: false))
        _ = try await backend.context.database.execute("INSERT OR REPLACE INTO settings(key, value) VALUES('auto_tests', '0')")
        let off = await ticker.runOnce()
        XCTAssertEqual(off, .off)
        let empty = WeeklyAutoTicker(backend: { nil })
        let missing = await empty.runOnce()
        XCTAssertNil(missing, "ohne Hochschule kein Backend")
        // unter XCTest startet die Schleife nie (die Tests bauen eigene Laeufe)
        empty.resume()
        XCTAssertFalse(empty.isRunning)
    }
}
