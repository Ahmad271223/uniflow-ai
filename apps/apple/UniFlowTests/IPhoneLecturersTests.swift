import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Lehrende auf dem iPhone (develop Build 10, LUH, Stud.IP; docs/IPHONE-STAND-2026-11-06.md): Seite "Lehrende" mit
/// Suche in voller Breite, Personen als Liste (E-Mail 44 pt hoch, "Nachricht in Stud.IP" in voller Breite), Bereich
/// "Lehrende" auf der Modulseite; erreichbar aus Uni-Mail (Zeile in voller Breite) und von der Modulseite. Personen aus
/// der Debug-Nachbildung (erfunden, example.org), kein Netz.
final class IPhoneLecturersTests: IPhoneLearnTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-06T10:00:00")!

    private func device() throws -> APIClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-lehrende-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let host = LocalBackendHost(directory: dir.appendingPathComponent("db", isDirectory: true), clock: clock, university: .luh)
        try awaiting {
            let b = try await host.backend()
            try await b.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color) VALUES (1, 'Mathematik für Ingenieure I', '#4f5bd5'), (2, 'Programmieren I', '#0e9f9a')")
                for (id, title, module) in [("c-ma", "Mathematik für Ingenieure I", 1), ("c-ma-ue", "Übung zu Mathematik für Ingenieure I", 1),
                                            ("c-prog", "Programmieren I", 2)] {
                    try c.execute("INSERT INTO courses(id, title, kind, active, module_id, created_at) VALUES (?, ?, 'vorlesung', 1, ?, 't')",
                                  [.text(id), .text(title), .integer(Int64(module))])
                }
            }
            let client = StudIPClient(base: StudIPSync.base, transport: DebugStubTransport(directory: ContainerTestBed.stubDirectory), pauseMillis: 0)
            _ = await StudIPExtrasSync(host: host).lecturers(client: client, courses: [
                StudIPCourse(id: "c-ma", title: "Mathematik für Ingenieure I"),
                StudIPCourse(id: "c-ma-ue", title: "Übung zu Mathematik für Ingenieure I"),
                StudIPCourse(id: "c-prog", title: "Programmieren I"),
            ])
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    private func rows(_ env: HostedEnvironment) -> [NSObject] { elements(env).filter { identifier($0) == "lecturer.row" } }

    func testPageListWithWideSearchAndButtons() throws {
        let env = try hostPhone(LecturersPage(), api: try device())
        XCTAssertTrue(env.wait(timeout: 15) { !self.rows(env).isEmpty }, dump(env))
        let width = env.window.bounds.width
        XCTAssertGreaterThan(frame(element(env, id: "lecturers.search")).width, width * 0.8, "Suche in voller Breite")
        let row = try XCTUnwrap(rows(env).first)
        XCTAssertGreaterThan(frame(row).width, width * 0.75, "Person als Zeile in voller Breite")
        let mail = try XCTUnwrap(elements(env).first { identifier($0) == "lecturer.email" })
        XCTAssertGreaterThanOrEqual(frame(mail).height, 43.5, "E-Mail 44 pt hoch")
        let message = try XCTUnwrap(elements(env).first { identifier($0) == "lecturer.studipMessage" })
        XCTAssertGreaterThan(frame(message).width, width * 0.7, "Nachricht in Stud.IP in voller Breite")
        XCTAssertTrue(shows(env, "Die Angaben bleiben auf diesem \(UFDevice.name)"), "Geraetename im Hinweis")
        assertFitsOnAllPhones(env, "Lehrende")
        shoot(env, "iphone-lehrende")
    }

    func testModuleSectionOnPhone() throws {
        let env = try hostPhone(ScrollView { ModuleLecturersCard(moduleID: 1, moduleName: "Mathematik für Ingenieure I").padding(16) }, api: try device())
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "Alle Lehrenden") != nil && self.element(env, label: "Dr. Beispiel Dozentin,", prefix: true) != nil },
                      dump(env))
        XCTAssertGreaterThan(frame(element(env, label: "Dr. Beispiel Dozentin,", prefix: true)).width, env.window.bounds.width * 0.75,
                             "Person in voller Breite")
        assertFitsOnAllPhones(env, "Lehrende im Modul")
    }

    func testPadKeepsSmallButtons() throws {
        let env = try hostPad(LecturersPage(), api: try device())
        XCTAssertTrue(env.wait(timeout: 15) { !self.rows(env).isEmpty }, dump(env))
        let message = try XCTUnwrap(elements(env).first { identifier($0) == "lecturer.studipMessage" })
        XCTAssertLessThan(frame(message).width, 300, "iPad: kleiner Knopf")
        XCTAssertLessThanOrEqual(frame(element(env, id: "lecturers.search")).width, 421, "iPad: Suche 420 breit")
    }
}
