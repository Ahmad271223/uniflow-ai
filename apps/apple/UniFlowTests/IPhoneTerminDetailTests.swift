import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Termin-Detail auf dem iPhone (develop Build 10, 06.11.2026; docs/IPHONE-STAND-2026-11-06.md): Termin im Stundenplan
/// oder Lernkalender antippen -> Blatt von unten (halb/ganz) mit "Zum Modul", Raum (Antippen startet die Route zu Fuss),
/// "Im Raumfinder anzeigen" und den Lehrenden; Knoepfe in voller Breite, nichts ragt ueber den Rand. Einzeltermin
/// (Uni-Kalender, Stud.IP-Kalender) als Dialog-Blatt. Gegenprobe iPad: Schublade rechts, kleine Knoepfe.
/// Lehrende erfunden (example.org), lokales Backend, kein Netz; geoeffnet wird nichts (`TerminOpen.handler`).
final class IPhoneTerminDetailTests: IPhoneLearnTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-05T10:00:00")!
    private var opened: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            opened = []
            TerminOpen.handler = { [weak self] url in self?.opened.append(url) }
            TerminLecturersSection.tried = []
            TerminLecturersSection.fetchOverride = nil
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            TerminOpen.handler = nil
            TerminLecturersSection.fetchOverride = nil
        }
        try await super.tearDown()
    }

    /// Geraet mit Modul, Kurs "c-ma", Vorlesung am Donnerstag in "1101 - F102" und zwei Dozent/innen plus Tutor
    private func device() throws -> (APIClient, Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-termin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: clock, university: .luh)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let id = try awaiting { () async throws -> Int in
            let b = try await host.backend()
            try await b.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color) VALUES (1, 'Mathematik für Ingenieure I', '#4f5bd5')")
                try c.execute("INSERT INTO courses(id, title, kind, active, module_id, created_at) VALUES ('c-ma', 'Mathematik für Ingenieure I', 'vorlesung', 1, 1, 't')")
                try c.execute("""
                    CREATE TABLE IF NOT EXISTS studip_lecturers (course_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL,
                    position INTEGER, label TEXT, name TEXT, username TEXT, email TEXT, office_hours TEXT, location TEXT, institute TEXT,
                    fetched_at TEXT, PRIMARY KEY (course_id, user_id))
                    """)
                try c.execute("CREATE TABLE IF NOT EXISTS studip_lecturer_courses (course_id TEXT PRIMARY KEY, fetched_at TEXT NOT NULL)")
                let rows: [(String, String, Int, String, String, String, String)] = [
                    ("u-a", "dozent", 0, "Prof. Dr. Erika Beispiel", "ebeispiel", "erika.beispiel@example.org", "Di 10–11 Uhr"),
                    ("u-b", "dozent", 1, "Dr. Max Muster", "mmuster", "max.muster@example.org", ""),
                    ("u-t", "tutor", 2, "Erfundener Tutor", "etutor", "", ""),
                ]
                for r in rows {
                    try c.execute("""
                        INSERT INTO studip_lecturers(course_id, user_id, role, position, label, name, username, email, office_hours, location,
                        institute, fetched_at) VALUES ('c-ma', ?, ?, ?, '', ?, ?, ?, ?, '', '', '2026-11-05T09:00:00')
                        """, [.text(r.0), .text(r.1), .integer(Int64(r.2)), .text(r.3), .text(r.4), .text(r.5), .text(r.6)])
                }
                try c.execute("INSERT INTO studip_lecturer_courses(course_id, fetched_at) VALUES ('c-ma', '2026-11-05T09:00:00')")
            }
            let created = try await api.value("/api/timetable/events", method: "POST",
                                              body: ["title": "Mathematik für Ingenieure I", "kind": "vorlesung", "weekday": 3, "start_time": "10:00",
                                                     "end_time": "11:30", "rrule": "weekly", "room": "1101 - F102", "module_id": 1,
                                                     "course_id": "c-ma"])
            return try XCTUnwrap(created.i("id"))
        }
        return (api, id)
    }

    /// Oeffnet den Termin wie Stundenplan und Lernkalender (`PlanActions.openEvent`) mit der Schublade der Huelle
    private struct Opener: View {
        let id: Int
        @EnvironmentObject private var overlay: UFOverlay
        @EnvironmentObject private var toast: UFToastCenter
        @EnvironmentObject private var router: UFRouter
        @EnvironmentObject private var session: Session

        var body: some View {
            Color.clear
                .modifier(UFDrawerHost(overlay: overlay))
                .onAppear { PlanActions(api: session.api, overlay: overlay, toast: toast, router: router).openEvent(id, date: "2026-11-05") }
        }
    }

    private func presented(_ env: HostedEnvironment) -> UIViewController? {
        guard let p = env.hosting.presentedViewController, !p.isBeingDismissed else { return nil }
        return p
    }

    private func presentedFrame(_ env: HostedEnvironment) -> CGRect {
        guard let p = presented(env), let v = p.presentationController?.presentedView ?? p.view else { return .null }
        return v.convert(v.bounds, to: nil)
    }

    func testEventAsHalfSheetWithWideRoomAndLecturers() throws {
        let (api, id) = try device()
        let env = try hostPhone(Opener(id: id), api: api)
        XCTAssertTrue(env.wait(timeout: 15) { self.presented(env) != nil && self.shows(env, "Dr. Max Muster") }, dump(env))
        let sheet = try XCTUnwrap(presented(env))
        XCTAssertEqual(Set(sheet.sheetPresentationController?.detents.map(\.identifier) ?? []), [.medium, .large], "halb und ganz")
        sheet.sheetPresentationController?.animateChanges { sheet.sheetPresentationController?.selectedDetentIdentifier = .large }
        env.pump(0.8)
        let s = presentedFrame(env)
        let route = frame(button(env, "Raum 1101 - F102, Route zu Fuß starten"))
        let finder = frame(button(env, "Raum 1101 - F102 im Raumfinder anzeigen"))
        let all = frame(button(env, "Allen Lehrenden schreiben"))
        let module = frame(element(env, id: "termin.module"))
        for (name, f) in [("Route", route), ("Raumfinder", finder), ("Allen schreiben", all), ("Zum Modul", module)] {
            XCTAssertGreaterThan(f.width, s.width * 0.8, "\(name) in voller Breite: \(f) in \(s)")
            XCTAssertGreaterThanOrEqual(f.height, 43.5, "\(name) 44 pt hoch: \(f)")
        }
        XCTAssertGreaterThan(finder.minY, route.maxY - 1, "Raumfinder unter der Route")
        let mail = frame(button(env, "E-Mail an erika.beispiel@example.org"))
        XCTAssertGreaterThanOrEqual(mail.height, 43.5, "E-Mail-Adresse 44 pt hoch: \(mail)")
        XCTAssertGreaterThan(frame(button(env, "Nachricht in Stud.IP", prefix: true)).width, s.width * 0.6, "Stud.IP-Nachricht breit")
        assertFits(env, "Termin-Detail")
        shoot(env, "iphone-termin-detail")
        // Raum antippen: Route zu Fuss, sofort
        XCTAssertTrue(tap(env, "Raum 1101 - F102, Route zu Fuß starten"))
        XCTAssertTrue(env.wait { !self.opened.isEmpty }, dump(env))
        XCTAssertTrue(opened.first?.absoluteString.contains("walking") == true, "\(opened)")
        // E-Mail ohne Uni-Mail: mailto mit Betreff
        XCTAssertTrue(tap(env, "E-Mail an max.muster@example.org"))
        XCTAssertTrue(env.wait { self.opened.count == 2 }, dump(env))
        XCTAssertEqual(opened.last?.absoluteString, "mailto:max.muster@example.org?subject=Frage%20zu%20Mathematik%20f%C3%BCr%20Ingenieure%20I")
        dismissSheet(env)
    }

    func testEventFitsOnAllPhones() throws {
        let (api, id) = try device()
        let env = try hostPhone(Opener(id: id), api: api)
        XCTAssertTrue(env.wait(timeout: 15) { self.presented(env) != nil && self.shows(env, "Prof. Dr. Erika Beispiel") }, dump(env))
        assertFitsOnAllPhones(env, "Termin-Detail")
        dismissSheet(env)
    }

    /// Einzeltermin (ohne Serie) als Dialog-Blatt: Quelle, "Zum Modul" breit, Raum und Lehrende
    func testDatedEventDialogOnPhone() throws {
        let (api, _) = try device()
        let e: JSONValue = ["title": "Mathematik für Ingenieure I", "start": "10:00", "end": "11:30", "room": "1101 - F102",
                            "kind": "vorlesung", "module_id": 1, "course_id": "c-ma"]
        let env = try hostPhone(DatedEventDialog(e: e, date: "2026-11-05").padding(16), api: api)
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Dr. Max Muster") }, dump(env))
        XCTAssertGreaterThan(frame(element(env, id: "termin.module")).width, env.window.bounds.width * 0.7, "Zum Modul breit")
        XCTAssertGreaterThan(frame(button(env, "Allen Lehrenden schreiben")).width, env.window.bounds.width * 0.7)
        XCTAssertNotNil(element(env, id: "event.source"))
        assertFitsOnAllPhones(env, "Einzeltermin")
    }

    /// iPad: Schublade rechts (kein Blatt), Knoepfe wie bisher klein
    func testPadKeepsDrawerAndSmallButtons() throws {
        let (api, id) = try device()
        let env = try hostPad(Opener(id: id), api: api)
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Dr. Max Muster") }, dump(env))
        XCTAssertNil(presented(env), "iPad: Schublade, kein Blatt")
        XCTAssertLessThan(frame(button(env, "Allen Lehrenden schreiben")).width, 300, "iPad: kleiner Knopf")
        XCTAssertLessThan(frame(button(env, "Raum 1101 - F102 im Raumfinder anzeigen")).width, 300)
    }
}
