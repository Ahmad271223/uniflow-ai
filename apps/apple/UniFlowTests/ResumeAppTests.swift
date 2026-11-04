import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Weitermachen wie zuvor (04.11.2026, docs/WEITERMACHEN-2026-11-04.md): Stand je Fenster mitschreiben (Dokument,
/// Seite, KI-Hilfe, "Daneben öffnen") und beim Start entscheiden: Dokument wieder oeffnen, andere Seite, oder still auf
/// der Uebersicht bleiben (nichts gemerkt, Dokument verschwunden). Alle Daten sind erfunden.
@MainActor
final class ResumeAppTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "resume-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Gemerkter Stand, wie ein Fenster mit dieser Kennung ihn beim Start liest
    private func stored(_ d: UserDefaults, scene: String) -> ResumeState? {
        let t = ResumeTracker(defaults: d)
        t.sceneID = scene
        return t.stored()
    }

    // MARK: reine Entscheidung

    func testDecision() {
        XCTAssertEqual(ResumeDecision.decide(nil, documentExists: nil), .dashboard)
        XCTAssertEqual(ResumeDecision.decide(ResumeState(route: "#/"), documentExists: nil), .dashboard)
        XCTAssertEqual(ResumeDecision.decide(ResumeState.forRoute(.plan(view: "day")), documentExists: nil), .route(.plan(view: "day")))
        var s = ResumeState.forRoute(.doc("f1", page: 4))
        s.tutorOpen = true
        XCTAssertEqual(ResumeDecision.decide(s, documentExists: true), .document(id: "f1", page: 4, panels: s))
        XCTAssertEqual(ResumeDecision.decide(s, documentExists: false), .dashboard, "Dokument weg: still Uebersicht")
        XCTAssertEqual(ResumeDecision.decide(s, documentExists: nil), .dashboard)
    }

    // MARK: Mitschreiben

    func testTrackerWritesPanelsPerScene() throws {
        let d = try defaults()
        let t = ResumeTracker(defaults: d)
        t.now = { Date(timeIntervalSince1970: 1_793_000_000) }
        t.sceneID = "A"
        t.noteRoute(.doc("f1"))
        t.noteDocument(id: "f1", page: nil)
        t.notePage(5, of: "f1")
        t.noteTutor(open: true, of: "f1")
        t.noteCompanion(id: "f2", page: 3, of: "f1")
        t.notePage(9, of: "anderes")                                    // fremdes Dokument: nichts
        let s = try XCTUnwrap(stored(d, scene: "A"))
        XCTAssertEqual(s.fileID, "f1")
        XCTAssertEqual(s.page, 5)
        XCTAssertEqual(s.route, "#/doc/f1?page=5")
        XCTAssertTrue(s.tutorOpen)
        XCTAssertEqual(s.companionID, "f2")
        XCTAssertEqual(s.companionPage, 3)
        XCTAssertFalse(s.at.isEmpty)

        // Sprung auf eine Seite desselben Dokuments behaelt die Spalten; ein anderes Ziel setzt sie zurueck
        t.noteRoute(.doc("f1", page: 7))
        XCTAssertEqual(t.state?.tutorOpen, true)
        XCTAssertEqual(t.state?.page, 7)
        t.noteTutor(open: false, of: "f1")
        XCTAssertEqual(stored(d, scene: "A")?.tutorOpen, false)
        t.noteRoute(.dashboard)                                         // ausdruecklich geschlossen
        XCTAssertNil(stored(d, scene: "A")?.fileID)

        // anderes Fenster: eigener Stand; unbekanntes Fenster (nach Beenden neu angelegt): der zuletzt geschriebene
        let b = ResumeTracker(defaults: d)
        b.sceneID = "B"
        b.noteRoute(.doc("f9", page: 2))
        XCTAssertNil(stored(d, scene: "A")?.fileID)
        XCTAssertEqual(stored(d, scene: "neu")?.fileID, "f9")
    }

    func testRestoresAtLaunchFlags() throws {
        let d = try defaults()
        XCTAssertFalse(MainView.restoresAtLaunch(defaults: d, underTest: true))
        XCTAssertTrue(MainView.restoresAtLaunch(defaults: d, underTest: false))
        d.set("#/plan", forKey: "UFRoute")
        XCTAssertFalse(MainView.restoresAtLaunch(defaults: d, underTest: false), "Startparameter waehlen selbst eine Seite")
    }

    // MARK: Wiederherstellen mit dem lokalen Backend

    private func host() async throws -> LocalBackendHost {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let backend = try await host.backend()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, subject, kind, created_at) VALUES ('k1', 'Analysis I', 'Analysis', 'vorlesung', '2026-10-01')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f1', 'k1', 'vl01.pdf', 5, 'pdf')")
        }
        return host
    }

    private func written(_ d: UserDefaults, _ s: ResumeState) throws {
        d.set(try JSONEncoder().encode(s), forKey: ResumeState.lastKey)
    }

    func testRestoreDocumentWithTutorOpen() async throws {
        let d = try defaults()
        var s = ResumeState.forRoute(.doc("f1", page: 4))
        s.tutorOpen = true
        s.companionID = "f2"
        try written(d, s)
        let t = ResumeTracker(defaults: d)
        let router = UFRouter()
        let decision = await t.restoreIfNeeded(api: APIClient.local(try await host()), router: router)
        XCTAssertEqual(decision, .document(id: "f1", page: 4, panels: s))
        XCTAssertEqual(router.route, .doc("f1", page: 4))
        XCTAssertNil(t.takeRestoredPanels(for: "anderes"))
        let p = try XCTUnwrap(t.takeRestoredPanels(for: "f1"))
        XCTAssertTrue(p.tutorOpen)
        XCTAssertEqual(p.companionID, "f2")
        XCTAssertNil(t.takeRestoredPanels(for: "f1"), "nur einmal")
        let again = await t.restoreIfNeeded(api: APIClient.local(try await host()), router: router)
        XCTAssertEqual(again, .dashboard, "einmal je Fenster")
        XCTAssertEqual(t.stored()?.tutorOpen, true, "Spalten bleiben gemerkt, bis der Editor meldet")
    }

    func testRestoreMissingDocumentStaysOnDashboard() async throws {
        let d = try defaults()
        try written(d, ResumeState.forRoute(.doc("geloescht", page: 2)))
        let router = UFRouter()
        let decision = await ResumeTracker(defaults: d).restoreIfNeeded(api: APIClient.local(try await host()), router: router)
        XCTAssertEqual(decision, .dashboard)
        XCTAssertEqual(router.route, .dashboard)
    }

    func testRestoreOtherRouteAndNothingStored() async throws {
        let d = try defaults()
        let router = UFRouter()
        let none = await ResumeTracker(defaults: d).restoreIfNeeded(api: nil, router: router)
        XCTAssertEqual(none, .dashboard)
        try written(d, ResumeState.forRoute(.cards))
        let decision = await ResumeTracker(defaults: d).restoreIfNeeded(api: nil, router: router)
        XCTAssertEqual(decision, .route(.cards))
        XCTAssertEqual(router.route, .cards)
    }

    /// Ohne Zugang wartet die Wiederherstellung eines Dokuments auf den naechsten Versuch (Container noch zu)
    func testRestoreWaitsForAPI() async throws {
        let d = try defaults()
        try written(d, ResumeState.forRoute(.doc("f1")))
        let t = ResumeTracker(defaults: d)
        let router = UFRouter()
        let first = await t.restoreIfNeeded(api: nil, router: router)
        XCTAssertEqual(first, .dashboard)
        let second = await t.restoreIfNeeded(api: APIClient.local(try await host()), router: router)
        XCTAssertEqual(second, .document(id: "f1", page: nil, panels: ResumeState.forRoute(.doc("f1"))))
    }
}
